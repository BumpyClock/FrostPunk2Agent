# Extending the bridge

## Layout

- `mod/FP2AgentBridge/Scripts/main.lua` — file IPC loop (`bridge/request.json` → `response.json`,
  `status.json` heartbeat). Commands run on the game thread via `ExecuteInGameThread`.
- `commands.lua` — generic reflection commands (`help` lists them).
- `reflect.lua` — UE value → JSON conversion; every read is pcall-guarded.
- `extractors.lua` — extractor registry (`register`, declarative `fromClass`).
- `fp2_extractors.lua` — Frostpunk 2 extractors. Add new ones here.
- The game loads the mod through a junction, so edits are live after `./fp2.exe reload`.
  UE4SS log: `<game>\Frostpunk2\Binaries\Win64\ue4ss\UE4SS.log` (Lua errors land there and in `bridge/bridge.log`).

## Discovery commands

```powershell
./fp2.exe modules                                         # /Script packages by class count
./fp2.exe classes module=/Script/Frostpunk2 contains=Research
./fp2.exe find_all class=PXResearchComponent
./fp2.exe components ref=first:BP_BaseCity_C
./fp2.exe object ref=first:PXResearchComponent depth=2 arrayLimit=20   # gameOnly=true default
./fp2.exe object ref=... gameOnly=false types=true
./fp2.exe describe class=PXResearchUtils ownOnly=true      # functions + params
./fp2.exe get ref=first:PXCityComponent path=stockpile.Stock depth=2
./fp2.exe call ref=/Script/Frostpunk2.Default__PXNeedUtils fn=GetSupportedNeeds args='["@first:PXCityComponent"]'
./fp2.exe search contains=Council limit=20               # scan live objects (slow: whole GUObjectArray)
```

`research/fp2_classes.txt` lists all 2,200 native `/Script/Frostpunk2` classes (regenerate with `classes`).

`ref` forms: full object path, `first:<ClassName>` (FindFirstOf), or a `Class /Path` full name.

## Patterns

- Maps of data asset → number: use `assetMap` in `fp2_extractors.lua`.
- UFunction getters: `obj:GetFoo()`; static library calls: `StaticFindObject("/Script/Frostpunk2.Default__PXFooUtils"):Fn(args)`.
  Object args can be passed as UObjects from other reads (strings do not auto-resolve in Lua).
- Avoid `ForEachUObject` in extractors (scans every object; tens of ms). Cache refs in locals.
- Lua `x and y or z` breaks when `y` is false/nil; use `reflect.result(ok, v)` or explicit `if`.

## Crash hazards (measured)

- **FText inside struct/container params or return values crashes the game** (access violation in
  `FProperty::CopyCompleteValue` → `FText::FText` inside UE4SS `process_lua_function`). Example: requirement
  result structs from `Has*`/`Can*` functions. `reflect.invoke` and `call` now refuse these
  (`describe` marks them `!text`). Read the same data from properties or simpler getters instead.
- Plain FText returns and reading FText *properties* are fine.
- Game crash reports: `%LOCALAPPDATA%\11bitstudios\Frostpunk2\Steam\Saved\Crashes\*\CrashContext.runtime-xml`
  (`<ErrorMessage>`, `<CallStack>`).
- After a crash: relaunch (`Start-Process steam://rungameid/1601580`), Continue from the main menu, `fp2 wait-ready`.

## Calling conventions (measured)

- UFunction returning `TArray<UObject*>` arrives as a Lua table of userdata; `reflect.invoke`/`plain` turn it into refs.
- Struct args can be Lua tables: `call ... fn=GetTotalHours 'args=[{"ScaledTicks":4060}]'`.
- Object args: `"@<ref>"` strings, e.g. `args=["@first:PXCityComponent"]`.
- Run `fp2.exe` from PowerShell, not Git Bash: MSYS rewrites `/Script/...` arguments into Windows paths.

## Verify

After adding an extractor: reload, run it, compare to the HUD with one screenshot/zoom,
then record "measured" in DATA_MAP.md. Never ship an extractor whose numbers you have not compared.
