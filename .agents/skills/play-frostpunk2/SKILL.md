---
name: play-frostpunk2
description: Play Frostpunk 2 through the FP2AgentBridge UE4SS mod and the `fp2` CLI. Read exact city state as JSON, control time, camera, screenshots, mouse and keys from one CLI, and grow the mod's data and action coverage as you play.
---

# Play Frostpunk 2

Frostpunk 2 is a city-survival builder. Keep the city warm, fed, housed and supplied;
expand districts onto deposits; research ideas; pass laws in the Council while factions
pull the city apart. Losing: Trust or Tension collapse, or people freeze/starve.

Goal: keep the city alive and growing with deliberate, explained decisions.

## One CLI

Everything goes through `./fp2.exe` (repo root; source `cli/`, rebuild with
`cd cli; bun run build`). `./fp2.exe -h` lists subcommands. Prefer it over computer use:

| Need | Command |
|---|---|
| Is the mod alive? | `fp2 status` |
| What should I fix? | `fp2 brief` (alerts + deficits + depleting stocks) |
| Exact numbers | `fp2 state`, `fp2 extract name=resources|needs|statistics|population|time|deposits|districts` |
| Pause / resume / speed | `fp2 pause`, `fp2 resume`, `fp2 speed 1..3` (verified via `UserPaused` reason) |
| Let time pass | `fp2 advance ticks=1680` (1 week); stops early when a modal/event pauses |
| See the screen | `fp2 screenshot [region=hud|objectives|bottom|center|x0,y0,x1,y1] [scale=0.5]` → PNG path; Read it |
| Click / hold / drag | `fp2 click x,y`, `fp2 hold x,y ms=2000`, `fp2 rclick`, `fp2 drag`, `fp2 scroll x,y ±n`, `fp2 move` |
| Keys | `fp2 keys escape`, `fp2 keys space@3000` (hold 3 s) |
| Camera | `fp2 camera ref=<object>` · `fp2 camera x=.. y=..` · `fp2 camera reset=true` |
| Where is X on screen? | `fp2 locate ref=<object>` → world location + client pixel |
| After editing Lua | `fp2 reload` |
| Start / recover the game | `fp2 launch` (closes a stuck crash reporter, starts via Steam, waits for bridge) |
| Load / save | `fp2 saves` (disk list), `fp2 load name=..`, `fp2 save name=..` (see caveat in MOD_GAPS) |
| Popups & decisions | `fp2 modals` (title/description/decision), `fp2 choose index=N` |

### Game actions (bridge → the game's own command layer, Leader action origin)

All mutations validate through the game and charge normal costs; most accept `dryRun=true`.

| Action | Command |
|---|---|
| Free cells / deposits | `fp2 cells free=true`, `fp2 cells deposit=soil`, `fp2 extract name=deposits type=logistics` |
| Pick a placement | `fp2 pick_cells count=6 [deposit=soil]` → `{cells:[...]}` (connected, next to the city) |
| Build a district | `fp2 district_types` → `fp2 place_district type=Housing 'cells=[..6..]' [dryRun=true]` |
| Frostbreak | `fp2 pick_cells count=8 frozen=true nearX=.. nearY=..` → `fp2 expand 'cells=[..8..]'` |
| Buildings | `fp2 building_types [district=Housing]` → `fp2 place_building type=H_ResearchInstitute [district=Housing]` |
| Districts overview | `fp2 districts` |
| Research | `fp2 research`, `fp2 research_topics`, `fp2 research_start topic=<id> [community=<type>]` (community decides the outcome variant) |
| Construction progress | `fp2 extract name=construction` (also in `brief`) |
| Time | `fp2 date`, `fp2 game.pause`, `fp2 game.resume`, `fp2 game.speed level=0..2` |
| Abilities | `fp2 abilities` → `fp2 ability owner=Production id=Toggle_IndustrialPrefabsProduction active=true` (Instruct path) |
| Generator | `fp2 generator`, `fp2 overdrive active=true|false` |
| Quests / map icons | `fp2 extract name=quests`, `fp2 extract name=icons` (both in `state`) |
| Event dialogs | `fp2 modals` → `fp2 choose index=N` (resolves the decision through the game) |
| Council | `fp2 council`, `fp2 laws`, `fp2 council-open`; vote with `fp2 vote policy=..` only inside the Council after proposing |
| Hotkeys | `fp2 keybinds contains=..` (Council C, Research R, Frostland V, Districts B, Frostbreak X, Buildings N) |
| New game | `fp2 new-game` (from the main menu; resolves intro dialogs, pauses) |

Pass arrays in PowerShell as single-quoted `'cells=[1,2,3]'`.

### Council (measured working flow)

1. `fp2 laws` → pick a policy with high `seats.For` and low `Against` (the Council predicts the same split).
2. `fp2 council-open` (presses C, skips the chamber cutscene; needs a built Council Hall and an open session —
   `fp2 council` → `minTicksToNextSession` is ~10 weeks after each vote).
3. UI: **Propose a law** → law tab (Survival/City/Society/Rule) → law → option → **Propose** → **Vote** → **I see**.
   Take a screenshot per step; positions depend on the window/monitor, so use fractions from the screenshot.
4. Verify: `fp2 council` → `activePolicies` contains the policy.

Never act while a cutscene plays: `choose`/`vote`/`propose`, `click` and `hold` refuse while a `Cutscene` pause
reason is active (override with `--force`). Bridge `propose`/`vote` are guarded/experimental (see MOD_GAPS).
Research needs a Research Institute (Housing district building); without it `ResearchSpeedMultiplier` is 0.

Coordinates are **game client pixels** at full resolution (a `scale=0.5` screenshot pixel ×2).
Fractions `0..1` also work. `locate` returns the same pixel space, so
`fp2 click <locate.screen.x>,<locate.screen.y>` clicks an object directly.

Use computer-use tools only when the CLI cannot do something (e.g. a dialog that refuses
synthetic input). Grant `frostpunk2-win64-shipping.exe` if you need it.

## UI facts learned the hard way

- Many confirm buttons need **press-and-hold** (`fp2 hold x,y ms=2000`). Skip cutscenes with `fp2 keys e@3000`
  (holding Space skips too but also toggles pause).
- New game from the main menu: Utopia Builder → Next (tales optional) → click 3 communities + a faction →
  Next → map → Next → Start; then hold the intro confirm and skip the cutscene. Everything after that is bridge-driven.
- District placement: Districts menu (bottom-right first icon, `B`), pick type, click 6 adjacent hex tiles,
  then click the ✓ that appears. `time.pauseReasons` shows `DistrictPainting` while in placement mode.
- Hatched terrain is frozen: "Frostbreak this area first". Extraction/Logistics districts must start on a deposit
  (`fp2 extract name=deposits type=logistics`).
- Mouse near window edges pans the camera; re-center with `fp2 camera ref=first:BP_BaseCity_C`.
- The game stops rendering while unfocused; `screenshot`/`click` focus it first (no ALT tap when already focused —
  held ALT shows the economy overlay).
- Screenshots occasionally come back as a flat dark frame right after an action; the CLI retries (field `blank`).

## Session start

1. `fp2 status`. `alive:false` → game not running or mod not loaded. Install with
   `./scripts/Install-Bridge.ps1` (game closed). Launch: `Start-Process steam://rungameid/1601580`.
2. `fp2 wait-ready` after loading a save / starting a game.
3. `fp2 pause`, then `fp2 brief`. Read [DATA_MAP.md](references/DATA_MAP.md) for meaning and units.

## Play loop

1. **Pause.** `fp2 brief`.
2. **Triage** worst first: negative need balances, stock `change` that empties a stockpile soon,
   statistics whose `target` is high (Cold, Hunger, Tension, Sickliness, Crime, Squalor), homeless > 0.
3. **Decide** one or two actions (see [GAMEPLAY.md](references/GAMEPLAY.md)).
4. **Act**: prefer bridge action commands; else `screenshot` → `click`/`hold`.
5. **Verify** with the mod (supply/demand, needs, construction).
6. `fp2 advance ticks=1680`; handle whatever `stoppedBy` reports; repeat.
7. Journal decisions/outcomes in `gameplay/<date>/log.md`.

## Grow the mod as you play

Whenever you read a number from a screenshot, click through a menu repeatedly, or hit a
UI wall, add an extractor or action command. See [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md);
known gaps in [MOD_GAPS.md](references/MOD_GAPS.md); callable game functions in
`research/fp2_functions.txt` and `research/ACTION_CANDIDATES.md`.

## Rules

- No cheating: no stockpile edits (`TryChange*Stockpile`), no `PXCheat*`, no `set` on game state.
  Action commands must go through the game's own validated paths (Try*/Can* + ActionOrigin).
- Do not overwrite or delete the user's saves.
- One controller drives the UI at a time; the client lock serializes bridge calls.
