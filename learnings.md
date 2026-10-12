# Learnings

Running log of what play and bridge work taught us. Newest first within each section. Each line: what happened,
label (measured / inferred / guessed), and what to do differently. Durable rules move into the skills
(`.claude/skills/play-frostpunk2`, `.claude/skills/fp2-mod-dev`); this file keeps the trail.

## Gameplay

- 2026-10-11, wk 232: research was idle (`anyInProgress` false) for an unknown number of weeks after the whiteout,
  and no alert said so (measured). Check `fp2 research` at every re-plan; a CLI alert is being added.
- wk 232: Housing Block refused in all three housing districts with 257 prefabs and 2,464 heatstamps in stock
  (measured). Likely no free slot (guessed). The bridge does not yet give the reason.
- 2026-10-11, wk 226: food stock 702 at -48/day (2.1 wk) while the whiteout ends in 3.9 wk. The shed-food decision
  at wk 201 cost ~200 food/day for 25 weeks (measured). Budget food for the full whiteout length before shedding a
  food district, not just fuel.
- Whiteout (wk 201-230): warned ~70 weeks ahead by a story dialog and the forecast strip (measured). Noting it as an
  undated short goal and returning to colonies/factories cost ~40 lives (measured). Threats become `horizon=threat
  priority=1 due=<arrival>` goals with dated prep checks.
- Shedding heated non-essential districts took Heating -750 -> 0 and the Cold target 50 -> 7 (measured). Overdrive
  lowers Heating demand but not the Cold target, and wear spikes fast in a whiteout (measured).
- A Heating Hub cuts Heating need ~60 but draws ~60 power: net zero when the generator is maxed (measured).
- Coal stock sat at its 50,000 cap before the whiteout ("surplus wasted"): the cap, not production, set the reserve
  (measured).
- `E_Woodworks_Dominion` is limited per city; it became placeable only after the depleted one was deconstructed
  (measured). Do not cancel research to "fix" a missing building before checking limits.
- Migration law looked useless at first, then brought +200 and +1,191 (measured). Judge actions after their lead
  time.
- A child-labour law was passed believing it was something else (measured). Always read law name, text and effects.

## Bridge and CLI

- 2026-10-11, wk 232: `fp2 ability owner=Production#10 id=Toggle_IndustrialPrefabsProduction active=true` switched
  the district to Goods (`Toggle_IndustrialGoodsProduction` active=true afterwards). With both toggles false,
  Production#6 made prefabs (+10/day) (measured). Read the toggles back and measure `change` after switching.
  Goods are consumed as fast as they are made: stock and `change` stay 0, and only the Possession need moves
  (-89 -> -49) (measured).
- 2026-10-11: `fp2 ability ... dryRun=true` ignored `dryRun` and activated Emergency Shifts on Food_Supply#3
  (measured). Fixed in `A.setAbility`. Before relying on `dryRun` for a command, check it has a dryRun path.
- `turn` overshot `weeks` at speed 3 (3.4 in-game weeks per real second, 1.5 s poll). Fixed with clock-rate pacing
  (measured).
- Repeated "UserPaused": story events set the pause flag before their dialog shows. `turn` resumes once (measured).
- Polling the bridge during a level load crashed the game (Wwise). `recover` holds calls ~90 s after a load
  (measured).
- Crash classes `pcall` does not catch: FText in struct/container params, SoftObject reads, null/stale UObjects,
  guessed world-context args, Lua strings for FName params (measured). Save before any first call.
- Hiding `fp2 reload` output let a Lua syntax error go unnoticed (measured). Never hide reload output.
- 2026-10-11: added `research.idle` event (stops the turn, `brief` alert) and a `check` block on `place_building` dryRun/refusal (slots used/limit, free-slot districts, workforce, stock shortfall). `X_HousingBloc_Base` refusals in Housing#1/#4/#9 were full slots: limit 1, 1 used (measured). The limit varies by district; what raises it is unknown.

## Process

- Event-driven play (~170 wakeups reacting) neglected quests (measured). Plan from the goal stack; waiting is a move.
- Expanding while people froze and food fell (measured). Run the stability check before any growth commitment.
