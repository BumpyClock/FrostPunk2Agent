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

## 2026-10-11 wk 253 | resources | gap
- Wanted: which districts consume coal, to cut demand in a coal crisis.
- Tried: `fp2 extract name=resources` gives city `supply` 162 and `change` -114 only (measured); no per-district consumer list.
- Workaround: toggled districts off while paused and read `change` (Production#10 36/day, Production#6 24/day).
- Cost: several toggles and reads; ~170 coal/day of demand is still unattributed.
