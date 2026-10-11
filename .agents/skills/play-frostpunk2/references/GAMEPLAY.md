# Gameplay notes

Mark each note with its evidence: (observed) = seen in this repo's play logs; (general) =
general FP2 knowledge, verify before relying on it.

## Economy

- Needs (`needs` extractor): Shelter ← Housing districts; Nourishment ← Food districts;
  Heating/Warmth ← Generator power + heat-related buildings; Possession ← Goods (Industrial);
  Maintenance ← Materials. Negative balance raises the matching statistic (Cold, Hunger,
  Squalor, ...). (general)
- `resources.change` is the net change per stockpile update; HUD shows the same numbers. (observed)
- A new Utopia Builder start (Citizen) has: 8000 people, 4800 workforce, 450 Heatstamps,
  1500 Prefabs, 40000 Materials, 50000 Food, 15000 Coal; Shelter −47, Possession −40. (observed)
- Housing District costs 40 Heatstamps, 200 Prefabs and 200 workforce while building. (observed)
- Districts need 6 adjacent hex tiles. Frozen (hatched) tiles must be frostbroken first. (observed)
- Extraction and Logistics districts must start on a matching deposit. Nearest Logistics deposit to the
  Windswept Peaks start is ~29k units NW, beyond frozen land. (observed)
- Districts next to Housing add Squalor (proximity); Housing next to the generator ring gets +1 temperature. (observed)

## Priorities early (general)

1. Shelter and Heating deficits first (they drive Cold/Sickliness/Tension).
2. Food supply before stock runs out (`stock / -change` updates).
3. Goods (Industrial) for Possession; Materials for Maintenance.
4. Logistics district to unlock the Frostland (expeditions, outposts, cores).
5. Research Institute + Idea tree; keep factions' trust via Council votes/promises.

## Time

- 10 game ticks = 1 hour; 1680 ticks = 1 week (`PXTimeSubsystem.GetTotalHours/GetTotalWeeks`). (observed)
- HUD calendar date is interpolated between logic ticks; trust `gameTimeTicks`. (observed)
