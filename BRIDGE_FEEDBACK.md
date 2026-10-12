# Bridge feedback from play sessions

Play agents append here when the bridge or CLI lacks a read or action, returns something wrong, or crashes. The
maintainer reads this between sessions, fixes the bridge, and removes handled entries. Format: see the
`play-frostpunk2` skill, section "Bridge and CLI are read-only during play". Newest at the bottom.


## 2026-10-11 wk 246 | turn event deaths.increased | bug
- Wanted: turns to stop when people die (whiteout cold deaths), so the death wave is judged at once.
- Tried: `fp2 turn` across wk 201-246; HUD death toll went 102 -> 143 (measured, screenshot) and `fp2 extract name=society` now returns `deathToll` 143, `deathsByCause {Cold:143}` (measured). No turn reported `deaths.increased` in `stoppedBy.kinds` or `events` (measured over the whiteout turns).
- Workaround: read `fp2 health` `deaths` [total, delta] each turn.
- Cost: ~40 cold deaths during the whiteout surfaced only from the HUD, weeks late.

## 2026-10-11 wk 246 | expand (frostbreak) | gap
- Wanted: frostbreak cost before committing (coal crisis, 217 prefabs).
- Tried: `fp2 expand 'cells=[166,224,276,331,383,344,373,369]' dryRun=true`: `check` and `cost` both refused (FText in ReturnValue). Only `duration` 3360 ticks returned. After the real call heatstamps went 2434 -> 2402 while paused (measured; other costs unknown).
- Workaround: committed blind after a save.
- Cost: none this time; a blind spend when prefabs are tight could block a district.
- wk 252 update: `deaths.increased` did fire (143 -> 148, byCause Cold) and stopped the turn (measured). The earlier miss may be specific to the whiteout turns; keep the entry until checked.

## 2026-10-11 wk 254 | place_building check | bug
- Wanted: why `E_DeepProspector_Progress` could not go into Extraction#8 (cell 221, deep coal).
- Tried: `fp2 place_building type=E_DeepProspector_Progress district=Extraction#8 dryRun=true` returned `blockers` ["no free building slot in this district (0/1 used)", "short 1 CoresResource"] with `buildingsUsed` 0, `freeSlots` 1, `thisDistrictHasFreeSlot` false (measured). The slot blocker contradicts the counts; the real blocker is the Core. Extraction#8 is deactivated (NoDeposit), which may be the cause.
- Workaround: treated the Core as the blocker.
- Cost: a few tokens; a misleading blocker could send an agent to deconstruct for a slot.
- wk 338 update: same blocker ("no free building slot (0/1 used)") on Production#10 and LogisticsDistrict#22; a real `place_building type=X_HousingBloc_Base district=LogisticsDistrict#22` then succeeded (construction started, prefabs 56 -> 6, measured). With 0 used of 1, the slot blocker is a false positive. `districtsWithFreeSlot` was empty at the same time.

## 2026-10-11 wk 253 | resources | gap
- Wanted: which districts consume coal, to cut demand in a coal crisis.
- Tried: `fp2 extract name=resources` gives city `supply` 162 and `change` -114 only (measured); no per-district consumer list.
- Workaround: toggled districts off while paused and read `change` (Production#10 36/day, Production#6 24/day).
- Cost: several toggles and reads; ~170 coal/day of demand is still unattributed.

## 2026-10-11 wk 264 | expand_district | bug
- Wanted: upgrade a Housing district (Housing_2_Upgraded, +3 cells, 50 prefabs + 50 hs, 2 wk) to get a building slot for the promised hospital.
- Tried: `fp2 expand_district district=Housing#1|#4|#9 'cells=[47,72,61]'` (cells free, unfrozen, contiguous 47-61-72, next to the Housing cluster that `pick_cells` names as Housing#4; measured). Each returned the level info with `underExpansionNow` false and `queuedCells` 0; no construction appeared in `brief` (measured). No error or reason given; `dryRun=true` gave the same output, so it does not check adjacency or affordability.
- Workaround: placed a new Housing district (200 prefabs, 4 wk) instead of a 50-prefab upgrade.
- Cost: ~150 prefabs and 2 extra weeks on a promise clock.
- wk 290 update: same silent no-op on `expand_district district=Extraction#19 'cells=[466,476,501]'` with all three cells thawed and next to the district (measured). Workaround: a new 5-cell district (`place_district` accepted 5 cells).

## 2026-10-11 wk 291 | frost_sites / explorations | gap
- Wanted: what Randall's Flats gave after exploration (listed `possibleResources` People, Cores, Prefabs; `sites` 3), to get a Core for the Deep Melting Drill.
- Tried: `fp2 explorations name=Randall` -> state explored, sites 3 (measured). `fp2 frost_sites territory=Randall` and `territory=Flats` list no site in Randall's Flats (the `Flats` match was Deathway Flats) (measured). `extract name=resources` CoresResource 0. `fp2 keys v keepFocus=true` then `fp2 screenshot`: still the city view (measured; the same V failure as wk 246).
- Workaround: none; sent the teams to Kneeache Climbs.
- Cost: cannot tell whether Randall's sites need an action (a cache, ruins, a settlement) or hold nothing; ~17 weeks of expedition may be wasted.

## 2026-10-11 wk 295 | explore | gap
- Wanted: to know why an expedition stopped and how many Frostland teams it needs before sending it.
- Tried: `fp2 explore territory=Kneeache` (Hard) and `territory=Ratway` (Medium) with 15 teams total. `frost_teams` showed inUse 25 and 20 (free -10, -5) (measured). Each ended within 0.2-1 week with an `exploration.finished` event while the territory stayed `unexplored`, progress 0 (measured). `explore dryRun=true` returns no team cost; `explorations teams=true` exists but the abort is not reported as an abort.
- Workaround: built a second Logistics district (200 prefabs, 5 weeks) for 30 teams.
- Cost: two wasted expedition starts; the `exploration.finished` event reads like success. An `exploration.aborted` kind, and the team need in `explore dryRun`, would have saved both.

## 2026-10-11 wk 308 | pick_cells deposit= | bug
- Wanted: cells for a new wood (later soil) district after the old deposits ran out.
- Tried: `fp2 pick_cells count=6 type=Extraction deposit=Wood` returned 250,289,213,260,194,245; I placed an Extraction district there (150 prefabs, 4 weeks). It finished with `NoDeposit`: all four wood deposits read 0 in `extract name=districtDeposits` (measured). `pick_cells type=Food_Supply deposit=soil` then proposed 140/150, whose soil deposits also read 0 (measured). `cells deposit=X` lists cells without amounts.
- Workaround: matched `extract name=deposits` amounts to `cells` by distance by hand; frostbroke to live deposits.
- Cost: 150 prefabs (~6.5 weeks of prefab output), 4 weeks, and a materials crisis (stock 30K -> 15K).

## 2026-10-11 wk 327 | explore / explorations | gap
- Wanted: the risk of an expedition before sending people (deciding between Kneeache Climbs, Hard, and other Core sources).
- Tried: `fp2 explorations` gives difficulty `TerritoryDifficulty_2Hard`, weeks and possible resources; `explore dryRun=true` gives no casualty risk (measured). The expedition ended with the HUD notification "272 died during exploration" (death toll 148 -> 420, measured). The `deaths.increased` event reported `byCause {Cold: 148}`, so the 272 have no cause in the bridge (measured). Afterwards `frost_sites territory=Kneeache` listed no site although `sites` is 2, and `charted` stayed false (measured).
- Workaround: none.
- Cost: 272 lives, 27 weeks of 25 teams, and still no Core.

## 2026-10-11 wk 341 | heat_adjust, health | doc + gap
- Wanted: fix a Warmth deficit (-110) that was killing people (54 cold deaths at temperature level 2).
- Tried: `heat_distribute` with auto on: 36-42 unallocated batches stayed unused and Warmth stayed -110/-130 (measured). `heat_auto active=false`, then `heat_adjust district=Housing#9 adjustment=1` LOWERED it from 2 to 1: `adjustment` is the absolute level, while the help text says "adjustment above/below its need" (measured). `health` rated Warmth only "act", and `heat_levels` showed no bad level throughout.
- Workaround: set housing levels to need+1 by hand.
- Cost: 54 deaths; the help text sent me the wrong way once.
- Also: `extract name=population` returns `population` 1032 and per-community sizes in the hundreds while `extract name=society` returns 15,492 (measured). One of them is a different measure under the same name.

## 2026-10-11 wk 356 | council_ui negotiate | bug
- Wanted: a negotiated vote (Heated Commons) through the `council_ui` steps.
- Tried: `council_ui step=community community=Sandbox_Dominion_CommunityType`, `step=side side=for`, `step=term index=1`, `step=accept` all returned ok. On screen the "VOTE FOR" diamond stayed unselected and their terms stayed greyed (measured, screenshots). The community still became "already negotiated" and the bar did not move until the vote. `step=terms` returned the same merged text for every index (law, ability and building text mixed); the screen showed different terms (research Waste Incineration Facility / Grant Agenda) (measured).
- Workaround: pixel clicks worked: VOTE FOR diamond (476,758), term diamond (3344,620 for the first term), ACCEPT (3344,1300 or 3344,1108 depending on term count); the bar moved 18 -> 40 -> 63 For. `step=vote` then worked: LAW PASSED 71 For / 51 required. A pixel click on the back arrow (84,94) returns from a negotiation to the community list.
- Cost: ~10 screenshots; the Machinists' negotiation was spent without visible effect (it did count at the vote: a "Promise to Machinists" quest exists).
