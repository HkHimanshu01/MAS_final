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

| Parameter | Location | Default | What to change |
|---|---|---|---|
| `MAX_TURNS` tier table | `scripts/briefing.sh` | 15 / 25 / 35 / 50 | Raise all tiers if agents consistently hit turn limits; lower to reduce cost |
| `TIMEOUT` tier table | `scripts/briefing.sh` | 180 / 300 / 420 / 600 s | Raise if agents time out on large repos; lower to fail fast |
| Collector timeout | `scripts/briefing.sh` | `timeout 10` per collector | Raise on slow disks or large git histories |
| Git lookback window | `collectors/git.sh` | `--since="14 days ago"` | Widen for bugs in older code; narrow for speed |
| Error grep line limit | `collectors/errors.sh` | `head -50` per error string | Raise if context is being truncated; lower to save tokens |
| File count tier boundaries | `scripts/briefing.sh` | 100 / 500 / 2000 | Adjust to match your typical repo sizes |

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

| Parameter | Location | Default | Effect |
|---|---|---|---|
| `--max-turns` | `scripts/orchestrator.sh` (set from briefing metadata) | 15–50 (tier-based) | More turns = deeper investigation, more tokens, higher cost. Primary lever for quality vs speed |
| `CLAUDE_TIMEOUT` | `scripts/orchestrator.sh` | 180–600 s (tier-based) | Hard wall-clock limit. Set slightly above `MAX_TURNS × avg-seconds-per-turn` |
| Minimum hypotheses | `prompts/diagnosis.md` | 2 | Raise to 3 for ambiguous bugs; costs 1–2 extra turns |
| Confidence stop threshold | `prompts/diagnosis.md` | `> 0.7` | Lower to get faster (shallower) diagnoses; raise for higher certainty before stopping |
| Checkpoint trigger | `prompts/diagnosis.md` | after 10 files examined | Lower for faster recovery on timeout; raise to reduce write overhead |
| Progressive narrowing depth | `prompts/diagnosis.md` | max 3 call-chain levels | Raise for deeply nested codebases; lower to keep focus |
| Self-critique count | `prompts/diagnosis.md` | 3 ways hypothesis could be wrong | Raise for higher-stakes bugs; each adds ~0.5 turns |
| Model | `scripts/claude_json.sh` | default (claude-sonnet-4-6) | Switch to claude-opus-4-7 for highest quality; claude-haiku-4-5 for speed/cost |
| Checkpoint recovery confidence override | `scripts/orchestrator.sh` | 0.4 | If checkpoint is used after timeout, this is the confidence stamped on the output |

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

| Parameter | Location | Default | Effect |
|---|---|---|---|
| `--max-turns` | `scripts/orchestrator.sh` | 1 | Single-pass by design. Raise to 3 if agent needs to re-read files before producing diff |
| `CLAUDE_TIMEOUT` | `scripts/orchestrator.sh` | 180 s | Raise if large files cause slow reads |
| NO_FIX confidence threshold | `prompts/solution.md` | `< 0.5` | Raise (e.g. `< 0.65`) to be more conservative about suggesting fixes when diagnosis is uncertain |
| Fix scope instruction | `prompts/solution.md` | "one focused fix" | Can add "list up to 2 alternate fixes" to get multiple options |
| Risk labelling guidance | `prompts/solution.md` | low/medium/high descriptions | Tighten definitions if risk labels are inconsistent across runs |
| Model | `scripts/claude_json.sh` | default (claude-sonnet-4-6) | Switch to claude-opus-4-7 for better diffs on complex logic |

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

| Parameter | Location | Default | Effect |
|---|---|---|---|
| `--max-turns` | `scripts/orchestrator.sh` | 15 | Raise for complex test writing or multi-file fixes; lower to reduce cost |
| `CLAUDE_TIMEOUT` | `scripts/orchestrator.sh` | 300 s | Raise if test suite is slow; lower to fail fast |
| Test execution timeout | `prompts/validation.md` / orchestrator | 120 s | Raise for large test suites; lower for fast unit-test repos |
| New test count | `prompts/validation.md` | "exactly one focused test" | Change to "up to 2 tests" if the bug scenario has multiple entry points |
| Test label | `prompts/validation.md` | `GENERATED_BUT_NOT_VERIFIED` | Change to trigger red-green verification when that stretch goal is implemented |
| `RCA_MAS_KEEP_WORKTREE` | env var | unset (removes worktree) | Set to `1` to keep worktree for manual inspection after run |
| Model | `scripts/claude_json.sh` | default (claude-sonnet-4-6) | Switch to claude-opus-4-7 for better test generation |

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
  │     removes: worktree (unless RCA_MAS_KEEP_WORKTREE=1)
  │
  └── [report.sh]
        reads:  diagnosis.json, solution.json, validation.json
        writes: report.md
```

---

## All Tunable Parameters — Quick Reference

This table consolidates every parameter you are likely to adjust. All confidence values are floats 0.0–1.0.

### Turn and timeout budgets

| Parameter | File | Default | Notes |
|---|---|---|---|
| `MAX_TURNS` (< 100 files) | `scripts/briefing.sh` | 15 | |
| `MAX_TURNS` (100–500 files) | `scripts/briefing.sh` | 25 | |
| `MAX_TURNS` (500–2000 files) | `scripts/briefing.sh` | 35 | |
| `MAX_TURNS` (> 2000 files) | `scripts/briefing.sh` | 50 | |
| `TIMEOUT` (< 100 files) | `scripts/briefing.sh` | 180 s | |
| `TIMEOUT` (100–500 files) | `scripts/briefing.sh` | 300 s | |
| `TIMEOUT` (500–2000 files) | `scripts/briefing.sh` | 420 s | |
| `TIMEOUT` (> 2000 files) | `scripts/briefing.sh` | 600 s | |
| Agent 2 `--max-turns` | `scripts/orchestrator.sh` | 1 | |
| Agent 2 `CLAUDE_TIMEOUT` | `scripts/orchestrator.sh` | 180 s | |
| Agent 2.5 `--max-turns` | `scripts/orchestrator.sh` | 15 | |
| Agent 2.5 `CLAUDE_TIMEOUT` | `scripts/orchestrator.sh` | 300 s | |
| Agent 2.5 test exec timeout | `prompts/validation.md` | 120 s | `timeout 120 $TEST_COMMAND` |

### Confidence thresholds

| Parameter | File | Default | Effect |
|---|---|---|---|
| Agent 1 stop threshold | `prompts/diagnosis.md` | 0.7 | Stop early if confidence exceeds this after checkpoint |
| Checkpoint recovery override | `scripts/orchestrator.sh` | 0.4 | Confidence stamped when checkpoint is used after timeout |
| Agent 2 NO_FIX gate | `prompts/solution.md` | 0.5 | Return NO_FIX if `diagnosis.confidence` is below this |

### Search and investigation depth

| Parameter | File | Default | Effect |
|---|---|---|---|
| Git lookback window | `collectors/git.sh` | `--since="14 days ago"` | Widen for older bugs |
| Collector timeout | `scripts/briefing.sh` | 10 s each | Raise on slow disks |
| Error grep line limit | `collectors/errors.sh` | 50 lines per error string | Raise if key locations are being truncated |
| Call-chain depth limit | `prompts/diagnosis.md` | 3 levels | Raise for deeply nested code |
| Checkpoint file trigger | `prompts/diagnosis.md` | after 10 files examined | Lower for faster timeout recovery |
| Minimum hypotheses | `prompts/diagnosis.md` | 2 | Raise for ambiguous bugs |
| Self-critique items | `prompts/diagnosis.md` | 3 | Each adds ~0.5 turns |

### Model selection

| Agent | File | Default model | Upgrade to |
|---|---|---|---|
| Agent 1 | `scripts/claude_json.sh` | claude-sonnet-4-6 | claude-opus-4-7 for deeper reasoning |
| Agent 2 | `scripts/claude_json.sh` | claude-sonnet-4-6 | claude-opus-4-7 for complex diffs |
| Agent 2.5 | `scripts/claude_json.sh` | claude-sonnet-4-6 | claude-opus-4-7 for better test writing |

### Validation worktree

| Parameter | Location | Default | Effect |
|---|---|---|---|
| `RCA_MAS_KEEP_WORKTREE` | env var | unset | Set to `1` to inspect worktree after run |
| Worktree parent | `scripts/orchestrator.sh` | `../.rca-mas-worktrees/` | Change if repo is in a location where sibling dirs are not writable |
| New test count | `prompts/validation.md` | 1 | Raise if bug has multiple entry points |

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
| `manifest.json` | orchestrator | Run metadata, tool versions, mode |
| `bug.md` | orchestrator | Normalized bug input |
| `briefing.md` | briefing.sh | Repo map for Agent 1 |
| `errors.txt` | briefing.sh | Extracted error strings |
| `agent1_prompt.md` | orchestrator | Assembled Agent 1 prompt (debug) |
| `diagnosis.raw.json` | Agent 1 | Full Claude wrapper response |
| `diagnosis.json` | orchestrator | `.structured_output` extracted |
| `checkpoint.json` | Agent 1 | Mid-run state on timeout |
| `agent2_prompt.md` | orchestrator | Assembled Agent 2 prompt (debug) |
| `solution.raw.json` | Agent 2 | Full Claude wrapper response |
| `solution.json` | orchestrator | `.structured_output` extracted |
| `patches/fix.diff` | orchestrator | Unified diff from solution |
| `agent25_prompt.md` | orchestrator | Assembled Agent 2.5 prompt (debug) |
| `validation.raw.json` | Agent 2.5 | Full Claude wrapper response |
| `validation.json` | orchestrator | `.structured_output` extracted |
| `patches/generated_test.diff` | Agent 2.5 | New test only |
| `patches/fix_and_test.diff` | Agent 2.5 | Fix + test combined |
| `report.md` | report.sh | Final developer-readable report |
| `log.jsonl` | orchestrator | Structured event log per stage |
| `agent1.log` | orchestrator | Agent 1 stderr |
| `agent2.log` | orchestrator | Agent 2 stderr |
| `agent25.log` | orchestrator | Agent 2.5 stderr |
