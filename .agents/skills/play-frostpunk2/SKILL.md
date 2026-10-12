---
name: play-frostpunk2
description: Play Frostpunk 2 through the FP2AgentBridge UE4SS mod and the `fp2` CLI. Use for a play session. Start with `fp2 recover`, keep a goal stack in `fp2 goals`, and advance with `fp2 turn`, which runs until a stop event or a heartbeat and returns events, due goals and a brief. The bridge and CLI are read-only during play: log every missing read, action or bug in BRIDGE_FEEDBACK.md and play on.
---

# Play Frostpunk 2

Frostpunk 2 is a city-survival builder. Keep the city warm, fed, housed and supplied, expand districts onto deposits,
research ideas, and pass laws in the Council while factions pull the city apart. You lose when Trust or Tension
collapses, or when people freeze or starve. Aim for the best decision per in-game week, with tokens as the constraint.
Use bridge commands for state and actions; use screenshots and input only where no command exists.

All commands go through `./fp2.exe` at the repo root (`fp2 -h` lists them). Run it from PowerShell: Git Bash rewrites
`/Script/...` arguments into Windows paths (there, prefix `MSYS_NO_PATHCONV=1`). Quote arrays: `'cells=[1,2,3]'`.

## How to approach the game

### The game loop

- **Heat drives everything.** Generator power and heat allocation feed the needs (Heating, Warmth, Shelter,
  Nourishment, Possession, Maintenance). A negative need raises its statistic (Cold, Hunger, Squalor, ...), which
  raises Tension and erodes Trust. Temperature drops are forecast (`turn.weather`, `fp2 brief` alerts, the HUD
  strip); a whiteout is announced by a story dialog about 70 weeks ahead (measured). Generator headroom (`power`
  vs `powerLimit`) is the safety margin for what the forecast misses.
- **Inputs are scarce and shared.** Workforce staffs districts and running construction. Prefabs and Cores gate
  districts, upgrades and colonies. Heatstamps pay for research, buildings and hubs. Coal, food and materials are
  flows: read `change` and runway, not stock alone.
- **Time scales differ by an order of magnitude.** Stocks drain in weeks. Construction takes 2 to 5 weeks, research
  10 to 30. Council sessions come about 10 weeks apart. Laws, migration and abilities take weeks to act.
- **Society reacts to everything.** Each law, research variant and dialog choice shifts community standing. New
  factions bring their own quests and Utopia Trees. Trust and Tension decide survival as much as resources do.
- **Expansion competes with the city.** Exploration, outposts, settlements and colonies draw on the same scarce
  inputs the city needs to survive.

### Thinking patterns

These habits separated good turns from bad ones in past runs. They do not say which choice to make.

1. **Stabilize before you grow.** Before a growth commitment, check generator headroom, food and fuel runway, free
   workforce, Squalor and Tension trends, recent deaths, and whether growth spends inputs survival needs. No slack:
   fix the base first. Record the verdict; revisit it after a temperature drop or population jump. (A past run
   expanded while people froze and food fell.) Checklist: [GAMEPLAY.md](references/GAMEPLAY.md).
2. **Plan from the goal stack, not from events.** An event is a prompt to re-check the stack, not an instruction.
   Waiting while stocks build is a real move. (A past run spent ~170 wakeups reacting and neglected its quests.)
3. **Decide from facts, never from ids or defaults.** Resolve every id to its in-game name, description and effects,
   and compare the alternatives, including research variants. If the bridge cannot show it, get the read first.
   (A past run passed a child-labour law believing it was something else.)
4. **Respect lead times before judging.** Write down the expected effect and when it should show. Do not call an
   action a failure before then. (A past run called the migration law useless; it later brought +200, then +1,191.)
5. **Name the binding constraint and the trade.** State which input limits you and what the choice costs. When
   unsure, prefer reversible moves (district on/off, ability toggles), then measure.
6. **A catastrophe outranks the plan.** A whiteout warning is not one more event: it reorders the stack. Decide
   out loud where survival sits (`priority=1`), which long-horizon goals it defers and until when, and keep that
   order until the threat has passed. (A past run noted "whiteout coming" as an undated short goal at week 128, went
   back to colonies and factories, undid its own heat shedding, and lost 40 people at week 201.) Playbook:
   [GAMEPLAY.md](references/GAMEPLAY.md#whiteout-playbook).

## Session start

1. `fp2 status`, then `fp2 recover` (launches if needed, loads `name=X` or the newest `agent-rolling-*`, `agent-*`
   or `AutoSave*`, ends paused; a save that crashes the game on load is marked bad and the next one is tried, up to
   3 loads). After any load, bridge calls wait ~90 s (polling mid-load crashed the game); do not work around it. First install: `./scripts/Install-Bridge.ps1` with the game closed. If `turn` warns about a
   detached watcher, run `fp2 watch-stop`.
2. `fp2 health` (verdict and reasons: act on `critical` and `act` first), then `fp2 goals`. If empty, seed it: `long` = the scenario quest (`fp2 snapshot --fields quests`); `short` = one
   city-problem target, one capacity goal, and the research path from `fp2 research_plan topic=X`. Read
   `goals.focus` (top of the stack) and `goals.threats` (every open threat with `weeksLeft`), and `fp2 brief`
   `weather` before the first turn. Then `fp2 turn`.

## The turn loop

`fp2 turn` resumes time, runs until the first stop event or `weeks` in-game weeks (the heartbeat), pauses, and
returns `{turn: {fromWeek, toWeek, date, advancedWeeks, stoppedBy: {reason, kinds}, capped?}, events, dropped,
goals: {focus, open, due, threats, file}, brief, weather, warnings?}`. Two rules shorten a turn on their own:
it never runs past the nearest open goal's `due` week (`stoppedBy.reason` `goalDue`, so every check and threat
is judged exactly when you said it would be), and in a cold crisis (whiteout active, or temperature level 3 or
colder) the default length is 1 week (an explicit `weeks=N` is kept). `turn.capped` says which rule applied.
Each turn:

- Pauses: `turn` ends paused by design. A story event sets the player pause flag, and its dialog only appears once time runs; `turn` resumes once on a bare `UserPaused` so the dialog shows up as a stop event (measured). A second bare `UserPaused` is a real player pause. Your own district toggles and temperature rises do not stop a turn.
- Read `stoppedBy.reason`. `event` or `heartbeat`: continue below. A modal class: `fp2 modals`, decide,
  `fp2 choose index=N`. `Cutscene ...`: skip with `fp2 keys e@3000`. `UserPaused`: the user paused; ask before
  resuming. With a modal or cutscene already open, `turn` returns at once without resuming time.
- Treat each event as a question: does it threaten a goal, finish one, or open an option? If not, let it pass.
  Quiet turn: run the next one. Event kinds and reactions: [DATA_MAP.md](references/DATA_MAP.md#turn-events).
- Act only when a goal or a stop event calls for it. Apply thinking patterns 1, 3, 5 and 6 first.
- **Threats.** `threat.warning` (a story dialog whose text names a whiteout, storm, cold wave or unrest; it is
  acknowledged for you but still stops the turn), `whiteout.incoming`, `weather.forecastDrop` and
  `whiteout.started` each demand a decision now, not a note. Add `fp2 goals add horizon=threat priority=1
  due=<arrival week> expect="<what prepared looks like>" text=".."`; `due`, `expect` and `priority` are required,
  so you state the arrival week and the rank. `due` = the current week plus `turn.weather.whiteout.startsInWeeks`
  (measured: the strip held the whiteout 70 weeks ahead, at the same time as the story warning). Add check goals
  for the preparation steps with their own due weeks (fuel full by week X, generator upgrade done by week Y), so
  `turn` lands on each. Then edit the goals it defers (`goals edit id=N priority=..` or a note) so `goals.focus`
  reads the threat. Work the playbook in GAMEPLAY.md until `whiteout.ended`; only then restore deferred priorities.
- When an action has a delay (law, build, research), add `fp2 goals add horizon=check due=<week> expect=".."`.
- When `goals.due` is non-empty, judge each `expect` against the brief, then `fp2 goals done id=N note=".."` or
  `fp2 goals edit id=N due=.. expect=..` with the reason.
- Re-plan when research finishes, a build completes, a Council session opens, a territory is explored, or the
  heartbeat fires: re-read `fp2 health`, `snapshot.quests`, `fp2 research_plan`, `fp2 utopia`, `fp2 frost_sites`, free workforce
  and stocks, and update the `long` and `short` goals.
- Read only what the decision needs: `fp2 turn --fields turn,events,goals.focus,goals.due,goals.threats,weather,brief.alerts`.
- Target shape (not yet built): the game keeps running, `fp2 watch-start` streams events to `.runtime/watch.jsonl`,
  and the agent reads them under a Monitor while it reasons, adapting without pausing. Until then `turn` pauses
  at each stop; keep turns short in a crisis and long when the stack is quiet.

**Gameplay blog.** Keep a decision log in `gameplay-<YYYY-MM-DD>.html` (one self-contained page per real-world day,
repo root). At each major decision (law, large build, deaths, crisis, recovery), insert an entry after
`<!-- entries:start -->`: in-game date, what you did, the tradeoff and its human cost, and what kind of city it
builds. State guesses and mistakes plainly. Keep entries brief; the log is secondary to play.

## Commands

Never pipe `fp2` output through python or `ConvertFrom-Json`; use `--fields a.b,c[0].d` (one path prints the value,
several print an object keyed by path; `*` maps over an array: `fp2 laws --fields "*.id,*.name,*.seats"` prints one
row per law). Never `Start-Sleep` after an input; use `wait=<cond>`. Mutating commands
validate through the game and charge normal costs; most accept `dryRun=true`.

| Need | Command |
|---|---|
| Play a turn | `fp2 turn [weeks=4] [stopOn=kind,..] [speed=3] [saveEvery=2] [saveName=agent-rolling] [autoAck=true]`; saves rotate over `agent-rolling-a/-b/-c` |
| Goal stack | `fp2 goals [all=true]` (`focus`, `open` ordered by `priority` then threat/check/short/long then due, `due`, `threats`), `goals add text=".." [horizon=long\|short\|check\|threat] [due=<week>] [expect=".."] [priority=<1..>]` (threat: `due`, `expect`, `priority` required), `goals done id=N [note=..]`, `goals edit id=N [text=..] [due=..] [expect=..] [horizon=..] [priority=..]`, `goals rm id=N`. File: `.runtime/goals.jsonl` |
| Start, crash recovery | `fp2 recover [name=<save display name>] [attempts=3]`; in a loaded game it loads `name=X` in place, or only pauses when no name is given (measured). Load crashes go to `.runtime/bad-saves.json` (`fp2 saves` shows `bad`) |
| Wait for state | `fp2 wait-for cond=<c> [timeout=20]`; `c`: `modal`, `no-modal`, `council`, `no-council`, `cutscene`, `no-cutscene`, `paused`, `running`, `ready`, `reason:<s>`, `no-reason:<s>`. `click`, `hold`, `keys` take `wait=<c>` |
| HUD, triage | `fp2 snapshot` (every HUD section), `fp2 brief` (weather and whiteout first, then alerts, deficits, depleting stocks, modals, construction), `fp2 extract name=<x>` (omit `name` to list), `fp2 date`, `fp2 extract name=weather` (level and degrees now, forecast entries with `whiteout`/`whiteoutEnds`, `whiteout {active, startsInWeeks, endsInWeeks}`, `storm` while one covers the city; measured) |
| Districts | `fp2 districts` (efficiency, proximity, workforce), `fp2 district_types`, `fp2 district_active district=Production#2 active=false` (frees workforce) |
| Place a district | `fp2 pick_cells count=6 [type=X] [deposit=soil]`, `fp2 layout_preview type=X 'cells=[..]'`, `fp2 place_district type=Housing 'cells=[..6..]'`; deposits: `fp2 cells free=true deposit=..`, `fp2 extract name=deposits` |
| Deconstruct | `fp2 deconstruct district=X dryRun=true` shows the refund (a depleted Extraction district returned 158 prefabs + 75 heatstamps over 3 weeks, measured); without dryRun starts it at normal duration |
| Buildings | `fp2 building_types [district=Housing]`, `fp2 place_building type=H_ResearchInstitute [district=Housing#0] [dryRun=true]` (`check` shows district slots used/limit, free-slot districts, workforce, stock shortfall and `blockers`; a refusal names them; measured: Housing#1/#4/#9 had limit 1, 1 used; the limit differs per district and what raises it is unknown) |
| Frostbreak | `fp2 frostbreak_path deposit=Logistics [go=true]`, or `fp2 pick_cells count=8 frozen=true` + `fp2 expand 'cells=[..8..]'` |
| Research | `fp2 research` (`speed` 0 without a Research Institute, observed), `fp2 research_topics [all=true] [solves=Squalor]`, `fp2 research_plan topic=X`, `fp2 research_start topic=<id> community=<type>` |
| Outposts | `fp2 build_outpost type=Coal territory=Steppes [dryRun=true]` (measured: built instantly, no stockpile cost, state Operational), `fp2 connect_outpost type=X` (needs a trail first; see MOD_GAPS) |
| Utopia, Frostland | `fp2 utopia`, `fp2 utopia-assign node=X`, `fp2 territories`, `fp2 explore territory=X [dryRun=true]`, `fp2 frost_sites [kind=outpost\|colony]` |
| Health | `fp2 health` (one call under 3 KB): `verdict` (critical > act > watch > ok) with `reasons`, runway bands (ok >= 20 weeks, watch 10-20, act 5-10, critical < 5), generator load, `caps`, Council open, whiteout, quests. Act on `critical` and `act` reasons first; tier bands are guesses |
| Stock caps, heat levels | `fp2 stock_caps` (resources at their cap and still gaining, weeks to cap, the depot hub that raises each limit), `fp2 heat_levels [deep=true]` (per-district heat level name, bad levels, insulation, generator headroom; pair with `heat_adjust`/`heat_distribute`) |
| Utopia detail | `fp2 utopia_v2 [unlocks=true]` (points, score, assignable nodes, what a node grants). Spend only when `hasPoint` is true: `fp2 utopia-assign node=X` |
| Factions | `fp2 factions [community=X] [detail=tiers]` (size, seats, standing, fervor, promises with `weeksLeft`, tension, trust), `fp2 vote_predict [policy=X] [detail=predict,history]` (required votes, seats For/Against/Hesitant, `margin`; below 0: negotiate or sway), `fp2 sway` (reads mode and cost) |
| Community actions | `fp2 community_actions community=X`, then `fp2 community_action community=X action=Y [target=Z] [district=D] dryRun=true`, then without `dryRun`. One use per community per cooldown (FundProjects_CA: 20 weeks, -154 heatstamps, +0.1 standing, measured) |
| Pass a law, UI in sync | Save first, outside the Council. `fp2 keys c keepFocus=true`, then `fp2 council_ui` (`lobbyVisible` true), then `council_ui step=` `laws`, `law policy=X`, `select policy=<exact id>` (phase becomes Negotiations), optional negotiation (next row), `vote` (LAW PASSED), then `fp2 keys escape` on the results screen. `select` needs an id from `fp2 laws` (proposable list) |
| Negotiate, sway | `council_ui step=negotiate`, `community community=X`, `side side=for`, `terms` (their demands in screen order), `term index=N`, `accept`; the promise starts after the vote. `fp2 negotiate [community=X]` reads status (`cancel=true` untested), `council_ui step=sway mode=SwayAye` untested |
| Promises | `fp2 factions` lists them. `fp2 promise` only points to the negotiation path. `fp2 promise_abandon community=X [promise=<index\|name>] [dryRun=true]`: default `path=quest` fails the quest (measured working; standing likely drops). `path=abandon` crashed the game once and needs `force=true`: do not use. A story-dialog "promise" is a quest, not a community promise |
| Frostland teams, expeditions | `fp2 frost_teams` (total/inUse/free; 15 per active Logistics district), `fp2 explorations [state=unexplored\|exploring\|explored] [weather=true]` (weeks, difficulty, resources; teams cost reads only as the `frost_teams` delta), `fp2 explore_stop territory=<name> [dryRun=true]` (recall an expedition before a whiteout; teams return, progress is lost) |
| Outposts | `fp2 outposts` (deposit left, extraction weeks, teams, active reasons, connection, storm), `fp2 outpost_active type=<id> active=false` (frees teams), `fp2 outpost_upgrade type=<id> [dryRun=true]` (the game may refuse silently), `fp2 build_outpost2 territory=<name> [type=<id>] [dryRun=true]` (safer build path). `outpost_action` lists nothing (unproven) |
| Trails | `fp2 trails` (types, live trails, `constructing`), `fp2 trail_plan type=<outpost>` (grid facts, candidate cells; unproven). `trail_build` is gated (cell format unresolved). `trail_tool step=start/status/build/cancel` drives the painter; untested, needs an available trail type (V first) |
| Colonies | `fp2 cities` (index, main/colony, population, workforce, unrest, stock), `fp2 colony_sites [territory=X] [details=true]` (cost, weeks, `canShow`, `built`), `fp2 colony_build site=X [community=Y] [parent=N] [dryRun=true]` (founds a colony: save first; 3000 people leave the main city, other costs unverified) |
| Trade, people | `fp2 trade_routes [city=N]` (limit per resource, trail capacity; trading is locked until unlocked), `fp2 trade_route to=N resources='{"food":100}' [replace=true] [dryRun=true]` (0 stops a resource; refuses over the limit; mutation untested), `fp2 transfer_people to=N amount=K [community=X] [from=M] [dryRun=true]` (a relocation unit carries them: main city drops at once, colony gains on arrival) |
| Abandon, recolonize | `fp2 city_abandon city=N confirm=true [dryRun=true]` (never the main city), `fp2 recolonize city=N [community=X] [confirm=true] [dryRun=true]`; real calls untested |
| Colony unrest | `fp2 colony_exchange`: unrest per city and the count of independent-colony exchange components. The exchange itself is not readable (a full read crashed the game) |
| Heat, abilities | `fp2 generator` (`wear` 0..1; 1 = malfunction with casualties), `fp2 overdrive-cycle [weeks=1] [maxWear=0.5]` (duty-cycled overdrive under a wear ceiling), `fp2 heat`, `fp2 heat_distribute`, `fp2 heat_auto active=true`, `fp2 heat_adjust district=Housing#1 adjustment=1`, `fp2 overdrive active=true`, `fp2 abilities describe=true`, `fp2 ability owner=Production#N id=<id> active=true` |
| Dialogs, map icons | `fp2 modals`, `fp2 choose index=N`, `fp2 extract name=icons`, `fp2 open_icon ref=<icon ref>` |
| Saves, time | `fp2 saves`, `fp2 save name=agent-X [override=true]`, `fp2 new-game`, `fp2 launch`; secondary: `fp2 pause`, `fp2 resume`, `fp2 speed 1\|2\|3`, `fp2 advance [ticks=N]` (1680 ticks = 1 week) |
| UI fallback | `fp2 screenshot [region=hud\|..] [scale=0.5]`, `fp2 click x,y [wait=..]`, `fp2 hold x,y ms=2000`, `fp2 keys escape`, `fp2 camera ref=<obj>`, `fp2 locate ref=<obj>`, `fp2 keybinds contains=..` |

UI facts (measured): pixels are game client pixels (double a `scale=0.5` screenshot pixel); `locate` uses the same
space. Many confirm buttons need `fp2 hold x,y ms=2000`. Skip cutscenes with `fp2 keys e@3000`. Do not tap Alt in
game (economy overlay). The mouse at the window edge pans; re-center with `fp2 camera ref=first:BP_BaseCity_C`.
Hotkeys: Council C, Research R, Frostland V, Districts B.

## Council

Read `fp2 council` (`phase`, `agendaPolicy`, `minTicksToNextSession`, `activePolicies`) and `fp2 laws` (in-game
`name`, `description`, `effect`, `effects`, and seats For/Against/Hesitant, which predict the vote). The default
lists laws proposable now; `all=true` lists every inactive law.

Asset ids do not say what a law does. Read each candidate's text and `effects`, then decide for this run: weigh
what it costs people against what the city needs now (deficits, workforce, deaths, trust) and against the
alternatives. No law is always right or always wrong. Record the reasoning in the gameplay blog.

`fp2 pass-law policy=<id>` opens the Council, proposes, votes, dismisses the result and returns `active`; check it.
It refuses when no session is open (`phase` 1) unless `--force`. Sessions reopened ~10 weeks after a vote (observed).

For a law that needs a negotiation, or when the hub shows its lobby, drive the hub with `fp2 council_ui` steps (table
rows "Pass a law, UI in sync" and "Negotiate, sway"). Check the vote first with `fp2 vote_predict`.

Council UI rules (measured 2026-10-11):

- The UI must leave the lobby before a proposal. `propose` (RequestSession) while the hub still showed its lobby
  moved the phase to Negotiations with the UI left on the lobby, and a click on "PROPOSE A LAW" then crashed the
  game. `propose` now refuses while the lobby is visible unless `force=true`. Use the `council_ui` steps above:
  `council-open` (or `fp2 keys c keepFocus=true`) -> `laws` -> `law` -> `select` -> `negotiate` -> `community` ->
  `side` -> `terms`/`term` -> `accept` -> `vote`. Each step fires the panel's own button event and kept the UI in
  sync through propose, negotiate, accept and the vote (LAW PASSED 55 For / 51 required, then Escape).
- Pixel clicks on the lobby did nothing, and a Space keypress did not advance it. Use the steps.
- Never save inside the Council scene: a save written there did not load (the game stayed at the main menu).
  Save before opening it. `fp2 save` warns.
- `council-open` failed twice ("Council did not open") while `fp2 keys c keepFocus=true` opened it. Cause inferred:
  the key press restores the previous foreground window at once and the key is lost.
- The "?" `WBP_Tutorial_New_C` widget in each hub panel is a hint button, not a modal.
- `phase` 1 (Agenda) with `minTicksToNextSession` 16800 means a session is available; the recess length is config.
  A law passed with a promise starts a quest ("Promise to Merchants", 40 weeks) that `fp2 factions` lists.
- `fp2 pass-law` sends the bridge `propose` (CLI code), so the lobby guard refuses it while the hub shows the lobby;
  not re-run since the guard was added. Prefer the steps above, and they are the only path for a negotiation.

## Safety rules

- Cutscene guard: `choose`, `vote`, `propose`, `ability`, `overdrive`, and `click`/`rclick`/`hold` without `--force`
  refuse during a `Cutscene` pause reason. Skip it first: Council input during a cutscene froze the UI (measured).
- Vote and propose only inside the Council scene (`council.inParliament`). `InstructVote` outside it locked all
  game input until a reload (measured). Never pass `unsafe=true`.
- No cheats: no `TryChange*Stockpile`, `PXCheat*`, `call` or `set` to change game state.
- Never overwrite or delete the user's saves. Use `override=true` only on agent-named slots.
- When a command has no visible effect, read `pauseReasons`, `cutscene`, `modals` and window focus before
  repeating it. A `true` return proves neither effect nor persistence (measured).

## Bridge and CLI are read-only during play

Play agents never edit `mod/`, `cli/`, or `fp2.exe`, never run `fp2 reload`, and never use the reflection commands
(`call`, `object`, `get`, `set`, `describe`, `find_all`, `search`, `functions`, `classes`). Those belong to the
maintainer, who refines the bridge between sessions from your notes.

When a read or action is missing, wrong, or crashes, append an entry to [BRIDGE_FEEDBACK.md](../../../BRIDGE_FEEDBACK.md)
(repo root) and continue with what exists (`fp2 screenshot`, `click`, `hold`, `keys` are the UI fallback). One entry
per gap, newest at the bottom, this shape:

```
## <date> wk <week> | <command or feature> | <gap|bug|crash|doc>
- Wanted: <the decision you were making and the read or action you needed>
- Tried: <exact fp2 commands and what they returned; the HUD value if you read one from a screenshot>
- Workaround: <what you did instead, or "none; skipped the decision">
- Cost: <what the gap cost: tokens, weeks of play, a wrong decision, a death wave>
```

Label values measured (from a command or the HUD) or inferred. Do not propose code. Do not log the same gap twice:
grep the file for the command name first and add a line under the existing entry instead.

## References

- [DATA_MAP.md](references/DATA_MAP.md): extractors, turn events, fields, units, ids. Read to interpret state.
- [GAMEPLAY.md](references/GAMEPLAY.md): economy and heat rules, stability check. Read before deciding builds.
- [MOD_GAPS.md](../fp2-mod-dev/references/MOD_GAPS.md): uncovered features, measured Council and save caveats.
