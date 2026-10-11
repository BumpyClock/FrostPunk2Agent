# Changelog

All notable changes are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The project has no tagged releases yet.

## [Unreleased]

### Added

- UE4SS Lua mod `FP2AgentBridge` with a file bridge (`request.json`, `response.json`, `status.json`
  heartbeat), generic reflection commands, and curated extractors for time, resources, needs, statistics,
  population, society (trust, community standing), construction, quests, map icons, districts and deposits.
- Game actions through the game's own command layer: districts, frostbreaking, buildings, research,
  abilities, generator overdrive, heat allocation (`heat`, `heat_distribute`, `heat_auto`), event
  decisions, `save` and `load`. Most mutations accept `dryRun=true`.
- Council reads (`council`, `laws`), guarded `propose` and `vote` commands, and `fp2 pass-law`, which
  runs the whole flow (open the Council, propose, vote, dismiss the result, verify).
- `snapshot` command: the whole HUD in one call, including decision choices in modals.
- `fp2` Bun/TypeScript CLI (compiles to `fp2.exe`): `brief`, `advance`, pause and speed control,
  `snapshot`, screenshots, mouse and keys, `launch`, `new-game`, `council-open`, `saves`, `wait-ready`.
- `fp2 watch`, `watch-start` and `watch-stop`: one JSON line per meaningful change (dialogs, construction
  and research, deficits, statistic bands, stock runway, quests, icons, Council phase), with optional
  auto-pause and a detached watcher that appends to `.runtime/watch.jsonl`.
- Keyless `bridge.reload` (`fp2 reload`); `fp2 reload --full` for `main.lua` changes.
- `keybinds` command listing Enhanced Input bindings.
- Install and uninstall scripts for UE4SS and the mod junction (`scripts/`).
- `play-frostpunk2` agent skill with data map, mod development guide, gameplay notes and known gaps.

### Changed

- Cutscene guard: `choose`, `vote`, `propose`, `ability` and `overdrive` refuse during a cutscene, and
  `click`, `rclick` and `hold` refuse unless `--force`.
- The watcher ignores bark icons and does not auto-pause on `stock.recovered`.

### Fixed

- UE4SS crash classes are guarded: FText inside struct parameters, and SoftObject property reads.
- `vote` refuses outside the Council scene, where it locked all game input.

### Known issues

- `fp2 pass-law` does not check for an open session before it starts.
- `population.population` sums unassigned community sizes only and differs from the HUD total.
