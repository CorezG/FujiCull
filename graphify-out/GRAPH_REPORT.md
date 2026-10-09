# Graph Report - FujiCull  (2026-10-09)

## Corpus Check
- 5 files · ~1,619 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 22 nodes · 19 edges · 5 communities (2 shown, 3 thin omitted)
- Extraction: 100% EXTRACTED · 0% INFERRED · 0% AMBIGUOUS
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `3a0c43df`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- FujiCull — Product Requirements (v1)
- 4. Functional requirements
- REQUIREMENTS.md
- CLAUDE.md
- .claude/CLAUDE.md

## God Nodes (most connected - your core abstractions)
1. `FujiCull — Product Requirements (v1)` - 9 edges
2. `4. Functional requirements` - 7 edges
3. `graphify` - 1 edges
4. `graphify` - 1 edges
5. `FujiCull` - 1 edges
6. `1. Problem & goal` - 1 edges
7. `2. User & context` - 1 edges
8. `3. Core workflow` - 1 edges
9. `4.1 Opening a source` - 1 edges
10. `4.2 Decisions` - 1 edges

## Surprising Connections (you probably didn't know these)
- None detected - all connections are within the same source files.

## Communities (5 total, 3 thin omitted)

### Community 0 - "FujiCull — Product Requirements (v1)"
Cohesion: 0.25
Nodes (8): 1. Problem & goal, 2. User & context, 3. Core workflow, 5. Non-functional requirements, 6. Out of scope for v1 (candidates for later), 7. Assumptions to confirm, 8. Tip (not a requirement), FujiCull — Product Requirements (v1)

### Community 1 - "4. Functional requirements"
Cohesion: 0.29
Nodes (7): 4.1 Opening a source, 4.2 Decisions, 4.3 Keyboard (one-handed, right hand), 4.4 Screen layout, 4.5 Saving progress, 4.6 Apply (offload + delete), 4. Functional requirements

## Knowledge Gaps
- **3 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `FujiCull — Product Requirements (v1)` connect `FujiCull — Product Requirements (v1)` to `4. Functional requirements`, `REQUIREMENTS.md`?**
  _High betweenness centrality (0.533) - this node is a cross-community bridge._
- **Why does `4. Functional requirements` connect `4. Functional requirements` to `FujiCull — Product Requirements (v1)`?**
  _High betweenness centrality (0.386) - this node is a cross-community bridge._