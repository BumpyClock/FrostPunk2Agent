#!/usr/bin/env bun
// fp2: single CLI for playing Frostpunk 2 through the FP2AgentBridge mod.
import { readFileSync } from "node:fs";
import { BridgeError, bridgeDir, call, callEnvelope, loadQuietLeftMs, readStatus, setTransport } from "./bridge";
import { compiled, daemonStatus, ensureDaemon, isManager, readDaemonInfo, routedTransport, runDaemon, runRemote, stopDaemon, type RunIO } from "./daemon";
import { focusGame, sendKeys } from "./win32";
import { brief } from "./brief";
import { screenshot } from "./capture";
import { click, drag, move, scroll } from "./mouse";
import { watch } from "./watch";
import { join } from "node:path";
import { repoRoot } from "./bridge";
import { cutsceneReason, overdriveCycle, setPaused, setSpeed, sleep, time, userPaused, waitFor, waitReady } from "./game";
import { addGoal, goalView, loadGoals, removeGoal, updateGoal } from "./goals";
import { STOP_DEFAULT, turn } from "./turn";
import { RECOVER_MAX_ATTEMPTS, assertShadersCompiled, launchAndWaitShaders, recover, resolveSaveName, unstick } from "./recover";
import { isBadSave, listSaves, SAVE_DIR } from "./saves";

// Named crop regions as fractions of the client area (calibrated on a 21:9 maximized window).
const REGIONS: Record<string, number[]> = {
  hud: [0, 0, 1, 0.075],
  objectives: [0, 0.07, 0.32, 0.72],
  bottom: [0, 0.86, 1, 1],
  center: [0.25, 0.2, 0.75, 0.8],
};

const HELP = `fp2 <subcommand> [key=value ...] [--compact] [--fields a.b,c[0].d] [--timeout S] [--args-file F|-] [--no-daemon]

Play loop:
  recover [name=X] [attempts=3]
                         relaunch if the bridge is dead, load X or the newest agent-rolling-*, agent-*, AutoSave*
                         save from the main menu, wait until ready, pause; in a loaded game, load X in place (else only pause). A load
                         that crashes the game marks the save bad (.runtime/bad-saves.json) and tries the next one
  turn [weeks=4] [stopOn=kind,..] [speed=3] [saveEvery=2] [saveName=agent-rolling] [autoAck=true]
                         resume, run until a stop event or weeks pass, pause; returns {turn, events, dropped,
                         goals, brief, weather}. Never runs past the nearest open goal's due week (stoppedBy
                         goalDue). In a cold crisis (whiteout, temperature level >= 3) the default length is 1
                         week; an explicit weeks= is kept. Saves rotate over <saveName>-a/-b/-c.
                         Events also append to .runtime/watch.jsonl. Default stopOn: ${STOP_DEFAULT.join(",")}
  goals                  the stack: focus (top goal), open (ordered by priority, then threat/check/short/long,
                         then due), due ones, every open threat with weeksLeft; all=true includes done.
                         File .runtime/goals.jsonl, one JSON per line
  goals add text=".." [horizon=long|short|check|threat] [due=<week>] [expect=".."] [priority=<1..>]
                         threat = a warned danger (whiteout, storm, unrest): due=<arrival week>, expect and
                         priority are required (decide what it outranks and what it defers)
  goals done id=N [note=".."] | goals edit id=N [text=..] [due=..] [expect=..] [horizon=..] [priority=..] | goals rm id=N
  wait-for cond=<c> [timeout=20]
                         c: modal | no-modal | council | no-council | cutscene | no-cutscene | paused | running |
                         ready | reason:<substr> | no-reason:<substr>. click/hold/keys accept wait=<c>.

Local subcommands:
  status                 heartbeat (no game-thread round trip); loadQuietSeconds > 0 means a load was issued and
                         every client holds game-thread calls until it ends (they crashed the game mid-load)
  launch                 kill leftover CrashReportClient, start the game via Steam, wait for the bridge and for
                         startup shader compilation (BP_ShaderCompilerActor_C gone); load refuses while it runs
                         (--force overrides): a load mid-compile leaves "COMPILING SHADERS N/743" stuck
  unstick [dryRun=true]  clear a stuck "COMPILING SHADERS N/743" overlay: acts only when in a level with no
                         BP_ShaderCompilerActor_C, the overlay shown (opacity > 0) and its counter frozen for 10 s;
                         then OnShaderCompilationFinished, wait 13 s, Space. Prints the evidence; {stuck:false}
                         otherwise. recover and its ready check run it on their own
  pass-law policy=<id>   Council through its own UI handlers: open, laws, law, select, vote, dismiss, verify (needs an open session)
  council-open           open the Council (key C), skip its intro cutscene, return council state
  new-game               from the main menu: Utopia Builder, Windswept Peaks, 3 communities, intro skipped, paused
  saves [limit=20]       save files on disk, newest first (load with: fp2 load name=<name>; save: fp2 save name=<new>)
  snapshot               everything the HUD shows, one call (bridge command)
  watch [interval=2] [pauseOn=critical|kind,..]
                         stream one JSON line per meaningful change (dialogs, construction/research done,
                         deficits, stat bands, stock runway, quest progress, map icons, council phase)
  utopia-assign node=X   spend a Utopia Tree point (opens/closes the panel; fp2 utopia lists nodes)
  watch-start [pauseOn=..] [saveEvery=2] [saveName=agent-rolling] / watch-stop
                         detached watcher appending to .runtime/watch.jsonl (tail it from a Monitor);
                         saves every saveEvery in-game weeks (0 = off), rotating <saveName>-a/-b/-c;
                         autoAck=true (default) dismisses one-option "I see" dialogs, emitting dialog.acknowledged
  brief                  triaged digest: deficits, depleting stocks, rising stats, pause/modal state
  pause | resume         pause/unpause game time (verified via the mod)
  speed <1|2|3>          set game speed via the bridge (game.speed)
  overdrive-cycle [weeks=1] [maxWear=0.5] [minWear=0.05]  duty-cycle generator overdrive under a wear ceiling (cold snaps)
  advance [ticks=N]      resume, wait until game time advances N ticks (default 24000), pause, print brief;
                         stops early when a modal/event pauses the game
  wait-ready             block until a city is loaded and gameplay began (after load/new game)
  keys <chord...>       send keys to the game window, e.g. keys space | keys ctrl+r  (--keep-focus or keepFocus=true)
  screenshot [region=hud|objectives|bottom|center|x0,y0,x1,y1] [scale=0.5] [out=path]
                         capture the game client area to PNG (pixels or 0..1 fractions); prints the path
  click x,y [--double]   (refused while a cutscene plays unless --force) left-click at client pixel (or 0..1 fraction) coordinates from a scale=1 screenshot
  rclick x,y             right-click
  hold x,y [ms=1500]     press-and-hold (FP2 confirm buttons need a hold)
  move x,y | drag x,y x2,y2 | scroll x,y <ticks>   (scroll: + up / - down)
  focus [--max]          bring the game window to the foreground (needed before screenshots); --max maximizes
  reload [--full]        re-require Lua modules in place (no keys); --full = UE4SS Ctrl+R reload (main.lua changes);
                         a Lua error returns the failing file's lines as context

Daemon (default transport; FP2_NO_DAEMON=1 or --no-daemon uses the file bridge directly):
  daemon status | start | stop [--force]
                         fp2 starts a background daemon (.runtime/fp2-daemon.exe, a copy of fp2.exe) on first use
                         and sends each command to it; it is the only process on the file bridge and serializes all
                         calls (watcher included). A newer fp2.exe restarts it when idle; it exits after 6 h idle.
                         One long command (turn, advance, overdrive-cycle, wait-for, wait-ready) at a time; Ctrl-C
                         stops it (turn, advance, overdrive-cycle also pause the game). status: pid, port, uptime,
                         calls served, call latency

Bridge subcommands (run inside the game; 'fp2 help' lists them):
  state, extract name=X, world, find_all, classes, modules, search, describe, object, get,
  components, call, set, ping, help

Values parse as JSON when valid, else strings. Dotted keys nest: a.b=1 -> {"a":{"b":1}}.
--fields prints only the given paths: one path prints the value, several print {path: value}.`;

function parseValue(text: string): unknown {
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

type Parsed = { positional: string[]; args: Record<string, any>; flags: Record<string, string | boolean> };

function parse(argv: string[]): Parsed {
  const positional: string[] = [];
  const args: Record<string, any> = {};
  const flags: Record<string, string | boolean> = {};
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a.startsWith("--")) {
      const name = a.slice(2);
      if (["timeout", "args-file", "fields"].includes(name)) flags[name] = argv[++i];
      else flags[name] = true;
    } else if (a.includes("=")) {
      const eq = a.indexOf("=");
      const parts = a.slice(0, eq).split(".");
      let node = args;
      for (const p of parts.slice(0, -1)) node = node[p] ??= {};
      node[parts.at(-1)!] = parseValue(a.slice(eq + 1));
    } else positional.push(a);
  }
  return { positional, args, flags };
}

/** Resolve a dotted path like `cities[0].stock.Core_FoodResource` against a value. */
// Path segments: names, [N] indices, and `*` to map the rest of the path over an array.
function pick(v: unknown, path: string): unknown {
  const parts = path.match(/[^.[\]]+/g) ?? [];
  let node: any = v;
  for (let i = 0; i < parts.length; i++) {
    if (node == null) return undefined;
    if (parts[i] === "*") {
      if (!Array.isArray(node)) return undefined;
      const rest = parts.slice(i + 1).join(".");
      return rest ? node.map((el) => pick(el, rest)) : node;
    }
    node = node[parts[i]];
  }
  return node;
}

function project(v: unknown, paths: string[]): unknown {
  // `*.a,*.b` on an array yields [{a, b}, ...]: one row per element.
  if (Array.isArray(v) && paths.every((f) => f.startsWith("*."))) {
    return v.map((el) => Object.fromEntries(paths.map((f) => [f.slice(2), pick(el, f.slice(2))])));
  }
  return paths.length === 1 ? pick(v, paths[0]) : Object.fromEntries(paths.map((f) => [f, pick(v, f)]));
}

async function advance(ticks: number, timeoutMs: number) {
  const start = await time();
  if (userPaused(start)) await setPaused(false);
  const from = start.gameTimeTicks ?? 0;
  const deadline = Date.now() + timeoutMs;
  let t = start;
  let stoppedBy: string | null = null;
  while (Date.now() < deadline) {
    await sleep(500);
    t = await time();
    if ((t.gameTimeTicks ?? 0) - from >= ticks) break;
    if (t.paused) {
      // Saving pauses the game for a moment (watcher rolling save); keep waiting through it.
      const reasons = (t.pauseReasons ?? []).filter((r: string) => r !== "SavingGame");
      if ((t.pauseReasons ?? []).length > 0 && reasons.length === 0) continue;
      stoppedBy = reasons.join(", ") || "paused";
      break;
    }
  }
  if (!userPaused(t)) t = await setPaused(true);
  return { advancedTicks: (t.gameTimeTicks ?? 0) - from, stoppedBy, brief: await brief() };
}

// Clear intro/story dialogs (resolved through the game via `choose`) and skip cutscenes
// (hold E; Space would toggle pause). Stops once only UserPaused remains.
async function settleIntro(maxSteps = 12) {
  for (let i = 0; i < maxSteps; i++) {
    await sleep(1500);
    const t = await time();
    const reasons = (t.pauseReasons ?? []).filter((r) => r !== "UserPaused");
    if (!reasons.length) return;
    if (reasons.some((r) => /Cutscene/i.test(r))) {
      await sendKeys(["e@3000"], true); // cutscene first: choices are blocked while it plays
      continue;
    }
    const modals = await call<any[]>("modals").catch(() => []);
    if (Array.isArray(modals) && modals.length) await call("choose", { index: 0 });
  }
}

// Skip any running cutscene (hold E) until its pause reason clears.
async function skipCutscenes(maxTries = 6) {
  let t = await time();
  for (let i = 0; i < maxTries && cutsceneReason(t); i++) {
    await sendKeys(["e@3000"], true);
    await sleep(1500);
    t = await time();
  }
  if (cutsceneReason(t)) throw new BridgeError(`cutscene still active: ${cutsceneReason(t)}`);
  return t;
}

// Open the Council (House of Delegates, key C), skip its intro cutscene, and only then hand
// control back. Measured: clicking Council UI while the intro cutscene was active left it unresponsive.
// C toggles the Council: the old loop pressed it again after 4 s while the chamber was still opening, which could
// close it (inferred; council-open failed twice where one `keys c` opened it, measured). Press once, then wait.
async function councilOpen() {
  for (let attempt = 0; attempt < 2; attempt++) {
    if ((await call<any>("council")).inParliament) break;
    await sendKeys(["c"], true);
    for (let i = 0; i < 15; i++) {
      await sleep(1000);
      if ((await call<any>("council")).inParliament) break;
    }
  }
  const c = await call<any>("council");
  if (!c.inParliament) throw new BridgeError("Council did not open (is the Council Hall built?)");
  await skipCutscenes();
  await sleep(1500);
  return { ...(await call<any>("council")), pauseReasons: (await time()).pauseReasons };
}

// A Lua load error names the file and line; attach the surrounding lines so the fix needs no second read.
function luaErrorContext(message: string): { file: string; line: number; context: string[] } | undefined {
  const m = message.match(/([\w-]+\.lua):(\d+):/);
  if (!m) return undefined;
  const path = join(repoRoot(), "mod", "FP2AgentBridge", "Scripts", m[1]);
  try {
    const lines = readFileSync(path, "utf8").split(/\r?\n/);
    const n = Number(m[2]);
    const from = Math.max(1, n - 3);
    const to = Math.min(lines.length, n + 3);
    const context: string[] = [];
    for (let i = from; i <= to; i++) context.push(`${i === n ? ">" : " "}${i}: ${lines[i - 1]}`);
    return { file: m[1], line: n, context };
  } catch {
    return undefined;
  }
}

async function reload(full: boolean) {
  if (!full) {
    // Keyless: re-require all Lua modules except main.lua inside the running VM.
    try {
      return await call("bridge.reload");
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      const ctx = luaErrorContext(msg);
      if (!ctx) throw e;
      throw new BridgeError(`${msg}\n${ctx.file}:${ctx.line}\n${ctx.context.join("\n")}`);
    }
  }
  // Full UE4SS reload (needed only for main.lua changes). Ctrl+R also hits the game's R = Research
  // hotkey, so close the Idea Tree it opens.
  const before = (await readStatus()).started;
  await sendKeys(["ctrl+r"]);
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    const st = await readStatus();
    if (st.alive && st.started !== before) {
      await sleep(1000);
      const t = await time().catch(() => undefined);
      if (t && (t.pauseReasons ?? []).some((r) => /IdeaTree/i.test(r))) await sendKeys(["escape"], true);
      return { reloaded: true, full: true, started: st.started };
    }
  }
  throw new BridgeError("no reload observed within 15s; check ue4ss/UE4SS.log");
}

/** One CLI command. Output goes through io.out, so the daemon can run commands for clients (see daemon.ts). */
async function runCommand(argv: string[], io: RunIO): Promise<number> {
  const { positional, args, flags } = parse(argv);
  const compact = Boolean(flags.compact);
  const fields = String(flags.fields ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const print = (v: unknown) => {
    if (fields.length) v = project(v, fields);
    io.out(compact ? JSON.stringify(v) : JSON.stringify(v, null, 2));
  };
  const timeoutMs = flags.timeout ? Number(flags.timeout) * 1000 : 30_000;
  const [cmd, ...rest] = positional;
  if (!cmd || cmd === "-h" || flags.help) {
    io.out(HELP);
    return 0;
  }
  if (flags["args-file"]) {
    const f = String(flags["args-file"]);
    Object.assign(args, JSON.parse(f === "-" ? (io.stdin ?? (await Bun.stdin.text())) : readFileSync(f, "utf8")));
  }
  switch (cmd) {
    case "status":
      print({ ...(await readStatus()), bridgeDir: bridgeDir(), loadQuietSeconds: Math.round(loadQuietLeftMs() / 1000) });
      return 0;
    case "brief":
      print(await brief());
      return 0;
    case "pause":
      print(await setPaused(true));
      return 0;
    case "resume":
      print(await setPaused(false));
      return 0;
    case "speed": {
      const n = rest[0] ?? String(args.level ?? "");
      await setSpeed(Number(n));
      print(await time());
      return 0;
    }
    case "overdrive-cycle":
      // Cold snap helper: duty-cycle generator overdrive under a wear ceiling.
      print(await overdriveCycle({ weeks: Number(args.weeks ?? 1), maxWear: Number(args.maxWear ?? 0.5), minWear: Number(args.minWear ?? 0.05) }));
      return 0;
    case "advance":
      print(await advance(Number(args.ticks ?? 24000), flags.timeout ? timeoutMs : 600_000));
      return 0;
    case "turn": {
      const stopOn = new Set(args.stopOn ? String(args.stopOn).split(",").map((s: string) => s.trim()).filter(Boolean) : STOP_DEFAULT);
      print(
        await turn({
          weeks: Number(args.weeks ?? 4),
          weeksDefaulted: args.weeks === undefined,
          stopOn,
          speed: args.speed === undefined ? 3 : Number(args.speed),
          saveEveryWeeks: Number(args.saveEvery ?? 2),
          saveName: String(args.saveName ?? "agent-rolling"),
          autoAck: String(args.autoAck ?? "true") === "true",
          intervalMs: Number(args.interval ?? 1.5) * 1000,
          timeoutMs: flags.timeout ? timeoutMs : 600_000,
        }),
      );
      return 0;
    }
    case "goals": {
      const sub = rest[0] ?? "list";
      const id = Number(args.id);
      switch (sub) {
        case "list": {
          const d = await call<any>("date").catch(() => ({}));
          const view = { week: d.week, ...goalView(d.week) };
          print(args.all === true ? { ...view, all: loadGoals().goals } : view);
          return 0;
        }
        case "add": {
          const d = await call<any>("date").catch(() => ({}));
          print(addGoal({ text: String(args.text ?? ""), horizon: args.horizon, due: args.due === undefined ? undefined : Number(args.due), expect: args.expect, priority: args.priority === undefined ? undefined : Number(args.priority) }, { week: d.week, date: d.date }));
          return 0;
        }
        case "done": {
          const d = await call<any>("date").catch(() => ({}));
          print(updateGoal(id, { done: true, doneWeek: d.week, ...(args.note ? { note: String(args.note) } : {}) }));
          return 0;
        }
        case "edit": {
          const patch: Record<string, unknown> = {};
          for (const k of ["text", "horizon", "expect", "note"]) if (args[k] !== undefined) patch[k] = String(args[k]);
          if (args.due !== undefined) patch.due = Number(args.due);
          if (args.priority !== undefined) patch.priority = Number(args.priority);
          if (args.done !== undefined) patch.done = args.done === true;
          print(updateGoal(id, patch));
          return 0;
        }
        case "rm":
          print(removeGoal(id));
          return 0;
        default:
          throw new BridgeError("goals [list|add|done|edit|rm]");
      }
    }
    case "recover":
      print(await recover(args.name === undefined ? undefined : String(args.name), flags.timeout ? timeoutMs : 240_000, Number(args.attempts ?? RECOVER_MAX_ATTEMPTS)));
      return 0;
    case "wait-for":
      print(await waitFor(String(args.cond ?? rest[0] ?? ""), Number(args.timeout ?? 20) * 1000));
      return 0;
    case "wait-ready":
      // Until the bridge is alive, gameplay has begun and a city exists (after load / new game).
      print({ ready: true, ...(await waitReady(flags.timeout ? timeoutMs : 180_000)) });
      return 0;
    case "screenshot": {
      const name = new Date().toISOString().replace(/[:.]/g, "-");
      let region = args.region;
      if (typeof region === "string") region = REGIONS[region] ?? region.split(",").map(Number);
      print(await screenshot({ out: String(args.out ?? join(repoRoot(), ".runtime", "shots", `${name}.png`)), region, scale: args.scale }));
      return 0;
    }
    case "watch": {
      // One JSON line per meaningful change; run under a Monitor tool. pauseOn: "critical" or comma list of event kinds.
      const pauseOn = new Set(String(args.pauseOn ?? "").split(",").filter(Boolean));
      const saveEvery = Number(args.saveEvery ?? 0);
      await watch({ intervalMs: Number(args.interval ?? 2) * 1000, pauseOn, once: Boolean(flags.once), saveEveryWeeks: saveEvery > 0 ? saveEvery : undefined, saveName: args.saveName ? String(args.saveName) : undefined, autoAck: String(args.autoAck ?? "false") === "true", out: (l) => io.out(JSON.stringify(l)) });
      return 0;
    }
    case "watch-start": {
      // Detached watcher that outlives this process and any Monitor tool: runs a copy of the exe
      // (so `bun run build` can replace fp2.exe) and appends JSON lines to .runtime/watch.jsonl.
      const { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } = await import("node:fs");
      const rt = join(repoRoot(), ".runtime");
      mkdirSync(rt, { recursive: true });
      const pidFile = join(rt, "watch.pid");
      if (existsSync(pidFile)) {
        const old = readFileSync(pidFile, "utf8").trim();
        const alive = Bun.spawnSync(["tasklist", "/FI", `PID eq ${old}`]).stdout.toString().includes(old);
        if (alive) throw new BridgeError(`watcher already running (pid ${old}); fp2 watch-stop first`);
      }
      const exe = join(rt, "fp2-watch.exe");
      copyFileSync(process.execPath, exe);
      const log = join(rt, "watch.jsonl");
      const wargs = [`interval=${args.interval ?? 2}`, `pauseOn=${args.pauseOn ?? "dialog.opened,need.deficit,stock.runway,research.finished,research.idle,construction.finished"}`, `saveEvery=${args.saveEvery ?? 2}`, `saveName=${args.saveName ?? "agent-rolling"}`, `autoAck=${args.autoAck ?? "true"}`];
      const ps = `Start-Process -FilePath '${exe}' -ArgumentList ${["watch", ...wargs].map((a) => `'${a}'`).join(",")} -WorkingDirectory '${repoRoot()}' -RedirectStandardOutput '${log}' -RedirectStandardError '${log}.err' -WindowStyle Hidden -PassThru | ForEach-Object Id`;
      const res = Bun.spawnSync(["powershell", "-NoProfile", "-Command", ps]);
      const pid = res.stdout.toString().trim();
      if (!/^\d+$/.test(pid)) throw new BridgeError(`failed to start watcher: ${String(res.stderr ?? "")}`);
      writeFileSync(pidFile, pid);
      print({ started: true, pid: Number(pid), log, tail: `tail -n0 -F "${log.replaceAll("\\", "/")}"` });
      return 0;
    }
    case "watch-stop": {
      const { existsSync, readFileSync, rmSync } = await import("node:fs");
      const pidFile = join(repoRoot(), ".runtime", "watch.pid");
      if (!existsSync(pidFile)) {
        print({ stopped: false, reason: "no watch.pid" });
        return 0;
      }
      const pid = readFileSync(pidFile, "utf8").trim();
      Bun.spawnSync(["taskkill", "/PID", pid, "/F"]);
      rmSync(pidFile, { force: true });
      print({ stopped: true, pid: Number(pid) });
      return 0;
    }
    case "council-open":
      print(await councilOpen());
      return 0;
    case "utopia-assign": {
      // The game assigns Utopia points only through its panel: open it (U), assign via the bridge, close it.
      const node = String(args.node ?? "");
      if (!node) throw new BridgeError("utopia-assign needs node=<tag suffix or name> (see fp2 utopia)");
      let res = await call("utopia_assign", { node }).catch((e) => e as Error);
      let opened = false;
      if (res instanceof Error && /panel not open/.test(res.message)) {
        focusGame();
        sendKeys(["u"]);
        opened = true;
        await Bun.sleep(1500);
        res = await call("utopia_assign", { node }).catch((e) => e as Error);
      }
      if (opened) {
        sendKeys(["u"]);
        await Bun.sleep(500);
      }
      if (res instanceof Error) throw res;
      print(res);
      return 0;
    }
    case "pass-law": {
      // Council flow through the UI's own handlers: open -> laws -> law -> select (propose) -> vote -> dismiss result -> verify.
      const policy = String(args.policy ?? "");
      if (!policy) throw new BridgeError("policy required (see fp2 laws)");
      const c0 = await call<any>("council");
      const sessionOpen = c0.phase === 1 || (c0.minTicksToNextSession ?? 1) <= 0;
      if (!sessionOpen && !flags.force) throw new BridgeError(`no open Council session (phase ${c0.phase}, minTicksToNextSession ${c0.minTicksToNextSession}); wait for council.sessionAvailable.changed or pass --force`);
      // Resolve the policy before opening the Council, so a typo does not leave the chamber open.
      const laws = await call<any[]>("laws");
      const needle = policy.toLowerCase();
      const match = (Array.isArray(laws) ? laws : []).find((l) => [l.id, l.law, l.name].some((x) => typeof x === "string" && x.toLowerCase().includes(needle)));
      if (!match) throw new BridgeError(`no proposable law matching '${policy}' (see fp2 laws)`);
      // Leaving the Council clears the player pause; restore it if we started paused.
      const wasPaused = userPaused(await time());
      await councilOpen();
      // Drive the Council through its own widget handlers (council_ui steps) so the UI stays in sync; a bridge
      // `propose` while the hub lobby is visible desynced the UI and a later click crashed the game (measured).
      const ui = async (step: string, extra: Record<string, unknown> = {}) => call<any>("council_ui", { step, ...extra });
      await ui("laws");
      await sleep(1000);
      await ui("law", { policy: match.id ?? policy });
      await sleep(1000);
      const selected = await ui("select", { policy: match.id ?? policy });
      const proposed = { policy: selected?.after?.agendaPolicy ?? match.id ?? policy };
      await sleep(4000); // proposal transition (black frames)
      await skipCutscenes();
      const vote = await ui("vote");
      await sleep(6000); // vote animation -> result screen
      await sendKeys(["escape"], true); // IA_ExitResultScreen
      await sleep(3000);
      const c = await call<any>("council");
      if (c.inParliament) {
        await sendKeys(["escape"], true); // IA_ExitHOD
        await sleep(2000);
      }
      const after = await call<any>("council");
      if (wasPaused) await setPaused(true);
      print({ policy: proposed.policy, vote: vote?.after?.phase, active: (after.activePolicies ?? []).includes(proposed.policy), phase: after.phase, inParliament: after.inParliament, paused: wasPaused });
      return 0;
    }
    case "click":
    case "rclick":
    case "hold": {
      if (!flags.force) {
        const cs = await time().then(cutsceneReason).catch(() => undefined);
        if (cs) throw new BridgeError(`${cmd} blocked: cutscene active (${cs}); skip it (fp2 keys e@3000) or pass --force`);
      }
      const pt = String(rest[0] ?? "").split(",").map(Number);
      if (pt.length !== 2 || pt.some(Number.isNaN)) throw new BridgeError(`${cmd} needs x,y (pixels, or 0..1 fractions)`);
      const res: any = await click(pt, { right: cmd === "rclick", holdMs: cmd === "hold" ? Number(args.ms ?? 1500) : undefined, double: Boolean(flags.double) });
      if (args.wait) res.waited = await waitFor(String(args.wait), Number(args.timeout ?? 20) * 1000);
      print(res);
      return 0;
    }
    case "move":
      print(await move(String(rest[0]).split(",").map(Number)));
      return 0;
    case "drag":
      print(await drag(String(rest[0]).split(",").map(Number), String(rest[1]).split(",").map(Number)));
      return 0;
    case "scroll":
      print(await scroll(String(rest[0]).split(",").map(Number), Number(rest[1] ?? args.ticks ?? 1)));
      return 0;
    case "saves":
      // Disk listing (works without the game); newest first. `display` is the name `load` takes.
      print({ dir: SAVE_DIR, saves: listSaves().slice(0, Number(args.limit ?? 20)).map((s) => (isBadSave(s) ? { ...s, bad: true } : s)) });
      return 0;
    case "save": {
      // Saves made inside the Council scene did not load later (measured: the game stayed at the main menu).
      const c = await call<any>("council").catch(() => undefined);
      const env = await callEnvelope("save", args, timeoutMs);
      const warning = c?.inParliament ? "saved inside the Council; such saves are unreliable (one did not load, measured): leave the Council and save again" : undefined;
      const out: any = flags.raw ? env : env.ok ? env.result : env;
      print(warning ? (out && typeof out === "object" && !Array.isArray(out) ? { ...out, warning } : { result: out, warning }) : out);
      return env.ok ? 0 : 1;
    }
    case "load": {
      // Accepts a display name or a file name (FrostPunk2SaveGame9); the game loads by display name.
      if (!flags.force) await assertShadersCompiled();
      print(await call("load", { ...args, name: resolveSaveName(String(args.name ?? "")) }));
      return 0;
    }
    case "unstick":
      print(await unstick([], args.dryRun === true));
      return 0;
    case "launch":
      print({ launched: true, ...(await launchAndWaitShaders(flags.timeout ? timeoutMs : 240_000)) });
      return 0;
    case "new-game": {
      // Main menu -> Utopia Builder (no tales) -> first 3 communities + first faction -> Windswept Peaks
      // -> Start -> intro hold-confirm -> cutscene skip. Coordinates are client fractions measured on a
      // maximized 3840x1600 window (fp2 focus --max). Steps that open screens wait for UI transitions.
      await focusGame(true);
      await sleep(1500);
      const step = async (pt: number[], ms = 1500) => {
        await click(pt);
        await sleep(ms);
      };
      const NEXT = [0.888, 0.944];
      await sendKeys(["enter"], true); // "press any key" title
      await sleep(3000);
      await step([0.25, 0.489], 3000); // Utopia Builder
      await step(NEXT, 2500); // Tales -> Communities
      for (const x of [0.356, 0.4146, 0.4734]) await step([x, 0.3825], 500);
      await step([0.3268, 0.5594], 1000); // starting faction
      await step(NEXT, 2500); // -> Map
      await step([0.169, 0.2], 1000); // Windswept Peaks
      await step(NEXT, 2500); // -> Challenge
      await step(NEXT, 1000); // Start
      const deadline = Date.now() + 240_000;
      for (;;) {
        try {
          const cities = await call<any>("find_all", { class: "PXCityComponent", limit: 1 });
          const t = await time();
          if ((t as any).gameplayBegan && cities.total > 0) break;
        } catch {}
        if (Date.now() > deadline) throw new BridgeError("new game did not load");
        await sleep(2000);
      }
      await setPaused(true);
      await settleIntro();
      const t = await setPaused(true);
      try {
        await call("call", { ref: "/Script/Frostpunk2.Default__PXUserSettingsUtils", fn: "SetPopupTutorialsEnabled", args: [false], mutate: true });
      } catch {}
      print({ started: true, time: t, brief: await brief() });
      return 0;
    }
    case "keys": {
      await sendKeys(rest, Boolean(flags["keep-focus"]) || args.keepFocus === true);
      const res: any = { sent: rest };
      if (args.wait) res.waited = await waitFor(String(args.wait), Number(args.timeout ?? 20) * 1000);
      print(res);
      return 0;
    }
    case "focus":
      await focusGame(Boolean(flags.max));
      print({ focused: true });
      return 0;
    case "reload":
      print(await reload(Boolean(flags.full)));
      return 0;
    default: {
      const env = await callEnvelope(cmd, args, timeoutMs);
      print(flags.raw ? env : env.ok ? env.result : env);
      return env.ok ? 0 : 1;
    }
  }
}

/** runCommand plus the error report every command prints: exit 2 for bridge errors, 3 for anything else. */
async function runCli(argv: string[], io: RunIO): Promise<number> {
  try {
    return await runCommand(argv, io);
  } catch (err) {
    io.out(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }, null, 2));
    return err instanceof BridgeError ? 2 : 3;
  }
}

/** Run in this process without bridge calls; no daemon needed. */
const LOCAL = new Set(["status", "saves", "watch-start", "watch-stop", "screenshot", "focus", "move", "drag", "scroll"]);
/** Run in this process (keyboard/mouse input, window focus, game launch, streaming); bridge calls go to the daemon. */
const CLIENT = new Set(["watch", "keys", "click", "rclick", "hold", "new-game", "council-open", "pass-law", "utopia-assign", "recover", "launch", "unstick"]);

const commandOf = (argv: string[]) => parse(argv).positional[0];

async function daemonCommand(sub: string | undefined, args: Record<string, any>, flags: Record<string, string | boolean>): Promise<number> {
  const out = (v: unknown) => console.log(JSON.stringify(v, null, 2));
  switch (sub) {
    case "run":
      await runDaemon({ srcExe: String(args.src ?? process.execPath), runCli, commandOf });
      return 0;
    case "start": {
      if (!isManager()) throw new BridgeError("daemon start needs the compiled fp2.exe");
      const { info, warning } = await ensureDaemon();
      if (!info) throw new BridgeError(warning ?? "daemon did not start");
      out({ ...(await daemonStatus(info, 2000)), ...(warning ? { warning } : {}) });
      return 0;
    }
    case "stop": {
      const info = readDaemonInfo();
      if (!info) {
        out({ stopped: false, reason: "no daemon running" });
        return 0;
      }
      const r = await stopDaemon(info, Boolean(flags.force));
      out(r);
      return r.stopped ? 0 : 2;
    }
    case "status": {
      const info = readDaemonInfo();
      const st = info ? await daemonStatus(info, 2000) : null;
      if (!info || !st) {
        out({ running: false, reason: info ? `pid ${info.pid} does not answer` : "no daemon running" });
        return 0;
      }
      let stale: boolean | undefined;
      if (isManager()) {
        const { statSync } = await import("node:fs");
        stale = info.srcExe.toLowerCase() !== process.execPath.toLowerCase() || statSync(process.execPath).mtimeMs !== info.exeMtime;
      }
      out({ running: true, ...st, ...(stale === undefined ? {} : { stale }) });
      return 0;
    }
    default:
      throw new BridgeError("daemon status | start | stop [--force]");
  }
}

// Routing. `daemon *` and -h run here. With the daemon (the default for the compiled fp2.exe) a command runs in
// the daemon (/run), except LOCAL and CLIENT commands, which run here with their bridge calls sent to the daemon
// (/call). Without a daemon (--no-daemon, FP2_NO_DAEMON=1, `bun run`, or a daemon that will not start) everything
// runs here on the file bridge, as before.
async function entry(): Promise<number> {
  const raw = process.argv.slice(2);
  const argv = raw.filter((a) => a !== "--no-daemon");
  const noDaemon = argv.length !== raw.length || process.env.FP2_NO_DAEMON === "1";
  const io: RunIO = { out: (s) => console.log(s) };
  const { positional, args, flags } = parse(argv);
  const cmd = positional[0];
  if (cmd === "daemon") {
    try {
      return await daemonCommand(positional[1], args, flags);
    } catch (err) {
      io.out(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }, null, 2));
      return 2;
    }
  }
  if (!cmd || cmd === "-h" || flags.help || noDaemon || !compiled() || LOCAL.has(cmd)) return runCli(argv, io);
  if (!isManager()) {
    // The detached watcher (.runtime/fp2-watch.exe): use a live daemon, never start or stop one.
    setTransport(routedTransport());
    return runCli(argv, io);
  }
  const { info, warning } = await ensureDaemon();
  if (warning) console.error(`fp2: ${warning}`);
  if (!info) return runCli(argv, io);
  setTransport(routedTransport(info));
  if (CLIENT.has(cmd) || (cmd === "reload" && flags.full)) return runCli(argv, io);
  return (await runRemote(info, argv)) ?? runCli(argv, io);
}

entry().then(
  (code) => process.exit(code),
  (err) => {
    console.log(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }, null, 2));
    process.exit(err instanceof BridgeError ? 2 : 3);
  },
);
