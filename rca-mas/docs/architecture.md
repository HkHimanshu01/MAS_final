# Architecture

RCA MAS is a CLI tool that compresses 30–60 minute manual bug investigations into 3–8 minute automated reports. A QA engineer drops in a bug report (`bug.md`); the tool returns a developer-ready root-cause analysis with a proposed fix.

---

## Pipeline

```
bug.md
  │
  ▼
briefing.sh           ← pure bash, zero LLM calls, 2–30s
  │  outputs: briefing.md, errors.txt, MAX_TURNS, TIMEOUT, REPO_TIER
  │
  ▼
Agent 1a (Investigation) ← Claude Code, free-text, reads repo, writes checkpoint.json
  │  confidence ≥ 0.7 → stop early and write final checkpoint
  │
  ▼
Agent 1b (Conclusion) ← Claude Code, schema-enforced, reads checkpoint, writes diagnosis.json
  │  always small budget (5 turns) — synthesis only, no re-investigation
  │
  ▼
Agent 2 (Solution)    ← Claude Code, reads diagnosis.json, writes solution.json + patches
  │  confidence < 0.5 → writes NO_FIX instead of a bad patch
  │
  ▼
Agent 2.5 (Validate)  ← optional (--validate flag), applies patch in worktree, runs tests
  │
  ▼
report.md             ← assembled by orchestrator from all JSON outputs
```

Agent 1 is split into two phases because schema-enforced output (`--json-schema`) forces the model to reserve its final turn for JSON production rather than investigation. Separating the phases means Agent 1a can use every turn for investigation, and Agent 1b focuses entirely on synthesis.

Each stage sees less context than the previous (context funnel). Agent 1a sees the whole repo. Agent 1b sees only the checkpoint and bug report. Agent 2 sees only `briefing.md + diagnosis.json`. Agent 2.5 sees only `solution.json + test output`.

---

## Repo Layout

```
rca-mas/
├── rca-mas.sh                  ← CLI entry point (orchestrator)
├── config/
│   └── defaults.env            ← all tunable parameters
├── lib/
│   └── log.sh                  ← die/warn/info/log_event helpers
├── scripts/
│   ├── briefing.sh             ← phases 1-6 repo scan
│   └── collectors/
│       ├── git.sh              ← git history + blame
│       ├── deps.sh             ← import tracing
│       ├── errors.sh           ← fixed-string search across repo
│       └── testrunner.sh       ← test framework detection + src→test mapping
├── prompts/
│   ├── agent1.md               ← Agent 1 system prompt
│   ├── agent2.md               ← Agent 2 system prompt
│   └── agent2_5.md             ← Agent 2.5 system prompt
├── schemas/
│   ├── diagnosis.schema.json
│   ├── solution.schema.json
│   └── validation.schema.json
├── tests/
│   ├── test_briefing.sh
│   ├── test_collectors.sh
│   ├── test_json_schemas.sh
│   ├── test_smoke_report_only.sh
│   ├── test_real_repo_briefing.sh
│   ├── fixtures/
│   └── real_repos/click/
├── docs/
├── examples/
│   ├── bug.md
│   └── sample-report.md
└── Makefile
```

Run outputs go under the **target repo**, not the tool repo:

```
<target-repo>/
└── .rca-mas/
    ├── runs/
    │   ├── <RUN_ID>/           ← one directory per run (timestamp-based ID)
    │   └── latest -> <RUN_ID>  ← symlink to most recent run
    └── ...

../.rca-mas-worktrees/           ← sibling directory to target repo (Agent 2.5 only)
    └── <RUN_ID>/
```

---

## Path Separation

Two roots are always distinct:

| Variable | Points to | Set by |
|---|---|---|
| `TOOL_ROOT` | The `rca-mas/` directory (scripts, prompts, schemas, config) | Orchestrator at startup |
| `TARGET_REPO_ROOT` | The repo being analyzed | CLI argument or `cd` |
| `RUN_DIR` | `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}` | Orchestrator at startup |

Scripts in `TOOL_ROOT` never write to their own directory. All outputs go under `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/`.

---

## Component Responsibilities

### briefing.sh
Pure bash. Reads `bug.md` and scans the target repo. Produces `briefing.md` (structured context document) and `errors.txt` (one search string per line). Zero LLM calls. Saves Agent 1 approximately 8–12 orientation turns by pre-computing file locations, git history, dependency chains, and error sources.

### Agent 1a — Investigation
Claude Code in agentic loop with no output schema. Reads `briefing.md` and uses Read/Grep/Glob tools to explore the repo. Writes `checkpoint.json` — an intermediate findings file — after reading its first 2–3 files and again as a final summary before stopping. Stops early if confidence exceeds `RCA_CONFIDENCE_STOP` (default 0.7). Turn budget is scaled to repo size via the tier system. Free-text output mode means all turns are available for investigation.

### Agent 1b — Conclusion
Claude Code with `--json-schema` enforcement. Reads `checkpoint.json` written by Agent 1a plus the original bug report. Synthesises the checkpoint into the final `diagnosis.json` in 3–5 turns. Does not re-investigate. If Agent 1a timed out before writing a real checkpoint, Agent 1b emits an honest minimal diagnosis rather than hallucinating evidence.

### Agent 2 — Solution
Claude Code. Reads `briefing.md` + `diagnosis.json`. Single pass (1 turn). Writes `solution.json` and patch files as unified diffs. If confidence is below `RCA_CONFIDENCE_NOFX` (default 0.5), writes a `NO_FIX` response instead of producing a bad patch.

### Agent 2.5 — Validation (optional)
Claude Code. Invoked only with `--validate` flag. Creates a git worktree sibling to the target repo, applies the patch from `solution.json`, runs the detected test suite, captures output. Writes `validation.json`. Never touches the main working tree.

### Orchestrator (`rca-mas.sh`)
Bash. Drives the entire pipeline: sources config, runs briefing, invokes each agent via `claude --max-turns`, assembles `report.md`, writes `manifest.json` and `cost_summary.json`, manages the `latest` symlink, runs cleanup. Gracefully degrades at every step — a failed stage writes partial output rather than crashing.

---

## Tier System

Repo size drives Agent 1a's turn budget and wall-clock timeout. Agent 1b always gets a small fixed budget (5 turns, 120s) regardless of tier.

| Tier | File Count | Agent 1a turns | Agent 1a timeout |
|---|---|---|---|
| XS | < 100 | 20 | 360s |
| S | 100–499 | 30 | 900s |
| M | 500–1999 | 45 | 1500s |
| L | ≥ 2000 | 60 | 2400s |

File count is the number of git-tracked files (`git ls-files | wc -l`). All breakpoints and budgets live in `config/defaults.env` and are overridable via environment variables before running.

---

## Graceful Degradation

| Failure | Behavior |
|---|---|
| Collector times out or errors | Warning appended to `## Briefing Warnings` in briefing.md; pipeline continues |
| Agent 1a times out mid-loop | Last-written checkpoint survives; Agent 1b synthesises diagnosis from it |
| Agent 1b times out | Orchestrator synthesises diagnosis.json from checkpoint using bash; confidence preserved |
| Agent 2 low confidence | `status: NO_FIX` in `solution.json`; report shows this clearly |
| Agent 2.5 tests fail | `status: FAIL` in `validation.json`; patch still present in run directory |
| No test framework found | `TEST_COMMAND: UNKNOWN` in briefing.md |
| Non-git target repo | Filesystem fallback for file existence checks |

Nothing in the pipeline throws an unhandled exit. Every failure mode has an explicit output.

---

## Security Boundaries

- Never reads `.env`, `.pem`, `.key`, `id_rsa`, `.secret`, `.token`, `.passwd`, `.password`
- Never runs `curl`, `wget`, `ssh`, `scp`
- Never commits, pushes, or creates branches in the target repo
- Never modifies source files in the target repo directly (validation uses a disposable worktree)
- Bug report content is treated as untrusted input — all agent prompts include prompt-injection defenses
- Each agent has explicit tool restrictions in its Claude Code invocation flags
