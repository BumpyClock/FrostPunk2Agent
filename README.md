# FrostPunk2Agent

Lets AI agents play **Frostpunk 2** with exact game data instead of screenshots.

- **`mod/FP2AgentBridge`**: a [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod. Inside the game it
  answers JSON requests over a file bridge. It reflects any UObject and runs curated extractors
  (resources, needs, statistics, construction, quests, map icons, research, council). Its actions
  (districts, frostbreaking, buildings, research, saves) go through the game's own command layer.
- **`cli/`**: `fp2`, a single Bun/TypeScript CLI. It compiles to `fp2.exe` and handles bridge calls,
  triage (`brief`), time control, screenshots of the game window, mouse and keys, and launch/load.
- **`.agents/skills/play-frostpunk2`**: the agent skill. It covers how to play, the data map, how to
  extend the mod, and known gaps and crash hazards.

## Setup (Windows)

```powershell
./scripts/Install-Bridge.ps1 -Download   # game closed; installs UE4SS + links the mod (undo: Uninstall-Bridge.ps1)
cd cli; bun install; bun run build; cd ..
./fp2.exe launch                         # starts the game via Steam, waits for the bridge
./fp2.exe brief
```

The UE4SS runtime is downloaded from its GitHub releases and is not part of this repository.
Tested with Frostpunk 2 (UE 5.4.3) and UE4SS experimental 3.0.1-1164.

## Status

The CLI covers reads, time control, districts, frostbreaking, buildings, research, quests, icons and saves.
The Council is read-only for now; see `references/MOD_GAPS.md`.
Two UE4SS crash classes are guarded: FText inside struct parameters, and SoftObject property reads.
