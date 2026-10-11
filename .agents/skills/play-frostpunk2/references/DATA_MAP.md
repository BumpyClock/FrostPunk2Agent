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
| `quests` | yes | `PXQuestUtils.GetActiveQuests` | `class`, `name`, `description`, `weeksLeft` (omitted for endless quests), and `objectives` with `name` or `debug`, `progress`, `max`. A quest named `silent stat quest` is ignored by the watcher. |
| `icons` | yes | visible `PXTrackerPanel` widgets | `kind` (widget class without `WBP_`/`_C`), `target`, `location`, `screen` (client pixel), `district`, `ref`. `all=true` includes hidden. Click one through the game with `open_icon ref=...`. |
| `districts` | no | `districtHolder.Districts` | Per city: `districts` with `ref` and `type`; `limit=100`. The richer view is the `districts` command. |
| `deposits` | no | every `PXDepositComponent` | Sorted by distance to the main city. `type`, `amount`, `location`, `distance`, `screen`. Args: `limit=30`, `type`, `maxDistance`. |

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
| `districts` | `type`, `id`, `buildings`, `underConstruction` per district |

The snapshot has no `time` or `session` sections; use `date` and `pauseReasons`, or `extract name=time`.

## Ids

Resources: `Core_Heatnotes` (Heatstamps), `Core_FoodResource`, `CoalResource`, `OilResource`,
`Core_MaterialsResource`, `Core_PrefabsResource`, `Core_GoodsResource`, `CoresResource`,
`Core_PowerResource`, `LogisticsUnitsResource`, `MilitiaResource`.

Needs: `Shelter`, `Warmth`, `Heating`, `Nourishment`, `Possession`, `Maintenance`.

Statistics: `Cold`, `Hunger`, `Sickliness`, `Crime`, `Squalor`, `Tension`, `Homelessness`,
`ColonyUnrest`, `Wealth`, `CitySize`, `NationSize`.

Vote attitudes in `laws` come from `EPXVoteAttitude` (`fp2 enum name=EPXVoteAttitude`).
