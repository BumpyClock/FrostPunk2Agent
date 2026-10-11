# Data map

Where game data lives and how extractors read it. Verified against FP2 build with
UE 5.4.3 and UE4SS experimental 3.0.1-1164 (2026-10-11). "Measured" = compared to the HUD.

## Object model

- World subsystems: `PX*Subsystem` (e.g. `PXTimeSubsystem`). Mostly logic; little state.
- City actor `BP_BaseCity_C` holds ~50 components (`./fp2.exe components ref=first:BP_BaseCity_C`).
  `PXCityComponent` links them: `stockpile`, `EconomyHolder`, `NeedHolder`,
  `statisticHolder`, `WorkforceHolder`, `peopleAllocationHolderComponent`,
  `districtHolder`, `CommunitiesHolder`, `Generator`, `Nation`, `CityType`.
- Game definitions are data assets: `/Game/Scenarios/Shared/Configs/...DA_*`.
  Extractors shorten them to ids (`DA_Core_FoodResource` → `Core_FoodResource`).
- Static helper libraries `PX*Utils` (call on `/Script/Frostpunk2.Default__PX*Utils`):
  `PXStockpileUtils`, `PXStatisticUtils`, `PXNeedUtils`, ...; `describe class=PXNeedUtils`.

## Extractors (`./fp2.exe state` runs those marked *)

| Extractor | Source | Notes |
|---|---|---|
| `time`* | `PXTimeSubsystem` | `paused`, `pauseReasons` (e.g. `WBP_Modal_C` = a modal is open), `speed`, `gameTimeTicks` (`currentGameTime.ScaledTicks`), `startDateDays`. Tick→calendar scale unverified. |
| `resources`* | `city.stockpile.Stock/StockLimits`, `EconomyHolder.TargetSupply/TargetDemand`, `PXStockpileUtils.GetCityStockpileChangeOfResource` | `change` = net per stockpile update; matched HUD deltas (measured: food −523, coal −79, goods −89). Limits only exist for some resources. |
| `needs`* | `NeedHolder.NeedsRequired/NeedsFulfilled` | `balance = fulfilled − required`. Measured: Heating −5970, Shelter −159 matched HUD. |
| `statistics`* | `statisticHolder.CurrentStatistics/TargetStatistics` | 0–100ish, higher = worse. `current` drifts toward `target`. |
| `population`* | `WorkforceHolder.TotalWorkforce`, `peopleAllocationHolderComponent`, `PXTemperatureComponent`, `Generator` UFunctions | `population` sums *unassigned community sizes* only — not the HUD total (measured 10429 vs HUD ~30.7K). Gap. |
| `districts` | `districtHolder.Districts` | district component refs; type id best-effort. |
| `session`* | PlayerController world | map, game mode, pause flag of world settings (not FP2 pause; use `time.paused`). |

## Resource ids

`Core_Heatnotes` (Heatstamps), `Core_FoodResource`, `CoalResource`, `OilResource`,
`Core_MaterialsResource`, `Core_PrefabsResource`, `Core_GoodsResource`, `CoresResource`,
`Core_PowerResource`, `LogisticsUnitsResource`, `MilitiaResource`.

## Need ids

`Shelter`, `Warmth`, `Heating`, `Nourishment`, `Possession`, `Maintenance`.

## Statistic ids

`Cold`, `Hunger`, `Sickliness`, `Crime`, `Squalor`, `Tension`, `Homelessness`,
`ColonyUnrest`, `Wealth`, `CitySize`, `NationSize`.
