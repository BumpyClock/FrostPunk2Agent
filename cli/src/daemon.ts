// fp2 daemon: one long-lived process that owns the file bridge.
// It listens on 127.0.0.1 (random port, token in .runtime/daemon.json) and serializes every bridge call in one
// in-process queue. Clients send whole commands (/run: the command runs in the daemon, output comes back) or raw
// bridge calls (/call: watcher, UI commands that stay in the client). It runs from a copy of fp2.exe
// (.runtime/fp2-daemon.exe) so `bun run build` can replace fp2.exe; a client that sees a newer fp2.exe restarts it.
import { AsyncLocalStorage } from "node:async_hooks";
import { spawn } from "node:child_process";
import { closeSync, copyFileSync, existsSync, mkdirSync, openSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from "node:fs";
import { basename, join, resolve } from "node:path";
import { BridgeError, directCallEnvelope, pidAlive, repoRoot, setTransport, type Envelope, type Transport } from "./bridge";
import { disablePowerThrottling } from "./win32";

const IDLE_EXIT_MS = 6 * 3600_000;
const STATUS_TIMEOUT_MS = 300;
const START_TIMEOUT_MS = 10_000;
/** Blank keepalive lines on long responses, so no idle timeout on either side cuts a 10-minute turn. */
const KEEPALIVE_MS = 5000;
const DAEMON_POLL_MS = 5;
const QUEUE_WAIT_MS = 60_000;
/** A rebuilt fp2.exe restarts the daemon only after this much quiet: a client command between its calls looks idle. */
const RESTART_QUIET_MS = 10_000;

/** Commands that drive the game for a long time: one at a time per daemon. */
export const LONG_COMMANDS = new Set(["turn", "advance", "overdrive-cycle", "wait-for", "wait-ready"]);
/** Commands that resume game time: an interrupt pauses the game. */
const RESUMES_TIME = new Set(["turn", "advance", "overdrive-cycle"]);

export type DaemonInfo = { pid: number; port: number; token: string; srcExe: string; exeMtime: number; exe: string; started: number };
export type RunIO = { out: (s: string) => void; stdin?: string };
export type RunCli = (argv: string[], io: RunIO) => Promise<number>;

const runtimeDir = () => join(repoRoot(), ".runtime");
const infoFile = () => join(runtimeDir(), "daemon.json");
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const errText = (e: unknown) => (e instanceof Error ? e.message : String(e));

/** A compiled fp2 exe (not `bun run src/main.ts`): only then can a daemon copy of it be started. */
export const compiled = () => !/^bun(\.exe)?$/i.test(basename(process.execPath));
/** The user-facing fp2.exe: may start, stop and restart daemons. The watcher and the daemon copies only route. */
export const isManager = () => compiled() && !/[\\/]\.runtime[\\/]/i.test(process.execPath);

/** The recorded daemon, or null. A record whose pid is gone is removed. */
export function readDaemonInfo(): DaemonInfo | null {
  let info: DaemonInfo;
  try {
    info = JSON.parse(readFileSync(infoFile(), "utf8"));
  } catch {
    return null;
  }
  if (info.pid && pidAlive(info.pid)) return info;
  rmSync(infoFile(), { force: true });
  return null;
}

// ---------------------------------------------------------------- client side

// Connection failures carry code "ConnectionRefused": nothing reached the daemon, so a fallback cannot run twice.
const isRefused = (e: any) => e?.code === "ConnectionRefused";
/** The daemon accepted the connection but sent nothing: its event loop is stuck. */
const isStuck = (e: any) => e?.code === "DaemonStuck";
/** /run and /call replies start with a newline at once; silence for this long means a stuck daemon. */
const FIRST_BYTE_MS = 3000;
const STUCK_PROBE_MS = 2000;

/** Parse an HTTP/1.1 reply; null until it is complete (content-length reached, or the last chunk seen). */
function parseHttp(raw: Buffer): { status: number; body: string } | null {
  const sep = raw.indexOf("\r\n\r\n");
  if (sep < 0) return null;
  const head = raw.subarray(0, sep).toString("latin1");
  const status = Number(head.split(" ")[1]);
  const body = raw.subarray(sep + 4);
  const length = head.match(/^content-length:\s*(\d+)/im);
  if (length) return body.length >= Number(length[1]) ? { status, body: body.subarray(0, Number(length[1])).toString("utf8") } : null;
  if (!/^transfer-encoding:\s*chunked/im.test(head)) return null;
  const parts: Buffer[] = [];
  for (let i = 0; ; ) {
    const nl = body.indexOf("\r\n", i);
    if (nl < 0) return null;
    const size = parseInt(body.subarray(i, nl).toString("latin1"), 16);
    if (size === 0) return { status, body: Buffer.concat(parts).toString("utf8") };
    if (!(size > 0) || body.length < nl + 2 + size) return null;
    parts.push(body.subarray(nl + 2, nl + 2 + size));
    i = nl + 2 + size + 2;
  }
}

/**
 * Minimal HTTP/1.1 client on Bun.connect. In a fresh process the first fetch() cost ~32 ms and a Bun.connect
 * request ~4 ms (measured); every fp2 call pays that once. `totalMs` bounds the whole exchange.
 */
function http(info: DaemonInfo, method: string, path: string, body?: unknown, totalMs?: number): Promise<{ status: number; body: string }> {
  return new Promise((resolve, reject) => {
    const payload = body === undefined ? "" : JSON.stringify(body);
    let pending = Buffer.from(
      `${method} ${path} HTTP/1.1\r\nHost: 127.0.0.1\r\nx-fp2-token: ${info.token}\r\nContent-Type: application/json\r\n` +
        `Content-Length: ${Buffer.byteLength(payload)}\r\nConnection: close\r\n\r\n${payload}`,
    );
    const chunks: Buffer[] = [];
    let settled = false;
    let sock: { end(): void } | undefined;
    const fail = (e: any, code?: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (code) e = Object.assign(e instanceof Error ? e : new Error(String(e)), { code });
      reject(e);
      sock?.end();
    };
    // Silence on /run or /call: ask /status on a second connection; while it answers the daemon is only slow,
    // so keep waiting. No answer within STUCK_PROBE_MS too means its event loop is stuck.
    const timer = setTimeout(() => {
      if (totalMs) return fail(new Error(`daemon did not answer within ${totalMs} ms`), "DaemonTimeout");
      daemonStatus(info, STUCK_PROBE_MS).then((st) => {
        if (!st) fail(new Error(`daemon sent nothing for ${FIRST_BYTE_MS} ms and /status did not answer`), "DaemonStuck");
      });
    }, totalMs ?? FIRST_BYTE_MS);
    const flush = (s: { write(b: Buffer): number }) => {
      if (pending.length) pending = pending.subarray(s.write(pending));
    };
    Bun.connect({
      hostname: "127.0.0.1",
      port: info.port,
      socket: {
        open(s) {
          sock = s;
          flush(s);
        },
        drain: flush,
        data(s, d) {
          if (!chunks.length && !totalMs) clearTimeout(timer);
          chunks.push(Buffer.from(d));
          // Bun.serve keeps a streamed reply's connection open: finish on the last chunk, not on close.
          const reply = parseHttp(Buffer.concat(chunks));
          if (!reply || settled) return;
          settled = true;
          clearTimeout(timer);
          resolve(reply);
          s.end();
        },
        close() {
          fail(new BridgeError("daemon closed the connection before its reply was complete"));
        },
        error(_s, e) {
          fail(e);
        },
        connectError(_s, e) {
          fail(e, "ConnectionRefused");
        },
      },
    }).catch((e) => fail(e, "ConnectionRefused"));
  });
}

/** POST and read a streamed reply: keepalive blank lines, then one JSON line. */
async function post(info: DaemonInfo, path: string, body: unknown, totalMs?: number): Promise<any> {
  const res = await http(info, "POST", path, body, totalMs);
  const last = res.body.trim().split("\n").at(-1) ?? "";
  try {
    return JSON.parse(last);
  } catch {
    throw new BridgeError(`daemon replied ${res.status}: ${res.body.slice(0, 200)}`);
  }
}

export async function daemonStatus(info: DaemonInfo, timeoutMs = STATUS_TIMEOUT_MS): Promise<any | null> {
  try {
    const res = await http(info, "GET", "/status", undefined, timeoutMs);
    return res.status === 200 ? JSON.parse(res.body) : null;
  } catch {
    return null;
  }
}

/** Kill a recorded daemon process (only when its image is an fp2-daemon copy) and drop its record. */
function killDaemon(info: DaemonInfo) {
  if (pidAlive(info.pid) && /^fp2-daemon/i.test(imageName(info.pid))) Bun.spawnSync(["taskkill", "/PID", String(info.pid), "/F"]);
  try {
    if (JSON.parse(readFileSync(infoFile(), "utf8")).pid === info.pid) rmSync(infoFile(), { force: true });
  } catch {}
}

/**
 * Bridge calls from a client process: through the daemon while one answers, else the file bridge directly.
 * The daemon is looked up again after a refused connection (its port and token change on every restart).
 * Only a refused connection falls back: the call never reached the daemon, so it cannot run twice.
 */
export function routedTransport(initial: DaemonInfo | null = readDaemonInfo()): Transport {
  let info = initial;
  return async (command, args, timeoutMs) => {
    for (let attempt = 0; attempt < 2; attempt++) {
      if (!info) info = readDaemonInfo();
      if (!info) break;
      try {
        const r = await post(info, "/call", { command, args, timeoutMs });
        if (r.thrown !== undefined) throw new BridgeError(r.thrown);
        return r.envelope as Envelope;
      } catch (e) {
        // A stuck daemon never read the request, so the call can go direct. Only fp2.exe kills it: the watcher
        // must not end a daemon that may recover in the middle of a turn.
        if (isStuck(e) && isManager()) killDaemon(info);
        else if (!isRefused(e)) throw e;
        info = null;
      }
    }
    return directCallEnvelope(command, args, timeoutMs);
  };
}

function imageName(pid: number): string {
  const out = Bun.spawnSync(["tasklist", "/FI", `PID eq ${pid}`, "/FO", "CSV", "/NH"]).stdout.toString();
  return out.match(/^"([^"]+)"/)?.[1] ?? "";
}

/** Stop a daemon: /stop, then kill it if it is still there after 3 s. Refuses a busy daemon unless force. */
export async function stopDaemon(info: DaemonInfo, force = false): Promise<{ stopped: boolean; pid: number; reason?: string }> {
  try {
    const r = await post(info, "/stop", { force }, 2000);
    if (r.ok === false) return { stopped: false, pid: info.pid, reason: r.error };
  } catch {}
  for (let i = 0; i < 150 && pidAlive(info.pid); i++) await sleep(20);
  if (pidAlive(info.pid)) killDaemon(info);
  for (let i = 0; i < 100 && pidAlive(info.pid); i++) await sleep(20);
  killDaemon(info);
  return { stopped: !pidAlive(info.pid), pid: info.pid };
}

const exeMtime = (path: string) => statSync(path).mtimeMs;
const sameExe = (info: DaemonInfo, src: string) => info.srcExe.toLowerCase() === src.toLowerCase() && info.exeMtime === exeMtime(src);

/** Copy fp2.exe next to .runtime unless an identical copy is there; a copy locked by a running daemon is skipped. */
function daemonExe(src: string): string | null {
  const s = statSync(src);
  for (const name of ["fp2-daemon.exe", "fp2-daemon-b.exe"]) {
    const dest = join(runtimeDir(), name);
    try {
      const d = statSync(dest);
      if (d.size === s.size && d.mtimeMs === s.mtimeMs) return dest; // CopyFileW keeps the write time
    } catch {}
    try {
      copyFileSync(src, dest);
      return dest;
    } catch {}
  }
  return null;
}

async function startDaemon(src: string): Promise<DaemonInfo | null> {
  mkdirSync(runtimeDir(), { recursive: true });
  const lock = join(runtimeDir(), "daemon.start.lock");
  const deadline = Date.now() + START_TIMEOUT_MS;
  // One starter at a time; the others wait for its daemon.
  for (;;) {
    try {
      closeSync(openSync(lock, "wx"));
      break;
    } catch {
      try {
        if (Date.now() - statSync(lock).mtimeMs > 20_000) rmSync(lock, { force: true });
      } catch {}
      const info = readDaemonInfo();
      if (info && (await daemonStatus(info))) return info;
      if (Date.now() > deadline) return null;
      await sleep(50);
    }
  }
  try {
    // Another starter may have finished while this one waited for the lock.
    const running = readDaemonInfo();
    if (running && sameExe(running, src) && (await daemonStatus(running))) return running;
    const exe = daemonExe(src);
    if (!exe) return null;
    const logFd = openSync(join(runtimeDir(), "daemon.log"), "a");
    const child = spawn(exe, ["daemon", "run", `src=${src}`], { cwd: repoRoot(), detached: true, stdio: ["ignore", logFd, logFd], windowsHide: true });
    child.unref();
    closeSync(logFd);
    while (Date.now() < deadline) {
      await sleep(25);
      const info = readDaemonInfo();
      if (info && info.pid === child.pid && (await daemonStatus(info))) return info;
      // The child exits when another daemon already answers (a racing starter): use that one.
      if (child.exitCode !== null) return info && sameExe(info, src) && (await daemonStatus(info)) ? info : null;
    }
    return null;
  } finally {
    rmSync(lock, { force: true });
  }
}

/**
 * A live daemon running the current fp2.exe, starting or restarting one as needed; null means use the file
 * bridge directly. The common case costs no round trip: daemon.json names a live pid started from this exact
 * fp2.exe (path and mtime); a dead or stuck daemon shows up on the request itself. A daemon on an older build
 * is restarted only when idle: killing it mid-turn would leave the game running.
 */
export async function ensureDaemon(): Promise<{ info: DaemonInfo | null; warning?: string }> {
  const src = process.execPath;
  let info = readDaemonInfo();
  if (info && sameExe(info, src)) return { info };
  if (info) {
    const st = await daemonStatus(info);
    if (st) {
      if (st.activeRuns > 0 || st.queueDepth > 0 || Number(st.idleMs ?? 0) < RESTART_QUIET_MS) {
        return { info, warning: `daemon (pid ${info.pid}) runs an older fp2.exe and is busy or was used in the last 10 s${st.busy ? ` with '${st.busy.argv.join(" ")}'` : ""}; using it until it is idle` };
      }
      await stopDaemon(info);
    } else {
      // Recorded pid is alive but does not answer: a hung daemon, or the pid was reused by another program.
      killDaemon(info);
      rmSync(infoFile(), { force: true });
    }
    info = null;
  }
  info = await startDaemon(src);
  return info ? { info } : { info: null, warning: "daemon did not start (see .runtime/daemon.log); using the file bridge directly" };
}

/**
 * Run a CLI command inside the daemon and return its exit code; its output goes to stdout.
 * Ctrl-C sends /interrupt: the daemon pauses the game (turn, advance, overdrive-cycle) and stops the run.
 * Returns null when the command never reached the daemon (refused, or a stuck daemon, which is killed): the
 * caller runs the command itself.
 */
export async function runRemote(info: DaemonInfo, argv: string[]): Promise<number | null> {
  argv = [...argv];
  let stdin: string | undefined;
  const fi = argv.indexOf("--args-file");
  if (fi >= 0 && argv[fi + 1] !== undefined) {
    // The daemon has another cwd and no stdin: resolve the file here.
    if (argv[fi + 1] === "-") stdin = await Bun.stdin.text();
    else argv[fi + 1] = resolve(argv[fi + 1]);
  }
  const runId = crypto.randomUUID();
  let interrupting = false;
  process.on("SIGINT", () => {
    if (interrupting) process.exit(130);
    interrupting = true;
    console.error("fp2: interrupting; the daemon stops the run (and pauses the game if the run resumed it)");
    post(info, "/interrupt", { runId }, 3000).catch(() => undefined);
    setTimeout(() => process.exit(130), 8000).unref();
  });
  let r: any;
  try {
    r = await post(info, "/run", { argv, stdin, runId });
  } catch (e) {
    if (isRefused(e)) return null;
    if (isStuck(e) && !(await daemonStatus(info, STUCK_PROBE_MS))?.busy) {
      killDaemon(info);
      return null;
    }
    console.log(JSON.stringify({ ok: false, error: `daemon connection failed: ${errText(e)}` }, null, 2));
    return 3;
  }
  if (r.thrown !== undefined) {
    console.log(JSON.stringify({ ok: false, error: r.thrown }, null, 2));
    return 2;
  }
  await Bun.write(Bun.stdout, String(r.output ?? ""));
  return interrupting ? 130 : Number(r.code ?? 3);
}

// ---------------------------------------------------------------- daemon side

type RunCtx = { id: string; argv: string[]; cmd: string; long: boolean; started: number; aborted: boolean; abortTaken: boolean; done: boolean };

const runCtx = new AsyncLocalStorage<RunCtx>();
const active = new Set<RunCtx>();
let longRun: RunCtx | null = null;
let queueTail: Promise<unknown> = Promise.resolve();
let queueDepth = 0;
let lastActivity = Date.now();
const stats = { calls: 0, callMsTotal: 0, lastCallMs: 0, runs: 0, runMsTotal: 0, lastRunMs: 0, rejected: 0, interrupts: 0 };

/** An interrupt surfaces once, as an error from the run's next (or current) bridge call; cleanup calls after it work. */
function takeAbort(ctx: RunCtx) {
  if (!ctx.aborted || ctx.abortTaken) return false;
  ctx.abortTaken = true;
  return true;
}

function queuedCall(command: string, args: Record<string, unknown>, timeoutMs: number, ctx?: RunCtx): Promise<Envelope> {
  lastActivity = Date.now();
  if (ctx && takeAbort(ctx)) return Promise.reject(new BridgeError(`'${command}' interrupted by the client`));
  queueDepth++;
  const queuedAt = Date.now();
  const job = queueTail.then(async () => {
    const t0 = Date.now();
    try {
      // Same bound as client.lock on the direct path: do not pile up behind a call the game never answers.
      if (t0 - queuedAt > QUEUE_WAIT_MS) throw new BridgeError(`bridge busy: '${command}' waited ${Math.round((t0 - queuedAt) / 1000)}s behind other calls (game thread not answering?)`);
      return await directCallEnvelope(command, args, timeoutMs, { pollMs: DAEMON_POLL_MS, aborted: ctx ? () => takeAbort(ctx) : undefined });
    } finally {
      queueDepth--;
      stats.calls++;
      stats.lastCallMs = Date.now() - t0;
      stats.callMsTotal += stats.lastCallMs;
      lastActivity = Date.now();
    }
  });
  queueTail = job.catch(() => undefined);
  return job;
}

function interrupt(ctx: RunCtx, why: string) {
  if (ctx.done || ctx.aborted) return;
  ctx.aborted = true;
  stats.interrupts++;
  console.error(`${new Date().toISOString()} interrupt run '${ctx.argv.join(" ")}': ${why}`);
  if (RESUMES_TIME.has(ctx.cmd)) queuedCall("game.pause", {}, 10_000).catch((e) => console.error(`pause after interrupt failed: ${errText(e)}`));
}

/** A response that sends a blank line every KEEPALIVE_MS, then the JSON result; onCancel when the client goes away. */
function streamed(work: () => Promise<unknown>, onCancel?: () => void): Response {
  let timer: ReturnType<typeof setInterval> | undefined;
  const enc = new TextEncoder();
  const stream = new ReadableStream({
    start(controller) {
      controller.enqueue(enc.encode("\n")); // first byte at once: the client treats silence as a stuck daemon
      timer = setInterval(() => {
        try {
          controller.enqueue(enc.encode("\n"));
        } catch {}
      }, KEEPALIVE_MS);
      work()
        .catch((e) => ({ thrown: errText(e) }))
        .then((v) => {
          clearInterval(timer);
          try {
            controller.enqueue(enc.encode(JSON.stringify(v) + "\n"));
            controller.close();
          } catch {}
        });
    },
    cancel() {
      clearInterval(timer);
      onCancel?.();
    },
  });
  return new Response(stream, { headers: { "content-type": "application/x-ndjson" } });
}

const avg = (total: number, n: number) => (n ? Math.round((total / n) * 10) / 10 : null);

export async function runDaemon(opts: { srcExe: string; runCli: RunCli; commandOf: (argv: string[]) => string | undefined }) {
  mkdirSync(runtimeDir(), { recursive: true });
  const other = readDaemonInfo();
  if (other && other.pid !== process.pid && (await daemonStatus(other, 1000))) {
    console.error(`${new Date().toISOString()} another daemon (pid ${other.pid}) answers; exiting`);
    process.exit(0);
  }
  setTransport((command, args, timeoutMs) => queuedCall(command, args, timeoutMs, runCtx.getStore()));
  const unthrottled = disablePowerThrottling();
  const token = crypto.randomUUID().replaceAll("-", "");
  const started = Date.now();
  const exeMtimeAtStart = exeMtime(opts.srcExe);

  let port = 0;
  const status = (): Record<string, unknown> => ({
    ok: true,
    pid: process.pid,
    port,
    exe: process.execPath,
    srcExe: opts.srcExe,
    exeMtime: exeMtimeAtStart,
    started: new Date(started).toISOString(),
    uptimeSec: Math.round((Date.now() - started) / 1000),
    idleSec: Math.round((Date.now() - lastActivity) / 1000),
    idleMs: Date.now() - lastActivity,
    callsServed: stats.calls,
    meanCallMs: avg(stats.callMsTotal, stats.calls),
    lastCallMs: stats.calls ? stats.lastCallMs : null,
    runsServed: stats.runs,
    meanRunMs: avg(stats.runMsTotal, stats.runs),
    lastRunMs: stats.runs ? stats.lastRunMs : null,
    rejected: stats.rejected,
    interrupts: stats.interrupts,
    queueDepth,
    activeRuns: active.size,
    unthrottled,
    busy: longRun ? { argv: longRun.argv, sinceSec: Math.round((Date.now() - longRun.started) / 1000) } : null,
  });

  let exiting = false;
  const exit = (why: string) => {
    if (exiting) return;
    exiting = true;
    console.error(`${new Date().toISOString()} daemon exit: ${why}`);
    try {
      if (JSON.parse(readFileSync(infoFile(), "utf8")).pid === process.pid) rmSync(infoFile(), { force: true });
    } catch {}
    setTimeout(() => process.exit(0), 30);
  };

  async function run(body: any): Promise<unknown> {
    const argv: string[] = Array.isArray(body.argv) ? body.argv.map(String) : [];
    const cmd = opts.commandOf(argv) ?? "";
    const long = LONG_COMMANDS.has(cmd);
    if (long && longRun) {
      stats.rejected++;
      return { thrown: `daemon busy: '${longRun.argv.join(" ")}' has been driving the game for ${Math.round((Date.now() - longRun.started) / 1000)}s; one long command at a time (wait, or Ctrl-C it)` };
    }
    const ctx: RunCtx = { id: String(body.runId ?? crypto.randomUUID()), argv, cmd, long, started: Date.now(), aborted: false, abortTaken: false, done: false };
    if (long) longRun = ctx;
    active.add(ctx);
    lastActivity = Date.now();
    const lines: string[] = [];
    try {
      const code = await runCtx.run(ctx, () => opts.runCli(argv, { out: (s) => lines.push(s), stdin: body.stdin }));
      return { code, output: lines.length ? lines.join("\n") + "\n" : "" };
    } finally {
      ctx.done = true;
      active.delete(ctx);
      if (longRun === ctx) longRun = null;
      stats.runs++;
      stats.lastRunMs = Date.now() - ctx.started;
      stats.runMsTotal += stats.lastRunMs;
      lastActivity = Date.now();
    }
  }

  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    idleTimeout: 255,
    async fetch(req, srv): Promise<Response> {
      if (req.headers.get("x-fp2-token") !== token) return new Response("forbidden", { status: 403 });
      const path = new URL(req.url).pathname;
      if (path === "/status") return Response.json(status());
      const body: any = req.method === "POST" ? await req.json().catch(() => ({})) : {};
      srv.timeout(req, 0);
      switch (path) {
        case "/call":
          return streamed(async () => ({ envelope: await queuedCall(String(body.command), body.args ?? {}, Number(body.timeoutMs ?? 30_000)) }));
        case "/run": {
          const ctxId = String(body.runId ?? "");
          return streamed(
            () => run(body),
            () => {
              for (const c of active) if (c.id === ctxId) interrupt(c, "client disconnected");
            },
          );
        }
        case "/interrupt": {
          const hit = [...active].filter((c) => !body.runId || c.id === body.runId);
          for (const c of hit) interrupt(c, "client interrupt");
          return Response.json({ ok: true, interrupted: hit.map((c) => c.argv.join(" ")) });
        }
        case "/stop":
          if ((active.size || queueDepth) && !body.force) {
            const what = longRun ? `'${longRun.argv.join(" ")}'` : `${active.size} run(s), ${queueDepth} queued call(s)`;
            return Response.json({ ok: false, error: `busy with ${what}; pass --force to stop anyway (the game may be left running)` });
          }
          exit("stop requested");
          return Response.json({ ok: true, pid: process.pid });
        default:
          return new Response("not found", { status: 404 });
      }
    },
  });

  port = Number(server.port);
  const info: DaemonInfo = { pid: process.pid, port, token, srcExe: opts.srcExe, exeMtime: exeMtimeAtStart, exe: process.execPath, started };
  writeFileSync(infoFile() + ".tmp", JSON.stringify(info));
  renameSync(infoFile() + ".tmp", infoFile());
  console.error(`${new Date().toISOString()} daemon pid ${process.pid} on 127.0.0.1:${server.port} (src ${opts.srcExe})`);

  // Housekeeping: leave when idle for IDLE_EXIT_MS, when fp2.exe is gone (twice in a row: a build replaces it),
  // or when daemon.json names another daemon. Never in the middle of a run.
  let srcMissing = 0;
  setInterval(() => {
    if (active.size || queueDepth) return;
    srcMissing = existsSync(opts.srcExe) ? 0 : srcMissing + 1;
    if (srcMissing >= 2) return exit(`${opts.srcExe} is gone`);
    if (Date.now() - lastActivity > IDLE_EXIT_MS) return exit(`idle for ${IDLE_EXIT_MS / 3600_000} h`);
    try {
      const rec = JSON.parse(readFileSync(infoFile(), "utf8"));
      if (rec.pid !== process.pid) return exit(`superseded by pid ${rec.pid}`);
    } catch {
      return exit("daemon.json removed");
    }
  }, 60_000);
  await new Promise(() => {});
}
