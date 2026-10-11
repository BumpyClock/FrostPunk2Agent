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
The snapshot has no `time` or `session` sections; use `date` and `pauseReasons`, or `extract name=time`.

## Turn events

`fp2 turn` returns these in `events`; each has `week`, `date`, `kind`, `detail`. Every event, including noise, is
appended to `.runtime/watch.jsonl`. Stop kinds by default: `dialog.opened`, `dialog.ackFailed`, `deaths.increased`,
`need.deficit`, `stock.runway` (10 weeks or less), `research.finished`, `construction.finished`,
`council.sessionAvailable.changed` (session opens), `exploration.finished`, `temperature.changed`,
`building.unlocked`, `ability.available`, `district.deactivated`, `deposit.depleting` (10 weeks or less), `homeless.changed`. Noise kinds (`icons.changed`,
`game.paused`, `game.resumed`, `ui.pauseReasons.changed`, `stock.recovered`, `dialog.closed`, `stat.falling`,
`exploration.progress`, `construction.state`) are only counted in `dropped`.

| Event kind | Meaning | Reaction |
|---|---|---|
| `dialog.opened` | Modal or decision; `detail` has title, description, choices | `fp2 modals`, decide, `fp2 choose index=N` |
| `dialog.acknowledged` | `turn` dismissed a one-option dialog with no effects ("I see"); `detail` keeps its text | Read it; faction or story news |
| `dialog.ackFailed` | Auto-ack could not dismiss a one-option dialog (`detail.error`); the game stays paused | `fp2 modals`, then `fp2 choose index=0 ref=<modal ref>` |
| `notification` | Dialog without choices (population growth, info popup) | Read `detail`; usually no action |
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
| `building.unlocked`, `ability.available` | A building type or ability became available; `detail` has name, description, effects | Weigh it against the goal stack |
| `bridge.error` | A bridge call failed | `fp2 status`, then `fp2 recover` |

## Ids

Resources: `Core_Heatnotes` (Heatstamps), `Core_FoodResource`, `CoalResource`, `OilResource`,
`Core_MaterialsResource`, `Core_PrefabsResource`, `Core_GoodsResource`, `CoresResource`,
`Core_PowerResource`, `LogisticsUnitsResource`, `MilitiaResource`.

Needs: `Shelter`, `Warmth`, `Heating`, `Nourishment`, `Possession`, `Maintenance`.

Statistics: `Cold`, `Hunger`, `Sickliness`, `Crime`, `Squalor`, `Tension`, `Homelessness`,
`ColonyUnrest`, `Wealth`, `CitySize`, `NationSize`.

Vote attitudes in `laws` come from `EPXVoteAttitude` (`fp2 enum name=EPXVoteAttitude`).
