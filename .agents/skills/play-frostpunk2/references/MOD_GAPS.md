# Known gaps

Ordered by how often play needs them. Remove an entry when a command covers it.

## Not covered yet

- Council negotiation and promises (`InstructNegotiate`, `PXDesireUtils.MakePromise`).
- Proximity magnitudes: `layout_preview` matches giver/taker types but not effect sizes. Sizes live in
  `/Game/Scenarios/Shared/Configs/CellProximity/Rules/DA_CellProximityRule_*` and
  `PXCellProximityHolderComponent.SupportedCellProximities` (not read yet).
- District expansion: `fp2 district_expansion district=X` reads levels, cells, cost and the upgrade type.
  Starting one with chosen cells has no bridge path yet: `PXInstructionUtils.ExpandDistrict` needs an internal
  Name id (actor and component FNames had no effect, measured), and the UI calls it natively, so
  `instruction_hooks` saw nothing. `PXDistrictExpansionUtils.TryAutoExpandDistrict(@ctx, district)` works and
  charges the real cost, but the game picks the cells (it skipped the wood deposit once, measured). For chosen
  cells use the UI: `fp2 camera ref=<district ref>`, click the district, click the expand icon (four arrows)
  under the panel, click 3 cells inside the white area, click the checkmark.
- District upgrades (Housing_2_Upgraded, Housing_3_Advanced): not placeable directly
  (`ConstructionByPlayerBlocked`); likely reached through buildings and `PXBuildingUtils.UpgradeBuilding`. Unconfirmed.
- Efficiency levels: `districts` reads the current level and percent; changing it (`IncreaseEfficiency`) is not wrapped.
- Utopia Tree node unlocks: no non-UI command path. `utopia_assign` drives the panel's own handlers
  (`PXUtopiaToolNodesPanel.HandleUtopiaToolNodeClicked`, then `PXUtopiaNodeDetailsPanel.AssignPoint`) while the
  panel is open; the CLI `utopia-assign` opens and closes it with U (measured: Goods Emporium Open -> Unlocked).
- Total population as the HUD shows it. `population.population` sums unassigned community sizes only;
  `society.population` is the candidate but is not compared to the HUD.
- Frostland beyond exploration: expeditions, outposts, colonies, trails (`InstructConstructOutpost`, `BuildTrail`).
  `fp2 territories` and `fp2 explore` cover exploration only.
- Heat: `heat_adjust` sets a district's adjustment level, but the relation between adjustment, allocation
  and the HUD heat bars is unmeasured.
- Other ability and city actions beyond the toggle in `fp2 ability` (`PXAbilityUtils.ActivateActorAbility`).
- Logistics district placement needs a Logistics deposit inside the build area. Frostbreak toward it first.
- Cost checks for area expanders and construction return FText structs, which the crash guard blocks.
  `dryRun` on `expand` reports the error in `check`, `cost` and `duration`; the real call still runs and the
  game validates it.

## Measured caveats

### Saves

`save name=X` queues `PXSaveSubsystem.SaveGame`. The game writes a new incrementing file each time
(`FrostPunk2SaveGame.sav`, `FrostPunk2SaveGame1.sav`, ...), never overwrites, and flushes only on the next
game tick, so run `fp2 advance ticks=10` and check `fp2 saves`. `load name=X` resolves display names
through `DoesSaveGameExists`, not file names. Do not delete or overwrite the user's saves.

### Council

- `InstructVote` works inside the Council scene after a proposal (measured 2026-10-11: the UI went to
  "Law passed", one Escape returned to the city, and the policy was active). Outside the scene it locked
  all game input; only a reload recovered it.
- `RequestSession` (propose) plus `vote` inside the Council passed a law with the UI following (measured,
  saved before the test). An earlier propose attempt outside those conditions desynced the Council UI
  (Propose button dead, input stuck).
- Code state: `propose` and `vote` refuse unless `IsInParliament` is true and no cutscene is active
  (`unsafe=true` overrides the scene check only).
- `fp2 pass-law policy=<id>` runs `council-open`, `propose`, a 4 s wait, cutscene skip, `vote`, a 6 s wait,
  Escape (result screen), and a second Escape if still in the chamber. It reports `active` from
  `council.activePolicies`. It needs an open session; it has no separate check for that.
- `council-open` presses C and skips the chamber intro cutscene before returning. Council UI input during
  that cutscene left the UI unresponsive (measured).
- Sessions reopened about 10 weeks after each vote (observed). The watcher emits
  `council.sessionAvailable.changed` when the phase is 1 or `minTicksToNextSession` is 0 or less.

### Hotkeys

UE4SS's reload chord Ctrl+R also triggers the game's R = Research hotkey and opens the Idea Tree.
`fp2 reload` avoids keys; `fp2 reload --full` closes the Idea Tree afterward.

### Other

- `choose` is untested on a real decision; only tutorial modals have been seen. `fp2 modals` lists
  each decision's `choices`.
- Calendar `week` is `floor(ticks/1680)`. HUD week and day labels can lag the logic tick.
