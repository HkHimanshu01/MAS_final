# Step 4.5 Strategy — Real GitHub Repo Test Fixture
**Status:** Proposed — pending decision
**Author:** Claude Sonnet 4.6
**Date:** 2026-05-03

---

## 1. The Problem This Solves

Current test data (Step 4 tests) is entirely synthetic — 3-file fake repos built inside test scripts. These prove that briefing mechanics work correctly: file validation, error extraction, tier selection, collector execution. They do NOT prove that briefing produces useful output on a real codebase with real bugs.

The risk of skipping this: we build Agent 1, Agent 2, and the full report on top of a briefing that works mechanically but gives Agent 1 nothing useful to work with on real data. We discover this at Step 12 and have to go back to fix Step 4 after 6 more steps are built on top of it. That is expensive.

**Step 4.5 is a cheap insurance policy against that risk.**

---

## 2. The Core Idea

Pick one real GitHub repo with real closed bugs. For each bug:
- The GitHub issue becomes `bug.md` (input to the tool)
- The fix commit SHA is the ground truth (we know exactly which files were changed)
- We run briefing and check: did it surface the right signals?

Agent 1 is not needed for this. We only read `briefing.md` and `errors.txt` and ask: would this give a good investigator a head start?

This same fixture — the repo, the bugs, the expected fix files — gets reused at every subsequent step (6, 7, 8, 12) without recreating anything.

---

## 3. Proposed Repo: `pallets/flask`

### Why Flask

| Criterion | Flask | Notes |
|---|---|---|
| File count | ~200 Python files | S-tier → 25 turns, 300s timeout |
| Language | Python | Best briefing support (deps.sh, pytest) |
| GitHub issues | Thousands, well-labelled | Easy to find bugs with clear error messages |
| Fix commit style | Usually 1–3 files | Ground truth is unambiguous |
| Test framework | pytest | testrunner.sh detects correctly |
| Import depth | Shallow | deps.sh traces correctly |
| Credibility | Well-known project | Good demo value |
| History quality | 15+ years | git blame is meaningful |

### Alternatives considered

| Repo | Files | Notes | Verdict |
|---|---|---|---|
| `tiangolo/fastapi` | ~400 files | Async-heavy, good Python | Second choice |
| `django/django` | ~2000 files | L-tier, too large for quick test | Too slow |
| `requests/requests` | ~50 files | XS-tier, too small | Too simple |
| `psf/black` | ~100 files | S-tier, formatter — bugs are subtle | Harder to score |

**Recommendation: Flask. Second choice: FastAPI.**

---

## 4. How Many Bugs and Why 3

Three bugs covering three difficulty levels. This matters because:
- **1 bug** — could get lucky, not representative
- **3 bugs** — catches systematic failures (e.g. briefing always fails on vague issues)
- **5+ bugs** — overkill for Step 4.5, slows down each test run

| Bug | Difficulty | Criteria |
|---|---|---|
| Bug 1 — Easy | Baseline | Quoted error string in issue, 1-file fix, error string exists in source code |
| Bug 2 — Medium | Realistic | 2-file fix, issue text moderately vague, fix commit touches both files |
| Bug 3 — Hard | Edge case | No quoted error string in issue, old bug (tests git lookback), fix is a logic change not a crash |

Bug 3 is intentionally expected to produce weak briefing — that is the honest result, not a failure of the strategy.

---

## 5. What Gets Created and Where

### 5a. Fixture data (committed to MAS repo)

```
C:\MAS_final\test-fixtures\
└── flask\
    ├── README.md                   ← documents all bugs, SHAs, how to use
    ├── bugs\
    │   ├── bug1.md                 ← GitHub issue title + body, copy-pasted
    │   ├── bug2.md
    │   └── bug3.md
    └── expected\
        ├── bug1_fix_sha.txt        ← one line: the fix commit SHA
        ├── bug1_fix_files.txt      ← one file per line: files touched by fix
        ├── bug2_fix_sha.txt
        ├── bug2_fix_files.txt
        ├── bug3_fix_sha.txt
        └── bug3_fix_files.txt
```

**Why committed:** Portable. Any developer, any machine, any CI can run the tests with this data. No internet required once the fixture is written. The bug text and expected answers are static facts.

### 5b. Cloned repo (NOT committed, gitignored)

```
C:\MAS_final\test-repos\
└── flask\        ← git clone --depth 100 https://github.com/pallets/flask
```

**Why gitignored:** A git clone of Flask is ~50MB. Not appropriate to commit. Recreatable with one command. `.gitignore` entry: `test-repos/`.

### 5c. Test script (committed to MAS repo)

```
C:\MAS_final\rca-mas\tests\test_real_briefing.sh
```

Runs briefing against each of the 3 bugs and scores the output. Does NOT call Claude. Does NOT require Agent 1.

---

## 6. What the Test Script Does

```
For each bug (1, 2, 3):
  1. Read fix_sha from expected/
  2. git checkout fix_sha~1   (one commit before the fix)
  3. Set BUG_FILE to bugs/bugN.md
  4. Run briefing.sh directly (not full pipeline)
  5. Assert:
     a. briefing.md created
     b. errors.txt created
     c. MENTIONED_FILES contains at least one file from fix_files.txt  ← key signal
     d. Error Sources section contains at least one match in fix files ← key signal
     e. TEST_COMMAND is pytest
     f. Git History section is non-empty
     g. Briefing Warnings is (none)
  6. Report: PASS / PARTIAL / FAIL with details
```

**Scoring is objective.** The ground truth is `fix_files.txt`. Either briefing pointed Agent 1 at the right files or it didn't. No subjective judgment.

**PARTIAL** is a valid outcome — if briefing found 1 of 2 fix files, that's useful information (Agent 1 still gets a head start) but not perfect.

---

## 7. Setup Procedure (One-Time, ~30 Minutes)

### Phase 1 — Find the 3 bugs (15 min, manual)

Go to `github.com/pallets/flask/issues?state=closed` and search for issues with:
- A quoted error message in the body
- A linked PR or commit reference
- Fix commit that touches 1–3 files (check with `git show <sha> --name-only`)

Record: issue number, issue title, issue body, fix commit SHA, files changed.

### Phase 2 — Create fixture data (10 min)

```bash
mkdir -p C:\MAS_final\test-fixtures\flask\{bugs,expected}

# For each bug:
# 1. Paste issue text into bugs/bugN.md
# 2. Write SHA into expected/bugN_fix_sha.txt
# 3. Run: git show <sha> --name-only | grep -v '^commit\|^Author\|^Date\|^$\|^    ' \
#          > expected/bugN_fix_files.txt
```

### Phase 3 — Clone the repo (5 min)

```bash
git clone --depth 100 https://github.com/pallets/flask C:\MAS_final\test-repos\flask
```

Verify all 3 fix commits are within the depth:
```bash
git -C C:\MAS_final\test-repos\flask log --oneline | grep -E "<sha1>|<sha2>|<sha3>"
```

### Phase 4 — Run the test once manually, inspect output

```bash
bash rca-mas/tests/test_real_briefing.sh
cat test-repos/flask/.rca-mas/runs/latest/briefing.md
```

Manually read `briefing.md`. Does it look useful? Would you give this to a developer as a starting point?

---

## 8. How This Fixture Is Reused Per Step

| Step | What it adds | How fixture is used |
|---|---|---|
| **4.5 (now)** | Briefing quality check | Run briefing, check MENTIONED_FILES and Error Sources against fix_files.txt |
| **6 (Agent 1)** | First real diagnosis | Run full pipeline, check `diagnosis.affected_files` against fix_files.txt. Does Agent 1 find the right file? |
| **7 (Agent 2)** | Fix quality | Check `patches/fix.diff` targets the right file. Is the diff reasonable? |
| **8 (Report)** | Readability | Read report.md as a developer. Is it clear? Would you act on it? |
| **12 (Final)** | Full acceptance | Run all 3 bugs end-to-end. Score each dimension. Pass/fail against defined criteria. |

**The fixture is built once and used 5 times.** Cost is paid now, value compounds across every subsequent step.

---

## 9. Pros and Cons

### Pros

| Pro | Detail |
|---|---|
| Catches real failures early | Briefing on a vague GitHub issue may produce `MENTIONED_FILES: (none)` — you want to know this before building Agent 1 on top |
| Objective scoring | Ground truth is the fix commit. Pass/fail is unambiguous |
| Reusable across all remaining steps | No recreation needed from Step 4.5 through Step 12 |
| Cheap to set up | ~30 minutes, no code changes to the MAS itself |
| Honest about limitations | Bug 3 (hard) is expected to score poorly — that's a feature, not a bug |
| Doesn't block Step 5 | Fixture setup is parallel work. Step 5 (schemas) can proceed independently |
| Credible demo | Flask is well-known. Shows the tool works on a real project |

### Cons

| Con | Detail | Mitigation |
|---|---|---|
| Manual bug selection | Need to find 3 good bugs manually (~15 min) | One-time cost |
| Clone required | ~50MB Flask clone, not committed | Gitignored, one-command setup |
| Windows git ownership | `/tmp` clone may hit safe-directory issues | Use user home dir for clone: `C:\MAS_final\test-repos\` |
| Briefing may be weak on hard bug | Bug 3 expected to score low | That's honest — surfaces real limitation |
| No automated re-clone | If clone is deleted, must re-run setup | Documented in README.md |
| Flask may not cover all languages | Python only | Sufficient for v1 — no JS/Go test repos needed yet |
| Breaks if Flask repo changes | Fix commits could be rebased/deleted | Use `--depth 100` + verify at setup time |

---

## 10. What This Does NOT Do

To be clear about scope:

- Does NOT test Agent 1 (not built yet)
- Does NOT validate fix quality
- Does NOT test validation worktree
- Does NOT automate GitHub issue fetching (bug text is copy-pasted manually)
- Does NOT run on every `make test` call (too slow, kept separate)
- Does NOT replace the synthetic unit tests already in place

It is a **manual quality gate** run at key checkpoints, not a continuous integration test.

---

## 11. Decision Criteria for Judge LLM

Before approving this strategy, verify:

1. **Scope is correct** — Step 4.5 only tests briefing output, not agent quality. Agent calls are zero.
2. **Fixture is reusable** — same 3 bugs, same SHAs, same expected files used from Step 4.5 through Step 12.
3. **Ground truth is objective** — scoring based on `fix_files.txt` content, not subjective opinion.
4. **Separation is clean** — fixture data committed, cloned repo gitignored, test script in `tests/`.
5. **Doesn't break existing gates** — `make test` still runs the fast synthetic tests. Real repo test is a separate script.
6. **Doesn't block Step 5** — schemas can be written in parallel.
7. **Effort is proportionate** — ~30 min setup, ~10 min per subsequent use. Worth it for a tool that claims to compress 30-60 min investigations.

---

## 12. Open Decisions (Need Your Input)

| Decision | Options | My recommendation |
|---|---|---|
| Which repo? | Flask / FastAPI / other | Flask — smaller, simpler, well-known |
| Who selects the 3 bugs? | Me (research GitHub) / You (pick issues you know) | I research, you approve |
| Where does clone live? | `C:\MAS_final\test-repos\` / inside `rca-mas\` | `C:\MAS_final\test-repos\` — outside rca-mas folder |
| When to do setup? | Before Step 5 / After Step 5 / After Step 6 | After Step 5 — schemas are fast, no conflict |
| Hard fail on Bug 3? | Yes / No — PARTIAL is acceptable | PARTIAL acceptable — honesty over false pass |

---

## 13. Summary Recommendation

**Do Step 4.5. It is worth 30 minutes now to avoid hours of rework at Step 12.**

The specific recommendation:
1. Use **Flask** as the test repo
2. Find **3 bugs** with clear fix commits — I research, you approve the selections
3. Store fixture in `C:\MAS_final\test-fixtures\flask\` (committed)
4. Clone to `C:\MAS_final\test-repos\flask\` (gitignored)
5. Do setup **after Step 5** so it doesn't block schema work
6. Run `test_real_briefing.sh` manually before starting Step 6 to confirm briefing quality
