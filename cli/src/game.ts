// Shared game-time helpers: clock, player pause, readiness, cutscene checks.
import { BridgeError, call, readStatus } from "./bridge";

export const TICKS_PER_WEEK = 1680;
export const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

export type TimeInfo = { paused: boolean; pauseReasons?: string[]; speed?: string; gameTimeTicks?: number; gameplayBegan?: boolean };
// Lua encodes an empty list as {}; normalize so callers can treat pauseReasons as an array.
export const time = async (): Promise<TimeInfo> => {
  const t = await call<TimeInfo>("extract", { name: "time" });
  t.pauseReasons = Array.isArray(t.pauseReasons) ? t.pauseReasons : [];
  return t;
};

// "UserPaused" is the player's toggle; other reasons (modals, tutorial logs) clear themselves
// when the UI closes, so they must not count as "paused by us".
export const userPaused = (t: TimeInfo) => (t.pauseReasons ?? []).includes("UserPaused");
export const cutsceneReason = (t: TimeInfo) => (t.pauseReasons ?? []).find((r) => /Cutscene/i.test(r));

export async function setPaused(want: boolean): Promise<TimeInfo> {
  // Uses PXTimeUtils.SetPausedByPlayer through the bridge (no keystrokes, works unfocused).
  await call(want ? "game.pause" : "game.resume");
  const t = await time();
  if (userPaused(t) !== want) throw new BridgeError(`pause state not applied (reasons=${(t.pauseReasons ?? []).join(",")})`);
  const others = (t.pauseReasons ?? []).filter((r) => r !== "UserPaused");
  if (!want && others.length) (t as any).warning = `still paused by UI: ${others.join(", ")}`;
  return t;
}

export async function setSpeed(level: number) {
  if (![1, 2, 3].includes(level)) throw new BridgeError("speed needs 1, 2 or 3");
  await call("game.speed", { level: level - 1 });
}

/** True once a city exists and gameplay began (after load / new game). */
export async function isReady(): Promise<{ ready: boolean; detail: unknown }> {
  try {
    const t = await time();
    const cities = await call<any>("find_all", { class: "PXCityComponent", limit: 1 });
    return { ready: Boolean(t.gameplayBegan) && cities.total > 0, detail: { gameplayBegan: t.gameplayBegan, cities: cities.total } };
  } catch (e) {
    return { ready: false, detail: String(e) };
  }
}

export async function waitReady(timeoutMs: number): Promise<TimeInfo> {
  const deadline = Date.now() + timeoutMs;
  let last: unknown = null;
  while (Date.now() < deadline) {
    const r = await isReady();
    last = r.detail;
    if (r.ready) return time();
    await sleep(1000);
  }
  throw new BridgeError(`not ready: ${JSON.stringify(last)}`);
}

export async function waitAlive(timeoutMs: number) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const st = await readStatus();
    if (st.alive) return st;
    await sleep(2000);
  }
  throw new BridgeError("game/bridge did not come up in time");
}

/**
 * Named UI conditions for `wait-for` and the `wait=` option of click/keys/hold.
 * modal | no-modal | council | no-council | cutscene | no-cutscene | paused | running | ready |
 * reason:<substr> | no-reason:<substr>
 */
export async function waitFor(cond: string, timeoutMs: number) {
  const started = Date.now();
  const deadline = started + timeoutMs;
  let last: unknown = null;
  const check = async (): Promise<boolean> => {
    if (cond === "ready") return (await isReady()).ready;
    const t = await time();
    const reasons = t.pauseReasons ?? [];
    last = { pauseReasons: reasons };
    if (cond.startsWith("reason:")) return reasons.some((r) => r.includes(cond.slice(7)));
    if (cond.startsWith("no-reason:")) return !reasons.some((r) => r.includes(cond.slice(10)));
    switch (cond) {
      case "cutscene":
        return Boolean(cutsceneReason(t));
      case "no-cutscene":
        return !cutsceneReason(t);
      case "paused":
        return userPaused(t);
      case "running":
        return reasons.length === 0;
      case "modal":
      case "no-modal": {
        const modals = await call<any[]>("modals").catch(() => []);
        const open = Array.isArray(modals) && modals.length > 0;
        last = { pauseReasons: reasons, modals: open };
        return cond === "modal" ? open : !open;
      }
      case "council":
      case "no-council": {
        const c = await call<any>("council").catch(() => ({}));
        last = { pauseReasons: reasons, inParliament: c.inParliament };
        return cond === "council" ? Boolean(c.inParliament) : !c.inParliament;
      }
      default:
        throw new BridgeError(`unknown wait condition '${cond}' (modal, no-modal, council, no-council, cutscene, no-cutscene, paused, running, ready, reason:X, no-reason:X)`);
    }
  };
  for (;;) {
    if (await check()) return { met: cond, waitedMs: Date.now() - started, ...(last as object) };
    if (Date.now() >= deadline) throw new BridgeError(`wait-for '${cond}' timed out after ${timeoutMs / 1000}s: ${JSON.stringify(last)}`);
    await sleep(500);
  }
}
