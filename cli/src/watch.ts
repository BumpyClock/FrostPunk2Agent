// `fp2 watch`: poll the bridge snapshot and print one JSON line per meaningful change.
// Designed to run under an agent's Monitor tool: quiet while nothing important happens.
import { call } from "./bridge";

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
  for (const m of Array.isArray(s.modals) ? s.modals : []) put(`modal.${m.title ?? m.class}`, { title: m.title, description: m.description, choices: m.choices });

  for (const c of Array.isArray(s.construction) ? s.construction : []) put(`construction.${c.district ?? c.target}#${c.ref?.slice(-12)}`, c.state);

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

  const pop = city(s, "population");
  put("homeless", (pop?.homeless ?? 0) > 0);

  const soc = city(s, "society");
  if (soc?.totalTrust !== undefined) put("trust.total", band(soc.totalTrust));
  for (const c of soc?.communities ?? []) put(`standing.${c.community}`, band(c.standing ?? 0));
  put("temperature", pop?.temperatureLevel ?? null);

  for (const q of Array.isArray(s.quests) ? s.quests : []) {
    if (q.name === "silent stat quest") continue;
    for (const o of q.objectives ?? []) put(`quest.${q.name}.${o.name ?? o.debug}`, `${o.progress}/${o.max}`);
  }

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

const CRITICAL = new Set(["dialog.opened", "need.deficit", "stock.runway", "stat.rising", "ui.cutscene.changed", "research.finished", "construction.finished", "council.sessionAvailable.changed"]);

export async function watch(opts: { intervalMs: number; pauseOn: Set<string>; once?: boolean; out: (line: unknown) => void }) {
  let prev: Map<string, string> | null = null;
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
      const events = diff(prev, next, s);
      for (const e of events) {
        // Ignore stock runway "growing" -> bucket noise when nothing is actually short.
        if (e.kind === "stock.runway" && (e.detail as any).weeksLeftUnder === null) continue;
        opts.out({ at: new Date().toISOString(), date: s.date?.date, week: s.date?.week, ...e });
      }
      const critical = events.filter((e) => opts.pauseOn.has(e.kind) || (opts.pauseOn.has("critical") && CRITICAL.has(e.kind)));
      if (critical.length && !asArray(s.pauseReasons).includes("UserPaused")) {
        await call("game.pause").catch(() => undefined);
        opts.out({ at: new Date().toISOString(), date: s.date?.date, kind: "watch.autopaused", detail: critical.map((e) => e.kind) });
      }
    }
    prev = next;
    if (opts.once) return;
    await sleep(opts.intervalMs);
  }
}
