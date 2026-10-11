# Gameplay notes

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
- District expansion adds cells (Extraction: +3 cells, 50 prefabs + 50 heatstamps, 2 weeks) and upgrades the
  type (Extraction -> Extraction_2_Upgraded). A new deposit cell joins the district immediately and extraction
  resumes before the upgrade finishes. (observed: Materials went from -345 to +210/day the next day)
- Switching districts off (`district_active`) is the fast lever to stretch a shrinking stock while the fix
  builds; switch them back one at a time and measure each step. (observed)
- Districts next to Housing add Squalor. Housing next to the generator ring gets +1 temperature. (observed)

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
  Shelter deficit; `deaths.increased` in the watcher reports each wave. (observed; cause inferred)
- A generator upgrade building can change the generator mode without raising `powerLimit` (observed:
  Symbiosis Lvl1 kept 750). It also exposes City Support abilities (`fp2 abilities describe=true`): Food
  Production, Housing (+1 temperature level), Heavy Industry. Food Production raised food by about 8/day with no
  power change (observed).
- If the generator is at its power limit, distribution does not help. Check `fp2 generator`
  (`power`, `powerLimit`, `capacityPct`, `overdriveSupported`, `canOverdrive`) and fuel stock. (general)

## Stability check before expanding

Before spending on colonies, settlements or big builds, audit the base (`fp2 snapshot`): generator `power`
vs `powerLimit` (headroom), food `change`, free workforce, Squalor/Tension trends, death waves, and whether
the expansion competes with survival for scarce inputs (Cores, prefabs, workers). Expansion that consumes the
city's safety margin is short-term pain that can become collapse in the next cold snap. Decide per run;
expanding early can be right when the base has slack. Revisit the verdict after each temperature drop or population jump, and include
lead times (research weeks, construction weeks, weeks before a law's effect shows). (observed: at 92% generator load and negative food,
the run paused colonies and built the generator upgrade first)

## Priorities early (general)

1. Shelter and Heating deficits first; they drive Cold, Sickliness and Tension.
2. Food supply before the stock runs out (`stock / -change` updates).
3. Goods (Industrial) for Possession, Materials for Maintenance.
4. A Logistics district to unlock the Frostland (expeditions, outposts, cores).
5. A Research Institute for the idea tree. Keep faction trust through Council votes and promises.

## Saves

- The game's autosave rotates AutoSave1 and AutoSave2 and overwrote an older playthrough's autosave.
  Copy them out (for example to `.runtime/save-backup/`) before playing a new game on a shared profile. (observed)
- `fp2 save` writes a new `FrostPunk2SaveGameN.sav` each time and flushes on the next game tick. (observed)

## Time

- 10 game ticks are 1 hour and 1680 ticks are 1 week. (observed)
- The HUD calendar date is interpolated between logic ticks. Trust `gameTimeTicks`. (observed)
