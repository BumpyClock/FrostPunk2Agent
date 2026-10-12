# Learnings

Running log of what play and bridge work taught us. Newest first within each section. Each line: what happened,
label (measured / inferred / guessed), and what to do differently. Durable rules move into the skills
(`.claude/skills/play-frostpunk2`, `.claude/skills/fp2-mod-dev`); this file keeps the trail.

## Gameplay

- 2026-10-11, wk 327-341: I called a Warmth deficit (-70, later -130) harmless because no district showed a bad heat
  level and Cold read 0. At wk 341 Cold reached 16 (target 14) and 54 people died of cold at temperature level 2
  (measured). A Warmth deficit raises Cold with a lag; treat it as a death risk. Auto heat allocation left 36 heat
  batches unused while Warmth was short; turning auto off and setting housing heat one level above need moved
  Warmth -110 -> +60 at 54% generator load (measured). `heat_adjust adjustment=N` sets the level to N, not +N
  (measured: Housing#9 went 2 -> 1).
- 2026-10-11, wk 300-327: a Hard expedition (Kneeache Climbs, 25 teams, 25 weeks) killed 272 people ("272 died
  during exploration", toll 148 -> 420, measured) and revealed no site that `frost_sites` lists; Cores stayed 0.
  Nothing I read before sending it mentioned a death risk; I treated difficulty as time and team cost only. Treat
  Hard territory as a human cost, and ask what else gives the resource first (Utopia nodes, research, trade).
- wk 308-325: `pick_cells deposit=X` and the `cells` listing ignore deposit amounts: a wood district (150
  prefabs, 4 weeks) landed on four empty deposits, and the soil pick was also empty (measured). Before placing a
  resource district, match `extract name=deposits` amounts to the cells.
- 2026-10-11, wk 300-304: `change` for prefabs and heatstamps is per WEEK, for coal, food and materials per DAY
  (measured: prefabs 97 -> 120 in one week at "+23"; coal 68.7K -> 80.8K in 3 weeks at "+576"). Prefabs were the
  real bottleneck for every build plan; I had planned at 7x the true rate. Switching Production#10 from goods to
  prefabs took prefabs +10 -> +23/wk and Possession -69 -> -109 (measured).
- wk 304: the sawmill's wood ran out and materials went -8 -> -515/day (measured). The `deposit.depleting` warnings
  started at 20 weeks; I queued the replacement behind food and prefabs. With prefabs at +23/wk, a 190-prefab
  replacement needs 8+ weeks of lead: start it at the 20-week warning.
- 2026-10-11, wk 264-277: Housing districts hold one building; the promised hospital needed a new Housing district
  (200 prefabs, 4 wk) because `expand_district` silently did nothing (measured). Promise kept at wk 270: "Trust rises".
  Heat Utilisation research cut generator load (97.5% at the level-3 drop -> 82% after it plus the second mine; mixed,
  inferred). Production#2 on prefabs gave +2 prefabs/day for 100 heat, 40 coal and 100 materials (measured): an
  old district can be a net loss; measure before keeping it on.
- wk 265: a Blasting Coal Mine drains a 96K tiny deposit in ~30 weeks (62K left at wk 265, 9 weeks left at wk 276,
  measured). Each mine buys months, not years; plan the next coal source when the current one hits 20 weeks.
- 2026-10-11, wk 253-254: coal crisis. Extraction#8 depleted wk 252; its replacement Extraction#17 (96K coal, frostbroken
  to cell 383) gave the same supply 162/day, so net stayed -114 (measured). Coal users measured by toggling while
  paused: Production#10 (goods) 36/day + 100 materials, Production#6 (prefabs) 24/day; Emergency Shifts on a coal
  district +40 supply (measured). A replacement district only holds the line: start the next coal source before the
  old one is under 10 weeks. Check `building_types district=Extraction` for already-unlocked boosters
  (Blasting Coal Mine +210, 40 prefabs, no Core) before planning research (measured: Coal Mines was researched and unused).
- wk 254: Deep Melting Drill needs 1 Core; with 0 Cores the deep coal plan was dead on arrival (measured). Read a
  building's full cost (`place_building dryRun=true`) before committing research to it.
- wk 248: Biowaste Hothouse took food -100 -> +22/day; Housing Block in Production#6 took Shelter -19 -> -11 (measured).

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

- 2026-10-11: `propose` run through the bridge while the Council hub UI was on its lobby moved the phase to Negotiations
  and left the UI behind; a later click on "PROPOSE A LAW" crashed the game in UI rendering (measured, no Lua frames).
  The UI must be in step with bridge-driven state: `propose` now refuses at the lobby and `council_ui` steps drive the
  panels' own events (measured: LAW PASSED 55 For / 51 required, UI in sync).
- 2026-10-11: a save written inside the Council scene did not load; the game stayed at the main menu (measured). Save
  before opening the Council. `save` warns.
- 2026-10-11: `recover` loaded a save during the startup shader compile; the load destroyed `BP_ShaderCompilerActor_C`
  and the loading screen stayed on "COMPILING SHADERS N/743" with input blocked (measured twice). Calling
  `OnShaderCompilationFinished` on the widget, then Space, cleared it. `fp2 unstick` automates that and `recover`
  now waits for the compiler actor to go.
- 2026-10-11: `PXDesireUtils.AbandonPromise` crashed the game with a valid `PXPromiseQuest` (Wwise
  `AK::WriteBytesMem::SetCount` <- `FAnsiString::operator=` stack, measured). `PXQuestUtils.FinishQuest(quest, false)`
  works instead (default `path=quest`). A declared-class check did not prevent the crash. Test a new static call once,
  after a save.
- 2026-10-11: `colony_exchange` v1 (static `PXStockpileExchangeUtils` tier getters, out-param reads) crashed with the
  same Wwise stack (measured). It now reads unrest and the component count only. Treat that stack as a bad static
  Utils call, not an audio fault (inferred).
- 2026-10-11: `PXCityUtils.TransferCommunity` moved 100 people between cities instantly with no unit and no cost
  (measured): a cheat path, removed. `transfer_people` uses `AssignUnitToRelocateCommunityOrder` with a
  `RelocateCommunityUnit` (source -100 at once, target +0 until arrival, measured). Run every new mutation once with
  a before/after stock read; a free instant result means a bypass.
- 2026-10-11: the Council handler chain works from Lua: the widgets' own bound button events (lobby ExploreLaws,
  policy entry Propose, Negotiate, group choice, side, term, Accept, Vote) drove a full negotiated vote with the UI in
  sync (measured). Pixel clicks on the lobby did nothing. Prefer a widget's own event to a pixel click or a direct
  Instruct call when a UI panel is open.
- 2026-10-11: the CLI daemon did not cut latency (measured: `date` 114-131 ms through it, 112-149 ms direct). The gains
  came from lazy FFI loading and `fs.watch` on the bridge folder: `date` 151-179 -> 112-149 ms, `snapshot` 220-268 ->
  184-212 ms, `brief` 355-407 -> 267-305 ms. Floor: about 55 ms exe start, 40 ms exit, 35-45 ms per bridge call.
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