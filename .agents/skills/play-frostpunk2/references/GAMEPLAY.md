# Gameplay notes

See [MECHANICS.md](MECHANICS.md) for the rules behind these notes (resources, heat levels, society, Frostland,
timers, health thresholds). This file keeps play-tested procedures.

Each note carries its evidence. "Observed" means seen in this repo's play. "General" means general
Frostpunk 2 knowledge; verify before relying on it.

## Economy

- Needs (`needs` extractor): Shelter comes from Housing districts, Nourishment from Food districts,
  Heating and Warmth from generator power and heat-related buildings, Possession from Goods (Industrial),
  Maintenance from Materials. A negative balance raises the matching statistic (Cold, Hunger, Squalor, ...). (general)
- `resources.change` is the net change per stockpile update, and the HUD shows the same numbers. (observed)
- A new Utopia Builder start (Citizen) has 8000 people, 4800 workforce, 450 Heatstamps, 1500 Prefabs,
  40000 Materials, 50000 Food and 15000 Coal. Shelter starts at -47 and Possession at -40. (observed)
- A Housing district costs 40 Heatstamps and 200 Prefabs, and takes 200 workforce while building. (observed)
- Districts need 6 adjacent hex tiles. Frozen (hatched) tiles must be frostbroken first. (observed)
- Extraction and Logistics districts must start on a matching deposit. On the Windswept Peaks start the
  nearest Logistics deposit is about 29k units northwest, beyond frozen land. (observed)
- Cells flagged Outside are buildable: a Logistics district was placed on an Outside deposit cell.
  `pick_cells` includes them. (observed)
- In the Repopulate the Frostland scenario natural growth is disabled. Population grows only through
  migration laws and the Frostland. (observed)
- `fp2 district_active active=false` frees a district's workforce; use it to staff a priority build, then
  switch the district back on. (observed)
- Industrial (Production) districts make either Goods or Prefabs: district abilities
  `Toggle_IndustrialGoodsProduction` / `Toggle_IndustrialPrefabsProduction` (`fp2 abilities describe=true`,
  `fp2 ability owner=Production#N id=Toggle_IndustrialPrefabsProduction active=true`). Prefab supply is set by how
  many Industrial districts make prefabs and at what efficiency (`fp2 districts` `efficiencyPct`). (observed)
- Deposits run out. An Extraction district whose deposit is exhausted goes inactive with reason
  `NoDeposit` (`fp2 districts`), and its supply drops to 0 without a `need.deficit` first. Watch deposit
  `amount` (`fp2 extract name=deposits`) and `inactiveReasons`. (observed: the only sawmill ran dry and Materials
  fell 345/day)
- Industry consumes Materials to make Goods or Prefabs, so a Materials outage also stops prefab output. With no
  prefabs, you cannot build a new Extraction district (150), which is a deadlock unless you can expand an
  existing one. (observed)
- A small wood deposit (86.4K) fed one sawmill for about 6 months (observed). Plan the next deposit before the
  current one runs out; expansion has one level, so it works once per district (measured).
- A depleted district can be deconstructed for a refund (`fp2 deconstruct`); that refund can fund the replacement
  district when prefabs are the bottleneck. (observed)
- Cold deaths happened at Cold 10 (18 deaths in one wave, observed). Overdrive lowered the Heating requirement but
  did not move Cold's target; switching off heated non-essential districts did (Cold target 14 -> 10). Insulate
  District costs 50 prefabs + 50 heatstamps (activation cost in `abilities describe=true`).
- District expansion adds cells (Extraction: +3 cells, 50 prefabs + 50 heatstamps, 2 weeks) and upgrades the
  type (Extraction -> Extraction_2_Upgraded). A new deposit cell joins the district immediately and extraction
  resumes before the upgrade finishes. (observed: Materials went from -345 to +210/day the next day)
- Switching districts off (`district_active`) is the fast lever to stretch a shrinking stock while the fix
  builds; switch them back one at a time and measure each step. (observed)
- Districts next to Housing add Squalor. Housing next to the generator ring gets +1 temperature. (observed)
- Stock caps are raised by hub districts, not by buildings: `FuelDepotHub` (+50,000 coal and oil) and the
  Materials, Goods and Food depot hubs (+50,000 each). Each costs 80 Heatstamps and 50 Prefabs, takes 2 weeks and
  100 workforce. Build the hub for a resource that sits at its cap ("surplus wasted") or that a whiteout will
  drain. (measured)
- Each district has its own heat level (Freezing, Very Cold, Cold, Chilly, Livable, Warm). A switched-off district
  reads `HeatLevel_0_NotActive`; the district's `insulated` flag is readable. (measured)

## Heat

- A Heating deficit while the generator is under its power limit usually means unallocated heat, not
  missing power. Run `fp2 heat`: `unallocatedHeatBatches` above 0 with `autoAllocate:false` confirms it.
  Then run `fp2 heat_distribute`. (observed: a Heating deficit of -30 cleared, with fulfilled going
  from 210 to 240 of 240 required.)
- Automatic allocation was off by default in that game. `fp2 heat_auto active=true` turns it on; its
  effect over time is unmeasured.
- `fp2 heat_adjust district=<label> adjustment=N` raises or lowers one district's heat level relative to its
  need; `fp2 district_active active=false` switches a district off to free its workforce. Effects are unmeasured.
- `fp2 heat_auto active=true` fixed a -240 Heating deficit after a temperature drop, as long as coal
  throughput allowed it. (observed)
- Generator abilities trade one input for another (`fp2 abilities describe=true`). Compare benefit, cost
  and side effects before toggling. (observed: Caloryfics Boost cut coal use in one run)
- Cold deaths came in waves about every 11 weeks while Shelter was in deficit (58 deaths per wave). Fix the
  Shelter deficit; `deaths.increased` (a `fp2 turn` stop event) reports each wave. (observed; cause inferred)
- A generator upgrade building can change the generator mode without raising `powerLimit` (observed:
  Symbiosis Lvl1 kept 750). It also exposes City Support abilities (`fp2 abilities describe=true`): Food
  Production, Housing (+1 temperature level), Heavy Industry. Food Production raised food by about 8/day with no
  power change (observed).
- Cold snaps (temperature level drops) raise every district's heat `needed`. Idle districts still count
  toward the Heating requirement, so lowering their allocation (`heat_adjust`) does not cut demand (measured).
  Levers that worked: generator City Support "Housing" (+1 temperature in Housing districts; Heating -150 -> -60,
  measured) and a Heating Hub district (raises temperature of neighbours within 2 cells; 5 weeks to build).
- Overdrive closes a heat gap fast but wears the generator quickly (wear +0.14 per 6 game-hours, measured; 1.0 =
  malfunction with casualties). Wear decays to 0 within a day once off. `fp2 overdrive-cycle` alternates it under
  a ceiling; half-time overdrive did not move Cold's target in one test, so weigh it against wear risk.
- If the generator is at its power limit, distribution does not help. Check `fp2 generator`
  (`power`, `powerLimit`, `capacityPct`, `overdriveSupported`, `canOverdrive`) and fuel stock. (general)

## Whiteout playbook

A whiteout is the catastrophe the whole game builds toward. It outranks every other goal while it is coming or
present (thinking pattern 6). What one run measured (Utopia Builder, week 128 to 230):

- **Warning.** A story dialog ("An Old Enemy": "A whiteout is coming... Without shelter and ample fuel, our people
  will be at mortal risk") with one option, 73 weeks before it hit. `turn` reports it as `threat.warning`. At the
  same time the forecast strip (`turn.weather`, `fp2 brief`) already held the storm: at week 129 it showed level 4
  (-60C) with `whiteout: true` 70.6 weeks out and `whiteoutEnds: true` 100.6 weeks out, and `turn` stopped on
  `whiteout.incoming` (startsInWeeks 69.6, endsInWeeks 99.6). The strip looks 100 weeks ahead (the game's
  prediction interval), so the arrival and end weeks are known from the first warning.
- **Impact.** Temperature level 1 (-30C) to 4 (-60C) in one step. Heating went -750, Warmth -1090, Cold target 50,
  and 40 people died in the first wave. The storm ("Sun-Dimming Storm") also cuts hothouse food output, blocks
  exploration of territories under it, and cuts off sites and outposts under it (in-game description). It lasted
  about 29 weeks (week 201 to about 230).
- **Levers that worked during it.** Switching off every heated non-essential district (industry, coal mines, food,
  faction hub) took Heating from -750 to 0 and the Cold target from 50 to 7; generator City Support "Housing" on.
  Switching districts back on one at a time and measuring each (Extraction#8 alone pushed Heating to -180).
- **Levers that did not.** Overdrive lowered the Heating requirement but not the Cold target, and wear reached 0.7
  to 0.8 within one poll at whiteout demand (use `fp2 overdrive-cycle`, which now switches off predictively). A
  Heating Hub cut Heating need by 60 but drew 60 power. Insulating one housing district changed nothing in 2 weeks.
- **Costs of shedding.** The shed food district cost about 200 food per day: the stock fell from 25,000 to 700 in 17
  weeks. Coal burned 300 per day with both mines off (runway 5 to 6 weeks), and the coal stock had sat at its
  50,000 limit for weeks before ("surplus wasted" alert), so the cap, not production, set the fuel reserve.

Preparation, from the warning to the arrival (general unless marked):

1. **Reorder the stack.** `fp2 goals add horizon=threat priority=1 due=<arrival week> expect=".."`, and defer
   colonies, outposts, Utopia and long research in the goal texts or priorities. Keep `turn` at 1 to 2 weeks when
   the arrival is under 10 weeks away, and 1 week during the whiteout (the default does this).
2. **Fuel.** Fill coal to the stock limit and raise the limit with a `FuelDepotHub` district (+50,000 coal and oil,
   80 Heatstamps, 50 Prefabs, 2 weeks; measured). Budget: whiteout weeks x 7 x coal per day at full heating, plus margin. Hold the coal mines on until
   the stock is full, then decide what to shed.
3. **Food.** Fill the food stock; hothouses lose output in the storm. Budget the same way. Prefer food districts that
   do not depend on light if the tree offers them.
4. **Heat capacity with lead time.** Generator Upgrade research is 12 to 20 weeks, a Heating Hub 5 weeks and 50
   prefabs, Insulate District 50 prefabs per housing district. Start them so they finish before the arrival; a
   reserve of prefabs for insulation beats a factory that finishes during the storm.
5. **Frostland.** Recall expeditions and do not start exploration or outposts that the storm will cut off (no bridge
   action for recall yet: use the Frostland view, V). Outposts under the whiteout stop supplying.
6. **Shed list.** Write down, before the arrival, which districts go off at `whiteout.started` and in which order
   they return, and what each costs per day. Housing, generator and the hub that heats housing stay on.
7. **Do not undo the prep on a warm week.** A cold snap (level 2) at week 120 was not the whiteout; the run restored
   its shed districts at week 151 and met the whiteout at week 201 with nothing shed and coal at the cap.
8. **After `whiteout.ended`.** Check food and coal runways first, then restore districts one at a time, measuring
   Heating after each; restore deferred goal priorities last.

## Stability check before expanding

Before spending on colonies, settlements or big builds, audit the base (`fp2 snapshot`): generator `power`
vs `powerLimit` (headroom), food `change`, free workforce, Squalor/Tension trends, death waves, and whether
the expansion competes with survival for scarce inputs (Cores, prefabs, workers). Expansion that consumes the
city's safety margin is short-term pain that can become collapse in the next cold snap. Decide per run;
expanding early can be right when the base has slack. Revisit the verdict after each temperature drop or population jump, and include
lead times (research weeks, construction weeks, weeks before a law's effect shows). (observed: at 92% generator load and negative food,
the run paused colonies and built the generator upgrade first)

## Colonies, Frostland and society (measured 2026-10-11, Sandbox save, weeks 247 to 257)

- Colony founding (`colony_build site=Loch`) was instant and moved 3,000 people out of the main city (11,998 to
  8,998). It charged no Prefabs, Cores or Heatstamps and was accepted with 0 free teams and 0 Cores. Do not assume
  campaign colonies are free: guides list Cores, teams, Prefabs and weeks. Read stocks before and after.
- Frostland teams are the `LogisticsUnits` supply: 15 per active Logistics district. Exploring Chilton Pass took 10
  (`explore_stop` returns them). An outpost with no free teams sits inactive with `UnmetDemand`. `outpost_upgrade`
  was refused with no change and no cost.
- `FundProjects_CA` on the Merchants community cost 154 Heatstamps, raised standing 0.2 to 0.3, and set a 20-week
  cooldown; a second call was refused. Standing 0.2 reads Favourable, 0 to 0.1 Neutral, -0.3 Opposing, -0.5 Hostile.
- Before `propose`, get the Council hub UI past its lobby; a bridge `propose` over the lobby desynced the UI and a
  later click crashed the game. Use laws from `fp2 laws` (proposable), not `laws all=true`.

## Priorities early (general)

1. Shelter and Heating deficits first; they drive Cold, Sickliness and Tension.
2. Food supply before the stock runs out (`stock / -change` updates).
3. Goods (Industrial) for Possession, Materials for Maintenance.
4. A Logistics district to unlock the Frostland (expeditions, outposts, cores).
5. A Research Institute for the idea tree. Keep faction trust through Council votes and promises.

## Saves

- The game's autosave rotates AutoSave1 and AutoSave2 and overwrote an older playthrough's autosave.
  Copy them out (for example to `.runtime/save-backup/`) before playing a new game on a shared profile. (observed)
- `fp2 save` writes a new `FrostPunk2SaveGameN.sav` each time (observed); `override=true` reuses the slot with
  that display name.

## Time

- 10 game ticks are 1 hour and 1680 ticks are 1 week. (observed)
- The HUD calendar date is interpolated between logic ticks. Trust `gameTimeTicks`. (observed)
