# RCA Compression MAS — Locked Architecture Reference

> **V1 ARCHITECTURE LOCKED.** Do not add new agents, folders, integrations, dashboards, databases, retry loops, or plugin systems before v1 delivery. Allowed changes: bug fixes, safer shell handling, clearer prompts, better report wording, config tuning, docs improvements.

---

## Purpose

RCA Compression MAS is a CLI tool that compresses developer bug investigation from 30–60 minutes into a 3–8 minute report. It reads a QA bug report, scans the repo with bash, asks Claude Code agents to diagnose and propose a fix, optionally validates that fix in a safe git worktree, and writes a developer-readable `report.md`.

Human always decides. The system never commits, pushes, deploys, or edits the main working tree.

---

## High-Level Design

### Problem

A QA tester finds a bug during manual testing and raises it on GitHub/JIRA. The developer spends 30–60 minutes reading the report, searching the codebase, tracing call chains, checking git history, forming a hypothesis, and verifying it. All under deadline.

### Solution

A CLI tool (`rca-mas.sh`) that reads the bug report, runs bash-based triage, then invokes Claude Code agents in sequence to produce a developer-ready root-cause report in 3–8 minutes.

### Design Principles

| Principle | Implementation |
|---|---|
| Safe by default | report-only mode never edits source files |
| Validation isolated | `--validate` uses git worktree only |
| All parameters in one place | `config/defaults.env` — override any value by exporting before running |
| Inspectable runs | every run has manifest, logs, raw outputs, final JSON, cost summary |
| Cost visible | `cost_summary.json` + Cost / Runtime section in every report |
| Claude Code only | no API-key design |
| Bash-first | bash + git + jq + Claude Code CLI |
| No overbuilding | no dashboard, database, PR automation, evaluator platform |

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
├── docs/
│   ├── index.md
│   ├── architecture.md           ← this file
│   ├── user-manual.md
│   ├── briefing-flow.md
│   ├── agent-flow.md
│   ├── validation-flow.md
│   ├── cost-and-runtime.md
│   ├── runbook.md
│   ├── troubleshooting.md
│   └── testing-real-github-bugs.md
├── examples/
│   ├── bug.md
│   └── sample-report.md
├── tests/
│   ├── fixtures/
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   └── test_smoke_report_only.sh
├── Makefile
├── README.md
├── CLAUDE.md
└── code_practices.md
```

---

## TOOL_ROOT vs TARGET_REPO_ROOT

The MAS runs from inside the repo being analyzed. These two paths must always be kept separate.

| Name | Meaning |
|---|---|
| `TOOL_ROOT` | where rca-mas scripts, prompts, and schemas live |
| `TARGET_REPO_ROOT` | the repo being analyzed (where you `cd` before running) |
| `RUN_DIR` | `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` |

Rules:
- Read scripts, prompts, schemas from `TOOL_ROOT`
- Run code search and git commands in `TARGET_REPO_ROOT`
- Write all outputs under `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}`
- Never scan RCA MAS source files when target repo is different

---

## Pipeline Overview

```
bug.md / GitHub issue
  │
  ▼
[Briefing]  ←── pure bash, 4 collectors, 0 LLM calls
  │ briefing.md  errors.txt  MAX_TURNS  TIMEOUT
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
[report.sh + cost_summary.json]  ←── bash, JSON → markdown
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
              writes:  cost_summary.json
              calls:   scripts/report.sh
                         reads: diagnosis.json, solution.json, validation.json, cost_summary.json
                         writes: report.md
```

---

## Component Details

### Briefing (bash, zero LLM)

**Role:** Orients Agent 1 before the agentic loop. Saves 8–12 turns of orientation.

**Inputs:** `bug.md`, `TARGET_REPO_ROOT`

**Outputs:** `briefing.md`, `errors.txt`

**What it does:**
- Regex-extracts file paths from `bug.md`, validates each (rejects traversal + secrets)
- Extracts quoted error strings, one per line to `errors.txt`
- Counts files via `git ls-files` (fallback: `find`) → selects tier
- Writes metadata header to `briefing.md`
- Runs 4 collectors with `timeout $RCA_COLLECTOR_TIMEOUT` each; continues on failure
- Deduplicates output with `awk`

**4 Collectors:**

| Collector | What it produces |
|---|---|
| `git.sh` | `git log` for mentioned files, recent merges, `git blame` |
| `deps.sh` | Import/require chains for mentioned files (Python, JS/TS, Go) |
| `errors.sh` | Fixed-string grep for every error string across full repo |
| `testrunner.sh` | Detected test command + src→test file mapping |

**Tunable parameters — all in `config/defaults.env`:**

| Variable | Default | What to change |
|---|---|---|
| `RCA_TURNS_XS/S/M/L` | 15 / 25 / 35 / 50 | Turn budgets per tier |
| `RCA_TIMEOUT_XS/S/M/L` | 180 / 300 / 420 / 600 s | Timeout per tier |
| `RCA_TIER_XS/S/M` | 100 / 500 / 2000 | File count breakpoints |
| `RCA_COLLECTOR_TIMEOUT` | 10 s | Raise on slow disks |
| `RCA_GIT_LOOKBACK` | `"14 days ago"` | Widen for older bugs |
| `RCA_ERROR_GREP_LIMIT` | 50 lines | Raise if locations are being truncated |

---

### Agent 1 — Diagnosis

**Role:** Senior QA engineer. Investigates the full codebase. Produces structured diagnosis with competing hypotheses and evidence.

**Prompt file:** `prompts/diagnosis.md`  
**Schema file:** `schemas/diagnosis.schema.json`

**Inputs (assembled into `agent1_prompt.md`):**
- `prompts/diagnosis.md`
- `briefing.md`
- `bug.md`

**Outputs:** `diagnosis.json`, `diagnosis.raw.json`, `checkpoint.json` (after 10 files)

**Output schema — required fields:**

```json
{
  "run_id": "string",
  "root_cause": "string",
  "selected_hypothesis_id": "string",
  "confidence": 0.0,
  "hypotheses": [
    {
      "id": "string",
      "summary": "string",
      "supporting_evidence": [{"type":"string","path":"string","lines":"string","note":"string"}],
      "contradicting_evidence": [...],
      "confidence": 0.0
    }
  ],
  "rejected_hypotheses": [{"id":"string","reason":"string"}],
  "affected_files": ["string"],
  "call_chain": ["string"],
  "files_examined": ["string"],
  "unknowns": ["string"],
  "introducing_commit": "string or null",
  "next_best_action": "string"
}
```

**Tool access:**
```
--tools "Read,Grep,Glob,Bash,Write"
--allowedTools: Read, Grep, Glob
  Bash(git log *), Bash(git blame *), Bash(git show *)
  Bash(git diff *), Bash(git status *)
  Bash(rg *), Bash(grep *), Bash(find *)
  Write(.rca-mas/runs/**)    ← checkpoint only
```

**Tunable parameters — all in `config/defaults.env` unless noted:**

| Variable / Prompt text | Location | Default | Effect |
|---|---|---|---|
| `RCA_TURNS_*` tiers | `config/defaults.env` | 15–50 | More turns = deeper investigation, more cost |
| `RCA_TIMEOUT_*` tiers | `config/defaults.env` | 180–600 s | Hard wall-clock limit |
| `RCA_CONFIDENCE_STOP` | `config/defaults.env` | 0.7 | Lower for faster/cheaper; raise for higher certainty |
| `RCA_CONFIDENCE_CHECKPOINT` | `config/defaults.env` | 0.4 | Stamped on output after timeout recovery |
| "at least 2" (hypotheses) | `prompts/diagnosis.md` | 2 | Raise to 3 for ambiguous bugs |
| "3 levels deep" (call chain) | `prompts/diagnosis.md` | 3 | Raise for deeply nested code |
| "10 files" (checkpoint) | `prompts/diagnosis.md` | 10 | Lower for faster timeout recovery |
| "3 ways" (self-critique) | `prompts/diagnosis.md` | 3 | Raise for higher-stakes bugs |
| `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents |

---

### Agent 2 — Solution

**Role:** Senior software engineer. Reads diagnosis + affected code. Produces one focused unified diff. Single pass, read-only.

**Prompt file:** `prompts/solution.md`  
**Schema file:** `schemas/solution.schema.json`

**Inputs (assembled into `agent2_prompt.md`):**
- `prompts/solution.md`
- `diagnosis.json`
- Source of each file in `diagnosis.affected_files`
- `## Dependencies` section from `briefing.md`

**Outputs:** `solution.json`, `solution.raw.json`, `patches/fix.diff`

**Output schema — required fields:**
```json
{
  "run_id": "string",
  "recommendation": "FIX | NO_FIX",
  "no_fix_reason": "string or null",
  "recommended_fix_id": "string or null",
  "fixes": [{
    "id": "string",
    "description": "string",
    "why_this_fixes_root_cause": "string",
    "unified_diff": "string",
    "affected_files": ["string"],
    "risk": "low | medium | high",
    "expected_tests": ["string"],
    "manual_review_notes": ["string"]
  }]
}
```

**Tool access:** `--tools "Read,Grep,Glob"` — no Bash, no Write.

**Tunable parameters:**

| Variable / Prompt text | Location | Default | Effect |
|---|---|---|---|
| `RCA_AGENT2_TURNS` | `config/defaults.env` | 1 | Raise to 3 only if agent needs file re-reads |
| `RCA_AGENT2_TIMEOUT` | `config/defaults.env` | 180 s | Raise if large files cause slow reads |
| `RCA_CONFIDENCE_NOFX` | `config/defaults.env` | 0.5 | Raise to 0.65 to be more conservative |
| "exactly one fix" | `prompts/solution.md` | 1 | Change to "up to 2" for multiple options |
| `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents |

---

### Agent 2.5 — Validation (optional)

**Role:** Basic safety check. Runs only with `--validate`. Operates exclusively inside a git worktree sibling to the repo.

**Prompt file:** `prompts/validation.md`  
**Schema file:** `schemas/validation.schema.json`

**Worktree location:** `RCA_WORKTREE_DIR/{RUN_ID}` (default: `../.rca-mas-worktrees/{RUN_ID}`)

**7-step process:**
1. Code review — logic errors in the fix
2. Create worktree (`git worktree add`)
3. Apply fix (`git apply`)
4. Run existing tests (`timeout $RCA_AGENT25_TEST_TIMEOUT $TEST_COMMAND`)
5. Write one regression test for the QA-reported scenario
6. Run new test
7. Save diffs, remove worktree

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
| `NOT_RUN_NO_COMMAND` | no test runner detected |

**Tool access:**
```
--tools "Read,Grep,Glob,Edit,Bash"
--allowedTools: Bash(git status *), Bash(git diff *), Bash(git apply *)
  Bash(pytest *), Bash(python -m pytest *), Bash(poetry run pytest *)
  Bash(npm test *), Bash(npm run test *), Bash(pnpm test *), Bash(yarn test *)
  Bash(npx vitest *), Bash(npx jest *), Bash(go test *), Bash(make test *)
```

**Tunable parameters:**

| Variable / Prompt text | Location | Default | Effect |
|---|---|---|---|
| `RCA_AGENT25_TURNS` | `config/defaults.env` | 15 | Raise for complex test writing |
| `RCA_AGENT25_TIMEOUT` | `config/defaults.env` | 300 s | Raise if test suite is slow |
| `RCA_AGENT25_TEST_TIMEOUT` | `config/defaults.env` | 120 s | Raise for large test suites |
| `RCA_KEEP_WORKTREE` | `config/defaults.env` | 0 | Set to 1 to inspect worktree after run |
| `RCA_WORKTREE_DIR` | `config/defaults.env` | `../.rca-mas-worktrees` | Change if sibling dir not writable |
| `RCA_MODEL` | `config/defaults.env` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents |

---

## Cost and Runtime Architecture

v1 does not hardcode exact dollar pricing. Cost visibility is implemented through lightweight bookkeeping.

### `cost_summary.json`

Written by orchestrator after all stages complete. One `jq` call per stage to record duration.

```json
{
  "run_id": "string",
  "mode": "report-only | validate",
  "model": "claude-sonnet-4-6 or override",
  "repo_tier": "XS | S | M | L",
  "agent1_max_turns": 25,
  "agent1_turns_used": 18,
  "agent2_max_turns": 1,
  "stage_durations_seconds": {
    "briefing": 3,
    "agent1": 142,
    "agent2": 34,
    "validation": 0,
    "report": 1
  },
  "total_duration_seconds": 180,
  "validation_run": false,
  "token_counts": {
    "agent1_input": null,
    "agent1_output": null,
    "agent2_input": null,
    "agent2_output": null,
    "note": "populated if Claude raw output exposes usage fields; null otherwise"
  },
  "cost_level": "LOW | MEDIUM | HIGH",
  "authoritative": false,
  "note": "No exact dollar pricing. Cost level is relative: LOW=XS/S tier + <20 turns, HIGH=L tier or opus model or >35 turns, MEDIUM=everything else."
}
```

**Token counts:** Extracted from `*.raw.json` via one `jq` call if Claude's wrapper exposes them. Never fail the pipeline if absent — fields remain `null`.

**Cost level logic:**
- `LOW` — XS or S tier, agent1_turns_used < 20, no validation
- `HIGH` — L tier, OR agent1_turns_used > 35, OR opus model used
- `MEDIUM` — everything else

### Cost warning config variables

| Variable | Default | Effect |
|---|---|---|
| `RCA_COST_WARN_SECONDS` | 480 | Log warning if total runtime exceeds this |
| `RCA_COST_WARN_AGENT1_TURNS` | 40 | Log warning if Agent 1 uses more turns than this |

### Cost drivers

| Driver | Control |
|---|---|
| Agent 1 depth | `RCA_TURNS_*`, `RCA_TIMEOUT_*` in defaults.env |
| Model choice | `RCA_MODEL` in defaults.env |
| Validation | `--validate` flag |
| Repo size | file-count tier (automatic) |
| Collector output size | `RCA_ERROR_GREP_LIMIT` in defaults.env |

---

## Data Flow

```
bug.md
  │
  ├── [briefing.sh]
  │     extracts: MENTIONED_FILES, ERROR_STRINGS
  │     computes: FILE_COUNT → MAX_TURNS, TIMEOUT tier
  │     runs: git.sh, deps.sh, errors.sh, testrunner.sh
  │     writes: briefing.md, errors.txt
  │
  ├── [Agent 1]
  │     reads:  agent1_prompt.md = diagnosis.md + briefing.md + bug.md
  │     writes: diagnosis.raw.json → diagnosis.json (.structured_output extracted)
  │             checkpoint.json (mid-run, after 10 files)
  │     key fields downstream:
  │       .confidence       → Agent 2 NO_FIX gate
  │       .affected_files   → Agent 2 context
  │       .root_cause       → report
  │
  ├── [Agent 2]
  │     reads:  agent2_prompt.md = solution.md + diagnosis.json + affected file sources + deps
  │     writes: solution.raw.json → solution.json
  │             patches/fix.diff (from solution.unified_diff)
  │     key fields downstream:
  │       .recommendation   → validation skip gate
  │       .unified_diff     → patches/fix.diff
  │       .risk             → report
  │
  ├── [Agent 2.5 — --validate only]
  │     creates: worktree at RCA_WORKTREE_DIR/{RUN_ID}
  │     applies: patches/fix.diff
  │     runs:   $TEST_COMMAND
  │     writes: validation.raw.json → validation.json
  │             patches/fix_and_test.diff
  │             patches/generated_test.diff
  │     removes: worktree (unless RCA_KEEP_WORKTREE=1)
  │
  ├── [orchestrator writes cost_summary.json]
  │     records: stage durations, model, tier, turns used
  │     extracts: token_counts from *.raw.json if available
  │
  └── [report.sh]
        reads:  diagnosis.json, solution.json, validation.json, cost_summary.json
        writes: report.md (11 sections)
```

---

## All Tunable Parameters — Quick Reference

**All parameters live in `config/defaults.env`.** Override by exporting before running:
```bash
RCA_MODEL=claude-opus-4-7 RCA_TURNS_L=70 ./rca-mas.sh bug.md
```

### Turn and timeout budgets

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
| `RCA_TIER_XS/S/M` | 100 / 500 / 2000 | file count breakpoints |
| `RCA_AGENT2_TURNS` | 1 | Agent 2 max turns |
| `RCA_AGENT2_TIMEOUT` | 180 s | Agent 2 wall-clock limit |
| `RCA_AGENT25_TURNS` | 15 | Agent 2.5 max turns |
| `RCA_AGENT25_TIMEOUT` | 300 s | Agent 2.5 wall-clock limit |
| `RCA_AGENT25_TEST_TIMEOUT` | 120 s | Test execution timeout inside worktree |

### Confidence thresholds

| Variable | Default | Effect |
|---|---|---|
| `RCA_CONFIDENCE_STOP` | 0.7 | Agent 1 stops early when confidence exceeds this |
| `RCA_CONFIDENCE_CHECKPOINT` | 0.4 | Stamped on output when checkpoint recovery is used |
| `RCA_CONFIDENCE_NOFX` | 0.5 | Agent 2 returns NO_FIX if below this |

### Search and investigation depth

| Variable / Prompt text | Location | Default | Effect |
|---|---|---|---|
| `RCA_GIT_LOOKBACK` | defaults.env | `"14 days ago"` | Widen for older bugs |
| `RCA_COLLECTOR_TIMEOUT` | defaults.env | 10 s | Raise on slow disks |
| `RCA_ERROR_GREP_LIMIT` | defaults.env | 50 lines | Raise if locations truncated |
| "3 levels deep" | `prompts/diagnosis.md` | 3 | Raise for deeply nested code |
| "10 files" (checkpoint) | `prompts/diagnosis.md` | 10 | Lower for faster timeout recovery |
| "at least 2" (hypotheses) | `prompts/diagnosis.md` | 2 | Raise for ambiguous bugs |
| "3 ways" (self-critique) | `prompts/diagnosis.md` | 3 | Raise for high-stakes bugs |

### Model

| Variable | Default | Options |
|---|---|---|
| `RCA_MODEL` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents; `claude-haiku-4-5-20251001` for speed |

One variable controls all 3 agents.

### Cost warnings

| Variable | Default | Effect |
|---|---|---|
| `RCA_COST_WARN_SECONDS` | 480 | Log warning if total runtime exceeds this |
| `RCA_COST_WARN_AGENT1_TURNS` | 40 | Log warning if Agent 1 uses more turns than this |

### Validation worktree

| Variable | Default | Effect |
|---|---|---|
| `RCA_KEEP_WORKTREE` | 0 | Set to 1 to keep worktree after run |
| `RCA_WORKTREE_DIR` | `../.rca-mas-worktrees` | Change if sibling dir not writable |

---

## Context Funnel

Each agent receives less context than the previous. Prevents context pollution.

```
Agent 1   full repo access + briefing.md (~10K+ tokens)
  │
  ▼  passes only diagnosis.json (clean structured summary)
  │
Agent 2   diagnosis.json + affected file sources + deps (~5K tokens)
  │
  ▼  passes diagnosis + solution
  │
Agent 2.5 diagnosis.json + solution.json + affected file sources (~4K tokens)
```

Agent 2 never sees Agent 1's 30K tokens of exploration.

---

## Graceful Degradation

Every failure is a warning, not a crash. Pipeline always continues and surfaces degradation in report.

| Failure | Behavior |
|---|---|
| Collector fails | Log warning in `log.jsonl`; section left empty; Agent 1 cold-starts |
| Agent 1 timeout + checkpoint exists | Use checkpoint; stamp confidence 0.4; continue |
| Agent 1 timeout + no checkpoint | Emit `root_cause: "UNKNOWN"`, confidence 0.0 |
| Agent 1 invalid JSON | Save raw, log error, skip Agent 2 |
| `diagnosis.confidence < RCA_CONFIDENCE_NOFX` | Agent 2 returns NO_FIX; skip validation |
| Agent 2 empty/malformed diff | Warn in report; skip validation |
| No test runner detected | Validation reports `NOT_RUN_NO_COMMAND`; still writes test diff |
| Token counts absent in raw JSON | `cost_summary.token_counts` fields set to null; pipeline continues |
| All stages fail | `report.md` still written; shows what failed and why |

---

## Security Boundaries

- Never reads `.env`, `.pem`, `.key`, `id_rsa`, or credential files
- Never runs network commands (`curl`, `wget`, `ssh`, `scp`)
- Never writes outside `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` except inside validation worktree
- Never commits, pushes, deploys, tags, or opens PRs
- Never installs dependencies
- Bug report is always treated as untrusted input — prompt injection defence in every agent prompt
- `.claude/settings.json` enforces deny rules at the Claude Code permission level

---

## Run Artifacts

Every run writes to `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/`. `latest` symlink always points to most recent run.

| File | Written by | Always present? |
|---|---|---|
| `manifest.json` | orchestrator | yes |
| `cost_summary.json` | orchestrator | yes |
| `bug.md` | orchestrator | yes |
| `issue.json` | orchestrator | only with `--issue` |
| `briefing.md` | briefing.sh | yes |
| `errors.txt` | briefing.sh | yes |
| `agent1_prompt.md` | orchestrator | yes |
| `diagnosis.raw.json` | Agent 1 | yes |
| `diagnosis.json` | orchestrator | yes |
| `checkpoint.json` | Agent 1 | only on timeout |
| `agent2_prompt.md` | orchestrator | yes |
| `solution.raw.json` | Agent 2 | yes |
| `solution.json` | orchestrator | yes |
| `patches/fix.diff` | orchestrator | if recommendation=FIX |
| `agent25_prompt.md` | orchestrator | only with `--validate` |
| `validation.raw.json` | Agent 2.5 | only with `--validate` |
| `validation.json` | orchestrator | yes (SKIPPED if report-only) |
| `patches/generated_test.diff` | Agent 2.5 | only with `--validate` |
| `patches/fix_and_test.diff` | Agent 2.5 | only with `--validate` |
| `report.md` | report.sh | yes |
| `log.jsonl` | orchestrator | yes |
| `agent1.log` | orchestrator | yes |
| `agent2.log` | orchestrator | yes |
| `agent25.log` | orchestrator | only with `--validate` |

### `manifest.json` fields

| Field | Purpose |
|---|---|
| `run_id` | unique run identifier |
| `mode` | `report-only` or `validate` |
| `tool_root` | absolute path to rca-mas installation |
| `target_repo_root` | absolute path to repo being analyzed |
| `repo_remote_url` | git remote origin URL |
| `git_head_sha` | exact code state at time of run |
| `git_branch` | current branch |
| `bug_source` | `file` or `github_issue` |
| `bug_source_file` | path to the bug.md used |
| `issue_url` | GitHub issue URL (only with `--issue`) |
| `expected_fix_commit` | set via `EXPECTED_FIX_SHA=abc ./rca-mas.sh bug.md` — for comparing against known fix |
| `started_at` | ISO 8601 |
| `ended_at` | ISO 8601 or null if run crashed |
| `stage_statuses` | `{briefing, agent1, agent2, validation, report}` — updated as each completes |
| `stage_durations_seconds` | wall-clock seconds per stage |
| `cost_summary` | path to `cost_summary.json` |
| `tool_versions` | claude, git, jq, gh versions |

---

## Report Contract

`report.md` must include all 11 sections:

1. Status
2. Root Cause
3. Confidence
4. Evidence
5. Affected Files
6. Proposed Fix
7. Patch Files
8. Validation
9. Cost / Runtime
10. Unknowns / Risks
11. Next Action

Report must not hide uncertainty. If a stage degraded, the report must say so.

---

## docs/ Contents

All 10 docs are required deliverables.

| Doc | Purpose |
|---|---|
| `docs/index.md` | Reading order, one-line summary of each doc |
| `docs/architecture.md` | This file — locked architecture reference |
| `docs/user-manual.md` | Practical usage: prerequisites, first run, reading the report, config tuning, cleanup |
| `docs/briefing-flow.md` | `briefing.sh` + 4 collectors: inputs, outputs, failure behaviour, tier table |
| `docs/agent-flow.md` | Agent 1 + 2 + 2.5: roles, tool restrictions, schemas, confidence rules |
| `docs/validation-flow.md` | Worktree lifecycle, patch application, test generation, cleanup |
| `docs/cost-and-runtime.md` | Cost drivers, how to read `cost_summary.json`, cost_level meaning, token count caveats |
| `docs/runbook.md` | How to run, all CLI flags, env var overrides, output files, debug process |
| `docs/troubleshooting.md` | Common failures with exact fixes: not logged in, jq error, empty diagnosis, timeout |
| `docs/testing-real-github-bugs.md` | Step-by-step guide for testing against real repos with known fix commits |

---

## Architecture Lock Rules

Architecture is locked for v1.

**Allowed without approval:**
- Safer shell handling
- Bug fixes
- Clearer prompts
- Better report wording
- Better docs
- Config tuning
- Small tests for planned behaviour

**Not allowed without explicit approval:**
- New agents
- New folders beyond the approved structure
- Dashboard or web UI
- Database
- PR creation or auto-commit/push
- Full eval platform
- Retry/evaluator loops
- JIRA or Slack integration
- Any new external dependency
