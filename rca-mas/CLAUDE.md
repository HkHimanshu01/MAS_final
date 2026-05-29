# CLAUDE.md — RCA Compression MAS

## What this project is

A CLI tool that compresses 30–60 minute bug investigations into 3–8 minute automated reports. It reads a QA bug report (`bug.md`), scans the repo with bash, invokes Claude Code agents to diagnose and propose a fix, optionally validates in a git worktree, and writes `report.md`.

```bash
./rca-mas.sh bug.md
cat .rca-mas/runs/latest/report.md
```

## Authoritative files

- `architecture.md` — locked architecture reference (this folder)
- `code_practices.md` — implementation authority: bash patterns, CLI contract, agent tool restrictions, security rules
- `config/defaults.env` — every tunable parameter (turns, timeouts, confidence thresholds, model)
- `plan.md` — build order and per-file implementation spec

## Repo layout

```
rca-mas/
├── rca-mas.sh                    ← entry point: arg parsing, prereq checks, execs orchestrator
├── run.sh                        ← convenience wrapper (lint, test-*, run, report, clean)
├── Makefile                      ← same targets as run.sh (if make is installed)
├── config/defaults.env           ← ALL tunable parameters — change here, nowhere else
├── scripts/
│   ├── orchestrator.sh           ← pipeline controller, owns run lifecycle
│   ├── briefing.sh               ← pure bash repo scan, zero LLM calls
│   ├── claude_json.sh            ← shared run_claude_schema() helper for all agents
│   ├── extract_agent1a_stream.sh ← parses stream-json JSONL from Agent 1a
│   ├── finalize_agent1a_summary.sh ← forces FINAL FINDINGS if agent timed out
│   ├── check_agent1a_quality.sh  ← gates checkpoint quality (ok / weak)
│   ├── recover_agent1a_findings.sh ← fallback evidence extraction when quality is weak
│   └── report.sh                 ← reads JSON files, writes report.md
├── lib/
│   ├── log.sh                    ← die/warn/info/log_event (JSONL)
│   ├── json.sh                   ← extract_structured, jq_field, assert_valid_json
│   ├── paths.sh                  ← make_run_id, init_run_dir, update_latest_symlink
│   └── cleanup.sh                ← register_worktree, run_cleanup (trap EXIT)
├── collectors/
│   ├── git.sh                    ← git log, blame, recent merges for mentioned files
│   ├── deps.sh                   ← import tracing for Python, JS/TS, Go
│   ├── errors.sh                 ← fixed-string grep across repo for each error string
│   └── testrunner.sh             ← detect test framework, map src→test files
├── prompts/
│   ├── investigation.md          ← Agent 1a system prompt (toolful investigation)
│   ├── investigation_write.md    ← checkpoint-write phase prompt
│   ├── diagnosis.md              ← Agent 1b system prompt (schema-enforced synthesis)
│   ├── agent1b_repair.md         ← Agent 1b one-shot repair prompt
│   ├── solution.md               ← Agent 2 system prompt
│   ├── agent2_repair.md          ← Agent 2 one-shot repair prompt
│   ├── agent1a_force_summary.md  ← forced finalization prompt
│   ├── agent1a_recover_from_evidence.md ← evidence recovery prompt
│   └── validation.md             ← Agent 2.5 system prompt
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── templates/
│   └── CLAUDE.md.snippet         ← append to target repo's CLAUDE.md for chat-driven mode
├── tests/
│   ├── fixtures/                 ← static JSON/MD used by synthetic tests (not real runs)
│   │   ├── sample_bug.md
│   │   ├── sample_diagnosis.json
│   │   ├── sample_solution.json
│   │   ├── sample_validation.json
│   │   └── smoke_bug.md
│   ├── real_repos/
│   │   └── click/
│   │       ├── bugs/bug1.md … bug5.md  ← real pallets/click bug reports
│   │       └── expected/               ← known fix SHAs, affected files, metadata
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   ├── test_smoke_report_only.sh
│   └── test_real_repo_briefing.sh
├── docs/                         ← 16 reference docs (see docs/index.md)
├── examples/bug.md
├── architecture.md               ← locked architecture reference
├── code_practices.md             ← implementation spec
└── plan.md                       ← build order
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

```text
bug.md → briefing.sh (bash, 0 LLM calls)
       → Agent 1a investigation (toolful, full repo access)
       → checkpoint-write phase (1-turn synthesis)
       → Agent 1b diagnosis (1-turn schema enforcement)
       → Agent 2 solution (single pass, read-only)
       → Agent 2.5 validation (--validate only, isolated worktree)
       → report.md
```

Agent 1 is split into two phases: **1a** (free-text, full repo access, writes checkpoint.json) and **1b** (schema-enforced, reads checkpoint only, emits diagnosis.json). This ensures diagnosis output is always produced — 1a uses all turns for investigation, 1b has a dedicated budget for synthesis.

Agent 2 is a single pass with a one-shot repair fallback on schema failure.

Each stage receives only the previous stage's output (context funnel). Agent 1b sees only checkpoint + bug report. Agent 2 never sees the raw repo.

## Agent tool restrictions

| Agent | Tools | Bash allowed |
| --- | --- | --- |
| Agent 1a (investigation) | Read, Grep, Glob, Bash | git log/blame/show/diff/status, rg, grep, find, cat, wc, head, tail, ls — read-only only |
| checkpoint-write | (none — 1-turn claude call) | none |
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
| --- | --- | --- |
| Change agent turn budgets or timeouts | `config/defaults.env` | `docs/cli-reference.md` |
| Change confidence thresholds | `config/defaults.env` | `docs/agent-contracts.md` |
| Change the model | `RCA_MODEL` in `config/defaults.env` | — |
| Improve Agent 1a investigation | `prompts/investigation.md` | `docs/agent-contracts.md` |
| Improve Agent 1b diagnosis quality | `prompts/diagnosis.md` | `docs/agent-contracts.md` |
| Change fix output format | `prompts/solution.md` + `schemas/solution.schema.json` | `docs/schemas.md` |
| Add a collector | new file in `collectors/`, register in `scripts/briefing.sh` | `docs/briefing-and-collectors.md` |
| Add a report section | `scripts/report.sh` | `docs/run-artifacts.md` |
| Add a schema field | `schemas/*.schema.json` + matching prompt + `docs/schemas.md` | `docs/schemas.md` |
| Debug a failed run | read `log.jsonl`, check `*.raw.json` | `docs/troubleshooting.md` |
| Understand a stage in depth | — | `docs/pipeline-flow.md` |
| Understand worktree validation | — | `docs/validation-worktree.md` |
| Understand security rules | — | `docs/security-model.md` |
| Understand why a decision was made | — | `docs/decisions.md` |
| Add or run tests | `tests/` | `docs/testing-guide.md` |

## Documentation update rule

**When you change code, update the matching doc in the same step.**

| Code change | Doc to update |
| --- | --- |
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

## Reference map

| Topic | Where to read |
| --- | --- |
| Full architecture with diagrams | `architecture.md` |
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

## Testing

### Which command to use when

| Situation | Command | Time |
| --- | --- | --- |
| Writing code, want fast feedback | `bash run.sh test-fast` | ~2 min |
| Changed `briefing.sh` or a collector | `bash run.sh test-briefing` | ~4 min |
| Want quick real-repo signal | `bash run.sh test-real-repo-quick` | ~40s |
| Before moving to the next step | `bash run.sh lint && bash run.sh test` | ~6 min |
| Full pre-release check | `bash run.sh test-full` | ~9 min |

### What each suite tests

| Suite | What it verifies | Uses |
| --- | --- | --- |
| `test_briefing.sh` | `briefing.sh` end-to-end: metadata, collectors, error extraction, path safety | Tiny controlled temp repo |
| `test_collectors.sh` | Each collector: exits 0, correct headers, edge cases | Tiny controlled temp repo |
| `test_json_schemas.sh` | Schema validity, fixture validation, `lib/json.sh` helpers | JSON fixtures only (no repo) |
| `test_smoke_report_only.sh` | Full pipeline wiring, all output files, report sections | Fixture JSON, no Claude calls |
| `test_real_repo_briefing.sh` | Briefing quality on real bugs with known fixes | pallets/click clone |

**Note on fixtures:** Files under `tests/fixtures/` are hand-authored test inputs with `run_id: "fixture-run"`. They exist solely to test schema validation and pipeline wiring — they are not real agent outputs.

### Real-repo test setup

Requires pallets/click cloned locally:
```bash
git clone https://github.com/pallets/click /path/to/test-repos/click
RCA_REAL_REPO_ROOT=/path/to/test-repos/click bash run.sh test-real-repo
```

### Key commands

```bash
bash run.sh lint                 # bash -n syntax check on all scripts
bash run.sh test-fast            # lint + schemas + smoke
bash run.sh test-briefing        # briefing + collectors tests
bash run.sh test-schemas         # schema + fixture tests only (~5s)
bash run.sh test                 # all 4 synthetic suites
bash run.sh test-real-repo-quick # bugs 1+4 only
bash run.sh test-real-repo       # all 5 real-repo bugs
bash run.sh test-full            # all synthetic + all real-repo bugs
bash run.sh run                  # ./rca-mas.sh examples/bug.md
bash run.sh run-validate         # ./rca-mas.sh examples/bug.md --validate
bash run.sh report               # cat .rca-mas/runs/latest/report.md
bash run.sh clean                # rm -rf .rca-mas/runs .rca-mas-worktrees
```

If `make` is installed, replace `bash run.sh` with `make`.
