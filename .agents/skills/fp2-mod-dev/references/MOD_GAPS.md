# Known gaps

Ordered by how often play needs them. Remove an entry when a command covers it.

## Not covered yet

- Proximity magnitudes: `layout_preview` matches giver/taker types but not effect sizes. Sizes live in
  `/Game/Scenarios/Shared/Configs/CellProximity/Rules/DA_CellProximityRule_*` and
  `PXCellProximityHolderComponent.SupportedCellProximities` (not read yet).
- Trails: `connect_outpost` (InstructConnectOutpostToCity) does nothing without a trail (measured). `trails`,
  `trail_plan`, `trail_build` and `trail_tool` exist; none has built a trail. The test save has no available trail
  type (`GetAvailableTrailTypes` empty, measured), so `trail_tool` is untested and `trail_build` stays gated.
  `BuildTrail.trailCells` is `Array<Int>` (measured), but the ints are not `PXCityCellComponent` indices (1632 cells,
  614 duplicate indices, none equal the outpost's `CellIndex` 17787). Inferred from dumps: Frostland dot indices of
  `PXFrostlandDetailsSubsystem` (`GridCellSize` 9000, `WorldSize` 2016000 x 2016000, 224 columns; `*ByDot` maps).
  The outpost dot did not calibrate consistently as row-major or column-major, so `candidateCells` is unproven.
  `PXTrailUtils.GetNearestTrailpointVector` returns a denormal garbage Vector (X 4e-316, measured): do not use. Next
  step: a save where Trails (ConnectionLvl1) is researched; build one trail in the UI, read its `PXTrailComponent`
  `Path`, and compare it with `candidateCells`. Painter chain for `trail_tool` (from dumps): `ActivateTrailInputTool`
  -> `GetActiveInputTool` (`PXPaintTrailInputTool`) -> `TryStartPainting(worldPos, true)` -> clicks per chunk ->
  `CanBuildTrail` / `GetChuncksCount` -> `BuildTrail()`; `DeactivateCurrentInputTool` cancels.
- Deconstructions are not listed in `construction`/`brief` (measured); read progress with
  `PXDeconstructionUtils.GetDeconstructionProgress(actor)`.
- Ability cost and refusal reason: `fp2 ability` reports `activeNow:false` with no reason when the game refuses
  (measured: Insulate District with 9 prefabs). Cost data is not read; find it on the ability asset or a
  `Can*` check that does not return FText.
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
  `utopia_v2` reads points, score and assignable nodes. No reflected assign function exists (searched
  `fp2_functions.txt`: only `PXUtopiaNodeDetailsPanel.AssignPoint`, the debug panel `HandleUnlockClicked` /
  `UnlockAllNodes` and the cheat `AddUtopiaToolBonusPoint`); `HandleNodeSelected` only selects. Where the
  "lesser faction agenda" thresholds live is open (read `scoreTracker`, `score`, `config`).
- Frostland: expeditions (`explorations`, `explore_stop`), outposts (`outposts`, `outpost_active`, `build_outpost2`)
  and colonies (`colony_build`, `cities`, `transfer_people`) have commands. Still open: trails (above), outpost
  actions and the upgrade requirement, the colony cost (below). `build_outpost` works on a coal outpost
  (`CoalPermamentOutpost`, Infinite Steppes: built instantly, Operational, measured).
- Food-herd outposts are unbuilt via the bridge: `build_outpost territory=Faebait` on `FoodLargeOutpost_LargeHerd`
  (site `FoodOutpostSite`, Faebait Gorge) crashed the game twice (access violation reading 0x18 in UE4SS
  `UObject::HasAnyInternalFlags`, measured), both about 16 s after "Faebait Gorge explored". Both crash stacks show
  three nested Lua `pcall`s above the failing call (measured from the dumps): the bridge's dispatch pcall, an action
  `pcall(function() ... end)`, and the pcall inside `reflect.isValid`. That fits `reflect.isValid(x)` or `assetId(x)`
  on a destroyed (non-null) object, not a null one: a nullptr raises a catchable Lua error ("UObject instance is
  nullptr", measured in bridge.log). The direct `InstructConstructOutpost` call has only one pcall above it, so it is
  not the crashing frame (inferred). The second crash may have run the pre-fix code if no `fp2 reload` followed the
  edit (guessed). Guards now validate every sub-object in `frost_sites` and every argument of the instruction. Needs
  live verification: save, `build_outpost territory=Faebait dryRun=true`, then without dryRun, then `frost_sites
  territory=Faebait`. If it still crashes, build the herd outpost from the UI and record the outcome here. No
  game-side check is used: `PXOutpostUtils.CanConstructOutpost` returns a requirement struct (FText class).
  `build_outpost2` (target by ref or `GetSites` -> `TryGetOutpostFromSite`, no `FindAllOf` walk) resolved the Huge Herd
  at Faebait in a dryRun (measured); the real call is untested.
- Heat: `heat_levels` reads each district's level (measured: `HeatLevel_5_Livable`, `HeatLevel_0_NotActive`,
  insulated flag). The relation between `heat_adjust` / allocation and the level still needs one measured before/after.
- Other ability and city actions beyond the toggle in `fp2 ability` (`PXAbilityUtils.ActivateActorAbility`).
- Logistics district placement needs a Logistics deposit inside the build area. Frostbreak toward it first.
- `place_building` refusal reasons come from scalar reads (`GetBuildingLimit`, `GetBuildings`,
  `GetCompatibleDistrictsWithFreeSlots`, workforce, stock vs cost; measured). `PXBuildingUtils.CanConstructBuilding*` and
  `CanAffordBuilding` return requirement structs (FText) and stay unread, so a refusal from an unmet building
  requirement (law, research) is not named: `blockers` is empty then.
- Cost checks for area expanders and construction return FText structs, which the crash guard blocks.
  `dryRun` on `expand` reports the error in `check`, `cost` and `duration`; the real call still runs and the
  game validates it.

- Colony cost and checks. `colony_build` (`InstructBuildCity`, `sendUnit=true`) founded the Loch Food Colony
  instantly on the Sandbox save: 3000 people (`StartCommunitySize`) left the main city (11998 -> 8998) and no
  prefabs, cores or heatstamps were charged; it was accepted with 0 cores, 0 free teams and a deactivated Logistics
  District (measured). The only listed cost is `LogisticsUnitsResource -20` plus the 3000 people. Open question:
  does `InstructBuildCity` skip the team and cost check, or are Sandbox colonies free? Verify on a campaign save
  where a colony costs cores, prefabs and weeks (for example Windward Moor: 1 Core, 10 teams, 400 prefabs, 5 weeks):
  read stocks before and after. If the check is bypassed, gate `colony_build` on stocks and teams read from
  `PXCityType.ConstructionSetup` (`colony_sites details=true`). `CanCreateCity`, `CanAbandonCity`,
  `CanRecolonizeCity` and `CanTransferCommunity` return `PXCheckResult`; `GetCityConstructionCost`,
  `GetCityRecolonizationCost` and `GetTransferCommunityCost` return `PXGameplayDescription`. Both hold FText, so no
  dryRun shows the game's verdict. Recolonization and transfer costs are unread. The real `city_abandon` and
  `recolonize` calls are untested.
- Trade routes. The game creates an empty `PXTradeComponent` route per city pair when a colony is founded
  (measured). Trading is locked on the test save (`tradingUnlocked` false, `routeCountLimit` 0), so `trade_route`
  refuses. From Lua, `GetKeyProp` / `GetValueProp` on the `InstructUpdateTradeRoute.Resources` MapProperty resolve
  nothing (measured: `mapSignature.ok` false), so a TMap built from a Lua table is unproven. Open: the trade map
  key and value types, and what unlocks trading. Fallback: the `PXColonyResourceTradePanel` handlers
  (`InitializeResourcePanel(colony)`, `UpdateMainCityResource` / `UpdateColonyResource(Resource, Amount)`,
  `CreateTradeRoute`); the finalize handler is unknown.
- Colony exchange (independent-colony offers and negotiation) is not readable: the v1 read crashed the game (see
  Crashes and stalls). `colony_exchange` returns unrest and the component count only.
- Expedition teams cost has no getter. `explorations teams=true` found no teams cost on the exploration component
  or its economy maps (measured). The cost shows only as the `frost_teams` delta (10 teams for Chilton Pass, Easy).
- Outposts: `outpost_upgrade` was refused silently by the game on an outpost with `canShowUpgrade` true (no change,
  no cost). The reason is unreadable because `CanUpgradeOutpost` returns FText and the type holds a
  `PXBlueprintRequirement`. `PXOutpostType` has no action list, so `outpost_action` is unproven and may be removed.
  `CanExecuteOutpostAction`, `CanActivateOutpost`, `CanConnectOutpostToCity` and `GetSettlementUpgradeTooltipInfo`
  return FText structs. `PXOutpostUtils.DestroyOutpost(Outpost)` takes no ActionOrigin (raw removal): no command;
  use `outpost_active active=false`. `PXInstructionUtils.StopTerritoryExploration(World, territoryId:Name)` is unused
  because the territory FName id property is unknown.
- Promises. Current faction demands outside a negotiation are not readable (FText desire getters); in the Council,
  `council_ui step=terms` lists them from the option widgets' visible text. Sway availability (`IsSwayAvailable`)
  and `IsNegotiationAvailable` return `PXCheckResult`. A story-dialog promise (for example "Unfair Stigma", a
  hospital in 40 weeks) is a quest, not a community promise (`factions.hasPromises` stayed false).
  `vote_predict detail=promised` (the `TryGetPromisedPoliciesForCommunity` out-param) returned nothing and was
  removed. Struct arrays returned by getters (`GetCommunityCoreAffinities`, `GetLastVotingHistoryItems`) come back
  as copies whose fields cannot be read: read the owning property.
- Stock limit raisers: `stock_caps` reads them (district hubs). Placing a depot hub with `place_district
  type=FuelDepotHub` is untested (a one-tile hub may need `pick_cells`). Other raisers (laws, outposts, research)
  show only when active.
- Economy tiers: the trust and tension tier bands and the wear, load and whiteout bands in `health` are guesses
  (`TH.*` constants in `economy_actions.lua`). Replace them with HUD-measured values. `health.population.total` is
  `society.population`; it was not compared with the HUD counter.
- `GetUtopiaToolGameplayDescription`, `GetNodeUIData`, `GetNodesUIData` and `GetNodeDetailsUIData` return FText
  structs: never called.

## Measured caveats

### Saves

`save name=X` writes immediately through `PXSaveSubsystem.SaveGameImmediate` (from the code).
Without `override=true` the game writes a new incrementing file each time (`FrostPunk2SaveGame.sav`,
`FrostPunk2SaveGame1.sav`, ...); `override=true` reuses the slot with that display name. `queued=true` takes the
old `SaveGame` path, which flushes only on the next game tick (measured). Check with `fp2 saves`. `load name=X` resolves display names
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
  `council.activePolicies`. It refuses without an open session unless `--force`.
- `council-open` presses C and skips the chamber intro cutscene before returning. Council UI input during
  that cutscene left the UI unresponsive (measured).
- Sessions reopened about 10 weeks after each vote (observed). The watcher emits
  `council.sessionAvailable.changed` when the phase is 1 or `minTicksToNextSession` is 0 or less. Phase 1 with
  `minTicksToNextSession` 16800 constant means a session is available (measured; the recess length is config).
- Lobby desync crash (measured 2026-10-11): `propose` ran through the bridge while the hub UI was still on its
  lobby (pauseReasons `UserPaused`, `WBP_Tutorial_New_C`, `WBP_ParliamentHub_C`). The phase moved to Negotiations
  and a pixel click on "PROPOSE A LAW" crashed the game in UI rendering (`nsvgRasterizeFull`, AntiLag2; no Lua
  frames). Inferred: the UI desynced from the bridge-driven proposal. `propose` now refuses while the lobby is
  visible (`force=true` overrides). Drive the hub with `council_ui` steps: the widgets' own bound button events kept
  the UI in sync through propose, negotiate, accept and vote (measured: LAW PASSED 55 For / 51 required). Pixel
  clicks on the lobby did nothing and a Space keypress did not advance it.
- A save written inside the Council scene (`agent-society-proposed`) did not load: the game stayed at the main
  menu (measured). Save before opening the Council; `fp2 save` warns.
- `council-open` failed twice ("Council did not open") while `fp2 keys c keepFocus=true` opened it. Inferred: the
  key press restores the previous foreground window at once and the key is lost.
- The "?" `WBP_Tutorial_New_C` widget inside each hub panel is a hint button, not a modal (measured).
- `propose` needs a law from `fp2 laws` (the proposable list), not `laws all=true`. After it the phase is 2
  (Negotiations).

### Crashes and stalls (2026-10-11)

- `colony_exchange` v1 crashed the game: access violation reading 0x150, stack Wwise `AK::WriteBytesMem::SetCount`
  <- UE4SS `FAnsiString::operator=` <- `process_lua_function` (measured). Not bisected. Candidates, ranked
  (inferred): `PXStockpileExchangeUtils.GetStockpileExchangeTiersNum()` and `GetStockpileExchangeTierValue(i)`
  (static, no world context, and the only exchange calls that run with no component); then
  `GetResponseTimeAndProgress` with table out-params; then `IsDefianceThresholdValidForNegotiations` and
  `HasResourceToDeliver`; member getters last. The command now reads unrest and the component count only (one
  `PXStockpileExchangeComponent` exists on the main city). To read exchange state, use `fp2 object` on a component
  ref and read properties, not the Utils functions.
- `promise_abandon` with `PXDesireUtils.AbandonPromise(ctx, quest)` crashed the game once: access violation reading
  0x0, the same Wwise / `FAnsiString::operator=` stack, with a valid `PXPromiseQuest` element of
  `GetCommunityPromises` (measured). Default `path=quest` (`PXQuestUtils.FinishQuest(ctx, quest, false)`) works
  (measured). `path=abandon` needs `force=true`. The game has no UI to abandon a promise (observed).
- This Wwise / `FAnsiString::operator=` / `process_lua_function` stack has now appeared three times (world-context
  guess, `colony_exchange`, `AbandonPromise`). Read it as a bad argument to a static Utils function (inferred), not
  as an audio fault.
- Shader-compile overlay: `fp2 recover` loaded a save while the main-menu shader compile
  (`BP_ShaderCompilerActor_C`) ran. The load destroys the actor, so `WBP_InitializationLoadingScreen_C` never
  receives `OnShaderCompilationFinished` and stays on "COMPILING SHADERS N/743" with input blocked (measured twice:
  243/743, 559/743). The bridge works underneath. Manual fix: `call ref=<widget> fn=OnShaderCompilationFinished
  mutate=true`, wait 12 s, `fp2 keys space`. The CLI now handles it: `fp2 unstick`, and `recover` / `launch` wait for
  the compiler actor to vanish before loading.
- `recover`'s ready check failed on a save that opens on a story modal. Fixed in the CLI (ready = in the world, no
  compile overlay).
- `fp2 keys` and `click` from another process hung while the CLI rebuilt and restarted the daemon (measured). Wait
  for the rebuild to finish.

### Hotkeys

UE4SS's reload chord Ctrl+R also triggers the game's R = Research hotkey and opens the Idea Tree.
`fp2 reload` avoids keys; `fp2 reload --full` closes the Idea Tree afterward.

### Other

- `choose` is untested on a real decision; only tutorial modals have been seen. `fp2 modals` lists
  each decision's `choices`.
- Calendar `week` is `floor(ticks/1680)`. HUD week and day labels can lag the logic tick.
