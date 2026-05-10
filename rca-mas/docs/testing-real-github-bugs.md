# Testing on Real GitHub Bugs

This document describes how to run the MAS against real GitHub bugs with known fix commits, and how to interpret the results.

---

## Why real-repo testing exists

Synthetic tests (`make test`) prove mechanics: files are created, JSON is valid, collectors don't crash. They do not prove that the tool produces useful output on a real codebase.

Real-repo testing proves quality: does briefing orient Agent 1 correctly? Does Agent 1 find the right file? Does Agent 2 produce a useful patch?

The real-repo fixture is reused at every step:

| Step | What is tested |
|---|---|
| 4.5 | Briefing quality — does `briefing.md` surface the right signals? |
| 6 | Agent 1 diagnosis quality — does `diagnosis.affected_files` match the fix? |
| 7 | Agent 2 fix quality — does `patches/fix.diff` target the right file? |
| 8 | Report usefulness — is `report.md` readable and actionable? |
| 11 | Validation — does the patch apply and do tests pass? |
| 12 | Final end-to-end scoring across all 5 bugs |

---

## Test fixture

**Repo:** `pallets/click`
**Clone location:** `C:/MAS_final/test-repos/click` (full clone, not committed to MAS repo)
**Fixture metadata:** `rca-mas/tests/real_repos/click/` (committed)
**Clone command:**
```bash
git clone https://github.com/pallets/click C:/MAS_final/test-repos/click
```

Override clone location:
```bash
RCA_REAL_REPO_ROOT=/path/to/click bash tests/test_real_repo_briefing.sh
```

---

## The 5 bugs

| Bug | Issue | Difficulty | Source file(s) | Fix SHA |
|---|---|---|---|---|
| Bug 1 (Easy) | #2971 — Error hint shows env var when none exists | Easy | `src/click/core.py` | `0be2bd3...` |
| Bug 2 (Easy) | #3039 — Pager `Popen()` should not use `shell=True` | Easy | `src/click/_termui_impl.py` | `7d71836...` |
| Bug 3 (Medium) | #3071 — `default=True` on feature flags is order-sensitive | Medium | `src/click/core.py` | `27aaed3...` |
| Bug 4 (Medium) | #3066 — `ctx.invoke` passes `Sentinel` to command | Medium/Hard | `src/click/core.py` | `6a1c0d0...` |
| Bug 5 (Hard) | #3019 — `prompt_suffix` empty suffix regression | Hard | `src/click/termui.py` + `_termui_impl.py` | `8533c96...` |

**Repo facts:**
- 149 tracked files → S-tier (25 turns, 300s timeout)
- Full git history (3097 commits)
- pytest detected via `pyproject.toml`

---

## Running the briefing test (Step 4.5+)

```bash
make test-real-repo
```

(`make test-real-briefing` is a backward-compatible alias for the same target.)

This runs `tests/test_real_repo_briefing.sh` which:
1. Checks out each bug's pre-fix commit in the clone
2. Runs `scripts/briefing.sh` directly against the clone
3. Scores `briefing.md` and `errors.txt` against ground truth
4. Prints PASS / PARTIAL / FAIL per bug

If the clone is missing:
```
SKIP: real repo clone not found. Set RCA_REAL_REPO_ROOT or run:
  git clone https://github.com/pallets/click C:/MAS_final/test-repos/click
```

---

## Scoring model

**Hard checks** (must pass every bug):
- `briefing.md` exists
- `errors.txt` exists
- Metadata section present with all 7 fields
- `TEST_COMMAND: pytest` detected
- Bug report file excluded from Error Sources
- No collector crash
- Output bounded

**Quality checks** (scored, not hard-failed):

| Signal | Points |
|---|---|
| At least one expected fix file in `MENTIONED_FILES` | +2 |
| At least one expected fix file in Error Sources | +2 |
| Git History references expected file | +1 |
| Dependencies section has useful imports | +1 |
| Test Mapping points to relevant test file | +1 |

**Expected outcomes per bug:**

| Bug | Minimum acceptable |
|---|---|
| Easy (B1, B2) | PASS |
| Medium (B3, B4) | PASS or PARTIAL |
| Hard (B5) | PARTIAL acceptable |

---

## Running the full pipeline test (Steps 6–12)

```bash
cd C:/MAS_final/test-repos/click
git checkout <pre_fix_ref>

EXPECTED_FIX_SHA=<fix_sha> \
  bash /path/to/rca-mas/rca-mas.sh bug.md

# Check Agent 1 found the right file:
jq '.affected_files' .rca-mas/runs/latest/diagnosis.json

# Compare against actual fix:
git show <fix_sha> --name-only
```

The `EXPECTED_FIX_SHA` variable is recorded in `manifest.json` and used at Step 12 for final scoring.

---

## Known limitations of this fixture

**3 of 5 bugs have backtick-quoted strings, not double-quoted.** Briefing extracts both (as of Step 4 hardening), so `errors.txt` will be populated. But the strings are identifier names (`` `shell=True` ``, `` `prompt_suffix` ``) not error messages — Error Sources may find them in docs or comments rather than the bug location.

**Bug 5 (Hard) is expected to score PARTIAL on briefing.** No file path in issue, no error string, pure behavior regression. This is intentional — it tests what happens when Agent 1 gets minimal signal.

**Bug 1 mentions `./click-test.py`.** This is a user-created script, not tracked by `git ls-files`. It will not appear in `MENTIONED_FILES`. Briefing still finds signals via Error Sources.

---

## Helper: test a specific known bug manually

```bash
test_known_bug() {
  local repo="$1" issue="$2" fix_sha="$3"
  git clone --depth 100 "https://github.com/$repo" /tmp/rca-test-repo
  cd /tmp/rca-test-repo
  git checkout "${fix_sha}^"
  gh issue view "$issue" --repo "$repo" \
    --json title,body --jq '(.title)+"\n\n"+(.body)' > bug.md
  EXPECTED_FIX_SHA="$fix_sha" /path/to/rca-mas/rca-mas.sh bug.md
  echo "=== Actual fix ===" && git show "$fix_sha" --name-only
  echo "=== Agent diagnosis ===" && jq -r '.affected_files[]' \
    .rca-mas/runs/latest/diagnosis.json
}

# Example:
test_known_bug pallets/click 2971 0be2bd385064053bb75f92db317de128db729d52
```
