# RCA Compression MAS — Plain English File Guide

> **STATUS: LOCKED FOR V1.**
> Locked pipeline:
> `bug.md / --issue → briefing.sh → Agent 1 diagnosis → Agent 2 solution → Agent 2.5 validation (optional) → report.md`

This document explains every file in the repo in plain English, what it does, and how it grows across build sessions. Use this as your map when you open any file and want to understand what you're looking at.

---

## How to read this

- **What it is** — one sentence, no jargon
- **What lives inside** — the actual content in plain terms
- **Who talks to it** — what calls it and what it calls
- **Build sessions** — the file starts small and grows; this shows what gets added when

---

## The Big Picture First

The repo has 5 layers. From outermost to innermost:

| Layer | Files | Job |
|---|---|---|
| Entry | `rca-mas.sh` | You talk to this. It talks to everything else. |
| Config | `config/defaults.env` | All the knobs in one place. |
| Shared utilities | `lib/*.sh` | Small helpers every script uses. |
| Pipeline | `scripts/*.sh`, `collectors/*.sh`, `prompts/*.md`, `schemas/*.json` | Where the actual work happens. |
| Output | `.rca-mas/runs/{RUN_ID}/` | Everything the tool produces per run. |

---

## File-by-File Explanation

### `rca-mas.sh`

**What it is:** The front door. The only file you ever call directly.

**What lives inside:**
- Reads your command line (`bug.md`, `--validate`, `--issue`, `--help`)
- Checks that `claude`, `git`, and `jq` are installed
- Checks you're logged into Claude Code
- Passes everything to `orchestrator.sh` and steps aside

**Who talks to it:** You (the user)
**Who it talks to:** `config/defaults.env` (reads settings), `scripts/orchestrator.sh` (hands off)

| Session | What gets added |
|---|---|
| 1 | Full file — arg parsing, prereq checks, all flags, `--help` output |
| — | Never changes after Session 1 unless a new flag is needed |

---

### `config/defaults.env`

**What it is:** A single text file with every number and setting the tool uses. Change a value here to change how the tool behaves — no need to touch any script.

**What lives inside:**
- Turn budgets (how many back-and-forths Agent 1 gets per repo size)
- Timeouts (how long before we give up on an agent)
- Confidence thresholds (when to stop, when to say "no fix", when to use a checkpoint)
- Git lookback window (how far back to check git history)
- Model name (which Claude model to use)
- Output folder location
- Cost warning thresholds

**Who talks to it:** `rca-mas.sh` and `scripts/orchestrator.sh` both source (read) this file at startup
**Who it talks to:** Nobody — it just stores values

| Session | What gets added |
|---|---|
| 1 | Full file — all variables with comments explaining each one |
| 4 | Two cost warning variables added: `RCA_COST_WARN_SECONDS`, `RCA_COST_WARN_AGENT1_TURNS` |

---

### `lib/log.sh`

**What it is:** The logging system. Four functions every script uses to report what's happening.

**What lives inside:**
- `log_event` — writes one line of structured JSON to `log.jsonl` (machine-readable, for debugging)
- `info` — prints a friendly `[rca-mas] ...` message to your terminal
- `warn` — prints a warning to your terminal
- `die` — prints an error and exits immediately

**Who talks to it:** Every script in the repo sources this file
**Who it talks to:** The `log.jsonl` file in the run directory

| Session | What gets added |
|---|---|
| 1 | Full file — all four functions, never changes |

---

### `lib/json.sh`

**What it is:** A small collection of `jq` helpers so the same JSON operations aren't copy-pasted everywhere.

**What lives inside:**
- `extract_structured` — pulls the agent's actual output out of Claude's wrapper JSON. Claude wraps its response in a container; this unwraps it. Falls back gracefully if the field is missing.
- `jq_field` — reads one field from a JSON file without crashing if the field doesn't exist
- `assert_valid_json` — checks a file is valid JSON; crashes with a clear error if not

**Who talks to it:** `orchestrator.sh`, `report.sh`
**Who it talks to:** JSON files in the run directory

| Session | What gets added |
|---|---|
| 1 | Full file — all three helpers, never changes |

---

### `lib/paths.sh`

**What it is:** Everything to do with creating and naming folders and files for a run.

**What lives inside:**
- `make_run_id` — generates a unique name like `1746180000-a3f7c1` (timestamp + git SHA)
- `init_run_dir` — creates the run folder and exports every canonical file path as a variable (`$DIAGNOSIS`, `$SOLUTION`, `$REPORT`, `$COST_SUMMARY`, etc.) so all scripts reference the same paths
- `update_latest_symlink` — points `.rca-mas/runs/latest` to the current run

**Who talks to it:** `orchestrator.sh`
**Who it talks to:** The filesystem

| Session | What gets added |
|---|---|
| 1 | Full file including `$COST_SUMMARY` path variable, never changes |

---

### `lib/cleanup.sh`

**What it is:** Handles tidying up after the run — specifically the temporary git worktree created during validation.

**What lives inside:**
- `register_worktree` — records which worktree path to delete later
- `run_cleanup` — deletes the worktree unless `RCA_KEEP_WORKTREE=1`; this runs automatically when the script exits (even on crash)

**Who talks to it:** `orchestrator.sh` registers the worktree; the `trap EXIT` calls cleanup automatically
**Who it talks to:** `git worktree remove` command

| Session | What gets added |
|---|---|
| 1 | Full file, never changes |

---

### `scripts/orchestrator.sh`

**What it is:** The conductor. It runs every stage in order, records what happened, and makes sure failures don't crash everything.

**What lives inside (grows across sessions):**
- Sources all lib files
- Creates the run directory and writes `manifest.json`
- Updates the `latest` symlink
- Calls each pipeline stage and records how long it took
- Handles failures gracefully (timeout recovery, NO_FIX gate, degraded modes)
- Writes `cost_summary.json` at the end
- Prints the report path when done

**Who talks to it:** `rca-mas.sh` (via `exec`)
**Who it talks to:** Everything — briefing, agents, report

| Session | What gets added |
|---|---|
| 1 | Infrastructure: creates run dir, writes manifest skeleton, symlink, starts log |
| 2 | Calls `briefing.sh`, records duration |
| 3 | Calls Agent 1 with real Claude invocation, checkpoint recovery, calls Agent 2, patch extraction, NO_FIX gate |
| 4 | Writes `cost_summary.json`, writes `ended_at` to manifest, updates `stage_durations_seconds`, GitHub issue input |
| 5 | Calls Agent 2.5, worktree lifecycle |

---

### `scripts/briefing.sh`

**What it is:** A fast bash scanner that reads the bug report and the repo, then writes a summary for Agent 1. Zero AI involved — pure bash.

**What lives inside:**
- Reads the bug report and pulls out any file paths mentioned
- Validates those paths exist in the repo (rejects fake paths, traversal attempts, secret files)
- Pulls out quoted error messages
- Counts how many files are in the repo → picks how many turns and how much time Agent 1 gets
- Writes a `briefing.md` with a metadata header and then runs 4 collector scripts
- Writes `errors.txt` with extracted error strings

**Who talks to it:** `orchestrator.sh`
**Who it talks to:** The 4 collector scripts, `briefing.md`, `errors.txt`

| Session | What gets added |
|---|---|
| 2 | Full file — file extraction, tier selection, collector runner, dedup |
| — | Never changes after Session 2 |

---

### `collectors/git.sh`

**What it is:** Asks git what happened recently in the files the bug mentions.

**What lives inside:**
- For each file mentioned in the bug: recent commit history, who last changed each line (`git blame`)
- Recent merges to master (in case a recent merge introduced the bug)

**Who talks to it:** `briefing.sh`
**Who it talks to:** git

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `collectors/deps.sh`

**What it is:** Traces what the mentioned files import — maps the dependency chain.

**What lives inside:**
- For Python files: finds `import` and `from X import` lines
- For JS/TS files: finds `require()` and `import from` lines
- For Go files: finds import blocks
- For other languages: prints a note that it can't trace deps, doesn't crash

**Who talks to it:** `briefing.sh`
**Who it talks to:** Source files in the repo

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `collectors/errors.sh`

**What it is:** Searches the entire codebase for wherever the error messages from the bug report appear.

**What lives inside:**
- Reads `errors.txt` one line at a time
- For each error string, searches the whole repo using fixed-string match (not regex — avoids word-splitting bugs with multi-word errors)
- Caps output at `RCA_ERROR_GREP_LIMIT` lines per error so briefing doesn't get bloated

**Who talks to it:** `briefing.sh`
**Who it talks to:** All source files in the repo (via `rg` or `grep`)

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `collectors/testrunner.sh`

**What it is:** Figures out how to run the repo's tests and maps source files to their test files.

**What lives inside:**
- Checks for `pytest.ini`, `package.json`, `go.mod`, `Makefile` etc. to detect the test framework
- Writes `TEST_COMMAND: pytest` (or whatever it finds) into briefing
- Maps source files to test files by naming convention (`foo.py` → `test_foo.py`)
- Writes `TEST_COMMAND: UNKNOWN` if nothing found

**Who talks to it:** `briefing.sh`
**Who it talks to:** The repo's config files

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `schemas/diagnosis.schema.json`

**What it is:** A contract that tells Claude exactly what JSON structure to return. Claude must produce output matching this shape — nothing more, nothing less.

**What lives inside:**
- Required fields: `root_cause`, `confidence`, `hypotheses` (at least 2), `affected_files`, `unknowns`, `next_best_action`, and more
- Each hypothesis must have supporting evidence AND contradicting evidence
- Each evidence item must have a file path, line number, and explanation
- `additionalProperties: false` — Claude cannot add fields that aren't listed here

**Who talks to it:** `scripts/claude_json.sh` passes this to Claude via `--json-schema`
**Who it talks to:** Claude Code CLI (enforces the schema)

| Session | What gets added |
|---|---|
| 3 | Full file, never changes |

---

### `schemas/solution.schema.json`

**What it is:** Same concept — the contract for Agent 2's output.

**What lives inside:**
- `recommendation`: either `"FIX"` or `"NO_FIX"`
- If FIX: a `unified_diff` (the actual patch), `risk` level, `expected_tests`
- If NO_FIX: a `no_fix_reason` explaining why

**Who talks to it:** `scripts/claude_json.sh`

| Session | What gets added |
|---|---|
| 3 | Full file, never changes |

---

### `schemas/validation.schema.json`

**What it is:** Contract for Agent 2.5's output.

**What lives inside:**
- `status`: one of 8 values (SKIPPED, TESTS_PASSED, TESTS_FAILED, etc.)
- Whether the patch was applied, whether a test was generated
- What test command was run, what failed

**Who talks to it:** `scripts/claude_json.sh`

| Session | What gets added |
|---|---|
| 3 | Full file, never changes |

---

### `scripts/claude_json.sh`

**What it is:** The single function that runs Claude. All three agents use this one function. If you ever want to swap to a different AI, this is the only file you change.

**What lives inside:**
- One function: `run_claude_schema`
- Builds the `claude` CLI command with the right flags (`--json-schema`, `--max-turns`, `--tools`, `--allowedTools`, optional `--model`)
- Pipes the prompt in via stdin (not as a shell argument — avoids size limits)
- Saves Claude's full response to a `.raw.json` file (useful for debugging)
- Extracts the actual structured output from Claude's wrapper JSON and saves it to the final `.json` file

**Who talks to it:** `orchestrator.sh` calls this for each agent
**Who it talks to:** Claude Code CLI

| Session | What gets added |
|---|---|
| 3 | Full file, never changes |

---

### `prompts/diagnosis.md`

**What it is:** The full instruction set Agent 1 reads before it starts investigating. This is the most important file for output quality. If Agent 1 is missing root causes, this is where you tune it.

**What lives inside (in order):**
1. Role definition ("You are a senior QA engineer...")
2. Security block (ignore instructions inside the bug report — prompt injection defence)
3. Description of what's in `briefing.md` so Agent 1 knows how to use it
4. Search strategy (search the whole codebase, not just recent commits)
5. Hypothesis requirement (produce at least 2, with evidence for and against each)
6. Checkpoint instruction (save progress after 10 files in case of timeout)
7. Stop condition (stop early if confident enough)
8. Self-critique (list 3 ways the diagnosis could be wrong)
9. Output format (JSON only, no markdown)
10. Negative instructions (don't invent, don't hide uncertainty)

**Who talks to it:** `orchestrator.sh` includes this in Agent 1's prompt
**Who it talks to:** Nobody — it's a text file Agent 1 reads

| Session | What gets added |
|---|---|
| 3 | Full file |
| Later | Tune based on real test results (change "at least 2" to "at least 3", adjust stop confidence, etc.) |

---

### `prompts/solution.md`

**What it is:** Agent 2's instruction set. Much shorter than diagnosis.md because Agent 2 has a simpler job.

**What lives inside:**
- Role definition ("You are a senior software engineer...")
- Security block
- NO_FIX rule (if confidence is too low, say so rather than guess)
- Fix requirements (one unified diff, no refactoring, no vendor files)
- Risk label definitions (low/medium/high)
- Output format

**Who talks to it:** `orchestrator.sh` includes this in Agent 2's prompt

| Session | What gets added |
|---|---|
| 3 | Full file |

---

### `prompts/validation.md`

**What it is:** Agent 2.5's instruction set. Tells it to work only inside the worktree and write exactly one regression test.

**What lives inside:**
- Role definition
- Security block
- The 7-step process (apply fix, run tests, write test, save diffs, clean up)
- Test writing requirements (same framework as repo, same import patterns)
- Strict restriction: only touch the worktree, never the main repo

**Who talks to it:** `orchestrator.sh` includes this in Agent 2.5's prompt

| Session | What gets added |
|---|---|
| 5 | Full file |

---

### `scripts/report.sh`

**What it is:** Reads all the JSON files from a run and produces the final human-readable `report.md`. No AI involved — pure bash and jq.

**What lives inside:**
- Reads `diagnosis.json`, `solution.json`, `validation.json`, `cost_summary.json`
- Converts confidence number to a label (0.82 → "HIGH")
- Formats evidence with file:line references
- Shows the proposed fix description and risk
- Shows the Cost / Runtime section from cost_summary
- Shows unknowns clearly
- 11 sections total

**Who talks to it:** `orchestrator.sh`
**Who it talks to:** The JSON files, writes `report.md`

| Session | What gets added |
|---|---|
| 4 | Full file with all 11 sections including Cost / Runtime |

---

### `scripts/orchestrator.sh` — cost_summary.json production

**What it is:** Not a separate file — this is logic added to orchestrator in Session 4.

**What it produces (`cost_summary.json`):**
- Which model was used
- Which tier the repo fell into (XS/S/M/L)
- How many turns Agent 1 used out of its budget
- How long each stage took in seconds
- Token counts from Claude's raw JSON if available (null if not — never fails)
- A cost level: LOW, MEDIUM, or HIGH based on model + turns + tier

**Why token counts are best-effort:** Claude Code CLI may or may not include token usage in its JSON wrapper. If it does, we capture it. If it doesn't, the fields are null. No estimation, no failure — just honest about what we know.

| Session | What gets added |
|---|---|
| 4 | Added to orchestrator — reads stage timings, extracts token counts from raw JSONs, writes cost_summary.json |

---

### `Makefile`

**What it is:** Shortcuts so you don't need to remember the full commands.

**What lives inside:**
- `make lint` — checks all bash files for syntax errors
- `make test` — runs all 4 test scripts (no Claude needed)
- `make run` — runs the tool on `examples/bug.md`
- `make run-validate` — runs with `--validate`
- `make report` — prints the latest report
- `make clean` — deletes all run outputs

| Session | What gets added |
|---|---|
| 1 | Full file, never changes |

---

### `tests/test_briefing.sh`

**What it is:** Automated test for `briefing.sh`. Runs without Claude.

**What it checks:**
- `briefing.md` gets created
- `errors.txt` gets created
- An empty bug report doesn't crash the tool
- Full multi-word error strings are preserved (not split)
- File paths are validated (fake paths are rejected)

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `tests/test_collectors.sh`

**What it is:** Automated test for the 4 collectors. Runs without Claude.

**What it checks:**
- Each collector runs without crashing
- A collector timing out doesn't kill the whole pipeline
- Output is bounded (no infinite loops)

| Session | What gets added |
|---|---|
| 2 | Full file |

---

### `tests/test_json_schemas.sh`

**What it is:** Automated test for the schemas and JSON helpers. Runs without Claude.

**What it checks:**
- Sample fixture JSON files validate cleanly
- `assert_valid_json` catches broken JSON
- `extract_structured` handles Claude wrapper correctly

| Session | What gets added |
|---|---|
| 3 | Full file |

---

### `tests/test_smoke_report_only.sh`

**What it is:** End-to-end smoke test using pre-written fixture JSON instead of real Claude calls. Proves the whole pipeline works without spending any tokens.

**What it checks:**
- Full pipeline runs without crashing
- `report.md` is created
- `cost_summary.json` is created
- All 11 report sections are present
- `git status` shows no source files were modified

| Session | What gets added |
|---|---|
| 4 | Full file |

---

### `tests/fixtures/`

**What it is:** Pre-written sample files used by the automated tests.

| File | What it is |
|---|---|
| `sample_bug.md` | A minimal bug report with one file path and one quoted error |
| `sample_diagnosis.json` | A valid diagnosis — confidence 0.82, 2 hypotheses, real evidence structure |
| `sample_solution.json` | A valid solution with a FIX recommendation and a real unified diff |
| `sample_solution_nofx.json` | A valid solution with NO_FIX and a reason |
| `sample_validation.json` | A valid validation with status SKIPPED |
| `sample_cost_summary.json` | A valid cost_summary structure with all fields |
| `invalid.json` | Deliberately broken JSON for testing error handling |

| Session | What gets added |
|---|---|
| 2 | `sample_bug.md` |
| 3 | `sample_diagnosis.json`, `sample_solution.json`, `sample_solution_nofx.json`, `sample_validation.json`, `invalid.json` |
| 4 | `sample_cost_summary.json` |

---

### `examples/bug.md`

**What it is:** A realistic sample bug report you can use to smoke test the tool immediately.

**What lives inside:** A credible bug report with a title, steps to reproduce, a quoted error message, a file path, and an affected feature — enough for briefing to extract real signals.

| Session | What gets added |
|---|---|
| 1 | Full file, never changes |

---

### `examples/sample-report.md`

**What it is:** An example of what a good `report.md` looks like after a successful run. Shows developers what to expect from the tool's output.

**What lives inside:** A complete 11-section report with realistic content — root cause, evidence with file:line references, a proposed fix, cost summary, unknowns. Written by hand, not generated.

| Session | What gets added |
|---|---|
| 1 | Full file — written to show the ideal output |

---

### `docs/index.md`

**What it is:** The table of contents for the docs folder.

**What lives inside:** One-line description of each doc and what order to read them.

| Session | What gets added |
|---|---|
| 1 | Stub (purpose paragraph) |
| 4 | Full content |

---

### `docs/architecture.md`

**What it is:** The locked architecture reference — pipeline diagram, every component, every parameter table.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content (already written separately as `architecture.md` in MAS_final) |

---

### `docs/user-manual.md`

**What it is:** Practical guide for someone who just wants to run the tool. Prerequisites, first run, reading the report, tuning config, cleanup.

**Who it's for:** A developer or consultant who has never used the tool before.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content covering: prerequisites, first run, local bug.md run, GitHub issue run, validation run, reading the report, config tuning basics, cleanup |

---

### `docs/briefing-flow.md`

**What it is:** Explains how `briefing.sh` and the 4 collectors work internally.

**What lives inside:** What signals each collector produces, the tier table, failure behaviour, what to tune.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `docs/agent-flow.md`

**What it is:** Explains how each agent works — what it reads, what it produces, what its tool restrictions are.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `docs/validation-flow.md`

**What it is:** Explains the worktree validation process — how the worktree is created, how the fix is applied, how tests are run, how cleanup works.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 5 | Full content (written alongside Agent 2.5) |

---

### `docs/cost-and-runtime.md`

**What it is:** Explains what drives cost, how to read `cost_summary.json`, what LOW/MEDIUM/HIGH means, and why token counts may be null.

**Who it's for:** Anyone who wants to understand or reduce the cost of a run.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `docs/runbook.md`

**What it is:** Operator reference. All CLI flags, all env var overrides, what files to look at when something goes wrong, how to re-run a stage.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `docs/troubleshooting.md`

**What it is:** Symptom → cause → exact fix for the most common failures.

**What lives inside:** Sections for: Claude not logged in, jq not found, empty diagnosis, Agent 1 timeout, NO_FIX returned, validation fails, worktree already exists.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `docs/testing-real-github-bugs.md`

**What it is:** Step-by-step guide for testing the tool against real GitHub bugs with known fixes.

**What lives inside:** How to find good test cases, how to clone at the pre-fix state, how to run the tool, how to compare agent output against the actual fix commit, a copy-paste shell helper function, recommended test repos.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `README.md`

**What it is:** The first thing someone reads. Quick start and overview.

**What lives inside:** What the tool does, prerequisites, quickstart commands, link to user-manual.md.

| Session | What gets added |
|---|---|
| 1 | Stub |
| 4 | Full content |

---

### `CLAUDE.md`

**What it is:** Instructions for Claude Code when it's working inside the rca-mas repo itself (not when the tool is running against another repo).

**What lives inside:** What this project is, what Claude must never do (no auto-commit, no push, no PR), which files are authoritative (`code_practices.md`, `config/defaults.env`).

| Session | What gets added |
|---|---|
| 1 | Full file |

---

### `code_practices.md`

**What it is:** Coding standards for anyone building or modifying the tool. Bash patterns, security rules, Claude invocation contract.

**What lives inside:** Script headers, helper functions, allowed bash patterns, forbidden patterns, security boundaries, Claude invocation rules.

| Session | What gets added |
|---|---|
| 1 | Copied from `c:\MAS_final\code_practices.md` |

---

### `.gitignore`

**What it is:** Tells git what not to track.

**What lives inside:** `.rca-mas/runs/`, `.rca-mas-worktrees/`, `*.log`, `.DS_Store`

| Session | What gets added |
|---|---|
| 1 | Full file |

---

### `.claude/settings.json`

**What it is:** Security rules enforced at the Claude Code level — belt-and-suspenders on top of the prompt guardrails.

**What lives inside:** A deny list that prevents Claude from reading secrets (`.env`, `.pem`, `.key`), and from running dangerous commands (`git push`, `git commit`, `rm -rf`, `curl`, `wget`, `ssh`).

| Session | What gets added |
|---|---|
| 1 | Full file |

---

## What the Run Output Looks Like (`.rca-mas/runs/{RUN_ID}/`)

This folder is created fresh for every run. Here's what builds up across sessions:

| File | Created in session | What it contains |
|---|---|---|
| `manifest.json` | 1 (stub) → 4 (complete) | Run metadata: mode, repo, timestamps, stage statuses, durations, tool versions |
| `cost_summary.json` | 3 (stub) → 4 (real) | Model, tier, turns used, stage durations, token counts if available, cost level |
| `bug.md` | 1 | Copy of the bug report used |
| `issue.json` | 4 | Raw GitHub issue JSON (only with `--issue`) |
| `briefing.md` | 2 | Repo context: metadata header + git history + deps + error locations + test map |
| `errors.txt` | 2 | Extracted error strings from bug report, one per line |
| `agent1_prompt.md` | 3 | Exactly what was sent to Agent 1 (for debugging) |
| `diagnosis.raw.json` | 3 | Claude's full wrapper response for Agent 1 |
| `diagnosis.json` | 3 | The structured output extracted from the wrapper |
| `checkpoint.json` | 3 | Agent 1's mid-run state (only written on timeout) |
| `agent2_prompt.md` | 3 | Exactly what was sent to Agent 2 |
| `solution.raw.json` | 3 | Claude's full wrapper response for Agent 2 |
| `solution.json` | 3 | Structured solution output |
| `patches/fix.diff` | 3 | The proposed fix as a unified diff |
| `agent25_prompt.md` | 5 | What was sent to Agent 2.5 (only with `--validate`) |
| `validation.raw.json` | 5 | Claude's full wrapper response for Agent 2.5 |
| `validation.json` | 1 (stub SKIPPED) → 5 (real) | Validation status and test results |
| `patches/generated_test.diff` | 5 | The new regression test as a diff |
| `patches/fix_and_test.diff` | 5 | Fix + test combined diff |
| `report.md` | 1 (stub) → 4 (complete) | The final developer-readable report |
| `log.jsonl` | 1 | One JSON line per event, every stage |
| `agent1.log` | 3 | Agent 1 stderr — shows every tool call Claude made |
| `agent2.log` | 3 | Agent 2 stderr |
| `agent25.log` | 5 | Agent 2.5 stderr |

---

## Build Session Summary

| Session | What you can do after |
|---|---|
| **1** | `./rca-mas.sh --help` works. `./rca-mas.sh examples/bug.md` runs, creates a real run folder, real manifest, real symlink. Pipeline completes with stub outputs. |
| **2** | `make test` passes. Briefing works on real repos. You can run `briefing.sh` against Flask and get a real `briefing.md` with git history, deps, and error locations. |
| **3** | Full pipeline runs on a real bug. `diagnosis.json`, `solution.json`, and `patches/fix.diff` are real outputs from Claude. |
| **4** | `report.md` is complete with all 11 sections. `cost_summary.json` is written. All 10 docs are complete. GitHub issue input works. |
| **5** | `--validate` works. Fix is applied in a safe worktree, tests run, regression test written, diffs saved. |
