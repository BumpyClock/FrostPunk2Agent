# Known gaps

Ordered by how often play needs them. Remove an entry when a command covers it.

## Not covered yet

- Council negotiation and promises (`InstructNegotiate`, `PXDesireUtils.MakePromise`). Proposing/voting work.
- Utopia Tree node unlocks: no reflected command path (only UI widget handlers).
- Faction/community trust and standing extractor (`PXTrustSubsystem`, `PXCommunityComponent` modifiers).
- Total population (HUD number); `population` sums unassigned community sizes only.
- Frostland: expeditions, outposts, colonies, trails (`InstructStartTerritoryExploration`, `InstructConstructOutpost`, `BuildTrail`).
- Generator modes/overdrive, heat allocation (`SetGeneratorOverdriveActive`, `PXHeatManagementUtils`).
- District/city abilities (martial law, etc.): `PXAbilityUtils.ActivateActorAbility`.
- Logistics district placement needs a Logistics deposit inside the build area (frostbreak toward it first).
- Area expander / construction cost checks return FText structs → blocked by the crash guard; the
  `expand` command executes anyway and the game validates (returns `ok`).

## Caveats

- `save name=X`: the game writes a new incrementing file (`FrostPunk2SaveGame.sav`, `...1.sav`, ...), never
  overwrites, and only flushes after a game tick (`fp2 advance ticks=10`). Load by the name you passed
  (`fp2 load name=X`); `DoesSaveGameExists` resolves display names, not file names.
- `vote` (InstructVote) **works inside the Council scene** after a proposal (measured 2026-10-11: UI went to
  "Law passed", one Escape returned to the city, policy active). **Outside the scene it locked all game input**
  (only a reload recovered); the command refuses unless `IsInParliament` and no cutscene is playing.
- Bridge `propose` (RequestSession) + `vote` inside the Council passed a law with the UI following (measured,
  saved before the test). An earlier attempt outside those conditions desynced the UI, so both refuse unless
  `IsInParliament` and no cutscene. `fp2 pass-law` wraps the flow.
- `choose` is untested on a real decision (only tutorial modals seen so far).
- Calendar `week` = floor(ticks/1680); HUD week/day labels can lag the logic tick.
