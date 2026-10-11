# Known gaps

Ordered by how often play needs them. Remove an entry when a command covers it.

## Not covered yet

- Council / laws: proposing, voting, promises (`PXInstructionUtils.InstructVote/InstructNegotiate`,
  `PXPolicyUtils.GetAllInactivePolicies`, `PXParliamentSubsystem.PredictVote`). See `research/ACTION_CANDIDATES.md`.
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
- Bridge `propose` (RequestSession) desynced the Council UI once (state then unclear: wrong monitor + possible
  cutscene). Disabled pending a clean re-test; propose via UI for now.
- `choose` is untested on a real decision (only tutorial modals seen so far).
- Calendar `week` = floor(ticks/1680); HUD week/day labels can lag the logic tick.
