# Pipeline Flow

Step-by-step execution from the moment you run `rca-mas.sh` to the final `report.md`. Each stage lists its inputs, outputs, and what happens on failure.

---

## Stage 0 — Orchestrator Startup

**Script:** `rca-mas.sh`

**What happens:**
1. Parses CLI arguments: `bug.md` path, `--validate` flag, `--issue` URL (optional)
2. Sources `config/defaults.env` — loads all `RCA_*` variables
3. Sources `lib/log.sh` — sets up `die`, `warn`, `info`, `log_event`
4. Resolves `TOOL_ROOT` (directory of `rca-mas.sh`) and `TARGET_REPO_ROOT` (current working directory or explicit arg)
5. Generates `RUN_ID` — timestamp-based string, e.g. `20260504-101523`
6. Creates `RUN_DIR`: `$TARGET_REPO_ROOT/.rca-mas/runs/$RUN_ID/`
7. Copies `bug.md` into `RUN_DIR/bug.md`
8. Initialises `RUN_DIR/manifest.json` with `started_at`, `run_id`, `mode`, `tool_versions`
9. Creates `RUN_DIR/log.jsonl` (empty)
10. Sets `BRIEFING`, `ERRORS_TXT`, `LOG_FILE`, `CHECKPOINT` environment variables pointing into `RUN_DIR`

**Inputs:** `bug.md` (file path), `TARGET_REPO_ROOT` (env or CWD), `config/defaults.env`
**Outputs:** `RUN_DIR/` created, `manifest.json` initialised, env vars exported

**Failure:** `die` on missing `bug.md`. All other startup failures are fatal before any LLM cost is incurred.

---

## Stage 1 — Briefing (bash, zero LLM calls)

**Script:** `scripts/briefing.sh`

**What happens:**

### Phase 1 — Extract search strings from bug.md
- Regex captures both double-quoted and backtick-quoted strings between 5 and 200 characters
- Strips surrounding quotes, deduplicates, writes one string per line to `errors.txt`
- These become the inputs to `collectors/errors.sh`

### Phase 2 — Extract and validate file paths
- Regex extracts path-like tokens (`word.ext`, `dir/file.ext`, `file.ext:42`)
- Five rejection rules applied to each candidate:
  1. Absolute path (starts with `/`) → skip
  2. Path traversal (contains `../`) → skip
  3. Secret extension (`.env`, `.pem`, `.key`, `id_rsa`, `.secret`, `.token`, `.passwd`, `.password`) → skip
  4. Unknown extension (not in the allowed list of ~25 source extensions) → skip
  5. Not tracked by `git ls-files` (in a git repo) → skip
- Produces `MENTIONED_FILES` — space-separated list of valid, git-tracked paths
- **Optimisation:** `git ls-files` is called once and cached; not once per file

### Phase 3 — File count and tier selection
- Reuses the cached `git ls-files` output to count tracked files
- Maps count to tier (XS/S/M/L) using breakpoints from `defaults.env`
- Exports `MAX_TURNS`, `TIMEOUT`, `REPO_TIER`

### Phase 4 — Write metadata header to briefing.md
```
## Metadata
MAX_TURNS: 25
TIMEOUT: 300
FILE_COUNT: 141
REPO_TIER: S
MENTIONED_FILES: src/click/core.py
ERROR_COUNT: 5
TEST_COMMAND: UNKNOWN
```
`TEST_COMMAND` is written as `UNKNOWN` now and backfilled after testrunner.sh runs.

### Phase 5 — Run four collectors with timeout
Each collector runs as: `timeout $RCA_COLLECTOR_TIMEOUT bash $script`

| Collector | Output section | What it does |
|---|---|---|
| `git.sh` | `## Git History` | Recent merges, per-file git log, blame (first 30 lines) |
| `deps.sh` | `## Dependencies` | Top-level imports for each mentioned file |
| `errors.sh` | `## Error Sources` | Fixed-string search across repo for each error string; src/ hits first, docs/changelogs excluded |
| `testrunner.sh` | `## Test Mapping` | Detect test framework, map source files to test files |

If a collector times out (exit 124) or fails (non-zero): the failure is logged to `BRIEFING_WARNINGS`, the section is omitted or truncated, and the pipeline continues. Collectors never crash briefing.

### Phase 6 — Backfill TEST_COMMAND and append warnings
- `testrunner.sh` writes detected command to `$TEST_CMD_FILE`
- `briefing.sh` reads it back and replaces the `TEST_COMMAND: UNKNOWN` placeholder using `awk`
- Appends `## Briefing Warnings` section (lists any collector failures, or "(none)")

**Inputs:** `BUG_FILE`, `TARGET_REPO_ROOT`, `RUN_DIR`, `TOOL_ROOT`, all `RCA_*` vars
**Outputs:** `briefing.md`, `errors.txt`, `MAX_TURNS`/`TIMEOUT`/`REPO_TIER` exported

**Failure:** Collector failures are warnings. Non-existent `TARGET_REPO_ROOT` is fatal.

---

## Stage 2a — Agent 1a: Investigation (free-text, no schema, no file writes)

**Scripts:** `orchestrator.sh` (invokes `claude` directly) + helper scripts in `scripts/`

**What happens (8-step flow):**

1. Orchestrator assembles `agent1a_prompt.md` from `prompts/investigation.md` + bug report + briefing + run metadata
2. Toolful investigation: `claude --output-format stream-json --max-turns $RCA_A1A_TURNS --tools "Read,Grep,Glob,Bash"` — stderr kept separate from stream stdout
3. **Validate stream is non-empty and contains a `result` event** — partial streams (timeout mid-investigation) are flagged immediately. Then `scripts/extract_agent1a_stream.sh` produces `agent1a_output.txt`, `agent1a_evidence.txt`, `agent1a_meta.env` (session_id, stop_reason, exit_code)
4. Forced finalization: `scripts/finalize_agent1a_summary.sh` resumes via `--resume <session_id> --tools "" --max-turns 1` and requests FINAL FINDINGS — runs whenever session_id is non-empty
5. Quality gate (pass 1): `scripts/check_agent1a_quality.sh` marks `agent1a_quality=ok` or `agent1a_quality=weak`. Weak quality is logged at `warn` level (visible in terminal) so the operator knows
6. If weak: `scripts/recover_agent1a_findings.sh` synthesises findings from evidence transcript using a no-tools no-resume Claude call
7. Quality gate (pass 2): re-checks after recovery. If still weak, the stage is marked `degraded` and the operator is warned that Agent 1b will cap confidence at 0.4
8. Checkpoint write: a single Claude call (`--tools "" --max-turns 1 --output-format json`) reads `agent1a_findings.md` + `agent1a_evidence.txt` (capped at 8000 bytes from the tail) and emits the JSON checkpoint into `checkpoint.json`. If extraction fails, `extract_normalize_json` retries on the raw output. If still no valid JSON, a **degraded seed** with `_degraded_seed: true` is written and the stage is marked `degraded`. Agent 1b detects the marker and refuses to synthesise from it.

**max_turns is an emergency cap, not the stopping mechanism.** Agent 1a writes FINAL FINDINGS when confidence ≥0.70. stop_reason=tool_use is recoverable — forced finalization handles it.

**All script failures are visible.** Earlier versions used `|| true` to suppress errors silently. The current orchestrator captures every non-zero exit (`_A1A_EXTRACT_FAILED`, `_A1A_FINALIZE_FAILED`, `_A1A_RECOVER_FAILED`, `_A1A_QUALITY_FAILED`) and emits `log_event warn` for each, so failures surface in `log.jsonl` and `agent1a.log` rather than being silently swallowed.

**Turn budgets by tier (current defaults):**

| Tier | Max turns | Timeout |
|---|---|---|
| XS | 200 | 900s |
| S  | 200 | 900s |
| M  | 200 | 900s |
| L  | 200 | 900s |

Turns are an emergency cap; the cost cap (`RCA_A1A_BUDGET_USD`) is the primary throttle. Tier slots remain available for per-tier overrides if you need them.

**Allowed tools:** Read, Grep, Glob, Bash (read-only: `git log/show/blame/diff/status`, `grep`, `rg`, `find`, `cat`, `wc`, `head`, `tail`, `ls`, `sed`)

**Forbidden:** Write, Edit, running tests, executing project code, network access

**Inputs:** `agent1a_prompt.md`, repo source files (read-only)

**Outputs:**

| File | Description |
|---|---|
| `agent1a_output.txt.stream` | Raw stream-json JSONL from claude |
| `agent1a_stderr.txt` | Stderr from claude (separate from stream) |
| `agent1a_output.txt` | Extracted assistant text + finalization output |
| `agent1a_evidence.txt` | Tool calls, tool results, result metadata |
| `agent1a_findings.md` | Canonical FINAL FINDINGS — primary checkpoint writer input |
| `agent1a_meta.env` | session_id, stop_reason, result_subtype, exit_code |
| `agent1a_quality.env` | quality=ok\|weak, finalization, recovery status |
| `checkpoint.json` | Written by checkpoint-write phase from findings + evidence |

**Failure:** stop_reason=tool_use → forced finalization resumes session. Finalization failure → evidence recovery. All paths produce `agent1a_findings.md` and `checkpoint.json`. Pipeline continues in all cases.

---

## Stage 2b — Agent 1b: Conclusion (schema-enforced, reads checkpoint)

**Script:** `orchestrator.sh` — calls `claude` directly with `--output-format json --json-schema diagnosis.schema.json --tools ""`.

**What happens:**

1. **Checkpoint gates** — before invoking Claude, the orchestrator checks:
   - `checkpoint.json` exists and is a JSON object
   - is not a `_degraded_seed` (write phase failed earlier)
   - has at least one useful field non-empty: `hypothesis`, `root_cause`, `call_chain`, or `files_examined`
   Any gate failure marks the stage `failed` and writes a placeholder diagnosis without calling Claude.
2. **Log checkpoint shape** — emits `log.jsonl` event `agent1b checkpoint shape` listing whether the checkpoint has `root_cause`, `hypotheses[]`, `selected_hypothesis_id`, etc., so operators see what Agent 1b is receiving.
3. **Assemble prompt** — `agent1b_prompt.md` = `prompts/diagnosis.md` + bug report + checkpoint inline + run metadata (`RUN_ID`, `CHECKPOINT_QUALITY`, `CONFIDENCE_STOP`).
4. **Call Claude** — `timeout $RCA_A1B_TIMEOUT claude -p ... --output-format json --json-schema ... --max-turns $RCA_A1B_TURNS --tools ""`. Stdout to `agent1b_raw.json`, stderr to `agent1b_stderr.txt` (kept separate).
5. **Extract** via `extract_normalize_json` from `lib/json.sh`. Handles `.structured_output` (object or stringified JSON), `.result` (object or stringified JSON or fenced markdown), and raw top-level objects.
6. **Stamp `run_id` and cap confidence** — if `agent1a_quality` is `weak` or `failed`, confidence is capped at 0.4.
7. **Validate** against `schemas/diagnosis.schema.json` via `validate_diagnosis_json`.
8. **Repair** — if validation fails, one repair pass: `prompts/agent1b_repair.md` + checkpoint + bug + the invalid output + validation error. Re-validate.
9. **Atomic write** — `diagnosis.json` is written only after schema validation passes. On total failure, a placeholder diagnosis with `confidence: 0.0` and `root_cause: "Agent 1b failed to produce valid diagnosis. <reason>"` is written.

**Data flow contract (1a → 1b):** Agent 1a's checkpoint-write phase emits fields that map 1:1 onto the diagnosis schema (`root_cause`, `hypotheses[]`, `selected_hypothesis_id`, etc.) so Agent 1b can copy them through verbatim. See [agent-contracts.md](agent-contracts.md#checkpoint-contract-data-flow-from-agent-1a) for the field-by-field mapping table.

**Turn budget:** Always small (default 20 turns, 120s). The investigation is already done.

**Allowed tools:** None — Agent 1b runs with `--tools ""`. Pure synthesis from the checkpoint.

**Forbidden:** All tools (Read, Grep, Glob, Bash, Write, Edit), network access

**Inputs:** `agent1b_prompt.md`, `checkpoint.json`, `prompts/diagnosis.md`, `schemas/diagnosis.schema.json`, `agent1a_quality.env`

**Outputs:**

| File | When |
|---|---|
| `agent1b_raw.json` | Always (raw Claude response) |
| `agent1b_stderr.txt` | Always |
| `agent1b_meta.env` | Always (exit_code, normalized, schema_valid, repair_attempted, repair_success, failure_reason) |
| `agent1b_quality.env` | Always (`agent1b_quality=ok` or `agent1b_quality=failed`) |
| `agent1b_repair_*.json` | Only when repair was triggered |
| `diagnosis.invalid.json` / `.txt` | Only on validation failure (debug aid) |
| `diagnosis.raw.json` | Copy of `agent1b_raw.json` on success, or placeholder on failure |
| `diagnosis.json` | Schema-validated diagnosis or 0.0-confidence placeholder |

**diagnosis.json shape:**

```json
{
  "run_id": "1778052942-fed9049",
  "root_cause": "...",
  "selected_hypothesis_id": "h1",
  "hypotheses": [...],
  "rejected_hypotheses": [...],
  "affected_files": ["src/foo.py"],
  "call_chain": ["..."],
  "files_examined": ["src/foo.py"],
  "unknowns": [],
  "confidence": 0.82,
  "introducing_commit": null,
  "next_best_action": "..."
}
```

**Failure handling:** Fail-closed. If extraction, validation, and the one repair attempt all fail, the placeholder diagnosis (confidence 0.0) is written instead of fabricating from the checkpoint. Agent 2 sees the low confidence and emits `NO_FIX`.

---

## Stage 3 — Agent 2: Solution (schema-enforced, reads briefing + diagnosis only)

**Script:** `orchestrator.sh` — calls `claude` directly with `--output-format json --json-schema solution.schema.json`, no tools enabled. Pattern mirrors Agent 1b.

**What happens (11-step flow):**

1. **Gate on diagnosis.json** — must exist, must be a JSON object. If Agent 1b's `agent1b_quality=failed`, write a clean NO_FIX without invoking Claude (saves cost when upstream already failed).
2. **Compute WEAK_EVIDENCE flag** — orchestrator sets `WEAK_EVIDENCE=true` when `diagnosis.confidence < RCA_CONFIDENCE_WEAK_THRESHOLD` (default 0.6) OR when `agent1a_quality` is `weak`/`failed`. Logs the assessment.
3. **Assemble prompt** — `agent2_prompt.md` = `prompts/solution.md` + briefing.md (inline) + diagnosis.json (inline) + Run Metadata (`RUN_ID`, `DIAGNOSIS_CONFIDENCE`, `AGENT1A_QUALITY`, `WEAK_EVIDENCE`, `WEAK_EVIDENCE_REASON`, `RCA_CONFIDENCE_NOFX`, `RCA_CONFIDENCE_WEAK_THRESHOLD`).
4. **Call Claude** — `timeout $RCA_AGENT2_TIMEOUT claude -p ... --output-format json --json-schema ... --max-turns $RCA_AGENT2_TURNS` (default 20). No `--tools` flag — system prompt enforces no-tool synthesis. Stdout to `agent2_raw.json`, stderr to `agent2_stderr.txt`.
5. **Extract** via `extract_normalize_json`. Handles structured_output, .result, raw object, stringified/fenced JSON. **Rejects Claude error envelopes** (e.g. `is_error=true`, `subtype=error_max_turns`) — these would otherwise be misread as a top-level object.
6. **Stamp + enforce weak_evidence** — orchestrator overwrites `weak_evidence` and (when true) `weak_evidence_reason` in the candidate based on its own computed values. Claude doesn't get to ignore the flag.
7. **Validate** against `solution.schema.json` via `validate_solution_json`. Schema rules + semantic rules: FIX requires confidence ≥ 0.5, non-empty `fixes[]`, valid unified_diff with `diff --git`, `---`, `+++`, and `@@` markers, no markdown fences; NO_FIX requires non-empty `no_fix_reason` and empty `fixes[]`.
8. **Repair** — if invalid, one repair pass: `prompts/agent2_repair.md` + briefing + diagnosis + invalid output + validation error + run metadata. Re-validate.
9. **Atomic write** — `solution.json` is written only after validation passes. On total failure, write a placeholder NO_FIX with `confidence: 0.0` and a `no_fix_reason` explaining the failure.
10. **Extract patch** — if `recommendation: FIX`, extract the recommended fix's `unified_diff` to `patches/fix.diff`. If NO_FIX, remove any stale `patches/fix.diff` from prior runs.
11. **Sidecars** — always write `agent2_meta.env` and `agent2_quality.env`.

**Data flow contract (1b → 2):** Agent 1b emits a schema-validated diagnosis. Agent 2 reads `diagnosis.root_cause`, `diagnosis.confidence`, `diagnosis.affected_files`, `diagnosis.hypotheses[].supporting_evidence`, `diagnosis.next_best_action` to construct a unified diff. `affected_files` in each fix must be a subset of `diagnosis.affected_files`.

**Turn budget:** 20 turns / 600s default. Generous because complex multi-part fixes (Bug 3 class) need room for schema enforcement and internal thinking; the cost cap is the real throttle.

**Allowed tools:** None. The system prompt forbids tool use; the orchestrator does not pass `--allowedTools`.

**Forbidden:** Repo inspection, patch application, test execution, network access, credential file reads.

**Inputs:** `agent2_prompt.md`, `briefing.md`, `diagnosis.json`, `agent1a_quality.env`, `agent1b_quality.env`

**Outputs:**

| File | When |
|---|---|
| `agent2_raw.json` | Always |
| `agent2_stderr.txt` | Always |
| `agent2_meta.env` | Always |
| `agent2_quality.env` | Always (`agent2_quality=ok` or `agent2_quality=failed`) |
| `agent2_repair_*` | Only when first call failed validation |
| `solution.invalid.json` / `.txt` | Only on validation failure |
| `solution.raw.json` | Copy of `agent2_raw.json` or placeholder |
| `solution.json` | Schema-validated or fail-closed placeholder |
| `patches/fix.diff` | Only when `recommendation: FIX` |

**solution.json shape (FIX):**

```json
{
  "run_id": "1778750267-c88f333",
  "recommendation": "FIX",
  "confidence": 0.90,
  "no_fix_reason": null,
  "recommended_fix_id": "fix1",
  "weak_evidence": false,
  "weak_evidence_reason": null,
  "fixes": [
    {
      "id": "fix1",
      "description": "...",
      "why_this_fixes_root_cause": "...",
      "unified_diff": "diff --git a/path.py b/path.py\n--- a/path.py\n+++ b/path.py\n@@ -L,N +L,N @@\n-old\n+new\n",
      "affected_files": ["path.py"],
      "risk": "low|medium|high",
      "expected_tests": ["tests/..."],
      "manual_review_notes": ["..."]
    }
  ]
}
```

**Failure handling:** Fail-closed. If extraction, validation, and the one repair attempt all fail, the placeholder NO_FIX (confidence 0.0) is written instead of fabricating a patch. Agent 2.5 (if invoked) sees NO_FIX and skips patch application.

---

## Stage 4 — Agent 2.5: Validation (optional)

**Invoked only when:** `--validate` flag is passed AND `solution.json` status is not `NO_FIX`

**What happens:**
1. Orchestrator creates a git worktree at `../.rca-mas-worktrees/$RUN_ID/`
2. Agent applies the patch from `solution.json` to the worktree
3. Agent runs the test command from `TEST_COMMAND` in the worktree
4. Captures test output, determines pass/fail
5. Writes `validation.json`
6. Orchestrator removes the worktree (unless `RCA_KEEP_WORKTREE=1`)

**Allowed tools:** Read, Write (worktree only), Bash (test execution in worktree only)
**Forbidden:** Write to the main working tree, git commit, git push, network access

**Inputs:** `solution.json`, `patches/*.diff`, `prompts/agent2_5.md`, `schemas/validation.schema.json`
**Outputs:** `RUN_DIR/validation.json`

**validation.json shape:**
```json
{
  "status": "PASS",
  "test_command": "pytest tests/test_options.py",
  "test_output_summary": "5 passed in 1.2s",
  "patch_applied": true,
  "worktree_path": "../.rca-mas-worktrees/20260504-101523"
}
```

**Failure:** Patch fails to apply → `status: ERROR`. Tests fail → `status: FAIL`. Both cases: patch and test output still saved.

---

## Stage 5 — Report Assembly

**Script:** `scripts/report.sh` (called by orchestrator)

**What happens:**
1. Reads `diagnosis.json`, `solution.json`, `validation.json` (if present)
2. Assembles `report.md` with mandatory sections
3. Writes `cost_summary.json` with model, tier, turns used, total wall-clock time
4. Finalises `manifest.json` with `ended_at` timestamp
5. Updates `latest` symlink/directory to point to `RUN_DIR`
6. Prints path to `report.md` on stdout

**Inputs:** All JSON outputs from stages 2–4
**Outputs:** `RUN_DIR/report.md`, `RUN_DIR/cost_summary.json`, `manifest.json` finalised, `latest` updated

**Failure:** Missing JSON fields produce `UNKNOWN` or `SKIPPED` in the relevant report section. Report is always written even if upstream stages were partial.

---

## End-to-End Timing

| Stage | Typical time |
|---|---|
| Startup | < 1s |
| Briefing (Linux/Mac) | 3–5s |
| Briefing (Windows/MSYS2) | 15–30s |
| Agent 1a investigation (S-tier repo) | 3–8 min |
| Agent 1b conclusion | 20–60s |
| Agent 2 | 30–90s |
| Agent 2.5 (optional) | 1–3 min |
| Report assembly | < 1s |
| **Total (no validation)** | **4–10 min** |
| **Total (with validation)** | **6–14 min** |
