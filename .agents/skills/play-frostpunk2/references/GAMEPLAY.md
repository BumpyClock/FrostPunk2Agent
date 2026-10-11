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
- Turn on the generator's Caloryfics Boost early (`fp2 ability id=CaloryficsBoost active=true`); it cut
  coal use. (observed)
- Cold deaths came in waves about every 11 weeks while Shelter was in deficit (58 deaths per wave). Fix the
  Shelter deficit; `deaths.increased` in the watcher reports each wave. (observed; cause inferred)
- If the generator is at its power limit, distribution does not help. Check `fp2 generator`
  (`power`, `powerLimit`, `capacityPct`, `overdriveSupported`, `canOverdrive`) and fuel stock. (general)

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
