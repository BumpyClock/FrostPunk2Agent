# Data map

Where game data lives and how the extractors read it. Built against Frostpunk 2 (UE 5.4.3) and
UE4SS experimental 3.0.1-1164. "Measured" means compared to the HUD in play; "unverified" means read
from the code only.

## Object model

- World subsystems are `PX*Subsystem` (for example `PXTimeSubsystem`). They hold logic and little state.
- The city actor `BP_BaseCity_C` holds about 50 components (`fp2 components ref=first:BP_BaseCity_C`).
  `PXCityComponent` links them: `stockpile`, `EconomyHolder`, `NeedHolder`, `statisticHolder`,
  `WorkforceHolder`, `peopleAllocationHolderComponent`, `districtHolder`, `Generator`, `Nation`, `CityType`.
- Game definitions are data assets (`/Game/Scenarios/Shared/Configs/...DA_*`). Extractors shorten them to ids
  (`DA_Core_FoodResource` becomes `Core_FoodResource`).
- Static helper libraries are `PX*Utils`, called on `/Script/Frostpunk2.Default__PX*Utils`
  (`PXStockpileUtils`, `PXNeedUtils`, ...). Inspect one with `fp2 describe class=PXNeedUtils`.
- Per-city extractors return an array with one entry per `PXCityComponent`, each carrying `ref` and
  `cityType`. A failing extractor entry carries `error` instead of failing the call.

## Extractors

`fp2 extract name=<x>` runs one extractor; `fp2 extract` lists them. `fp2 state` runs every extractor
marked `inState`. `fp2 snapshot` is a separate bridge command that builds the HUD view (see below).

| Extractor | `inState` | Source | Fields and notes |
|---|---|---|---|
| `session` | yes | PlayerController world | `inWorld`, `map`, `gameMode`, `gameState`, `playerController`, `timeDilation`, `paused` (world settings pauser; not the FP2 pause, use `time.paused`). |
| `time` | yes | `PXTimeSubsystem` | `paused`, `pauseReasons` (for example `UserPaused`, `WBP_Modal_C` for an open modal, `Cutscene ...`), `speed` (level name), `speedLock`, `gameplayBegan`, `gameTimeTicks` (`currentGameTime.ScaledTicks`), `startDateDays`, `logicTicks`. Measured: 10 ticks = 1 hour, 1680 ticks = 1 week. |
| `resources` | yes | `city.stockpile.Stock/StockLimits`, `EconomyHolder.TargetSupply/TargetDemand`, `PXStockpileUtils.GetCityStockpileChangeOfResource` | `stock`, `limits`, `supply`, `demand`, `change`. Measured: `change` matched the HUD deltas (food -523, coal -79, goods -89). `brief` treats `change` as per game day (7 times it per 1680-tick week). Limits exist for some resources only. |
| `needs` | yes | `NeedHolder.NeedsRequired/NeedsFulfilled` | Per need: `required`, `fulfilled`, `balance = fulfilled - required`. Measured: Heating -5970 and Shelter -159 matched the HUD. |
| `statistics` | yes | `statisticHolder.CurrentStatistics/TargetStatistics` | `current` and `target` maps, roughly 0 to 100. Higher is worse except Wealth, CitySize, NationSize. `current` drifts toward `target`. |
| `population` | yes | `WorkforceHolder`, `peopleAllocationHolderComponent`, `PXTemperatureComponent`, `Generator` | `totalWorkforce`, `homeless`, `communitySizes`, `population`, `temperatureLevel`, `temperatureC` (`Degrees` of the current level; unverified against the HUD), `generator` (`power`, `potentialPower`, `fuel`, `mode`). Measured gap: `population` sums unassigned community sizes only (10429 vs HUD about 30.7K). Use `society.population` for the total. |
| `society` | yes | `PXTrustUtils`, `PXCommunityUtils` | `totalTrust`, `population` (`GetScaledCityPopulationSize`), `communitiesSize`, and `communities` sorted by size with `community`, `size`, `standing`, `fervor`, plus `deathToll` (HUD death counter widget `TargetDeathCount`) and `deathsByCause` (death-meter script map). Not yet compared to the HUD faction bar or death counter (unverified); the death fields are absent when the widget does not exist. |
| `construction` | yes | every `PXConstructionComponent` not in state `Finished` | `state`, `target` (owner class), `district`, `progress` (0 to 1), `weeksLeft`, `ref`. |
| `quests` | yes | `PXQuestUtils.GetActiveQuests` | `class`, `name`, `description`, `weeksLeft` (omitted for endless quests), and `objectives` with `name` or `debug`, `progress`, `max`. A quest named `silent stat quest` produces no events. |
| `icons` | yes | visible `PXTrackerPanel` widgets | `kind` (widget class without `WBP_`/`_C`), `target`, `location`, `screen` (client pixel), `district`, `ref`. `all=true` includes hidden. Click one through the game with `open_icon ref=...`. |
| `districts` | no | `districtHolder.Districts` | Per city: `districts` with `ref` and `type`; `limit=100`. The richer view is the `districts` command. |
| `deposits` | no | every `PXDepositComponent` | Sorted by distance to the main city. `type`, `amount`, `location`, `distance`, `screen`. Args: `limit=30`, `type`, `maxDistance`. |
| `weather` | no (in `snapshot`) | `PXTemperatureComponent.CurrentTemperatureLevel`, `GetTemperaturePredictionInterval()` (168000 ticks = 100 weeks), `PXTemperatureUtils.GetTemperatureTimeline(ctx, PXTemperatureComponent, From, To)` -> `PXTemperatureTimelineChangeInfo[]` (`Timestamp`, `TemperatureLevel`, `TemperatureLevelChange`, `Weather`, `EnterWeatherIntersection`), `PXWeatherUtils.GetCityWeatherLevel` | `current` (`id`, `level`, `degrees`), `predictionWeeks`, `horizonWeeks` (the prediction interval by default, or `weeks=`), `forecast` [`atTicks`, `weeksFromNow`, `level`, `levelId`, `degrees`, `whiteout` (the storm reaches the city at this entry), `whiteoutEnds`], `whiteout` {`known`, `active`, `startsInWeeks`, `startsAtTicks`, `endsInWeeks`, `endsAtTicks`}, `storm` {`id`, `name`, `level`} ("Calm", level 0, with no storm; a whiteout is level 1+), `nowTicks`; `timelineError` when the call was refused. Level numbers rise as it gets colder. Measured mid-whiteout (week 226): `active: true`, storm "Sun-Dimming Storm", exit entry in 3.9 weeks with `TemperatureLevelChange -3` (level 4 to 1), then levels 2, 3, 2 at 14, 44 and 64 weeks. Measured at week 129: `active: false`, the whiteout entry 70.6 weeks out, its end 100.6 weeks out. `debug=true` adds `targetClass`, `entryStruct`, `entrySchema`, `entries`, `unparsed`. |

## `snapshot` command

`fp2 snapshot` returns the HUD in one call. Each section is wrapped so one failure yields `{error}` for
that section only.

| Key | Content |
|---|---|
| `date` | `ticks`, `week` (`floor(ticks/1680)`), `date` string, `dateDays`, `hours` |
| `pauseReasons`, `cutscene` | active pause reasons; `cutscene` is set when one contains `Cutscene` |
| `resources`, `needs`, `statistics`, `population`, `society`, `construction`, `quests`, `icons` | the extractors above |
| `modals` | open popups with `title`, `description`, `decision`, and `choices` (`index`, `name`, `description`, `effects`) |
| `research` | `supported`, `active`, `anyInProgress`, `topic`, `outcome`, `speed` |
| `council` | `active`, `inParliament`, `phase`, `minTicksToNextSession`, `ticksToForcedVote`, `agendaPolicy`, `seats`, `activePolicies` (the `parliament` ref is removed) |
| `generator` | `power`, `fuel`, `capacity`, `mode`, overdrive flags, `visibleModes` |
| `exploration` | `exploring` (`name`, `progress` 0 to 1, `explored`) and `revealed` (count of explorable territories) |
| `districts` | `type`, `id`, `buildings`, `underConstruction` per district |

The snapshot carries `districtDeposits` (extractor `districtDeposits`: `district` label, deposit `ref`, `type`, `amount` for each deposit a deposit-requiring district works, via `PXDepositUtils.GetDepositsUsedByDistrict`; inferred, not yet compared with the HUD) for `deposit.depleting`.
The snapshot carries `weather` (extractor `weather`, see above) for `weather.forecastDrop` and the whiteout events.
The snapshot has no `time` or `session` sections; use `date` and `pauseReasons`, or `extract name=time`.

## Turn events

`fp2 turn` returns these in `events`; each has `week`, `date`, `kind`, `detail`. Every event, including noise, is
appended to `.runtime/watch.jsonl`. Stop kinds by default: `dialog.opened`, `dialog.ackFailed`, `threat.warning`, `deaths.increased`,
`need.deficit`, `stock.runway` (10 weeks or less), `research.finished`, `research.idle`, `construction.finished`,
`council.sessionAvailable.changed` (session opens), `exploration.finished`, `temperature.changed`,
`building.unlocked`, `ability.available`, `district.deactivated`, `deposit.depleting` (10 weeks or less),
`weather.forecastDrop` (a drop of 2+ levels or to level 3 or colder), `whiteout.incoming`, `homeless.changed`. Noise kinds (`icons.changed`,
`game.paused`, `game.resumed`, `ui.pauseReasons.changed`, `stock.recovered`, `dialog.closed`, `stat.falling`,
`exploration.progress`, `construction.state`) are only counted in `dropped`.

| Event kind | Meaning | Reaction |
|---|---|---|
| `dialog.opened` | Modal or decision; `detail` has title, description, choices | `fp2 modals`, decide, `fp2 choose index=N` |
| `dialog.acknowledged` | `turn` dismissed a one-option dialog with no effects ("I see"); `detail` keeps its text | Read it; faction or story news |
| `threat.warning` | A one-option dialog whose title or text names a danger (whiteout, storm, blizzard, cold wave, temperature drop, mortal risk, generator failure, riot, uprising, civil war; `watch.ts` `THREAT_RE`). It was acknowledged, but it stops the turn; `detail.threat` is the matched word, `detail.source` `dialog`. Measured: the whiteout warning "An Old Enemy" came 73 weeks before the whiteout | `fp2 goals add horizon=threat priority=1 due=<week> expect=".."`; reorder the stack (SKILL.md thinking pattern 6, GAMEPLAY.md Whiteout playbook) |
| `dialog.ackFailed` | Auto-ack could not dismiss a one-option dialog (`detail.error`); the game stays paused | `fp2 modals`, then `fp2 choose index=0 ref=<modal ref>` |
| `notification` | Dialog without choices (population growth, info popup) | Read `detail`; usually no action |
| `research.idle` | Research is supported and active but no topic is in progress (`research.anyInProgress` false; measured: it sat idle for weeks, unflagged). Fires once on the move into idle; not emitted in the same poll as `research.finished` (that event already stops). Also returned once, without stopping, when a turn starts while idle (`detail.atStart`). `brief.alerts` repeats "research idle" every turn until a topic runs | `fp2 research_topics`, then `fp2 research_start topic=X` |
| `need.deficit` / `need.ok` | A need balance went below or back to 0 | Heating: see [GAMEPLAY.md](GAMEPLAY.md) Heat |
| `stock.runway` / `stock.recovered` | Stock runway crossed 20, 10, 5 or 2 weeks, or recovered | Fix the supply of that resource |
| `stat.rising` / `stat.falling` | A statistic crossed a 10-point band; `detail` has current and target | Treat Cold, Hunger, Tension, Sickliness, Crime, Squalor |
| `trust.up/down`, `standing.up/down` | Total trust or community standing crossed a 10-point band | `fp2 council`, `fp2 laws` |
| `construction.started/state/finished`, `research.started/finished` | Work began, changed or ended | Queue the next build or topic |
| `exploration.started/progress/finished`, `exploration.revealed.changed` | Exploration began, advanced a quarter, finished, or the revealed territory count changed | `fp2 territories`, then `fp2 explore` |
| `quest.progress` | Quest objective progress changed | `fp2 snapshot --fields quests` |
| `icons.changed` | Count of a map tracker kind changed (Bark icons ignored) | `fp2 extract name=icons`, `fp2 open_icon ref=..` |
| `council.sessionAvailable.changed`, `council.phase.changed`, `council.agenda.changed` | Council session opened or changed | See Council in SKILL.md |
| `ui.cutscene.changed`, `ui.pauseReasons.changed` | A cutscene or pause reason appeared or cleared | No input during a cutscene; skip with `fp2 keys e@3000` |
| `deaths.increased` | Death toll rose; `detail` has from, to, `byCause` | Find the cause (cold, hunger, sickness) and fix its need |
| `homeless.changed`, `temperature.changed`, `districts.changed`, `research.active.changed` | State flag changed | Re-read the relevant section |
| `district.deactivated` / `district.activated` | A district went off or on; `detail.reasons` (`NoDeposit`: deposit exhausted, `PlayerChoice`) | `NoDeposit`: expand onto a new deposit or build elsewhere before stocks run out |
| `deposit.depleting` | A deposit worked by a district (Extraction, ...) will run out soon: remaining weeks fell under 20, 10 or 5. `detail` has `district`, `type`, `amount`, `weeksLeft`, `weeksLeftUnder`. Weeks left = amount / amount lost per week between snapshots (samples persist in `.runtime/deposit-samples.json`; needs about half a week of data). Stops the turn at 10 or less | Expand onto a new deposit now: at 0 the district goes `NoDeposit`, its materials drop to 0 and every dependent Industry district goes `UnmetDemand` |
| `weather.forecastDrop` | The forecast shows a colder level than the one before it within 10 weeks; `detail` has `level`, `from`, `inWeeks`, `degrees`, `fromDegrees`, `whiteout`. Once per forecast entry (`.runtime/weather-warned.json`; a load to an earlier time re-arms it) | Add a due-dated goal; prepare heat before `inWeeks` (see GAMEPLAY.md Whiteout preparation) |
| `whiteout.incoming` / `whiteout.started` / `whiteout.ended` | A whiteout is forecast (`startsInWeeks`, `endsInWeeks`; once per whiteout; measured: fired at week 130 with startsInWeeks 69.6), began (the storm reached the city: `GetCityWeatherLevel` level 1+, "Calm" is level 0) or ended | Playbook in GAMEPLAY.md: threat goal now, shed list at `started`, restore one district at a time after `ended` |
| `building.unlocked`, `ability.available` | A building type or ability became available; `detail` has name, description, effects | Weigh it against the goal stack |
| `bridge.error` | A bridge call failed | `fp2 status`, then `fp2 recover` |

## Extension commands (measured 2026-10-11)

Commands from the extension modules `colony_actions`, `frostland_actions`, `society_actions` and `economy_actions`
(listed in `mod/FP2AgentBridge/Scripts/extensions.txt`). Game build 1.6.1 (630894) with Fractured Utopias and Breach
of Trust. "Measured" means a live call on one Sandbox / Utopia save ("The City", Edens Point, weeks 247-257).
"Untested" means never run live; "unverified" means read from code or dumps only. Check and cost getters
(`Can*`, `Get*Cost`) return FText structs, a crash class, so the bridge does not call them: dryRun cannot show the
game's verdict and the game validates the real call. Run a first live call of any command after `fp2 save`.

### Multi-city commands (`colony_actions`)

City selector: `city=`, `from=`, `to=`, `parent=` take the `index` printed by `fp2 cities` (the position among all
`PXCityComponent`s, `A.cities()`). A string matches the cityType id, the in-game name or a full ref. Without a
selector, colony commands use the main city (`PXNationUtils.GetPlayerMainCity`); older commands use the first city
in `A.cities()`, which need not be the main city.

| Command | Source | Fields | Measured notes | Risk and caveats |
|---|---|---|---|---|
| `cities` | `PXNationUtils` (`IsCityOwnedByPlayer`, `IsMainCityOfNation`, `GetPlayerMainCity`, `GetAllPlayerCities`), `PXCityUtils.IsCityAccessible`, `GetCityTensionStatistic` + `PXStatisticUtils`, `PXWorkforceUtils`, the `resources` extractor | Per player city: `index`, `ref`, `cityType`, `name`, `main`, `kind` (main/colony), `accessible`, `population`, `communitiesSize`, `founder`, `cityTypeLimits` (startCommunitySize, minimalCommunitySize, transportLimit, canBeAbandonedByPlayer), `workforce`, `unrest` (tension statistic), `stock` (food, coal, oil, materials, goods, prefabs, heatstamps, cores), `tradingUnlocked`, `hasTradeRoute`, `relocatingOut`, `selected`. `all=true` adds non-player cities. | One city, population 11998, before founding; two after. | Read only. Abandon and recolonize availability are not readable (`PXCheckResult` holds FText). |
| `colony_sites` | `frost_sites kind=colony`, `PXSiteUtils.CanShowBuildingColony`, `PXCityUtils.GetCityByType`, `GetCityConstructionDuration`, `PXUnitUtils.GetUnitCostFromCityConstructionCost`, `PXCityAreaUtils.GetCityAreaByType` | Per site: `name`, `canShow`, `built`, `cityRef`, `weeks`, `unitCost`, `areaSpawned`, `areaRef`. `details=true` adds `cityTypeProps`. | 3 sites; all 3 areas spawned, `canShow` true. Loch: `unitCost` `{LogisticsUnitsResource: -20}`, `weeks` 15. | `unitCost` may be only the founding unit's share. The full colony cost is an open question (MOD_GAPS). `GetCityConstructionCost` is FText and not called. |
| `colony_build` | `PXInstructionUtils.InstructBuildCity` (Leader origin, `sendUnit=true`) | args `site`, `community`, `parent`, `dryRun`. dryRun reports `cityType`, `areaRef`, `parent`, `community`, `communities`, `weeks`, `unitCost`. | `site=Loch` founded "Food Colony" instantly as city 2. Main city population 11998 -> 8998 (`StartCommunitySize` 3000 moved). No prefab, core or heatstamp change. Accepted with 0 free teams and 0 cores. | Mutates. It is unknown whether `InstructBuildCity` skips the cost check or Sandbox colonies are free. Save first; wait 60-90 s before further bridge calls if a level streams in. |
| `city_abandon` | `PXCityUtils.AbandonCity` (Leader origin) | args `city`, `confirm=true`, `dryRun`. | Only refusals measured: the main city and a missing `confirm` are refused. | Irreversible for the colony. A real abandon is untested. |
| `recolonize` | `PXCityUtils.RecolonizeCity` (Leader origin) | args `city`, `community`, `confirm`, `dryRun`. | Untested. | Refuses active player cities; a non-player city needs `confirm=true`. Cost is unread. |
| `trade_routes` | `PXTradeUtils` (`GetCityTradeRoute`, `GetTradedResources`, `GetTradeRouteResourceLimit`, `IsTradingUnlocked`), `PXTrailUtils` (`GetActorsConnectedTrailType`, `GetTrailTypeCapacity`), `TradeHolder` | `cities` (unlocked, visible, `routeCountLimit`, routes), `pairs` per ordered pair (limit, connected, trailType, trailCapacity, route), `tradable`. | After founding, both pairs already hold a `PXTradeComponent` route with empty resources. `tradingUnlocked` false, `routeCountLimit` 0, pair `limit` 0. | The `Resources` map key and value types do not resolve at runtime (MapProperty only). |
| `trade_route` | `InstructCreateTradeRoute` / `InstructUpdateTradeRoute` | args `to`, `from`, `resources` (JSON; aliases food, coal, oil, materials, goods; 0 stops one), `replace`, `unverifiedMap`, `dryRun`. dryRun reports `mapSignature`, `mapEvidence`, `limit`, `requestedTotal`, `sourceStock`. | dryRun: `mapSignature.ok` false, so the real call was refused. Trading is locked on this save. | The mutation is untested. A TMap built from a Lua table is unproven. Gates in order: key/value types, stored `PXTradeComponent.TradedResources` entries, then `unverifiedMap=true`. Fallback: the `PXColonyResourceTradePanel` handlers. |
| `transfer_people` | `PXUnitUtils.AssignUnitToRelocateCommunityOrder(ctx, unitType, src, tgt, community, amount)`; unit types from `PXGameplayUtils.GetUnitConfig()` | args `to`, `from`, `community`, `amount`, `unit`, `dryRun`. Result: `relocatingNow`, `relocatingAmount`, `targetSizeNow`. | Relocation-unit path (v2): unit `RelocateCommunityUnit`, `relocatingNow` true, amount 100, main city -100 at once, colony +0 until arrival, no stock change. Unit types in config: `RelocateCommunityUnit`, `ExplorationUnit`, `WanderersUnit_Sandbox`. | Arrival and any later cost are not recorded. v1 (`PXCityUtils.TransferCommunity`) moved 100 people instantly with no unit and no cost (cheat path), and was removed. |
| `colony_exchange` | Tension statistic reads as in `cities`; `FindAllOf("PXStockpileExchangeComponent")` (refs only) | `unrest` per player city; `exchangeComponents` (`count`, `refs`). | One `PXStockpileExchangeComponent` on the main city. | Unrest and component count only. The v1 read crashed the game (Wwise stack; see MOD_GAPS), so no function is called on the components. Offer and negotiation state are unread. |

### Frostland commands (`frostland_actions`)

| Command | Source | Fields | Measured notes | Risk and caveats |
|---|---|---|---|---|
| `frost_teams` | `EconomyHolder.TargetSupply/TargetDemand[LogisticsUnitsResource]`, `PXEconomyUtils.GetSupplyOfResource/GetDemandOfResource`, `city:GetDistricts()` | `total`, `inUse`, `free`, `check`, `logisticsDistricts`, `expeditions`, `constructedOutposts`. `breakdown=true` adds `byComponent`. | Teams are a flow resource: 15 per active Logistics district, 0 while the district was player-deactivated. Exploring Chilton Pass raised `inUse` by 10; `explore_stop` returned them (15/15). | Not compared with the HUD counter (unverified). |
| `explorations` | `GetTerritoriesByState`, `PXTerritoryUtils` (`GetTerritoryDifficulty`, `GetTerritoryBaseDifficulty`, `GetTerritoryExplorationTime`, `GetExplorationPreparationTime`, `GetTerritoryPossibleResources`) | Per territory: `state`, `charted`, `progress`, `explorationWeeks`, `weeksLeft`, `preparationWeeks`, `difficulty`, `possibleResources`, `neighbours`. `weather=true` adds the storm level. | 16 territories (5 explored, 11 unexplored). `explorationWeeks` 15 (Easy) and 25 (Hard). `weather=true` read Calm, level 0. | `weeksLeft` = `explorationWeeks` x (1 - `progress`) is inferred. `teamsRequired` is not readable: the exploration component and its economy maps hold no teams cost, so the cost shows only as the `frost_teams` delta (10 for Chilton Pass, Easy). `GetResearchedTerritoryRequirements` is FText and not read. |
| `explore_stop` | `PXInstructionUtils.InstructStopTerritoryExploration` on the territory's exploration component | args `territory`, `dryRun`. Result: `inProgressNow`. | `inProgressNow` false and teams refunded. | Progress is lost (research note). Use it to recall an expedition before a whiteout. |
| `outposts` | `PXOutpostUtils` getters (`GetAllConstructedOutposts`, `GetOutpostMainResource`, `GetOutpostCurrentDepositAmount`, `GetOutpostTimeToFinishExtraction`, `CanShowOutpostUpgrade`, ...), `PXActivityUtils.GetDeactivationReasons`, `PXTrailUtils.GetActorsConnectedTrailType` | `type`, `name`, `territory`, `mainResource`, `depositType`, `permanent`, `depleted`, `depositLeft`, `extractionWeeksLeft`, `teams`, `active`, `deactivationReasons`, `connectedCity`, `trailType`, `upgradesTo`, `canShowUpgrade`, `upgradeProgress`, `weather`, `cellIndex`, `actions`. | One Coal Mining Complex: `depositLeft` 50810, `extractionWeeksLeft` 36.3, inactive with `UnmetDemand` while teams were 0, `upgradesTo` `CoalPermamentSettlement`, `canShowUpgrade` true. | `actions` is always empty: `PXOutpostType` has no action list. |
| `outpost_active` | `InstructActivateLogic` / `InstructDeactivateLogic` with the PlayerChoice reason | args `ref` / `type` / `territory`, `active`, `dryRun`. | Toggling false and true set and cleared `DeactivationReason_PlayerChoice`. | Teams freed on deactivation is inferred. |
| `outpost_action` | `PXOutpostUtils.ExecuteOutpostAction` (Leader origin) | args `ref` / `type` / `territory`, `action`, `dryRun`. | Lists `[]`. | Unproven: no action list exists on the outpost type. `CanExecuteOutpostAction` is FText. Candidate for removal. |
| `outpost_upgrade` | `PXOutpostUtils.UpgradeOutpost` (Leader origin) | args `ref` / `type` / `territory`, `dryRun`, `debug`. | The real call on an outpost with `canShowUpgrade` true was refused by the game: no change, no cost. | The refusal reason is unreadable (FText check; the type holds a `PXBlueprintRequirement`). Upgrade cost unknown. |
| `trails` | `PXTrailUtils` (`GetAvailableTrailTypes`, `IsTrailTypeAvailable`, `GetTrailTypeCapacity`, `GetTrailTypeConstructionDuration`, `HasAnyConnection`), `FindAllOf PXTrailComponent` / `PXTrailEndpointComponent` | `types`, `trails`, `constructing`, `cityHasConnection`, `outpostLinks`, `endpoints`, `trailCellsSchema`. | `types` empty (no trail type available on this save), 221 endpoints, `cityHasConnection` true. `BuildTrail.trailCells` is `Array<Int>`. | Trail cost getters are FText and skipped. |
| `trail_plan` | `PXFrostlandDetailsSubsystem` (`GridCellSize`, `WorldSize`, `OutpostByDot`, `CityToCellMap`), trail metadata | `schema`, `grid`, `calibration`, `target`, `candidateCells`, `waypoints`, `chunks`, `weeks`. | `cellSize` 9000, `worldSize` 2016000 x 2016000 (224 columns). The outpost dot 17787 did not calibrate consistently as row-major or column-major. The ints are not city cell indices (1632 cells, 614 duplicate indices, none equal 17787). | `candidateCells` is unproven. `nearestTrailpoint` (`GetNearestTrailpointVector`) returns a denormal garbage Vector and is debug only. |
| `trail_build` | `PXInstructionUtils.BuildTrail(World, ownerCityId, trailType, origin, trailCells, chunks)` | args `cells=[ints]`, `chunks`, `trailType`, `dryRun`. | Gated: the cells format is unresolved and no trail type is available on the test save. Not run. | Needs a save with a trail type and a real trail `Path` to calibrate against. |
| `trail_tool` | Input-tool chain: `PXInputToolTypeUtils.ActivateTrailInputTool`, `PXPaintTrailInputTool.TryStartPainting`, `BuildTrail`, `DeactivateCurrentInputTool` | args `step=start/status/build/cancel`, `type`, `x`, `y`, `dryRun`. | Untested. `step=start dryRun=true` errors "no available trail type". | Needs a trail type; the painter route replaces the cells format. Run `step=cancel` if not built. |
| `build_outpost2` | `InstructConstructOutpost` via `GetSites` -> `PXSiteUtils.TryGetOutpostFromSite` (no `FindAllOf` walk) | args `ref` / `territory` + `type`, `dryRun`. | dryRun resolved the Huge Herd outpost at Faebait. | The real food-herd build is untested; `build_outpost` crashed there twice (MOD_GAPS). |

### Society and Council commands (`society_actions`)

| Command | Source | Fields | Measured notes | Risk and caveats |
|---|---|---|---|---|
| `factions` | `PXCityUtils.GetCityTensionStatistic`, `PXStatisticUtils`, `PXTrustUtils` (`GetTotalTrust`, `GetCommunityStanding`), `PXFactionUtils`, `PXCommunityUtils`, `PXDesireUtils.HasAnyMadePromises` / `GetCommunityPromises` | `totalTrust`, `population`, `tension` (`value`, `target`, `progress`), `contributors`, `fervorTotal`, `communities[]`: `id`, `name` (Machinists, Merchants, Foragers, Venturers, Menders), `faction`, `factionTrust`, `size`, `percent`, `seats`, `standing`, `fervor` (0..3), `hasPromises`, `promises[]` (`name`, `weeksLeft`, `objectives`). `detail=tiers,affinities,statuses,modifiers,desires,desirecomp,planned` adds opt-in reads. | `trustTier` Accepted at `totalTrust` 0.6. `standingTier`: 0.2 Favourable, 0.1 and 0 Neutral, -0.3 Opposing, -0.5 Hostile. Fervor 2 = tier Weak. `planned` lists the community type -> `PXDesire` after a negotiation is accepted. | `detail=affinities` is unverified (property path changed). Desire texts are FText and not readable. A story promise such as the "Unfair Stigma" hospital is a quest, not a community promise (`hasPromises` stayed false). |
| `vote_predict` | `PXParliamentUtils` (`GetRequiredVotesNumber`, `GetCommunitySupportToPolicy`, `GetAttitudeToPolicy`, `CanNegotiateWithCommunity`, `CanBypassVoteForCommunity`), parliament `VotingHistory` property | `policy`, `phase`, `requiredVotes`, `seats` (For, Against, Hesitant), `margin`, `swayable`, `swayMode`, `swayCost`, per-community `support`, `attitude`, `canNegotiate` + `reason`, `canBypass`. `detail=predict,history`. | `Food_Chaos`: `requiredVotes` 51, For 33 / Against 38 / Hesitant 29, `margin` -18. | `detail=promised` returned nothing and was removed. |
| `negotiate` | Parliament and hub widget state (`PXParliamentUtils`); `InstructBreakNegotiations` | Read: `canNegotiate` + `reason`, chamber `seats`, `margin`, panel visibility. | Read measured; out of session it errors "no policy on the agenda". | `cancel=true` is untested. The negotiation itself runs through `council_ui`. |
| `council_ui` | The Council hub widgets' own bound button events (see MOD_DEVELOPMENT, Council UI entry points) | State: `inParliament`, `phase`, `hub` panel visibility, `lobbyVisible`, `agendaPolicy`, `pauseReasons`. Steps: `laws`, `law policy=`, `select policy=`, `negotiate`, `community community=`, `side side=for/against`, `terms`, `term index=`, `accept`, `vote`, `sway mode=`, `change_proposal`, `sync`. | Full chain measured with the UI in sync: law list, policy list, propose (phase Agenda -> Negotiations), negotiate, group panel, side, term, accept (`plannedPromises` set), vote (LAW PASSED 55 For / 51 required), Escape (phase Maintenance). `step=terms` lists their terms in screen order. | `step=sway` and `step=change_proposal` are untested. Save before opening the Council. `select` needs the exact policy id from `fp2 laws` (the proposable list, not `all=true`). |
| `community_actions` | `PXCommunityActionUtils` (`GetVisibleCommunityActions`, `GetPossibleCommunityActions`, `GetCommunityActionCooldownTimeLeft`) | Per community: `actions[]` with `id`, `name`, `possible`, `cooldownWeeks`, `everExecuted`. `details=true` adds the asset dump. | Ids: `FundProjects_CA`, `Negotiate_CA`, `FactionSession_CA`, `RequestFunds_CA`, `GoodRelations_Deradicalisation_CA`, `DemandFunds_CA`, `HeatHomes_CA`. `CooldownPerCommunity` 33600 ticks (20 weeks). | `cooldownWeeks` = cooldown end time minus now. Descriptions and `IsActionPossible` text are FText. |
| `community_action` | `InstructCommunityAction` (Leader origin, `isForced=false`) | args `community`, `action`, `target`, `district`, `dryRun`. | `FundProjects_CA` on Merchants: heatstamps 2455 -> 2301 (-154), standing 0.2 -> 0.3, 20-week cooldown; a second call was refused. | Mutates; costs vary per action. |
| `promise` | Community actions of promise type | Reports the game's promise action, else points to the Council path. | dryRun measured: points to the Council path. | Promises are made in the negotiation (`council_ui step=accept`). |
| `promise_abandon` | `PXQuestUtils.FinishQuest(ctx, quest, false)` (default `path=quest`); `PXDesireUtils.AbandonPromise` (`path=abandon`) | args `community`, `promise` (index or name substring), `path`, `dryRun`, `force`. dryRun shows the class chain and the call. | `path=quest` is measured working. `path=abandon` crashed the game once with a valid `PXPromiseQuest` and needs `force=true`. | Do not use `path=abandon`. Standing likely drops (broken-promise penalty, unmeasured). The game has no UI to abandon a promise. |
| `sway` | `PXParliamentUtils` sway getters and setters (`GetSwayMode`, `GetSwayModifierCost`, `GetPredictedSwayEffectivness`, `SetSwayMode`, `ResetSwayMode`), `IsPolicySwayable` | `mode`, `cost`, `effectiveness`, `modes` (DoNotSway, SwayAye, SwayNay), `policy`, `swayable`. | Read measured. | Setting `mode=` is untested; availability (`IsSwayAvailable`) is not readable. |
| `propose` (guard) | `RequestSession`, overrides the core command | args `policy`, `skipRecess`, `dryRun`, `force`. | Refuses while the hub lobby is visible. | `force=true` skips the guard and reintroduces the UI desync crash. The guard lives in `society_actions.lua`; merge into `actions.lua` later. |

Unreadable (FText in struct returns, a crash class): desire lists and ranks, `IsNegotiationAvailable`,
`IsSwayAvailable`, `IsActionPossible`, community action descriptions, trust factor groups. Struct arrays returned by
getters (`GetCommunityCoreAffinities`, `GetLastVotingHistoryItems`) come back as copies whose fields cannot be read:
read the owning property instead.

### Economy reads (`economy_actions`)

| Command | Source | Fields | Measured notes | Risk and caveats |
|---|---|---|---|---|
| `health` | Composes the `resources`, `needs`, `statistics`, `population`, `society`, `construction`, `quests`, `weather` extractors, `generator`, `research`, `council`, plus `PXWorkforceUtils` | One call under about 3 KB: `verdict` (critical > act > watch > ok) with `reasons`, `gen`, `runway` (weeks under 20; bands ok >= 20, watch 10-20, act 5-10, critical < 5), `caps` (`!` = at cap and still gaining), `needDeficits`, `stats`, `tension`, `trust`, `deaths` (total, delta since the previous call), `population` (`total` = `society.population`, `unassigned`, `communities`), `homeless`, `work`, `research.idle`, `build`, `council`, `weather`, `quests`. | Week 247: coal runway 8 weeks, generator load 57.5 %, trust 0.562, tension 21. Council phase 1 with `minTicksToNextSession` 16800 constant means a session is available (the recess length is config), so `council.open` is right. | Trust and tension tier bands and the wear, load and whiteout bands are guesses (constants at the top of `economy_actions.lua`). `population.total` is not compared with the HUD counter (unverified). |
| `stock_caps` | `PXStockpileUtils.GetCityStockpileLimitOfResource`, `IsCityStockpileOfResourceFull`, `stockpile.StockLimits`, `stockpile.Modifiers`, `PXDistrictUtils` (`IsDistrictHub`, `GetDistrictConstructionCost`) | Per limited resource: `stock`, `limit`, `mapLimit`, `pct`, `perDay`, `weeksToCap`, `weeksToEmpty`, `wasted`, `raisedBy`. `hubs`, `activeSources`. | The limit raisers are district hubs: `FuelDepotHub` (coal and oil, +50000), `MaterialsDepotHub`, `GoodsDepotHub`, `FoodDepotHub` (+50000 each). Hub cost 80 heatstamps + 50 prefabs, 2 weeks, 100 workforce. | `limit` can differ from `mapLimit` (the map may be a base value, inferred). Other sources (laws, outposts, research) appear in `activeSources` only when active. Placing a hub with `place_district` is untested. |
| `heat_levels` | `PXHeatLevelComponent`, `PXHeatLevelType.IngameName`, `PXDistrictUtils.IsDistrictInsulated`, `PXCellProximityUtils`, joined to `heat` and `generator` | Per district: `lv` (HUD name Freezing, Very Cold, Cold, Chilly, Livable, Warm), `id`, `bad`, `insulated`, `warmedBy`, `alloc/need/adj`. `deep=true` adds `PXHeatManagementUtils` balance reads. | Per-district levels are readable (`HeatLevel_5_Livable`, `HeatLevel_0_NotActive`; insulated flag). | `deep=true` and the HUD-name mapping for every level are unmeasured. The allocation-to-level relation needs a before/after measurement. |
| `utopia_v2` | `fp2 utopia` base, `PXUtopiaToolsUtils`, `PXUtopiaToolPanelsUtils.GetScoreUIData`, `PXUtopiaToolComponent.ScoreTracker`, `PXCommunityUtils.GetCommunityCoreAffinities` | Per faction: `hasPoint`, `score`, `scoreTracker`, `counts`, `assignable` (Open nodes), `dominant`; `unlocks=true` adds node `grants`; `affinities=true`. | Venturers tree: 12 nodes (Hub unlocked, 3 open), `nextThreshold` 15, dominant faction Venturers. | Read only; spending a point stays `utopia-assign`. Where the lesser-faction agenda thresholds live is open. `GetNodeUIData` and `GetUtopiaToolGameplayDescription` return FText structs and are never called. |

## Ids

Resources: `Core_Heatnotes` (Heatstamps), `Core_FoodResource`, `CoalResource`, `OilResource`,
`Core_MaterialsResource`, `Core_PrefabsResource`, `Core_GoodsResource`, `CoresResource`,
`Core_PowerResource`, `LogisticsUnitsResource`, `MilitiaResource`.

Needs: `Shelter`, `Warmth`, `Heating`, `Nourishment`, `Possession`, `Maintenance`.

Statistics: `Cold`, `Hunger`, `Sickliness`, `Crime`, `Squalor`, `Tension`, `Homelessness`,
`ColonyUnrest`, `Wealth`, `CitySize`, `NationSize`.

Vote attitudes in `laws` come from `EPXVoteAttitude` (`fp2 enum name=EPXVoteAttitude`).
