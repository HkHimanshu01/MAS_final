# Architecture

RCA Compression MAS reads a QA bug report, scans the repo with bash, asks Claude Code agents to diagnose and propose a fix, optionally validates in a safe git worktree, and writes a developer-readable report.md.

## Pipeline

```
bug.md / --issue
  → briefing.sh (pure bash, 4 collectors, 0 LLM calls)
  → Agent 1 — diagnosis (agentic loop, full codebase search)
  → Agent 2 — solution (single pass, read-only, unified diff)
  → Agent 2.5 — validation (optional, --validate only, worktree)
  → report.md
```

## Path model

| Variable | Value |
|---|---|
| TOOL_ROOT | Where rca-mas scripts, prompts, schemas live |
| TARGET_REPO_ROOT | Repo being analyzed (where you cd before running) |
| RUN_DIR | TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID} |

> Full content added at Step 9.
