// Goal stack: the agent's long-term aims, short-term targets and lead-time checks.
// Stored as .runtime/goals.jsonl (one JSON object per line) so it survives context compaction
// and crashes, and so a human or agent can edit it by hand in a pinch.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, repoRoot } from "./bridge";

/**
 * long: the scenario aim. short: a city target. check: a lead-time promise judged at `due`.
 * threat: a warned future danger (whiteout, storm, unrest); `due` is the expected arrival week and is required,
 * because a threat goal without one was never re-read and a whiteout killed 40 (measured).
 */
export type Horizon = "long" | "short" | "check" | "threat";
export type Goal = {
  id: number;
  horizon: Horizon;
  text: string;
  /** In-game week by which the goal should be checked or reached. */
  due?: number;
  /** What the agent expects to observe when it checks (lead-time promise). */
  expect?: string;
  /**
   * Rank in the stack, 1 = first. The agent sets it explicitly; threats require it so a whiteout warning is an
   * explicit decision to put survival ahead of long-horizon plans, not one more line in the list.
   */
  priority?: number;
  addedWeek?: number;
  addedDate?: string;
  done?: boolean;
  doneWeek?: number;
  note?: string;
};

const HORIZONS: Horizon[] = ["long", "short", "check", "threat"];
// Stack order among goals of equal priority: nearest danger first, the scenario aim last.
const HORIZON_RANK: Record<Horizon, number> = { threat: 0, check: 1, short: 2, long: 3 };

/** Explicit priority first (1 before 2; unset last), then horizon, then the nearer due week. */
export function stackOrder(a: Goal, b: Goal): number {
  const pa = a.priority ?? Infinity;
  const pb = b.priority ?? Infinity;
  if (pa !== pb) return pa - pb;
  const ha = HORIZON_RANK[a.horizon] ?? 9;
  const hb = HORIZON_RANK[b.horizon] ?? 9;
  if (ha !== hb) return ha - hb;
  return (a.due ?? Infinity) - (b.due ?? Infinity);
}

export function goalsPath(): string {
  return join(repoRoot(), ".runtime", "goals.jsonl");
}

export function loadGoals(): { goals: Goal[]; invalidLines: number } {
  const p = goalsPath();
  if (!existsSync(p)) return { goals: [], invalidLines: 0 };
  const goals: Goal[] = [];
  let invalidLines = 0;
  for (const line of readFileSync(p, "utf8").split(/\r?\n/)) {
    if (!line.trim()) continue;
    try {
      const g = JSON.parse(line);
      if (typeof g?.id === "number" && typeof g?.text === "string") goals.push(g);
      else invalidLines++;
    } catch {
      invalidLines++;
    }
  }
  return { goals, invalidLines };
}

function saveGoals(goals: Goal[]) {
  mkdirSync(join(repoRoot(), ".runtime"), { recursive: true });
  // Full rewrite keeps the file one-object-per-line and hand-editable.
  writeFileSync(goalsPath(), goals.map((g) => JSON.stringify(g)).join("\n") + (goals.length ? "\n" : ""));
}

/**
 * Open goals, those whose due week has arrived, and every open threat (always listed, with weeks left, so a
 * warned danger stays in view on each turn instead of only on its due week).
 */
export function goalView(week?: number) {
  const { goals, invalidLines } = loadGoals();
  const open = goals.filter((g) => !g.done).sort(stackOrder);
  const due = typeof week === "number" ? open.filter((g) => typeof g.due === "number" && g.due <= week) : [];
  const threats = open
    .filter((g) => g.horizon === "threat")
    .map((g) => ({ ...g, ...(typeof week === "number" && typeof g.due === "number" ? { weeksLeft: g.due - week } : {}) }));
  // The goal the next decision serves: top of the ordered stack.
  const focus = open.length ? { id: open[0].id, horizon: open[0].horizon, priority: open[0].priority, text: open[0].text } : null;
  return { focus, open, due, threats, file: goalsPath(), ...(invalidLines ? { invalidLines } : {}) };
}

/** The nearest open due week after `week` (undefined when none): `turn` never runs past it. */
export function nextDueWeek(week: number): { id: number; due: number; horizon: Horizon } | undefined {
  const open = loadGoals().goals.filter((g) => !g.done && typeof g.due === "number" && (g.due as number) > week);
  if (!open.length) return undefined;
  const g = open.reduce((m, x) => ((x.due as number) < (m.due as number) ? x : m));
  return { id: g.id, due: g.due as number, horizon: g.horizon };
}

export function addGoal(input: { text: string; horizon?: string; due?: number; expect?: string; priority?: number }, now?: { week?: number; date?: string }): Goal {
  if (!input.text) throw new BridgeError("goals add needs text=...");
  const horizon = (input.horizon ?? "short") as Horizon;
  if (!HORIZONS.includes(horizon)) throw new BridgeError(`horizon must be one of ${HORIZONS.join(", ")}`);
  if (horizon === "threat" && (typeof input.due !== "number" || !input.expect || typeof input.priority !== "number")) {
    throw new BridgeError("horizon=threat needs due=<expected arrival week>, expect=\"..\" (what prepared looks like) and priority=<rank, 1 = first>: a whiteout is a catastrophe, so decide where it sits in the stack and what it defers; a threat goal without a due week was never re-read and a whiteout killed 40");
  }
  if (input.priority !== undefined && !(Number.isInteger(input.priority) && input.priority >= 1)) throw new BridgeError("priority is an integer >= 1 (1 = first)");
  const { goals } = loadGoals();
  const g: Goal = { id: goals.reduce((m, x) => Math.max(m, x.id), 0) + 1, horizon, text: input.text };
  if (typeof input.due === "number") g.due = input.due;
  if (input.expect) g.expect = input.expect;
  if (typeof input.priority === "number") g.priority = input.priority;
  if (now?.week !== undefined) g.addedWeek = now.week;
  if (now?.date) g.addedDate = now.date;
  appendFileSync(goalsPath(), JSON.stringify(g) + "\n");
  return g;
}

export function updateGoal(id: number, patch: Partial<Goal>): Goal {
  const { goals } = loadGoals();
  const g = goals.find((x) => x.id === id);
  if (!g) throw new BridgeError(`no goal with id ${id}`);
  const merged = { ...g, ...patch };
  if (merged.horizon === "threat" && !merged.done && typeof merged.due !== "number") throw new BridgeError("a threat goal keeps a due week; edit due=<week> or mark it done");
  Object.assign(g, patch);
  saveGoals(goals);
  return g;
}

export function removeGoal(id: number): Goal {
  const { goals } = loadGoals();
  const i = goals.findIndex((x) => x.id === id);
  if (i < 0) throw new BridgeError(`no goal with id ${id}`);
  const [g] = goals.splice(i, 1);
  saveGoals(goals);
  return g;
}
