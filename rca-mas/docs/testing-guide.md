# Testing Guide

How to run the test suite, what each test file covers, how to write new tests, and how to run the real GitHub bug tests.

---

## Test Tiers

| Situation | Command | Time | What runs |
| --- | --- | --- | --- |
| Writing code, fast feedback | `make test-fast` | ~2 min | lint + schemas + smoke |
| Changed briefing.sh or a collector | `make test-briefing` | ~4 min | briefing + collectors |
| Quick real-repo signal | `make test-real-repo-quick` | ~40s | bugs 1 and 4 only |
| Step gate (before each new step) | `make lint && make test` | ~6 min | all 4 synthetic suites |
| Pre-lock gate (before locking a step) | `make test-full` | ~9 min | all synthetic + all 5 real-repo bugs |

**Step gate** (must pass before proceeding to the next build step):
```bash
make lint && make test
```

**Pre-lock gate** (run before declaring a step complete):
```bash
make test-full
```

---

## Quick Start

```bash
cd rca-mas/
make lint              # syntax check all scripts
make test              # run all 4 unit test suites (no Claude, no network, ~30s)
make test-real-repo    # real-repo quality test (requires click clone, ~3 min)
```

All three should exit 0. If any fails, fix before proceeding.

---

## Test Suites

### 1. `tests/test_briefing.sh` — Briefing Logic

Tests `scripts/briefing.sh` and all 4 collectors against a tiny controlled git repo created in a temp directory. No Claude calls. No network.

**What it covers:**
- `briefing.md` and `errors.txt` are created and non-empty
- All 7 metadata fields present (`MAX_TURNS`, `TIMEOUT`, `FILE_COUNT`, `REPO_TIER`, `MENTIONED_FILES`, `ERROR_COUNT`, `TEST_COMMAND`)
- `REPO_TIER` is one of `XS|S|M|L`
- `FILE_COUNT` is numeric
- `TEST_COMMAND` correctly detects `pytest` from `pytest.ini`
- All 5 collector sections present in briefing.md
- Double-quoted error strings preserved as multi-word phrases in `errors.txt`
- Backtick-quoted strings extracted correctly
- Git-tracked file accepted in `MENTIONED_FILES`
- Untracked file rejected from `MENTIONED_FILES`
- Absolute path (`/etc/passwd`) rejected
- Path traversal (`../../../etc/shadow`) rejected
- Secret extension (`.env`) rejected
- Error Sources section finds matches in source code (not in bug.md)
- `bug.md` excluded from Error Sources (circular evidence check)
- Test file mapping: `src/cart/pricing.py -> tests/test_pricing.py`
- Empty bug report does not crash
- Non-git directory uses filesystem fallback

Run directly:
```bash
bash tests/test_briefing.sh
```

---

### 2. `tests/test_collectors.sh` — Individual Collector Behavior

Tests each collector in isolation with controlled inputs.

**What it covers:**
- `git.sh`: git log output present, blame section present
- `deps.sh`: Python imports extracted, unsupported language handled gracefully
- `errors.sh`: fixed-string search finds matches, circular evidence exclusion
- `testrunner.sh`: pytest detected from `pytest.ini`, `go test ./...` detected from `go.mod`, test file mapping accuracy

Run directly:
```bash
bash tests/test_collectors.sh
```

---

### 3. `tests/test_json_schemas.sh` — Schema Validation

Validates all three JSON schemas and tests that example JSON validates against them correctly.

**What it covers:**
- `schemas/diagnosis.schema.json` is valid JSON Schema
- `schemas/solution.schema.json` is valid JSON Schema
- `schemas/validation.schema.json` is valid JSON Schema
- Example `COMPLETE` diagnosis validates against schema
- Example `PARTIAL` diagnosis validates against schema
- Example `NO_FIX` solution validates against schema
- Example `PASS` validation validates against schema
- Example `SKIPPED` validation validates against schema

Run directly:
```bash
bash tests/test_json_schemas.sh
```

---

### 4. `tests/test_smoke_report_only.sh` — End-to-End Pipeline (No Claude)

Runs the full pipeline using pre-written fixture JSON files instead of live Claude calls. Tests pipeline wiring, output structure, and source file immutability.

**What it covers:**
- Pipeline exits 0
- All required output files created (11 files)
- `manifest.json` has required fields and `ended_at` is set
- All 5 JSON files are valid JSON (`jq -e . file.json`)
- `report.md` contains all 11 mandatory sections
- Source files not modified during pipeline run (immutability check)
- `latest` symlink created and points to run directory

Run directly:
```bash
bash tests/test_smoke_report_only.sh
```

---

### 5. `tests/test_real_repo_briefing.sh` — Real GitHub Bug Quality Test

Tests briefing quality against 5 real bugs from [pallets/click](https://github.com/pallets/click). Requires a local clone of the click repo.

**What it covers:**
- Briefing runs successfully against each of 5 real bugs (at pre-fix commit states)
- Hard checks (all must pass): briefing.md exists, errors.txt exists, required metadata fields present, `TEST_COMMAND=pytest` detected, `bug.md` excluded from Error Sources
- Quality signals (scored): expected fix files found in briefing, Error Sources section non-empty, Git History non-empty, Test Mapping section present
- Repo restored to original HEAD after all 5 bugs

**Setup required:**

```bash
# Clone click once (outside the rca-mas repo)
git clone https://github.com/pallets/click C:/MAS_final/test-repos/click

# Run the test
make test-real-briefing
# Or directly:
bash tests/test_real_repo_briefing.sh
```

**Expected results:**
- Bug 1: PASS
- Bug 2: PASS
- Bug 3: PASS
- Bug 4: PASS (was expected PARTIAL)
- Bug 5: PASS (was expected PARTIAL)

**Scoring:**

Each bug gets hard checks and quality signal checks:

| Check type | Description |
|---|---|
| `[HARD-OK]` / `[HARD-FAIL]` | Must pass — failure means the briefing is broken |
| `[+SIGNAL]` | Quality signal — briefing contains expected content |
| `[-SIGNAL]` | Quality signal — expected content missing (not a hard failure) |

---

## Writing New Tests

All test scripts follow this pattern:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

PASS=0; FAIL=0

pass() { printf '  [PASS] %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf '  [FAIL] %s\n' "$1"; (( FAIL++ )) || true; }

# --- Your tests ---
[ -f "$some_file" ] && pass "file exists" || fail "file missing"
grep -q "expected string" "$some_file" && pass "string found" || fail "string missing"

# --- Results ---
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

**Rules:**
- Every assertion uses `pass` or `fail` — never `exit` directly on assertion failure
- Print the file path or value that failed, not just "unexpected output"
- Always clean up temp directories in a `trap` or at the end of the script
- Tests must be runnable standalone (`bash tests/test_mytest.sh`) and via `make test`

---

## Manual Validation Checklist

After a real run (with Claude), verify the report manually:

```
[ ] report.md exists and is non-empty
[ ] ## Status section present and not "UNKNOWN"
[ ] ## Root Cause section contains a specific explanation (not generic)
[ ] ## Confidence shows a numeric score
[ ] ## Evidence section cites specific file paths and line numbers
[ ] ## Proposed Fix section contains an actual diff (not placeholder)
[ ] ## Validation section shows PASS/FAIL/SKIPPED (not missing)
[ ] ## Next Action section has numbered steps
[ ] errors.txt contains strings from the bug report
[ ] diagnosis.json confidence >= 0.5 (otherwise expect NO_FIX)
[ ] log.jsonl contains no ERROR-level events
[ ] No source files modified in target repo (git status clean)
```

---

## Fixtures

Fixture files live in `tests/fixtures/`:

| File | Purpose |
|---|---|
| `fixtures/sample_bug.md` | Minimal bug report for smoke tests |
| `fixtures/smoke_bug.md` | Bug report used by `test_smoke_report_only.sh` |

Real-repo fixtures live in `tests/real_repos/click/`:

| Path | Purpose |
|---|---|
| `bugs/bug{1-5}.md` | Real GitHub issue content (title + body only) |
| `expected/bug{N}_fix_sha.txt` | Full SHA of the commit that fixed the bug |
| `expected/bug{N}_pre_fix_ref.txt` | Full SHA to check out before running briefing |
| `expected/bug{N}_fix_files.txt` | Files changed by the fix (quality signal reference) |
| `expected/bug{N}_metadata.json` | Full fixture metadata (not passed to MAS) |
| `scoring_contract.md` | Scoring rules and expected results for all 5 bugs |

---

## Test Gate Rules

Every step in the build plan requires passing both gates:

```bash
make lint   # must exit 0
make test   # must exit 0
```

Never proceed to the next build step with a failing test. The test suite is the source of truth for correctness — not the code, not the docs.
