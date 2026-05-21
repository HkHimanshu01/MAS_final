# CLAUDE.md — RCA Compression MAS

## What this project is

A CLI tool that compresses 30–60 minute bug investigations into 3–8 minute automated reports. It reads a QA bug report (`bug.md`), scans the repo with bash, invokes Claude Code agents to diagnose and propose a fix, optionally validates in a git worktree, and writes `report.md`.

```bash
./rca-mas.sh bug.md
cat .rca-mas/runs/latest/report.md
```

## Authoritative files

- `code_practices.md` — implementation authority: bash patterns, CLI contract, agent tool restrictions, security rules
- `config/defaults.env` — every tunable parameter (turns, timeouts, confidence thresholds, model)
- `architecture.md` (at repo root) — locked architecture reference
- `plan.md` (at repo root) — build order and per-file implementation spec

## Repo layout

```
rca-mas/
├── rca-mas.sh                  ← entry point: arg parsing, prereq checks, execs orchestrator
├── config/defaults.env         ← ALL tunable parameters — change here, nowhere else
├── scripts/
│   ├── orchestrator.sh         ← pipeline controller, owns run lifecycle
│   ├── briefing.sh             ← pure bash repo scan, zero LLM calls
│   ├── claude_json.sh          ← shared run_claude_schema() helper for all 3 agents
│   └── report.sh               ← reads JSON files, writes report.md
├── lib/
│   ├── log.sh                  ← die/warn/info/log_event (JSONL)
│   ├── json.sh                 ← extract_structured, jq_field, assert_valid_json
│   ├── paths.sh                ← make_run_id, init_run_dir, update_latest_symlink
│   └── cleanup.sh              ← register_worktree, run_cleanup (trap EXIT)
├── collectors/
│   ├── git.sh                  ← git log, blame, recent merges for mentioned files
│   ├── deps.sh                 ← import tracing for Python, JS/TS, Go
│   ├── errors.sh               ← fixed-string grep across repo for each error string
│   └── testrunner.sh           ← detect test framework, map src→test files
├── prompts/
│   ├── investigation.md        ← Agent 1a system prompt (free-text investigation)
│   ├── diagnosis.md            ← Agent 1b system prompt (conclusion, schema-enforced)
│   ├── solution.md             ← Agent 2 system prompt
│   └── validation.md          ← Agent 2.5 system prompt
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── tests/
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   ├── test_smoke_report_only.sh
│   └── test_real_repo_briefing.sh
├── docs/                       ← all 16 docs are required deliverables
├── examples/bug.md
└── Makefile
```

## Path rules — critical

| Variable | Points to |
|---|---|
| `TOOL_ROOT` | `rca-mas/` directory — scripts, prompts, schemas, config |
| `TARGET_REPO_ROOT` | the repo being analyzed |
| `RUN_DIR` | `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` |

- Read scripts, prompts, schemas from `TOOL_ROOT`
- Run git commands and code search in `TARGET_REPO_ROOT`
- Write all outputs under `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}`
- Never scan `rca-mas/` source files when analyzing a different target repo

## Pipeline

```
bug.md → briefing.sh (bash, 0 LLM calls) → Agent 1a investigation → Agent 1b conclusion → Agent 2 solution → Agent 2.5 validation (--validate only) → report.md
```

Agent 1 is split into two phases: **1a** (free-text, no schema, writes checkpoint.json) and **1b** (schema-enforced, reads checkpoint, emits diagnosis.json). This ensures diagnosis output is always produced — 1a uses all turns for investigation, 1b has a dedicated small budget for synthesis.

Each stage receives only the previous stage's output (context funnel). Agent 1b sees only checkpoint + bug report. Agent 2 never sees the raw repo.

## Agent tool restrictions

| Agent | Tools | Bash allowed |
|---|---|---|
| Agent 1a (investigation) | Read, Grep, Glob, Bash | git log/blame/show/diff/status, rg, grep, find, cat, wc, head, tail, ls, sed — read-only only. Never Write. Never edits files. |
| Agent 1b (conclusion) | Read, Grep, Glob | none — synthesis only, no investigation |
| Agent 2 | Read, Grep, Glob | none |
| Agent 2.5 | Read, Grep, Glob, Edit, Bash | git status/diff/apply, test runners (pytest/go test/npm test etc.), worktree only |

## Rules when working in this repo

- **Never** auto-commit, auto-push, auto-tag, or open PRs
- **Never** modify files under `.rca-mas/runs/` or `.rca-mas-worktrees/`
- **Never** read `.env`, `.pem`, `.key`, `id_rsa`, or any credential file
- **Never** run `curl`, `wget`, `ssh`, `scp` unless explicitly instructed
- **Never** add external LLM SDKs, databases, dashboards, Jira/Slack integrations, auto-PR, or auto-deploy
- Architecture is **LOCKED FOR V1** — no new agents, folders, or integrations without approval
- Future ideas go in `potential_changes.md` only, never in plan.md or architecture.md

## What to change and where

| I want to… | Change this | Read first |
|---|---|---|
| Change agent turn budgets or timeouts | `config/defaults.env` | `docs/cli-reference.md` — full env var table |
| Change confidence thresholds | `config/defaults.env` | `docs/agent-contracts.md` — confidence score reference |
| Change the model | `RCA_MODEL` in `config/defaults.env` | — |
| Improve Agent 1 diagnosis quality | `prompts/diagnosis.md` | `docs/agent-contracts.md` — Agent 1 contract |
| Change fix output format | `prompts/solution.md` + `schemas/solution.schema.json` | `docs/schemas.md` — solution schema fields |
| Add a collector | new file in `collectors/`, register in `scripts/briefing.sh` | `docs/briefing-and-collectors.md` — collector rules |
| Add a report section | `scripts/report.sh` | `docs/run-artifacts.md` — report structure |
| Add a schema field | `schemas/*.schema.json` + matching prompt + `docs/schemas.md` | `docs/schemas.md` — all schema fields |
| Debug a failed run | read `log.jsonl`, check `*.raw.json` | `docs/troubleshooting.md` — symptom → fix |
| Understand a stage in depth | — | `docs/pipeline-flow.md` — every stage with I/O |
| Understand worktree validation | — | `docs/validation-worktree.md` — full lifecycle |
| Understand security rules | — | `docs/security-model.md` — trust boundaries |
| Understand why a decision was made | — | `docs/decisions.md` — kept/cut features |
| Add or run tests | `tests/` | `docs/testing-guide.md` — all 5 test suites |

## Documentation update rule

**When you change code, update the matching doc in the same step. This is non-negotiable.**

| Code change | Doc to update |
|---|---|
| New or changed CLI flag or env var | `docs/cli-reference.md` |
| New or changed run artifact | `docs/run-artifacts.md` |
| New or changed schema field | `docs/schemas.md` |
| Agent behavior change | `docs/agent-contracts.md` |
| Collector change | `docs/briefing-and-collectors.md` |
| Pipeline stage change | `docs/pipeline-flow.md` |
| Validation / worktree change | `docs/validation-worktree.md` |
| Security rule change | `docs/security-model.md` |
| Architecture decision | `docs/decisions.md` |
| New test suite or fixture | `docs/testing-guide.md` |
| Anything that helps a new dev | `docs/development-guide.md` |

Docs that are always in sync with code are a **hard requirement** — see `code_practices.md` §15.4. If in doubt whether a doc needs updating, update it. Stale docs are worse than no docs.

## Reference map — where to find detailed information

| Topic | Where to read |
|---|---|
| Full architecture with diagrams | `docs/architecture.md` |
| Every pipeline stage in detail | `docs/pipeline-flow.md` |
| All CLI flags and env vars | `docs/cli-reference.md` |
| Agent roles, inputs, outputs, tool lists | `docs/agent-contracts.md` |
| Briefing phases and all 4 collectors | `docs/briefing-and-collectors.md` |
| All JSON schema fields | `docs/schemas.md` |
| Every file in a run directory | `docs/run-artifacts.md` |
| Worktree lifecycle and patch application | `docs/validation-worktree.md` |
| Security boundaries and denied operations | `docs/security-model.md` |
| How to add collectors, prompts, schemas | `docs/development-guide.md` |
| How to run and write tests | `docs/testing-guide.md` |
| Common failures and exact fixes | `docs/troubleshooting.md` |
| Why architecture choices were made | `docs/decisions.md` |
| QA workflow and human handoff | `docs/qa-to-dev-flow.md` |
| All docs in reading order | `docs/index.md` |
| Full implementation spec | `code_practices.md` |
| Locked architecture | `architecture.md` (repo root) |
| Build steps and per-file spec | `plan.md` (repo root) |

## Build order

Follow `plan.md` steps 1–12 in sequence. Do not skip steps.

Current status: **Steps 1–7 complete and locked.** Next: Step 8 (report.sh polish — full 11-section render) and Step 11 (Agent 2.5 validation with worktree, `--validate` only).

### What is done (locked)

- Step 1: Scaffold, `config/defaults.env`, all `lib/`, `rca-mas.sh`, `Makefile`, `examples/`, doc stubs
- Step 2: `orchestrator.sh` infrastructure — run dir, manifest, symlink, logs
- Step 3: Stub pipeline — fixture JSON written to run dir, full command exits 0
- Step 4: `briefing.sh` + 4 collectors — briefing useful on real repos
- Step 4.5: Real GitHub repo fixture (`pallets/click`, 5 bugs) + `tests/test_real_repo_briefing.sh`
- Step 5: JSON schemas (`diagnosis`, `solution`, `validation`) gated by `test_json_schemas.sh`
- Step 6: Agent 1a (toolful investigation) + checkpoint-write phase + Agent 1b (schema-enforced synthesis with one-shot repair, fail-closed). Verified end-to-end on real-repo bugs 3, 4, and 5 with confidence 0.82–0.92 matching upstream fixes. Data flow contract: Agent 1a's checkpoint emits fields that map 1:1 onto `diagnosis.schema.json` so Agent 1b can pass through verbatim. See [docs/agent-contracts.md](docs/agent-contracts.md) for the field mapping and [docs/pipeline-flow.md](docs/pipeline-flow.md) for the 8-step Agent 1a flow.
- Step 7: Agent 2 (solution proposal) — schema-enforced (`schemas/solution.schema.json`), reads only `briefing.md` + `diagnosis.json`. **Invocation pattern matches Agent 1b verbatim**: `--json-schema` enforced, `--max-turns 5` main / `--max-turns 1` repair, no `--tools` flag (defaults technically enabled, but the system prompt forbids tool use and the model has been compliant). Orchestrator computes a `WEAK_EVIDENCE` flag from `diagnosis.confidence < RCA_CONFIDENCE_WEAK_THRESHOLD` OR `agent1a_quality` weak/failed and enforces it post-extraction. FIX output produces `patches/fix.diff` extracted from the recommended fix's `unified_diff`. Verified end-to-end on the same gate as Step 6 — real-repo bugs 3, 4, and 5 all produced `agent2: ok`, confidence 0.70–0.78, schema-valid FIX patches **functionally equivalent to upstream PRs #3079, #3068, #3021** (same file + same line range + same mechanism in every case). 11-step flow documented in [docs/pipeline-flow.md](docs/pipeline-flow.md) Stage 3.

### Known issue

`collectors/errors.sh` includes hits from `.rst` docs and test files, which can flood Agent 1a with low-signal noise on docs-heavy repos. Pre-existing memory entry tracks this. Despite the noise, Agent 1a quality gate + recovery still produced ok diagnoses on bugs 3/4/5. Refinement deferred to a follow-up.

## Testing process

### Which target to use when

| Situation | Command | Time | What it runs |
| --- | --- | --- | --- |
| Writing code, want fast feedback | `bash run.sh test-fast` | ~2 min | lint + schemas + smoke |
| Changed `briefing.sh` or a collector | `bash run.sh test-briefing` | ~4 min | briefing + collectors |
| Want quick real-repo signal | `bash run.sh test-real-repo-quick` | ~40s | bugs 1 and 4 only |
| Before moving to the next step | `bash run.sh lint && bash run.sh test` | ~6 min | all 4 synthetic suites |
| Before locking a step as complete | `bash run.sh test-full` | ~9 min | all synthetic + all 5 real-repo bugs |

### Step gate (required before each new step)
```bash
bash run.sh lint && bash run.sh test
# or if make is installed: make lint && make test
```

### Pre-lock gate (required before declaring a step complete)
```bash
bash run.sh test-full
# or if make is installed: make test-full
```

### Real-repo test setup
Requires the pallets/click clone at `C:/MAS_final/test-repos/click`:
```bash
git clone https://github.com/pallets/click C:/MAS_final/test-repos/click
```
Override location: `RCA_REAL_REPO_ROOT=/path/to/click bash run.sh test-real-repo`

Run specific bugs only: `RCA_REAL_REPO_BUGS=1,4 bash run.sh test-real-repo`

### What each suite tests

| Suite | What it verifies | Target repo |
| --- | --- | --- |
| `test_briefing.sh` | `briefing.sh` end-to-end: metadata, collectors, error extraction, path safety | Tiny controlled temp repo |
| `test_collectors.sh` | Each collector: exits 0, correct headers, edge cases (empty input, exclusions) | Tiny controlled temp repo |
| `test_json_schemas.sh` | Schema validity, fixture validation, `lib/json.sh` helpers | No repo (JSON files only) |
| `test_smoke_report_only.sh` | Full pipeline wiring, all output files, report sections | rca-mas itself (fixture JSON, no Claude) |
| `test_real_repo_briefing.sh` | Briefing quality on real bugs with known fixes | pallets/click clone |

**Important:** `test_briefing.sh` and `test_collectors.sh` use tiny controlled repos — this is intentional. They test that the code works correctly with known inputs. `test_real_repo_briefing.sh` tests quality on real data. Both are necessary; they test different things.

## Key commands

If `make` is installed:

```bash
make lint                    # bash -n syntax check on all scripts
make test-fast               # lint + schemas + smoke (~2 min, use while coding)
make test-briefing           # briefing + collectors tests
make test-schemas            # schema + fixture tests only (~5s)
make test                    # all 4 synthetic suites (~6 min, step gate)
make test-real-repo-quick    # bugs 1+4 only, fast real-repo signal (~40s)
make test-real-repo          # all 5 real-repo bugs (~3 min)
make test-full               # full synthetic + real-repo (pre-lock gate)
make run                     # ./rca-mas.sh examples/bug.md
make run-validate            # ./rca-mas.sh examples/bug.md --validate
make report                  # cat .rca-mas/runs/latest/report.md
make clean                   # rm -rf .rca-mas/runs .rca-mas-worktrees
```

If `make` is **not** installed (Windows/MSYS2 without make — use `run.sh`):

```bash
bash run.sh lint
bash run.sh test-fast
bash run.sh test-briefing
bash run.sh test-schemas
bash run.sh test
bash run.sh test-real-repo-quick
bash run.sh test-real-repo
bash run.sh test-full
bash run.sh run
bash run.sh run-validate
bash run.sh report
bash run.sh clean
```
