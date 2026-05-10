# Schemas

JSON schemas for the three structured outputs that pass between agents. All live in `schemas/`.

---

## diagnosis.json

**Written by:** Agent 1
**Read by:** Agent 2, orchestrator (for report assembly)
**Schema file:** `schemas/diagnosis.schema.json`

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `status` | string | Yes | `COMPLETE`, `PARTIAL`, or `NO_REPRO` |
| `confidence` | number | Yes | 0.0–1.0. Agent 1 stops when this exceeds `RCA_CONFIDENCE_STOP` (0.7) |
| `root_cause` | string | Yes | Plain English description of why the bug occurs |
| `evidence` | array | Yes | List of evidence objects (see below) |
| `hypotheses` | array | Yes | List of strings — accepted and rejected hypotheses |
| `affected_files` | array | Yes | List of file paths that need to change |
| `turns_used` | number | No | How many turns Agent 1 used (informational) |

### Evidence Object

| Field | Type | Required | Description |
|---|---|---|---|
| `file` | string | Yes | Relative path from repo root |
| `lines` | string | Yes | Line range, e.g. `"412-418"` or `"42"` |
| `note` | string | Yes | What this code does that causes the bug |

### Example

```json
{
  "status": "COMPLETE",
  "confidence": 0.82,
  "root_cause": "get_error_hint() in the Option class includes envvar in the error message without checking whether envvar is None. The guard 'if self.show_envvar and self.envvar is not None' is missing.",
  "evidence": [
    {
      "file": "src/click/core.py",
      "lines": "412-418",
      "note": "get_error_hint() constructs the error string unconditionally when show_envvar=True"
    }
  ],
  "hypotheses": [
    "ACCEPTED: Missing None check in get_error_hint() — confirmed by code at core.py:414",
    "REJECTED: Bug in error formatting — formatting is correct, the problem is upstream"
  ],
  "affected_files": ["src/click/core.py"],
  "turns_used": 18
}
```

### Status Values

| Value | Meaning |
|---|---|
| `COMPLETE` | Root cause identified |
| `PARTIAL` | Timed out; confidence is set to `RCA_CONFIDENCE_CHECKPOINT` (0.4) |
| `NO_REPRO` | Cannot locate the bug in the current codebase state |

---

## solution.json

**Written by:** Agent 2
**Read by:** Agent 2.5, orchestrator
**Schema file:** `schemas/solution.schema.json`

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `status` | string | Yes | `COMPLETE`, `PARTIAL`, or `NO_FIX` |
| `confidence` | number | Yes | 0.0–1.0. If below `RCA_CONFIDENCE_NOFX` (0.5), Agent 2 must write `NO_FIX` |
| `fix_description` | string | Yes (if not `NO_FIX`) | Plain English description of what the fix does |
| `affected_files` | array | Yes (if not `NO_FIX`) | Files modified by the patch |
| `patches` | array | Yes (if not `NO_FIX`) | Relative paths to `.diff` files under `RUN_DIR/patches/` |
| `test_suggestion` | string | No | Specific test command to verify the fix |
| `reason` | string | Yes (if `NO_FIX`) | Why a fix cannot be responsibly produced |

### Example — COMPLETE

```json
{
  "status": "COMPLETE",
  "confidence": 0.78,
  "fix_description": "Add a None check before including envvar in the error message. Change 'if self.show_envvar' to 'if self.show_envvar and self.envvar is not None'.",
  "affected_files": ["src/click/core.py"],
  "patches": ["patches/fix_core.diff"],
  "test_suggestion": "pytest tests/test_options.py -k test_show_envvar"
}
```

### Example — NO_FIX

```json
{
  "status": "NO_FIX",
  "confidence": 0.38,
  "reason": "Diagnosis confidence is below threshold. Root cause is suspected to be in the parser but evidence is insufficient to locate the specific lines."
}
```

### Patch Files

Patches are unified diffs written to `RUN_DIR/patches/`. They can be applied with:

```bash
git apply .rca-mas/runs/latest/patches/fix_core.diff
```

Or inspected directly:

```bash
cat .rca-mas/runs/latest/patches/fix_core.diff
```

### Status Values

| Value | Meaning |
|---|---|
| `COMPLETE` | Patch produced with acceptable confidence |
| `NO_FIX` | Confidence too low; no patch produced |
| `PARTIAL` | Patch produced but Agent 2 flagged uncertainty |

---

## validation.json

**Written by:** Agent 2.5
**Read by:** orchestrator (for report assembly)
**Schema file:** `schemas/validation.schema.json`

### Fields

| Field | Type | Required | Description |
|---|---|---|---|
| `status` | string | Yes | `PASS`, `FAIL`, `ERROR`, or `SKIPPED` |
| `test_command` | string | Yes (if not `SKIPPED`) | Exact command that was run |
| `test_output_summary` | string | Yes (if not `SKIPPED`) | Last few lines or summary of test output |
| `patch_applied` | boolean | Yes (if not `SKIPPED`) | Whether the patch applied cleanly |
| `worktree_path` | string | No | Path to the worktree (for debugging) |

### Example — PASS

```json
{
  "status": "PASS",
  "test_command": "pytest tests/test_options.py -k test_show_envvar",
  "test_output_summary": "3 passed in 0.8s",
  "patch_applied": true,
  "worktree_path": "../.rca-mas-worktrees/20260504-101523"
}
```

### Example — FAIL

```json
{
  "status": "FAIL",
  "test_command": "pytest tests/test_options.py",
  "test_output_summary": "2 passed, 1 failed\nFAILED tests/test_options.py::test_show_envvar_none - AssertionError",
  "patch_applied": true,
  "worktree_path": "../.rca-mas-worktrees/20260504-101523"
}
```

### Example — SKIPPED

```json
{
  "status": "SKIPPED"
}
```

### Status Values

| Value | Meaning |
|---|---|
| `PASS` | Patch applied cleanly; all tests passed |
| `FAIL` | Patch applied but one or more tests failed |
| `ERROR` | Patch did not apply (conflict, wrong base, missing file) |
| `SKIPPED` | `--validate` not passed, or upstream was `NO_FIX` |

---

## Raw vs Parsed Output

Claude Code produces a raw JSON string inside its response. The orchestrator:

1. Captures the raw Claude output to `RUN_DIR/raw_agent1_output.txt` (or `raw_agent2_output.txt`, `raw_agent25_output.txt`)
2. Extracts the JSON block using `jq` or a regex
3. Validates against the schema
4. Writes the validated JSON to `diagnosis.json` / `solution.json` / `validation.json`

If extraction fails, the orchestrator writes a stub JSON with `status: PARTIAL` and logs the parse error to `log.jsonl`. The raw output file is always preserved for debugging.
