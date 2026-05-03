# RCA Compression MAS — Architecture Reference

## Purpose

This document is the single reference for understanding, building, and tuning the RCA Compression MAS. It covers the high-level design, each agent's role and configuration, data flows between components, and — most importantly — every parameter you will want to tweak.

---

## High-Level Design

### Problem

A QA tester finds a bug during manual testing and raises it on GitHub/JIRA. The developer spends 30–60 minutes reading the report, searching the codebase, tracing call chains, checking git history, forming a hypothesis, and verifying it. All under deadline.

### Solution

A CLI tool (`rca-mas.sh`) that reads the bug report, runs bash-based triage, then invokes three Claude Code agents in sequence to produce a developer-ready root-cause report in 3–8 minutes.

### Key design constraints

| Constraint | Decision |
|---|---|
| No API keys | Claude Code CLI only |
| Works on any machine | Bash + git + jq — zero extra dependencies |
| Never touches source code | report-only default; validation uses git worktree |
| Human always decides | System proposes, never applies to working tree |
| Sequential agents | Each feeds the next; no parallelism possible |
| Context isolation | Each agent sees less than the previous one |
| All parameters in one place | `config/defaults.env` — override any value by exporting before running |

---

## Repo Structure

```
rca-mas/
├── rca-mas.sh                    ← entry point (arg parsing, prereq checks)
├── config/
│   └── defaults.env              ← ALL tunable parameters in one place
├── scripts/
│   ├── orchestrator.sh           ← pipeline controller (owns run lifecycle)
│   ├── briefing.sh               ← pure bash repo scan (zero LLM calls)
│   ├── claude_json.sh            ← shared Claude Code invocation helper
│   └── report.sh                 ← JSON → report.md
├── lib/
│   ├── log.sh                    ← structured JSONL logging + info/warn/die
│   ├── json.sh                   ← jq helpers (extract_structured, assert_valid_json)
│   ├── paths.sh                  ← run directory init + path variables
│   └── cleanup.sh                ← worktree + temp file cleanup trap
├── collectors/
│   ├── git.sh
│   ├── deps.sh
│   ├── errors.sh
│   └── testrunner.sh
├── prompts/
│   ├── diagnosis.md
│   ├── solution.md
│   └── validation.md
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── docs/                         ← 8 docs (see docs/ section)
├── examples/
│   ├── bug.md                    ← smoke test sample
│   └── sample-report.md
├── tests/
│   ├── fixtures/
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   └── test_smoke_report_only.sh
├── Makefile
├── README.md
└── CLAUDE.md
```

---

## Pipeline Overview

```
bug.md (QA report)
  │
  ▼
[Briefing]  ←── pure bash, 4 collectors, 0 LLM calls
  │ briefing.md  MAX_TURNS  TIMEOUT  TEST_COMMAND  MENTIONED_FILES
  ▼
[Agent 1 — Diagnosis]  ←── agentic loop, searches full codebase
  │ diagnosis.json  checkpoint.json (on timeout)
  ▼
[Agent 2 — Solution]  ←── single pass, read-only
  │ solution.json  patches/fix.diff
  ▼
[Agent 2.5 — Validation]  ←── only with --validate flag
  │ validation.json  patches/generated_test.diff  patches/fix_and_test.diff
  ▼
[report.sh]  ←── bash, JSON → markdown
  │
  ▼
report.md  →  Developer
```

## File Dependency Map

```
rca-mas.sh
  sources: config/defaults.env
  execs:   scripts/orchestrator.sh
              sources: lib/log.sh  lib/json.sh  lib/paths.sh  lib/cleanup.sh
              calls:   scripts/briefing.sh
                         runs: collectors/git.sh
                               collectors/deps.sh
                               collectors/errors.sh
                               collectors/testrunner.sh
              calls:   scripts/claude_json.sh  (run_claude_schema)
                         uses: prompts/diagnosis.md + schemas/diagnosis.schema.json → Agent 1
                               prompts/solution.md  + schemas/solution.schema.json  → Agent 2
                               prompts/validation.md + schemas/validation.schema.json → Agent 2.5
              calls:   scripts/report.sh
                         reads: diagnosis.json, solution.json, validation.json
                         writes: report.md
```

---

## Component Details

### Briefing (bash, zero LLM)

**Role:** Orients Agent 1 before the agentic loop begins. Saves 8–12 turns of `ls`/`find`/`grep` warm-up.

**Inputs:** `bug.md`, repo root

**Outputs:** `briefing.md`, `errors.txt`

**What it does:**
- Regex-extracts file paths and error strings from `bug.md`, validates each with `[ -f "$path" ]`
- Counts repo files with `git ls-files` (or `find` fallback)
- Selects `MAX_TURNS` and `TIMEOUT` from the file-count tier table
- Detects the test command in the repo
- Runs 4 collectors with `timeout 10` each; continues if any fail
- Deduplicates output with `awk`

**4 Collectors:**

| Collector | What it produces |
|---|---|
| `git.sh` | `git log` for mentioned files (last 14 days), recent merges to master, `git blame` |
| `deps.sh` | Import/require chains for mentioned files (Python, JS/TS, Go) |
| `errors.sh` | Fixed-string grep for every error string across the full repo |
| `testrunner.sh` | Detected test command + src→test file mapping by convention |

**Tunable parameters — Briefing:**

| Parameter | Variable | Location | Default | What to change |
|---|---|---|---|---|
| `MAX_TURNS` per tier | `RCA_TURNS_XS/S/M/L` | `config/defaults.env` | 15 / 25 / 35 / 50 | Raise if agents hit turn limits; lower to reduce cost |
| `TIMEOUT` per tier | `RCA_TIMEOUT_XS/S/M/L` | `config/defaults.env` | 180 / 300 / 420 / 600 s | Raise if agents time out; lower to fail fast |
| Collector timeout | `RCA_COLLECTOR_TIMEOUT` | `config/defaults.env` | 10 s per collector | Raise on slow disks or large git histories |
| Git lookback window | `RCA_GIT_LOOKBACK` | `config/defaults.env` | `"14 days ago"` | Widen for bugs in older code |
| Error grep line limit | `RCA_ERROR_GREP_LIMIT` | `config/defaults.env` | 50 lines per error | Raise if key locations are being truncated |
| File count tier boundaries | `RCA_TIER_XS/S/M` | `config/defaults.env` | 100 / 500 / 2000 | Adjust to match your typical repo sizes |

---

### Agent 1 — Diagnosis

**Role:** Senior QA engineer. Investigates the full codebase autonomously using Claude Code's built-in tools. Produces a structured diagnosis with competing hypotheses and evidence.

**Prompt file:** `prompts/diagnosis.md`

**Schema file:** `schemas/diagnosis.schema.json`

**Inputs (assembled into `agent1_prompt.md` before run):**
- `prompts/diagnosis.md` (role + instructions)
- `briefing.md` (repo map, git history, deps, error locations, test map)
- `bug.md` (QA report — treated as untrusted input)

**Output:** `diagnosis.json`, `diagnosis.raw.json`, `checkpoint.json` (written mid-run after 10 files)

**Output schema:**

```json
{
  "run_id": "string",
  "root_cause": "string",
  "selected_hypothesis_id": "string",
  "hypotheses": [
    {
      "id": "string",
      "summary": "string",
      "supporting_evidence": [
        { "type": "string", "path": "string", "lines": "string", "note": "string" }
      ],
      "contradicting_evidence": [...],
      "confidence": 0.0
    }
  ],
  "rejected_hypotheses": [{ "id": "string", "reason": "string" }],
  "affected_files": ["string"],
  "call_chain": ["string"],
  "files_examined": ["string"],
  "unknowns": ["string"],
  "confidence": 0.0,
  "introducing_commit": "string or null",
  "next_best_action": "string"
}
```

**Tool access:**

```
--tools "Read,Grep,Glob,Bash,Write"
--allowedTools:
  Read
  Grep
  Glob
  Bash(git log *)
  Bash(git blame *)
  Bash(git show *)
  Bash(git diff *)
  Bash(git status *)
  Bash(rg *)
  Bash(grep *)
  Bash(find *)
  Write(.rca-mas/runs/**)    ← checkpoint only
```

**Tunable parameters — Agent 1:**

| Parameter | Variable | Location | Default | Effect |
|---|---|---|---|---|
| `--max-turns` | `RCA_TURNS_*` tiers | `config/defaults.env` | 15–50 (tier-based) | More turns = deeper investigation, more cost. Primary lever for quality vs speed |
| `CLAUDE_TIMEOUT` | `RCA_TIMEOUT_*` tiers | `config/defaults.env` | 180–600 s (tier-based) | Hard wall-clock limit |
| Minimum hypotheses | (prompt text) | `prompts/diagnosis.md` | 2 | Raise to 3 for ambiguous bugs |
| Confidence stop threshold | `RCA_CONFIDENCE_STOP` | `config/defaults.env` | 0.7 | Lower for faster/cheaper; raise for higher certainty |
| Checkpoint trigger | (prompt text) | `prompts/diagnosis.md` | after 10 files | Lower for faster timeout recovery |
| Call-chain depth | (prompt text) | `prompts/diagnosis.md` | 3 levels | Raise for deeply nested codebases |
| Self-critique count | (prompt text) | `prompts/diagnosis.md` | 3 | Each adds ~0.5 turns |
| Model (all agents) | `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | Set `claude-opus-4-7` for highest quality |
| Checkpoint recovery confidence | `RCA_CONFIDENCE_CHECKPOINT` | `config/defaults.env` | 0.4 | Stamped on output when checkpoint is used after timeout |

---

### Agent 2 — Solution

**Role:** Senior software engineer. Reads the diagnosis and affected code, produces a focused unified diff. Single pass, read-only.

**Prompt file:** `prompts/solution.md`

**Schema file:** `schemas/solution.schema.json`

**Inputs (assembled into `agent2_prompt.md`):**
- `prompts/solution.md`
- `diagnosis.json`
- Actual source of each file in `diagnosis.affected_files`
- `## Dependencies` section from `briefing.md`

**Output:** `solution.json`, `solution.raw.json`, `patches/fix.diff`

**Output schema:**

```json
{
  "run_id": "string",
  "recommendation": "FIX | NO_FIX",
  "no_fix_reason": "string or null",
  "recommended_fix_id": "string or null",
  "fixes": [
    {
      "id": "string",
      "description": "string",
      "why_this_fixes_root_cause": "string",
      "unified_diff": "string",
      "affected_files": ["string"],
      "risk": "low | medium | high",
      "expected_tests": ["string"],
      "manual_review_notes": ["string"]
    }
  ]
}
```

**Tool access:**

```
--tools "Read,Grep,Glob"
No Bash. No Edit. No Write.
```

**Tunable parameters — Agent 2:**

| Parameter | Variable | Location | Default | Effect |
|---|---|---|---|---|
| `--max-turns` | `RCA_AGENT2_TURNS` | `config/defaults.env` | 1 | Single-pass by design. Raise to 3 if agent needs file re-reads before producing diff |
| `CLAUDE_TIMEOUT` | `RCA_AGENT2_TIMEOUT` | `config/defaults.env` | 180 s | Raise if large files cause slow reads |
| NO_FIX confidence threshold | `RCA_CONFIDENCE_NOFX` | `config/defaults.env` | 0.5 | Raise to 0.65 to be more conservative |
| Fix scope instruction | (prompt text) | `prompts/solution.md` | "one focused fix" | Change to "up to 2" for multiple options |
| Risk labelling guidance | (prompt text) | `prompts/solution.md` | low/medium/high | Tighten definitions if labels are inconsistent |
| Model (all agents) | `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | Set `claude-opus-4-7` for better diffs |

---

### Agent 2.5 — Validation + New Test

**Role:** Validates the proposed fix and writes a regression test for the specific QA-reported scenario. Only runs with `--validate` flag. Operates exclusively inside a git worktree sibling to the repo.

**Prompt file:** `prompts/validation.md`

**Schema file:** `schemas/validation.schema.json`

**Inputs (assembled into `agent25_prompt.md`):**
- `prompts/validation.md`
- `diagnosis.json`
- `solution.json`
- Source of affected files
- Worktree path

**Output:** `validation.json`, `validation.raw.json`, `patches/fix.diff`, `patches/generated_test.diff`, `patches/fix_and_test.diff`

**Worktree location:** `../.rca-mas-worktrees/{RUN_ID}` (sibling to repo, never inside run dir)

**7-step validation process:**

```
1. Code review      — LLM reviews fix for logic errors (runs in all modes)
2. Create worktree  — git worktree add ../.rca-mas-worktrees/{RUN_ID} HEAD
3. Apply fix        — git apply --check then apply patch in worktree
4. Run existing     — timeout 120 $TEST_COMMAND in worktree
5. Write new test   — one test for the exact QA-reported scenario
6. Run new test     — execute in worktree after fix
7. Remove worktree  — git worktree remove (idempotent cleanup)
```

**Output status values:**

| Status | Meaning |
|---|---|
| `SKIPPED` | report-only mode |
| `PATCH_APPLIED` | diff applied, no tests run |
| `TEST_CREATED` | new test written, not yet run |
| `TESTS_PASSED` | existing tests pass after fix |
| `TESTS_FAILED` | regression detected |
| `GENERATED_BUT_NOT_VERIFIED` | new test written, pass/fail unknown |
| `VALIDATION_FAILED` | worktree or apply step failed |

**Tool access:**

```
--tools "Read,Grep,Glob,Edit,Bash"
--allowedTools (inside worktree only):
  Bash(git status *)
  Bash(git diff *)
  Bash(git apply *)
  Bash(pytest *)       Bash(python -m pytest *)
  Bash(poetry run pytest *)  Bash(uv run pytest *)
  Bash(tox *)          Bash(nox *)
  Bash(npm test *)     Bash(npm run test *)
  Bash(pnpm test *)    Bash(yarn test *)
  Bash(npx vitest *)   Bash(npx jest *)
  Bash(go test *)      Bash(make test *)
```

**Tunable parameters — Agent 2.5:**

| Parameter | Variable | Location | Default | Effect |
|---|---|---|---|---|
| `--max-turns` | `RCA_AGENT25_TURNS` | `config/defaults.env` | 15 | Raise for complex test writing; lower to reduce cost |
| `CLAUDE_TIMEOUT` | `RCA_AGENT25_TIMEOUT` | `config/defaults.env` | 300 s | Raise if test suite is slow |
| Test execution timeout | `RCA_AGENT25_TEST_TIMEOUT` | `config/defaults.env` | 120 s | Raise for large test suites |
| New test count | (prompt text) | `prompts/validation.md` | "exactly one focused test" | Change to "up to 2" for multiple entry points |
| Keep worktree | `RCA_KEEP_WORKTREE` | `config/defaults.env` or env var | 0 | Set to `1` to inspect worktree after run |
| Worktree parent dir | `RCA_WORKTREE_DIR` | `config/defaults.env` | `../.rca-mas-worktrees` | Change if sibling dir is not writable |
| Model (all agents) | `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | Set `claude-opus-4-7` for better test generation |

---

## Data Flow

```
bug.md
  │
  ├── [briefing.sh]
  │     ├── extracts: MENTIONED_FILES, ERROR_STRINGS
  │     ├── computes: FILE_COUNT → MAX_TURNS, TIMEOUT
  │     ├── runs: git.sh, deps.sh, errors.sh, testrunner.sh
  │     └── writes: briefing.md, errors.txt
  │
  ├── [Agent 1]
  │     reads:  agent1_prompt.md = diagnosis.md + briefing.md + bug.md
  │     writes: diagnosis.raw.json
  │             diagnosis.json  (.structured_output extracted)
  │             checkpoint.json (mid-run, after 10 files)
  │     key fields consumed downstream:
  │       diagnosis.confidence       → Agent 2 NO_FIX gate
  │       diagnosis.affected_files   → Agent 2 context assembly
  │       diagnosis.root_cause       → report
  │       diagnosis.hypotheses[]     → report
  │
  ├── [Agent 2]
  │     reads:  agent2_prompt.md = solution.md + diagnosis.json
  │                                + source of affected_files
  │                                + briefing ## Dependencies section
  │     writes: solution.raw.json
  │             solution.json
  │             patches/fix.diff     (extracted from solution.unified_diff)
  │     key fields consumed downstream:
  │       solution.recommendation    → validation skip gate
  │       solution.unified_diff      → patches/fix.diff → Agent 2.5
  │       solution.risk              → report
  │
  ├── [Agent 2.5]  (--validate only)
  │     reads:  agent25_prompt.md = validation.md + diagnosis.json
  │                                 + solution.json + affected file sources
  │     creates: worktree at ../.rca-mas-worktrees/{RUN_ID}
  │     applies: patches/fix.diff
  │     runs:   $TEST_COMMAND (from briefing)
  │     writes: validation.raw.json
  │             validation.json
  │             patches/fix_and_test.diff
  │             patches/generated_test.diff
  │     removes: worktree (unless RCA_KEEP_WORKTREE=1)
  │
  └── [report.sh]
        reads:  diagnosis.json, solution.json, validation.json
        writes: report.md
```

---

## All Tunable Parameters — Quick Reference

**All parameters live in `config/defaults.env`.** Override any of them by exporting before running:
```bash
RCA_MODEL=claude-opus-4-7 RCA_TURNS_L=70 ./rca-mas.sh bug.md
```
Prompt-text parameters require editing the prompt file directly.

### Turn and timeout budgets — all in `config/defaults.env`

| Variable | Default | Tier |
|---|---|---|
| `RCA_TURNS_XS` | 15 | repos < 100 files |
| `RCA_TURNS_S` | 25 | 100–500 files |
| `RCA_TURNS_M` | 35 | 500–2000 files |
| `RCA_TURNS_L` | 50 | > 2000 files |
| `RCA_TIMEOUT_XS` | 180 s | repos < 100 files |
| `RCA_TIMEOUT_S` | 300 s | 100–500 files |
| `RCA_TIMEOUT_M` | 420 s | 500–2000 files |
| `RCA_TIMEOUT_L` | 600 s | > 2000 files |
| `RCA_TIER_XS` | 100 | file count breakpoint |
| `RCA_TIER_S` | 500 | file count breakpoint |
| `RCA_TIER_M` | 2000 | file count breakpoint |
| `RCA_AGENT2_TURNS` | 1 | Agent 2 max turns |
| `RCA_AGENT2_TIMEOUT` | 180 s | Agent 2 wall-clock limit |
| `RCA_AGENT25_TURNS` | 15 | Agent 2.5 max turns |
| `RCA_AGENT25_TIMEOUT` | 300 s | Agent 2.5 wall-clock limit |
| `RCA_AGENT25_TEST_TIMEOUT` | 120 s | Test execution timeout inside worktree |

### Confidence thresholds — all in `config/defaults.env`

| Variable | Default | Effect |
|---|---|---|
| `RCA_CONFIDENCE_STOP` | 0.7 | Agent 1 stops early when confidence exceeds this |
| `RCA_CONFIDENCE_CHECKPOINT` | 0.4 | Stamped on output when checkpoint recovery is used after timeout |
| `RCA_CONFIDENCE_NOFX` | 0.5 | Agent 2 returns NO_FIX if `diagnosis.confidence` is below this |

### Search and investigation depth

| Variable / Prompt text | Location | Default | Effect |
|---|---|---|---|
| `RCA_GIT_LOOKBACK` | `config/defaults.env` | `"14 days ago"` | Widen for older bugs |
| `RCA_COLLECTOR_TIMEOUT` | `config/defaults.env` | 10 s | Raise on slow disks |
| `RCA_ERROR_GREP_LIMIT` | `config/defaults.env` | 50 lines | Raise if locations are being truncated |
| "3 levels deep" | `prompts/diagnosis.md` | 3 levels | Raise for deeply nested code |
| "10 files" (checkpoint) | `prompts/diagnosis.md` | 10 files | Lower for faster timeout recovery |
| "at least 2" (hypotheses) | `prompts/diagnosis.md` | 2 | Raise for ambiguous bugs |
| "3 ways" (self-critique) | `prompts/diagnosis.md` | 3 | Each adds ~0.5 turns |

### Model — `config/defaults.env`

| Variable | Default | Options |
|---|---|---|
| `RCA_MODEL` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents; `claude-haiku-4-5-20251001` for speed |

One variable controls all 3 agents. Set it in defaults.env or export before running.

### Validation worktree — `config/defaults.env`

| Variable | Default | Effect |
|---|---|---|
| `RCA_KEEP_WORKTREE` | 0 | Set to `1` to keep worktree for manual inspection after run |
| `RCA_WORKTREE_DIR` | `../.rca-mas-worktrees` | Change if sibling dir is not writable |

---

## docs/ Contents

8 documentation files. All are required deliverables.

| File | Content |
|---|---|
| `docs/index.md` | Reading order, one-line summary of each doc |
| `docs/architecture.md` | This file — pipeline, components, parameters, data flow |
| `docs/briefing-flow.md` | `briefing.sh` + 4 collectors: inputs, outputs, failure behaviour, tier table |
| `docs/agent-flow.md` | Agent 1 + 2 + 2.5: roles, tool restrictions, schemas, confidence rules |
| `docs/validation-flow.md` | Worktree lifecycle, patch application, test generation, cleanup |
| `docs/runbook.md` | How to run, all CLI flags, env var overrides, output files |
| `docs/troubleshooting.md` | Common failures with exact fixes: Claude not logged in, jq error, empty diagnosis, timeout |
| `docs/testing-real-github-bugs.md` | Step-by-step guide for testing against real repos with known fix commits |

---

## Context Funnel

Each agent receives less context than the previous one. This prevents context pollution and keeps each agent focused.

```
Agent 1   full repo access  +  briefing.md (~10K+ tokens of investigation context)
  │
  ▼  passes only diagnosis.json (clean structured summary)
  │
Agent 2   diagnosis.json  +  affected file sources  +  deps section  (~5K tokens)
  │
  ▼  passes diagnosis + solution + affected file sources
  │
Agent 2.5 diagnosis.json  +  solution.json  +  affected file sources  (~4K tokens)
```

Agent 2 never sees Agent 1's 30K tokens of exploration traces.

---

## Graceful Degradation

Every failure mode is a warning, not a crash. The pipeline continues and surfaces degradation in the final report.

| Failure | Behavior |
|---|---|
| A collector fails | Log warning in `log.jsonl`; briefing section left empty; Agent 1 cold-starts |
| Agent 1 times out | Use `checkpoint.json` if present; stamp confidence 0.4; continue to Agent 2 |
| Agent 1 times out, no checkpoint | Emit `diagnosis.json` with `root_cause: "UNKNOWN"`, confidence 0.0 |
| Agent 1 produces invalid JSON | Save as `diagnosis.raw.json`; log error; skip Agent 2 |
| `diagnosis.confidence < 0.5` | Agent 2 returns `NO_FIX`; skip Agent 2.5 |
| Agent 2 produces empty/malformed diff | Write warning to report; skip validation |
| No test runner detected | Agent 2.5 skips test execution; still writes generated test diff |
| All stages fail | `report.md` still written; shows what failed and why |

---

## Security Boundaries

- Never reads `.env`, `.pem`, `.key`, `id_rsa`, or credential files
- Never runs network commands (`curl`, `wget`, `ssh`, `scp`)
- Never writes outside `.rca-mas/runs/{RUN_ID}` (except inside validation worktree)
- Never commits, pushes, deploys, tags, or opens PRs
- Never installs dependencies
- Bug report is always treated as untrusted input — prompt injection defense is required in every agent prompt
- `.claude/settings.json` enforces deny rules at the Claude Code permission level

---

## Run Artifacts

Every run writes to `.rca-mas/runs/{RUN_ID}/`. The `latest` symlink always points to the most recent run.

| File | Written by | Purpose |
|---|---|---|
| `manifest.json` | orchestrator | Run metadata — see fields below |
| `bug.md` | orchestrator | Normalized bug input |
| `issue.json` | orchestrator | Raw GitHub issue payload (only with `--issue`) |
| `briefing.md` | briefing.sh | Repo map for Agent 1 |
| `errors.txt` | briefing.sh | Extracted error strings |
| `agent1_prompt.md` | orchestrator | Assembled Agent 1 prompt (debug) |
| `diagnosis.raw.json` | Agent 1 | Full Claude wrapper response |
| `diagnosis.json` | orchestrator | `.structured_output` extracted |
| `checkpoint.json` | Agent 1 | Mid-run state written after 10 files (used for recovery on timeout) |
| `agent2_prompt.md` | orchestrator | Assembled Agent 2 prompt (debug) |
| `solution.raw.json` | Agent 2 | Full Claude wrapper response |
| `solution.json` | orchestrator | `.structured_output` extracted |
| `patches/fix.diff` | orchestrator | Unified diff from solution |
| `agent25_prompt.md` | orchestrator | Assembled Agent 2.5 prompt (debug) — only with `--validate` |
| `validation.raw.json` | Agent 2.5 | Full Claude wrapper response |
| `validation.json` | orchestrator | `.structured_output` extracted (always written, SKIPPED if report-only) |
| `patches/generated_test.diff` | Agent 2.5 | New test only |
| `patches/fix_and_test.diff` | Agent 2.5 | Fix + test combined |
| `report.md` | report.sh | Final developer-readable report |
| `log.jsonl` | orchestrator | Structured JSONL event log per stage |
| `agent1.log` | orchestrator | Agent 1 stderr |
| `agent2.log` | orchestrator | Agent 2 stderr |
| `agent25.log` | orchestrator | Agent 2.5 stderr |

### `manifest.json` fields

| Field | Value | Purpose |
|---|---|---|
| `run_id` | `<timestamp>-<sha>` | Unique run identifier |
| `mode` | `report-only` or `validate` | How the run was invoked |
| `repo_root` | absolute path | Where the tool was run from |
| `repo_remote_url` | git remote origin URL | Cross-reference run against GitHub repo |
| `git_head_sha` | HEAD SHA | Exact code state at time of run |
| `git_branch` | branch name | |
| `bug_source` | `file` or `github_issue` | Input type |
| `bug_source_file` | path to bug.md | Traceability |
| `issue_url` | GitHub issue URL | Only when `--issue` used |
| `expected_fix_commit` | SHA or null | Set via `EXPECTED_FIX_SHA=abc ./rca-mas.sh bug.md` — for comparing agent output against known fix |
| `started_at` | ISO 8601 | |
| `ended_at` | ISO 8601 or null | null if run crashed before completion |
| `stage_statuses` | `{briefing, agent1, agent2, validation, report}` | Updated as each stage completes — partial runs are inspectable |
| `tool_versions` | claude, git, jq, gh | Reproducibility |
