#!/usr/bin/env bun
// fp2: single CLI for playing Frostpunk 2 through the FP2AgentBridge mod.
import { readFileSync } from "node:fs";
import { BridgeError, bridgeDir, call, callEnvelope, readStatus } from "./bridge";
import { focusGame, sendKeys } from "./win32";
import { brief } from "./brief";
import { screenshot } from "./capture";
import { click, drag, move, scroll } from "./mouse";
import { watch } from "./watch";
import { join } from "node:path";
import { repoRoot } from "./bridge";

// Named crop regions as fractions of the client area (calibrated on a 21:9 maximized window).
const REGIONS: Record<string, number[]> = {
  hud: [0, 0, 1, 0.075],
  objectives: [0, 0.07, 0.32, 0.72],
  bottom: [0, 0.86, 1, 1],
  center: [0.25, 0.2, 0.75, 0.8],
};

const HELP = `fp2 <subcommand> [key=value ...] [--compact] [--timeout S] [--args-file F|-]

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
  watch-start [pauseOn=..] / watch-stop
                         detached watcher appending to .runtime/watch.jsonl (tail it from a Monitor)
  brief                  triaged digest: deficits, depleting stocks, rising stats, pause/modal state
  pause | resume         pause/unpause game time (verified via the mod)
  speed <1|2|3>          set game speed (sends number key)
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
  reload [--full]        re-require Lua modules in place (no keys); --full = UE4SS Ctrl+R reload (main.lua changes)

Bridge subcommands (run inside the game; 'fp2 help' lists them):
  state, extract name=X, world, find_all, classes, modules, search, describe, object, get,
  components, call, set, ping, help

Values parse as JSON when valid, else strings. Dotted keys nest: a.b=1 -> {"a":{"b":1}}.`;

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
      if (["timeout", "args-file"].includes(name)) flags[name] = argv[++i];
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
const print = (v: unknown) => console.log(compact ? JSON.stringify(v) : JSON.stringify(v, null, 2));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

type TimeInfo = { paused: boolean; pauseReasons?: string[]; speed?: string; gameTimeTicks?: number };
const time = () => call<TimeInfo>("extract", { name: "time" });

// "UserPaused" is the player's toggle; other reasons (modals, tutorial logs) clear themselves
// when the UI closes, so they must not count as "paused by us".
const userPaused = (t: TimeInfo) => (t.pauseReasons ?? []).includes("UserPaused");

async function setPaused(want: boolean): Promise<TimeInfo> {
  // Uses PXTimeUtils.SetPausedByPlayer through the bridge (no keystrokes, works unfocused).
  await call(want ? "game.pause" : "game.resume");
  const t = await time();
  if (userPaused(t) !== want) throw new BridgeError(`pause state not applied (reasons=${(t.pauseReasons ?? []).join(",")})`);
  const others = (t.pauseReasons ?? []).filter((r) => r !== "UserPaused");
  if (!want && others.length) (t as any).warning = `still paused by UI: ${others.join(", ")}`;
  return t;
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
      stoppedBy = (t.pauseReasons ?? []).join(", ") || "paused";
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

const cutsceneReason = (t: TimeInfo) => (t.pauseReasons ?? []).find((r) => /Cutscene/i.test(r));

// Skip any running cutscene (hold E) until its pause reason clears.
async function skipCutscenes(maxTries = 6): Promise<TimeInfo> {
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

async function reload(full: boolean) {
  if (!full) {
    // Keyless: re-require all Lua modules except main.lua inside the running VM.
    return call("bridge.reload");
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

async function main(argv: string[]): Promise<number> {
  const { positional, args, flags } = parse(argv);
  compact = Boolean(flags.compact);
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
      if (!["1", "2", "3"].includes(n)) throw new BridgeError("speed needs 1, 2 or 3");
      await call("game.speed", { level: Number(n) - 1 });
      print(await time());
      return 0;
    }
    case "advance":
      print(await advance(Number(args.ticks ?? 24000), flags.timeout ? timeoutMs : 600_000));
      return 0;
    case "wait-ready": {
      // Until the bridge is alive, gameplay has begun and a city exists (after load / new game).
      const deadline = Date.now() + (flags.timeout ? timeoutMs : 180_000);
      let last: unknown = null;
      while (Date.now() < deadline) {
        try {
          const t = await time();
          const cities = await call<any[]>("find_all", { class: "PXCityComponent", limit: 1 });
          last = { gameplayBegan: (t as any).gameplayBegan, cities: (cities as any).total };
          if ((t as any).gameplayBegan && (cities as any).total > 0) {
            print({ ready: true, ...t });
            return 0;
          }
        } catch (e) {
          last = String(e);
        }
        await sleep(1000);
      }
      throw new BridgeError(`not ready: ${JSON.stringify(last)}`);
    }
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
      await watch({ intervalMs: Number(args.interval ?? 2) * 1000, pauseOn, once: Boolean(flags.once), out: (l) => console.log(JSON.stringify(l)) });
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
      const wargs = [`interval=${args.interval ?? 2}`, `pauseOn=${args.pauseOn ?? "dialog.opened,need.deficit,stock.runway,research.finished,construction.finished"}`];
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
    case "click":
    case "rclick":
    case "hold": {
      if (!flags.force) {
        const cs = await time().then(cutsceneReason).catch(() => undefined);
        if (cs) throw new BridgeError(`${cmd} blocked: cutscene active (${cs}); skip it (fp2 keys e@3000) or pass --force`);
      }
      const pt = String(rest[0] ?? "").split(",").map(Number);
      if (pt.length !== 2 || pt.some(Number.isNaN)) throw new BridgeError(`${cmd} needs x,y`);
      print(await click(pt, { right: cmd === "rclick", holdMs: cmd === "hold" ? Number(args.ms ?? 1500) : undefined, double: Boolean(flags.double) }));
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
    case "saves": {
      // Disk listing (works without the game); newest first.
      const dir = join(process.env.LOCALAPPDATA ?? "", "11bitstudios", "Frostpunk2", "Steam", "Saved", "SaveGames");
      const { readdirSync, statSync } = await import("node:fs");
      const list = readdirSync(dir)
        .filter((f) => f.endsWith(".sav"))
        .map((f) => ({ name: f.slice(0, -4), modified: statSync(join(dir, f)).mtime.toISOString(), bytes: statSync(join(dir, f)).size }))
        .sort((a, b) => b.modified.localeCompare(a.modified));
      print({ dir, saves: list.slice(0, Number(args.limit ?? 20)) });
      return 0;
    }
    case "launch": {
      // Close a leftover crash reporter (it blocks relaunch), start via Steam, wait for the bridge.
      Bun.spawnSync(["taskkill", "/IM", "CrashReportClient.exe", "/F"], { stdout: "ignore", stderr: "ignore" });
      const running = Bun.spawnSync(["tasklist", "/FI", "IMAGENAME eq Frostpunk2-Win64-Shipping.exe"]).stdout.toString();
      if (!running.includes("Frostpunk2-Win64-Shipping")) {
        Bun.spawn(["C:/Program Files (x86)/Steam/steam.exe", "-applaunch", "1601580"], { stdout: "ignore", stderr: "ignore" });
      }
      const deadline = Date.now() + (flags.timeout ? timeoutMs : 240_000);
      while (Date.now() < deadline) {
        const st = await readStatus();
        if (st.alive) {
          print({ launched: true, bridge: st });
          return 0;
        }
        await sleep(2000);
      }
      throw new BridgeError("game/bridge did not come up in time");
    }
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
    case "keys":
      await sendKeys(rest, Boolean(flags["keep-focus"]));
      print({ sent: rest });
      return 0;
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
