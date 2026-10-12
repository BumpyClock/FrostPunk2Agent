# Frostpunk 2 mechanics

The rules an agent needs to hold a model of the whole game loop, by system. [GAMEPLAY.md](GAMEPLAY.md) holds
play-tested procedures (whiteout playbook, stability check). [DATA_MAP.md](DATA_MAP.md) holds fields and ids. This
file holds the rules behind them.

## Labels and trust order

- **measured**: read from the bridge or HUD in this repo's play (today's session or earlier ones). Wins over every
  other label.
- **source**: from a web guide or wiki. The URL appears once per section. Treat as a prior and check against the
  bridge before building on it.
- **unverified**: a single anecdote, an inference from names, a conflicting source, or an untested bridge path.
- **1.3+**: a rule changed by patch 1.3 (2025-05-08, heating overhaul) or later (1.4: 2025-09-18). Most web guides
  predate it. Game version at research time: 1.6.1, both DLCs (Fractured Utopias 1.5, Breach of Trust 1.6).

Stale-guide traps (pre-1.3 claims that no longer hold, or never matched):

| Old claim | Now |
|---|---|
| One global heat demand; Housing 40, Central 70 heat | Per-district temperature levels plus heat allocation (section 3) |
| Heating Hub gives +40 heat; "3-cell" adjacency rule | Hub warms neighbours within 2 cells; adjacency counts per single cell |
| Depot building raises a stock cap by 30,000 | Hub districts raise it by 50,000 (measured, section 1) |
| Frostbreak cost charged per use | Charged per cell |
| Prologue and early whiteout "30 to 40 weeks" | Measured 29 weeks (section 9) |
| Logistics District gives 20 teams | Measured 15 per active district |

## 1. Resources and stockpiles

Source: https://frostpunk-2.game-vault.net/wiki/Resources

| Class | Members | Rule |
|---|---|---|
| Global | Heatstamps, Prefabs, Cores | Shared by city and colonies. No stock cap (source). Heatstamps arrive weekly (source) |
| Stockpiled, per city | Coal, Oil, Food, Materials, Goods | Per-city cap. Produced and consumed daily (source). Moved between city and colony in batches (section 8) |
| Fixed supply | Workforce, Heat, Steam, Shelter, Guard Squads, Frostland Teams | Supplied up to a limit, never stockpiled. Teams are global (source) |

- Order of fulfilment: workforce requirements first, then other demands, from production, then stockpile
  (source). Stock empty: districts may shut down and the matching statistic rises (source).
- Surplus at cap is lost. The HUD raises a "surplus wasted" alert. Measured: coal sat at the 50,000 limit for weeks
  before a whiteout, so the cap and not production set the fuel reserve. A source says drain from deposits is also
  throttled at cap. Unverified.
- **Cap raisers are hub districts** (measured). `FuelDepotHub` (+50,000 coal and oil), `MaterialsDepotHub`,
  `GoodsDepotHub` and `FoodDepotHub` (+50,000 each) cost 80 Heatstamps and 50 Prefabs, take 2 weeks and 100
  workforce. The source describes "Depot" buildings at +30,000 and 150 Heatstamps: stale, trust the measured values.
  Other raisers (source): outpost "Outpost 11" +30,000 to all caps, settlements +60,000 and +100,000, a 1.4 research
  for hub capacity. Colonies cap at 30,000 (source, patch 1.1.0). The base city cap is not documented anywhere:
  read `resources.limits`.
- Heatstamps (source): about 1 per 1,000 population per week, scaled by Goods consumption. Unmet Goods demand cuts
  income. Law research costs none. Measured start of a Utopia Builder (Citizen): 8,000 people, 4,800 workforce (60 %,
  so workforce is a fixed share of population), 450 Heatstamps, 1,500 Prefabs, 40,000 Materials, 50,000 Food, 15,000
  Coal.
- Per 1,000 people (source or inferred, unverified): Shelter 10, Food about 20 per day, Goods about 10 per day. One
  Food District (60 per day) feeds about 3,000 people. Everything else is district upkeep.
- Materials (source): upkeep of nearly every district, not construction. Housing needs none. About 50 per day per
  non-housing district. A deficit raises Squalor. Industry uses Materials to make Goods or Prefabs, so a Materials
  outage also stops prefabs (measured, GAMEPLAY).
- Prefabs and Cores: Prefabs come from Industrial districts set to Prefabs, prefab deposits and caches. Cores come
  only from Frostland expeditions (source). Both gate districts, upgrades and colonies.
- Tip (source): hold more than three quarters of every stock as buffer.

## 2. Needs and problems

Source: https://frostpunk-2.game-vault.net/wiki/Problems and
https://www.noobfeed.com/articles/frostpunk-2-all-problems%2C-trust-%26-tension-and-how-to-solve-them

Need ids (measured): `Shelter`, `Warmth`, `Heating`, `Nourishment`, `Possession`, `Maintenance`. A negative
balance raises the matching statistic; the statistic's `current` value drifts toward its `target` on a 0 to 100 scale
(measured).

| Problem (statistic) | Driven by | Effects when high | Counters |
|---|---|---|---|
| Cold | Shelter deficit (fast), Heating or Warmth deficit, homeless, fuel out, whiteout | Disease, Tension, deaths, less growth. Since 1.3: absentees and efficiency loss in cold districts | More housing, fuel, allocation, insulation, hubs. No building removes it directly |
| Hunger | Food deficit | Disease, Tension, starvation deaths that cut Trust | Food districts, hothouses, Food laws, Emergency Shifts (cost Tension and Disease) |
| Squalor | Materials deficit, Progress buildings and oil-burning generator, Housing next to Industrial, Extraction or Logistics | Disease, Tension, events that damage districts (Wear, then district off) | Materials supply, Filtration or Ventilation Towers, waste buildings, switch dirty buildings off |
| Disease (`Sickliness`) | Adaptation buildings, Food next to Industrial or Extraction, high Cold, Hunger or Squalor, Emergency Shifts | Sick workers become absent, Tension | Hospitals, Pharmaceutical Lab, treatment laws. Since 1.4 Warm districts cure people |
| Crime | Goods deficit, large population, events | Tension, slower growth, citizens join factions | Meet Goods demand, Watchtowers, Prisons, Guard laws |
| Tension | Any other problem, protests, Fervor, unpopular laws, failed votes | Maximum Tension ends the run, after a last-chance prompt | Keep problems low |

- Level names run Absent, then rising steps, to Catastrophic, with a trend (Diminishing, Stable, Increasing)
  (source). A step name "Overwhelming" appears in Utopia text (source). Exact thresholds are unknown: use
  `statistics` numbers and the `stat.rising` event, which fires per 10-point band (measured).
- Catastrophic triggers a drastic event (source).
- Measured deaths: 18 died in one wave at Cold 10. Waves recurred about every 11 weeks (58 per wave) while Shelter
  was in deficit. A whiteout put the Cold target at 50 and killed 40 in the first wave.
- Problems do not hit Trust or Tension directly. They fire events and uprisings that move those two (source).
  Deaths since 1.3 tie to the communities they come from (source).
- Trust falls with unkept promises, deaths, starvation, a generator turned off, rushed research (source).
- Quick fixes by shortage (source: https://game8.co/games/Frostpunk-2/archives/474390): Shelter, build or expand
  Housing. Food, Food district or harvest site. Goods, switch an Industrial district to Goods. Prefabs, switch to
  Prefabs. Cores, expeditions. Workforce, drop efficiency elsewhere or change labour laws.

## 3. Heat since patch 1.3

Source: https://www.thegamer.com/frostpunk-2-heating-city-methods-tips/ ,
https://www.neoseeker.com/frostpunk-2/tech/Heating , https://gamingbolt.com/frostpunk-2-update-adds-new-sandbox-map-overhauls-heating-serenity-mode-and-more

**Model (1.3+).** Each district has its own temperature level: Freezing, Very Cold, Cold, Chilly, Livable, Warm
(source; HUD names measured). The bridge reads the level as an asset id such as `HeatLevel_5_Livable`, and
`HeatLevel_0_NotActive` for a switched-off district (measured). The ordinal in the id suggests an order; the position
of Warm is unverified. A district's level is the sum of: weather baseline, heat allocated from the generator,
adjacency (generator, Warm neighbours), terrain, insulation, hubs, laws and the district type's own value (source).

| Lever | Rule | Label |
|---|---|---|
| Allocation | Each allocated level costs 30 heat; 25 with the Heat Utilisation idea | source (Neoseeker, Jul 2025) |
| Allocation cap | 5 levels per district; 1.4 cut the Prologue cap to 3; Progress generator upgrades add levels | source |
| Unallocated heat | `fp2 heat` shows `unallocatedHeatBatches` above 0 with `autoAllocate:false`: run `fp2 heat_distribute`. A -30 Heating deficit cleared (fulfilled 210 to 240 of 240) | measured |
| Auto-allocation | `fp2 heat_auto active=true` cleared a -240 deficit after a temperature drop while coal throughput held. In the game it needs the Heat Allocation Automation research and keeps districts at Livable, not Warm | measured (effect), source (research) |
| Idle districts | Switched-off districts still count toward the Heating requirement, so `heat_adjust` on them does not cut demand | measured |
| Insulation | "Insulate District" costs 50 Prefabs and 50 Heatstamps and adds +1 level (source). Insulating one housing district changed nothing in 2 weeks of whiteout demand | measured (cost, null result) |
| Heating Hub | Single tile, warms neighbours within 2 cells, 5 weeks to build. In a whiteout it cut Heating need by 60 but drew 60 power. About 50 Prefabs to build (unverified) | measured |
| Heat Dispatcher | +1, +2, +3 level by tier, 200 to 400 workforce | source |
| Radiating warmth | A Warm district gives +1/4 level per adjacent tile to neighbours, capped at +9/4; chains can self-sustain | source (partly anecdote) |
| Generator adjacency | Housing next to the generator ring gets +1 temperature. City Support "Housing" ability gives +1 level in Housing districts: Heating -150 to -60 in a cold snap | measured |
| Efficiency and switching off | Lowering efficiency lowers heat need and output. Switching off every heated non-essential district took Heating from -750 to 0 and the Cold target from 50 to 7 | measured |

**Generator.** In the Central District (source). Check `fp2 generator`: `power`, `powerLimit`, `capacityPct`,
`overdriveSupported`, `canOverdrive`. If `power` equals `powerLimit`, distribution cannot help.

- Capacity tiers (source): Generator Capacity (50 Heatstamps), Improved (100), Advanced (200); each has an
  Adaptation or a Progress variant. Colony furnaces cap at 3,000 (source). City tier values are not documented.
  Measured: `powerLimit` 750 on one save; the Symbiosis Lvl1 upgrade building kept 750 and added City Support
  abilities (Food Production about +8 food per day, Housing, Heavy Industry).
- Fuel path (source): Upgrade I is a permanent choice. Adaptation (Adaptive Pumps) burns coal, oil or steam. Progress
  (Oil Pumps) burns oil only, adds allocation levels and emits Squalor. Upgrade II: Adaptation gets Intake
  Optimisation; Progress gets Surplus Injectors (4 Cores). Base ratios (pre-1.3, unverified): coal 1 heat per unit,
  steam 1:1, oil 2:1 (Adaptive) or 5:1 (Oil Pumps). Steam cannot be stockpiled.
- Measured burn: coal fell 300 per day with both mines off in a whiteout (runway 5 to 6 weeks).
- Turning the generator off costs Trust (source).

**Overdrive.**

- Source: about +35 % heat, "safe up to 60 %" on the wear gauge, 30 weeks maximum, off when unstable.
- Measured: wear rose +0.14 per 6 game-hours, fell to 0 within a day once off, and reached 0.7 to 0.8 within one poll
  at whiteout demand. 1.0 is a malfunction with casualties. Overdrive lowered the Heating requirement but did not
  move the Cold target. Do not read the 60 % figure as a safe steady state: use `fp2 overdrive-cycle`.
- Wear formula and accident threshold are undocumented.

## 4. Districts and buildings

Source: https://frostpunk-2.game-vault.net/wiki/Districts . Costs differ between wiki pages: read live costs.

| District | Placement | Output (source) | Notes |
|---|---|---|---|
| Central | Unique | Shelter 90, Food 20, Goods 15, Guard Squads 12, holds the generator | Council Hall goes here |
| Housing | Anywhere | Shelter 20 | Measured cost 40 Heatstamps, 200 Prefabs, 200 workforce while building |
| Food | Fertile Soil | Food 60 (80 expanded) | Hothouses add food (source) |
| Extraction | On a matching deposit | Coal 120 to 150, or Materials 150 to 190 | Measured: 150 Prefabs to build |
| Industrial | Anywhere | Goods 20 (30) or Prefabs, switched by ability | `Toggle_IndustrialGoodsProduction` and `Toggle_IndustrialPrefabsProduction` (measured) |
| Logistics | Old Waystation, or a Logistics deposit | Frostland Teams | 15 per active district (measured); 400 workforce, 40 Heatstamps, 200 Prefabs to build (source) |

- Placement (measured): a district needs 6 adjacent hex cells. Frozen cells must be frostbroken first. Cells flagged
  Outside are buildable. Extraction and Logistics must start on a matching deposit.
- Frostbreaking (source: https://frostpunk-2.game-vault.net/wiki/Frostbreaking ): up to 8 contiguous cells, 4
  Heatstamps and 25 workforce per cell, 2 weeks regardless of cell count. Workforce is returned, Heatstamps are spent.
  1.3+: cost counts per cell. Other guides quote 30 Heatstamps and 200 workforce for 8 cells.
- **Adjacency (1.3+).** Effects apply per adjacent cell, not per 3 cells (source). Negative: Housing next to
  Industrial, Extraction or Logistics adds Squalor (measured: districts next to Housing add Squalor). Food next to
  those adds Disease (source). Positive: Industrial bordering Extraction lowers Materials use, and shares workers
  (source). A depleted Extraction district drops the adjacency of its neighbours (source, anecdote).
- **Expansion.** Extraction expansion adds 3 cells, costs 50 Prefabs and 50 Heatstamps, takes 2 weeks, and upgrades
  the type. A new deposit cell joins at once and output resumes before the upgrade ends (measured: Materials went
  from -345 to +210 per day). Expansion has one level for most districts (measured for Extraction; source for the
  rest). A guide says Housing expands twice: unverified, conflicts with a 1.3 note that removed a third tier.
  Output rises while workforce and Materials upkeep stay the same (source).
- **Efficiency.** `fp2 districts` shows `efficiencyPct`. A slider lowers workforce need, heat and output together
  (source). Switching off (`district_active`) frees the workforce at once (measured). A district OFF loses adjacency
  bonuses (source): lower efficiency instead when adjacency matters.
- **Deposits run out** (measured). An exhausted Extraction district goes inactive with reason `NoDeposit` and its
  supply falls to 0 without a `need.deficit` first. Extraction output does not scale with the number of deposit
  cells covered; cells set only the deposit's lifetime (source). Fix: expand onto a fresh deposit, or deconstruct for a
  refund (measured: 158 Prefabs and 75 Heatstamps over 3 weeks for a depleted district).
- **Building slots** (measured): Housing districts had a limit of 1 building, 1 used. The limit varies per district;
  what raises it is unknown. Buildings add their own heat and materials need (source).
- **Hubs** (source): single-tile buildings or districts. Heating Hub, Maintenance Hub (cuts Materials demand of
  neighbours), Rail Hub, Air Transport Hub, resource Depot hubs (section 1).
- **Logistics.** Needs a Logistics deposit or an Old Waystation at the map edge (source; measured nearest was about
  29k units away on one start). The first one unlocks the Frostland. A deactivated Logistics district supplies 0
  teams (measured). Logistics Bays add teams (section 8).

## 5. Society and Council

Source: https://www.gamerguides.com/frostpunk-2/guide/communities-and-factions ,
https://www.ludo.guide/guide/frostpunk-2/communities-and-factions/overview/communities-and-factions-explained ,
https://www.pcgamesn.com/frostpunk-2/council

### Groups and axes

- Three axes of six values (source): Adaptation or Progress, Equality or Merit, Tradition or Reason. Hovering a
  decision shows which values it matches.
- **Communities** hold a view on one axis, are larger and easier to negotiate with. **Factions** hold all three,
  are firm, and split off communities. Both hold Council seats in proportion to population (source). 1.3+: every
  group can hold its own district.
- Story roster (source): Frostlanders (Adaptation), New Londoners (Progress), then Stalwarts, Faithkeepers,
  Pilgrims, Evolvers by Prologue choice. The Prologue choice is permanent and sets the Chapter 5 war pair.
  Sources disagree on Faithkeeper and Evolver cornerstones: read them in game.
- Utopia Builder roster (source): six lesser factions at start (Labourers Equality, Merchants Merit, Foragers
  Adaptation, Machinists Progress, Thinkers Reason, Lords Tradition), then eight Utopia factions (section 7).
  Measured: the Merchants community appears under the type id `Competition` in `fp2 factions`.
- Enacting a Cornerstone gives +2 Fervor to the faction opposed to its affinity (source, patch 1.1.0).

### Relation tiers (standing)

Seven tiers, worst to best in HUD order (source): Hostile, Opposing, Skeptical, Neutral, Favourable, Supporting,
Devoted. The bridge `standing` is a number; the tier name comes from `fp2 factions detail=tiers`.

| Tier | Measured standing | Notes |
|---|---|---|
| Hostile | -0.5 | |
| Opposing | -0.3 | |
| Skeptical | not seen | |
| Neutral | 0 and 0.1 | Minimum target |
| Favourable | 0.2 | Community actions need Favourable or above (source) |
| Supporting, Devoted | not seen | |

Boundaries between tiers are unmeasured. The standing scale beyond -0.5 to 0.3 is unmeasured. Treat Skeptical, Opposing
and Hostile as "act now" (unverified, inferred from guide advice).

### Trust (city-wide)

- Aggregate of group relations weighted by size (source). The bridge `totalTrust` runs 0 to 1; the source HUD runs 0
  to 100.
- Tiers, worst to best (source: noobfeed): Despised, Tolerated, Accepted, Respected, Revered. A second source writes
  "Reviled" for the bottom tier: unverified. Measured: `trustTier` Accepted at `totalTrust` 0.6.
- At the bottom tier a time-limited ultimatum asks to raise trust to 25 %; failure ends the run (source). The
  Chapter 3 objective needs Accepted or better (source). Measured: trust 0.562, tension 21 at week 247 of one save.

### Fervor

Per group, 0 to 3 (measured range). Serenity Mode (1.3+) removes Fervor (source).

| Fervor | State (source) | Counter |
|---|---|---|
| 0 | Satisfied | |
| 1 | Protest: propaganda, districts shut down; negotiation still possible | Meet demand, fund, grant agenda |
| 2 | Riot: injuries and deaths; negotiation impossible until suppressed or demands met | Promote (-1 Fervor), deradicalize via a Favourable community, guards |
| 3 | Civil war: districts at war stop and degrade | Guards per district (12 protect buildings, 24 bystanders, 36 end fighting; one guide says 18), Rule laws |

Measured: the bridge reported Fervor 2 as `fervorTier` Weak. That label does not match "Riot", so treat the source
state names as unverified and the tiers `None, Weak, ...` as the bridge vocabulary. Fervor rises on refused demands,
decisions against a group, ignoring it, and opposing Cornerstones. Riots cannot start in the Story before Chapter 3
(source). A Rally is high Fervor with good relations: it raises Tension briefly (source).

### Community actions

`fp2 community_actions community=<type>` lists them; `fp2 community_action ... dryRun=true` checks first.

| Id (measured) | Likely meaning (unverified, from names and web) | Measured result |
|---|---|---|
| `FundProjects_CA` | Gift Heatstamps for standing | On Merchants: Heatstamps 2455 to 2301 (-154), standing 0.2 to 0.3, cooldown 20 weeks (33,600 ticks per community), second call refused |
| `RequestFunds_CA`, `DemandFunds_CA` | Favours: collect Heatstamps (lowers relations) or seize with guards (large drop) | not run |
| `GoodRelations_Deradicalisation_CA` | Deradicalize a faction: needs Favourable or above, drops Fervor one level, hurts relations with parent and target, about 50 weeks apart (source) | not run |
| `Negotiate_CA`, `FactionSession_CA` | Council negotiation, grant the faction the next agenda slot | not run |
| `HeatHomes_CA` | A community special action | not run |

Source actions with no id seen yet: Promote (more seats, Fervor -1, can stop a riot), Condemn, Round-Up (needs a
Prison, arrests up to 500 members, never at severe Tension). Only the Fund cost is measured: read costs with
`dryRun`. The cooldown reader returns the end time, so subtract the current week (measured).

### Council

- **Unlock** (source): Council Hall in the Central District, needs a Research Institute. First act is a vote of
  confidence.
- **Cadence** (measured): `council.phase` 1 is the Agenda phase. `minTicksToNextSession` of 16,800 ticks (10 weeks)
  with phase 1 means a session is available; the recess length is config. After `propose`, phase 2 is Negotiations.
  One law per session, then about 10 weeks of recess. Failed laws can return (source).
- **Votes** (measured): 100 seats. `requiredVotes` 51 for a normal law; `vote_predict Food_Chaos` showed For 33,
  Against 38, Hesitant 29. Rule laws need two thirds, 67 (source; one source says 70, unverified in play).
- **Laws.** Four categories: Survival, City, Society, Rule (source). Use the list from `fp2 laws` (proposable now),
  not `laws all=true` (measured). Law research costs no Heatstamps (source). A law can be swapped later.
- **Negotiate** (source): pick a group and a side, then one of about three random terms (enact a law, research an
  idea, build or remove a building, a community action). A timer starts. Meeting it raises trust. Missing it or
  reverting it (including demolish then rebuild) drops relations and can fire an event months later. An active
  promise can block new negotiation with that group.
- Not every story ask is a promise (measured): the "Unfair Stigma" hospital-in-40-weeks is a quest, and
  `factions.hasPromises` stayed false.
- **Sway** (the bridge `sway` command, unverified mapping to the source "Pressure delegates"): adds votes, hurts
  relations with every faction.
- **Rule laws** (source): Guided Voting (hesitant delegates vote your way), Guard Enforcers, Secret Police (removes
  rivals' seats), Bureau of Propaganda, Captain's Authority (all 100 delegates vote as you want; needs all other Rule
  laws, unlocked near civil war).
- **UI hazard** (measured): `propose` through the bridge while the Council hub still showed its lobby left the UI out
  of sync, and a later click crashed the game. Get the hub UI past the lobby first; prefer hub handlers.
- Early law order from guides (source, unverified): Guided Voting, then Guard Enforcers; Paid Essentials; Heat
  Recycling; Food Additives; Durable Goods. Match the law to the worst current problem: each vote costs 10 weeks.

## 6. Research

Source: https://www.pcgamesn.com/frostpunk-2/tips , https://www.gameskinny.com/tips/frostpunk-2-best-research/

- **One idea at a time** (source). `fp2 research` shows `speed` 0 without a Research Institute (measured), and
  `research.idle` fires when nothing runs (measured: it sat idle for weeks unflagged).
- **Institute** (source): 400 workforce, 100 Heatstamps, 50 Prefabs, built in a Housing district, which needs an
  expanded Housing district. More institutes help with diminishing returns. Speed also comes from the Mandatory
  School law and a rush ability that costs Trust.
- **Cost** (source, unverified): about 50, 100 or 200 Heatstamps per idea tier; law ideas are free.
- **Variants** (source): factions offer competing ideas for the same problem. Adopting one pleases its proposer and
  upsets rivals. In the bridge, `fp2 research_start topic=<id> community=<type>` picks the proposer. Compare the
  variants' effects before choosing, not only the proposer.
- **Drawers** (source): Heating, Resources, Frostland, City, Society, Hubs. Cornerstone bars fill as you adopt one
  side's ideas and grant a Cornerstone ability.
- Early priorities (source, unverified): Asbestos Lining and Crop Selection (cut Housing and Food heat need),
  Housing Insulation, a coal mine idea, Factory, Waste Heat Conversion, Logistics Bays, then Hothouses and
  Hospitals.

## 7. Utopia Builder

Source: https://game8.co/games/Frostpunk-2/archives/474499 ,
https://primagames.com/gaming/all-frostpunk-2-factions-and-communities-explained-differences-research-and-laws

- **Setup** (source): 7 maps (Broken Shore, Windswept Peaks, Horizon, Crater, Fractured Gorge, The Pit, one
  unconfirmed), 3 community pairs, difficulty sliders (Economy, Weather, Frostland, Society) locked once the run starts.
  Presets: Citizen, Officer, Steward, Captain. Serenity Mode is a separate preset.
- **Ambitions** (source; all doable on Citizen):

| Ambition | Target |
|---|---|
| Colonise the Frostland | 10,000 people in each of 3 colonies, all problems absent |
| Develop a Metropolis | 50,000 people in the main city, no problems |
| Build a Prosperous Future | 100,000 each of Fuel, Food, Goods, Materials, no problems |

  Population growth stalls while any problem is Overwhelming (source). Challenge events (storm, outbreak) give a
  bonus or end the run if failed (source). Endless mode after 2,087 weeks (one guide, unverified).
- **Fractured Utopias tree (DLC 1.5, source).** Each of 8 factions has a 12-node tree: Bohemians, Overseers, Menders,
  Venturers, Icebloods, Technocrats, Legionnaires, Proteans. Nodes unlock the faction hub, laws, abilities, a Housing
  variant. A Utopia Point comes only when all three lesser factions behind the faction's values reach a threshold;
  appeasing one earns nothing. It does not advance with time.
  - Measured on one save: Venturers tree, 12 nodes, Hub unlocked, 3 nodes open, `nextThreshold` 15 (unit unverified),
    dominant faction Venturers. Read with `fp2 utopia`.
  - Opposites invert all three axes (Bohemians and Overseers, Menders and Venturers, Icebloods and Technocrats,
    Legionnaires and Proteans; last two inferred). An opposing faction appears after progress.
  - Venturers are Progress, Merit, Reason; passive City Investment adds Heatstamps; active Finance Mercenaries adds
    Guards (source).
- **Planning rule** (inferred): choose a target faction early, steer laws and research toward its three values, keep
  its three lesser factions above their thresholds at the same time.

## 8. Frostland

Source: https://frostpunk-2.game-vault.net/wiki/Outposts_and_Settlements . Trail, skyway and settlement figures come
from guides whose URLs the research notes did not keep (Dexerto, PCGamesN, a removed Steam guide): weak sources.

- **Teams.** Supply is `EconomyHolder` `LogisticsUnits`: 15 per active Logistics district, 0 while the district is
  switched off (measured). Exploring Chilton Pass took 10 teams; `explore_stop` returned them (measured). More teams
  (source, unverified): Vanguard Logistics Bay +20, Automated Bay +15, up to 3 bays; Fortitude Base +50.
- **Expeditions.** The Frostland view (key V) shows teams needed, threat and time. Measured on one save: 16 territories;
  `explorationWeeks` 15 for an Easy territory, 25 for a Hard one. Dangerous or Deadly territories can kill teams and
  cut Trust (source). Recalling early loses progress (source). A finished expedition leaves a marker to collect and
  needs stock space (source). Cores come from here.
- **Outposts.** Occupied by teams, which leave the free pool. An unupgraded outpost has finite resources (source).
  Measured: a coal outpost with `depositLeft` 50,810 and 36.3 weeks of extraction left. It sat inactive with
  `UnmetDemand` while free teams were 0. `build_outpost` built one instantly with no stockpile cost (measured). The
  `outpost_upgrade` command was refused silently by the game (no change, no cost); the requirement is unreadable.
  Settlements (source): unlimited output, need Settlement Heating and Skyways research, a skyway link, 350 Prefabs,
  800 to 2,400 workforce and about 3 Cores (weak source). A second upgrade may survive whiteouts (weak source).
- **Trails and skyways** (weak source): trail segment 25 Heatstamps and 5
  Prefabs, 1 week, capacity 250 per resource per link. Skyway segment 10 teams, 50 Heatstamps, 20 Prefabs, capacity
  600 each way only if the whole route is skyway; Freight Docks add more. Measured: no trail type was available on the
  Sandbox save, and trail cells are `Array<Int>` that are not city cell indices (a Frostland grid is the likely index).
- **Colonies** (a separate city with its own generator and problems; the main city's Council rules for all):

| Item | Measured (Sandbox save "The City", weeks 247 to 257) | Guide (unverified for this save) |
|---|---|---|
| Founding cost | `colony_build site=Loch`: instant, accepted with 0 free teams and 0 Cores; only `LogisticsUnitsResource` -20 listed | Windward Moor: 1 Core, 10 teams, 400 Prefabs, 5 weeks |
| People moved | 3,000 (`StartCommunitySize`): main city 11,998 to 8,998 | Moving people does not raise the total |
| Prefab, Core, Heatstamp change | none | see cost row |
| Open question | Whether `InstructBuildCity` skips the cost check or Sandbox colonies are free | |

  Do not plan campaign colonies as free. Check stocks before and after on a campaign save. A founding colony also
  creates two empty trade routes (one per pair); trading stayed locked in Sandbox (`tradingUnlocked` false).
- **Transfers** (source): sliders for coal, oil, food, materials, goods and people, capped by link capacity;
  batches of 5,000. `PXCityUtils.TransferCommunity` moved 100 people instantly at no cost (measured): a cheat path,
  never use it. The unit-order path is untested live. Arrivals need food, heat and housing at once.
- **Whiteout effects.** The in-game text says a whiteout cuts off sites and outposts under it and blocks exploration
  (measured text). Sources add that only locations under the storm are cut, so distant colonies may keep running,
  and that only food and coal can move between cities in a whiteout (weak sources). Recall expeditions before it and
  start no new ones.

## 9. Weather and whiteouts

Lead times, strip behaviour and the playbook are in [GAMEPLAY.md](GAMEPLAY.md#whiteout-playbook) (measured). Do not
copy them here. Facts to add:

- The forecast looks 100 weeks ahead (168,000 ticks, measured). Standard temperature is -20 C and changes come in
  batches (source: https://gamerguides.com/frostpunk-2/guide/getting-started/tips-and-tricks ).
- Measured: temperature level 1 is -30 C, level 4 is -60 C. One whiteout moved level 1 to 4 in one step and lasted
  about 29 weeks. Sources claim a drop of at least 60 C and 30 to 40 weeks: stale in both numbers.
- Effects (measured text and run): hothouse food output falls, exploration under the storm is blocked, sites and
  outposts under it are cut off. Heating deficit jumped to -750 with Warmth -1,090.
- Serenity Mode (1.3+) shortens whiteouts and removes Fervor (source).
- Apocalyptic Whiteout tale (Utopia Builder, TheGamer; URL not recorded, weak source): starts about week 558, 120 weeks,
  survive with at least half the population. Stock before week 550: fuel 1,000,000, food 600,000, materials
  800,000, goods 300,000, prefabs 3,000, plus 50 % margin. Another guide says week 418 and 200 weeks on Steward:
  conflict, unverified.
- Stock targets that guides give for the first whiteout (unverified): Prologue 40,000 food; Chapter 2 about 130k food
  and 100k oil across two cities (anecdote).

## 10. Scripted events and timers

Quest timers are authoritative in `snapshot.quests` (`weeksLeft`, measured field). The table below holds priors.

| Mode | Event | Timer or goal | Label |
|---|---|---|---|
| Campaign Prologue | Whiteout | Stockpile 40,000 food before it. "88 days" in one guide, 88 weeks in another; the timescale is weeks | source, conflict |
| Campaign Ch1 | Fuel crisis | Coal, Research Institute, Council Hall and vote of confidence, Logistics on a waystation, transfer 75 oil from the Old Dreadnought. No timer | source |
| Campaign Ch2 | Defeat or Embrace the Frost | A whiteout ahead; stock fuel and food in both cities | source |
| Campaign Ch3 | Winterhome | No timer. Salvage or Settle (set by the Ch2 route) | source |
| Campaign Ch4 | Gas outburst | 48 weeks. Salvage needs 40 Cores | source |
| Campaign Ch5 | Civil war | Hidden limit, warning near 30 weeks left; Peace Accords within a few weeks, 67 votes; Secure Rule 4 weeks | source |
| Utopia Builder | Ambitions | Section 7. Challenge events fail the run | source |
| Utopia Builder | Fractured Utopias | Utopia Points by thresholds, no timer | source |
| Any | Story dialogs with a deadline | Missed law or research ask loses trust, can lead to rebellion | source |

- Number of Old Waystations: 2 or 3 depending on guide. Violent Ch5 faction: Pilgrims or Faithkeepers (one guide
  says Stalwarts). Unverified.
- **Ways to lose** (source, with the bridge reads that warn first):
  1. Maximum Tension or Trust at the bottom tier: `health`, `statistics`, `trust.down`.
  2. Food gone in a whiteout: `stock.runway`.
  3. Heat unmet and the death rate rising: `need.deficit`, `deaths.increased`.
  4. Overdrive pushed too far: `generator.wear` toward 1.
  5. Missed Prologue food goal, Chapter 5 timer, Peace Accords deadline: `quests.weeksLeft`.
  6. Ignored faction demands leading to rebellion: `standing.down`, `factions` Fervor.
  7. A failed Utopia challenge.

## 11. Health thresholds experts use

Few numeric thresholds exist in guides; the bridge `health` command carries guessed bands (its own constants).

| Metric | Threshold | Label |
|---|---|---|
| Stock runway events | `stock.runway` fires at 20, 10, 5, 2 weeks | measured (bridge) |
| Fuel runway | Whiteout length times burn per day, plus margin; guides say 30 to 40 weeks, measured 29 | source, measured |
| Stock vs cap | Keep above three quarters of cap | source |
| Generator load | At 92 % with negative food, one run paused colonies and built the upgrade first | measured (decision) |
| Overdrive wear | Source 60 %; measured 0.7 to 0.8 within one poll in a whiteout | source, measured |
| Cold | Deaths at Cold 10; target 50 in a whiteout | measured |
| Heat | Unmet Heating deficit is the warning; zero or surplus is healthy | measured |
| Relations | Keep every group at Neutral or better; Favourable for actions | source, measured tiers |
| Trust | Accepted (0.6) or better; bottom tier triggers an ultimatum | measured, source |
| Council votes | 51 normal, 67 Rule | measured, source |
| Council recess | 10 weeks (16,800 ticks) | measured |
| Population | One guide says stay at or below 40,000 | unverified |
| Colony offload | Moving 3,000 people cut the main city from 11,998 to 8,998 | measured |

Early-warning HUD reads (source): weather strip whiteout icon, heat bar red, resource bars red, promise countdowns,
research icon idle, faction panel, Tension orb, and the five problem icons (hover for causes).
