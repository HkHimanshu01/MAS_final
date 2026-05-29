# Steps 1–3 Audit Report
**Date:** 2026-05-03
**Repo:** `C:\MAS_final\rca-mas`
**Auditor:** Claude Sonnet 4.6

> **Historical snapshot.** This report describes the state of the codebase after Steps 1–3 were complete and Steps 4–12 had not yet started. All 12 build steps (including Agent 2.5 worktree verification under `--validate`) are now locked and complete. See [plan.md](../../plan.md) for current status.

---

## 1. Overall Verdict

**PASS WITH WARNINGS**

All 57 automated tests pass. Syntax is clean across all 13 scripts. The pipeline runs end-to-end, produces all required artifacts, and the TOOL_ROOT / TARGET_REPO_ROOT path model is confirmed working against an external repo. Two warnings require action before Step 4: `make` is not installed (the defined lint/test gate cannot run as specified), and `examples/bug.md` referenced in `plan.md` does not exist (repo uses `samples/bug.md` per `code_practices.md`). Neither is a code defect but both affect the test gates and external review clarity.

---

## 2. Files Changed

### `git diff --stat`
```
 architecture.md | 8 ++++++--
 explanation.md  | 4 ++++
 plan.md         | 8 ++++++--
 3 files changed, 16 insertions(+), 4 deletions(-)
```

### `git diff --name-only`
```
architecture.md
explanation.md
plan.md
```

These are planning files only — header lock notices added during the pre-code readiness phase. The entire `rca-mas/` implementation directory is untracked (new, not yet committed). No implementation source files were modified after being written.

---

## 3. Step-by-Step Completion Status

| Step | Expected deliverable | Evidence found | Status | Notes |
|---|---|---|---|---|
| Step 1 | Scaffold, config, lib, CLI, docs stubs | All folders present, 13 scripts pass `bash -n`, `--help` exits 0, all error cases handled | PASS | `examples/` missing — repo uses `samples/` per `code_practices.md`. `code_practices.md` not copied into repo. |
| Step 2 | Run lifecycle, manifest, logs, latest | `manifest.json` has all 17 fields, `log.jsonl` is valid JSONL, `latest/` directory synced, `ended_at` set, stage_statuses updated per stage | PASS | `latest` is a synced directory on Windows, not a symlink. `expected_fix_commit` writes `""` not `null` when unset. |
| Step 3 | Stub pipeline, stub JSON, stub report | Pipeline exits 0, all 5 JSON files valid, all 11 report sections present, no Claude calls, no real briefing logic, 57/57 tests pass | PASS | `agent1_prompt.md`, `agent2_prompt.md`, `agent*.log` absent — expected, written in Steps 6–7. |

---

## 4. Repo Structure Review

| Required path | Present? | Complete or stub | Notes |
|---|---|---|---|
| `rca-mas.sh` | ✅ Yes | Complete | Thin entry point, delegates to orchestrator via `exec` |
| `config/defaults.env` | ✅ Yes | Complete | All 20 locked variables with correct default values |
| `scripts/orchestrator.sh` | ✅ Yes | Partial — infrastructure complete, agent wiring stubbed | Run lifecycle, manifest, logging, symlink fully implemented |
| `lib/log.sh` | ✅ Yes | Complete | `die`, `warn`, `info`, `log_event` all implemented |
| `lib/json.sh` | ✅ Yes | Complete | `extract_structured`, `jq_field`, `assert_valid_json` implemented |
| `lib/paths.sh` | ✅ Yes | Complete | `make_run_id`, `init_run_dir`, `update_latest_symlink`, `sync_latest` implemented |
| `lib/cleanup.sh` | ✅ Yes | Complete | `register_worktree`, `run_cleanup`, EXIT trap wired |
| `collectors/git.sh` | ✅ Yes | Stub | Outputs `## Git History` placeholder — Step 4 |
| `collectors/deps.sh` | ✅ Yes | Stub | Outputs `## Dependencies` placeholder — Step 4 |
| `collectors/errors.sh` | ✅ Yes | Stub | Outputs `## Error Locations` placeholder — Step 4 |
| `collectors/testrunner.sh` | ✅ Yes | Stub | Outputs `TEST_COMMAND: UNKNOWN` — Step 4 |
| `scripts/briefing.sh` | ✅ Yes | Stub | Writes stub `briefing.md` and empty `errors.txt` — Step 4 |
| `scripts/claude_json.sh` | ✅ Yes | Stub | `run_claude_schema()` calls `die` if invoked — Step 6 |
| `scripts/report.sh` | ✅ Yes | Stub | Writes all 11 section headers with `N/A` content — Step 8 |
| `prompts/` | ✅ Yes (empty dir) | Empty — expected | Step 6 (diagnosis.md), Step 7 (solution.md), Step 11 (validation.md) |
| `schemas/` | ✅ Yes (empty dir) | Empty — expected | Step 5 |
| `docs/` | ✅ Yes | 15 stubs, all non-empty | Names follow `code_practices.md` §15.1, not `plan.md` (different naming convention) |
| `examples/bug.md` | ❌ No | Does not exist | Repo uses `samples/bug.md` per `code_practices.md` §3. `plan.md` says `examples/`. See §13. |
| `examples/sample-report.md` | ❌ No | Does not exist | Listed in `plan.md`, not in `code_practices.md`. Not built. See §13. |
| `samples/bug.md` | ✅ Yes | Complete | Realistic bug with file path + quoted error string |
| `tests/fixtures/` | ✅ Yes | 7 files, all correct | `invalid.json` intentionally broken, 5 valid fixtures + `sample_bug.md` |
| `tests/test_briefing.sh` | ✅ Yes | Complete | 4 assertions, all pass |
| `tests/test_collectors.sh` | ✅ Yes | Complete | 8 assertions, all pass |
| `tests/test_json_schemas.sh` | ✅ Yes | Complete | 10 assertions, all pass |
| `tests/test_smoke_report_only.sh` | ✅ Yes | Complete | 35 assertions, all pass |
| `Makefile` | ✅ Yes | Complete | 6 targets correct — `make` not installed on this machine |
| `README.md` | ✅ Yes | Stub | Purpose paragraph + quick start — full content Step 9 |
| `CLAUDE.md` | ✅ Yes | Complete | Rules, lock reference, build order, test gate requirement |
| `.claude/settings.json` | ✅ Yes | Complete | 14 deny rules per `code_practices.md` §6.4 |
| `.gitignore` | ✅ Yes | Complete | All 5 required entries present |
| `code_practices.md` (in repo) | ❌ No | Missing from `rca-mas/` | Only exists in `C:\MAS_final\`. Plan says it should live in repo. |

---

## 5. CLI Behavior Review

| Command | Expected | Actual exit code | Result | Notes |
|---|---|---|---|---|
| `./rca-mas.sh --help` | Exit 0, usage text | 0 | ✅ PASS | All flags documented, env overrides shown |
| `./rca-mas.sh` (no args) | Exit 1, usage text | 0 | ⚠️ WARN | Shows usage but exits 0. Strict CLI convention: no-args should exit 1 |
| `./rca-mas.sh nonexistent.md` | Exit 1, clear error | 1 | ✅ PASS | `error: Bug file not found: nonexistent.md` |
| `./rca-mas.sh --unknown` | Exit 1, clear error | 1 | ✅ PASS | `error: Unknown flag: --unknown. Run with --help for usage.` |
| `./rca-mas.sh examples/bug.md` | — | 1 | ⚠️ WARN | Exits 1 with `Bug file not found: examples/bug.md`. Expected — `examples/` does not exist. The audit command referenced `plan.md` naming. Correct path is `samples/bug.md`. |
| `./rca-mas.sh samples/bug.md` | Exit 0, pipeline runs | 0 | ✅ PASS | Full pipeline runs, RUN_ID printed, report path printed |
| `./rca-mas.sh samples/bug.md --issue 42` | Exit 1, mutual exclusion | 1 | ✅ PASS | `error: Cannot use both a bug file and --issue.` |
| `./rca-mas.sh --repo owner/repo` | Exit 1, --repo requires --issue | 1 | ✅ PASS | `error: --repo requires --issue` |

---

## 6. Run Artifact Review

### Artifact table

| Artifact | Present? | Valid JSON? | Purpose | Notes |
|---|---|---|---|---|
| `manifest.json` | ✅ Yes | ✅ Yes | Run metadata — IDs, paths, timestamps, tool versions, stage statuses | All 17 required fields present |
| `bug.md` | ✅ Yes | N/A | Copy of the input bug report used for this run | Copied from `samples/bug.md` |
| `briefing.md` | ✅ Yes | N/A | Repo context for Agent 1 | Stub content — real content in Step 4 |
| `errors.txt` | ✅ Yes | N/A | Extracted error strings | Empty (0 bytes) — correct for stub |
| `diagnosis.json` | ✅ Yes | ✅ Yes | Agent 1 structured output | Schema-compatible stub shape |
| `diagnosis.raw.json` | ✅ Yes | ✅ Yes | Claude wrapper JSON (debug artifact) | Copy of diagnosis.json for stub |
| `solution.json` | ✅ Yes | ✅ Yes | Agent 2 structured output | `NO_FIX` stub |
| `solution.raw.json` | ✅ Yes | ✅ Yes | Claude wrapper JSON (debug artifact) | Copy of solution.json for stub |
| `validation.json` | ✅ Yes | ✅ Yes | Agent 2.5 output / SKIPPED flag | `SKIPPED` — correct for report-only mode |
| `cost_summary.json` | ✅ Yes | ✅ Yes | Run cost and timing summary | All fields present, `authoritative: false` |
| `report.md` | ✅ Yes | N/A | Final developer-readable report | All 11 sections present — stub content |
| `log.jsonl` | ✅ Yes | ✅ (per line) | Structured event log | 8 events, all valid JSON lines |
| `patches/` | ✅ Yes (empty) | N/A | Patch diffs directory | Empty — populated in Steps 7 and 11 |
| `agent1_prompt.md` | ❌ No | N/A | Debug: what was sent to Agent 1 | Expected absent — Step 6 |
| `agent2_prompt.md` | ❌ No | N/A | Debug: what was sent to Agent 2 | Expected absent — Step 7 |
| `agent1.log` | ❌ No | N/A | Agent 1 stderr | Expected absent — Step 6 |
| `agent2.log` | ❌ No | N/A | Agent 2 stderr | Expected absent — Step 7 |

### Manifest summary (actual run)

```json
{
  "run_id": "1777818698-248dadb",
  "mode": "report-only",
  "tool_root": "/c/MAS_final/rca-mas",
  "target_repo_root": "/c/MAS_final/rca-mas",
  "bug_source": "file",
  "stage_statuses": {
    "briefing": "ok",
    "agent1": "stub",
    "agent2": "stub",
    "validation": "skipped",
    "report": "ok"
  },
  "stage_durations_seconds": {
    "briefing": 1,
    "agent1": 1,
    "agent2": 0,
    "validation": 2,
    "report": 0
  }
}
```

---

## 7. Stub Pipeline Review

| Item | Status | Evidence |
|---|---|---|
| `diagnosis.json` is stubbed | ✅ Confirmed | `root_cause: "STUB — Agent 1 not yet implemented (Step 6)"`, `confidence: 0.0` |
| `solution.json` is stubbed | ✅ Confirmed | `recommendation: "NO_FIX"`, `no_fix_reason: "STUB — Agent 2 not yet implemented (Step 7)"` |
| `validation.json` is SKIPPED | ✅ Confirmed | `status: "SKIPPED"`, note says run with `--validate` |
| `report.md` is stubbed | ✅ Confirmed | All 11 sections present with `N/A` / `STUB` content |
| No real Claude calls made | ✅ Confirmed | `run_claude_schema()` calls `die` if invoked. No `claude` process spawned. No `.raw.json` from real agent. |
| No real briefing/collector logic | ✅ Confirmed | `briefing.sh` writes fixed stub text. Collectors output hardcoded placeholder strings. No regex, no `git`, no `grep` calls. |
| `cost_summary.json` stub is honest | ✅ Confirmed | `authoritative: false`, note: `"Stub cost summary — real values populated from Step 6 onwards."` |

---

## 8. TOOL_ROOT vs TARGET_REPO_ROOT Review

**How TOOL_ROOT is detected:**
`rca-mas.sh` resolves it via `$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)`. This captures the absolute path of the directory containing `rca-mas.sh` itself, regardless of where the caller's working directory is. It is exported immediately and used by orchestrator to source all libs, config, prompts, and schemas.

**How TARGET_REPO_ROOT is detected:**
Set to `$(pwd)` inside `rca-mas.sh` before `exec`-ing the orchestrator. This captures the caller's working directory at the moment the command is run — the repo being analyzed.

**Where outputs are written:**
`RUN_DIR = TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}`. All file writes go here. The tool never writes to `TOOL_ROOT` during a run.

**External temp target repo test result:**
```
TOOL_ROOT  = /c/MAS_final/rca-mas
TMP_TARGET = /tmp/tmp.kvtjKpHgOj

manifest.json confirmed:
  tool_root:        /c/MAS_final/rca-mas     ← correct
  target_repo_root: /tmp/tmp.kvtjKpHgOj      ← correct, separate from tool

PASS: target run dir exists in TMP_TARGET
NOTE: tool root has its own independent .rca-mas/ from earlier test runs (not from this invocation)
```

**Safe for real GitHub repo testing:** YES. TOOL_ROOT and TARGET_REPO_ROOT are fully separate. Running `bash /c/MAS_final/rca-mas/rca-mas.sh bug.md` from inside a cloned Flask repo will correctly write all outputs to `flask/.rca-mas/runs/` and read all scripts/prompts/schemas from `rca-mas/`. Confirmed by the external repo test above.

**One edge case to watch:** If the external repo has no commits yet (bare `git init`), the RUN_ID SHA component falls back to `nongit` (seen in test: `1777818183-nongit`). This is handled correctly and does not cause a crash.

---

## 9. Syntax and Makefile Checks

| Check | PASS / FAIL / WARN | Notes |
|---|---|---|
| `bash -n rca-mas.sh` | ✅ PASS | Exit 0 |
| `bash -n lib/*.sh` (4 files) | ✅ PASS | cleanup.sh, json.sh, log.sh, paths.sh — all clean |
| `bash -n scripts/*.sh` (4 files) | ✅ PASS | briefing.sh, claude_json.sh, orchestrator.sh, report.sh — all clean |
| `bash -n collectors/*.sh` (4 files) | ✅ PASS | deps.sh, errors.sh, git.sh, testrunner.sh — all clean |
| `make -n lint` | ❌ FAIL (EXIT 127) | `make` not installed. Makefile content is syntactically correct. |
| `make -n test` | ❌ FAIL (EXIT 127) | `make` not installed. |
| `make -n run` | ❌ FAIL (EXIT 127) | `make` not installed. |
| `make -n report` | ❌ FAIL (EXIT 127) | `make` not installed. |
| `make -n clean` | ❌ FAIL (EXIT 127) | `make` not installed. |
| `make lint` (bash equivalent) | ✅ PASS | `bash -n rca-mas.sh scripts/*.sh collectors/*.sh lib/*.sh` — all pass |

---

## 10. Config Review

| Config group | Variables found | Status | Notes |
|---|---|---|---|
| Turn budgets | `RCA_TURNS_XS=15`, `RCA_TURNS_S=25`, `RCA_TURNS_M=35`, `RCA_TURNS_L=50` | ✅ PASS | Match locked plan exactly |
| Timeouts | `RCA_TIMEOUT_XS=180`, `RCA_TIMEOUT_S=300`, `RCA_TIMEOUT_M=420`, `RCA_TIMEOUT_L=600` | ✅ PASS | Match locked plan exactly |
| Tier breakpoints | `RCA_TIER_XS=100`, `RCA_TIER_S=500`, `RCA_TIER_M=2000` | ✅ PASS | Match locked plan exactly |
| Agent 2 settings | `RCA_AGENT2_TURNS=1`, `RCA_AGENT2_TIMEOUT=180` | ✅ PASS | Correct |
| Agent 2.5 settings | `RCA_AGENT25_TURNS=15`, `RCA_AGENT25_TIMEOUT=300`, `RCA_AGENT25_TEST_TIMEOUT=120` | ✅ PASS | Correct |
| Confidence thresholds | `RCA_CONFIDENCE_STOP=0.7`, `RCA_CONFIDENCE_NOFX=0.5`, `RCA_CONFIDENCE_CHECKPOINT=0.4` | ✅ PASS | Match locked plan exactly |
| Collector settings | `RCA_GIT_LOOKBACK="14 days ago"`, `RCA_ERROR_GREP_LIMIT=50`, `RCA_COLLECTOR_TIMEOUT=10` | ✅ PASS | Correct |
| Validation worktree settings | `RCA_WORKTREE_DIR="../.rca-mas-worktrees"`, `RCA_KEEP_WORKTREE=0` | ✅ PASS | Correct |
| Model setting | `RCA_MODEL=""` (empty = claude-sonnet-4-6) | ✅ PASS | Correct — empty string means default model |
| Cost/runtime warnings | `RCA_COST_WARN_SECONDS=480`, `RCA_COST_WARN_AGENT1_TURNS=40` | ✅ PASS | Correct |
| Output directory | `RCA_OUTPUT_DIR=".rca-mas"` | ✅ PASS | Correct |

All 20 variables present. All values match locked plan defaults.

---

## 11. Security and Safety Review

### `.claude/settings.json`

| Check | Result |
|---|---|
| Valid JSON | ✅ Yes |
| Deny rules present | ✅ Yes — 14 rules |
| Covers `.env` reads | ✅ `Read(./.env)`, `Read(./.env.*)` |
| Covers secret files | ✅ `Read(./secrets/**)`, `*.pem`, `*.key`, `id_rsa*` |
| Covers destructive git | ✅ `git push *`, `git commit *`, `git tag *` |
| Covers `rm -rf` | ✅ `Bash(rm -rf *)` |
| Covers network | ✅ `curl *`, `wget *`, `ssh *`, `scp *` |

### Dangerous pattern scan in executable scripts

| Pattern found | Location | Risk | Assessment |
|---|---|---|---|
| `rm -rf "$WORKTREE_PATH"` | `lib/cleanup.sh:21` | Removes worktree directory | ✅ Safe — path is a registered worktree under `../.rca-mas-worktrees/` |
| `rm -rf "$latest"` | `lib/paths.sh:44` | Removes `latest` pointer | ✅ Safe — scoped to `.rca-mas/runs/latest` only |
| `rm -rf .rca-mas/runs .rca-mas-worktrees` | `Makefile:27` | Deletes run output | ✅ Safe — `make clean` explicitly deletes output dirs only |
| `rm -rf "$TMPDIR_RUN"` | `tests/test_briefing.sh`, `tests/test_collectors.sh` | Deletes temp test dir | ✅ Safe — `mktemp -d` scoped temp directories |
| `rm -rf .rca-mas/runs .rca-mas-worktrees` | `tests/test_smoke_report_only.sh:75` | Test cleanup | ✅ Safe — scoped to output dirs |

**Zero dangerous commands found in executable script paths. All `rm -rf` occurrences are scoped to temp or output directories.**

### Credential/secret scan

| Pattern | Found | Assessment |
|---|---|---|
| `api_key`, `api-key` | ❌ Not found | Clean |
| `token` | `docs/security-model.md` stub text only | ✅ Safe — doc reference only |
| `password` | ❌ Not found | Clean |
| `secret` | `.claude/settings.json` deny rule, `docs/security-model.md` stub | ✅ Safe — both are deny rules or doc stubs |
| `sk-` | ❌ Not found | Clean |

**Zero actual credentials in any file.**

### Report-only mode safety

Report-only mode was confirmed to not modify source files. The `test_smoke_report_only.sh` test asserts this explicitly:
```
PASS: git status clean (no tracked source files modified)
```
All run outputs go to `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/` only.

---

## 12. Scope Creep Check

| Future step item | Present? | Acceptable? | Notes |
|---|---|---|---|
| Briefing real logic (file path extraction, regex, tier selection) | No | ✅ Yes | `briefing.sh` writes a fixed stub only |
| Collectors real logic (git log, grep, imports) | No | ✅ Yes | Collectors output hardcoded placeholder strings |
| Schemas real content | No | ✅ Yes | `schemas/` directory is empty |
| Claude calls | No | ✅ Yes | `run_claude_schema()` calls `die` if invoked — guard in place |
| Agent prompts | No | ✅ Yes | `prompts/` directory is empty |
| Real report generation (reading JSON, jq formatting) | No | ✅ Yes | `report.sh` writes fixed stub with all 11 section headers |
| GitHub issue import | No | ✅ Yes | `--issue` flag wired in `rca-mas.sh` and orchestrator but `gh` call is inside an `if [ -n "$ISSUE_NUM" ]` block that isn't reached in these tests |
| Validation worktree | No | ✅ Yes | `--validate` flag accepted but no worktree code exists yet |

**No scope creep detected. Zero Step 4+ work was accidentally implemented.**

---

## 13. Deviations from Locked Plan

| Deviation | Detail | Impact |
|---|---|---|
| `examples/` vs `samples/` | `plan.md` specifies `examples/bug.md` and `examples/sample-report.md`. Implementation uses `samples/bug.md` per `code_practices.md` §3. `examples/` directory does not exist. | ⚠️ The audit command `./rca-mas.sh examples/bug.md` fails with `Bug file not found`. Any script, doc, or test referencing `examples/` will fail. Must be noted for external reviewers. |
| `examples/sample-report.md` missing | Listed in `plan.md` repo structure, not in `code_practices.md`. Not created. | ⚠️ Minor — useful reference artifact. Can be added at Step 9 during docs pass. |
| `code_practices.md` not in repo | `code_practices.md` §3 lists it as a required file inside `rca-mas/`. Only present in `C:\MAS_final\`. | ⚠️ Minor — does not affect runtime, but the CLAUDE.md references it as authoritative and it should be findable inside the repo. |
| `docs/` naming convention | Built docs follow `code_practices.md` §15.1 names (`briefing-and-collectors.md`, `agent-contracts.md`, etc.). `plan.md` uses different names (`briefing-flow.md`, `agent-flow.md`). | ⚠️ Naming mismatch between planning files. Correct decision — `code_practices.md` wins — but `plan.md` references will be confusing to anyone cross-referencing. |
| `expected_fix_commit` as `""` not `null` | When `EXPECTED_FIX_SHA` env var is not set, manifest writes `""` instead of `null`. `plan.md` spec shows this as nullable. | Minor — `jq` distinguishes `""` from `null`. Will matter in Step 12 when EXPECTED_FIX_SHA comparison logic is implemented. |
| `latest` as directory not symlink | On Windows without Developer Mode, `ln -sfn` creates a directory instead of a symlink. `sync_latest` copies files at end of run. | Platform-specific — works correctly but `ls -la` shows `drwxr-xr-x` not `-> path`. On Linux/Mac a true symlink is created. |
| `make` not installed | `Makefile` defines the test gate commands. `make lint` and `make test` are the agreed pre-step gates. Neither works on this machine. | ⚠️ Functional gap — test gates are being run as raw bash invocations instead. Must be resolved before Step 4. |
| No hardcoded local paths in scripts | Verified — zero Windows-specific paths (`C:\`, `MAS_final`) found in any script | ✅ Good — scripts are portable |

---

## 14. Failures Requiring Fix Before Step 4

| Blocker | Evidence | Why it matters | Suggested fix |
|---|---|---|---|
| `make` not installed | `make -n lint` exits 127. `make: not found` in PATH. | The agreed test gate is `make lint && make test`. Every step's pass condition depends on these commands working as defined. Running ad-hoc bash equivalents is not the same as the defined gate. | Install `make` via winget: `winget install GnuWin32.Make` or via Git for Windows which may bundle it. Verify with `make --version`. |

---

## 15. Warnings to Monitor Later

| Warning | Detail | When to address |
|---|---|---|
| `examples/` vs `samples/` naming | Any doc or external reference using `examples/bug.md` will fail. `plan.md` still says `examples/`. | Step 9 — update `plan.md` docs references or add `examples/` as an alias |
| `./rca-mas.sh` no-args exits 0 | Strict CLI convention is exit 1 when no actionable input is given. Minor UX issue. | Step 9 during CLI docs finalisation |
| `expected_fix_commit` writes `""` not `null` | Manifest field should be `null` when unset, not empty string. | Step 10 when `EXPECTED_FIX_SHA` workflow is wired |
| `code_practices.md` not in repo | Should live inside `rca-mas/` per the spec. Currently only in planning folder. | Step 9 during docs pass |
| `examples/sample-report.md` missing | `plan.md` lists it as a required file. Useful as a reference for developers reading the output. | Step 9 — create a hand-written sample report |
| `latest` is a directory on Windows | Not a true symlink. `LATEST_RUN` pointer file present for machine-readable path. Works but is non-standard. Should be documented. | Step 9 — add note to `docs/run-artifacts.md` |
| `docs/` names follow `code_practices.md` not `plan.md` | Anyone cross-referencing `plan.md` doc names will not find them. | Step 9 — update `plan.md` doc list to match what was built |
| `gh` shows as `not-installed` in manifest tool_versions | `gh` was installed via winget but PATH not refreshed in current shell. New terminal will find it. | Before Step 10 — confirm `gh --version` works in a fresh shell |

---

## 16. Final Recommendation

**Are Steps 1–3 solid enough as backbone?** YES

The infrastructure is correctly built. Path model works. Manifest is complete. Logging is structured. All 57 tests pass. Stub pipeline is honest about what is and is not implemented. Security deny rules are in place. No scope creep.

**Safe to proceed to Step 4?** YES — after resolving the one blocker.

**What should be fixed first:**

1. **Install `make`** — one command, five minutes. This is the only blocker. Without it the defined test gate (`make lint && make test`) cannot run as specified.
   ```powershell
   winget install GnuWin32.Make
   ```
   Then verify: `make --version` and `make lint` and `make test` all pass before starting Step 4.

2. No other fixes required before Step 4. The warnings in §15 are all minor and have designated later steps where they will be resolved naturally.
