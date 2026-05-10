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

**What happens (10-step flow):**

1. Orchestrator assembles `agent1a_prompt.md` from `prompts/investigation.md` + bug report + briefing + run metadata
2. Toolful investigation: `claude --output-format stream-json --max-turns $RCA_A1A_TURNS --tools "Read,Grep,Glob,Bash"` — stderr kept separate from stream stdout
3. Stream extracted: `scripts/extract_agent1a_stream.sh` produces `agent1a_output.txt`, `agent1a_evidence.txt`, `agent1a_meta.env` (session_id, stop_reason, exit_code)
4. Forced finalization: `scripts/finalize_agent1a_summary.sh` resumes via `--resume <session_id> --tools "" --max-turns 1` and requests FINAL FINDINGS — runs for every Agent 1a session
5. Quality gate (pass 1): `scripts/check_agent1a_quality.sh` marks `agent1a_quality=ok|weak`
6. If weak: `scripts/recover_agent1a_findings.sh` synthesises findings from evidence transcript using a no-tools no-resume Claude call
7. Quality gate (pass 2): re-checks after recovery
8. Checkpoint write: checkpoint-write phase receives `agent1a_findings.md` + `agent1a_evidence.txt` and writes `checkpoint.json`

**max_turns is an emergency cap, not the stopping mechanism.** Agent 1a writes FINAL FINDINGS when confidence ≥0.70. stop_reason=tool_use is recoverable — forced finalization handles it.

**Turn budgets by tier:**

| Tier | Max turns | Timeout |
|---|---|---|
| XS | 15 | 900s |
| S  | 25 | 900s |
| M  | 30 | 900s |
| L  | 40 | 900s |

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

**Script:** `orchestrator.sh` → `run_claude_schema()` in `scripts/claude_json.sh`

**What happens:**
1. Orchestrator assembles `agent1b_prompt.md` from `prompts/diagnosis.md` + bug report + run metadata (with checkpoint path)
2. Agent 1b does NOT receive the full briefing — it reads the checkpoint and bug report only
3. Agent 1b runs under `timeout $RCA_A1B_TIMEOUT` (default 120s) with `--max-turns $RCA_A1B_TURNS` (default 5)
4. `--json-schema diagnosis.schema.json` is enforced — output must be valid JSON
5. Agent 1b reads the checkpoint, reads the bug report, and synthesises the final `diagnosis.json`
6. If the checkpoint is the seed (confidence 0.0): Agent 1b emits a minimal honest diagnosis stating the investigation failed

**Turn budget:** Always small (default 5 turns, 120s). The investigation is already done.

**Allowed tools:** Read (checkpoint + optionally a few source lines), Grep (disambiguation only), Glob (file location only)
**Forbidden:** Write, Bash, Edit, running tests, network access

**Inputs:** `agent1b_prompt.md`, `checkpoint.json`, `prompts/diagnosis.md`, `schemas/diagnosis.schema.json`
**Outputs:** `RUN_DIR/diagnosis.raw.json` (full Claude wrapper), `RUN_DIR/diagnosis.json` (extracted, validated)

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

**Failure:** If Agent 1b times out, the orchestrator synthesises `diagnosis.json` from `checkpoint.json` using bash, preserving checkpoint confidence or falling back to `RCA_CONFIDENCE_CHECKPOINT` (0.4).

---

## Stage 3 — Agent 2: Solution

**Invocation:** `claude --max-turns $RCA_AGENT2_TURNS --timeout $RCA_AGENT2_TIMEOUT -p "$(cat $TOOL_ROOT/prompts/agent2.md)"`

**What happens:**
1. Agent receives `briefing.md` + `diagnosis.json` — does NOT see raw repo
2. Single pass (1 turn by default)
3. If `diagnosis.json` confidence < `RCA_CONFIDENCE_NOFX` (0.5): writes `status: NO_FIX`
4. Otherwise: produces `solution.json` with unified diff patches

**Allowed tools:** Read (diagnosis.json, briefing.md only)
**Forbidden:** Grep, Glob, Write to repo files, network access

**Inputs:** `briefing.md`, `diagnosis.json`, `prompts/agent2.md`, `schemas/solution.schema.json`
**Outputs:** `RUN_DIR/solution.json`, `RUN_DIR/patches/*.diff`

**solution.json shape:**
```json
{
  "status": "COMPLETE",
  "confidence": 0.78,
  "fix_description": "...",
  "affected_files": ["src/click/core.py"],
  "patches": ["patches/fix_core.diff"],
  "test_suggestion": "pytest tests/test_options.py -k test_envvar"
}
```

**Failure:** Low confidence → `status: NO_FIX`. Report shows this. Pipeline does not run Agent 2.5.

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
