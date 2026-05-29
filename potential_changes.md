# Potential Changes — v2 and Beyond

> This file is the only place for future ideas. Do not add them to plan.md, architecture.md, or implementation_suggestions.md.
> None of these are in scope for v1.

---

## Agent Team (Parallel Hypothesis Generation)

Run multiple Agent 1 instances in parallel, each forming independent hypotheses, then merge/vote on the best one. Requires moving from Claude Code CLI to Claude SDK to use the native `Task` tool for subagent spawning. High cost multiplier for marginal diversity gain — only worth it for highly ambiguous bugs where a single agent consistently produces low-confidence diagnoses.

## Best Practices Agent

A post-run agent that reads the final `diagnosis.json` and `solution.json` from a completed run and generates reusable test cases from the root cause and fix. Stores them in a shared test knowledge base (e.g. `TARGET_REPO_ROOT/.rca-mas/test-bank/`) so future runs on the same repo can reference past findings. Over time builds a repo-specific library of regression scenarios that QA and developers can pull from directly.

**Why:** Right now every run is stateless — findings are written to a report and forgotten. A best practices agent makes the MAS accumulate knowledge about a repo across runs rather than starting cold every time.

## Claude Code Hooks Integration

Add Claude Code hooks to auto-trigger the MAS on specific events — for example, running the pipeline automatically when a new GitHub issue is created, when a CI test fails, or when a developer opens a branch. Hooks would eliminate the manual `./rca-mas.sh bug.md` invocation and make the tool feel ambient rather than opt-in.

**Why:** The tool currently requires a developer to consciously invoke it. Hooks would close the loop between QA filing a bug and the agent starting work — reducing the human coordination step to near zero.
