# FujiCull

Native macOS (Swift 6, SwiftPM, Command Line Tools only) app for culling Fujifilm RAW+JPEG shoots from the SD card.

Read CONSTRAINTS.md before writing code. Do not weaken it to make a change pass.

- What to build: docs/REQUIREMENTS.md. How: docs/DESIGN.md and docs/decisions/ (ADRs). Hardware facts: docs/spikes/.
- Work items: tasks/todo.md, in order; tasks/plan.md for the overview.
- Before calling a task done: `make check` (every check in CONSTRAINTS.md, at most 90 s). At checkpoints: `make check-full`.
- Build and launch the app: `make run`.
- Never point code or tests at real volumes (Fuji SD, C&J Archive). Use temp directories. `Sample Images/` is gitignored and never committed.

## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

Rules:
- For codebase questions, first run `graphify query "<question>"` when graphify-out/graph.json exists. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
