---
name: fp2-mod-dev
description: Extend the FP2AgentBridge UE4SS mod and the `fp2` CLI when Frostpunk 2 play hits a missing read or action. Covers the detour policy, saves before first calls, retry discipline, editing, subagent limits, build and reload, verification, and the crash classes that kill the game.
---

# Grow the FP2 bridge

Use this skill when play (the `play-frostpunk2` skill) needs a read or action that `fp2` lacks: you read a number
from a screenshot, click through a menu repeatedly, or hit a UI wall. Done means the new command works on the live
game, matches the HUD, and is recorded. Then return to the turn loop.

Mod code: `mod/FP2AgentBridge/Scripts/` (Lua). CLI: `cli/src/` (Bun/TypeScript, builds `fp2.exe`). Layout,
discovery commands and Lua patterns: [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md). Read it before the first
edit. Check [MOD_GAPS.md](references/MOD_GAPS.md) first: the gap may be known, with measured dead ends.

## Who uses this skill

The maintainer, between play sessions. Play agents (the `play-frostpunk2` skill) treat `mod/`, `cli/` and `fp2.exe`
as read-only and log what they lacked in `BRIDGE_FEEDBACK.md` (repo root). Start a bridge session by reading that
file, turning each entry into a command, a doc fix, or a MOD_GAPS.md entry, and deleting it once handled.

## Action path policy

Plug into the entry points the game's own UI uses; never invent a parallel write path.

1. Most UI buttons call `PXInstructionUtils.Instruct*` or a `PX*Utils.Try*` with plain parameters (objects, bools,
   ints, FName) and the Leader ActionOrigin. Measured by hooking them during a UI district expansion: the UI calls
   them natively. Call the same function with the same arguments.
2. Where the UI builds a struct first (any `!text` struct such as `PXVoteBypassData`, `PXDesire`,
   `PXPromiseQuestParameters`; cell or route arrays), call the widget handler that builds it (open the panel, then
   drive the handlers through `liveWidget`, as `utopia_assign` does) so the game constructs the struct. Never build
   an FText struct from a Lua table: it crashes the game (measured).
3. Pixel input (`click`, `hold`, `keys`) only when neither entry point is visible, and only with wait conditions.

Find the entry point from the dumps (`research/fp2_functions.txt`, `research/describe/*.json`: widget classes
`WBP_*`, `PX*Panel`, `PX*Widget`, handlers `Handle*`/`On*Clicked`) and record it in the command's help text.

Never `set` game state, never call `*Immediately`/`instant*`/`PXCheat*`/`TryChange*Stockpile` paths.

## Before the first call of anything new

Run `fp2 save name=agent-<what> override=true` before the first call of a new reflective read, a new action, or a
changed code path. First calls of new reflective reads or actions caused 4 crashes in one session (measured). If
the game dies, `fp2 recover name=agent-<what>`.

## Retry discipline

- After 2 failed reloads or 1 crash on the same gap: save, write what was tried and how it failed to MOD_GAPS.md,
  and change the approach (a different function, a different read path, a property instead of a call).
- Never re-run `fp2 reload` without changing the file. One Lua syntax error was retried 5 times (measured).
- A reload error names the file and line and returns `context`: the failing file's lines around the error. Fix
  from that, not from a guess.

## Editing

- Use the Edit tool, or a Python script file run with `python -I`. Never inline heredocs with escapes. After one
  quoting failure, switch tools instead of retrying the same form.
- Lua files use CRLF line endings.
- After an edit, grep the anchor or run the command that exercises the new branch.
- Never hide `fp2 reload` output (no `| tail`, no `> $null`). A broken reload went unnoticed for minutes (measured).

## Subagents

Subagents on the live game may use only curated commands: `snapshot`, `brief`, `extract`, and the named commands
in `fp2 -h`. Never give them `call`, `object`, `get`, `describe`, `find_all` or `search` on the live game. Run
reflection in the main thread, after a save. Two crashes came from subagents doing reflective calls (measured).
Subagents may read `research/` files and source code freely.

## Build and reload

- The game loads the mod through a directory junction, so Lua edits are live after `fp2 reload`. `reload`
  re-loads every module except `main.lua` and needs no keypress.
- `main.lua` changes need `fp2 reload --full` (UE4SS Ctrl+R). Ctrl+R also opens Research; the CLI closes it.
- CLI: `cd cli; bun run build` (`bun run typecheck` for types). A foreground `fp2 watch` locks `fp2.exe`; stop it
  first. After a build, `watch-stop` then `watch-start` moves a detached watcher to the new build.
- Logs: `mod/FP2AgentBridge/bridge/bridge.log` (command failures), UE4SS.log in the game's `Binaries\Win64\ue4ss`
  (Lua errors), crash context under `%LOCALAPPDATA%\11bitstudios\Frostpunk2\Steam\Saved\Crashes`.

Detail: [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md#reload-build-logs).

## Verify

- Run the new extractor and compare it to the HUD once (one screenshot). Do not ship numbers you have not compared.
- A `true` return proves neither effect nor persistence. Read the state the action should change.
- Record the extractor or field in [DATA_MAP.md](../play-frostpunk2/references/DATA_MAP.md) as measured, update
  the play skill's command table if play needs it, remove the MOD_GAPS.md entry it covers, and add a CHANGELOG line.

## Safety

- Crash classes (measured): FText inside struct or container params, SoftObject reads, null or stale UObjects,
  guessed world-context arguments, Lua strings for FName params, `reflect.plain` on asset containers. `pcall` does
  not catch them. Read [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md#crash-hazards-measured) before calling
  anything new. Never pass `unsafe=true`.
- No cheats: no `TryChange*Stockpile`, no `PXCheat*`, no `set` on game state. New actions go through the game's
  validated paths (`Instruct*`, `Try*`/`Can*` with the Leader ActionOrigin), charge normal costs, and get
  `mutation = true`, a `dryRun` path, and `A.assertNoCutscene` where they involve choices or the Council.
- Never overwrite or delete the user's saves. Use `override=true` only on agent-named slots.

## References

- [MOD_DEVELOPMENT.md](references/MOD_DEVELOPMENT.md): layout, discovery commands, Lua patterns, crash hazards.
- [MOD_GAPS.md](references/MOD_GAPS.md): known missing features, measured dead ends, Council and save caveats.
- `research/fp2_functions.txt`: reflected UFunctions with params (`!text` marks FText). Search it before `describe`.
- `research/ACTION_CANDIDATES.md`: candidate game functions for new actions.
