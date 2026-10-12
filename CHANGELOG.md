# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project has no tagged releases yet.

## [Unreleased]

### Added

- `research.idle` turn and watch event (default stop) and a "research idle" alert in `fp2 brief`: research sat idle for
  weeks with nothing flagging it. `brief` now carries a `research` summary.
- `place_building` dryRun and refusal report `check`: district building limit and used slots, buildings present,
  districts with a free slot, deposits, workforce and stock shortfall, with a plain `blockers` list (Housing#4 was
  1/1 used).
- `threat.warning` turn event: a one-option story dialog whose text names a whiteout, storm, cold wave, generator
  failure or unrest is still acknowledged but now stops the turn (the whiteout warning "An Old Enemy" was
  auto-acknowledged and missed; 40 died 73 weeks later).
- Goals: `horizon=threat` (requires `due`, `expect` and `priority`), explicit `priority=<1..>` on any goal, an
  ordered `open` list (priority, then threat/check/short/long, then due), `focus` (top of the stack) and `threats`
  (every open threat with `weeksLeft`) in `fp2 goals` and every `turn`.
- `turn`: never runs past the nearest open goal's `due` week (`stoppedBy.reason` `goalDue`); in a cold crisis
  (whiteout active or temperature level 3+) the default length is 1 week (explicit `weeks=` kept); `turn.capped`
  and a warning say which rule applied. The result carries a `weather` summary (level, next drop, whiteout).
- `brief` reads the weather and leads its alerts with an active or forecast whiteout and the next temperature drop.
- `weather` extractor (in `snapshot`): current temperature level and degrees, the forecast strip
  (`PXTemperatureUtils.GetTemperatureTimeline` over the game's prediction interval, 100 weeks) and whiteout state.
  Measured live mid-whiteout: the storm is a timeline entry with a `Weather` object and `EnterWeatherIntersection`
  (true = arrives, false = leaves), and `PXWeatherUtils.GetCityWeatherLevel` names it ("Sun-Dimming Storm") while it
  covers the city ("Calm", level 0, otherwise); `whiteout.endsInWeeks` read 3.9. At week 129 the strip already held
  the whiteout 70.6 weeks ahead and `turn` stopped on `whiteout.incoming` (measured). Turn events
  `weather.forecastDrop` (stops for a drop of 2+ levels or to level 3+) and `whiteout.incoming` (stops), plus
  `whiteout.started` / `whiteout.ended`; each forecast warning fires once.
- Skill: thinking pattern 6 (a catastrophe outranks the plan) and a measured Whiteout playbook in GAMEPLAY.md.
- `deposit.depleting` turn event (stops at 10 weeks or less) for deposits worked by Extraction-type districts, from the
  amount trend between snapshots. New extractor `districtDeposits`, included in `snapshot`.
- `build_outpost` and `connect_outpost` (Frostland outposts; connection needs a trail).
- `deconstruct district=X [dryRun]`: refund preview and deconstruction at the normal duration.
- `generator` reports `wear`, `wearIncreasing`, `broken`; `overdrive-cycle` duty-cycles overdrive under a wear ceiling.
- `brief` counts only dialogs with choices as decisions.
- `fp2 turn [weeks=4] [stopOn=..] [speed=3] [saveEvery=2]`: the play primitive. Resumes time, stops at the first
  stop event or after `weeks` in-game weeks, pauses, and returns `{turn, events, dropped, goals, brief}`. Events also
  go to `.runtime/watch.jsonl`. Rolling save every `saveEvery` weeks.
- `fp2 goals`, `goals add`, `goals done`, `goals edit`, `goals rm`: goal stack in `.runtime/goals.jsonl`, returned by
  every `turn`.
- `fp2 recover [name=..]`: relaunch if needed, load the newest agent-rolling or AutoSave (or `name`), wait until
  ready, pause.
- `fp2 wait-for cond=.. [timeout=20]`; `click`, `hold` and `keys` take `wait=<cond>`.
- `--fields a.b,c[0].d` on any command prints only those paths.
- `reload` errors include a `context` field.
- Skill split: `.agents/skills/play-frostpunk2` (play) and `.agents/skills/fp2-mod-dev` (extending the bridge;
  references hold `MOD_DEVELOPMENT.md` and `MOD_GAPS.md`).
- `district_expansion` (levels, cells, cost, upgrade type) and `expand_district` (experimental; see MOD_GAPS),
  `instruction_hooks` / `instruction_log` for learning instruction arguments.
- `call` converts strings to FName for Name params; `advance` waits through SavingGame pauses; watcher auto-ack
  targets the modal by ref and reports `dialog.ackFailed`.
- Skill: "How to approach the game" section: the causal game loop, time scales, and five thinking patterns
  (stabilize before growth, goal stack over events, decide from facts, respect lead times, name the binding constraint).
- Layout: `district_types` proximity gives/takes, `districts` efficiency and proximity effects, `layout_preview`,
  and layout-scored `pick_cells type=X`.
- `building_types` adds name, description, effects, statistics and economy; snapshot `unlocks` lists buildings and
  abilities; watcher emits `building.unlocked` and `ability.available`; construction entries name the building.
- Skill: planning cadence, binding-constraint thinking, lead times, verification and shell rules (from session review).
- `abilities describe=true` returns each ability's in-game name and description.
- `place_building district=` accepts labels from `districts` (for example `MainQuarter#0`).
- `frost_sites`: Frostland outposts (settlement upgrade chain) and colony sites with territory and state.
- `call` fills `WorldContextObject` with the PlayerController (`"@ctx"` placeholder) after a guessed context crashed the game.
- Tech tree planning: `research_topics all=true` describes locked topics (outcomes, requirement trees,
  prerequisite topics, research weeks); `research_plan topic=X` returns the ordered path to a topic.
- `utopia` reads each faction's Utopia Tree (points, nodes, state, descriptions, links);
  `utopia-assign node=X` spends a point through the game's panel handlers.
- Watcher `autoAck` (on in `watch-start`) dismisses one-option dialogs and reports `dialog.acknowledged`.
- `modals` choices include hidden `actions` and `affinities`; game text decodes HTML entities.
- `frostbreak_path`: plans frostbreaking to a cell or deposit (shortest frozen route plus room for a
  district) in expander-sized batches; `go=true` starts the first batch.
- `research` reports `progress` and `weeksLeft`; `research_topics` reports names, questions, outcome
  descriptions and the city problems each outcome solves (`solves=<Statistic>` filter).
- `watch-start` keeps a rolling save (`agent-rolling`, every 2 in-game weeks by default; `saveEvery`, `saveName`).
- `save` writes immediately (`SaveGameImmediate`) and takes `override=true` to reuse a slot.
- `saves` shows each file's display name; `load` accepts a file name or display name and uses
  `ForceLoadGame` from the main menu.
- `laws` returns each law's in-game name, description and effect text; `all=true` lists every inactive law.
- `laws` returns `effects`: each law's modifier effects as data (for example Mass-Produced Goods →
  `EconomyResourceRatio`, `Ratios: {Goods: 0.25}`).
- Watcher emits `notification` for dialogs without choices (population growth, info popups) instead of
  `dialog.opened`, so they no longer auto-pause the game.
- `districts` returns label, workforce, active state and deactivation reasons.
- UE4SS Lua mod `FP2AgentBridge` with a file bridge (`request.json`, `response.json`, `status.json`
  heartbeat), generic reflection commands, and curated extractors for time, resources, needs, statistics,
  population, society (trust, community standing, death toll and deaths by cause), construction, quests, map icons, districts and deposits.
- Game actions through the game's own command layer: districts, frostbreaking, buildings, research,
  abilities, generator overdrive, heat allocation (`heat`, `heat_distribute`, `heat_auto`, `heat_adjust`), `district_active` (switch a district off or on), Frostland exploration (`territories`, `explore`), event
  decisions, `save` and `load`. Most mutations accept `dryRun=true`.
- Council reads (`council`, `laws`), guarded `propose` and `vote` commands, and `fp2 pass-law`, which
  runs the whole flow (open the Council, propose, vote, dismiss the result, verify).
- `snapshot` command: the whole HUD in one call, including decision choices in modals.
- `fp2` Bun/TypeScript CLI (compiles to `fp2.exe`): `brief`, `advance`, pause and speed control,
  `snapshot`, screenshots, mouse and keys, `launch`, `new-game`, `council-open`, `saves`, `wait-ready`.
- `fp2 watch`, `watch-start` and `watch-stop`: one JSON line per meaningful change (dialogs, construction
  and research, deficits, statistic bands, stock runway, quests, icons, Council phase, deaths, Frostland exploration), with optional
  auto-pause (including `deaths.increased`) and a detached watcher that appends to `.runtime/watch.jsonl`.
- Keyless `bridge.reload` (`fp2 reload`); `fp2 reload --full` for `main.lua` changes.
- `keybinds` command listing Enhanced Input bindings.
- Install and uninstall scripts for UE4SS and the mod junction (`scripts/`).
- `play-frostpunk2` agent skill with data map, mod development guide, gameplay notes and known gaps.

### Changed

- `overdrive-cycle` switches off when the predicted wear at the next poll reaches `maxWear` (polling every 120 ms)
  instead of after an overshoot; at whiteout demand wear went 0.05 to 0.69 inside one 250 ms poll and the old loop
  stopped on "overshot" before switching off (measured, twice). Reports `overshoots`.
- `turn` heartbeat: the loop estimates the game clock rate and, in the final stretch, polls `extract time` and pauses
  at `weeks` itself. Before, the fixed 1.5 s poll let speed 3 (about 3.4 weeks per real second, measured) run
  5.75 weeks on `weeks=2`. Overshoot is now about one bridge round trip.
- `recover` focuses the game window (verified, retried) before the dismiss key and proves the loading screen closed
  by game time advancing; up to 3 presses (space, enter, space).
- `turn` and `watch-start` rotate saves over `<saveName>-a/-b/-c` (oldest overwritten) instead of one
  `agent-rolling` slot, which became unloadable once and left no fallback.
- `recover` detects a crash during load (process gone, new crash report, crash reporter, stale heartbeat), kills the
  game and loads again, up to `attempts=3`, and reports each failed save. A crash with no bridge calls in flight
  marks the save in `.runtime/bad-saves.json` and moves to the next save (`agent-rolling*`, `agent-*`, `AutoSave*`).
  `saves` flags bad saves.
- After a successful `load`, all clients hold game-thread calls for 90 s (`.runtime/load-quiet-until`,
  `FP2_LOAD_QUIET_SECONDS`); polling during a load crashed the game in Wwise. `status` shows `loadQuietSeconds`.
- `pass-law` refuses without an open Council session unless `--force`.
- Cutscene guard: `choose`, `vote`, `propose`, `ability` and `overdrive` refuse during a cutscene, and
  `click`, `rclick` and `hold` refuse unless `--force`.
- The watcher ignores bark icons and does not auto-pause on `stock.recovered`.

### Fixed

- `deposit.depleting` no longer fires for a deposit that was already empty when a new `turn` took its first sample
  (a dead sawmill stopped every turn after 0.25 weeks, measured).
- `build_outpost` validates the outpost, its type, the city and the Leader origin before `InstructConstructOutpost`
  and refuses an already-built outpost; `frost_sites`, `overdrive`, `heat`, abilities and `connect_outpost` validate
  optional sub-objects before calls (food-herd outpost crash; needs live verification).
- `cells`, `pick_cells` and `place_district` treat `Outside` cells as buildable (measured with a Logistics district on an Outside deposit cell).
- UE4SS crash classes are guarded: FText inside struct parameters, and SoftObject property reads.
- `vote` refuses outside the Council scene, where it locked all game input.
- Actions no longer read the object an instruction acted on through the old reference (stale-object crash after
  `InstructConstructOutpost`). They re-find it by path or drop the read: `ability`, `overdrive`, `heat_adjust`,
  `district_active`, `explore`, `expand_district`, `deconstruct`, `connect_outpost`, `utopia_assign`; `choose`
  reads the modal before clicking; `build_outpost` returns no post-instruction state.

### Known issues

- `population.population` sums unassigned community sizes only and differs from the HUD total.
