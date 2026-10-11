# Extending the bridge

## Layout

Scripts live in `mod/FP2AgentBridge/Scripts/`.

| File | Role |
|---|---|
| `main.lua` | File IPC loop. A 50 ms `LoopAsync` reads `bridge/request.json`, runs the command on the game thread (`ExecuteInGameThread`), and writes `response.json`. Rewrites `status.json` (heartbeat) every second. Handles `bridge.reload`. |
| `commands.lua` | Command registry (`def(name, {help, mutation, run})`). Generic reflection commands, then game actions. `fp2 help` lists them. |
| `actions.lua` | Gameplay actions through the game's command layer (`PXInstructionUtils`, `PX*Utils`), all with the Leader ActionOrigin. |
| `extractors.lua` | Extractor registry (`register`, declarative `fromClass`, `snapshot`) and the engine-level `session` extractor. |
| `fp2_extractors.lua` | Frostpunk 2 extractors. Add new ones here. |
| `reflect.lua` | UE value to JSON conversion, object lookup (`first:<Class>` or a full path), crash guards. Every read is pcall-guarded. |
| `geo.lua` | World location and world-to-screen projection. |
| `json.lua` | JSON encode and decode. |

Bridge directory: `mod/FP2AgentBridge/bridge/` (override with `FP2_BRIDGE_DIR`). Files: `request.json`,
`response.json`, `status.json`, `bridge.log`. One request is in flight at a time; CLI clients serialize with
`client.lock`. The CLI finds the repo root from the exe or cwd, or from `FP2_ROOT`.

## Reload, build, logs

- The game loads the mod through a directory junction, so edits are live after a reload.
- `fp2 reload` runs `bridge.reload`: it re-loads every module except `main.lua` with `loadfile` and seeds
  `package.loaded`. It needs no keypress. UE4SS `require` caches outside `package.loaded`, so a plain
  `require` would return stale code.
- `fp2 reload --full` sends UE4SS's Ctrl+R hot reload and is needed only for `main.lua` changes. Ctrl+R
  collides with the game's R = Research hotkey, so Research opens. The CLI waits for `status.started` to
  change and presses Escape if the pause reasons include the Idea Tree.
- Build with `cd cli; bun run build` (`bun run typecheck` for types). A foreground `fp2 watch` locks
  `fp2.exe`; stop it first. `fp2 watch-start` runs `.runtime/fp2-watch.exe`, a copy, so builds are not
  blocked. Run `watch-stop` and `watch-start` to move the watcher to the new build.
- Logs: `bridge/bridge.log` (command failures and lifecycle), and
  `<game>\Frostpunk2\Binaries\Win64\ue4ss\UE4SS.log` (Lua errors).

## Discovery commands

Run `fp2.exe` from PowerShell. Git Bash rewrites `/Script/...` arguments into Windows paths.

```powershell
./fp2.exe modules                                         # /Script packages by class count
./fp2.exe classes module=/Script/Frostpunk2 contains=Research
./fp2.exe functions class=PXResearchUtils                 # UFunction catalog with params (!text marks FText)
./fp2.exe find_all class=PXResearchComponent
./fp2.exe components ref=first:BP_BaseCity_C
./fp2.exe object ref=first:PXResearchComponent depth=2 arrayLimit=20   # gameOnly=true by default
./fp2.exe object ref=... gameOnly=false types=true
./fp2.exe describe class=PXResearchUtils ownOnly=true     # properties and functions
./fp2.exe get ref=first:PXCityComponent path=stockpile.Stock depth=2
./fp2.exe call ref=/Script/Frostpunk2.Default__PXNeedUtils fn=GetSupportedNeeds args='["@first:PXCityComponent"]'
./fp2.exe search contains=Council limit=20                # scans every live object; slow
./fp2.exe enum name=EPXVoteAttitude
```

`research/fp2_classes.txt` and `research/fp2_functions.txt` list the reflected native classes and
UFunctions (regenerate with `classes` and `functions`).

`ref` forms: a full object path, `first:<ClassName>` (`FindFirstOf`), or `Class /Path` full names.

`call` runs getter-style names (`Get*`, `Is*`, `Can*`, `Has*`, ...) directly. Any other name needs
`mutate=true`. `set` needs `mutate=true`. Both bypass the game's validation, so they are for discovery,
not play (see the no-cheats rule in SKILL.md).

## Patterns

- Maps of data asset to number: use `assetMap` in `fp2_extractors.lua`.
- UFunction getters: `obj:GetFoo()`. Static library calls:
  `StaticFindObject("/Script/Frostpunk2.Default__PXFooUtils"):Fn(args)`.
- Object arguments pass as UObjects from other reads. Lua strings do not auto-resolve; the `call` command
  resolves `"@<ref>"` strings for you.
- Struct arguments can be Lua tables: `call ... fn=GetTotalHours 'args=[{"ScaledTicks":4060}]'`.
- A UFunction returning `TArray<UObject*>` arrives as a Lua table of userdata. `reflect.invoke` and `plain`
  turn it into refs.
- Avoid `ForEachUObject` in extractors; it scans every object and takes tens of milliseconds. Cache refs.
- Lua `x and y or z` breaks when `y` is false or nil. Use `reflect.result(ok, v)` or an explicit `if`.
- New mutating actions need `mutation = true` in `def`, a `dryRun` path where a check or price exists,
  `A.assertNoCutscene` if they involve choices or the Council, and the Leader ActionOrigin
  (`A.leaderOrigin()`).

- Out-params: pass an empty Lua table for each out-param; UE4SS fills it after the call, keyed by the
  param name for scalars (`prog.outProgress`) or by field for structs (`left.ScaledTicks`). Measured with
  `PXResearchUtils.GetResearchProgress(nation, topic, prog, left)`.
- TSet properties: `ForEach` passes `(elem)`; TArray passes `(index, elem)`. `actions.lua` `uarray` handles both.

## Crash hazards (measured)

- FText inside struct or container params or return values crashes the game (access violation in
  `FProperty::CopyCompleteValue` to `FText::FText` inside UE4SS `process_lua_function`). Example:
  requirement-result structs from `Has*` and `Can*` functions. `call` and `reflect.invoke` refuse these
  calls; `describe` and `functions` mark such params `!text`. Read the same data from properties or
  simpler getters. Passing `unsafe=true` to `call` skips the guard and accepts a crash.
- Plain FText returns and reading FText properties are fine.
- SoftObject reads crash: UE4SS `push_softobjectproperty` dereferences null for some values (found while
  dumping a UMG widget). `reflect` skips SoftObject and SoftClass properties, including inside arrays, sets
  and maps, and `get` refuses them.
- Area expander and construction cost checks return FText structs and hit the first guard. The `expand`
  action reads costs through `try` (errors become data) and still runs; the game validates and returns `ok`.
- Calling a method on, or passing, a null or stale UObject crashes the game (access violation in
  `UObject::HasAnyInternalFlags` inside `process_lua_function`). `pcall` does not catch it. Measured with
  `PXTerritoryUtils.GetAllCurrentlyExploringTerritories` plus `GetOwner():GetComponentByClass(...)`. Check
  `reflect.isValid(x)` before every call on an object that a game function returned, and prefer paths that
  already work (here: filter the revealed territory list on `inProgress`).
- Reading the object an instruction acted on, through the reference held before the instruction, crashed the game
  (access violation in `UObject::HasAnyInternalFlags`, measured: `target.City` read right after
  `InstructConstructOutpost` on a food-herd outpost). `Instruct*`, `Start*` and `Create*` calls can destroy or
  replace that object. In actions, read everything before the instruction; after it, capture `reflect.path(x)`
  first and re-find with `fresh(path)` (nil when gone), or drop the read and verify with a read command.
- A guessed world-context argument crashed the game (access violation in Wwise
  `AK::WriteBytesMem::SetCount`, measured right after `PXOutpostUtils.GetAllOutposts` was called with a level
  path as `WorldContextObject`). `call` now always fills `WorldContextObject` with the PlayerController; pass
  `"@ctx"` as a placeholder.
- Subagents share the live game. Two crashes came from subagents doing reflective calls (measured); keep them
  to curated commands (see Subagents in SKILL.md).
- `reflect.plain` on arbitrary asset containers is not SoftObject-guarded: plain-converting building-type
  properties crashed the game in `push_softobjectproperty` (measured). For asset data, walk maps with
  `ForEach` and keep only object keys and number or text values, or use `reflect.dump` (guarded).
- Passing a Lua string to an FName parameter crashes UE4SS (`push_nameproperty`, measured). `call` now converts
  strings to `FName` for Name params; in actions use `FName("...")` or an FName read from the game.
- Hooks (`RegisterHook`) on `PXInstructionUtils` functions only see calls that go through script; the UI calls
  them natively (measured: no records during a UI district expansion).
- Save before testing a new read on a live game: `fp2 save name=agent-<what> override=true`, then `fp2 saves`.
- Game crash reports are in `%LOCALAPPDATA%\11bitstudios\Frostpunk2\Steam\Saved\Crashes\*\CrashContext.runtime-xml`
  (`<ErrorMessage>`, `<CallStack>`).
- After a crash: `fp2 recover [name=<save>]` launches the game, loads the save from the main menu, waits until
  ready, closes the loading screen and pauses. Loading uses `ForceLoadGame`; plain `LoadGame` returns true from the
  main menu and does nothing (measured).
- A save can crash the game while loading (measured: the single `agent-rolling` slot crashed in Wwise on load,
  twice). `turn` and the watcher therefore rotate `agent-rolling-a/-b/-c`. `recover` treats a dead process, a new
  crash report, a running CrashReportClient or a heartbeat stale for 60 s during a load as a crash, records the save
  in `.runtime/bad-saves.json` (keyed by name and file time; an overwritten slot is usable again), kills the game
  and tries the next save, up to 3 loads.

## Verify

After adding an extractor, reload, run it, and compare it to the HUD with one screenshot. Then record it
in DATA_MAP.md as measured. Do not ship an extractor whose numbers you have not compared.
