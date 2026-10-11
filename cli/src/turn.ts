// `fp2 turn`: one play turn. Resume time, run until a stop event or the heartbeat, pause, and
// return everything the agent needs for its next decision in one object: what changed, what is
// due from the goal stack, and the brief. Events are also appended to .runtime/watch.jsonl.
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, call, readStatus, repoRoot } from "./bridge";
import { brief } from "./brief";
import { goalView } from "./goals";
import { TICKS_PER_WEEK, setPaused, setSpeed, sleep, userPaused } from "./game";
import { diff, facts, isAckOnly, type WatchEvent } from "./watch";

// Lua encodes empty tables as {}; treat anything non-array as empty.
const asArray = (v: unknown): any[] => (Array.isArray(v) ? v : []);

/** Event kinds that end a turn. stock.runway counts only under 10 weeks; council only when a session opens. */
export const STOP_DEFAULT = [
  "dialog.opened",
  "dialog.ackFailed",
  "deaths.increased",
  "need.deficit",
  "stock.runway",
  "research.finished",
  "construction.finished",
  "council.sessionAvailable.changed",
  "exploration.finished",
  "temperature.changed",
  "building.unlocked",
  "ability.available",
  "district.deactivated",
  "homeless.changed",
];

/** Logged to watch.jsonl but not returned inline: high volume, low decision value. */
const NOISE = new Set(["icons.changed", "game.paused", "game.resumed", "ui.pauseReasons.changed", "stock.recovered", "dialog.closed", "stat.falling", "exploration.progress", "construction.state", "research.active.changed"]);

const STOP_RUNWAY_WEEKS = 10;

function isStop(e: WatchEvent, stopOn: Set<string>): boolean {
  if (!stopOn.has(e.kind)) return false;
  const d: any = e.detail ?? {};
  if (e.kind === "stock.runway") return typeof d.weeksLeftUnder === "number" && d.weeksLeftUnder <= STOP_RUNWAY_WEEKS;
  if (e.kind === "council.sessionAvailable.changed") return d.to === true;
  if (e.kind === "homeless.changed") return d.to === true;
  return true;
}

function watcherPid(): number | null {
  const pidFile = join(repoRoot(), ".runtime", "watch.pid");
  if (!existsSync(pidFile)) return null;
  const pid = readFileSync(pidFile, "utf8").trim();
  return Bun.spawnSync(["tasklist", "/FI", `PID eq ${pid}`]).stdout.toString().includes(pid) ? Number(pid) : null;
}

export type TurnOptions = {
  weeks: number;
  stopOn: Set<string>;
  speed?: number;
  saveEveryWeeks: number;
  saveName: string;
  autoAck: boolean;
  intervalMs: number;
  timeoutMs: number;
};

export async function turn(opts: TurnOptions) {
  const st = await readStatus();
  if (!st.alive) throw new BridgeError(`bridge not alive (${st.reason}); run fp2 recover`);
  const rt = join(repoRoot(), ".runtime");
  mkdirSync(rt, { recursive: true });
  const log = join(rt, "watch.jsonl");
  const warnings: string[] = [];
  const wp = watcherPid();
  if (wp) warnings.push(`detached watcher running (pid ${wp}); it also auto-pauses and acks. fp2 watch-stop to avoid double handling`);

  let s: any = await call("snapshot", {}, 60_000);
  const fromTicks = Number(s.date?.ticks ?? 0);
  const fromWeek = s.date?.week;
  const blocking = asArray(s.pauseReasons).filter((r: string) => r !== "UserPaused" && r !== "SavingGame");
  const open = { modals: Array.isArray(s.modals) ? s.modals.filter((m: any) => (m.choices ?? []).length > 0).length : 0 };
  const goals = () => goalView(s.date?.week);
  if (blocking.length || open.modals) {
    // Something already needs the agent (a modal, a cutscene): do not resume time.
    return { turn: { fromWeek, toWeek: fromWeek, date: s.date?.date, advancedWeeks: 0, stoppedBy: { reason: blocking.join(", ") || "modal open", kinds: [] } }, events: [], dropped: {}, goals: goals(), brief: await brief(), warnings };
  }

  const emit = (e: object) => appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, ...e }) + "\n");
  if (opts.speed) await setSpeed(opts.speed);
  await setPaused(false);
  emit({ kind: "turn.started", detail: { weeks: opts.weeks, stopOn: [...opts.stopOn] } });

  let prev = facts(s);
  let lastSaveTicks = fromTicks;
  const returned: unknown[] = [];
  const dropped: Record<string, number> = {};
  let stoppedBy: { reason: string; kinds: string[] } | null = null;
  let pauseGraceUsed = false;
  const deadline = Date.now() + opts.timeoutMs;

  try {
    await runLoop();
  } catch (e) {
    // Never leave the game running on a CLI failure: a bug here once cost two unattended in-game weeks.
    await setPaused(true).catch(() => undefined);
    emit({ kind: "turn.failed", detail: String(e) });
    throw e;
  }

  async function runLoop() {
  while (!stoppedBy) {
    await sleep(opts.intervalMs);
    try {
      s = await call("snapshot", {}, 60_000);
    } catch (e) {
      stoppedBy = { reason: `bridge.error: ${String(e)}`, kinds: ["bridge.error"] };
      break;
    }
    const next = facts(s);
    let events = diff(prev, next, s).filter((e) => !(e.kind === "stock.runway" && (e.detail as any).weeksLeftUnder === null));
    prev = next;

    let pauseReasons: string[] = asArray(s.pauseReasons);
    if (opts.autoAck) {
      const acked: any[] = [];
      events = events.filter((e) => {
        if (e.kind !== "dialog.opened" || !isAckOnly(e.detail)) return true;
        acked.push(e.detail);
        return false;
      });
      for (const d of acked) {
        const err = await call("choose", { index: 0, ref: d.ref }).then(() => undefined, (e) => String(e));
        events.push(err ? { kind: "dialog.ackFailed", detail: { ...d, error: err } } : { kind: "dialog.acknowledged", detail: d });
      }
      // The snapshot predates the ack; re-read pause reasons so a dismissed "I see" does not end the turn.
      if (acked.length) pauseReasons = asArray((await call<any>("extract", { name: "time" }).catch(() => ({ pauseReasons }))).pauseReasons);
    }

    for (const e of events) {
      emit(e);
      if (NOISE.has(e.kind)) dropped[e.kind] = (dropped[e.kind] ?? 0) + 1;
      else returned.push({ week: s.date?.week, date: s.date?.date, ...e });
    }

    const ticks = Number(s.date?.ticks ?? fromTicks);
    const stops = events.filter((e) => isStop(e, opts.stopOn)).map((e) => e.kind);
    const reasons = pauseReasons.filter((r) => r !== "SavingGame");
    // The game pauses itself (player pause flag) a moment before an event dialog registers (measured: two
    // "UserPaused" stops with no human present, each followed by a story dialog). Re-poll once before
    // reporting a bare UserPaused so the dialog arrives as a stop event.
    const bareUserPause = !stops.length && reasons.length > 0 && reasons.every((r) => r === "UserPaused");
    if (bareUserPause && !pauseGraceUsed) {
      pauseGraceUsed = true;
      await sleep(1500);
      continue;
    }
    if (stops.length) stoppedBy = { reason: "event", kinds: [...new Set(stops)] };
    else if (reasons.length) stoppedBy = { reason: reasons.join(", "), kinds: [] }; // modal, cutscene, or the human paused
    else if (ticks - fromTicks >= opts.weeks * TICKS_PER_WEEK) stoppedBy = { reason: "heartbeat", kinds: [] };
    else if (Date.now() > deadline) stoppedBy = { reason: "timeout", kinds: [] };

    if (opts.saveEveryWeeks > 0 && ticks - lastSaveTicks >= opts.saveEveryWeeks * TICKS_PER_WEEK) {
      const r = await call("save", { name: opts.saveName, override: true }).then((x) => ({ ok: true, x }), (e) => ({ ok: false, x: String(e) }));
      emit({ kind: r.ok ? "watch.saved" : "watch.saveFailed", detail: { name: opts.saveName, result: r.x } });
      lastSaveTicks = ticks;
    }
  }
  }

  // End paused by the player so the game stays still while the agent thinks, even after a modal closes.
  try {
    const t = await call<any>("extract", { name: "time" });
    if (!userPaused(t)) await setPaused(true);
  } catch (e) {
    warnings.push(`could not pause at turn end: ${String(e)}`);
  }
  emit({ kind: "turn.ended", detail: stoppedBy });
  const toTicks = Number(s.date?.ticks ?? fromTicks);
  return {
    turn: { fromWeek, toWeek: s.date?.week, date: s.date?.date, advancedWeeks: Math.round(((toTicks - fromTicks) / TICKS_PER_WEEK) * 100) / 100, stoppedBy },
    events: returned,
    dropped,
    goals: goals(),
    brief: await brief(),
    ...(warnings.length ? { warnings } : {}),
  };
}
