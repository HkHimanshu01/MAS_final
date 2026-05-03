# RCA Compression MAS — Build Plan

## What We're Building

A CLI tool that compresses a 30–60 minute bug investigation into a 3–8 minute automated report. A QA tester finds a bug, raises a GitHub issue or writes a `bug.md`, runs one command, and a developer gets a structured report showing root cause, evidence, a proposed fix diff, and what to do next.

```
./rca-mas.sh bug.md
cat .rca-mas/runs/latest/report.md
```

**Scope:** Production-ready v1 in 1.5 weeks, 2 hours/day. Bash + git + jq + Claude Code CLI. No API keys, no dashboards, no databases. Agent 2.5 (validation) is built last and cut first if time runs short.

---

## Repo Structure

```
rca-mas/
├── rca-mas.sh                    ← you run this
├── config/
│   └── defaults.env              ← every tunable parameter in one place
├── scripts/
│   ├── orchestrator.sh           ← controls the whole pipeline
│   ├── briefing.sh               ← pure bash repo scan (no LLM)
│   ├── claude_json.sh            ← how Claude Code is invoked
│   └── report.sh                 ← JSON → report.md
├── lib/
│   ├── log.sh                    ← logging functions
│   ├── json.sh                   ← jq helpers
│   ├── paths.sh                  ← run directory setup
│   └── cleanup.sh                ← worktree cleanup trap
├── collectors/
│   ├── git.sh                    ← git history for mentioned files
│   ├── deps.sh                   ← import/require tracing
│   ├── errors.sh                 ← grep error strings across repo
│   └── testrunner.sh             ← detect test command + src→test mapping
├── prompts/
│   ├── diagnosis.md              ← Agent 1 full instructions
│   ├── solution.md               ← Agent 2 full instructions
│   └── validation.md             ← Agent 2.5 instructions (optional)
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── docs/
│   ├── index.md
│   ├── architecture.md
│   ├── briefing-flow.md
│   ├── agent-flow.md
│   ├── validation-flow.md
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
└── CLAUDE.md
```

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
                         reads: diagnosis.json, solution.json, validation.json
                         writes: report.md
```

---

## Every File — What It Is and How to Change It

### `config/defaults.env`

**The only file you need to touch to change agent behaviour.** Every tunable parameter lives here. Override any value by exporting it before running:

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

---

### `lib/log.sh`

Provides three functions used by every script:
- `log_event level stage msg [key=value ...]` — writes a JSON line to `log.jsonl`
- `info "..."` — prints `[rca-mas] ...` to stderr (visible in terminal)
- `warn "..."` — prints `[rca-mas] WARNING: ...` to stderr
- `die "..."` — prints error to stderr and exits 1

**To change the log format:** Edit the `printf` pattern inside `log_event`. Every script uses the same function.

---

### `lib/json.sh`

Three jq helpers so jq calls are not scattered across scripts:
- `extract_structured raw_file out_file` — extracts `.structured_output` from Claude's JSON wrapper; falls back to `.result` if null
- `jq_field file query` — reads one field safely; returns empty string if missing (never errors)
- `assert_valid_json file label` — calls `die` if the file is not valid JSON

**To change:** Add new jq helpers here. Do not inline jq calls in orchestrator or report.sh.

---

### `lib/paths.sh`

Three functions:
- `make_run_id` — generates `<timestamp>-<short-sha>` (e.g. `1746180000-a3f7c1`)
- `init_run_dir run_id` — creates `.rca-mas/runs/<run_id>/patches/` and exports all canonical path variables (`$DIAGNOSIS`, `$SOLUTION`, `$REPORT`, etc.)
- `update_latest_symlink` — points `.rca-mas/runs/latest` to the current run

**To change output location:** Change `RCA_OUTPUT_DIR` in `config/defaults.env`.

---

### `lib/cleanup.sh`

- `register_worktree path` — records which worktree to clean up
- `run_cleanup` — called by `trap ... EXIT`; removes the worktree unless `RCA_KEEP_WORKTREE=1`

**To keep worktree for inspection:** `export RCA_KEEP_WORKTREE=1` before running.

---

### `rca-mas.sh`

Entry point. Thin: sources config + log lib, parses CLI args, checks prerequisites, exports variables, `exec`s orchestrator.

**Flags:**
```
./rca-mas.sh <bug.md>                     # report-only
./rca-mas.sh <bug.md> --validate          # validate fix in isolated worktree
./rca-mas.sh --issue <NUM>                # fetch GitHub issue
./rca-mas.sh --issue <NUM> --repo <slug>  # with explicit repo
./rca-mas.sh --help
```

**To add a flag:** Add a `case` block, export the variable, handle it in orchestrator.

---

### `Makefile`

Developer shortcuts. No need to remember flags:

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
1. Sources all lib files
2. Registers `trap run_cleanup EXIT`
3. Generates `RUN_ID`, calls `init_run_dir`
4. Writes `manifest.json` (see below)
5. Updates latest symlink
6. Resolves input (copies bug.md or fetches GitHub issue)
7. Calls `briefing.sh`
8. Calls Agent 1 via `run_claude_schema`; handles timeout + checkpoint recovery
9. Updates `stage_statuses.agent1` in manifest
10. Calls Agent 2; handles NO_FIX gate; extracts `patches/fix.diff`
11. Writes skipped `validation.json` in report-only mode OR calls Agent 2.5 in `--validate` mode
12. Calls `report.sh`
13. Writes `ended_at` to manifest
14. Prints report path

**`manifest.json` fields** (designed for comparing against real fix commits later):

| Field | Value |
|---|---|
| `run_id` | `<timestamp>-<sha>` |
| `mode` | `report-only` or `validate` |
| `repo_root` | Absolute path |
| `repo_remote_url` | `git remote get-url origin` |
| `git_head_sha` | HEAD SHA at time of run |
| `git_branch` | Current branch |
| `bug_source` | `file` or `github_issue` |
| `bug_source_file` | Path to the bug.md used |
| `issue_url` | GitHub issue URL (if `--issue`) |
| `expected_fix_commit` | Set via `EXPECTED_FIX_SHA=abc ./rca-mas.sh bug.md` |
| `started_at` | ISO 8601 |
| `ended_at` | ISO 8601 (written at end; null if run crashed) |
| `stage_statuses` | `{briefing, agent1, agent2, validation, report}` — each updated as it completes |
| `tool_versions` | claude, git, jq, gh versions |

---

### `scripts/briefing.sh`

Pure bash. Zero LLM calls. Runs in ~2 seconds. Gives Agent 1 a head start instead of wasting 8–12 turns on orientation.

**What it produces:**
- `briefing.md` — metadata header + 4 collector sections
- `errors.txt` — extracted quoted error strings

**How it works:**
1. Extracts file paths from bug report using regex; validates each (`git ls-files --error-unmatch`; rejects traversal + secrets)
2. Extracts quoted error strings (`"..."` with 5–80 chars)
3. Counts files via `git ls-files | wc -l` → selects `MAX_TURNS` and `TIMEOUT` tier
4. Writes metadata header to `briefing.md`
5. Runs each of the 4 collectors with `timeout $RCA_COLLECTOR_TIMEOUT`; on failure: logs warning and continues
6. Deduplicates output with `awk '!seen[$0]++'`

**To tune:** All tier values and timeouts are in `config/defaults.env`.

---

### `collectors/git.sh`

Git history for mentioned files.

- `git log --since="$RCA_GIT_LOOKBACK" --oneline -- <file>` for each mentioned file
- `git log --merges --oneline origin/master | head -20` for recent merges
- `git blame <file>` for each mentioned file

**To tune:** `RCA_GIT_LOOKBACK` in defaults.env (default: `"14 days ago"`). Widen for bugs in old code.

---

### `collectors/deps.sh`

Import tracing for mentioned files. Best-effort.

- Python: `grep -nE "^(import |from .* import)"` on each file
- JS/TS: `grep -nE "(require\(|import .* from)"` on each file
- Go: `grep -nA5 "^import"` on each file
- Unsupported languages: prints a note, does not crash

**To add a language:** Add an `elif` block before the fallback.

---

### `collectors/errors.sh`

Finds where error strings appear in the codebase.

```bash
while IFS= read -r err; do
  [ -n "$err" ] || continue
  { rg -nF -- "$err" . 2>/dev/null || grep -RFn -- "$err" . 2>/dev/null || true; } \
    | head -"$RCA_ERROR_GREP_LIMIT"
done < "$ERRORS_TXT"
```

Key: `|| true` is required — `set -e` would exit on no-match grep. Fixed-string search (`-F`) avoids word-splitting bugs with multi-word errors.

**To tune:** `RCA_ERROR_GREP_LIMIT` in defaults.env (default: 50). Raise if key locations are being cut off.

---

### `collectors/testrunner.sh`

Detects the test command and maps source files to test files by convention.

- Checks for `pytest.ini`, `setup.cfg`, `pyproject.toml`, `package.json`, `go.mod`, `Makefile`
- Maps `foo.py` → `test_foo.py` or `foo_test.py` etc.
- Writes `TEST_COMMAND: UNKNOWN` if nothing detected

**To add a test runner:** Add a detection check before the `UNKNOWN` fallback.

---

### `schemas/diagnosis.schema.json`

Passed to Agent 1 via `--json-schema`. Forces structured output with `additionalProperties: false`.

Top-level required fields: `run_id`, `root_cause`, `selected_hypothesis_id`, `hypotheses[]`, `rejected_hypotheses[]`, `affected_files[]`, `call_chain[]`, `files_examined[]`, `unknowns[]`, `confidence` (0–1), `introducing_commit` (nullable), `next_best_action`

Each hypothesis: `id`, `summary`, `confidence`, `supporting_evidence[]`, `contradicting_evidence[]`

Each evidence item: `type`, `path`, `lines`, `note`

**To add a field:** Add to `properties` and to `required`. That's it. Claude Code will populate it.

---

### `schemas/solution.schema.json`

Passed to Agent 2. Key fields:

- `recommendation`: `"FIX"` or `"NO_FIX"`
- `no_fix_reason`: string or null
- `fixes[].unified_diff`: the actual patch text in unified diff format
- `fixes[].risk`: `"low"`, `"medium"`, or `"high"`
- `fixes[].expected_tests[]`: test paths that should verify the fix

---

### `schemas/validation.schema.json`

Passed to Agent 2.5. Key field:

- `status`: one of `SKIPPED`, `PATCH_APPLIED`, `TEST_CREATED`, `TESTS_PASSED`, `TESTS_FAILED`, `GENERATED_BUT_NOT_VERIFIED`, `VALIDATION_FAILED`

---

### `scripts/claude_json.sh`

The single function `run_claude_schema()` used by all 3 agents. Changing how Claude is invoked means editing this one file.

```bash
run_claude_schema prompt_file schema_file raw_file final_file max_turns tools [allow_rules...]
```

**What it does:**
1. Builds the `claude` command array with `--output-format json`, `--json-schema`, `--max-turns`, `--tools`, optional `--model`, optional `--allowedTools`
2. Pipes the prompt via stdin (`< "$prompt_file"`) — not via `-p "$(cat ...)"` which has shell arg size limits
3. Saves the full Claude wrapper response to `raw_file` (useful for debugging)
4. Extracts `.structured_output` → `final_file`; falls back to `.result` if null

**To change for all agents at once:**
- Switch model: set `RCA_MODEL=claude-opus-4-7` in defaults.env
- Change system prompt framing: edit the `-p "..."` string in the `cmd` array
- Add a new flag: add it to the `cmd` array

---

### `prompts/diagnosis.md`

**The most important file for output quality.** Agent 1 reads this as its complete instruction set.

**Sections (in order):**

| Section | What it does | What to tune |
|---|---|---|
| Contract comment | States role, inputs, outputs, tool list | — |
| Security block | Prompt injection defence | Do not remove |
| Inputs description | Explains briefing.md sections to the agent | — |
| Search strategy | Full codebase search, not just recent commits | Change "3 levels deep" for deeper repos |
| Hypothesis requirement | At least 2 hypotheses with evidence | Change "at least 2" to 3 for ambiguous bugs |
| Checkpoint instruction | Write mid-run state after 10 files | Change "10 files" for faster recovery |
| Stop condition | Stop early if confidence > `RCA_CONFIDENCE_STOP` | Controlled by defaults.env |
| Self-critique | 3 ways hypothesis could be wrong | Change "3" for more rigour |
| Output instructions | JSON only, no markdown fences | Do not change |
| Negative instructions | Do not invent, do not hide uncertainty | Do not remove |

**Agent 1 tool restrictions (set in orchestrator):**
```
Read, Grep, Glob
Bash(git log *), Bash(git blame *), Bash(git show *)
Bash(git diff *), Bash(git status *)
Bash(rg *), Bash(grep *), Bash(find *)
Write(.rca-mas/runs/**)   ← checkpoint only
```

---

### `prompts/solution.md`

Agent 2 reads this. Instructs it to produce one focused unified diff.

**Key rules in the prompt:**
- Return `NO_FIX` if `diagnosis.confidence < RCA_CONFIDENCE_NOFX`
- Produce exactly one fix (change to "up to 2" if you want options)
- Output a real unified diff — not pseudocode
- No refactoring unrelated code, no vendor files, no style-only edits
- Risk labels: low = isolated; medium = shared code path; high = auth/payments/data integrity

**Agent 2 tool restrictions:** `Read, Grep, Glob` only. No Bash, no Write.

---

### `prompts/validation.md`

Agent 2.5 reads this. Works only inside the validation worktree.

**7-step process instructed:**
1. Code review — logic errors in the fix
2. Create worktree (done by orchestrator before Agent 2.5 runs)
3. Apply fix — `git apply` the diff
4. Run existing tests — `timeout $RCA_AGENT25_TEST_TIMEOUT $TEST_COMMAND`
5. Write one regression test for the specific QA-reported scenario
6. Run the new test
7. Save all diffs (done by orchestrator after Agent 2.5 exits)

**Agent 2.5 tool restrictions:** `Read, Grep, Glob, Edit, Bash` — bash limited to git status/diff/apply and test runners only.

---

### `scripts/report.sh`

Pure bash + jq. No LLM. Reads the 3 JSON files, writes `report.md`.

**9 required sections:** Status, Root Cause, Confidence, Evidence, Affected Files, Proposed Fix, Patch Files, Validation, Unknowns / Risks, Next Action

**Confidence labels:**
- ≥ 0.8 → HIGH
- 0.6–0.79 → MEDIUM — verify unknowns
- 0.5–0.59 → LOW — treat as lead, not conclusion
- < 0.5 → VERY LOW — investigate manually

**To change:** Add or remove a `## Heading` block. Change threshold values in the `conf_label` function.

---

### `docs/testing-real-github-bugs.md`

How to validate that Agent 1 actually finds the right root cause. The approach: clone a repo at the pre-fix state, run the agent, compare `diagnosis.affected_files` against the actual files changed in the fix commit.

Shell helper (copy-paste):
```bash
test_known_bug() {
  local repo="$1" issue="$2" fix_sha="$3"
  git clone --depth 50 "https://github.com/$repo" /tmp/rca-test-repo
  cd /tmp/rca-test-repo && git checkout "${fix_sha}~1"
  gh issue view "$issue" --repo "$repo" \
    --json title,body --jq '(.title)+"\n\n"+(.body)' > /tmp/bug.md
  EXPECTED_FIX_SHA="$fix_sha" /PATH/rca-mas.sh /tmp/bug.md
  echo "=== Actual fix ===" && git show "$fix_sha" --name-only
  echo "=== Agent diagnosis ===" && jq -r '.affected_files[]' \
    /tmp/rca-test-repo/.rca-mas/runs/latest/diagnosis.json
}
```

Recommended repos:

| Repo | Size | Why |
|---|---|---|
| pallets/flask | ~200 files | Small, fast, well-documented issues |
| tiangolo/fastapi | ~400 files | Medium complexity |
| django/django | ~2000+ files | Large repo stress test |

---

## Unit Tests (4 scripts, no framework)

Each script prints `PASS` / `FAIL` per assertion and exits 1 if any fail. No Claude required.

| Script | What it tests |
|---|---|
| `tests/test_briefing.sh` | briefing.md created, errors.txt created, no crash on empty input, full error strings extracted |
| `tests/test_collectors.sh` | each collector runs, collector failure doesn't kill pipeline, output bounded |
| `tests/test_json_schemas.sh` | sample fixtures validate cleanly, invalid.json fails `assert_valid_json` |
| `tests/test_smoke_report_only.sh` | full pipeline with pre-written fixture JSON (no Claude), report.md created, git status clean |

**Fixtures in `tests/fixtures/`:**
- `sample_bug.md` — minimal bug with one file path + one quoted error
- `sample_diagnosis.json` — valid diagnosis, confidence 0.82, 2 hypotheses
- `sample_solution.json` — valid solution with FIX + unified_diff
- `sample_solution_nofx.json` — valid solution with NO_FIX
- `sample_validation.json` — valid validation, status SKIPPED
- `invalid.json` — `{broken json` for error-path testing

---

## Build Order

| Step | What gets built | Test after |
|---|---|---|
| 1 | `config/defaults.env`, all `lib/` files, `rca-mas.sh`, `Makefile`, `examples/`, `docs/` stubs | `make lint`, `./rca-mas.sh --help` |
| 2 | `scripts/orchestrator.sh` infrastructure (run dir, manifest, symlink) | manifest fields present, latest symlink updates |
| 3 | Stub pipeline (stub functions for all stages) | `./rca-mas.sh examples/bug.md` exits 0, 4 JSON files exist |
| 4 | `scripts/briefing.sh` + all 4 collectors | `make test`, briefing in isolation on Flask |
| 5 | 3 JSON schemas | `make test`, `jq -e . schemas/*.json` |
| 6 | `scripts/claude_json.sh` + `prompts/diagnosis.md` + Agent 1 wiring | trivial schema test, real Flask bug test |
| 7 | `prompts/solution.md` + Agent 2 wiring + patch extraction | fix.diff starts with `--- a/` |
| 8 | `scripts/report.sh` | all 9 sections in report.md |
| 9 | `README.md` + full docs pass | all 8 docs non-empty |
| 10 | GitHub issue input (`--issue` flag) | `issue.json` created, `bug_source = "github_issue"` in manifest |
| 11 | `prompts/validation.md` + Agent 2.5 + worktree lifecycle | patches/ has 3 diff files, worktree cleaned up |
| 12 | Final docs pass including `testing-real-github-bugs.md` | — |

---

## Quick Tuning Reference

| I want to... | Change this | In this file |
|---|---|---|
| More investigation depth | Raise `RCA_TURNS_*` | `config/defaults.env` |
| Faster / cheaper runs | Lower `RCA_TURNS_*` | `config/defaults.env` |
| Better quality model | `RCA_MODEL=claude-opus-4-7` | `config/defaults.env` |
| Wider git history | `RCA_GIT_LOOKBACK="30 days ago"` | `config/defaults.env` |
| Agent 1 stops less eagerly | Raise `RCA_CONFIDENCE_STOP` to 0.85 | `config/defaults.env` |
| Agent 2 more conservative | Raise `RCA_CONFIDENCE_NOFX` to 0.65 | `config/defaults.env` |
| Keep worktree for inspection | `RCA_KEEP_WORKTREE=1` | env var or defaults.env |
| More hypotheses from Agent 1 | Change "at least 2" to "at least 3" | `prompts/diagnosis.md` |
| Deeper call chain tracing | Change "3 levels deep" to "5" | `prompts/diagnosis.md` |
| Two fix options from Agent 2 | Change "exactly one" to "up to 2" | `prompts/solution.md` |
| Add a schema field | Add to `properties` + `required` | `schemas/*.schema.json` |
| Add a report section | Add `## Heading` block | `scripts/report.sh` |
| Change log format | Edit `log_event` printf pattern | `lib/log.sh` |

---

## Testing Guide (Step by Step)

### After Step 1
```bash
make lint                                     # no syntax errors
./rca-mas.sh --help                           # usage text, exits 0
./rca-mas.sh nonexistent.md                   # ERROR: file not found
./rca-mas.sh --issue 42 examples/bug.md       # ERROR: mutually exclusive
```

### After Step 2
```bash
./rca-mas.sh examples/bug.md
ls -la .rca-mas/runs/                         # RUN_ID dir + latest symlink
jq . .rca-mas/runs/latest/manifest.json       # all fields present
cat .rca-mas/runs/latest/log.jsonl            # JSON event lines
```

### After Step 3
```bash
./rca-mas.sh examples/bug.md                  # exits 0
jq -e . .rca-mas/runs/latest/diagnosis.json
jq -e . .rca-mas/runs/latest/solution.json
make test                                      # all 4 tests pass
```

### After Step 4
```bash
make test                                      # test_briefing + test_collectors pass
bash scripts/briefing.sh examples/bug.md /tmp/b.md /tmp/e.txt
grep "MAX_TURNS\|FILE_COUNT\|TEST_COMMAND" /tmp/b.md    # all present

# On Flask:
git clone --depth 20 https://github.com/pallets/flask /tmp/flask && cd /tmp/flask
bash /PATH/scripts/briefing.sh /PATH/examples/bug.md /tmp/fb.md /tmp/fe.txt
cat /tmp/fb.md          # FILE_COUNT ~200, TEST_COMMAND=pytest
```

### After Step 5
```bash
make test                                      # test_json_schemas passes
```

### After Step 6
```bash
# Quick sanity
source lib/log.sh; export RCA_LOG_FILE=/tmp/t.log; source scripts/claude_json.sh
printf 'Return JSON: {"answer":"hello"}' > /tmp/p.md
cat > /tmp/s.json <<'EOF'
{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"]}
EOF
CLAUDE_TIMEOUT=60 run_claude_schema /tmp/p.md /tmp/s.json /tmp/raw.json /tmp/out.json 3 "Read,Grep,Glob"
jq . /tmp/out.json      # {"answer":"hello"}

# Real test on Flask
cd /tmp/flask
./rca-mas.sh bug.md
jq '{root_cause, confidence, affected_files}' .rca-mas/runs/latest/diagnosis.json
```

### After Step 7
```bash
cat .rca-mas/runs/latest/patches/fix.diff     # starts with "--- a/"
jq '{recommendation}' .rca-mas/runs/latest/solution.json
```

### After Step 8
```bash
make report
# Check: 9 sections present, confidence shows HIGH/MEDIUM/LOW
```

### After Step 10
```bash
gh auth status
./rca-mas.sh --issue 5234 --repo pallets/flask
jq -r '.bug_source' .rca-mas/runs/latest/manifest.json   # "github_issue"
```

### After Step 11
```bash
make run-validate
ls .rca-mas/runs/latest/patches/    # fix.diff, generated_test.diff, fix_and_test.diff
ls ../.rca-mas-worktrees/ 2>/dev/null || echo "cleaned up correctly"
```

### Full acceptance
```bash
make lint && make test
make run && make report
jq -e . .rca-mas/runs/latest/diagnosis.json
jq -e . .rca-mas/runs/latest/solution.json
git status    # no source files modified
```
