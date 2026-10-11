// Goal stack: the agent's long-term aims, short-term targets and lead-time checks.
// Stored as .runtime/goals.jsonl (one JSON object per line) so it survives context compaction
// and crashes, and so a human or agent can edit it by hand in a pinch.
import { appendFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { BridgeError, repoRoot } from "./bridge";

export type Horizon = "long" | "short" | "check";
export type Goal = {
  id: number;
  horizon: Horizon;
  text: string;
  /** In-game week by which the goal should be checked or reached. */
  due?: number;
  /** What the agent expects to observe when it checks (lead-time promise). */
  expect?: string;
  addedWeek?: number;
  addedDate?: string;
  done?: boolean;
  doneWeek?: number;
  note?: string;
};

const HORIZONS: Horizon[] = ["long", "short", "check"];

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

/** Open goals, and those whose due week has arrived. */
export function goalView(week?: number) {
  const { goals, invalidLines } = loadGoals();
  const open = goals.filter((g) => !g.done);
  const due = typeof week === "number" ? open.filter((g) => typeof g.due === "number" && g.due <= week) : [];
  return { open, due, file: goalsPath(), ...(invalidLines ? { invalidLines } : {}) };
}

export function addGoal(input: { text: string; horizon?: string; due?: number; expect?: string }, now?: { week?: number; date?: string }): Goal {
  if (!input.text) throw new BridgeError("goals add needs text=...");
  const horizon = (input.horizon ?? "short") as Horizon;
  if (!HORIZONS.includes(horizon)) throw new BridgeError(`horizon must be one of ${HORIZONS.join(", ")}`);
  const { goals } = loadGoals();
  const g: Goal = { id: goals.reduce((m, x) => Math.max(m, x.id), 0) + 1, horizon, text: input.text };
  if (typeof input.due === "number") g.due = input.due;
  if (input.expect) g.expect = input.expect;
  if (now?.week !== undefined) g.addedWeek = now.week;
  if (now?.date) g.addedDate = now.date;
  appendFileSync(goalsPath(), JSON.stringify(g) + "\n");
  return g;
}

export function updateGoal(id: number, patch: Partial<Goal>): Goal {
  const { goals } = loadGoals();
  const g = goals.find((x) => x.id === id);
  if (!g) throw new BridgeError(`no goal with id ${id}`);
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
