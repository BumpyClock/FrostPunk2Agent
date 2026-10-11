#!/usr/bin/env bun
// fp2: single CLI for playing Frostpunk 2 through the FP2AgentBridge mod.
import { readFileSync } from "node:fs";
import { BridgeError, bridgeDir, call, callEnvelope, readStatus } from "./bridge";
import { focusGame, sendKeys } from "./win32";
import { brief } from "./brief";
import { screenshot } from "./capture";
import { click, drag, move, scroll } from "./mouse";
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
  saves [limit=20]       save files on disk, newest first (load with: fp2 load name=<name>; save: fp2 save name=<new>)
  brief                  triaged digest: deficits, depleting stocks, rising stats, pause/modal state
  pause | resume         pause/unpause game time (verified via the mod)
  speed <1|2|3>          set game speed (sends number key)
  advance [ticks=N]      resume, wait until game time advances N ticks (default 24000), pause, print brief;
                         stops early when a modal/event pauses the game
  wait-ready             block until a city is loaded and gameplay began (after load/new game)
  keys <chord...>       send keys to the game window, e.g. keys space | keys ctrl+r  (--keep-focus)
  screenshot [region=hud|objectives|bottom|center|x0,y0,x1,y1] [scale=0.5] [out=path]
                         capture the game client area to PNG (pixels or 0..1 fractions); prints the path
  click x,y [--double]   left-click at client pixel (or 0..1 fraction) coordinates from a scale=1 screenshot
  rclick x,y             right-click
  hold x,y [ms=1500]     press-and-hold (FP2 confirm buttons need a hold)
  move x,y | drag x,y x2,y2 | scroll x,y <ticks>   (scroll: + up / - down)
  focus [--max]          bring the game window to the foreground (needed before screenshots); --max maximizes
  reload                 hot-reload UE4SS Lua mods (Ctrl+R) and wait for the bridge to restart

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

async function reload() {
  const before = (await readStatus()).started;
  await sendKeys(["ctrl+r"]);
  for (let i = 0; i < 30; i++) {
    await sleep(500);
    const st = await readStatus();
    if (st.alive && st.started !== before) return { reloaded: true, started: st.started };
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
    case "click":
    case "rclick":
    case "hold": {
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
    case "keys":
      await sendKeys(rest, Boolean(flags["keep-focus"]));
      print({ sent: rest });
      return 0;
    case "focus":
      await focusGame(Boolean(flags.max));
      print({ focused: true });
      return 0;
    case "reload":
      print(await reload());
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
