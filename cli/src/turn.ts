// `fp2 turn`: one play turn. Resume time, run until a stop event or the heartbeat, pause, and
// return everything the agent needs for its next decision in one object: what changed, what is
// due from the goal stack, and the brief. Events are also appended to .runtime/watch.jsonl.
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, call, readStatus, repoRoot } from "./bridge";
import { brief } from "./brief";
import { goalView, nextDueWeek } from "./goals";
import { nextRollingSlot } from "./saves";
import { TICKS_PER_WEEK, setPaused, setSpeed, sleep, userPaused } from "./game";
import { diff, facts, isAckOnly, researchIdle, type WatchEvent } from "./watch";

// Lua encodes empty tables as {}; treat anything non-array as empty.
const asArray = (v: unknown): any[] => (Array.isArray(v) ? v : []);

/** Event kinds that end a turn. stock.runway counts only under 10 weeks; council only when a session opens. */
export const STOP_DEFAULT = [
  "dialog.opened",
  "dialog.ackFailed",
  // A one-option story warning (whiteout, storm, unrest) is acknowledged but still stops the turn.
  "threat.warning",
  "deaths.increased",
  "need.deficit",
  "stock.runway",
  "research.finished",
  // Research went idle with nothing queued (measured: it sat idle for weeks, unflagged).
  "research.idle",
  "construction.finished",
  "council.sessionAvailable.changed",
  "exploration.finished",
  "temperature.changed",
  // building.unlocked / ability.available arrive with research.finished or construction.finished,
  // which already stop; they are still returned as events.
  "district.deactivated",
  "deposit.depleting",
  // Forecast strip warnings (once per forecast entry); forecastDrop stops only for big or severe drops.
  "weather.forecastDrop",
  "whiteout.incoming",
  "homeless.changed",
];

/** Logged to watch.jsonl but not returned inline: high volume, low decision value. */
const NOISE = new Set(["icons.changed", "game.paused", "game.resumed", "ui.pauseReasons.changed", "stock.recovered", "dialog.closed", "stat.falling", "exploration.progress", "construction.state", "research.active.changed"]);

const STOP_RUNWAY_WEEKS = 10;
const STOP_DEPOSIT_WEEKS = 10;

const levelNum = (v: unknown) => Number(String(v ?? "").match(/(\d+)$/)?.[1] ?? 0);

/** Temperature level at or below which the city is in a crisis (TemperatureLevel4 was a whiteout, measured). */
const CRISIS_LEVEL = 3;
const CRISIS_WEEKS = 1;

/** A compact weather line for the turn result: what the HUD forecast strip shows, or why it could not be read. */
export function weatherSummary(w: any) {
  if (!w) return { known: false };
  if (w.error || w.timelineError) return { known: false, error: w.error ?? w.timelineError, level: w.current?.level, degrees: w.current?.degrees };
  const forecast: any[] = Array.isArray(w.forecast) ? w.forecast : [];
  let prev = Number(w.current?.level);
  let nextDrop: { inWeeks: number; level: number; degrees?: number } | undefined;
  for (const f of [...forecast].sort((a, b) => Number(a?.atTicks) - Number(b?.atTicks))) {
    if (typeof f?.level !== "number") continue;
    if (!nextDrop && Number.isFinite(prev) && f.level > prev && typeof f.weeksFromNow === "number") nextDrop = { inWeeks: f.weeksFromNow, level: f.level, degrees: f.degrees };
    prev = f.level;
  }
  const wo = w.whiteout ?? {};
  return {
    known: true,
    level: w.current?.level,
    degrees: w.current?.degrees,
    horizonWeeks: w.horizonWeeks,
    ...(nextDrop ? { nextDrop } : {}),
    whiteout: wo.known ? { active: Boolean(wo.active), ...(wo.startsInWeeks !== undefined ? { startsInWeeks: wo.startsInWeeks } : {}), ...(wo.endsInWeeks !== undefined ? { endsInWeeks: wo.endsInWeeks } : {}) } : "unknown",
    // "Calm" (level 0) is the no-storm reading; only a real storm is worth a line.
    ...(w.storm && Number(w.storm.level) >= 1 ? { storm: w.storm } : {}),
  };
}

/** True when the city is in a cold crisis: an active whiteout or a temperature level at CRISIS_LEVEL or colder. */
export function inCrisis(s: any): string | null {
  if (s?.weather?.whiteout?.known && s.weather.whiteout.active) return "whiteout active";
  const lvl = levelNum(asArray(s?.population)[0]?.temperatureLevel);
  if (lvl >= CRISIS_LEVEL) return `temperature level ${lvl}`;
  return null;
}

function isStop(e: WatchEvent, stopOn: Set<string>): boolean {
  if (!stopOn.has(e.kind)) return false;
  const d: any = e.detail ?? {};
  if (e.kind === "stock.runway") return typeof d.weeksLeftUnder === "number" && d.weeksLeftUnder <= STOP_RUNWAY_WEEKS;
  if (e.kind === "deposit.depleting") return typeof d.weeksLeftUnder === "number" && d.weeksLeftUnder <= STOP_DEPOSIT_WEEKS;
  if (e.kind === "weather.forecastDrop") return typeof d.level === "number" && (d.level - Number(d.from) >= 2 || d.level >= 3);
  if (e.kind === "council.sessionAvailable.changed") return d.to === true;
  if (e.kind === "homeless.changed") return d.to === true;
  // The agent's own toggles (PlayerChoice) are not news; a game-caused stop (NoDeposit, ...) is.
  if (e.kind === "district.deactivated") return !(Array.isArray(d.reasons) && d.reasons.every((r: string) => r === "PlayerChoice"));
  // Only a drop to a colder level threatens the city (TemperatureLevel number rises as it gets colder).
  if (e.kind === "temperature.changed") return levelNum(d.to) > levelNum(d.from);
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
  /** weeks came from the CLI default, so a crisis may shorten it; an explicit weeks= is kept. */
  weeksDefaulted?: boolean;
  stopOn: Set<string>;
  speed?: number;
  saveEveryWeeks: number;
  /** Prefix of the rotating save slots (<saveName>-a/-b/-c). */
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
    return { turn: { fromWeek, toWeek: fromWeek, date: s.date?.date, advancedWeeks: 0, stoppedBy: { reason: blocking.join(", ") || "modal open", kinds: [] } }, events: [], dropped: {}, goals: goals(), brief: await brief({ weather: s.weather, research: s.research }), weather: weatherSummary(s.weather), warnings };
  }

  // Turn length. Never run past the nearest open goal's due week, so a check or threat is judged exactly when the
  // agent said it would be (a threat goal that was only read on its due week, 70 weeks on, was never read: 40 died).
  // In a cold crisis the default length drops to CRISIS_WEEKS: a weeks=2 turn that overran to 5.5 weeks mid-whiteout
  // let food fall to 2 weeks (measured). An explicit weeks= is respected.
  let weeks = opts.weeks;
  let capped: { by: string; weeks: number } | null = null;
  const crisis = inCrisis(s);
  if (crisis && opts.weeksDefaulted && weeks > CRISIS_WEEKS) {
    weeks = CRISIS_WEEKS;
    capped = { by: `crisis (${crisis})`, weeks };
    warnings.push(`cold crisis (${crisis}): turn shortened to ${CRISIS_WEEKS} week; pass weeks=N to override`);
  }
  const nextDue = typeof fromWeek === "number" ? nextDueWeek(fromWeek) : undefined;
  if (nextDue && nextDue.due - (fromWeek as number) < weeks) {
    weeks = Math.max(0.25, nextDue.due - (fromWeek as number));
    capped = { by: `goal ${nextDue.id} (${nextDue.horizon}) due week ${nextDue.due}`, weeks };
  }

  const emit = (e: object) => appendFileSync(log, JSON.stringify({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, ...e }) + "\n");
  if (opts.speed) await setSpeed(opts.speed);
  await setPaused(false);
  emit({ kind: "turn.started", detail: { weeks, requestedWeeks: opts.weeks, capped, stopOn: [...opts.stopOn] } });

  let prev = facts(s);
  let lastSaveTicks = fromTicks;
  const returned: unknown[] = [];
  // Idle at turn start: report it (event + brief alert) but do not stop; the agent may have nothing it can start.
  if (researchIdle(s)) {
    const e = { kind: "research.idle", detail: { topic: null, atStart: true } };
    emit(e);
    returned.push({ week: s.date?.week, date: s.date?.date, ...e });
  }
  const dropped: Record<string, number> = {};
  let stoppedBy: { reason: string; kinds: string[] } | null = null;
  let pauseGraceUsed = false;
  const deadline = Date.now() + opts.timeoutMs;

  async function runLoop() {
  while (!stoppedBy) {
    heartbeatPaused = await pace();
    try {
      const t0 = Date.now();
      s = await call("snapshot", {}, 60_000);
      if (!heartbeatPaused) noteSample(Number(s.date?.ticks ?? sample.ticks), t0, Date.now());
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
        if (err) events.push({ kind: "dialog.ackFailed", detail: { ...d, error: err } });
        // A warning dialog is dismissed so the game is not blocked, but it is news that stops the turn.
        else if (d.threat) events.push({ kind: "threat.warning", detail: { ...d, source: "dialog" } });
        else events.push({ kind: "dialog.acknowledged", detail: d });
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
    // A story event sets the player pause flag, and its dialog widget is only created once time runs again
    // (measured: resuming showed "Venturers' Rallies Build Support" within 350 ms; waiting while paused never
    // did). So on a bare UserPaused, resume once and let the dialog appear as a stop event. A real player pause
    // ends the turn the second time.
    const bareUserPause = !heartbeatPaused && !stops.length && reasons.length > 0 && reasons.every((r) => r === "UserPaused");
    if (bareUserPause && !pauseGraceUsed) {
      pauseGraceUsed = true;
      warnings.push("game self-paused (story event); resumed once to let its dialog appear");
      await setPaused(false).catch(() => undefined);
      await sleep(1200);
      continue;
    }
    const heartbeat = capped?.by.startsWith("goal ") ? "goalDue" : "heartbeat";
    if (stops.length) stoppedBy = { reason: "event", kinds: [...new Set(stops)] };
    else if (heartbeatPaused && reasons.every((r) => r === "UserPaused")) stoppedBy = { reason: heartbeat, kinds: [] };
    else if (reasons.length) stoppedBy = { reason: reasons.join(", "), kinds: [] }; // modal, cutscene, or the human paused
    else if (ticks >= target) stoppedBy = { reason: heartbeat, kinds: [] };
    else if (Date.now() > deadline) stoppedBy = { reason: "timeout", kinds: [] };

    if (opts.saveEveryWeeks > 0 && ticks - lastSaveTicks >= opts.saveEveryWeeks * TICKS_PER_WEEK) {
      const name = nextRollingSlot(opts.saveName);
      const r = await call("save", { name, override: true }).then((x) => ({ ok: true, x }), (e) => ({ ok: false, x: String(e) }));
      emit({ kind: r.ok ? "watch.saved" : "watch.saveFailed", detail: { name, result: r.x } });
      lastSaveTicks = ticks;
    }
  }
  }

  // Pacing. Measured: speed 3 runs about 3.4 in-game weeks per real second, so a fixed 1.5 s poll let a
  // weeks=2 turn run 5.75 weeks before the first heartbeat check. The loop now estimates the clock rate and,
  // near the target, polls the cheap time extractor and pauses the game itself when the target is reached.
  const target = fromTicks + weeks * TICKS_PER_WEEK;
  let rate = 0; // ticks per ms while running
  let latMs = 150; // round trip of a light bridge call
  let sample = { ticks: fromTicks, at: Date.now() };
  let heartbeatPaused = false;
  const noteSample = (ticks: number, t0: number, t1: number) => {
    const at = (t0 + t1) / 2;
    const dt = at - sample.at;
    const r = dt > 150 && ticks > sample.ticks ? (ticks - sample.ticks) / dt : 0;
    if (r > 0 && (rate === 0 || r > rate * 0.5)) rate = r; // a save or UI pause can only lower a sample: ignore big drops
    sample = { ticks, at };
  };

  /** Sleep until the next poll. In the final stretch poll time and pause at the target; true if it paused. */
  async function pace(): Promise<boolean> {
    if (rate <= 0) {
      await sleep(Math.min(opts.intervalMs, 400)); // first poll is early: it measures the clock rate
      return false;
    }
    const etaMs = () => (target - sample.ticks) / rate - (Date.now() - sample.at);
    if (etaMs() > opts.intervalMs + 300) {
      await sleep(opts.intervalMs);
      return false;
    }
    for (let i = 0; i < 200; i++) {
      await sleep(Math.max(20, Math.min(300, etaMs() - 2 * latMs)));
      const t0 = Date.now();
      const t = await call<any>("extract", { name: "time" }).catch(() => null);
      const t1 = Date.now();
      if (!t) return false;
      latMs = Math.max(30, t1 - t0);
      const ticks = Number(t.gameTimeTicks);
      if (!Number.isFinite(ticks)) return false;
      const reasons = asArray(t.pauseReasons).filter((r: string) => r !== "SavingGame");
      noteSample(ticks, t0, t1);
      if (reasons.length) return false; // modal, cutscene or a human pause: the snapshot below reports it
      // Pause a little early: the pause call itself takes about one round trip, during which the clock still runs.
      if (ticks + rate * latMs >= target) {
        await call("game.pause").catch(() => undefined);
        return true;
      }
    }
    return false;
  }

  try {
    await runLoop();
  } catch (e) {
    // Never leave the game running on a CLI failure: a bug here once cost two unattended in-game weeks.
    await setPaused(true).catch(() => undefined);
    emit({ kind: "turn.failed", detail: String(e) });
    throw e;
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
    turn: { fromWeek, toWeek: s.date?.week, date: s.date?.date, advancedWeeks: Math.round(((toTicks - fromTicks) / TICKS_PER_WEEK) * 100) / 100, stoppedBy, ...(capped ? { capped } : {}) },
    events: returned,
    dropped,
    goals: goals(),
    brief: await brief({ weather: s.weather, research: s.research }),
    weather: weatherSummary(s.weather),
    ...(warnings.length ? { warnings } : {}),
  };
}
