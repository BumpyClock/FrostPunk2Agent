// `fp2 watch`: poll the bridge snapshot and print one JSON line per meaningful change.
// Designed to run under an agent's Monitor tool: quiet while nothing important happens.
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { call, repoRoot } from "./bridge";
import { nextRollingSlot } from "./saves";

type Snap = any;
export type WatchEvent = { kind: string; detail: unknown };

// Lua encodes empty tables as {}; treat anything non-array as empty.
const asArray = (v: unknown): any[] => (Array.isArray(v) ? v : []);
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const r1 = (n: number) => Math.round(n * 10) / 10;

// Statistics are reported in bands of 10 so slow drift does not spam events.
const band = (v: number) => Math.floor(v / 10) * 10;
// Stockpile runway thresholds in weeks.
const RUNWAY = [20, 10, 5, 2];
const runwayBucket = (weeks: number) => RUNWAY.find((t) => weeks < t) ?? Infinity;

// Deposit depletion: the game exposes only the remaining amount, so weeks left come from the amount trend between
// snapshots (a baseline sample is kept in .runtime/deposit-samples.json so a new `turn` process has history).
export const DEPOSIT_WEEKS = [20, 10, 5];
const DEPOSIT_MIN_WINDOW_TICKS = 840; // need half a week of data for a rate
const DEPOSIT_REBASE_TICKS = 5040; // move the baseline forward after 3 weeks, keeping its last estimate
const TICKS_WEEK = 1680;
type DepositSample = { ticks: number; amount: number; weeksLeft: number | null };
const depositInfo = new Map<string, { district: string; type: string; amount: number; weeksLeft: number | null }>();
let depositSamples: Map<string, DepositSample> | null = null;
const depositFile = () => join(repoRoot(), ".runtime", "deposit-samples.json");

function loadDepositSamples(): Map<string, DepositSample> {
  if (depositSamples) return depositSamples;
  depositSamples = new Map();
  try {
    if (existsSync(depositFile())) for (const [k, v] of Object.entries<DepositSample>(JSON.parse(readFileSync(depositFile(), "utf8")))) depositSamples.set(k, v);
  } catch {}
  return depositSamples;
}

function saveDepositSamples(m: Map<string, DepositSample>) {
  try {
    mkdirSync(join(repoRoot(), ".runtime"), { recursive: true });
    writeFileSync(depositFile(), JSON.stringify(Object.fromEntries(m)));
  } catch {}
}

/** Bucket of a deposit's remaining weeks: the smallest threshold above it, or "ok". */
const depositBucket = (weeks: number | null): number | "ok" => (weeks === null ? "ok" : (DEPOSIT_WEEKS.slice().reverse().find((t) => weeks < t) ?? "ok"));

/** Update trend samples from a snapshot's districtDeposits; returns key -> bucket for deposits a district works. */
function depositBuckets(s: Snap): Map<string, number | "ok"> {
  const out = new Map<string, number | "ok">();
  const ticks = Number(s.date?.ticks);
  const list = asArray(s.districtDeposits).filter((d) => d?.ref && typeof d.amount === "number");
  depositInfo.clear();
  if (!Number.isFinite(ticks) || !list.length) return out;
  const samples = loadDepositSamples();
  const seen = new Set<string>();
  for (const d of list) {
    const key = `${d.district}|${String(d.ref).slice(-40)}`;
    seen.add(key);
    const base = samples.get(key);
    let weeksLeft: number | null = null;
    if (!base || ticks < base.ticks || d.amount > base.amount) {
      samples.set(key, { ticks, amount: d.amount, weeksLeft: null });
    } else {
      const dt = ticks - base.ticks;
      weeksLeft = base.weeksLeft;
      if (dt >= DEPOSIT_MIN_WINDOW_TICKS) {
        const perTick = (base.amount - d.amount) / dt;
        weeksLeft = perTick > 0 ? d.amount / (perTick * TICKS_WEEK) : null;
        if (dt >= DEPOSIT_REBASE_TICKS) samples.set(key, { ticks, amount: d.amount, weeksLeft });
        else samples.set(key, { ...base, weeksLeft });
      }
      if (d.amount <= 0) weeksLeft = 0;
    }
    depositInfo.set(key, { district: d.district, type: d.type, amount: d.amount, weeksLeft: weeksLeft === null ? null : r1(weeksLeft) });
    out.set(key, depositBucket(weeksLeft));
  }
  for (const k of [...samples.keys()]) if (!seen.has(k)) samples.delete(k);
  saveDepositSamples(samples);
  return out;
}

function city(s: Snap, key: string) {
  const v = s?.[key];
  return Array.isArray(v) ? v[0] : undefined;
}

/** Reduce a snapshot to comparable facts: key -> primitive/JSON string. */
export function facts(s: Snap): Map<string, string> {
  const f = new Map<string, string>();
  const put = (k: string, v: unknown) => f.set(k, typeof v === "string" ? v : JSON.stringify(v));

  const reasons: string[] = asArray(s.pauseReasons).filter((r: string) => r !== "UserPaused");
  put("ui.pauseReasons", [...reasons].sort());
  put("game.paused", asArray(s.pauseReasons).includes("UserPaused"));
  put("ui.cutscene", s.cutscene ?? null);
  // Dialogs with choices need a decision; ones without (population growth, info popups) are notifications.
  for (const m of Array.isArray(s.modals) ? s.modals : []) {
    const decision = asArray(m.choices).length > 0;
    put(`${decision ? "modal" : "notice"}.${m.title ?? m.class}`, { title: m.title, class: m.class, ref: m.ref, description: m.description, choices: m.choices });
  }

  for (const c of Array.isArray(s.construction) ? s.construction : []) put(`construction.${c.name ?? c.building ?? c.district ?? c.target}#${c.ref?.slice(-12)}`, c.state);

  // District on/off with the game's reason (e.g. NoDeposit when a deposit runs dry, PlayerChoice).
  for (const d of asArray(s.districts)) {
    if (!d?.label) continue;
    put(`dstate.${d.label}`, d.active === false ? asArray(d.inactiveReasons).join("+") || "inactive" : "active");
  }

  // New buildings/abilities become available: announce them with their in-game meaning.
  for (const b of asArray(s.unlocks?.buildings)) put(`unlock.building.${b.id}`, { name: b.name, description: b.description, effects: b.effects, statistics: b.statistics, economy: b.economy });
  for (const a of asArray(s.unlocks?.abilities)) put(`unlock.ability.${a.owner}.${a.id}`, { owner: a.owner, name: a.name, description: a.description });

  const r = s.research ?? {};
  put("research.topic", r.topic ?? null);
  put("research.active", Boolean(r.active));

  const council = s.council ?? {};
  put("council.phase", council.phase ?? null);
  put("council.agenda", council.agendaPolicy ?? null);
  put("council.sessionAvailable", (council.minTicksToNextSession ?? 1) <= 0 || council.phase === 1);

  const needs = city(s, "needs")?.needs ?? {};
  for (const [k, v] of Object.entries<any>(needs)) put(`need.${k}`, v.balance < 0 ? "deficit" : "ok");

  const stats = city(s, "statistics");
  for (const [k, v] of Object.entries<number>(stats?.current ?? {})) put(`stat.${k}`, band(v));

  const res = city(s, "resources");
  for (const [k, delta] of Object.entries<number>(res?.change ?? {})) {
    const stock = res.stock?.[k] ?? 0;
    put(`runway.${k}`, delta < 0 ? runwayBucket(stock / -delta / 7) : "growing");
  }

  for (const [k, b] of depositBuckets(s)) put(`deposit.${k}`, b);

  const pop = city(s, "population");
  put("homeless", (pop?.homeless ?? 0) > 0);

  const soc = city(s, "society");
  if (soc?.totalTrust !== undefined) put("trust.total", band(soc.totalTrust));
  if (soc?.deathToll !== undefined) put("deaths.toll", soc.deathToll);
  for (const c of soc?.communities ?? []) put(`standing.${c.community}`, band(c.standing ?? 0));
  put("temperature", pop?.temperatureLevel ?? null);

  for (const q of Array.isArray(s.quests) ? s.quests : []) {
    if (q.name === "silent stat quest") continue;
    for (const o of q.objectives ?? []) put(`quest.${q.name}.${o.name ?? o.debug}`, `${o.progress}/${o.max}`);
  }

  const ex = s.exploration ?? {};
  put("exploration.revealed", ex.revealed ?? null);
  for (const t of asArray(ex.exploring)) put(`exploration.${t.name}`, Math.floor((t.progress ?? 0) * 4) / 4);

  const kinds: Record<string, number> = {};
  // Bark speech bubbles come and go constantly; they carry no actionable state.
  for (const i of Array.isArray(s.icons) ? s.icons : []) if (!/Bark/.test(i.kind)) kinds[i.kind] = (kinds[i.kind] ?? 0) + 1;
  for (const [k, n] of Object.entries(kinds)) put(`icons.${k}`, n);

  put("districts", (Array.isArray(s.districts) ? s.districts : []).map((d: any) => `${d.type}:${(d.buildings ?? []).join("+")}`).sort());
  return f;
}

/** Turn fact changes into events with human-readable detail. */
export function diff(prev: Map<string, string>, next: Map<string, string>, s: Snap): WatchEvent[] {
  const ev: WatchEvent[] = [];
  const keys = new Set([...prev.keys(), ...next.keys()]);
  for (const k of keys) {
    const a = prev.get(k);
    const b = next.get(k);
    if (a === b) continue;
    const [group] = k.split(".");
    const parse = (v?: string) => {
      if (v === undefined) return undefined;
      try {
        return JSON.parse(v);
      } catch {
        return v;
      }
    };
    const from = parse(a);
    const to = parse(b);
    switch (group) {
      case "modal":
        ev.push({ kind: b === undefined ? "dialog.closed" : "dialog.opened", detail: b === undefined ? { title: k.slice(6) } : to });
        break;
      case "notice":
        if (b !== undefined) ev.push({ kind: "notification", detail: to });
        break;
      case "dstate":
        if (a !== undefined && b !== undefined) {
          const label = k.slice(7);
          if (to === "active") ev.push({ kind: "district.activated", detail: { district: label, from } });
          else ev.push({ kind: "district.deactivated", detail: { district: label, reasons: String(to).split("+"), noDeposit: String(to).includes("NoDeposit") } });
        }
        break;
      case "unlock":
        if (a === undefined && b !== undefined) {
          const isBuilding = k.startsWith("unlock.building.");
          ev.push({ kind: isBuilding ? "building.unlocked" : "ability.available", detail: { id: k.split(".").pop(), ...(to as object) } });
        }
        break;
      case "construction":
        ev.push({ kind: b === undefined ? "construction.finished" : a === undefined ? "construction.started" : "construction.state", detail: { what: k.slice(13).split("#")[0], from, to } });
        break;
      case "need":
        ev.push({ kind: to === "deficit" ? "need.deficit" : "need.ok", detail: { need: k.slice(5), balance: city(s, "needs")?.needs?.[k.slice(5)]?.balance } });
        break;
      case "stat": {
        const name = k.slice(5);
        const cur = city(s, "statistics")?.current?.[name];
        const tgt = city(s, "statistics")?.target?.[name];
        ev.push({ kind: (to ?? 0) > (from ?? 0) ? "stat.rising" : "stat.falling", detail: { stat: name, current: cur === undefined ? undefined : r1(cur), target: tgt } });
        break;
      }
      case "runway": {
        const name = k.slice(7);
        const res = city(s, "resources");
        const worse = to !== "growing" && (from === "growing" || from === undefined || (typeof from === "number" && typeof to === "number" && to < from) || from === null);
        ev.push({ kind: worse ? "stock.runway" : "stock.recovered", detail: { resource: name, weeksLeftUnder: to, stock: res?.stock?.[name], perDay: res?.change?.[name] } });
        break;
      }
      case "deposit": {
        // Only a move to a shorter bucket is news (a deposit that vanished from the list is not).
        const rank = (v: unknown) => (typeof v === "number" ? v : Infinity);
        if (b !== undefined && rank(to) < rank(from ?? "ok")) ev.push({ kind: "deposit.depleting", detail: { ...depositInfo.get(k.slice(8)), weeksLeftUnder: to } });
        break;
      }
      case "deaths":
        ev.push({ kind: "deaths.increased", detail: { from, to, byCause: city(s, "society")?.deathsByCause } });
        break;
      case "exploration":
        if (k === "exploration.revealed") ev.push({ kind: "exploration.revealed.changed", detail: { from, to } });
        else ev.push({ kind: b === undefined ? "exploration.finished" : a === undefined ? "exploration.started" : "exploration.progress", detail: { territory: k.slice(12), progress: to } });
        break;
      case "trust":
      case "standing":
        ev.push({ kind: `${group}.${(to ?? 0) > (from ?? 0) ? "up" : "down"}`, detail: { what: k, band: to } });
        break;
      case "quest":
        ev.push({ kind: "quest.progress", detail: { objective: k.slice(6), from, to } });
        break;
      case "icons":
        ev.push({ kind: "icons.changed", detail: { kind: k.slice(6), from: from ?? 0, to: to ?? 0 } });
        break;
      case "game":
        if (k === "game.paused") {
          ev.push({ kind: to ? "game.paused" : "game.resumed", detail: {} });
          break;
        }
        ev.push({ kind: `${k}.changed`, detail: { from, to } });
        break;
      case "research":
        if (k === "research.topic" && to === null) {
          ev.push({ kind: "research.finished", detail: { topic: from } });
          break;
        }
        if (k === "research.topic" && from === null) {
          ev.push({ kind: "research.started", detail: { topic: to } });
          break;
        }
        ev.push({ kind: `${k}.changed`, detail: { from, to } });
        break;
      default:
        ev.push({ kind: `${k}.changed`, detail: { from, to } });
    }
  }
  return ev;
}

const CRITICAL = new Set(["district.deactivated", "deposit.depleting", "dialog.ackFailed", "exploration.finished", "dialog.opened", "need.deficit", "stock.runway", "stat.rising", "ui.cutscene.changed", "research.finished", "construction.finished", "council.sessionAvailable.changed"]);

const TICKS_PER_WEEK = 1680;

// A dialog whose only option is an acknowledgement with no gameplay effect ("I see").
export function isAckOnly(m: any): boolean {
  const choices = asArray(m?.choices);
  return choices.length === 1 && !choices[0]?.effects && !choices[0]?.description;
}

export async function watch(opts: { intervalMs: number; pauseOn: Set<string>; once?: boolean; saveEveryWeeks?: number; saveName?: string; autoAck?: boolean; out: (line: unknown) => void }) {
  let prev: Map<string, string> | null = null;
  // Rolling saves every N in-game weeks, rotating over <saveName>-a/-b/-c (oldest overwritten), so a crash loses
  // at most N weeks and one unloadable save still leaves two older ones.
  let lastSaveTicks: number | null = null;
  for (;;) {
    let s: Snap;
    try {
      s = await call("snapshot", {}, 60_000);
    } catch (e) {
      opts.out({ kind: "bridge.error", detail: String(e) });
      await sleep(Math.max(opts.intervalMs, 5000));
      continue;
    }
    const next = facts(s);
    if (prev === null) {
      opts.out({ at: new Date().toISOString(), kind: "watch.started", date: s.date?.date, week: s.date?.week, paused: asArray(s.pauseReasons).includes("UserPaused") });
    } else {
      // Ignore stock runway "growing" -> bucket noise when nothing is actually short.
      let events = diff(prev, next, s).filter((e) => !(e.kind === "stock.runway" && (e.detail as any).weeksLeftUnder === null));
      if (opts.autoAck) {
        const acked: unknown[] = [];
        events = events.filter((e) => {
          if (e.kind !== "dialog.opened" || !isAckOnly(e.detail)) return true;
          acked.push(e.detail);
          return false;
        });
        for (const d of acked as any[]) {
          // Target this modal by ref (several can be open at once); report failure instead of hiding it.
          const err = await call("choose", { index: 0, ref: d.ref }).then(() => undefined, (e) => String(e));
          if (err) {
            const failed = { kind: "dialog.ackFailed", detail: { ...d, error: err } };
            opts.out({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, ...failed });
            events.push(failed as any);
          } else {
            opts.out({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, kind: "dialog.acknowledged", detail: d });
          }
        }
      }
      for (const e of events) opts.out({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, ...e });
      const critical = events.filter((e) => opts.pauseOn.has(e.kind) || (opts.pauseOn.has("critical") && CRITICAL.has(e.kind)));
      if (critical.length && !asArray(s.pauseReasons).includes("UserPaused")) {
        await call("game.pause").catch(() => undefined);
        opts.out({ at: new Date().toISOString(), date: s.date?.date, kind: "watch.autopaused", detail: critical.map((e) => e.kind) });
      }
    }
    prev = next;
    const ticks = Number(s.date?.ticks);
    if (opts.saveEveryWeeks && Number.isFinite(ticks)) {
      if (lastSaveTicks === null || ticks < lastSaveTicks) lastSaveTicks = ticks;
      else if (ticks - lastSaveTicks >= opts.saveEveryWeeks * TICKS_PER_WEEK) {
        const name = nextRollingSlot(opts.saveName ?? "agent-rolling");
        try {
          const r = await call("save", { name, override: true });
          opts.out({ at: new Date().toISOString(), date: s.date?.date, kind: "watch.saved", detail: { name, result: r } });
          lastSaveTicks = ticks;
        } catch (e) {
          opts.out({ at: new Date().toISOString(), date: s.date?.date, kind: "watch.saveFailed", detail: String(e) });
          lastSaveTicks = ticks;
        }
      }
    }
    if (opts.once) return;
    await sleep(opts.intervalMs);
  }
}
