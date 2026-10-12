# FrostPunk2Agent

Lets AI agents play Frostpunk 2 from exact game data instead of screenshots.

- `mod/FP2AgentBridge`: a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod. Inside the game it
  answers JSON requests over a file bridge. It reflects any UObject, runs curated extractors, and runs
  actions through the game's own command layer.
- `cli/`: `fp2`, a Bun/TypeScript CLI that compiles to `fp2.exe`. It wraps bridge calls and adds triage
  (`brief`), a change watcher, time control, window screenshots, mouse and keys, and launch/save/load.
- Two agent skills:
  - `.agents/skills/play-frostpunk2`: play the game (play loop, data map, gameplay notes).
  - `.agents/skills/fp2-mod-dev`: extend the bridge. Its `references/` hold `MOD_DEVELOPMENT.md` and `MOD_GAPS.md`.

Windows only. Tested with Frostpunk 2 (UE 5.4.3) and UE4SS experimental 3.0.1-1164.

## Setup

Requires [Bun](https://bun.sh), PowerShell, and Steam Frostpunk 2 at the default path (pass `-GameDir`
to `Install-Bridge.ps1` otherwise).

```powershell
./scripts/Install-Bridge.ps1 -Download   # game closed: installs UE4SS, junctions the mod, enables hot reload
cd cli; bun install; bun run build; cd ..
./fp2.exe launch                         # starts the game via Steam, waits for the bridge heartbeat
./fp2.exe status
```

UE4SS is downloaded from its GitHub releases and is not part of this repository.
`scripts/Uninstall-Bridge.ps1` removes UE4SS and the mod junction and restores a backed-up `dwmapi.dll`.

## Workflows

Run `./fp2.exe -h` for the full list. Values are `key=value` and parse as JSON when valid. Quote
arrays in PowerShell: `'cells=[1,2,3]'`.

| Goal | Commands |
|---|---|
| Read everything the HUD shows | `fp2 snapshot` (one bridge call) |
| Triage | `fp2 brief`: alerts, need deficits, depleting stocks, open modals, construction |
| Play | `fp2 turn [weeks=4] [stopOn=..] [speed=3] [saveEvery=2]`: resume, stop at the first stop event or after `weeks` in-game weeks, pause, return `{turn, events, dropped, goals, brief, weather}`. Never runs past the nearest open goal's `due` week; in a cold crisis (whiteout, temperature level 3+) the default length is 1 week |
| Goals | `fp2 goals` (`focus`, ordered `open`, `due`, `threats`), `fp2 goals add text=.. [horizon=long\|short\|check\|threat] [due=<week>] [expect=..] [priority=<1..>]` (threat: due, expect and priority required), `goals done id=N`, `goals edit id=N ..`, `goals rm id=N` (stored in `.runtime/goals.jsonl`, returned by every `turn`) |
| Weather | `fp2 extract name=weather`: temperature now, forecast strip, whiteout start/end, current storm; `brief` leads with it; turn events `threat.warning`, `weather.forecastDrop`, `whiteout.incoming/started/ended` |
| Recover | `fp2 recover [name=..]`: relaunch if needed, load the newest `agent-rolling` or AutoSave (or `name`), wait until ready, pause |
| Wait | `fp2 wait-for cond=<modal\|no-modal\|council\|no-council\|cutscene\|no-cutscene\|paused\|running\|ready\|reason:X\|no-reason:X> [timeout=20]`; `click`, `hold` and `keys` take `wait=<cond>` |
| Stream changes (secondary) | `fp2 watch-start`, then tail `.runtime/watch.jsonl`; `fp2 watch-stop`. `fp2 watch` runs the same loop in the foreground |
| Time (secondary) | `fp2 pause`, `fp2 resume`, `fp2 speed 1\|2\|3`, `fp2 advance ticks=1680` (1680 ticks = 1 week). Prefer `turn` |
| Build | `fp2 pick_cells`, `fp2 district_types`, `fp2 place_district`, `fp2 expand`, `fp2 building_types`, `fp2 place_building`; most take `dryRun=true` |
| Research, abilities, heat | `fp2 research_topics`, `fp2 research_start`, `fp2 abilities`, `fp2 ability`, `fp2 generator`, `fp2 overdrive`, `fp2 heat`, `fp2 heat_distribute` |
| Dialogs | `fp2 modals`, `fp2 choose index=N` |
| Council | `fp2 council`, `fp2 laws`, then `fp2 pass-law policy=<id>` (opens the Council, proposes, votes, verifies; refuses without an open Council session unless `--force`) |
| New game, saves | `fp2 new-game`, `fp2 saves`, `fp2 save name=X`, `fp2 load name=X`, `fp2 wait-ready` |
| UI fallback | `fp2 screenshot`, `fp2 click`, `fp2 hold`, `fp2 keys` |
| Mod development | `fp2 reload` (keyless), `fp2 reload --full` (for `main.lua`), `fp2 describe`, `fp2 object`, `fp2 get`, `fp2 call` |

`turn` stops on: dialogs, threat warnings (a story dialog naming a whiteout, storm or unrest), deaths, need
deficits, stock runway under 10 weeks, deposits running out, forecast drops and incoming whiteouts, research or
construction finished, Council session open, exploration finished, temperature drops, district deactivated by the
game, homeless. Events also go to `.runtime/watch.jsonl`. `turn` keeps a rolling save every `saveEvery` weeks.

Add `--fields a.b,c[0].d` to any command to print only those paths.

Typical session:

```powershell
./fp2.exe recover                                    # relaunch if needed, load newest save, pause
./fp2.exe goals                                      # review the goal stack
./fp2.exe goals add text="Fix coal runway" horizon=short due=12
./fp2.exe turn weeks=4                               # play until a stop event or 4 weeks
./fp2.exe turn --fields turn,events,brief            # same, trimmed output
```

## Status

Working: reads (snapshot, extractors), time control, districts, frostbreaking, buildings, research,
abilities, generator, heat allocation, dialogs, saves, screenshots and input.

Known gaps and constraints:

- Council: `pass-law` needs an open session (`fp2 council` phase 1) and refuses without one unless `--force`. `propose` and `vote` refuse outside
  the Council scene or during a cutscene, because `InstructVote` outside the scene locked all game input.
  Negotiation and promises are not covered. See `.agents/skills/fp2-mod-dev/references/MOD_GAPS.md`.
- Two UE4SS crash classes are guarded: FText inside struct parameters and SoftObject property reads.
- Not covered: Council negotiation and promises, Utopia Tree unlocks, Frostland expeditions and outposts.
- Stop a foreground `fp2 watch` before `bun run build`; the running exe locks `fp2.exe`. `watch-start`
  runs a copy and does not block builds.

Changes are listed in `CHANGELOG.md`.
