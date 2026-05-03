# RCA Compression MAS — Locked v1 Build Plan

> **LOCKED.** Architecture and plan are approved for v1 implementation. Do not add new agents, folders, integrations, dashboards, databases, retry loops, or plugin systems before v1 delivery. Allowed changes: bug fixes, safer shell handling, clearer prompts, better report wording, config tuning, docs improvements.

---

## What We're Building

A CLI tool that compresses a 30–60 minute bug investigation into a 3–8 minute automated report. A QA tester finds a bug, raises a GitHub issue or writes a `bug.md`, runs one command, and a developer gets a structured report showing root cause, evidence, a proposed fix diff, and what to do next.

```bash
./rca-mas.sh bug.md
cat .rca-mas/runs/latest/report.md
```

**Scope:** Production-ready v1 in 1.5 weeks, 2 hours/day. Bash + git + jq + Claude Code CLI. No API keys, no dashboards, no databases. Agent 2.5 (validation) is built last and cut first if time runs short. Core = Agent 1 + Agent 2 + report.

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
│   ├── diagnosis.md              ← Agent 1 full instructions
│   ├── solution.md               ← Agent 2 full instructions
│   └── validation.md             ← Agent 2.5 instructions (optional v1)
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── docs/
│   ├── index.md
│   ├── architecture.md
│   ├── user-manual.md            ← practical usage guide for new users
│   ├── briefing-flow.md
│   ├── agent-flow.md
│   ├── validation-flow.md
│   ├── cost-and-runtime.md       ← cost drivers, runtime controls, how to read cost_summary.json
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

**lib/ rule:** Only 4 files. Only for logic used across 3+ scripts. Not a framework.

---

## Important Path Rule

The MAS runs from inside the target repo being analyzed. Implementation must separate:

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

## How the Files Connect

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
                         reads: diagnosis.json, solution.json, validation.json, cost_summary.json
                         writes: report.md
```

---

## Every File — What It Is and How to Change It

### `config/defaults.env`

**The only file you need to touch to change agent behaviour.** Every tunable parameter lives here. Override any value by exporting before running:

```bash
RCA_MODEL=claude-opus-4-7 ./rca-mas.sh bug.md
```

| Variable | Default | What it controls |
|---|---|---|
| `RCA_TURNS_XS/S/M/L` | 15 / 25 / 35 / 50 | Max turns for Agent 1 by repo size |
| `RCA_TIMEOUT_XS/S/M/L` | 180 / 300 / 420 / 600 s | Wall-clock limit for Agent 1 by repo size |
| `RCA_TIER_XS/S/M` | 100 / 500 / 2000 | File count breakpoints for tier selection |
| `RCA_AGENT2_TURNS` | 1 | Max turns for Agent 2 (keep at 1) |
| `RCA_AGENT2_TIMEOUT` | 180 s | Wall-clock limit for Agent 2 |
| `RCA_AGENT25_TURNS` | 15 | Max turns for Agent 2.5 |
| `RCA_AGENT25_TIMEOUT` | 300 s | Wall-clock limit for Agent 2.5 |
| `RCA_AGENT25_TEST_TIMEOUT` | 120 s | Timeout for running tests inside worktree |
| `RCA_CONFIDENCE_STOP` | 0.7 | Agent 1 stops early if confidence exceeds this |
| `RCA_CONFIDENCE_NOFX` | 0.5 | Agent 2 returns NO_FIX if confidence is below this |
| `RCA_CONFIDENCE_CHECKPOINT` | 0.4 | Confidence stamped on output when using checkpoint recovery |
| `RCA_GIT_LOOKBACK` | `"14 days ago"` | How far back `git.sh` looks for history |
| `RCA_ERROR_GREP_LIMIT` | 50 | Lines per error string in `errors.sh` |
| `RCA_COLLECTOR_TIMEOUT` | 10 s | Timeout per collector script |
| `RCA_OUTPUT_DIR` | `.rca-mas` | Where all run output goes |
| `RCA_WORKTREE_DIR` | `../.rca-mas-worktrees` | Parent for validation worktrees |
| `RCA_KEEP_WORKTREE` | 0 | Set to 1 to keep worktree after `--validate` for inspection |
| `RCA_MODEL` | (empty = sonnet-4-6) | Override model for all agents (e.g. `claude-opus-4-7`) |
| `RCA_COST_WARN_SECONDS` | 480 | Log a warning if total runtime exceeds this |
| `RCA_COST_WARN_AGENT1_TURNS` | 40 | Log a warning if Agent 1 uses more turns than this |

---

### `lib/log.sh`

Provides three functions used by every script:
- `log_event level stage msg [key=value ...]` — writes a JSON line to `log.jsonl`
- `info "..."` — prints `[rca-mas] ...` to stderr (visible in terminal)
- `warn "..."` — prints `[rca-mas] WARNING: ...` to stderr
- `die "..."` — prints error to stderr and exits 1

**To change the log format:** Edit the `printf` pattern inside `log_event`.

---

### `lib/json.sh`

Three jq helpers so jq calls are not scattered across scripts:
- `extract_structured raw_file out_file` — extracts `.structured_output` from Claude's JSON wrapper; falls back to `.result` if null
- `jq_field file query` — reads one field safely; returns empty string if missing (never errors)
- `assert_valid_json file label` — calls `die` if the file is not valid JSON

---

### `lib/paths.sh`

Three functions:
- `make_run_id` — generates `<timestamp>-<short-sha>` (e.g. `1746180000-a3f7c1`)
- `init_run_dir run_id` — creates `.rca-mas/runs/<run_id>/patches/` and exports all canonical path variables (`$DIAGNOSIS`, `$SOLUTION`, `$REPORT`, `$COST_SUMMARY`, etc.)
- `update_latest_symlink` — points `.rca-mas/runs/latest` to the current run

**To change output location:** Change `RCA_OUTPUT_DIR` in `config/defaults.env`.

---

### `lib/cleanup.sh`

- `register_worktree path` — records which worktree to clean up
- `run_cleanup` — called by `trap ... EXIT`; removes the worktree unless `RCA_KEEP_WORKTREE=1`

---

### `rca-mas.sh`

Entry point. Thin: sources config + log lib, parses CLI args, checks prerequisites, exports variables, `exec`s orchestrator.

**Flags:**
```
./rca-mas.sh <bug.md>                     # report-only (safe, never edits code)
./rca-mas.sh <bug.md> --validate          # validate fix in isolated worktree
./rca-mas.sh --issue <NUM>                # fetch GitHub issue
./rca-mas.sh --issue <NUM> --repo <slug>  # with explicit repo
./rca-mas.sh --help
```

**To add a flag:** Add a `case` block, export the variable, handle it in orchestrator.

---

### `Makefile`

```
make lint          # bash -n + shellcheck on all scripts
make test          # run all 4 test scripts (no Claude required)
make run           # ./rca-mas.sh examples/bug.md
make run-validate  # ./rca-mas.sh examples/bug.md --validate
make report        # cat .rca-mas/runs/latest/report.md
make clean         # rm -rf .rca-mas/runs .rca-mas-worktrees
```

Override bug file: `make run BUG=path/to/my-bug.md`

---

### `scripts/orchestrator.sh`

Pipeline controller. Owns the run lifecycle from start to finish.

**What it does in order:**
1. Sources all lib files, sets `TOOL_ROOT` and `TARGET_REPO_ROOT`
2. Registers `trap run_cleanup EXIT`
3. Generates `RUN_ID`, calls `init_run_dir`
4. Writes `manifest.json`
5. Updates latest symlink
6. Resolves input (copies bug.md or fetches GitHub issue)
7. Records stage start time → calls `briefing.sh` → records duration, updates `stage_statuses`
8. Records stage start time → calls Agent 1 → handles timeout + checkpoint recovery → records duration, updates `stage_statuses`
9. Records stage start time → calls Agent 2 → handles NO_FIX gate, extracts `patches/fix.diff` → records duration
10. Writes skipped `validation.json` (report-only) OR calls Agent 2.5 (--validate)
11. Writes `cost_summary.json`
12. Calls `report.sh`
13. Writes `ended_at` to manifest
14. Prints report path

**`manifest.json` fields:**

| Field | Value |
|---|---|
| `run_id` | `<timestamp>-<sha>` |
| `mode` | `report-only` or `validate` |
| `tool_root` | absolute path to rca-mas installation |
| `target_repo_root` | absolute path to repo being analyzed |
| `repo_remote_url` | `git remote get-url origin` |
| `git_head_sha` | HEAD SHA at time of run |
| `git_branch` | current branch |
| `bug_source` | `file` or `github_issue` |
| `bug_source_file` | path to the bug.md used |
| `issue_url` | GitHub issue URL (if `--issue`) |
| `expected_fix_commit` | set via `EXPECTED_FIX_SHA=abc ./rca-mas.sh bug.md` |
| `started_at` | ISO 8601 |
| `ended_at` | ISO 8601 (null if run crashed) |
| `stage_statuses` | `{briefing, agent1, agent2, validation, report}` — updated as each completes |
| `stage_durations_seconds` | `{briefing, agent1, agent2, validation, report}` — wall-clock seconds per stage |
| `cost_summary` | path to `cost_summary.json` |
| `tool_versions` | claude, git, jq, gh versions |

---

### Cost and Runtime — `cost_summary.json`

Written by orchestrator after all stages complete. Stored at `RUN_DIR/cost_summary.json`.

```json
{
  "run_id": "...",
  "mode": "report-only | validate",
  "model": "claude-sonnet-4-6 or override value",
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
  "note": "No exact dollar pricing. Cost level is relative based on model, tier, and turns used."
}
```

**Token counts:** Extracted from `*.raw.json` via one `jq` call if Claude's wrapper exposes them. Stored as-is. If absent, fields are `null` — the file is still written and the pipeline never fails because of missing token data.

**Cost level logic (in orchestrator):**
- `LOW` — XS/S tier, turns used < 20, no validation
- `HIGH` — L tier, OR turns used > 35, OR opus model
- `MEDIUM` — everything else

**`report.md` Cost / Runtime section** reads from `cost_summary.json`:
```
## Cost / Runtime
Model: claude-sonnet-4-6  |  Repo tier: S (340 files)  |  Total: 180s
Agent 1: 18/25 turns, 142s  |  Agent 2: 1/1 turns, 34s  |  Validation: skipped
Cost level: LOW  (non-authoritative — see docs/cost-and-runtime.md)
```

**Two new config variables for cost warnings:**
- `RCA_COST_WARN_SECONDS=480` — warn if total runtime exceeds this
- `RCA_COST_WARN_AGENT1_TURNS=40` — warn if Agent 1 uses this many turns

---

### `scripts/briefing.sh`

Pure bash. Zero LLM calls. Runs in ~2 seconds. Gives Agent 1 a head start instead of wasting 8–12 turns on orientation.

**What it produces:**
- `briefing.md` — metadata header + 4 collector sections
- `errors.txt` — extracted quoted error strings

**How it works:**
1. Extracts file paths from bug report using regex; validates each (rejects traversal + secrets)
2. Extracts quoted error strings (`"..."` with 5–80 chars)
3. Counts files via `git ls-files | wc -l` → selects `MAX_TURNS` and `TIMEOUT` tier
4. Writes metadata header to `briefing.md`
5. Runs each collector with `timeout $RCA_COLLECTOR_TIMEOUT`; on failure: logs warning and continues
6. Deduplicates output with `awk '!seen[$0]++'`

**To tune:** All tier values and timeouts are in `config/defaults.env`.

---

### Collectors

**`collectors/git.sh`** — `git log`, `git blame`, recent merges for mentioned files. Tune: `RCA_GIT_LOOKBACK`.

**`collectors/deps.sh`** — import/require tracing for Python, JS/TS, Go. Add an `elif` block to support more languages.

**`collectors/errors.sh`** — fixed-string grep for extracted error strings. `|| true` required everywhere. Tune: `RCA_ERROR_GREP_LIMIT`.

**`collectors/testrunner.sh`** — detects test command, maps src→test files by convention. Add detection before the `UNKNOWN` fallback.

---

### JSON Schemas

Three files in `schemas/`. Passed via `--json-schema`. `additionalProperties: false` on every object.

**`diagnosis.schema.json`** — required: `run_id`, `root_cause`, `selected_hypothesis_id`, `hypotheses[]`, `rejected_hypotheses[]`, `affected_files[]`, `call_chain[]`, `files_examined[]`, `unknowns[]`, `confidence`(0–1), `introducing_commit`(nullable), `next_best_action`

**`solution.schema.json`** — required: `run_id`, `recommendation`(FIX|NO_FIX), `no_fix_reason`, `recommended_fix_id`, `fixes[]` with `unified_diff`, `risk`(low|medium|high), `expected_tests[]`

**`validation.schema.json`** — required: `run_id`, `status`(7-value enum), `applied_patch`, `generated_test`, `test_command`, `commands_run[]`, `failures[]`, `regression_risk`, `notes[]`

**To add a field:** Add to `properties` + `required`. Done.

---

### `scripts/claude_json.sh`

Single function `run_claude_schema()` used by all 3 agents. The only file to change if swapping APIs.

**Function signature:**
```bash
run_claude_schema prompt_file schema_file raw_file final_file max_turns tools [allow_rules...]
```

**What it does:**
1. Builds `claude` command with `--output-format json`, `--json-schema`, `--max-turns`, `--tools`, optional `--model`, optional `--allowedTools`
2. Pipes prompt via stdin (not `-p "$(cat ...)"` — avoids shell arg size limits)
3. Saves full Claude wrapper to `raw_file`
4. Extracts `.structured_output` → `final_file`; falls back to `.result` if null

**To change for all agents:** Edit `RCA_MODEL` in defaults.env. One variable, all agents.

---

### `prompts/diagnosis.md`

**The most important file for output quality.** Tune this when Agent 1 misses root causes.

| Section | Purpose | What to tune |
|---|---|---|
| Contract comment | Role, inputs, outputs, tools | — |
| Security block | Prompt injection defence | Do not remove |
| Inputs description | What briefing.md sections contain | — |
| Search strategy | Full codebase, not just recent commits | "3 levels deep" for call chains |
| Hypothesis requirement | ≥2 hypotheses with evidence | "at least 2" → 3 for ambiguous bugs |
| Checkpoint instruction | Write state after 10 files | "10 files" for timeout recovery tuning |
| Stop condition | Stop if confidence > `RCA_CONFIDENCE_STOP` | Controlled by defaults.env |
| Self-critique | 3 ways hypothesis could be wrong | "3" for more rigour |
| Output instructions | JSON only, no fences | Do not change |
| Negative instructions | Do not invent, do not hide uncertainty | Do not remove |

**Agent 1 tool restrictions:**
```
Read, Grep, Glob
Bash(git log *), Bash(git blame *), Bash(git show *)
Bash(git diff *), Bash(git status *)
Bash(rg *), Bash(grep *), Bash(find *)
Write(.rca-mas/runs/**)   ← checkpoint only
```

---

### `prompts/solution.md`

- Return `NO_FIX` if confidence below `RCA_CONFIDENCE_NOFX`
- One focused unified diff
- No refactoring, no vendor files, no style edits
- Risk: low = isolated; medium = shared path; high = auth/payments/data integrity

**Agent 2 tool restrictions:** `Read, Grep, Glob` only.

---

### `prompts/validation.md`

Works only inside the validation worktree. 7-step process: code review → apply fix → run existing tests → write one regression test → run new test → save diffs → cleanup.

**Agent 2.5 tool restrictions:** `Read, Grep, Glob, Edit, Bash` — bash limited to git and test runner commands only.

---

### `scripts/report.sh`

Pure bash + jq. No LLM. Reads JSON files, writes `report.md`.

**11 required sections:**
1. Status
2. Root Cause
3. Confidence
4. Evidence
5. Affected Files
6. Proposed Fix
7. Patch Files
8. Validation
9. Cost / Runtime  ← reads from cost_summary.json
10. Unknowns / Risks
11. Next Action

**Confidence labels:** ≥0.8 HIGH / 0.6–0.79 MEDIUM / 0.5–0.59 LOW / <0.5 VERY LOW

---

### `docs/user-manual.md`

Practical guide for anyone using the tool. Must cover:
- prerequisites (Claude Code CLI, git, jq, optional gh)
- first run on `examples/bug.md`
- local `bug.md` run
- GitHub issue run
- validation run
- output folder explanation
- how to read the report
- config tuning basics
- cleanup commands

---

### `docs/cost-and-runtime.md`

- What drives cost (model, turns, tier, validation on/off)
- How to read `cost_summary.json`
- What `cost_level` LOW/MEDIUM/HIGH means
- How to reduce cost (lower turns, smaller model, no validation)
- Why token counts may be null
- Statement that numbers are non-authoritative

---

### `docs/testing-real-github-bugs.md`

Shell helper:
```bash
test_known_bug() {
  local repo="$1" issue="$2" fix_sha="$3"
  git clone --depth 50 "https://github.com/$repo" /tmp/rca-test-repo
  cd /tmp/rca-test-repo && git checkout "${fix_sha}~1"
  gh issue view "$issue" --repo "$repo" \
    --json title,body --jq '(.title)+"\n\n"+(.body)' > bug.md
  EXPECTED_FIX_SHA="$fix_sha" /PATH/TO/rca-mas/rca-mas.sh bug.md
  echo "=== Actual fix ===" && git show "$fix_sha" --name-only
  echo "=== Agent diagnosis ===" && jq -r '.affected_files[]' \
    .rca-mas/runs/latest/diagnosis.json
}
```

Recommended repos: pallets/flask (~200 files), tiangolo/fastapi (~400), django/django (~2000+)

---

## Run Artifacts

Every run writes to `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/`.

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

`latest` symlink always points to most recent run.

---

## Unit Tests (4 scripts, no framework)

Each prints PASS/FAIL per assertion, exits 1 if any fail. No Claude required.

| Script | What it tests |
|---|---|
| `tests/test_briefing.sh` | briefing.md + errors.txt created, no crash on empty input, full error strings preserved |
| `tests/test_collectors.sh` | each collector runs, failure doesn't kill pipeline, output bounded |
| `tests/test_json_schemas.sh` | sample fixtures validate cleanly, invalid.json fails `assert_valid_json` |
| `tests/test_smoke_report_only.sh` | full pipeline with fixture JSON (no Claude), report.md created with all sections, git status clean |

**Fixtures in `tests/fixtures/`:**
- `sample_bug.md`
- `sample_diagnosis.json` — confidence 0.82, 2 hypotheses
- `sample_solution.json` — FIX with unified_diff
- `sample_solution_nofx.json` — NO_FIX
- `sample_validation.json` — SKIPPED
- `sample_cost_summary.json` — valid cost_summary structure
- `invalid.json` — `{broken json`

---

## Build Order

| Step | What gets built | Done when |
|---|---|---|
| 1 | scaffold, `config/defaults.env`, all `lib/`, `rca-mas.sh`, `Makefile`, `examples/`, `docs/` stubs | `./rca-mas.sh --help` works |
| 2 | `orchestrator.sh` infrastructure: run dir, manifest (all fields), symlink, logs | manifest has all fields, symlink updates |
| 3 | stub pipeline: stub functions write fixture JSON to run dir | full command exits 0, 4 JSON files + cost_summary exist |
| 4 | `briefing.sh` + 4 collectors | `make test`, briefing useful on Flask |
| 5 | 3 JSON schemas | `make test`, all schemas parse cleanly |
| 6 | `claude_json.sh` + `prompts/diagnosis.md` + Agent 1 wiring | plausible `diagnosis.json` on one real bug |
| 7 | `prompts/solution.md` + Agent 2 wiring + patch extraction | fix.diff present, recommendation in report |
| 8 | `report.sh` with all 11 sections including Cost / Runtime | all 11 sections present |
| 9 | `README.md` + all 10 docs complete | new user can run from docs alone |
| 10 | GitHub `--issue` input | `issue.json` created, manifest `bug_source = "github_issue"` |
| 11 | `prompts/validation.md` + Agent 2.5 + worktree lifecycle | patches/ has 3 diff files, worktree cleaned |
| 12 | real GitHub bug demo + final docs pass | report compared against known fix commit |

**Priority order if time runs short:** report-only path → GitHub issue input → docs → validation polish.

---

## Quick Tuning Reference

| I want to... | Change this | In this file |
|---|---|---|
| More investigation depth | Raise `RCA_TURNS_*` | `config/defaults.env` |
| Faster / cheaper runs | Lower `RCA_TURNS_*` | `config/defaults.env` |
| Better quality model | `RCA_MODEL=claude-opus-4-7` | `config/defaults.env` |
| Wider git history | `RCA_GIT_LOOKBACK="30 days ago"` | `config/defaults.env` |
| Agent 1 stops less eagerly | Raise `RCA_CONFIDENCE_STOP` | `config/defaults.env` |
| Agent 2 more conservative | Raise `RCA_CONFIDENCE_NOFX` | `config/defaults.env` |
| Keep worktree for inspection | `RCA_KEEP_WORKTREE=1` | env var or defaults.env |
| More hypotheses from Agent 1 | Change "at least 2" to "at least 3" | `prompts/diagnosis.md` |
| Deeper call chain tracing | Change "3 levels deep" | `prompts/diagnosis.md` |
| Two fix options from Agent 2 | Change "exactly one" to "up to 2" | `prompts/solution.md` |
| Add a schema field | Add to `properties` + `required` | `schemas/*.schema.json` |
| Add a report section | Add `## Heading` block | `scripts/report.sh` |

---

## Testing Guide

### After Step 1
```bash
make lint
./rca-mas.sh --help                           # usage text, exits 0
./rca-mas.sh nonexistent.md                   # ERROR: file not found
./rca-mas.sh --issue 42 examples/bug.md       # ERROR: mutually exclusive
```

### After Step 2
```bash
./rca-mas.sh examples/bug.md
jq . .rca-mas/runs/latest/manifest.json       # all fields including tool_root, target_repo_root
cat .rca-mas/runs/latest/log.jsonl
ls -la .rca-mas/runs/                         # RUN_ID dir + latest symlink
```

### After Step 3
```bash
./rca-mas.sh examples/bug.md                  # exits 0
jq -e . .rca-mas/runs/latest/diagnosis.json
jq -e . .rca-mas/runs/latest/cost_summary.json
make test                                      # all 4 tests pass
```

### After Step 4
```bash
make test
bash scripts/briefing.sh examples/bug.md /tmp/b.md /tmp/e.txt
grep "MAX_TURNS\|FILE_COUNT\|TEST_COMMAND" /tmp/b.md
```

### After Step 6
```bash
cd /tmp/flask && /PATH/rca-mas.sh bug.md
jq '{root_cause, confidence, affected_files}' .rca-mas/runs/latest/diagnosis.json
```

### After Step 7
```bash
cat .rca-mas/runs/latest/patches/fix.diff     # starts with "--- a/"
```

### After Step 8
```bash
make report
# Check: 11 sections present including Cost / Runtime
jq '{cost_level, total_duration_seconds, agent1_turns_used}' .rca-mas/runs/latest/cost_summary.json
```

### After Step 10
```bash
./rca-mas.sh --issue 5234 --repo pallets/flask
jq -r '.bug_source' .rca-mas/runs/latest/manifest.json   # "github_issue"
```

### After Step 11
```bash
make run-validate
ls .rca-mas/runs/latest/patches/
ls ../.rca-mas-worktrees/ 2>/dev/null || echo "cleaned up"
```

### Full acceptance
```bash
make lint && make test
make run && make report
jq -e . .rca-mas/runs/latest/cost_summary.json
git status    # no source files modified
```
