# Potential Changes — v2 and Beyond

> This file is the only place for future ideas. Do not add them to plan.md, architecture.md, or implementation_suggestions.md.
> None of these are in scope for v1.

---

## Agent Team (Parallel Hypothesis Generation)

Run multiple Agent 1 instances in parallel, each forming independent hypotheses, then merge/vote on the best one. Requires moving from Claude Code CLI to Claude SDK to use the native `Task` tool for subagent spawning. High cost multiplier for marginal diversity gain — only worth it for highly ambiguous bugs where a single agent consistently produces low-confidence diagnoses.

## Best Practices Agent

A post-run agent that reads the final `diagnosis.json` and `solution.json` from a completed run and generates reusable test cases from the root cause and fix. Stores them in a shared test knowledge base (e.g. `TARGET_REPO_ROOT/.rca-mas/test-bank/`) so future runs on the same repo can reference past findings. Over time builds a repo-specific library of regression scenarios that QA and developers can pull from directly.

**Why:** Right now every run is stateless — findings are written to a report and forgotten. A best practices agent makes the MAS accumulate knowledge about a repo across runs rather than starting cold every time.
