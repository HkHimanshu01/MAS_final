# Scoring Contract — Click Real-Repo Benchmark

This file defines exactly how each bug is scored at each step.
It is the single source of truth for pass/fail criteria.
Do not change scoring rules without updating this file.

---

## Scoring philosophy

Briefing is a starting map, not a diagnosis. Do not score it like Agent 1.
Agent 1 is a hypothesis former, not a code reviewer. Score it on file targeting.
Agent 2 is a patch generator. Score it on diff correctness.
Report is a developer artifact. Score it on readability and accuracy.

---

## PASS / PARTIAL / FAIL definitions

| Result | Meaning |
|---|---|
| PASS | All hard checks pass AND at least one quality signal hit |
| PARTIAL | All hard checks pass BUT quality signals weak or missing |
| FAIL | Any hard check fails |

---

## Hard checks — apply at ALL steps, every bug

These must pass for every bug at every step. Failure = FAIL result.

| Check | What it verifies |
|---|---|
| briefing.md exists | Core output created |
| errors.txt exists | Core output created |
| Metadata section present with all 7 fields | Agent 1 gets tier/turns/timeout |
| TEST_COMMAND detected as pytest | testrunner.sh works on real repo |
| Bug report file excluded from Error Sources | No circular evidence |
| No collector crash | Pipeline robustness |
| Output bounded | No context explosion |
| Pipeline exits 0 | End-to-end stability |

---

## Step 4.5 — Briefing quality scoring

### Quality signals (scored per bug)

| Signal | Points | How to check |
|---|---|---|
| ≥1 expected fix file in MENTIONED_FILES | +2 | grep fix_files.txt against MENTIONED_FILES line |
| ≥1 expected fix file in Error Sources section | +2 | grep fix_files.txt against ## Error Sources content |
| Git History references expected fix file | +1 | grep fix_files.txt against ## Git History content |
| Dependencies section has useful imports | +1 | ## Dependencies section non-empty and non-trivial |
| Test Mapping points to relevant test file | +1 | src→test mapping present in ## Test Mapping |

### Expected minimum per bug

| Bug | Min score | Expected result |
|---|---|---|
| Bug 1 (Easy) | 3/7 | PASS |
| Bug 2 (Easy) | 3/7 | PASS |
| Bug 3 (Medium) | 2/7 | PASS or PARTIAL |
| Bug 4 (Medium/Hard) | 1/7 | PARTIAL |
| Bug 5 (Hard) | 1/7 | PARTIAL |

### Notes on signal expectations per bug

**Bug 1:** click-test.py not tracked → MENTIONED_FILES empty. But errors.txt has quoted strings → Error Sources will fire on core.py. Expected PASS via Error Sources path.

**Bug 2:** No double-quoted strings. With backtick extraction, `shell=True` enters errors.txt → Error Sources finds _termui_impl.py. Expected PASS.

**Bug 3:** Quoted strings are option names (`green`, `red`) → may not match source. But `flag_value`, `UNSET` from backtick strings will match core.py. Expected PASS or PARTIAL.

**Bug 4:** No double-quoted strings, no file path. Backtick strings include `Sentinel`, `ctx.invoke` → Error Sources finds core.py. Expected PARTIAL.

**Bug 5:** No quoted strings, no file path, pure regression. `prompt_suffix` from backtick → Error Sources finds termui.py. Expected PARTIAL.

---

## Step 6 — Agent 1 diagnosis quality scoring

| Signal | Points |
|---|---|
| diagnosis.affected_files contains ≥1 expected fix file | +3 |
| diagnosis.confidence ≥ 0.5 | +2 |
| diagnosis.root_cause is non-trivial (not UNKNOWN) | +2 |
| diagnosis.hypotheses has ≥2 entries | +1 |
| diagnosis.call_chain is non-empty | +1 |
| diagnosis.introducing_commit is non-null | +1 |

### Expected minimum per bug

| Bug | Min score | Expected result |
|---|---|---|
| Bug 1 (Easy) | 6/10 | PASS |
| Bug 2 (Easy) | 6/10 | PASS |
| Bug 3 (Medium) | 4/10 | PASS or PARTIAL |
| Bug 4 (Medium/Hard) | 3/10 | PARTIAL |
| Bug 5 (Hard) | 2/10 | PARTIAL |

---

## Step 7 — Agent 2 fix quality scoring

| Signal | Points |
|---|---|
| solution.recommendation == FIX | +2 |
| patches/fix.diff targets ≥1 expected fix file | +3 |
| solution.risk is low or medium (not high) | +1 |
| diff applies cleanly with git apply --check | +2 |
| solution.fixes[0].why_this_fixes_root_cause is non-trivial | +1 |
| solution.expected_tests references the correct test file | +1 |

### Expected minimum per bug

| Bug | Min score | Expected result |
|---|---|---|
| Bug 1 (Easy) | 7/10 | PASS |
| Bug 2 (Easy) | 7/10 | PASS |
| Bug 3 (Medium) | 5/10 | PASS or PARTIAL |
| Bug 4 (Medium/Hard) | 4/10 | PARTIAL |
| Bug 5 (Hard) | 3/10 | PARTIAL |

---

## Step 8 — Report usefulness scoring

Scored by manual review. Use these criteria:

| Criterion | PASS | FAIL |
|---|---|---|
| Root cause section is accurate | Matches actual fix | Generic or wrong |
| Confidence level is honest | Reflects actual uncertainty | Overclaims certainty |
| Evidence section cites real file:line | Real code references | Made up or vague |
| Proposed fix description is actionable | Developer can act on it | Too vague to act on |
| All 11 sections present | Yes | Any missing |

---

## Step 11 — Validation scoring

| Signal | Points |
|---|---|
| validation.status is TESTS_PASSED or PATCH_APPLIED | +3 |
| patches/fix.diff applied cleanly | +2 |
| patches/generated_test.diff exists | +2 |
| validation.test_command matches pytest | +1 |
| No regression detected | +2 |

---

## Step 12 — Final end-to-end scoring

Run all 5 bugs through the full pipeline. For each bug compute:

```
total_score = briefing_score + agent1_score + agent2_score + report_score + validation_score
```

Minimum acceptable totals for v1 sign-off:

| Bug | Min total (out of ~47) | Required result |
|---|---|---|
| Bug 1 | 25 | PASS |
| Bug 2 | 22 | PASS |
| Bug 3 | 18 | PASS or PARTIAL |
| Bug 4 | 14 | PARTIAL |
| Bug 5 | 10 | PARTIAL |

If Bug 1 and Bug 2 both PASS at Step 12, the tool is considered production-ready for v1.
Bugs 3–5 are stretch goals that inform prompt tuning for v1.1.
