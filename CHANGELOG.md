# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project has no tagged releases yet.

## [Unreleased]

### Added

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

- Cutscene guard: `choose`, `vote`, `propose`, `ability` and `overdrive` refuse during a cutscene, and
  `click`, `rclick` and `hold` refuse unless `--force`.
- The watcher ignores bark icons and does not auto-pause on `stock.recovered`.

### Fixed

- `cells`, `pick_cells` and `place_district` treat `Outside` cells as buildable (measured with a Logistics district on an Outside deposit cell).
- UE4SS crash classes are guarded: FText inside struct parameters, and SoftObject property reads.
- `vote` refuses outside the Council scene, where it locked all game input.

### Known issues

- `fp2 pass-law` does not check for an open session before it starts.
- `population.population` sums unassigned community sizes only and differs from the HUD total.
