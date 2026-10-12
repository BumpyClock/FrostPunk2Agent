// `fp2 launch` and `fp2 recover`: start the game, load a save from the main menu, and fall back to older
// saves when a load crashes the game.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, call, loadQuietLeftMs, readStatus } from "./bridge";
import { brief } from "./brief";
import { isReady, setPaused, sleep, time, waitAlive, waitReady } from "./game";
import { SAVE_DIR, markBadSave, recoveryCandidates, saveDisplayName } from "./saves";
import { gameFocused, sendKeys } from "./win32";

const GAME_EXE = "Frostpunk2-Win64-Shipping.exe";
const CRASH_DIR = join(process.env.LOCALAPPDATA ?? "", "11bitstudios", "Frostpunk2", "Steam", "Saved", "Crashes");
/** The heartbeat runs on UE4SS's async loop, so a long gap while loading means the game hung (inferred). */
const LOAD_HEARTBEAT_STALE_MS = 60_000;
export const RECOVER_MAX_ATTEMPTS = 3;

const processRunning = (image: string) => Bun.spawnSync(["tasklist", "/FI", `IMAGENAME eq ${image}`]).stdout.toString().includes(image.replace(/\.exe$/, ""));
const killProcess = (image: string) => Bun.spawnSync(["taskkill", "/IM", image, "/F"], { stdout: "ignore", stderr: "ignore" });

function crashDirs(): Set<string> {
  try {
    return new Set(readdirSync(CRASH_DIR));
  } catch {
    return new Set();
  }
}

function crashMessage(dir: string): string | undefined {
  try {
    const xml = readFileSync(join(CRASH_DIR, dir, "CrashContext.runtime-xml"), "utf8");
    return xml.match(/<ErrorMessage>([\s\S]*?)<\/ErrorMessage>/)?.[1]?.trim().slice(0, 200);
  } catch {
    return undefined;
  }
}

/** Start the game via Steam if it is not running (closing a leftover crash reporter first) and wait for the bridge. */
export async function launchGame(timeoutMs: number) {
  killProcess("CrashReportClient.exe");
  if (!processRunning(GAME_EXE)) {
    Bun.spawn(["C:/Program Files (x86)/Steam/steam.exe", "-applaunch", "1601580"], { stdout: "ignore", stderr: "ignore" });
  }
  return waitAlive(timeoutMs);
}

/** Kill a crashed or hung game and its crash reporter, and wait until the process is gone. */
async function killGame() {
  killProcess("CrashReportClient.exe");
  killProcess(GAME_EXE);
  for (let i = 0; i < 30 && processRunning(GAME_EXE); i++) await sleep(1000);
}

// Startup shader compilation. The main menu spawns BP_ShaderCompilerActor_C; WBP_InitializationLoadingScreen_C
// shows "COMPILING SHADERS N/743" until the actor reports OnShaderCompilationFinished. A save load destroys the
// actor mid-compile, so the screen never hears it and stays up with all input blocked, while the bridge still
// works (measured twice). Calling OnShaderCompilationFinished on the widget, waiting for its DelayDuration
// (~12 s) and pressing Space cleared it (measured).
const SHADER_COMPILER = "BP_ShaderCompilerActor_C";
const INIT_SCREEN = "WBP_InitializationLoadingScreen_C";
const SHADER_WAIT_MS = 15 * 60_000;
const SHADER_POLL_MS = 5000;
const CONTINUE_PROMPT_MS = 13_000;
const STUCK_CONFIRM_MS = 10_000;

/** Live (non-default) instances of a class, by path. */
async function instances(cls: string): Promise<string[]> {
  const r = await call<any>("find_all", { class: cls, limit: 10 });
  return (Array.isArray(r?.items) ? r.items : []).map((i: any) => String(i?.ref ?? "")).filter((p: string) => p && !p.includes("Default__"));
}

/** A property read through the bridge's `get` command (no function call), or undefined when it fails. */
async function prop(ref: string, path: string): Promise<any> {
  return call<any>("get", { ref, path, depth: 1 }).then((r) => r?.value, () => undefined);
}

// ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3 HitTestInvisible, 4 SelfHitTestInvisible.
const SHOWN_VISIBILITY = new Set([0, 3, 4]);

/**
 * The compile overlay of one initialization screen. The widget itself stays in the viewport and visible for the
 * whole session; after the compile finished (here: after a live unstick) its CompilingShadersCanvasContainer was
 * SelfHitTestInvisible with RenderOpacity 0 and CompilingProgressText still read "559/743" (measured). So the
 * overlay counts as shown only with RenderOpacity > 0. Opacity while stuck is not measured yet (inferred > 0).
 */
export type OverlayProbe = { screen: string; visibility?: number; opacity?: number; progress?: string; shown: boolean; counting: boolean };

async function probeOverlay(screen: string): Promise<OverlayProbe> {
  const container = (await prop(screen, "CompilingShadersCanvasContainer"))?.ref;
  const text = (await prop(screen, "CompilingProgressText"))?.ref;
  const vis = container ? await prop(container, "Visibility") : undefined;
  const visibility = typeof vis === "number" ? vis : typeof vis?.value === "number" ? vis.value : undefined;
  const opacity = container ? await prop(container, "RenderOpacity") : undefined;
  const progress = text ? await prop(text, "Text") : undefined;
  const m = typeof progress === "string" ? progress.match(/(\d+)\s*\/\s*(\d+)/) : null;
  return {
    screen,
    ...(visibility !== undefined ? { visibility } : {}),
    ...(typeof opacity === "number" ? { opacity } : {}),
    ...(typeof progress === "string" ? { progress } : {}),
    shown: visibility !== undefined && SHOWN_VISIBILITY.has(visibility) && typeof opacity === "number" && opacity > 0,
    counting: Boolean(m && Number(m[1]) < Number(m[2])),
  };
}

export type ShaderState = { compilers: number; inWorld: boolean; map?: string; overlays: OverlayProbe[]; showing: boolean };

/** Compiler actors, the compile overlays, and the map. showing = some overlay is on screen. */
export async function shaderState(): Promise<ShaderState> {
  const compilers = (await instances(SHADER_COMPILER)).length;
  const overlays: OverlayProbe[] = [];
  for (const screen of await instances(INIT_SCREEN)) overlays.push(await probeOverlay(screen));
  const session = await call<any>("extract", { name: "session" }).catch(() => ({}));
  return { compilers, inWorld: session?.inWorld === true, ...(session?.map ? { map: String(session.map) } : {}), overlays, showing: overlays.some((o) => o.shown) };
}

/** The stuck overlay: in a level (not the main menu), no compiler actor, overlay shown with an unfinished N/M counter. */
function stuckOverlay(s: ShaderState): OverlayProbe | undefined {
  if (s.compilers > 0 || !s.inWorld || !s.map || /menu/i.test(s.map)) return undefined;
  return s.overlays.find((o) => o.shown && o.counting);
}

/**
 * `fp2 unstick`: clear a stuck "COMPILING SHADERS N/743" overlay. Stuck = in a level, no BP_ShaderCompilerActor_C,
 * the overlay shown with an unfinished counter, and the counter unchanged across two reads 10 s apart. Only then
 * it calls OnShaderCompilationFinished, waits for the continue prompt and presses Space. Prints the evidence.
 */
export async function unstick(steps: string[] = [], dryRun = false) {
  const first = await shaderState();
  const candidate = stuckOverlay(first);
  if (!candidate) return { stuck: false, evidence: first };
  await sleep(STUCK_CONFIRM_MS);
  const second = await shaderState();
  const again = stuckOverlay(second);
  const evidence = { first, second };
  if (!again || again.screen !== candidate.screen || again.progress !== candidate.progress) return { stuck: false, reason: "overlay changed within 10 s (still compiling or closing)", evidence };
  if (dryRun) return { stuck: true, dryRun: true, evidence };
  await call("call", { ref: again.screen, fn: "OnShaderCompilationFinished", mutate: true });
  steps.push(`unstick: OnShaderCompilationFinished on ${again.screen} (progress ${again.progress}); waiting ${CONTINUE_PROMPT_MS / 1000}s for the prompt`);
  await sleep(CONTINUE_PROMPT_MS);
  let after = second;
  for (let i = 1; i <= 3; i++) {
    await sendKeys(["space"], true);
    await sleep(2000);
    after = await shaderState();
    if (!after.showing) {
      steps.push(`unstick: overlay gone after Space ${i}`);
      break;
    }
    steps.push(`unstick: overlay still shown after Space ${i}${gameFocused() ? "" : " (game window not focused)"}`);
  }
  const t = await time().catch(() => undefined);
  return { stuck: true, unstuck: !after.showing, evidence, after, pauseReasons: t?.pauseReasons, steps };
}

/**
 * Before a load: wait until no shader compiler actor exists on two polls in a row (clearing a stuck screen on the
 * way). Returns a failed Attempt on crash or timeout, else undefined.
 */
async function waitShadersCompiled(steps: string[], timeoutMs: number, crashed?: () => Promise<string | undefined>): Promise<Extract<Attempt, { ok: false }> | undefined> {
  const deadline = Date.now() + timeoutMs;
  let clear = 0;
  let lastLog = 0;
  for (;;) {
    const c = await crashed?.();
    if (c) return { ok: false, crashed: true, reason: `${c} (while waiting for shader compilation)` };
    const s = await shaderState().catch(() => undefined);
    if (s && s.compilers === 0 && s.showing) await unstick(steps);
    clear = s && s.compilers === 0 ? clear + 1 : 0;
    if (clear >= 2) {
      steps.push("shader compilation finished");
      return undefined;
    }
    if (s && s.compilers > 0 && Date.now() - lastLog > 60_000) {
      steps.push(`waiting for shader compilation (${s.compilers} compiler actor(s))`);
      console.error(`fp2: waiting for startup shader compilation (${s.compilers} compiler actor(s))`);
      lastLog = Date.now();
    }
    if (Date.now() > deadline) return { ok: false, crashed: false, reason: `shader compilation still running after ${timeoutMs / 60_000} min` };
    await sleep(SHADER_POLL_MS);
  }
}

/** Launch, then wait out startup shader compilation, so a following `load` cannot strand the game. */
export async function launchAndWaitShaders(timeoutMs: number) {
  const bridge = await launchGame(timeoutMs);
  const steps: string[] = [];
  const failed = await waitShadersCompiled(steps, SHADER_WAIT_MS);
  if (failed) throw new BridgeError(failed.reason);
  return { bridge, steps };
}

/** Refuse a load while startup shaders compile (it would leave the compile screen stuck). */
export async function assertShadersCompiled() {
  const n = (await instances(SHADER_COMPILER).catch(() => [])).length;
  if (n > 0) throw new BridgeError(`startup shader compilation still running (${n} ${SHADER_COMPILER}); a load now leaves the game stuck on "COMPILING SHADERS". Wait, use fp2 recover, or pass --force`);
}

/** `quiet`: the crash happened while no game-thread calls were made, so the save itself is suspect. */
type Attempt = { ok: true; time: unknown } | { ok: false; crashed: boolean; quiet?: boolean; reason: string };

// One load from the main menu. Measured sequence: Enter on the title screen, ForceLoadGame through the bridge
// (retried: the save subsystem is not ready at once), wait until a city exists, Space to close the loading
// screen, then the player pause. After the load is issued, no game-thread call is made until the post-load quiet
// period ends (LOAD_QUIET_MS in bridge.ts): polling during a load crashed the game in Wwise (measured).
// Reports a crash when the game process exits, a new crash report appears, the crash reporter starts, or the
// heartbeat stops for LOAD_HEARTBEAT_STALE_MS.
async function loadOnce(save: string, timeoutMs: number, steps: string[], inGame = false): Promise<Attempt> {
  const before = crashDirs();
  let lastAlive = Date.now();
  const crashed = async (): Promise<string | undefined> => {
    const fresh = [...crashDirs()].filter((d) => !before.has(d));
    if (fresh.length) {
      const msg = crashMessage(fresh[0]);
      return `crash report ${fresh[0]}${msg ? `: ${msg}` : ""}`;
    }
    if (!processRunning(GAME_EXE)) return "game process exited";
    if (processRunning("CrashReportClient.exe")) return "CrashReportClient running";
    if ((await readStatus()).alive) lastAlive = Date.now();
    else if (Date.now() - lastAlive > LOAD_HEARTBEAT_STALE_MS) return `bridge heartbeat stale for ${LOAD_HEARTBEAT_STALE_MS / 1000}s`;
    return undefined;
  };

  // A load issued while startup shaders still compile leaves the game stuck on "COMPILING SHADERS" (measured twice).
  const shaders = await waitShadersCompiled(steps, SHADER_WAIT_MS, crashed);
  if (shaders) return shaders;
  // The main-menu map, to tell a load the game dropped from one still running (measured: a save written inside the
  // Council scene left the game at the main menu, and recover waited out its full timeout).
  // Only recorded when no city is loaded, so a save on the same map as a loaded game is not taken for the menu.
  const menuMap = (await isReady()).ready ? undefined : (await session())?.map;
  if (!inGame) {
    await sendKeys(["enter"], true); // "press any key" title screen (harmless in the menu)
    steps.push("title dismissed");
  }
  const loadDeadline = Date.now() + 60_000;
  for (;;) {
    const err = await call("load", { name: save }).then(() => undefined, (e) => String(e));
    if (!err) break;
    const c = await crashed();
    if (c) return { ok: false, crashed: true, reason: `${c} (before load was issued: ${err})` };
    if (Date.now() > loadDeadline) return { ok: false, crashed: false, reason: `load ${save} failed: ${err}` };
    await sleep(5000);
  }
  steps.push(`loading ${save}; quiet for ${Math.round(loadQuietLeftMs() / 1000)}s`);

  // Quiet phase: heartbeat file and process checks only.
  while (loadQuietLeftMs() > 0) {
    const c = await crashed();
    if (c) return { ok: false, crashed: true, quiet: true, reason: c };
    await sleep(2000);
  }
  const deadline = Date.now() + timeoutMs;
  let atMenu = 0;
  for (;;) {
    const c = await crashed();
    if (c) return { ok: false, crashed: true, quiet: false, reason: `${c} (after the quiet period, while polling)` };
    const sess = await session();
    const ready = (await isReady()).ready;
    atMenu = menuMap && sess?.map === menuMap && !ready ? atMenu + 1 : 0;
    if (atMenu >= 2) return { ok: false, crashed: false, reason: `save did not load: ${save} still at the main menu (map ${menuMap}) after the quiet period; the game refused or dropped the load (saves made inside the Council are unreliable)` };
    // Ready: in the world with a city and gameplay begun, no shader compiler, no compile overlay. A modal or the
    // player pause does not matter here.
    if (sess?.inWorld === true && ready) {
      const s = await shaderState();
      if (s.compilers === 0 && !s.showing) break;
      if (s.compilers > 0) steps.push(`in world, ${s.compilers} shader compiler actor(s) still running`);
      else await unstick(steps); // acts only after its own checks (counter frozen for 10 s)
    }
    if (Date.now() > deadline) return { ok: false, crashed: false, reason: `${save} did not finish loading within ${timeoutMs / 1000}s after the quiet period` };
    await sleep(5000);
  }
  const dismissed = await dismissLoadingScreen(steps);
  if (!dismissed) return { ok: false, crashed: false, reason: `${save} loaded but the loading screen did not close after ${DISMISS_KEYS.length} key presses (game time does not advance, no modal past the loading screen); press a key in the game window` };
  const t = await setPaused(true);
  steps.push("ready, paused");
  return { ok: true, time: t };
}

/** `extract session` (inWorld, map), or undefined when the bridge does not answer. */
async function session(): Promise<{ inWorld?: boolean; map?: string } | undefined> {
  return call<any>("extract", { name: "session" }).catch(() => undefined);
}

/**
 * Non-player pause reasons when the loading screen is gone (PXLoadingScreenUtils.IsInLoadingScreen false; it read
 * false in the world, measured), else null. Its value during "press any key" is not measured (inferred true).
 */
async function modalPastLoadingScreen(): Promise<string[] | null> {
  const t = await time().catch(() => undefined);
  const others = (t?.pauseReasons ?? []).filter((r) => r !== "UserPaused" && r !== "SavingGame");
  if (!others.length) return null;
  const r = await call<any>("call", { ref: "/Script/Frostpunk2.Default__PXLoadingScreenUtils", fn: "IsInLoadingScreen", args: ["@ctx"] }).catch(() => undefined);
  return r?.results?.[0] === false ? others : null;
}

/** Keys tried in order on the "Press any key to continue" loading screen. */
const DISMISS_KEYS = ["space", "enter", "space"];

/** True when game time advances after the player pause is removed (leaves the game running; the caller pauses). */
async function clockAdvances(): Promise<boolean> {
  await setPaused(false).catch(() => undefined);
  const a = (await time().catch(() => ({ gameTimeTicks: undefined as number | undefined }))).gameTimeTicks;
  await sleep(1200);
  const b = (await time().catch(() => ({ gameTimeTicks: undefined as number | undefined }))).gameTimeTicks;
  return typeof a === "number" && typeof b === "number" && b > a;
}

// The key press is lost when the game window is not the foreground window (measured: the loading screen stayed up
// and game time never advanced). Focus is verified before each press (sendKeys focuses and retries); success is
// proved by the game clock advancing, not by the key being sent.
async function dismissLoadingScreen(steps: string[]): Promise<boolean> {
  for (let i = 0; i < DISMISS_KEYS.length; i++) {
    await sendKeys([DISMISS_KEYS[i]], true);
    if (!gameFocused()) steps.push(`dismiss ${i + 1}: game window not focused after the key press`);
    await sleep(1500);
    // A save can open on a story modal (measured: pauseReasons [WBP_LensesMessagesNew_C, UserPaused]); then time
    // cannot advance, so a modal with the loading screen gone also counts.
    const modal = await modalPastLoadingScreen();
    if (modal) {
      steps.push(`loading screen closed (key ${DISMISS_KEYS[i]}, press ${i + 1}); a modal is open (${modal.join(", ")})`);
      return true;
    }
    if (await clockAdvances()) {
      steps.push(`loading screen closed (key ${DISMISS_KEYS[i]}, press ${i + 1}); game time advances`);
      return true;
    }
    steps.push(`dismiss ${i + 1}: game time not advancing after ${DISMISS_KEYS[i]}`);
  }
  await setPaused(true).catch(() => undefined);
  return false;
}

/** Accept a display name or a file name (FrostPunk2SaveGame9); the game loads by display name. */
export function resolveSaveName(name: string): string {
  const file = join(SAVE_DIR, `${name}.sav`);
  return existsSync(file) ? saveDisplayName(file) ?? name : name;
}

/**
 * Session start and crash recovery in one call. In a loaded game it loads `name` in place, or only pauses when
 * no name is given. Otherwise it launches the
 * game if needed and loads `name` (or the newest recovery candidate). When a load crashes the game, the game is
 * killed and another load is tried, up to `maxAttempts` loads. A crash during the quiet phase (no game-thread
 * calls) marks the save bad in .runtime/bad-saves.json and moves to the next candidate; a crash after it does
 * not mark the save. A failure that is not a crash (load refused, timeout) stops at once.
 */
export async function recover(name: string | undefined, timeoutMs: number, maxAttempts = RECOVER_MAX_ATTEMPTS) {
  const steps: string[] = [];
  if ((await readStatus()).alive && (await waitReady(5_000).then(() => true, () => false))) {
    // In the world but possibly behind a stuck "COMPILING SHADERS" screen (input blocked): clear it first.
    const fixed: { stuck: boolean; unstuck?: boolean } = await unstick(steps);
    if (fixed.stuck && !fixed.unstuck) throw new BridgeError(`in a loaded game, but the shader-compilation screen is stuck and unstick failed: ${steps.join("; ")}`);
    if (fixed.stuck) await dismissLoadingScreen(steps);
    if (name) {
      // A named save in a loaded game: load it in place (LoadGame works in the world; measured). The old behaviour
      // only paused and left the current state, which silently skipped the requested reset (measured 2026-10-11).
      const save = resolveSaveName(name);
      steps.push(`in a loaded game: loading ${save}`);
      const r = await loadOnce(save, timeoutMs, steps, true);
      if (r.ok) return { recovered: true, save, attempts: 1, inGameLoad: true, steps, time: r.time, brief: await brief() };
      throw new BridgeError(`recover: loading ${save} from the running game failed: ${r.reason}${r.crashed ? " (game crashed; run fp2 recover again to relaunch)" : ""}`);
    }
    const t = await setPaused(true);
    return { recovered: false, reason: "already in a loaded game (pass name=<save> to load one)", ...(fixed.stuck ? { unstuck: true } : {}), steps, time: t, brief: await brief() };
  }
  const failed: { save: string; crashed: boolean; markedBad: boolean; reason: string }[] = [];
  const tried = new Set<string>();
  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    const save = attempt === 1 && name ? resolveSaveName(name) : recoveryCandidates(tried)[0];
    if (!save) break;
    if (!(await readStatus()).alive) {
      await launchGame(timeoutMs);
      steps.push(`attempt ${attempt}: launched`);
      await sleep(3000);
    }
    steps.push(`attempt ${attempt}: ${save}`);
    const r = await loadOnce(save, timeoutMs, steps);
    if (r.ok) return { recovered: true, save, attempts: attempt, ...(failed.length ? { failed } : {}), steps, time: r.time, brief: await brief() };
    const markedBad = r.crashed && r.quiet === true;
    failed.push({ save, crashed: r.crashed, markedBad, reason: r.reason });
    if (!r.crashed) break; // game state unknown: do not load another save over it
    if (markedBad) {
      markBadSave(save, r.reason);
      tried.add(save);
    }
    await killGame();
    steps.push(`attempt ${attempt}: crashed${markedBad ? `, ${save} marked bad` : " after the quiet period (save not marked)"}, game killed`);
  }
  if (!failed.length) throw new BridgeError("no recovery save found (agent-rolling*, agent-*, AutoSave*; bad saves skipped, see .runtime/bad-saves.json); pass name=<save>");
  throw new BridgeError(`recover failed after ${failed.length} load attempt(s): ${failed.map((f) => `${f.save}: ${f.reason}`).join(" | ")}`);
}
