# Extending the bridge

## Layout

Scripts live in `mod/FP2AgentBridge/Scripts/`.

| File | Role |
|---|---|
| `main.lua` | File IPC loop. A 10 ms `LoopAsync` reads `bridge/request.json`, runs the command on the game thread (`ExecuteInGameThread`), and writes `response.json`. Rewrites `status.json` (heartbeat) every second. Handles `bridge.reload`. |
| `commands.lua` | Command registry (`def(name, {help, mutation, run})`). Generic reflection commands, then game actions. `fp2 help` lists them. |
| `actions.lua` | Gameplay actions through the game's command layer (`PXInstructionUtils`, `PX*Utils`), all with the Leader ActionOrigin. |
| `extractors.lua` | Extractor registry (`register`, declarative `fromClass`, `snapshot`) and the engine-level `session` extractor. |
| `fp2_extractors.lua` | Frostpunk 2 extractors. Add new ones here. |
| `extensions.txt`, `<name>.lua` | Extension modules (`colony_actions`, `society_actions`, `frostland_actions`, `economy_actions`). See Extension modules below. |
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

## Extension modules

Add commands in their own file instead of editing `actions.lua` or `commands.lua`.

- `Scripts/extensions.txt` lists one module name per line (lines starting `--` are comments). Each
  `Scripts/<name>.lua` returns `{ register = function(def, env) ... end }`.
- Load order: `main.lua` reload loads the base modules, then the extensions in file order, then `commands`, which
  calls each `register(def, env)` once. A later `def` with the same name replaces the earlier one (`society_actions`
  overrides the core `propose` with a lobby guard).
- `env` fields: `def`, `actions`, `reflect`, `extractors`, `geo`, `json`, `num`, `lower`, `findClass`,
  `requireObject`, `h`.
- `env.h` (also `actions.h`, set at the end of `actions.lua`) exports the helpers actions use: `cdo` (Default__
  library object), `assetId`, `ctx` (the PlayerController world context), `world`, `cityId`, `try`, `fresh` (re-find
  an object by path), `textOf`, `uarray`, `nationOf`, `objList`, `communityLabel`, `costMap`, `compactCost`,
  `enumName`, `parliament`, `simplify`, `findPolicy`, `findDistrict`, `territoryInfo`, `siteInfo`, `tagName`,
  `liveWidget`, `districtByLabel`, `findTyped`, `resolveCells`, `cellInfo`, `outcomeInfo`.
- Hot reload: add the module name to `extensions.txt`, then `fp2 reload` (no keypress, no UE4SS restart). The reload
  result lists the modules it loaded and reports a Lua load error with file, line and context. Never hide it.
- Every mutating command sets `mutation = true`, has a `dryRun` path that validates and prices without acting, calls
  `A.assertNoCutscene` when it touches the Council or dialogs, uses the Leader ActionOrigin (`A.leaderOrigin()`),
  and validates every UObject with `reflect.isValid` before passing it.

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

## Council UI entry points

`council_ui` (in `society_actions.lua`) fires the Council hub widgets' own bound button events, so the UI stays in
step with the Council. Each event takes only the widget's own button (a `PXButtonEvent` delegate), so no FText
struct crosses the Lua boundary. The event name is
`BndEvt__<Owner>_<Button>_K2Node_ComponentBoundEvent_<N>_PXButtonEvent__DelegateSignature`, where `<N>` is the
K2Node index shown below (full names are in the `EV` table of `society_actions.lua`). The live hub is the
`WBP_ParliamentHub_C` instance under `/Engine/Transient.GameEngine_*` (the other `FindAllOf` match is the class
template). Read a widget's child only when the property is an object property (SoftObject reads crash). Chain
measured 2026-10-11 on one run, UI in sync, no crash:

| Step | Widget class | Entry point | Measured result |
|---|---|---|---|
| `laws` | `WBP_Parliament_MainScreen_C` (lobby) | bound event of `ExploreLawsButton` (index 4) | Lobby hides, law list shows |
| `law policy=X` | `WBP_Parliament_PolicyChoicePanel_C` | `OpenLawPoliciesPanel(law)` | Entries `WBP_ParliamentAdditionalPolicy_C` (property `Policy`) |
| `select policy=X` | `WBP_ParliamentAdditionalPolicy_C` | bound event of `ProposeButtonWidget` (index 9) | Phase Agenda -> Negotiations, agenda set, hub back to the lobby |
| `negotiate` | `WBP_Parliament_MainScreen_C` | bound event of `NegotiateButton` (index 2) | Intro panel (`WBP_Parliament_NegotiationsIntroPanel_C`) |
| `community` | `WBP_Parliament_NegotiationsIntroPanel_C` | `OnChoiceClickedFunc(communityType)` | `WBP_Parliament_GroupNegotiationsPanel_C`: MY TERMS (vote for/against) and THEIR TERMS (2 options: Grant Agenda community action; Research and hold vote) |
| `side` | the For/Against widget of the group panel (`WBP_HoD_Negotiationsingle_myterm_Widget`) | bound event of `MyTermsDecisionButton` (index 0) | Side selected |
| `term index=N` | `WBP_Parliament_Negotiation_option_Widget_C` | bound event of `TheirTermsCheckmarkButton` (index 1) | Term checked |
| `accept` | `WBP_Parliament_GroupNegotiationsPanel_C` | bound event of `AcceptNegotiation_Button` (index 1) | Hub back to the lobby; `plannedPromises` holds the community's `PXDesire` |
| `vote` | `WBP_Parliament_MainScreen_C` | bound event of `VoteButton` (index 1) | LAW PASSED 55 For / 51 required; promise quest "Promise to Merchants", 40 weeks; Escape -> phase 4 Maintenance |

`ChangeProposalButton` (bound event index 6) is wired but untested. `step=terms` reads the option widgets' visible text blocks
(`GetText` returns a plain FText); the `PXDesire` struct itself is never passed. Pixel clicks on the lobby did
nothing (click and hold at the text position), and a Space keypress did not advance it. Calling a widget's bound
event from Lua works because the handler runs the same Blueprint path as a click (inferred).

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
- `build_outpost` on a food-herd outpost (`FoodLargeOutpost_LargeHerd`, Faebait Gorge) crashed the game again after
  the post-instruction reads were removed (same `HasAnyInternalFlags` stack, reading 0x18, measured). The dump shows
  three nested `pcall`s above the failing call, so the crash came from `reflect.isValid` or a method call inside an
  action `pcall`, on a destroyed object (inferred). A null UObject raises a catchable Lua error ("UObject instance
  is nullptr", measured); a destroyed one crashes, and `reflect.isValid` cannot protect it because `IsValid` itself
  runs `HasAnyInternalFlags` (inferred). Rules: validate each optional sub-object (`CommunitiesHolder`, `Site`,
  `Type`, `Generator`) before reading or calling it; validate each object argument before an `Instruct*` call; never
  hold a reference across an instruction, a level load or a just-finished exploration. Check a crash dump's pcall
  depth to locate the Lua line: count `UE4SS + c7c9e1` frames (luaB_pcall in the current UE4SS build, inferred) in the `CallStack`.
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
- Game-thread bridge calls during a level load crash the game natively in Wwise (measured: `recover` polling
  `extract time` / `find_all` while loading crashed twice on `agent-rolling` and twice on `agent-before-connect`;
  the same `agent-before-connect` load with no bridge calls for 90 s succeeded). A successful `load` writes
  `.runtime/load-quiet-until` (now + 90 s, `FP2_LOAD_QUIET_SECONDS`); every client (`turn`, the watcher, any
  command) waits until then before its next game-thread call and watches only the heartbeat file. `fp2 status`
  shows `loadQuietSeconds`. Never call the bridge from another path during a load.
- `turn` and the watcher rotate saves over `agent-rolling-a/-b/-c`, so one unloadable save leaves two older ones.
  `recover` treats a dead process, a new crash report, a running CrashReportClient or a heartbeat stale for 60 s
  as a crash, kills the game and loads again, up to 3 loads. Only a crash in the quiet phase marks the save bad in
  `.runtime/bad-saves.json` (keyed by name and file time; an overwritten slot is usable again) and moves to the next
  save (`agent-rolling*`, `agent-*`, `AutoSave*`).
- A Wwise `AK::WriteBytesMem::SetCount` <- UE4SS `FAnsiString::operator=` <- `process_lua_function` stack is not an
  audio fault. It has appeared for a guessed world context, `colony_exchange` (static `PXStockpileExchangeUtils`
  tier getters and out-params) and `PXDesireUtils.AbandonPromise` with a valid `PXPromiseQuest` (measured, three
  times). Read it as a bad call into a static Utils function (inferred). A declared-class check (`ForEachProperty`,
  `GetPropertyClass`, `IsA`) is necessary but did not prevent the `AbandonPromise` crash. Prefer property reads and
  the UI's own widget events; test a new static call once, after a save.
- A crash in UI rendering (`nsvgRasterizeFull`, AntiLag2, no Lua frames) followed a bridge-driven `propose` while the
  Council hub showed its lobby (measured). Bridge-driven state changes need the matching UI step: use `council_ui`.
- A load that runs while the main-menu shader compile is active destroys `BP_ShaderCompilerActor_C`; the loading
  screen then stays on "COMPILING SHADERS N/743" with input blocked (measured twice). `fp2 unstick` clears it.
- A save written inside the Council scene did not load (measured). Save outside it.

## Verify

After adding an extractor, reload, run it, and compare it to the HUD with one screenshot. Then record it
in DATA_MAP.md as measured. Do not ship an extractor whose numbers you have not compared.
