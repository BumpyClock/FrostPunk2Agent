// File-based client for the FP2AgentBridge UE4SS mod.
// Protocol: write request.json (atomic rename), mod deletes it, writes response.json.
import { existsSync, mkdirSync, openSync, closeSync, readFileSync, renameSync, rmSync, statSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { dirname, join, resolve } from "node:path";

export class BridgeError extends Error {}

const HEARTBEAT_STALE_SECONDS = 5;
const STALE_LOCK_SECONDS = 120;

/** Repo root: FP2_ROOT, else the first ancestor of the exe/cwd/source that contains mod/FP2AgentBridge. */
export function repoRoot(): string {
  if (process.env.FP2_ROOT) return resolve(process.env.FP2_ROOT);
  const starts = [dirname(process.execPath), process.cwd(), import.meta.dir];
  for (const start of starts) {
    let dir = resolve(start);
    for (let i = 0; i < 8; i++) {
      if (existsSync(join(dir, "mod", "FP2AgentBridge", "Scripts", "main.lua"))) return dir;
      const up = dirname(dir);
      if (up === dir) break;
      dir = up;
    }
  }
  throw new BridgeError("cannot find repo root (mod/FP2AgentBridge); set FP2_ROOT");
}

export function bridgeDir(): string {
  return process.env.FP2_BRIDGE_DIR ? resolve(process.env.FP2_BRIDGE_DIR) : join(repoRoot(), "mod", "FP2AgentBridge", "bridge");
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export type Status = {
  alive: boolean;
  reason?: string;
  ageSeconds?: number;
  started?: number;
  busy?: boolean;
  handled?: number;
  [k: string]: unknown;
};

export async function readStatus(): Promise<Status> {
  const path = join(bridgeDir(), "status.json");
  // The mod replaces status.json every second (remove + rename): retry briefly.
  for (let i = 0; i < 20; i++) {
    try {
      const st = JSON.parse(readFileSync(path, "utf8")) as Status;
      const age = Date.now() / 1000 - Number(st.time ?? 0);
      st.ageSeconds = Math.round(age * 10) / 10;
      st.alive = age < HEARTBEAT_STALE_SECONDS;
      if (!st.alive) st.reason = "heartbeat stale; game closed, hung, or mod unloaded";
      return st;
    } catch {
      await sleep(50);
    }
  }
  return { alive: false, reason: "no readable status.json; game not running with the mod, or mod failed to load" };
}

export function pidAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (e: any) {
    return e?.code === "EPERM";
  }
}

async function withLock<T>(fn: () => Promise<T>): Promise<T> {
  const dir = bridgeDir();
  mkdirSync(dir, { recursive: true });
  const lock = join(dir, "client.lock");
  const deadline = Date.now() + 60_000;
  for (;;) {
    try {
      const fd = openSync(lock, "wx");
      writeFileSync(fd, String(process.pid));
      closeSync(fd);
      break;
    } catch {
      try {
        // A force-killed client (e.g. watch-stop) leaves its lock behind: clear it when the owner is gone.
        const owner = Number(readFileSync(lock, "utf8").trim());
        if (owner && !pidAlive(owner)) rmSync(lock, { force: true });
        else if (Date.now() - statSync(lock).mtimeMs > STALE_LOCK_SECONDS * 1000) rmSync(lock, { force: true });
      } catch {}
      if (Date.now() > deadline) throw new BridgeError(`another client holds ${lock}`);
      await sleep(50);
    }
  }
  try {
    return await fn();
  } finally {
    rmSync(lock, { force: true });
  }
}

// Game-thread calls during a level load crashed the game natively in Wwise (measured: recover polling
// wait-ready during a load crashed 4 times on 2 saves; the same load with no bridge calls for 90 s succeeded).
// A successful `load` writes .runtime/load-quiet-until; every client (this process, turn, the detached watcher)
// waits until then before its next game-thread call, watching only the heartbeat.
export const LOAD_QUIET_MS = Number(process.env.FP2_LOAD_QUIET_SECONDS ?? 90) * 1000;
const quietFile = () => join(repoRoot(), ".runtime", "load-quiet-until");

export function markLoadQuiet(ms = LOAD_QUIET_MS) {
  mkdirSync(join(repoRoot(), ".runtime"), { recursive: true });
  writeFileSync(quietFile(), String(Date.now() + ms));
}

/** Milliseconds left in the post-load quiet period (0 when none). */
export function loadQuietLeftMs(): number {
  try {
    return Math.max(0, Number(readFileSync(quietFile(), "utf8").trim()) - Date.now() || 0);
  } catch {
    return 0;
  }
}

async function waitLoadQuiet() {
  for (let left = loadQuietLeftMs(); left > 0; left = loadQuietLeftMs()) {
    const st = await readStatus();
    if (!st.alive) throw new BridgeError(`bridge not alive during the post-load quiet period: ${st.reason}`);
    await sleep(Math.min(left, 2000));
  }
}

export type Envelope = { id?: string; ok: boolean; result?: unknown; error?: string; elapsedMs?: number };

/** How a bridge call reaches the game: the file bridge in this process (default) or the fp2 daemon (daemon.ts). */
export type Transport = (command: string, args: Record<string, unknown>, timeoutMs: number) => Promise<Envelope>;
let transport: Transport | null = null;
export function setTransport(t: Transport | null) {
  transport = t;
}

export async function callEnvelope(command: string, args: Record<string, unknown> = {}, timeoutMs = 30_000): Promise<Envelope> {
  return transport ? transport(command, args, timeoutMs) : directCallEnvelope(command, args, timeoutMs);
}

/**
 * One exchange over the file bridge. `client.lock` serializes processes; the daemon also takes it, so a
 * --no-daemon client or an older watcher stays safe next to it. `aborted` (daemon only) is polled while waiting.
 */
export async function directCallEnvelope(
  command: string,
  args: Record<string, unknown> = {},
  timeoutMs = 30_000,
  opts: { pollMs?: number; aborted?: () => boolean } = {},
): Promise<Envelope> {
  const interrupted = () => new BridgeError(`'${command}' interrupted by the client`);
  await waitLoadQuiet();
  if (opts.aborted?.()) throw interrupted();
  const st = await readStatus();
  if (!st.alive) throw new BridgeError(`bridge not alive: ${st.reason}`);
  const dir = bridgeDir();
  const req = join(dir, "request.json");
  const resp = join(dir, "response.json");
  const id = crypto.randomUUID().slice(0, 12);
  return withLock(async () => {
    rmSync(resp, { force: true });
    const waker = responseWaker(dir);
    try {
      writeFileSync(req + ".tmp", JSON.stringify({ id, command, args }));
      renameSync(req + ".tmp", req);
      const deadline = Date.now() + timeoutMs;
      while (Date.now() < deadline) {
        if (opts.aborted?.()) {
          rmSync(req, { force: true });
          throw interrupted();
        }
        if (existsSync(resp)) {
          try {
            const env = JSON.parse(readFileSync(resp, "utf8")) as Envelope;
            if (env.id === id || env.id == null) {
              rmSync(resp, { force: true });
              if (command === "load" && env.ok) markLoadQuiet();
              return env;
            }
          } catch {}
        }
        await waker.sleep(opts.pollMs ?? 15);
      }
      rmSync(req, { force: true });
      throw new BridgeError(`timeout after ${timeoutMs / 1000}s waiting for '${command}' (game thread busy or loading?)`);
    } finally {
      waker.close();
    }
  });
}

/**
 * Wakes the response poll as soon as the mod writes response.json. Windows timers tick every ~15.6 ms, so a
 * 15 ms poll slept about 20 ms per round (measured); the poll remains as a fallback.
 */
function responseWaker(dir: string) {
  let wake: (() => void) | null = null;
  let watcher: FSWatcher | null = null;
  try {
    watcher = watch(dir, (_event, name) => {
      if (!name || String(name).startsWith("response")) wake?.();
    });
  } catch {}
  return {
    sleep: (ms: number) =>
      new Promise<void>((resolve) => {
        const done = () => {
          clearTimeout(timer);
          wake = null;
          resolve();
        };
        const timer = setTimeout(done, ms);
        wake = done;
      }),
    close: () => watcher?.close(),
  };
}

export async function call<T = any>(command: string, args: Record<string, unknown> = {}, timeoutMs?: number): Promise<T> {
  const env = await callEnvelope(command, args, timeoutMs);
  if (!env.ok) throw new BridgeError(String(env.error));
  return env.result as T;
}
