// Turn the raw `state` snapshot into a short triage list an agent can act on.
import { call } from "./bridge";
import { researchIdle } from "./watch";

type Num = Record<string, number>;
type CityRes = { cityType?: string; stock: Num; limits: Num; supply: Num; demand: Num; change?: Num };
type CityNeeds = { cityType?: string; needs: Record<string, { required: number; fulfilled: number; balance: number }> };
type CityStats = { cityType?: string; current: Num; target: Num };
type CityPop = { cityType?: string; population?: number; homeless?: number; totalWorkforce?: number; temperatureLevel?: string; generator?: Num & { mode?: string } };

// Statistics that are good when high; everything else is "higher = worse".
const GOOD_STATS = new Set(["Wealth", "CitySize", "NationSize"]);
const round = (n: number) => Math.round(n * 10) / 10;

/**
 * `weather` is the snapshot's weather section when the caller already has one (turn); otherwise the extractor is
 * read here, so the forecast strip (a coming drop, a whiteout) is part of every triage.
 */
export async function brief(given?: { weather?: any; research?: any }) {
  const s = await call<any>("state");
  const alerts: string[] = [];
  const weather = given && "weather" in given ? given.weather : await call<any>("extract", { name: "weather" }).catch((e) => ({ error: String(e) }));
  const w = weather ?? {};
  // `state` has no research section; turn passes the snapshot's, otherwise ask the bridge (one cheap call).
  const research = given && "research" in given ? given.research : await call<any>("research").catch((e) => ({ error: String(e) }));
  if (researchIdle({ research })) alerts.push("research idle: no topic in progress (fp2 research_topics, then research_start)");
  if (w.whiteout?.known && w.whiteout.active) alerts.push(`WHITEOUT active (level ${w.current?.level}${w.whiteout.endsInWeeks !== undefined ? `, ends in ~${w.whiteout.endsInWeeks} weeks` : ""})`);
  else if (w.whiteout?.known && typeof w.whiteout.startsInWeeks === "number") alerts.push(`whiteout forecast in ~${w.whiteout.startsInWeeks} weeks${w.whiteout.endsInWeeks !== undefined ? ` (ends ~${w.whiteout.endsInWeeks})` : ""}: prepare now`);
  if (Array.isArray(w.forecast)) {
    let prev = Number(w.current?.level);
    for (const f of [...w.forecast].sort((a: any, b: any) => Number(a?.atTicks) - Number(b?.atTicks))) {
      if (typeof f?.level !== "number") continue;
      if (Number.isFinite(prev) && f.level > prev) {
        alerts.push(`temperature drops to level ${f.level}${f.degrees !== undefined ? ` (${f.degrees}C)` : ""} in ~${f.weeksFromNow} weeks`);
        break;
      }
      prev = f.level;
    }
  }
  const cities: any[] = [];
  const res: CityRes[] = s.resources ?? [];
  const needs: CityNeeds[] = s.needs ?? [];
  const stats: CityStats[] = s.statistics ?? [];
  const pop: CityPop[] = s.population ?? [];

  res.forEach((r, i) => {
    const name = r.cityType ?? `city${i}`;
    const city: any = { city: name };
    const depleting: Record<string, string> = {};
    for (const [id, delta] of Object.entries(r.change ?? {})) {
      const stock = r.stock[id] ?? 0;
      if (delta < 0) {
        const days = stock / -delta; // change is per game day (measured: 7 x daily change per 1680-tick week)
        depleting[id] = `${stock} stock, ${delta}/day, ~${round(days / 7)} weeks left`;
        if (days < 70) alerts.push(`${name}: ${id} runs out in ~${round(days / 7)} weeks (${delta}/day)`);
      }
    }
    for (const [id, limit] of Object.entries(r.limits ?? {})) {
      if ((r.stock[id] ?? 0) >= limit && (r.change?.[id] ?? 0) > 0) alerts.push(`${name}: ${id} at stock limit ${limit}; surplus wasted`);
    }
    city.stock = r.stock;
    city.change = r.change;
    city.depleting = depleting;

    const n = needs[i]?.needs ?? {};
    city.needDeficits = Object.fromEntries(Object.entries(n).filter(([, v]) => v.balance < 0).map(([k, v]) => [k, v.balance]));
    for (const [k, v] of Object.entries(city.needDeficits)) alerts.push(`${name}: need ${k} deficit ${v}`);

    const st = stats[i];
    if (st) {
      const worrying: Record<string, string> = {};
      for (const [k, cur] of Object.entries(st.current)) {
        if (GOOD_STATS.has(k)) continue;
        const tgt = st.target[k] ?? cur;
        if (cur >= 40 || tgt >= 60) worrying[k] = `${round(cur)} -> ${round(tgt)}`;
        if (tgt >= 80 || cur >= 70) alerts.push(`${name}: ${k} ${round(cur)} heading to ${round(tgt)}`);
      }
      city.statistics = worrying;
    }
    const p = pop[i];
    if (p) {
      city.population = { workforce: p.totalWorkforce, homeless: p.homeless, temperature: p.temperatureLevel, generator: p.generator };
      if ((p.homeless ?? 0) > 0) alerts.push(`${name}: ${p.homeless} homeless`);
    }
    cities.push(city);
  });

  const t = s.time ?? {};
  let modals: unknown = [];
  try {
    modals = await call("modals");
  } catch (e) {
    modals = { error: String(e) };
  }
  // Only dialogs with choices need an answer; notifications (no choices) do not block play.
  const decisions = Array.isArray(modals) ? modals.filter((m: any) => Array.isArray(m?.choices) && m.choices.length > 0) : [];
  if (decisions.length) alerts.unshift(`${decisions.length} decision(s) open: answer with fp2 choose index=N`);
  let date: unknown = null;
  try {
    date = await call("date");
  } catch {}
  return {
    time: { paused: t.paused, pauseReasons: t.pauseReasons, speed: t.speed, gameTimeTicks: t.gameTimeTicks, date },
    weather: w.error || w.timelineError ? { error: w.error ?? w.timelineError, level: w.current?.level } : { level: w.current?.level, degrees: w.current?.degrees, horizonWeeks: w.horizonWeeks, forecast: Array.isArray(w.forecast) ? w.forecast.map((f: any) => ({ inWeeks: f.weeksFromNow, level: f.level, degrees: f.degrees, ...(f.whiteout ? { whiteout: true } : {}) })) : [], whiteout: w.whiteout?.known ? w.whiteout : "unknown" },
    research: research && !research.error ? { topic: research.topic, progress: research.progress, weeksLeft: research.weeksLeft, idle: researchIdle({ research }) } : { error: research?.error },
    modals,
    construction: (s.construction ?? []).map((c: any) => ({ what: c.district ?? c.target, state: c.state, progress: c.progress, weeksLeft: c.weeksLeft })),
    alerts,
    cities,
  };
}
