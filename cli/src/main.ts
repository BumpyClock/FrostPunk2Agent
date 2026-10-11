#!/usr/bin/env bun
// fp2: single CLI for playing Frostpunk 2 through the FP2AgentBridge mod.
import { closeSync, openSync, readFileSync, readSync } from "node:fs";
import { BridgeError, bridgeDir, call, callEnvelope, readStatus } from "./bridge";
import { focusGame, sendKeys } from "./win32";
import { brief } from "./brief";
import { screenshot } from "./capture";
import { click, drag, move, scroll } from "./mouse";
import { watch } from "./watch";
import { join } from "node:path";
import { repoRoot } from "./bridge";
import { cutsceneReason, setPaused, setSpeed, sleep, time, userPaused, waitAlive, waitFor, waitReady } from "./game";
import { addGoal, goalView, loadGoals, removeGoal, updateGoal } from "./goals";
import { STOP_DEFAULT, turn } from "./turn";

// Named crop regions as fractions of the client area (calibrated on a 21:9 maximized window).
const REGIONS: Record<string, number[]> = {
  hud: [0, 0, 1, 0.075],
  objectives: [0, 0.07, 0.32, 0.72],
  bottom: [0, 0.86, 1, 1],
  center: [0.25, 0.2, 0.75, 0.8],
};

const HELP = `fp2 <subcommand> [key=value ...] [--compact] [--fields a.b,c[0].d] [--timeout S] [--args-file F|-]

Play loop:
  recover [name=X]       relaunch if the bridge is dead, load X or the newest agent-rolling/AutoSave from the
                         main menu, wait until ready, pause; in a loaded game it only pauses
  turn [weeks=4] [stopOn=kind,..] [speed=3] [saveEvery=2] [saveName=agent-rolling] [autoAck=true]
                         resume, run until a stop event or weeks pass, pause; returns {turn, events, dropped,
                         goals, brief}. Events also append to .runtime/watch.jsonl. Default stopOn: ${STOP_DEFAULT.join(",")}
  goals                  open goals (all=true includes done); file .runtime/goals.jsonl, one JSON per line
  goals add text=".." [horizon=long|short|check] [due=<week>] [expect=".."]
  goals done id=N [note=".."] | goals edit id=N [text=..] [due=..] [expect=..] [horizon=..] | goals rm id=N
  wait-for cond=<c> [timeout=20]
                         c: modal | no-modal | council | no-council | cutscene | no-cutscene | paused | running |
                         ready | reason:<substr> | no-reason:<substr>. click/hold/keys accept wait=<c>.

Local subcommands:
  status                 heartbeat (no game-thread round trip)
  launch                 kill leftover CrashReportClient, start the game via Steam, wait for the bridge
  pass-law policy=<id>   bridge-only Council: open, propose, vote, dismiss, verify (needs an open session)
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
                         overwrites one rolling save every saveEvery in-game weeks (0 = off);
                         autoAck=true (default) dismisses one-option "I see" dialogs, emitting dialog.acknowledged
  brief                  triaged digest: deficits, depleting stocks, rising stats, pause/modal state
  pause | resume         pause/unpause game time (verified via the mod)
  speed <1|2|3>          set game speed via the bridge (game.speed)
  advance [ticks=N]      resume, wait until game time advances N ticks (default 24000), pause, print brief;
                         stops early when a modal/event pauses the game
  wait-ready             block until a city is loaded and gameplay began (after load/new game)
  keys <chord...>       send keys to the game window, e.g. keys space | keys ctrl+r  (--keep-focus)
  screenshot [region=hud|objectives|bottom|center|x0,y0,x1,y1] [scale=0.5] [out=path]
                         capture the game client area to PNG (pixels or 0..1 fractions); prints the path
  click x,y [--double]   (refused while a cutscene plays unless --force) left-click at client pixel (or 0..1 fraction) coordinates from a scale=1 screenshot
  rclick x,y             right-click
  hold x,y [ms=1500]     press-and-hold (FP2 confirm buttons need a hold)
  move x,y | drag x,y x2,y2 | scroll x,y <ticks>   (scroll: + up / - down)
  focus [--max]          bring the game window to the foreground (needed before screenshots); --max maximizes
  reload [--full]        re-require Lua modules in place (no keys); --full = UE4SS Ctrl+R reload (main.lua changes);
                         a Lua error returns the failing file's lines as context

Bridge subcommands (run inside the game; 'fp2 help' lists them):
  state, extract name=X, world, find_all, classes, modules, search, describe, object, get,
  components, call, set, ping, help

Values parse as JSON when valid, else strings. Dotted keys nest: a.b=1 -> {"a":{"b":1}}.
--fields prints only the given paths: one path prints the value, several print {path: value}.`;

const SAVE_DIR = join(process.env.LOCALAPPDATA ?? "", "11bitstudios", "Frostpunk2", "Steam", "Saved", "SaveGames");

// .sav header: int32 magic, then an FString (int32 length incl. NUL, bytes) holding the display name.
function saveDisplayName(path: string): string | undefined {
  try {

    const fd = openSync(path, "r");
    const buf = Buffer.alloc(512);
    readSync(fd, buf, 0, 512, 0);
    closeSync(fd);
    const len = buf.readInt32LE(4);
    if (len <= 1 || len > 500) return undefined;
    return buf.toString("utf8", 8, 8 + len - 1);
  } catch {
    return undefined;
  }
}

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

let compact = false;
let fields: string[] = [];

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

const print = (v: unknown) => {
  if (fields.length) v = project(v, fields);
  console.log(compact ? JSON.stringify(v) : JSON.stringify(v, null, 2));
};

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
async function councilOpen() {
  for (let attempt = 0; attempt < 3; attempt++) {
    const c = await call<any>("council");
    if (c.inParliament) break;
    await sendKeys(["c"], true);
    await sleep(4000);
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

/** Start the game via Steam if it is not running (closing a leftover crash reporter first) and wait for the bridge. */
async function launchGame(timeoutMs: number) {
  Bun.spawnSync(["taskkill", "/IM", "CrashReportClient.exe", "/F"], { stdout: "ignore", stderr: "ignore" });
  const running = Bun.spawnSync(["tasklist", "/FI", "IMAGENAME eq Frostpunk2-Win64-Shipping.exe"]).stdout.toString();
  if (!running.includes("Frostpunk2-Win64-Shipping")) {
    Bun.spawn(["C:/Program Files (x86)/Steam/steam.exe", "-applaunch", "1601580"], { stdout: "ignore", stderr: "ignore" });
  }
  return waitAlive(timeoutMs);
}

type SaveEntry = { file: string; display?: string; modified: string; bytes: number };
async function listSaves(): Promise<SaveEntry[]> {
  const { readdirSync, statSync } = await import("node:fs");
  return readdirSync(SAVE_DIR)
    .filter((f) => f.endsWith(".sav"))
    .map((f) => ({ file: f.slice(0, -4), display: saveDisplayName(join(SAVE_DIR, f)), modified: statSync(join(SAVE_DIR, f)).mtime.toISOString(), bytes: statSync(join(SAVE_DIR, f)).size }))
    .sort((a, b) => b.modified.localeCompare(a.modified));
}

/** Newest agent rolling save or game autosave (by file time); the name `load` takes. */
async function newestRecoverySave(): Promise<string> {
  const s = (await listSaves()).find((x) => /^agent-|^AutoSave/i.test(x.display ?? x.file));
  if (!s) throw new BridgeError("no agent-* or AutoSave* save found; pass name=<save>");
  return s.display ?? s.file;
}

// Session start and crash recovery in one call. Measured sequence from past recoveries: launch, Enter on the
// title screen, ForceLoadGame from the main menu (retried: the save subsystem is not ready at once),
// wait until a city exists, a key to close the loading screen, then the player pause.
async function recover(name: string | undefined, timeoutMs: number) {
  const steps: string[] = [];
  const st = await readStatus();
  if (!st.alive) {
    await launchGame(timeoutMs);
    steps.push("launched");
    await sleep(3000);
  }
  const ready = await waitReady(5_000).then(() => true, () => false);
  if (ready) {
    const t = await setPaused(true);
    return { recovered: false, reason: "already in a loaded game", steps, time: t, brief: await brief() };
  }
  const save = name ?? (await newestRecoverySave());
  await sendKeys(["enter"], true); // "press any key" title screen (harmless in the menu)
  steps.push("title dismissed");
  const deadline = Date.now() + 60_000;
  for (;;) {
    const err = await call("load", { name: save }).then(() => undefined, (e) => String(e));
    if (!err) break;
    if (Date.now() > deadline) throw new BridgeError(`load ${save} failed: ${err}`);
    await sleep(5000);
  }
  steps.push(`loading ${save}`);
  await waitReady(timeoutMs);
  await sendKeys(["space"], true); // closes the loading screen (measured)
  await sleep(2000);
  const t = await setPaused(true);
  steps.push("ready, paused");
  return { recovered: true, save, steps, time: t, brief: await brief() };
}

async function main(argv: string[]): Promise<number> {
  const { positional, args, flags } = parse(argv);
  compact = Boolean(flags.compact);
  fields = String(flags.fields ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const timeoutMs = flags.timeout ? Number(flags.timeout) * 1000 : 30_000;
  const [cmd, ...rest] = positional;
  if (!cmd || cmd === "-h" || flags.help) {
    console.log(HELP);
    return 0;
  }
  if (flags["args-file"]) {
    const f = String(flags["args-file"]);
    Object.assign(args, JSON.parse(f === "-" ? await Bun.stdin.text() : readFileSync(f, "utf8")));
  }
  switch (cmd) {
    case "status":
      print({ ...(await readStatus()), bridgeDir: bridgeDir() });
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
    case "advance":
      print(await advance(Number(args.ticks ?? 24000), flags.timeout ? timeoutMs : 600_000));
      return 0;
    case "turn": {
      const stopOn = new Set(args.stopOn ? String(args.stopOn).split(",").map((s: string) => s.trim()).filter(Boolean) : STOP_DEFAULT);
      print(
        await turn({
          weeks: Number(args.weeks ?? 4),
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
          print(addGoal({ text: String(args.text ?? ""), horizon: args.horizon, due: args.due === undefined ? undefined : Number(args.due), expect: args.expect }, { week: d.week, date: d.date }));
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
      print(await recover(args.name === undefined ? undefined : String(args.name), flags.timeout ? timeoutMs : 240_000));
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
      await watch({ intervalMs: Number(args.interval ?? 2) * 1000, pauseOn, once: Boolean(flags.once), saveEveryWeeks: saveEvery > 0 ? saveEvery : undefined, saveName: args.saveName ? String(args.saveName) : undefined, autoAck: String(args.autoAck ?? "false") === "true", out: (l) => console.log(JSON.stringify(l)) });
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
      const wargs = [`interval=${args.interval ?? 2}`, `pauseOn=${args.pauseOn ?? "dialog.opened,need.deficit,stock.runway,research.finished,construction.finished"}`, `saveEvery=${args.saveEvery ?? 2}`, `saveName=${args.saveName ?? "agent-rolling"}`, `autoAck=${args.autoAck ?? "true"}`];
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
      // Bridge-only Council flow: open (skip cutscene) -> propose -> vote -> dismiss result -> verify.
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
      const proposed = await call<any>("propose", { policy });
      await sleep(4000); // proposal transition (black frames)
      await skipCutscenes();
      const vote = await call<any>("vote", { policy });
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
      print({ policy: proposed.policy, vote: vote.result, active: (after.activePolicies ?? []).includes(proposed.policy), phase: after.phase, inParliament: after.inParliament, paused: wasPaused });
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
      print({ dir: SAVE_DIR, saves: (await listSaves()).slice(0, Number(args.limit ?? 20)) });
      return 0;
    case "load": {
      // Accepts a display name or a file name (FrostPunk2SaveGame9); the game loads by display name.
      const { existsSync } = await import("node:fs");
      const name = String(args.name ?? "");
      const file = join(SAVE_DIR, `${name}.sav`);
      const display = existsSync(file) ? saveDisplayName(file) ?? name : name;
      print(await call("load", { ...args, name: display }));
      return 0;
    }
    case "launch":
      print({ launched: true, bridge: await launchGame(flags.timeout ? timeoutMs : 240_000) });
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
      await sendKeys(rest, Boolean(flags["keep-focus"]));
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

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err) => {
    console.log(JSON.stringify({ ok: false, error: err instanceof Error ? err.message : String(err) }, null, 2));
    process.exit(err instanceof BridgeError ? 2 : 3);
  },
);
