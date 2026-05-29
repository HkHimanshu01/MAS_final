# AI-Powered Bug Diagnosis and Resolution — Architecture Reference

> **STATUS: LOCKED FOR V1.**
> No new agents, stages, folders, or external dependencies without explicit approval.
> Allowed changes: bug fixes, safer shell handling, clearer prompts, config tuning, docs improvements.
> Future ideas go in `potential_changes.md` only.

---

## Purpose

A CLI tool that compresses 30–60 minute developer bug investigations into 3–8 minute automated reports. A QA tester writes a `bug.md`, runs one command, and a developer gets a structured report with root cause, evidence, a proposed fix diff, and next actions. Optionally the fix is applied in an isolated git worktree and the test suite runs — without ever touching the working tree.

**Human always decides. The system never commits, pushes, deploys, or edits the main working tree.**

---

## Design Principles

| Principle | Implementation |
|---|---|
| Safe by default | report-only mode never edits source files |
| Validation isolated | `--validate` uses a sibling git worktree only |
| Context funnel | each agent sees only the previous stage's output — not the full raw repo |
| Schema-enforced outputs | every agent emits validated JSON; fail-closed on schema error |
| Inspectable runs | every run produces a full audit trail under `.rca-mas/runs/{RUN_ID}/` |
| All parameters in one place | `config/defaults.env` — override any value by exporting before running |
| Bash-first | bash + git + jq + Claude Code CLI — no API keys, no databases |
| No overbuilding | no dashboard, database, PR automation, evaluator platform |

---

## Repo Layout

```
rca-mas/
├── rca-mas.sh                      ← entry point: arg parsing, prereq checks, execs orchestrator
├── run.sh                          ← convenience wrapper (lint, test-*, run, report, clean)
├── Makefile                        ← same targets as run.sh (if make is installed)
├── CLAUDE.md                       ← Claude Code project instructions
├── README.md                       ← user-facing quick start
├── architecture.md                 ← this file
├── code_practices.md               ← implementation authority for Claude Code
├── plan.md                         ← build order and per-file spec
├── potential_changes.md            ← future ideas (never modify plan/architecture)
│
├── config/
│   └── defaults.env                ← ALL tunable parameters — change here, nowhere else
│
├── scripts/
│   ├── orchestrator.sh             ← pipeline controller, owns run lifecycle
│   ├── briefing.sh                 ← pure bash repo scan, zero LLM calls
│   ├── claude_json.sh              ← shared run_claude_schema() helper for all agents
│   ├── extract_agent1a_stream.sh   ← parses stream-json JSONL from Agent 1a
│   ├── finalize_agent1a_summary.sh ← forces FINAL FINDINGS if agent didn't write them
│   ├── check_agent1a_quality.sh    ← gates checkpoint quality (ok / weak)
│   ├── recover_agent1a_findings.sh ← fallback evidence extraction if quality is weak
│   └── report.sh                   ← reads JSON files, writes report.md
│
├── lib/
│   ├── log.sh                      ← die/warn/info/log_event (JSONL)
│   ├── json.sh                     ← extract_structured, jq_field, assert_valid_json
│   ├── paths.sh                    ← make_run_id, init_run_dir, update_latest_symlink
│   └── cleanup.sh                  ← register_worktree, run_cleanup (trap EXIT)
│
├── collectors/
│   ├── git.sh                      ← git log, blame, recent merges for mentioned files
│   ├── deps.sh                     ← import tracing for Python, JS/TS, Go
│   ├── errors.sh                   ← fixed-string grep for every error string
│   └── testrunner.sh               ← detect test framework, map src→test files
│
├── prompts/
│   ├── investigation.md            ← Agent 1a system prompt (toolful investigation)
│   ├── investigation_write.md      ← checkpoint-write phase prompt
│   ├── diagnosis.md                ← Agent 1b system prompt (schema-enforced synthesis)
│   ├── solution.md                 ← Agent 2 system prompt
│   └── validation.md               ← Agent 2.5 system prompt
│
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
│
├── templates/
│   └── CLAUDE.md.snippet           ← append to target repo's CLAUDE.md for chat-driven mode
│
├── tests/
│   ├── fixtures/                   ← static JSON/MD inputs for synthetic tests
│   │   ├── sample_bug.md
│   │   ├── sample_diagnosis.json
│   │   ├── sample_solution.json
│   │   ├── sample_validation.json
│   │   └── smoke_bug.md
│   ├── real_repos/
│   │   └── click/
│   │       ├── bugs/bug1.md … bug5.md    ← real pallets/click bug reports
│   │       └── expected/                 ← known fix SHAs, files, metadata
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   ├── test_smoke_report_only.sh
│   └── test_real_repo_briefing.sh
│
├── docs/                           ← 16 reference docs (see docs/index.md)
└── examples/
    └── bug.md
```

---

## Path Rules

| Variable | Points to |
|---|---|
| `TOOL_ROOT` | `rca-mas/` — scripts, prompts, schemas, config |
| `TARGET_REPO_ROOT` | the repo being analyzed |
| `RUN_DIR` | `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` |

- Read scripts, prompts, schemas from `TOOL_ROOT`
- Run git commands and code search in `TARGET_REPO_ROOT`
- Write all outputs under `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}`
- Never scan `rca-mas/` source files when analyzing a different target repo

---

## Pipeline

```
bug.md / --issue <N>
  │
  ▼
[briefing.sh]  ─── pure bash, 4 collectors, 0 LLM calls
  │  writes: briefing.md, errors.txt
  ▼
[Agent 1a — Investigation]  ─── toolful agentic loop, full repo access
  │  tools: Read, Grep, Glob, Bash (read-only git/grep/find)
  │  writes: agent1a_output.txt.stream → agent1a_output.txt, agent1a_evidence.txt
  │          agent1a_findings.md (canonical FINAL FINDINGS)
  ▼
[checkpoint-write phase]  ─── 1-turn synthesis, no investigation
  │  reads: agent1a_findings.md + agent1a_evidence.txt
  │  writes: checkpoint.json
  ▼
[Agent 1b — Diagnosis]  ─── 1-turn schema enforcement, no repo access
  │  reads: checkpoint.json only
  │  writes: diagnosis.json (schema-validated)
  ▼
[Agent 2 — Solution]  ─── single pass, read-only
  │  reads: diagnosis.json + briefing.md (deps section) + affected file sources
  │  writes: solution.json (schema-validated), patches/fix.diff
  ▼
[Agent 2.5 — Validation]  ─── only with --validate
  │  creates: sibling git worktree
  │  applies: patches/fix.diff
  │  runs: test suite
  │  writes: validation.json
  │  removes: worktree (unless RCA_KEEP_WORKTREE=1)
  ▼
[report.sh]  ─── bash, JSON → markdown
  │  reads: diagnosis.json, solution.json, validation.json, cost_summary.json
  ▼
report.md → Developer
```

---

## Why Agent 1 Is Split Into 1a and 1b

Agent 1a has many turns to freely investigate. Using all turns for investigation means it can hit the turn/timeout cap mid-conclusion and produce a cut-off output.

The split solves this:

| Phase | Budget | Task |
|---|---|---|
| Agent 1a | many turns (tier-based, 15–50) | toolful investigation — read code, grep, git blame |
| checkpoint-write | 1 turn | convert agent1a_findings.md + evidence into checkpoint.json |
| Agent 1b | 1 turn | convert checkpoint.json into schema-validated diagnosis.json |

Agent 1b never re-investigates. It only enforces the schema. If checkpoint quality is weak, it caps confidence at 0.4 rather than fabricating.

---

## Context Funnel

Each agent sees less than the previous. This prevents earlier exploration noise from corrupting later reasoning.

```
Agent 1a    full repo access + briefing.md (~10K+ tokens)
              │
              ▼  checkpoint.json — structured findings only
Agent 1b    checkpoint.json + bug.md (~3K tokens)
              │
              ▼  diagnosis.json — clean schema-validated output
Agent 2     diagnosis.json + affected file sources + deps section (~5K tokens)
              │
              ▼  solution.json + patches/fix.diff
Agent 2.5   diagnosis.json + solution.json + affected file sources (~4K tokens)
```

Agent 2 never sees Agent 1a's 30K+ tokens of raw exploration.

---

## Agent Tool Restrictions

| Agent | Tools | Bash |
|---|---|---|
| Agent 1a (investigation) | Read, Grep, Glob, Bash | git log/blame/show/diff/status, rg, grep, find, cat, wc, head, tail, ls — read-only only |
| checkpoint-write phase | (none — 1-turn claude call) | none |
| Agent 1b (conclusion) | Read, Grep, Glob | none — synthesis only |
| Agent 2 | Read, Grep, Glob | none |
| Agent 2.5 | Read, Grep, Glob, Edit, Bash | git status/diff/apply, test runners (pytest/go test/npm test etc.), worktree only |

---

## Schema-Enforced Outputs

Every agent output is validated against a JSON schema before the next stage runs.

| Output | Schema | On failure |
|---|---|---|
| `checkpoint.json` | (internal — mapped to diagnosis schema fields) | degraded seed written, Agent 1b fails fast |
| `diagnosis.json` | `schemas/diagnosis.schema.json` | one-shot repair attempt; fail-closed placeholder on total failure |
| `solution.json` | `schemas/solution.schema.json` | one-shot repair attempt; NO_FIX placeholder on total failure |
| `validation.json` | `schemas/validation.schema.json` | VALIDATION_FAILED status |

Fail-closed means: if schema enforcement fails completely, the pipeline writes a placeholder with `confidence: 0.0` and an error description. It never fabricates a diagnosis or patch.

---

## Run Artifacts (Full Audit Trail)

Every run writes to `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/`. The `latest` symlink always points to the most recent run. Old runs are never deleted automatically — run `make clean` or `bash run.sh clean` to remove.

```
.rca-mas/
└── runs/
    ├── latest -> 20260504-101523        ← symlink to most recent run
    └── 20260504-101523/
        ├── manifest.json                ← run metadata, stage statuses, tool versions
        ├── log.jsonl                    ← structured event log (one JSON per line)
        ├── bug.md                       ← copy of input bug report
        ├── briefing.md                  ← pre-computed repo context (from briefing.sh)
        ├── errors.txt                   ← error strings extracted from bug.md
        ├── test_command.txt             ← detected test command
        │
        ├── agent1a_prompt.md            ← assembled investigation prompt
        ├── agent1a_output.txt.stream    ← raw stream-json JSONL from claude
        ├── agent1a_stderr.txt           ← stderr from claude (separate from stream)
        ├── agent1a_output.txt           ← extracted assistant text + finalization
        ├── agent1a_evidence.txt         ← tool calls, tool results, result metadata
        ├── agent1a_findings.md          ← canonical FINAL FINDINGS (checkpoint writer input)
        ├── agent1a_meta.env             ← session_id, stop_reason, exit_code
        ├── agent1a_quality.env          ← quality=ok|weak, finalization/recovery status
        ├── agent1a.log                  ← bash-level log for Agent 1a helper scripts
        ├── agent1a_forced_summary.json  ← raw json from forced finalization call
        ├── agent1a_recovery_summary.json ← raw json from evidence-recovery (if run)
        │
        ├── agent1a_write_prompt.md      ← checkpoint-write phase prompt
        ├── agent1a_write_output.txt.json ← raw json from checkpoint-write call
        ├── checkpoint.json              ← structured findings; read by Agent 1b
        │
        ├── agent1b_prompt.md            ← assembled conclusion prompt
        ├── agent1b_raw.json             ← raw Claude JSON from Agent 1b call
        ├── agent1b_stderr.txt
        ├── agent1b_meta.env             ← exit_code, schema_valid, repair_attempted, etc.
        ├── agent1b_quality.env          ← agent1b_quality=ok|failed
        ├── agent1b_repair_prompt.md     ← (only if repair was triggered)
        ├── agent1b_repair_raw.json      ← (only if repair was triggered)
        ├── agent1b.log
        ├── diagnosis.raw.json           ← full Claude JSON wrapper (for token inspection)
        ├── diagnosis.json               ← schema-validated diagnosis
        ├── diagnosis.invalid.json       ← (only if schema validation failed)
        │
        ├── agent2_prompt.md             ← assembled solution prompt
        ├── agent2_raw.json              ← raw Claude JSON from Agent 2 call
        ├── agent2_stderr.txt
        ├── agent2_meta.env              ← exit_code, schema_valid, solution_status, etc.
        ├── agent2_quality.env           ← agent2_quality=ok|failed
        ├── agent2_repair_prompt.md      ← (only if repair was triggered)
        ├── agent2_repair_raw.json       ← (only if repair was triggered)
        ├── agent2.log
        ├── solution.raw.json            ← full Claude JSON wrapper
        ├── solution.json                ← schema-validated solution
        ├── solution.invalid.json        ← (only if schema validation failed)
        ├── patches/
        │   └── fix.diff                 ← unified diff (only when recommendation=FIX)
        │
        ├── validation.json              ← SKIPPED if report-only; result if --validate
        ├── validation.raw.json          ← (only with --validate)
        │
        ├── report.md                    ← developer-readable output (always written)
        └── cost_summary.json            ← stage durations, model, tier, turns used
```

### Key intermediate files explained

| File | What it is | Why it exists |
|---|---|---|
| `agent1a_output.txt.stream` | Raw JSONL events from Agent 1a | Source of truth for what claude actually emitted |
| `agent1a_evidence.txt` | All tool calls + results (clipped at 4096 bytes each) | Full evidence record; primary input to checkpoint-write |
| `agent1a_findings.md` | Canonical FINAL FINDINGS in structured markdown | Bridge between investigation and checkpoint; always exists after Agent 1a |
| `agent1a_quality.env` | `quality=ok\|weak` + reasons | Gates whether recovery runs; key debugging signal |
| `checkpoint.json` | Structured investigation findings | Durable handoff from Agent 1a to Agent 1b; survives timeout |
| `agent1b_meta.env` | Schema validation result, repair status | Audit record for Agent 1b execution |
| `diagnosis.invalid.json` | Failed schema candidate | Preserved for diagnosing prompt regressions |
| `solution.invalid.json` | Failed schema candidate | Preserved for diagnosing prompt regressions |
| `log.jsonl` | One JSON event per line from every script | Primary debugging tool; filter by stage or level |
| `manifest.json` | Run metadata + stage statuses | Single file to understand what happened in a run |

### Inspecting a run

```bash
# Read the final report
cat .rca-mas/runs/latest/report.md

# Check what happened at each stage
cat .rca-mas/runs/latest/log.jsonl | jq .

# See diagnosis confidence and root cause
cat .rca-mas/runs/latest/diagnosis.json | jq '{root_cause, confidence}'

# Check if Agent 1a quality was ok
cat .rca-mas/runs/latest/agent1a_quality.env

# See raw investigation findings before schema enforcement
cat .rca-mas/runs/latest/agent1a_findings.md

# Check if checkpoint was a degraded seed
cat .rca-mas/runs/latest/checkpoint.json | jq '._degraded_seed // false'

# See why schema validation failed (if it did)
cat .rca-mas/runs/latest/diagnosis.invalid.json
```

---

## Briefing Phase (bash, zero LLM)

**Role:** Pre-digests the repo before any agent runs. Saves 8–12 turns of orientation.

**4 Collectors:**

| Collector | What it produces |
|---|---|
| `git.sh` | `git log` for mentioned files, recent merges, `git blame` |
| `deps.sh` | Import/require chains for mentioned files (Python, JS/TS, Go) |
| `errors.sh` | Fixed-string grep for every error string across full repo |
| `testrunner.sh` | Detected test command + src→test file mapping |

Each collector runs with `timeout $RCA_COLLECTOR_TIMEOUT`. Failure logs a warning and leaves that section empty — the pipeline continues.

---

## Graceful Degradation

Every failure is a warning, not a crash. The pipeline always continues and surfaces degradation in the report.

| Failure | Behaviour |
|---|---|
| Collector fails | Warning in `log.jsonl`; section left empty; Agent 1a cold-starts |
| Agent 1a timeout + checkpoint exists | Use checkpoint; stamp confidence 0.4; continue |
| Agent 1a timeout + no checkpoint | Emit `root_cause: "UNKNOWN"`, confidence 0.0 |
| Agent 1a quality weak | Recovery pass runs against `agent1a_evidence.txt` |
| Checkpoint-write produces non-JSON | Degraded seed written; Agent 1b fails fast (no fabrication) |
| Agent 1b schema invalid | One repair attempt; fail-closed placeholder on total failure |
| `diagnosis.confidence < RCA_CONFIDENCE_NOFX` | Agent 2 returns NO_FIX; skip validation |
| Agent 2 schema invalid | One repair attempt; NO_FIX placeholder on total failure |
| No test runner detected | Validation reports `NOT_RUN_NO_COMMAND`; still writes test diff |
| All stages fail | `report.md` still written; shows what failed and why |

---

## All Tunable Parameters

**All parameters live in `config/defaults.env`.** Override by exporting before running:

```bash
RCA_MODEL=claude-opus-4-7 RCA_TURNS_L=70 ./rca-mas.sh bug.md
```

### Turn and timeout budgets

| Variable | Default | Effect |
|---|---|---|
| `RCA_A1A_TURNS_XS/S/M/L` | 200 (all tiers) | Agent 1a max turns — emergency cap; cost cap is primary throttle |
| `RCA_A1A_TIMEOUT_XS/S/M/L` | 900s (all tiers) | Agent 1a wall-clock limit |
| `RCA_A1B_TURNS` | 20 | Agent 1b synthesis turns |
| `RCA_A1B_TIMEOUT` | 120s | Agent 1b wall-clock limit |
| `RCA_TIER_XS/S/M` | 100/500/2000 | File count breakpoints for tier selection |
| `RCA_AGENT2_TURNS` | 20 | Agent 2 max turns |
| `RCA_AGENT2_TIMEOUT` | 600s | Agent 2 wall-clock limit |
| `RCA_AGENT25_TURNS` | 15 | Agent 2.5 max turns |
| `RCA_AGENT25_TIMEOUT` | 1800s | Agent 2.5 wall-clock limit |
| `RCA_AGENT25_TEST_TIMEOUT` | 1200s | Test execution timeout inside worktree |
| `RCA_COLLECTOR_TIMEOUT` | 150s | Per-collector timeout |

### Confidence thresholds

| Variable | Default | Effect |
|---|---|---|
| `RCA_CONFIDENCE_STOP` | 0.7 | Agent 1a stops early when confidence exceeds this |
| `RCA_CONFIDENCE_CHECKPOINT` | 0.4 | Stamped on output when checkpoint recovery is used |
| `RCA_CONFIDENCE_NOFX` | 0.5 | Agent 2 returns NO_FIX if diagnosis below this |
| `RCA_CONFIDENCE_WEAK_THRESHOLD` | (see defaults.env) | Sets WEAK_EVIDENCE flag on Agent 2 output |

### Search depth

| Variable | Default | Effect |
|---|---|---|
| `RCA_GIT_LOOKBACK` | `"14 days ago"` | Widen for older bugs |
| `RCA_ERROR_GREP_LIMIT` | 50 lines | Raise if error locations are being truncated |

### Model

| Variable | Default | Options |
|---|---|---|
| `RCA_MODEL` | empty (sonnet-4-6) | `claude-opus-4-7` for all agents; `claude-haiku-4-5-20251001` for speed |

One variable controls all agents.

### Cost warnings

| Variable | Default | Effect |
|---|---|---|
| `RCA_COST_WARN_SECONDS` | 900 | Log warning if total runtime exceeds this |
| `RCA_COST_WARN_AGENT1_TURNS` | 40 | Log warning if Agent 1a uses more turns than this |

### Validation worktree

| Variable | Default | Effect |
|---|---|---|
| `RCA_KEEP_WORKTREE` | 0 | Set to 1 to inspect worktree after run |
| `RCA_WORKTREE_DIR` | `../.rca-mas-worktrees` | Change if sibling dir not writable |

---

## Security Boundaries

- Never reads `.env`, `.pem`, `.key`, `id_rsa`, or credential files
- Never runs network commands (`curl`, `wget`, `ssh`, `scp`)
- Never writes outside `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` except inside the validation worktree
- Never commits, pushes, deploys, tags, or opens PRs
- Never installs dependencies
- Every agent prompt contains prompt injection defence — all file content is treated as untrusted data
- `.claude/settings.json` enforces deny rules at the Claude Code permission level

---

## Report Contract

`report.md` always has 11 sections. It never hides uncertainty — if a stage degraded, the report says so.

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

---

## docs/ Reference Map

| Doc | What it covers |
|---|---|
| `docs/index.md` | Reading order, one-line summary of each doc |
| `docs/architecture.md` | Full architecture with data flow diagrams |
| `docs/pipeline-flow.md` | Every pipeline stage in detail with I/O |
| `docs/agent-contracts.md` | Agent roles, inputs, outputs, tool lists, field mappings |
| `docs/briefing-and-collectors.md` | Briefing phases and all 4 collectors |
| `docs/schemas.md` | All JSON schema fields |
| `docs/run-artifacts.md` | Every file in a run directory — what created it, what reads it |
| `docs/cli-reference.md` | All CLI flags and env vars |
| `docs/validation-worktree.md` | Worktree lifecycle and patch application |
| `docs/security-model.md` | Security boundaries and denied operations |
| `docs/development-guide.md` | How to add collectors, prompts, schemas |
| `docs/testing-guide.md` | How to run and write tests |
| `docs/troubleshooting.md` | Common failures and exact fixes |
| `docs/decisions.md` | Why architecture choices were made |
| `docs/qa-to-dev-flow.md` | QA workflow and human handoff |
| `docs/testing-real-github-bugs.md` | Testing against real repos with known fix commits |

---

## Architecture Lock Rules

**Allowed without approval:** bug fixes, safer shell handling, clearer prompts, better report wording, config tuning, docs improvements, tests.

**Not allowed without explicit approval:** new agents, new folders beyond the approved structure, dashboard or web UI, database, PR creation or auto-commit/push, retry/evaluator loops, JIRA/Slack integration, any new external dependency.
