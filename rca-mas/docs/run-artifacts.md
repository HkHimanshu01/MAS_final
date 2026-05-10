# Run Artifacts

Every file produced under `.rca-mas/runs/{RUN_ID}/` during a run. What created it, what reads it, when it appears, and how to inspect it.

---

## Directory Structure

```
<target-repo>/
└── .rca-mas/
    └── runs/
        ├── latest -> 20260504-101523    ← symlink, always points to most recent run
        └── 20260504-101523/             ← RUN_ID = timestamp at run start
            ├── manifest.json
            ├── log.jsonl
            ├── bug.md
            ├── briefing.md
            ├── errors.txt
            ├── test_command.txt
            ├── agent1a_prompt.md        ← assembled investigation prompt
            ├── agent1a_output.txt       ← raw text output from Agent 1a
            ├── agent1a.log              ← Agent 1a stdout+stderr
            ├── checkpoint.json          ← written by Agent 1a; read by Agent 1b
            ├── agent1b_prompt.md        ← assembled conclusion prompt
            ├── agent1b.log              ← Agent 1b stdout+stderr
            ├── diagnosis.raw.json       ← full Claude JSON wrapper from Agent 1b
            ├── diagnosis.json           ← extracted, schema-validated diagnosis
            ├── solution.json
            ├── solution.raw.json
            ├── patches/
            │   └── fix_<name>.diff
            ├── validation.json           ← only with --validate
            ├── validation.raw.json       ← only with --validate
            ├── report.md
            └── cost_summary.json
```

---

## File Reference

### `manifest.json`
**Created by:** Orchestrator at startup
**Updated by:** Orchestrator at end of run
**Read by:** `make report`, CI integrations

Tracks the run lifecycle. Written in two phases: fields are initialised at startup and `ended_at` is filled at completion.

```json
{
  "run_id": "20260504-101523",
  "mode": "validate",
  "started_at": "2026-05-04T10:15:23Z",
  "ended_at": "2026-05-04T10:19:47Z",
  "tool_versions": {
    "rca_mas": "1.0.0",
    "claude_code": "1.x.x"
  },
  "bug_file": "bug.md",
  "repo_tier": "S",
  "max_turns": 25
}
```

---

### `log.jsonl`
**Created by:** Orchestrator at startup (empty)
**Written by:** All scripts (via `lib/log.sh` → `log_event`)
**Read by:** Debugging, post-mortems

Structured event log. One JSON object per line (JSONL format). Contains timestamps, stage names, durations, warnings, and error messages from every script in the pipeline.

```
{"ts":"2026-05-04T10:15:24Z","level":"info","stage":"briefing","msg":"collector ok","collector":"git","duration_seconds":"3"}
{"ts":"2026-05-04T10:15:27Z","level":"warn","stage":"briefing","msg":"collector failed","collector":"deps","reason":"timeout after 30s"}
{"ts":"2026-05-04T10:18:41Z","level":"info","stage":"agent1","msg":"diagnosis complete","confidence":"0.82","turns_used":"18"}
```

Inspect:
```bash
cat .rca-mas/runs/latest/log.jsonl | jq .
# Filter to warnings only:
cat .rca-mas/runs/latest/log.jsonl | jq 'select(.level == "warn")'
```

---

### `bug.md`
**Created by:** Orchestrator at startup (copied from input)
**Read by:** Agent 1, `briefing.sh`

The original bug report, copied into the run directory for reproducibility. Agents read from this copy, not the original file.

---

### `briefing.md`
**Created by:** `scripts/briefing.sh`
**Read by:** Agent 1, Agent 2

The structured context document. Contains all pre-computed repo information. Sections:

```
## Metadata
## Git History
## Dependencies
## Error Sources
## Test Mapping
## Briefing Warnings
```

Inspect:
```bash
cat .rca-mas/runs/latest/briefing.md
```

---

### `errors.txt`
**Created by:** `scripts/briefing.sh` (Phase 1)
**Read by:** `collectors/errors.sh`

One search string per line, extracted from quoted strings in `bug.md`. These are the strings `errors.sh` uses to grep across the repo.

```
TypeError: discount_value not found
discount_value
Cannot read properties of undefined
```

Inspect:
```bash
cat .rca-mas/runs/latest/errors.txt
```

---

### `test_command.txt`
**Created by:** `collectors/testrunner.sh`
**Read by:** `scripts/briefing.sh` (Phase 6, to backfill `TEST_COMMAND`)

Contains the detected test command on a single line, e.g. `pytest` or `go test ./...`. If no framework was detected, contains `UNKNOWN`.

---

### `agent1a_prompt.md`
**Created by:** Orchestrator before Agent 1a runs
**Read by:** Agent 1a (via `-p` flag), debugging

The assembled investigation prompt: `prompts/investigation.md` + bug report + briefing + run metadata including `CHECKPOINT_PATH`.

---

### `agent1a_output.txt`
**Created by:** `run_claude_freetext()` — raw text output from Agent 1a
**Read by:** Debugging only

Free-text output from the investigation phase. Not structured JSON. The useful output is `checkpoint.json`, not this file.

---

### `agent1a.log`
**Created by:** Orchestrator (stdout+stderr from the Agent 1a subprocess)
**Read by:** Debugging only

Contains bash-level logging from the Agent 1a invocation. Inspect this to diagnose tool permission errors or Claude exit codes.

---

### `checkpoint.json`
**Created by:** Agent 1a (written at least twice during investigation)
**Read by:** Agent 1b, orchestrator (timeout recovery)

The investigation's durable output. Agent 1a writes this early and updates it as findings accumulate. If Agent 1a is SIGKILL'd, the last-written checkpoint survives. The orchestrator writes a seed checkpoint before Agent 1a starts so there is always something to read.

```json
{
  "hypothesis": "...",
  "confidence": 0.85,
  "files_examined": ["src/click/core.py"],
  "call_chain": ["..."],
  "affected_files": ["src/click/core.py"],
  "supporting_evidence": [{"type": "code", "path": "...", "lines": "...", "note": "..."}],
  "rejected_hypotheses": [{"id": "h2", "reason": "..."}],
  "unknowns": ["..."],
  "introducing_commit": null,
  "next_best_action": "..."
}
```

Inspect:
```bash
cat .rca-mas/runs/latest/checkpoint.json | jq .
```

---

### `agent1b_prompt.md`
**Created by:** Orchestrator before Agent 1b runs
**Read by:** Agent 1b (via `-p` flag), debugging

The assembled conclusion prompt: `prompts/diagnosis.md` + bug report + run metadata (with checkpoint path). Does **not** include the full briefing — Agent 1b reads only the checkpoint.

---

### `agent1b.log`
**Created by:** Orchestrator (stdout+stderr from the Agent 1b subprocess)
**Read by:** Debugging only

---

### `diagnosis.json`
**Created by:** Agent 1b (schema-validated) or orchestrator bash synthesis (on Agent 1b timeout)
**Read by:** Agent 2, orchestrator

Root cause, confidence, evidence, hypotheses, affected files. See [schemas.md](schemas.md) for full field reference.

---

### `diagnosis.raw.json`
**Created by:** `run_claude_schema()` — full Claude JSON wrapper from Agent 1b
**Read by:** Debugging only

The complete unprocessed output from Agent 1b. Preserved for debugging parse failures or inspecting usage tokens.

---

### `solution.json`
**Created by:** Agent 2
**Read by:** Agent 2.5, orchestrator

Fix description, confidence, affected files, patch file locations. See [schemas.md](schemas.md) for full field reference.

---

### `raw_agent2_output.txt`
**Created by:** Orchestrator (captures raw Claude Code stdout for Agent 2)
**Read by:** Debugging only

Same purpose as `raw_agent1_output.txt` but for Agent 2.

---

### `patches/*.diff`
**Created by:** Agent 2
**Read by:** Agent 2.5, developer

Unified diff files for the proposed fix. Can be applied directly:

```bash
git apply .rca-mas/runs/latest/patches/fix_core.diff
# Or preview first:
git apply --check .rca-mas/runs/latest/patches/fix_core.diff
```

---

### `validation.json`
**Created by:** Agent 2.5 (only with `--validate`)
**Read by:** Orchestrator

Test result: `PASS`, `FAIL`, `ERROR`, or `SKIPPED`. See [schemas.md](schemas.md).

---

### `raw_agent25_output.txt`
**Created by:** Orchestrator (captures raw Claude Code stdout for Agent 2.5)
**Read by:** Debugging only

Only present when `--validate` was used.

---

### `report.md`
**Created by:** Orchestrator (assembled from all JSON outputs)
**Read by:** Developer

The human-readable output. 11 mandatory sections:

```
## Status
## Root Cause
## Confidence
## Evidence
## Affected Files
## Proposed Fix
## Patch Files
## Validation
## Cost / Runtime
## Unknowns / Risks
## Next Action
```

Inspect:
```bash
cat .rca-mas/runs/latest/report.md
# Or via Makefile:
make report
```

---

### `cost_summary.json`
**Created by:** Orchestrator at end of run
**Read by:** Developer, cost monitoring

Runtime and cost information for the run.

```json
{
  "model": "claude-sonnet-4-6",
  "repo_tier": "S",
  "agent1_turns_used": 18,
  "agent1_turns_budget": 25,
  "agent2_turns_used": 1,
  "total_wall_seconds": 264,
  "cost_warn": false
}
```

`cost_warn` is `true` if total runtime exceeded `RCA_COST_WARN_SECONDS` (default 480s) or if Agent 1 used more turns than `RCA_COST_WARN_AGENT1_TURNS` (default 40).

---

## The `latest` Symlink

```bash
# Always points to the most recent run directory
ls -la .rca-mas/runs/latest
# → .rca-mas/runs/latest -> 20260504-101523

# Read the latest report
cat .rca-mas/runs/latest/report.md
```

Old runs are never deleted automatically. Run `make clean` to remove all runs.

---

## Worktree (Agent 2.5 only)

Created at: `../.rca-mas-worktrees/{RUN_ID}/`

This is a sibling directory to the target repo, not inside it. It is removed after Agent 2.5 completes unless `RCA_KEEP_WORKTREE=1`. Not part of the `.rca-mas/runs/` tree — it is temporary working space only.

See [validation-worktree.md](validation-worktree.md) for details.
