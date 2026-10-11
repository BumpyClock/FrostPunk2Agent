// `fp2 launch` and `fp2 recover`: start the game, load a save from the main menu, and fall back to older
// saves when a load crashes the game.
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, call, loadQuietLeftMs, readStatus } from "./bridge";
import { brief } from "./brief";
import { isReady, setPaused, sleep, waitAlive, waitReady } from "./game";
import { SAVE_DIR, markBadSave, recoveryCandidates, saveDisplayName } from "./saves";
import { sendKeys } from "./win32";

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

/** `quiet`: the crash happened while no game-thread calls were made, so the save itself is suspect. */
type Attempt = { ok: true; time: unknown } | { ok: false; crashed: boolean; quiet?: boolean; reason: string };

// One load from the main menu. Measured sequence: Enter on the title screen, ForceLoadGame through the bridge
// (retried: the save subsystem is not ready at once), wait until a city exists, Space to close the loading
// screen, then the player pause. After the load is issued, no game-thread call is made until the post-load quiet
// period ends (LOAD_QUIET_MS in bridge.ts): polling during a load crashed the game in Wwise (measured).
// Reports a crash when the game process exits, a new crash report appears, the crash reporter starts, or the
// heartbeat stops for LOAD_HEARTBEAT_STALE_MS.
async function loadOnce(save: string, timeoutMs: number, steps: string[]): Promise<Attempt> {
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

  await sendKeys(["enter"], true); // "press any key" title screen (harmless in the menu)
  steps.push("title dismissed");
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
  for (;;) {
    const c = await crashed();
    if (c) return { ok: false, crashed: true, quiet: false, reason: `${c} (after the quiet period, while polling)` };
    if ((await isReady()).ready) break;
    if (Date.now() > deadline) return { ok: false, crashed: false, reason: `${save} did not finish loading within ${timeoutMs / 1000}s after the quiet period` };
    await sleep(5000);
  }
  await sendKeys(["space"], true); // closes the loading screen (measured)
  await sleep(2000);
  const time = await setPaused(true);
  steps.push("ready, paused");
  return { ok: true, time };
}

/** Accept a display name or a file name (FrostPunk2SaveGame9); the game loads by display name. */
export function resolveSaveName(name: string): string {
  const file = join(SAVE_DIR, `${name}.sav`);
  return existsSync(file) ? saveDisplayName(file) ?? name : name;
}

/**
 * Session start and crash recovery in one call. In a loaded game it only pauses. Otherwise it launches the
 * game if needed and loads `name` (or the newest recovery candidate). When a load crashes the game, the game is
 * killed and another load is tried, up to `maxAttempts` loads. A crash during the quiet phase (no game-thread
 * calls) marks the save bad in .runtime/bad-saves.json and moves to the next candidate; a crash after it does
 * not mark the save. A failure that is not a crash (load refused, timeout) stops at once.
 */
export async function recover(name: string | undefined, timeoutMs: number, maxAttempts = RECOVER_MAX_ATTEMPTS) {
  const steps: string[] = [];
  if ((await readStatus()).alive && (await waitReady(5_000).then(() => true, () => false))) {
    const t = await setPaused(true);
    return { recovered: false, reason: "already in a loaded game", steps, time: t, brief: await brief() };
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
