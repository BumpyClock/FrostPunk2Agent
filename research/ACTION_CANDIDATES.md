# FP2 action/read candidates for the AI agent

Source: `fp2_functions.txt` (5,151 reflected UFunctions), `fp2_classes.txt`, `City/*.json` property dumps.
Labels: **[M]** measured (exact text in the dumps), **[I]** inferred from names/signatures, **[G]** guessed.
Call convention: `*Utils` / `*Subsystem` static funcs -> CDO (`/Script/Frostpunk2.Default__PXFooUtils`); member funcs -> live instance. `WCO` = any live game object (city component works).

---

## 0. Cross-cutting: roots, ActionOrigin, IDs, result structs

### Roots (start every state read here)
| Signature | Returns | Note |
|---|---|---|
| `PXNationUtils.GetPlayerNation(WorldContextObject:Object, ReturnValue:Object)` | PXNationComponent | [M] |
| `PXNationUtils.GetPlayerMainCity(WorldContextObject:Object, ReturnValue:Object)` | PXCityComponent | [M] |
| `PXNationUtils.GetAllPlayerCities(WorldContextObject:Object, ReturnValue:Array)` | cities (main + colonies) | [M] |
| `PXNationUtils.GetNationCities(Nation:Object, OnlyActive:Bool, ReturnValue:Array)` | | [M] |
| `PXSelectionUtils.GetCurrentCity(WorldContextObject:Object, ReturnValue:Object)` | city the camera is on | [M] |
| `PXCityComponent.GetDistricts / GetCommunities / GetMainDistrict / GetCityCells / GetCityArea` | member on city | [M] |
| `PXNationComponent.GetResearch(ReturnValue:Object)` | research component | [M] |
| `PXGeneratorUtils.GetGeneratorFromCity(City:Object, ReturnValue:Object)` | generator | [M]; city dump `Generator` prop = PXGeneratorComponent [M] |
| `PXPolicyUtils.GetPlayerPolicy(WorldContextObject:Object, ReturnValue:Object)` | policyComponent | [M] |
| `PXParliamentUtils.GetCurrentParliament(WorldContextObject:Object, ReturnValue:Object)` | parliament | [M] |

### ActionOrigin (Object, class `PXActionOrigin`, a data asset)
- Consumers: 50 functions take `ActionOrigin:Object` [M] (construction, dilemmas, abilities, policies, outposts, cities, trails, generator overdrive).
- Sources:
  - `PXGameplayUtils.GetActionOriginConfig(ReturnValue:Object)` -> `PXActionOriginConfig` [M]. Its fields (not in dumps) likely hold Player/Leader/Other origins [G]. Dump its props first.
  - Asset path seen: `/Game/Scenarios/Shared/Configs/ActionOrigin/DA_OtherActionOrigin.DA_OtherActionOrigin` (on a live `PXConstructionComponent.ActionOrigin`) [M]. Sibling assets likely `DA_PlayerActionOrigin` / `DA_LeaderActionOrigin` in same folder [G]; find with `FindAllOf("PXActionOrigin")`.
  - `PXDeconstructionComponent.GetActionOrigin(ReturnValue:Object)` [M]; `PXConstructionComponent` prop `ActionOrigin` [M] -> read from a player-made construction to capture the player origin [I].
  - `PXGameplayContextUtils.TryGetActionOriginFromGameContext(Context:Struct, ActionOrigin:Object, IsValid:Bool)` [M].
  - Check: `PXActionOriginUtils.IsActionMadeByLeader(ActionOrigin:Object, ReturnValue:Bool)` [M] - use to verify you hold the player/leader origin. Wrong origin may skip affinity/trust effects tied to leader choices [I].

### PXInstructionUtils = replay-recordable command layer (best "normal path")
`PXReplaySubsystem` / `PXReplayUtils` exist [M]; `Instruct*` variants take objects, plain variants take `Name` IDs (`World:Object, cityId:Name, ...`) [M]. Inferred: `Instruct*` = what UI calls (records + executes); ID variants = replay executors [I]. Prefer `Instruct*` where it exists; the ID variants are the only wrapper for PlaceDistrict/PlaceBuilding/ExpandArea/ExpandDistrict/UpgradeBuilding.
- IDs: city dump has `CityOfTypeId = "City_DA_City_EdensPoint_Startup_0"` [M] -> probably the `cityId:Name` [I]. District/Building IDs: `NextDistrictId`/`NextBuildingId` counters exist on city [M]; per-actor ID prop name unknown [G] - dump a district/building component to find it.

### Result structs
`Can*`/`Is*Detailed` mostly return `ReturnValue:Struct` (requirements check result) [M]; field layout not in dumps -> dump once with UE4SS and look for a bool like `bPassed`/`Result` [G]. `Get*GameplayDescription` returns `PXGameplayDescription`-like structs; `PXDescriptionUtils.IsGameplayDescriptionEmpty/IsGameplayDescriptionPositive/GetStockpileCostFromGameplayDescription/GetWorkforceFromGameplayDescription` decode them [M].

---

## 1. District construction, frostbreaking, deposits, buildings, deconstruction

### Place district
| Signature | Call on | Confidence |
|---|---|---|
| `PXInstructionUtils.PlaceDistrict(World:Object, cityId:Name, DistrictType:Object, cellIndices:Array, BuildingSlotPositions:Array, ActionOrigin:Object, ReturnValue:Object)` | CDO | High that it places a district on exact cells [I]; cellIndices = int cell indices [G]; BuildingSlotPositions maybe empty array OK [G] |
| `PXInputToolTypeUtils.TryBuildingDistrictOnChosenCell(WorldContextObject:Object, DistrictType:Object, selectedCity:Object, cityCell:Object, useOutOfBuildArea:Bool, instantConstruction:Bool, ReturnValue:Object)` | CDO | Easiest: one seed cell, game picks shape [I]. Pass `useOutOfBuildArea=false`, `instantConstruction=false` (true = cheat-like) |
| `PXInputToolTypeUtils.TryBuildingDistrictOnRandomDeposit(WorldContextObject:Object, DistrictType:Object, selectedCity:Object, useOutOfBuildArea:Bool, instantConstruction:Bool, DepositCategory:Object, ReturnValue:Object)` | CDO | Best for extraction districts on deposits [I] |
| `PXDistrictUtils.CreateDistrictOnFreeSpace(City:Object, DistrictType:Object, ActionOrigin:Object, ReturnValue:Object)` | CDO | Auto-placement; may bypass cost/validation [G] |
| `PXDistrictUtils.CreateDistrictOnFreeSpaceWithDeposits(City:Object, DistrictType:Object, ActionOrigin:Object, depositsToSpawn:Array, ReturnValue:Object)` | CDO | Spawns deposits -> scripting/debug-ish, avoid [I] |
| `PXInputToolTypeUtils.ActivatePaintDistrictInputTool(WorldContextObject:Object, DistrictType:Object, ReturnValue:Bool)` | CDO | UI path: activates paint tool; then cells need input [I] |
| `PXPaintDistrictInputTool.CanFinishDistrictFromCell(cityCell:Object, useOutOfBuildArea:Bool, ReturnValue:Bool)` | live tool from `PXInputToolUtils.GetActiveInputTool` | Validation per seed cell [M] |

Validation / reads (all [M]):
- `PXDistrictUtils.GetSupportedDistricts(City:Object, ReturnValue:Array)` -> DistrictType list.
- `PXDistrictUtils.CanConstructDistrict(City:Object, DistrictType:Object, ReturnValue:Bool)`, `PXDistrictUtils.HasUnlockedDistrict(City:Object, DistrictType:Object, ReturnValue:Bool)`, `PXDistrictUtils.IsDistrictSupported(...)`, `PXBuildingUtils.CanAffordDistrictAndBuildings(City:Object, DistrictType:Object, BuildingTypes:Array, ReturnValue:Struct)`.
- `PXDistrictUtils.GetDistrictConstructionCost(Nation:Object, Type:Object, includeModifiers:Bool, ReturnValue:Struct)`, `GetDistrictTypeGameplayDescription(Nation, Type, CityComponent, ReturnValue)`.
- `PXDistrictUtils.HasRequiredDeposits(DistrictType:Object, targetCityCells:Array, ReturnValue:Bool)`, `HasAnyBlockingDeposits(DistrictType:Object, targetCityCell:Object, ReturnValue:Bool)`, `IsDistrictRequiringDeposits(DistrictType:Object, ReturnValue:Bool)`.
- `PXInputToolTypeUtils.HasPaintDistrictInputToolError(WorldContextObject:Object, cityCell:Object, ReturnValue:Array)`, `IsCityCellBlockedByRuleSet(...)`, `IsCityCellAreaExpandedOrInProgress(cityCell:Object, ReturnValue:Bool)`.
- `PXCityCellUtils.GetCityCellsGameplayDescription(WorldContextObject:Object, Nation:Object, cityCells:Array, DistrictType:Object, ReturnValue:Struct)` - preview of placement effects (proximity) [M].

### Cells (selection by index / position)
- Cells: `PXCityComponent.GetCityCells(ReturnValue:Array)` -> `PXCityCellComponent`s [M]. Index: city dump has `CellIndex` prop on PXCityComponent [M]; cells very likely also expose `CellIndex` prop [G] -> use for `cellIndices`.
- Neighbours/borders: `PXDistrictUtils.GetEmptyDistrictNeighbourCells(District:Object, cellModesExcluded:Array, ReturnValue:Set)`, `PXCityCellUtils.GetUnoccupiedBorderCityCells(cityCells:Array, Depth:Int, excludeDeposits:Bool, ReturnValue:Set)`, `PXCityCellUtils.FindClosestCellByCenter(cityCells:Array, Point:Struct, ReturnValue:Object)`, `PXCityCellUtils.IsCityCellOutOfBuildArea(cityCell:Object, ReturnValue:Bool)` [M].
- Per cell: `PXCityCellComponent.GetCenterPosition(ReturnValue:Struct)`, `GetBounds2D`, `HasFilledDeposit`, `IsBlockedByNation` [M]; `PXCityCellRegionUtils.GetUsedCityCells(Actor:Object, ReturnValue:Array)` [M].
- `PXCityCellSubsystem` / `PXCityGridSubsystem` expose only events + `GetAreCityCellsVisible` [M] - no index lookup UFunction. `PXCityGridComponent` has no UFunctions [M].
- World->screen: **no FP2-native projection UFunction** [M: no ProjectWorld/ToScreen hits]. Use engine `PlayerController:ProjectWorldLocationToScreen` / `GameplayStatics:ProjectWorldToScreen` with `GetCenterPosition` [I]. Hover reads: `PXInteractionUtils.GetHoveredCell/GetHoveredDistrict/GetHoveredDeposit(WorldContextObject:Object, ReturnValue:Object)` [M].
- Camera: `PXPlayerContextUtils.FocusCameraOnActor(WorldContextObject:Object, TargetActor:Object, fixedZoomTime:Float, positionOffset:Struct, vicinityRadius:Float)`, `FocusCameraOnPosition(...)` [M].

### Frostbreaking (= Area Expander) [I: `PXAreaExpander*`, cheat `ExpandBuildableAreaUnderCursor(AreaExpanderType)`, `IsCityCellOutOfBuildArea`]
| Signature | Note |
|---|---|
| `PXInstructionUtils.ExpandArea(cityId:Name, expanderType:Object, cellIndices:Array, ActionOrigin:Object, ReturnValue:Bool)` | Main action; no World param [M] |
| `PXAreaExpanderUtils.GetSupportedAreaExpanders(City:Object, ReturnValue:Array)` | expander types [M] |
| `PXAreaExpanderUtils.CanConstructAreaExpander(City:Object, Type:Object, Cells:Array, ReturnValue:Struct)` | validate (Cells = cell objects) [M] |
| `PXAreaExpanderUtils.HasUnlockedAreaExpander(City:Object, Type:Object, ReturnValue:Struct)`, `GetAreaExpanderRequiredCellCount(Type:Object, ReturnValue:Int)`, `GetAreaExpanderConstructionCost(City, Type, Cells, ReturnValue)`, `GetAreaExpanderConstructionDuration(...)` | [M] |
| `PXAreaExpanderUtils.IsCellUnderExpansion(Cell:Object, ReturnValue:Bool)`, `GetCityCellsUnderExpansionInCity(City:Object, ReturnValue:Array)`, `GetDepositsUnderExpansionInCity(City:Object, ReturnValue:Array)` | progress reads [M] |
| `PXInputToolTypeUtils.ActivateAreaExpanderTool(WorldContextObject:Object, AreaExpander:Object, CityComponent:Object, ReturnValue:Bool)` + `HasAreaExpanderInputToolError(WorldContextObject:Object, cityCell:Object, ReturnValue:Array)` | UI path [M] |
| AVOID `PXAreaExpanderUtils.ExpandAreaAroundDistrict(District:Object, Radius:Int, expandUnderDistrict:Bool)` | instant, no cost [I] |

### Deposits (`PXDepositComponent`, `PXDepositType`, `PXDepositCategory`) - all [M]
- `PXDepositUtils.GetDepositCategoriesInCity(City:Object, ReturnValue:Array)`, `GetDepositsOfCategoryInCity(City, DepositCategory, ReturnValue)`, `GetDepositsOfTypeWithinBuildArea(City:Object, depositType:Object, ReturnValue:Array)`.
- `PXDepositUtils.GetExpandedCellWithDepositClosestToCity(City:Object, DepositCategory:Object, useOutOfBuildArea:Bool, ReturnValue:Object)` -> seed cell for `TryBuildingDistrictOnChosenCell` [I].
- `PXDepositUtils.GetCellFirstFilledDeposit(WorldContextObject:Object, cityCellComponent:Object, ReturnValue:Object)`, `GetDepositAmountLeftInCity(City, depositType, ReturnValue:Int)`, `GetDistrictDepositAmounts(District:Object, ReturnValue:Map)`, `HasDistrictAnyNearlyDepletedDeposits(...)`, `HasDistrictDepletedAllDeposits(...)`, `PXDistrictUtils.GetDistrictTimeToFinishExtraction(District:Object, ReturnValue:Struct)`.
- Typical flow: category -> `GetExpandedCellWithDepositClosestToCity` (or frostbreak first if `useOutOfBuildArea` cell is outside) -> `TryBuildingDistrictOnRandomDeposit` / `PlaceDistrict` [I].
- AVOID `PXDepositUtils.DestroyDepositsInCity` [M].

### Expansion / rebuild of existing district
- `PXInstructionUtils.ExpandDistrict(World:Object, districtExpansionId:Name, cellIndices:Array, BuildingSlotPositions:Array, freeCost:Bool)` - pass `freeCost=false` [M].
- `PXDistrictExpansionUtils.CanStartDistrictExpansion(WorldContextObject:Object, District:Object, ReturnValue:Struct)`, `IsDistrictSupportingExpansion(...)`, `CancelExpansion(...)`, `GetExpansionProgress(...)` [M]. `TryAutoExpandDistrict(WorldContextObject:Object, District:Object)` - unknown cost behaviour [G].
- `PXInputToolTypeUtils.ActivateExpansionInputTool(WorldContextObject:Object, districtComponent:Object, freeCost:Bool, ReturnValue:Bool)` [M].
- `PXDistrictUtils.RebuildDistrict(WorldContextObject:Object, District:Object, CellsToAdd:Array, CellsToRemove:Array, ActionOrigin:Object, BuildingSlotPositions:Array)`; cost `GetDistrictRebuildingCost(District:Object, ReturnValue:Struct)` [M].
- Enhancements (district upgrades, e.g. insulation) [I]: `PXEnhancementUtils.GetSupportedEnhancement(Owner:Object, ReturnValue:Set)`, `CanStartEnhancement(Owner:Object, Type:Object, ReturnValue:Struct)`, `TryStartEnhancement(WorldContextObject:Object, Owner:Object, Type:Object, ActionOrigin:Object, ReturnValue:Bool)` [M].
- Faction district: `PXDistrictCustomizationUtils.TryStartFactionDistrict(WorldContextObject:Object, Faction:Object, District:Object, Type:Object, ActionOrigin:Object, ReturnValue:Bool)` [M].

### Buildings inside districts
| Signature | Note |
|---|---|
| `PXInstructionUtils.PlaceBuilding(DistrictId:Name, BuildingType:Object, ActionOrigin:Object, OverridePlacementSlotIndex:Int, ReturnValue:Bool)` | slot -1 = auto [G] |
| `PXBuildingUtils.CreateBuilding(WorldContextObject:Object, District:Object, Type:Object, ActionOrigin:Object, ReturnValue:Object)` | object-based; validation depth unknown, call `CanConstructBuilding` first [I] |
| `PXBuildingUtils.UpgradeBuilding(WorldContextObject:Object, Building:Object, Type:Object, ActionOrigin:Object)` / `PXInstructionUtils.UpgradeBuilding(World:Object, BuildingId:Name, BuildingType:Object, ActionOrigin:Object)` | [M] |
| Validate: `PXBuildingUtils.CanConstructBuilding(District:Object, Type:Object, ReturnValue:Struct)`, `CanAffordBuilding(City, BuildingType, ReturnValue)`, `HasUnlockedBuilding(City, Type, ReturnValue:Struct)`, `HasRequiredDeposits(District, Type, ReturnValue:Bool)` | [M] |
| Types: `PXBuildingUtils.GetUnlockedBuildings(WorldContextObject:Object, ReturnValue:Array)`, `PXDistrictUtils.GetDistrictSupportedBuildings(Nation:Object, DistrictType:Object, ReturnValue:Array)`, `GetCompatibleDistrictsWithFreeSlots(CityComponent:Object, BuildingType:Object, ReturnValue:Array)`, `PXDistrictComponent.GetBuildingLimit/GetBuildings` | [M] |

### Construction control & deconstruction (all [M])
- `PXConstructionUtils.PauseConstruction/UnpauseConstruction(WorldContextObject:Object, Construction:Object)`, `CancelConstruction(WorldContextObject:Object, Actor:Object)`, `CanCancelConstruction`, `GetConstructionProgress(ActorComponent, ReturnValue:Float)`, `GetConstructionTimeLeft`, `IsActorUnderConstructionDetailed`.
- `PXDeconstructionUtils.CanStartDeconstruction(Actor:Object, ReturnValue:Struct)` -> `StartDeconstruction(WorldContextObject:Object, Actor:Object, ActionOrigin:Object, gameTimeOverride:Struct, shouldGiveRefund:Bool)` (pass default/zero time struct [G], refund=true). `CancelDeconstruction`, `GetDeconstructionRefund(Actor:Object, ReturnValue:Map)`.
- Repair: `PXRepairUtils.CanStartRepairing(Actor, ReturnValue:Struct)` -> `StartRepairing(WorldContextObject:Object, Actor:Object)`.
- Activate/deactivate district logic: `PXInstructionUtils.InstructActivateLogic(WorldContextObject:Object, Owner:Object)`, `InstructDeactivateLogic(WorldContextObject:Object, Owner:Object, Type:Object)`; checks `PXActivityUtils.CanActivateLogic`, `CanBeDeactivatedByPlayerDetailed(Owner:Object, ReturnValue:Struct)`.

---

## 2. Research / Idea tree (all [M] unless noted)
| Signature | Note |
|---|---|
| `PXInstructionUtils.InstructStartResearch(WorldContextObject:Object, Nation:Object, Community:Object, Topic:Object, Outcome:Object)` | preferred start [I] |
| `PXResearchUtils.StartResearch(WorldContextObject:Object, Nation:Object, communityComponent:Object, ResearchTopic:Object, ResearchOutcome:Object)` | direct |
| `PXResearchUtils.CancelResearch / PauseResearch / UnpauseResearch(WorldContextObject:Object, Nation:Object)` | |
| Topics: `GetAllResearchTopics(WCO, ReturnValue:Array)`; filter `IsResearchTopicAvailable(WCO, Nation, ResearchTopic, ReturnValue:Bool)`, `IsResearchTopicUnlockedCheck(... ReturnValue:Struct)`, `ShouldResearchTopicBeVisible`, `CanCityAffordResearch(ResearchTopic, City, ReturnValue:Struct)` | |
| Community (who designs it): `GetCommunitiesAvailableForResearchTopic(WCO, Nation, ResearchTopic, ReturnValue:Array)` | |
| Outcome: `GetMatchingOutcome(WCO, Nation, ResearchTopic, Community, ReturnValue:Object)` / `GetExpectedOutcome(...)` / `GetMatchingOutcomeForCommunityType(...)` | |
| Progress: `GetCurrentlyResearchedTopic(Nation)`, `GetResearchProgress(Nation:Object, ResearchTopic:Object, outProgress:Float, outTimeLeft:Struct)`, `GetFinalResearchDuration`, `GetResearchTopicCost`, `GetResearchPathTowards(WCO, Nation, Topic, includeResearchedOnes, ReturnValue:Array)`, `IsOutcomeResearched` | |
| Queue | **none found** [M: no research queue UFunction]. Agent must keep its own queue and start next on completion. |
| AVOID | `FinishResearchImmediately`, `SetResearchSpeedMultiplier`, `PXCheatManager.FinishCurrentResearch/UnlockAllResearchOutcomes/SetInstantResearchEnabled` |

---

## 3. Council / laws / policies / promises (all [M] unless noted)
Normal flow [I]: pick inactive policy -> (optional) negotiate/promise -> vote.
| Signature | Note |
|---|---|
| `PXInstructionUtils.InstructVote(WorldContextObject:Object, Policy:Object, ReturnValue:Struct)` | propose + vote; returns vote result [I] |
| `PXInstructionUtils.Vote(World:Object, Policy:Object, swayMode:Enum, ReturnValue:Struct)` | with sway mode |
| `PXInstructionUtils.InstructNegotiate(WorldContextObject:Object, Policy:Object, communityType:Object, bypassData:Struct)` / `InstructBreakNegotiations(WorldContextObject:Object)` | faction negotiation |
| `PXInstructionUtils.InstructRecountVotes(WorldContextObject:Object, Nation:Object)`; check `PXParliamentUtils.CanRecountVotes(WCO, Nation, didRequirementPass:Bool, ReturnValue:Bool)` | |
| `PXParliamentUtils.RequestSession(WorldContextObject:Object, Forced:Bool, optionalPolicy:Object, skipRecess:Bool, RequestedByCommunity:Object, ReturnValue:Bool)` | lower-level path; pair with `AddPolicyToAgenda`, `TryToFinishVote` [I] |
| `PXParliamentUtils.SetSwayMode(WCO, swayMode:Enum)`, `IsSwayAvailable/IsSwayVisibleForPolicy`, `GetSwayModifierCost` | |
| Prediction: `PXParliamentSubsystem.PredictVote(parliament:Object, Policy:Object, perCommunityResult:Map, ReturnValue:Struct)`, `PXParliamentUtils.GetPredictedVoteResultForCommunityType(WCO, parliment, Policy, communityType, outAttitude:Enum, ReturnValue:Struct)`, `GetRequiredVotesNumber`, `GetAttitudeToPolicy`, `CanNegotiateWithCommunity(parliament, communityType, Policy, outReason:Enum, ReturnValue:Bool)` | |
| Session state: `GetCurrentParliamentPhase`, `GetMinTimeToNextSession`, `GetTimeToForcedVote`, `IsInParliament`, `GetVotingHistory(...)`, `GetLastVotingHistoryItems` | |
| Policies: `PXPolicyUtils.GetAllInactivePolicies(policyComponent:Object, onlyUnlockedPolicies:Bool, ReturnValue:Array)`, `GetActivePoliciesMap`, `GetPoliciesInLaw`, `GetLawsInGroup`, `GetCategories`, `IsPolicyUnlocked`, `GetPolicyTypeGameplayDescription(Nation, Policy, ReturnValue)`; `PXParliamentUtils.IsPolicyChangingAgendaVisible` | |
| Promises: `PXDesireUtils.MakePromise(WorldContextObject:Object, communityType:Object, Desire:Struct, CustomParameters:Struct, applyOnPromiseMadeModifier:Bool, ReturnValue:Object)`; build Desire via `MakePolicyDesire(Policy, repeal, ReturnValue)` / `MakeBuildingDesire` / `MakeResearchOutcomeDesire`; check `CanDesireBePromised`, `CanCreatePromiseQuest`; read `GetCommunityPromises`, `GetCommunityTypePolicyDesires`; `AbandonPromise` | promise via UI likely during negotiation [I] |
| Cornerstones: `PXCornerstoneUtils.EmbraceCornerstone / RejectCornerstone(WCO, Cornerstone:Object)`, `GetReachedCornerstone` | |
| AVOID | `PXPolicyUtils.SetPolicyActive(policyComponent, Policy, ActionOrigin)` (bypasses vote [I]), `FixTheNextHoDVote`, `SetExternalVotes`, `SetCurrentPhase`, `SkipRecessTime`, `ForceRepresentativesSession`, `BypassVote`, `PXCheatManager.SetAlwaysPassPolicyCheat/SetInstantPolicyPassingCheat/TrailerRigVote` |

---

## 4. Frostland: exploration, units, outposts, colonies, trails (all [M] unless noted)
| Area | Signature | Note |
|---|---|---|
| Explore | `PXInstructionUtils.InstructStartTerritoryExploration(WorldContextObject:Object, exploration:Object, City:Object, unitCity:Object)` / `InstructStopTerritoryExploration(WCO, exploration)` | `exploration` = `PXTerritoryExplorationComponent` [I] (from territory actor, or `FindAllOf`) |
| | `PXTerritoryUtils.CanCityExploreTerritory(WCO, territory:Object, City:Object, ReturnValue:Struct)`, `FindClosestCityForExploration(WCO, Nation, territory, City)`, `GetTerritoriesByState(WCO, State:Enum, ReturnValue:Array)`, `GetAllTerritories`, `GetTerritoryPossibleResources`, `GetExplorationPreparationTime` | |
| | `PXTerritoryExplorationComponent.IsExplored/IsCharted/IsExplorationInProgress/GetExplorationPercentage` | |
| Outposts | `PXInstructionUtils.InstructConstructOutpost(WorldContextObject:Object, City:Object, Outpost:Object, ActionOrigin:Object)`; check `PXOutpostUtils.CanConstructOutpost(City, Outpost, ReturnValue:Struct)` | Outposts from `GetAllOutposts(WCO)`, `PXSiteUtils.TryGetOutpostFromSite` |
| | `PXInstructionUtils.InstructConnectOutpostToCity(WCO, Outpost, City)`; `PXOutpostUtils.CanConnectOutpostToCity` | |
| | `PXOutpostUtils.UpgradeOutpost(WCO, Outpost, UpgradedOutpostType, ActionOrigin)` + `CanUpgradeOutpost`; `ExecuteOutpostAction(WCO, Outpost, Action, ActionOrigin)` + `CanExecuteOutpostAction` | action objects source unknown [G] |
| Colonies | `PXInstructionUtils.InstructBuildCity(WorldContextObject:Object, parentCity:Object, CityArea:Object, CityType:Object, ActionOrigin:Object, communityType:Object, sendUnit:Bool, ReturnValue:Object)`; check `PXCityUtils.CanCreateCity(WCO, Nation, CityArea, CityType, ReturnValue:Struct)` | CityArea: `PXCityAreaUtils.GetCityAreaByType`, `PXSiteUtils.GetAllCitySpawnersSites` + `TryGetCitySpawnerComponentFromSite` [I]; `sendUnit=true` for normal travel [I] |
| | `PXCityUtils.RecolonizeCity`, `AbandonCity` (+ `CanRecolonizeCity`, `CanAbandonCity`), `ExecuteCityAction(WCO, City, Action, ActionOrigin)` + `CanExecuteCityAction` | |
| | `PXCityUtils.TransferCommunity(WCO, SourceCity, TargetCity, communityType, populationSize)` + `CanTransferCommunity`, `GetTransferCommunityCost` | |
| Units | `PXUnitUtils.AssignUnitToTransportResourcesOrder(...)`, `AssignUnitToRelocateCommunityOrder(WCO, unitType, SourceCity, TargetCity, Community, Amount, ReturnValue)`, `AssignUnitToExplorationOrder(WCO, unitType, SourceCity, territory, ReturnValue)`, `CancelOrder`; reads `GetAllActiveUnits`, `GetUnitOrderProgress`, `GetUnitPathDurationLeft` | unitType source: `GetUnitConfig` [G]; prefer the higher-level calls above |
| Trails | `PXInstructionUtils.BuildTrail(World:Object, ownerCityId:Name, trailType:Object, ActionOrigin:Object, trailCells:Array, chunksCount:Int, ReturnValue:Object)` | trailCells format unknown [G] |
| | UI path: `PXInputToolTypeUtils.ActivateTrailInputTool(WCO, trailType, ReturnValue:Bool)` -> `PXPaintTrailInputTool.TryStartPainting(worldPos:Struct, canEnterSelectingStartPoint:Bool)` -> `CanBuildTrail` -> `BuildTrail()` | [I] |
| | `PXTrailUtils.GetAvailableTrailTypes(WCO, Nation, ReturnValue:Array)`, `CanCityAffordTrailCreation`, `AreActorsConnectedWithTrail`, `GetTrailCost` | |
| Dilemma sites | `PXSiteUtils.TryGetDilemmaFromSite(WCO, Site, ReturnValue:Object)` -> see area 7 | |
| AVOID | `PXTrailUtils.ConnectActorsWithTrailImmediately`, `PXOutpostUtils.SpawnOutpost*/DestroyOutpost/ReplaceWithOutpost`, `PXTerritoryUtils.SetExplorationTimeScale/SetTerritoryExplorationState`, `PXCityUtils.CreateCity` (no cost path [I]), `PXCheatManager.RevealWholeFrostland/SpawnColonyAndConnectWithTrail` | |

---

## 5. Generator, heat, resources, workforce, priorities (all [M] unless noted)
| Signature | Note |
|---|---|
| `PXGeneratorUtils.SetGeneratorOverdriveActive(WorldContextObject:Object, Generator:Object, Active:Bool, ActionOrigin:Object)`; check `CanActivateOverdriveDetailed(WCO, Generator, ReturnValue:Struct)` | overdrive |
| `PXGeneratorUtils.SetActiveGeneratorMode(WorldContextObject:Object, Generator:Object, Mode:Object)`; check `CanActivateGeneratorMode(WCO, Generator, Mode, ReturnValue:Struct)`; modes `GetActivableGeneratorModes / GetVisibleGeneratorModes` | no ActionOrigin; likely UI path [I] |
| `PXGeneratorUtils.SetActiveSwitchableAbility(WCO, Generator, generatorMode, Ability, ActionOrigin)` + `GetSwitchableAbilitiesForGeneratorMode` | fuel/mode sub-options |
| `SetGeneratorResourcesOrder(WCO, Generator, newResourcesOrder:Array)`, `SetGeneratorResourcesOrderAutoAllocate(WCO, Generator, IsActive)`, `SetGenerateSurplus(WCO, Generator, Active)` | fuel priority |
| Reads: `GetGeneratorCapacity`, `GetGeneratorPowerLimit`, `GetGeneratorIntake`, `GetNonGeneratorPowerBalance`, `IsGeneratorOverdriveActive`, `PXGeneratorComponent.GetCurrentMode/GetPowerProduction` | |
| Heat: `PXHeatManagementUtils.SetHeatAllocationAdjustmentLevel(WCO, heatAllocation:Object, adjustment:Int)` + `CanSetHeatAllocationAdjustmentLevel`; holder-wide `IncreaseHeatAllocationLevelsInHolder / DecreaseHeatAllocationLevelsInHolder / DistributeAvailableHeat / SetHeatAutoAllocation(WCO, heatAllocationHolder, IsActive)` | objects: `FindAllOf("PXHeatAllocationComponent")`, `FindAllOf("PXHeatAllocationHolderComponent")` (`GetGenerator` links holder to generator) [I] |
| Efficiency (work intensity per district?) [I]: `PXEfficiencyUtils.TryChangeEfficiencyLevel(WCO, Actor, Level, ReturnValue:Struct)`, `IncreaseEfficiency/DecreaseEfficiency`, `GetSupportedEfficiencyLevels`, `CanChangeEfficiencyLevel` | |
| Resources reads: `PXStockpileUtils.GetCityStockpileOfResource(City, Resource, ReturnValue:Int)`, `GetCityStockpileChangeOfResource`, `GetCityStockpileLimitOfResource`; `PXEconomyUtils.GetSupplyOfResource/GetDemandOfResource/GetTargetBalance(City, ReturnValue:Map)`; `PXNeedUtils.GetCityNeedsFulfilled/GetCityNeedsRequired`; `PXStatisticUtils.GetVisibleStatistics/GetCurrentStatisticValue` (tension, squalor, etc.) | Resource objects from `PXTradeUtils.GetNationTradableResources(Nation)` or map keys of `GetTargetBalance` [I] |
| Workforce reads: `PXWorkforceUtils.GetCityAvailableWorkforce/GetCityRequiredWorkforce/GetCityTotalWorkforce/GetCityUnemploymentPercentage` | |
| Resource allocation: read-only `PXResourceAllocationUtils.GetResourceAllocationLevel/Amount/Progress(City, Allocation, ...)` | **no setter UFunction** [M] |
| Priorities: `PXPriorityComponent` only props (`BasePriority`, `TotalPriority`) [M]; **no setter UFunction** [M] | |
| AVOID | `PXStockpileUtils.TryChangeCityStockpile/TryChangeNationStockpile` (direct stockpile edits), `PXCheatUtils.CheatSetNoCostGeneratorModeChange`, `PXCheatManager.ForceGeneratorMode/ChangeStockpile*/SetTarget*`, `PXSkipGeneratorController.UpgradeGenerator`, `ResetActivatedGeneratorModes` |

---

## 6. Trade
| Signature | Note |
|---|---|
| `PXInstructionUtils.InstructCreateTradeRoute(WorldContextObject:Object, SourceCity:Object, TargetCity:Object, Resources:Map, ReturnValue:Object)` | Resources = Map<ResourceObject,int> [I] |
| `PXInstructionUtils.InstructUpdateTradeRoute(WorldContextObject:Object, tradeRoute:Object, TargetCity:Object, Resources:Map)` | set map to 0 to stop [G] |
| Checks/reads: `PXTradeUtils.IsTradingUnlocked(City)`, `CanActivateTradeRoute(tradeRoute, ReturnValue:Struct)`, `GetTradeRouteResourceLimit(WCO, SourceCity, TargetCity, ReturnValue:Int)`, `GetTradeRoutes(City)`, `GetCityTradeRoute(SourceCity, TargetCity)`, `GetTradedResources`, `HasInsufficientResources` | [M] |
| Colony/foreign exchange (stockpile exchange) | `PXStockpileExchangeUtils.ProposeOffer(WCO, Exchange, youSell:Map, youBuy:Map, ColonySellActions:Array, ColonyBuyActions:Array)`, `CalculateNegotiationChance(...)`, `MarkOfferAcceptedByPlayer(WCO, Exchange)`, `PostponePlayerAccept`, `BreakNegotiationsByPlayer`, `DeliverResources(WCO, StockpileExchange, ReturnValue:Bool)`, `GetLastOffer`, `GetStockpileExchangeByCityType(WCO, colony, ReturnValue)`; component `GetCurrentState/IsWaitingForAcceptOfColonyOffer` | [M]; avoid `SetColonyStockpileExchangeAcceptMultiplier`, `SetColonyResourceInterestValue`, cheat `SetStockpileExchangeAlwaysAcceptOffer` |

---

## 7. Dilemmas, decisions, additional choices, modals
| Signature | Note |
|---|---|
| `PXInstructionUtils.InstructResolveDilemma(WorldContextObject:Object, Nation:Object, Dilemma:Object, choiceId:Int, ActionOrigin:Object)` | Frostland dilemma (site) [M] |
| `PXDilemmaUtils.CanExecuteDilemmaChoice(WCO, Nation, Dilemma, choiceId, ReturnValue:Struct)`, `CanShowDilemmaChoice`, `GetDilemmaChoiceGameplayDescription(Nation, Dilemma, choiceId, ReturnValue)`, `GetDilemmaDescriptionText`, `IsDilemmaInState`, `IsDilemmaResolved`, `GetAllDilemmas(WCO, ReturnValue:Array)` | [M]; avoid `ResolveDilemma(... forceResolve:Bool)` with force=true, `ResolveDilemmaWithoutChoice`, `Spawn*`, `PXSkipDilemmasController.ForceDilemmaResolve` |
| `PXInstructionUtils.SelectChoice(World:Object, Channel:Class, ChoiceIndex:Int, ClosePanel:Bool)` / `CheckSelectChoice(...)` | communication-channel event popups (story decisions); Channel = a `PXCommunicationChannelDefinition` subclass [I] |
| `PXCommunicationChannelWidget.OnChoiceButtonClicked(Decision:Object, ChoiceIndex:Int, ClosePanel:Bool)` | live widget; exact UI click path [I] (`FindAllOf("PXCommunicationChannelWidget")`) |
| `PXModalsManagementSubsystem.SelectModalChoice(Widget:Object, ChoiceIndex:Int)` | generic modals [M] |
| Decision reads: `PXDecision.GetChoices / GetName / GetDescription / GetSelectedChoice`; `PXDecisionUtils.GetVisibleChoices(WCO, Decision, ReturnValue:Array)`, `GetChoiceRequirementsCheckResult(WCO, Decision, decisionChoice:Struct, ReturnValue:Struct)`, `GetDecisionChoiceAsGameplayDescription` | [M]; live decisions via `FindAllOf("PXDecision")` [G] |
| Open trackers: `PXInstructionUtils.OpenCommunicationTracker(World:Object, trackerIndex:Int)`; `PXCommunicationChannelsUtils.HasOpenCommunicationChannelWidget(WCO, WidgetClass, ReturnValue:Bool)` | [M] |
| Additional choices (context actions on actors): `PXAdditionalChoiceUtils.GetAdditionalChoicesForActor(Actor, ReturnValue:Array)`, `CanExecuteAdditionalChoice(WCO, choice, Nation, contextActor, ReturnValue:Struct)`, `ExecuteAdditionalChoice(WCO, Nation, Actor, additionalChoice)` | [M] |
| Quests (read): `PXQuestUtils.GetActiveQuests(WCO, ReturnValue:Array)`, `GetQuestTimeLeft` | avoid `FinishQuest/FinishObjective/DismissQuest/Start*` |
| AVOID | `PXCheatManager.SelectDecisionChoice(Decision, choice)` (cheat path; fallback only) |

---

## 8. Factions / communities: trust, relations, actions, protests (all [M] unless noted)
| Signature | Note |
|---|---|
| Community actions (gatherings, crackdowns, etc. [I]): `PXInstructionUtils.InstructCommunityAction(WorldContextObject:Object, Action:Object, ActionOrigin:Object, actingCommunity:Object, isForced:Bool, OptionalDistrict:Object, OptionalTargetCommunity:Object)` | `isForced=false` |
| `PXCommunityActionUtils.GetVisibleCommunityActions(WCO, communityType, onlyVisibleOnFactionPanel, ReturnValue:Array)`, `GetPossibleCommunityActions`, `IsActionPossible(WCO, Action, Community, ReturnValue:Struct)`, `GetCommunityActionCooldownTimeLeft`, `GetCommunityActionGameplayDescription` | avoid `ResetCooldown` |
| Trust reads: `PXTrustUtils.GetTotalTrust(WCO, Nation)`, `GetFactionTrust(WCO, Nation, Faction)`, `GetCommunityStanding(WCO, Nation, Community)`, `GetTrustFactorGroups` | avoid `ChangeCommunityStanding/ChangeFactionTrust/ChangeTotalTrust` |
| Factions: `PXFactionUtils.GetFormedFactions(WCO, FormedFactions:Array)`, `GetAllValidFactions(Nation)`, `GetCommunityFromFaction`, `GetMembersFromCity`, `AreOpposing`, `GetFactionTypesRequiringPolicy` | avoid `FormFaction` |
| Communities: `PXCommunityUtils.GetAllCommunitiesFromNation(Nation)`, `GetCommunitySize`, `GetCommunityGameplayDescription`, `PXCommunityComponent.GetCommunityType/GetFaction/GetCommunitySize` | avoid all `Change*Size`, `Transfer*Size*`, imprint edits, batch edits |
| Demands/desires: `PXDesireUtils.GetCommunityTypePolicyDesires / GetCommunityTypeBuildingDesires / GetCommunityTypeResearchDesires / GetDesiresSortedByRank`; `PXFactionUtils.AreDemandRequirementsMet` | respond via promise (area 3) |
| Protests/ongoing actions (read): `PXOngoingActionUtils.GetDistrictsWithOngoingActions(WCO)`, `GetActiveOngoingActionForCommunity`, `GetOngoingActionProgress(WCO, OngoingAction, actionProgress, resolveProgress, progressDuration)`, `GetOngoingActionWholeCollapseProgress` | |
| Respond to protest: district abilities e.g. `DA_NegotiateEndtoProtest_DistrictAbility`, FactionWar `DA_Crush_*`, `DA_EnforcePeace_*`, `DA_Protect_*` [M asset paths] -> via area 10 ability call | [I] |
| AVOID | `ForceStartOngoingAction`, `EndOngoingAction*`, `RequestOngoingAction`, `SpreadOngoingAction*`, `SetStartingOngoingActionBlocked`, `PXUtopiaToolsUtils.AddUtopiaToolBonusPoint` |

---

## 9. Time / pause / speed / saving (all [M])
| Signature | Note |
|---|---|
| `PXTimeUtils.SetPausedByPlayer(WorldContextObject:Object, paused:Bool)` | player pause (preferred) |
| `PXTimeUtils.SetGameSpeedLevel(WorldContextObject:Object, gameSpeedLevel:Enum, changedByPlayer:Bool)` | `changedByPlayer=true`; enum values unknown, read `GetGameSpeedLevel` first [G] |
| `PXTimeUtils.Pause/Unpause(WCO, pauseReason:Name)` | custom reason name -> agent-owned pause lock [I] |
| Reads: `GetCurrentGameTime`, `ConvertGameTimeToDate`, `IsPaused`, `IsPausedByPlayer`, `GetPauseReasons`, `GetGameSpeed`; `PXTimeSubsystem.GetTotalDays/GetHours(gameTime)` | |
| Save: `PXSaveSubsystem.SaveGame(SaveName:Str, overrideSave:Bool, SaveType:Enum, ReturnValue:Bool)`; `AreSavesPending`; `GetSaveFileNames`; UI path `PXSaveSubsystemUIUtils.CreateNewSaveSlot(WCO, saveSlotNameText:Text)` | Subsystem instance via `FindFirstOf("PXSaveSubsystem")` [I] |
| AVOID | `SetGameTimeOverride`, `SetStartDateOverride`, `LockTimeSpeed`, `SetLoadingLock`, `DeleteSaveGame/DeleteAllSaveGames/DeleteSaveSlot`, `ForceLoadGame` |

---

## 10. Abilities, operations, tasks (all [M] unless noted)
| Signature | Note |
|---|---|
| `PXInstructionUtils.InstructSetActorAbilityActive(WorldContextObject:Object, Owner:Object, Ability:Object, Active:Bool, ActionOrigin:Object)` | preferred [I] |
| `PXAbilityUtils.ActivateActorAbility(WorldContextObject:Object, Actor:Object, Ability:Object, ActionOrigin:Object)` / `DeactivateActorAbility(...)` | direct |
| Checks: `IsActorAbilityAvailable(WCO, Actor, Ability, ReturnValue:Struct)`, `CanAffordActorAbility(Actor, Ability, ReturnValue:Struct)`, `HasActorUnlockedAbility`, `IsActorAbilityActive`, `GetActorAbilityState(WCO, Actor, Ability, ReturnValue:Struct)` | |
| Lists: `GetActorVisibleAbilities(WCO, Actor, ReturnValue:Array)`, `GetActiveAbilitiesForActor`, `GetAbilitiesOfCategoryForActor`, `GetAbilityGameplayDescription(WCO, Nation, Ability, contextActor, ReturnValue)` | Actor = city actor (city-wide: MartialLaw, EmergencyCouncilSession, RushResearch, cornerstone abilities [M asset paths]) or district actor (Asbestos_CleanUp, Contain_Aggressor, Stage_Coup, protest/faction-war abilities [M]) |
| Operation tasks: `PXOperationTaskUtils.CanStartOperationTask(Actor:Object, taskClass:Class, Cost:Struct, ReturnValue:Struct)`, `IsUnderAnyOperationTaskDetailed`, `GetCurrentOperationTaskProgress`, `CancelCurrentOperationTask`, `PauseCurrentOperationTask/UnpauseCurrentOperationTask` | **no start UFunction** [M]; tasks started via Enhancement/Rebuild/Repair paths [I] |
| `PXOperationUtils.GetStockpileCostFromOperationCost / GetWorkforceCostFromOperationCost / GetDurationFromOperationCost(operationCost:Struct, ...)` | decode cost structs |
| `PXTaskSubsystem.*QueuedTasks*` | internal task-queue lock; AVOID |

---

## 11. Avoid list (cheat/debug/scripting)
- Classes: `PXCheatManager` (93 funcs), `PXCheatUtils`, `PXCheatSubsystem`, `PXCityCheatSubsystem`, `PXSkip*` (Skip controllers: `ForceDilemmaResolve`, `SpawnMissing*`, `UpgradeGenerator`), `PXDebug*`, `PXAutomationScript`, `PXTwitch*`.
- Direct state writes: `PXStockpileUtils.TryChange*Stockpile`, `PXTrustUtils.Change*`, `PXCommunityUtils.Change*/Transfer*`, `PXCommunityBatchUtils.Change*/Create*/Delete*`, `PXStatusUtils.SetStatus*`, `PXStateUtils.Set*`, `PXTemperatureUtils.Set*/Add*`, `PXWeatherUtils.Schedule*/Spawn*`, `PXStoryUtils.Force*/Start*`, `PXQuestUtils.Finish*/Add*`, `PXScenarioGameplayUtils.StartChapter/EndLastChapter`, `PXNationUtils.ChangeNationOfCity/SetCurrentPlayerNation`, `PXGameplayUtils.DestroyGameplayActor`, `PXBlockageUtils.SetActionBlocked`, `PXActivityUtils.Block*/RemoveDeactivationReason`.
- Instant/no-cost toggles: any arg named `instantConstruction`, `freeCost`, `forceResolve`, `isForced`, `noCost` -> pass false.

## 12. Open questions to resolve in-game (cheap probes)
1. Dump `GetActionOriginConfig()` props; list `FindAllOf("PXActionOrigin")` names; confirm player origin with `IsActionMadeByLeader`.
2. Dump one `PXCityCellComponent`, `PXDistrictComponent`, `PXBuildingComponent` for ID/`CellIndex` prop names (needed by ID-based `PXInstructionUtils` calls).
3. Dump a `Can*` result struct to learn the pass/fail field.
4. Test `TryBuildingDistrictOnChosenCell(..., instantConstruction=false)` on a pause: confirm cost is charged and a construction component appears.
5. Enum values for `gameSpeedLevel`, `swayMode`, `SaveType`, territory `State`.
