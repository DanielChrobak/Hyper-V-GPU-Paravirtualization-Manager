## graphify

This project has a knowledge graph at graphify-out/ with god nodes, community structure, and cross-file relationships.

When the user types `/graphify`, use the installed graphify skill or instructions before doing anything else.

Rules:
- When graphify-out/graph.json exists, run `graphify query "<question>"` before your first grep, search or source-file read for a codebase question, and put this rule in every subagent prompt that explores code. Read raw files only for lines the graph or an earlier read already located. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for focused concepts. These return a scoped subgraph, usually much smaller than GRAPH_REPORT.md or raw grep output.
- Dirty graphify-out/ files are expected after hooks or incremental updates; dirty graph files are not a reason to skip graphify. Only skip graphify if the task is about stale or incorrect graph output, or the user explicitly says not to use it.
- If graphify-out/wiki/index.md exists, use it for broad navigation instead of raw source browsing.
- Read graphify-out/GRAPH_REPORT.md only for broad architecture review or when query/path/explain do not surface enough context.
- After modifying code, run `graphify update .` to keep the graph current (AST-only, no API cost).
- A committed graphify-out/graph.json is rewritten whole on every build, so a large diff to it in a pull request is expected. Do not flag it as churn or suggest skipping the graph rebuild or its hooks.

### Local setup

- This repository uses the local Graphify CLI and MCP server. The MCP configuration is in `.codex/config.toml`; CodeGraph is disabled only for this project.
- The initial graph covers code only. To rebuild it from PowerShell without model calls, run `$env:GRAPHIFY_BACKEND = 'none'` followed by `graphify extract . --code-only` and `graphify cluster-only . --no-label`.
- Generated files under `graphify-out/` are local and ignored by Git. Run `graphify update .` with `GRAPHIFY_BACKEND=none` after code changes to refresh them.
- Treat inferred calls as navigation hints and verify them in source. PowerShell test mocks can be mistaken for runtime callees. Disambiguate duplicate symbols with `path/to/file.ps1::FunctionName()` or a full node ID.
