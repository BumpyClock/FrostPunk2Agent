---
name: play-frostpunk2
description: Play Frostpunk 2 through the FP2AgentBridge UE4SS mod and the `fp2` CLI. Read exact city state as JSON, control time, camera, screenshots, mouse and keys from one CLI, and grow the mod's data and action coverage as you play.
---

# Play Frostpunk 2

Frostpunk 2 is a city-survival builder. Keep the city warm, fed, housed and supplied, expand districts
onto deposits, research ideas, and pass laws in the Council while factions pull the city apart.
You lose when Trust or Tension collapses, or when people freeze or starve.

Goal: keep the city alive and growing, with decisions you can explain. Use the bridge for state and
actions. Use screenshots and input only where the bridge has no command.

All commands go through `./fp2.exe` at the repo root (source in `cli/`; `fp2 -h` lists subcommands).
Run it from PowerShell: Git Bash rewrites `/Script/...` arguments into Windows paths. Quote arrays:
`'cells=[1,2,3]'`.

## Session start

1. `fp2 status`. `alive:false` means the game is not running or the mod did not load.
   Launch with `fp2 launch`. Install with `./scripts/Install-Bridge.ps1` (game closed).
2. `fp2 wait-ready` after launching, loading a save, or starting a game.
3. `fp2 pause`, then `fp2 watch-start` (see Play loop), then `fp2 brief`.
4. Read [DATA_MAP.md](references/DATA_MAP.md) for field meanings and units.

## Play loop

Run a detached watcher and react to its events instead of polling.

1. `fp2 watch-start` starts a hidden watcher that appends one JSON line per meaningful change to
   `.runtime/watch.jsonl` (errors go to `watch.jsonl.err`). It prints the tail command.
   Start a Monitor on it: `tail -n0 -F ".runtime/watch.jsonl"`.
2. `fp2 advance ticks=1680` resumes time for one week. It ends paused, prints a brief, and stops early
   when a modal or event pauses the game (`stoppedBy`). The default is 24000 ticks.
3. When an event arrives, pause if needed, then act on the cause (table below).
4. Verify the effect with `fp2 brief` or `fp2 snapshot`, then continue.
5. `fp2 watch-stop` ends the watcher.

The watcher also overwrites one rolling save (`agent-rolling`) every 2 in-game weeks (`saveEvery=N`,
`saveName=X`, `saveEvery=0` turns it off) and emits `watch.saved`. A crash or closed game then loses at most
2 weeks. Without it, all progress since the last manual save was lost once (measured).

The watcher auto-pauses the game on the kinds in `pauseOn` unless the player already paused. Defaults for
`watch-start`: `dialog.opened,need.deficit,stock.runway,research.finished,construction.finished`.
Override with `pauseOn=critical` (a preset: those plus `stat.rising`, `ui.cutscene.changed`,
`council.sessionAvailable.changed`, `exploration.finished`) or a comma list of kinds. `fp2 watch` (foreground, no auto-pause by
default) takes the same arguments; run it only under a Monitor.

Each line has `at`, `date`, `week`, `kind`, `detail`.

| Event kind | Meaning | Reaction |
|---|---|---|
| `dialog.opened` / `dialog.closed` | Modal or decision; `detail` has title, description, choices | `fp2 modals`, decide, `fp2 choose index=N` |
| `need.deficit` / `need.ok` | A need balance went below or back to 0 | Heating: see GAMEPLAY.md |
| `stock.runway` / `stock.recovered` | Stock runway crossed 20, 10, 5 or 2 weeks (`recovered` never auto-pauses) | Fix the supply of that resource |
| `stat.rising` / `stat.falling` | A statistic crossed a 10-point band; `detail` has current and target | Treat Cold, Hunger, Tension, Sickliness, Crime, Squalor |
| `trust.up/down`, `standing.up/down` | Total trust or community standing crossed a 10-point band | Check `fp2 council` and `fp2 laws` |
| `construction.started/state/finished`, `research.started/finished` | Work began, changed or ended | Queue the next build or topic |
| `exploration.started/progress/finished`, `exploration.revealed.changed` | Frostland exploration began, advanced in quarter steps, finished, or the count of revealed territories changed | `fp2 territories`, then `fp2 explore` |
| `quest.progress` | Quest objective progress changed | Check `snapshot.quests` |
| `icons.changed` | Count of a map tracker kind changed (Bark icons ignored) | `extract name=icons`, `open_icon` |
| `council.sessionAvailable.changed`, `council.phase.changed`, `council.agenda.changed` | Council session opened or changed | See Council |
| `ui.cutscene.changed`, `ui.pauseReasons.changed` | A cutscene or pause reason appeared or cleared | Do not click or choose during a cutscene |
| `deaths.increased` | Death toll rose; `detail` has from, to, `byCause` | Find the cause (cold, hunger, sickness) and fix its need |
| `homeless.changed`, `temperature.changed`, `districts.changed`, `research.active.changed` | State flag changed | Re-read the relevant section |
| `watch.started`, `watch.autopaused`, `bridge.error` | Watcher status | `bridge.error`: `fp2 status` |

## Commands

Mutating commands validate through the game, charge normal costs, and use the Leader action origin.
Most accept `dryRun=true`.

### Reads

| Need | Command |
|---|---|
| Mod alive | `fp2 status` (heartbeat only) |
| Whole HUD in one call | `fp2 snapshot`: date, pauseReasons, cutscene, resources, needs, statistics, population, society, construction, quests, icons, modals, research, council, generator, exploration, districts |
| Triage | `fp2 brief`: alerts, need deficits, depleting stocks, modals, construction |
| Raw extractors | `fp2 state` (all `inState` extractors), `fp2 extract name=<x>` (omit `name` to list), `names=[..]` |
| Clock | `fp2 date` |
| Free cells, deposits | `fp2 cells free=true [deposit=soil] [nearX=.. nearY=..]` (cells marked `outside` count as buildable; measured), `fp2 extract name=deposits type=logistics` |
| Districts, buildings | `fp2 districts`, `fp2 district_types`, `fp2 building_types [district=Housing]` |
| Research | `fp2 research`, `fp2 research_topics` |
| Frostland territories | `fp2 territories [state=revealed|explored|charted|hidden] [limit=30]`: nearest first, plus those being explored |
| Abilities, generator, heat | `fp2 abilities`, `fp2 generator`, `fp2 heat` |
| Council | `fp2 council`, `fp2 laws` |
| Dialogs | `fp2 modals` |
| Saves | `fp2 saves [limit=20]` (disk listing, newest first; `file` and `display` name) |
| Hotkeys | `fp2 keybinds contains=..`. Measured: Council C, Research R, Frostland V, Districts B |

### Actions

| Action | Command |
|---|---|
| Pick a placement | `fp2 pick_cells count=6 [deposit=soil]` returns connected cells next to the city |
| Build a district | `fp2 place_district type=Housing 'cells=[..6..]' [dryRun=true]` |
| Frostbreak | `fp2 pick_cells count=8 frozen=true [nearX=.. nearY=..]`, then `fp2 expand 'cells=[..8..]' [type=..]`; `fp2 expanders` lists types |
| Build a building | `fp2 place_building type=H_ResearchInstitute [district=Housing]` |
| Explore a territory | `fp2 explore territory=<name or ref> [dryRun=true]` (revealed territories only; `dryRun` shows preparation weeks) |
| Start research | `fp2 research_start topic=<id> [community=<type>]` (the community picks the outcome variant) |
| Answer a dialog | `fp2 choose index=N` |
| Open a map icon's event | `fp2 open_icon ref=<icon ref from extract name=icons>` |
| Toggle an ability | `fp2 ability owner=Production id=Toggle_IndustrialPrefabsProduction active=true` |
| Generator overdrive | `fp2 overdrive active=true\|false` |
| Distribute leftover heat | `fp2 heat_distribute`; `fp2 heat_auto active=true\|false` toggles automatic allocation |
| Adjust one district's heat | `fp2 heat_adjust district=Housing#1 adjustment=1` (labels come from `fp2 heat`) |
| Switch a district off or on | `fp2 district_active district=Production#2 active=false` (off frees its workforce) |

### Time

| Need | Command |
|---|---|
| Pause, resume | `fp2 pause`, `fp2 resume` (verified through the `UserPaused` reason; modals may still pause) |
| Speed | `fp2 speed 1\|2\|3` |
| Let time pass | `fp2 advance [ticks=N]` (1680 ticks = 1 week) |

### Council

Read `fp2 council` (`phase`, `agendaPolicy`, `seats`, `minTicksToNextSession`, `activePolicies`) and
`fp2 laws` (in-game `name`, `description`, `effect`, per-faction support and `seats` For/Against/Hesitant).
Read `name` and `description` before voting: ids mislead (`Children_TraditionStart` is child labour,
"Family Apprenticeship"). `fp2 laws all=true` lists every inactive law; the default lists only laws
proposable now and is empty between sessions. Pick a policy with many seats For and none Against; the game
predicts the same split.

Pass a law when `fp2 council` shows an open session (`phase` 1, Agenda; the watcher emits
`council.sessionAvailable.changed`): `fp2 pass-law policy=<id>`. It runs `council-open` (key C, then skips
the chamber cutscene), `propose` (RequestSession), `vote` (InstructVote), presses Escape on the result
screen, and returns `{policy, vote, active, phase, inParliament}`. Check `active`. Sessions reopened about
10 weeks after each vote (observed).

`propose` and `vote` also exist as bridge commands. Both refuse unless the Council scene is open
(`inParliament`) and no cutscene plays; `unsafe=true` bypasses the scene check and risks locked input.
Measurements are in [MOD_GAPS.md](references/MOD_GAPS.md). Research needs a Research Institute (a Housing building); previously observed: research speed is 0 without one (`fp2 research` shows `speed`).

### Saves, launch, new game

| Need | Command |
|---|---|
| Start or recover the game | `fp2 launch` (closes a stuck crash reporter, starts via Steam, waits for the bridge) |
| New game from the main menu | `fp2 new-game` (Utopia Builder, Windswept Peaks, first 3 communities, intro skipped, paused) |
| Save | `fp2 save name=X` writes immediately; `override=true` reuses the slot with that name |
| Load | `fp2 load name=X` (main menu or in game), `fp2 wait-ready`, `fp2 pause`, `fp2 keys space` (closes the loading screen) |

### UI fallback

Use these only when the bridge has no command.

| Need | Command |
|---|---|
| Screenshot | `fp2 screenshot [region=hud\|objectives\|bottom\|center\|x0,y0,x1,y1] [scale=0.5] [out=path]`; prints a PNG path to Read |
| Click, hold, drag | `fp2 click x,y [--double]`, `fp2 rclick x,y`, `fp2 hold x,y ms=2000`, `fp2 drag x,y x2,y2`, `fp2 scroll x,y ±n`, `fp2 move x,y` |
| Keys | `fp2 keys escape`, `fp2 keys ctrl+r`, `fp2 keys e@3000` (hold 3 s); `--keep-focus` stays in the game |
| Camera | `fp2 camera ref=<object>`, `fp2 camera x=.. y=..`, `fp2 camera reset=true` |
| Object to pixel | `fp2 locate ref=<object>` returns world location and client pixel |
| Focus window | `fp2 focus [--max]` |

Coordinates are game client pixels at full resolution (multiply a `scale=0.5` screenshot pixel by 2).
Fractions 0 to 1 also work. `locate` uses the same pixel space, so `fp2 click <x>,<y>` clicks an object.

UI facts (measured):

- Many confirm buttons need press-and-hold: `fp2 hold x,y ms=2000`.
- Skip cutscenes by holding E: `fp2 keys e@3000`. Holding Space also skips but toggles pause.
- District placement in the UI: Districts menu (`B`), pick a type, click 6 adjacent hex tiles, click the
  check mark. `time.pauseReasons` shows `DistrictPainting` in placement mode. Prefer `place_district`.
- Hatched terrain is frozen; frostbreak it first. Extraction and Logistics districts must start on a deposit.
- Mouse near the window edge pans the camera. Re-center with `fp2 camera ref=first:BP_BaseCity_C`.
- The game stops rendering when unfocused. `screenshot`, `click` and `keys` focus it first. Do not tap Alt
  while the game is focused: held Alt shows the economy overlay.
- A screenshot can come back as a flat dark frame after an action. The CLI retries and sets `blank`.

## Safety rules

- Cutscene guard: do not `choose`, `vote`, `propose`, `ability` or `overdrive` while a pause reason
  contains `Cutscene` (the bridge refuses). `click`, `rclick` and `hold` refuse too unless `--force`.
  Skip the cutscene first. Clicking Council UI during the intro cutscene left it unresponsive (measured).
- Vote and propose only inside the Council scene (`council.inParliament`). `InstructVote` outside it
  locked all game input until a reload (measured).
- Crash hazards (measured): UFunction calls whose struct or container params contain FText crash the game;
  `call` and the mod's own invokes refuse them. Reading SoftObject properties crashes UE4SS; dumps skip
  them. Never pass `unsafe=true` to bypass these. See [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md).
- No cheats: no `TryChange*Stockpile`, no `PXCheat*`, no `set` on game state. New actions must go through
  the game's validated paths (`Instruct*`, `Try*`/`Can*` with an ActionOrigin).
- Never overwrite or delete the user's saves. `save` writes a new numbered file unless `override=true`
  reuses a slot with the same display name; only override agent-named slots.
- `fp2 reload` re-requires all Lua modules except `main.lua`, with no keys. `fp2 reload --full` sends
  Ctrl+R for `main.lua` changes; in game R opens Research, so the CLI closes the Idea Tree afterward.
- Stop a foreground `fp2 watch` before `bun run build`. `watch-start` runs a copy and does not block builds,
  but run `watch-stop` then `watch-start` to pick up the new build.
- One controller drives the UI at a time; a client lock serializes bridge calls.

## Grow the mod as you play

When you read a number from a screenshot, click through a menu repeatedly, or hit a UI wall, add an
extractor or action. Read [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md) first, then check
[MOD_GAPS.md](references/MOD_GAPS.md) for what is known missing.

## References

- [DATA_MAP.md](references/DATA_MAP.md): extractors, field meanings, units, ids. Read when interpreting state.
- [GAMEPLAY.md](references/GAMEPLAY.md): economy rules and early priorities. Read before deciding builds.
- [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md): mod layout, discovery commands, crash hazards. Read before editing Lua.
- [MOD_GAPS.md](references/MOD_GAPS.md): uncovered features and measured caveats. Read before relying on Council or saves.
- `research/fp2_functions.txt`, `research/ACTION_CANDIDATES.md`: callable game functions.
