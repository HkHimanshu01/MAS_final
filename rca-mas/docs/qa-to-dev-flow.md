# QA to Developer Flow

How RCA MAS fits into the real bug-investigation workflow, why manual QA finds bugs that automated tests miss, and what the human handoff looks like.

---

## The Problem This Tool Solves

Automated test suites verify known behavior. QA engineers discover unexpected behavior. These are different activities, and the gap between them is where most production bugs live.

A QA engineer finds a bug. They write a bug report. That report lands on a developer's desk. The developer must now:

1. Reproduce the bug in their environment
2. Read the codebase to form a hypothesis
3. Search for where the error originates
4. Check recent git history for relevant changes
5. Identify which files need to change
6. Write a fix and test it

Steps 2–5 are pure investigation. On a medium-sized codebase (500–2000 files), this takes 30–60 minutes even for experienced developers. It requires holding a large mental model of the codebase in working memory while searching for a needle in a haystack.

RCA MAS automates steps 2–5. The developer receives a report that already has the root cause, evidence, affected files, and a proposed fix. They review and apply — they do not investigate from scratch.

---

## Why Automated Tests Pass While QA Finds Bugs

Three categories explain most of the gap:

### 1. Edge cases not covered by unit tests

Unit tests verify the happy path and a handful of known edge cases. QA exercises the product as a user would — with unexpected input combinations, unusual workflows, and interactions between features.

Example: A unit test verifies that `show_envvar=True` shows the env var. No test verifies what happens when `show_envvar=True` but `envvar=None`. QA finds this by running the CLI with an option that has no env var configured.

### 2. Regression from a recent change

A refactor or feature addition changes a shared function's behavior. Existing tests pass because they test the new behavior. The bug is in an undocumented invariant that the tests never encoded.

Example: A commit changes `Popen()` to use a list argument but forgets to change `shell=True` to `shell=False`. The existing test suite doesn't exercise the `--nonsense` argument being swallowed by the shell. A downstream project (mycli) runs tests that exercise it and fails.

### 3. Integration behavior between components

Unit tests mock dependencies. Integration tests run the full stack but only against known fixture data. QA runs the real product with real data and finds that two components interact incorrectly.

Example: `ctx.invoke()` was changed to use a new sentinel value. The component calling `ctx.invoke()` passes the sentinel downstream. The downstream component (JSON serializer) doesn't know what to do with a `Sentinel` object. All unit tests pass because they mock `ctx.invoke()`.

---

## The Bug Report Format

RCA MAS expects a `bug.md` file. No strict schema is required, but the tool extracts more signal from richer reports.

**What the tool extracts automatically:**
- Double-quoted strings (error messages, literal values): `"TypeError: the JSON object must be str"`
- Backtick-quoted strings (code references): `` `ctx.invoke` ``, `` `shell=True` ``
- File paths that are git-tracked: `src/click/core.py`, `src/click/_termui_impl.py`

**What makes a good bug report:**
- Exact error message, quoted
- Stack trace or code snippet
- Steps to reproduce
- Which version introduced the bug (if known)
- Related code paths or function names mentioned in backticks

**What the tool ignores:**
- User-supplied file paths that are not git-tracked (e.g. the user's own test script `click-test.py`)
- Absolute paths
- File extensions it doesn't recognise as source code

See `examples/bug.md` for a realistic example.

---

## End-to-End Flow

```
QA Engineer                Developer               RCA MAS Tool
──────────────────────────────────────────────────────────────────
Finds bug in product
  │
  ▼
Writes bug.md
  │
  ▼
Hands bug.md to developer ──────────────────────────────────────►
                                                                 │
                                Runs: bash rca-mas.sh bug.md     │
                                                                 ▼
                                                   briefing.sh scans repo
                                                   Agent 1 investigates
                                                   Agent 2 writes fix
                                                   (Agent 2.5 validates)
                                                                 │
                           ◄─────────────────── report.md ready │
                           │
                           Reviews report.md
                           Reads: root cause, evidence, proposed fix
                           │
                           ▼
                    git apply .rca-mas/runs/latest/patches/*.diff
                           │
                           ▼
                    Runs test suite manually
                           │
                           ▼
                    Reviews diff, adjusts if needed
                           │
                           ▼
                    Creates PR
```

---

## What the Developer Does With the Report

The report (`report.md`) has 11 sections. Here is how a developer reads it:

| Section | What the developer does |
|---|---|
| **Status** | Skims for `COMPLETE` vs `NO_FIX`. If `NO_FIX`, read the reason and investigate manually. |
| **Root Cause** | Reads the explanation. If it matches their mental model, continue. If it doesn't, open the cited file and verify. |
| **Confidence** | Checks the score. `HIGH` (≥ 0.7): apply the patch and test. `MEDIUM` (0.5–0.69): review the patch carefully before applying. `LOW` (< 0.5): treat the patch as a starting point, not a solution. |
| **Evidence** | Navigates to the cited file and line numbers. Confirms the tool found the right code. |
| **Affected Files** | Checks that the list makes sense. If unexpected files appear, investigate why. |
| **Proposed Fix** | Reads the description and reviews the diff. A developer with domain knowledge can often spot mistakes in the patch at this point. |
| **Patch Files** | Applies the patch: `git apply .rca-mas/runs/latest/patches/*.diff` |
| **Validation** | Checks whether the patch passed tests. `PASS` = green light. `FAIL` = something needs fixing. `SKIPPED` = run `make test` manually. |
| **Cost / Runtime** | Notes how many turns were used (high turn count can indicate the bug was hard to find). |
| **Unknowns / Risks** | Reads any explicit uncertainties the agent flagged. These are things the developer must verify themselves. |
| **Next Action** | Follows the numbered checklist. |

---

## When to Re-Run vs. Investigate Manually

**Re-run** when:
- `status: PARTIAL` (Agent 1 timed out) — increase the turn budget and try again
- `status: NO_FIX` with a low confidence that seems wrong — add more context to the bug report and re-run
- The report describes a plausible but wrong root cause — often fixed by adding the correct file path or error message to the bug report

**Investigate manually** when:
- `status: NO_FIX` with a coherent reason — the tool confirmed there is no clear root cause in the codebase; a human needs to dig deeper
- The evidence section cites irrelevant files — the bug may be in a dependency, not the repo
- The bug requires understanding deployment context or external services — the tool only sees the repo

---

## Human Handoff Checklist

Before closing the bug ticket:

```
[ ] Applied patch with git apply (or applied manually if patch was wrong)
[ ] Ran the full test suite locally
[ ] Confirmed the bug reproduction steps no longer reproduce
[ ] Reviewed Unknowns / Risks section in report.md
[ ] Added a regression test if one didn't exist
[ ] Committed with a message referencing the bug ticket
[ ] PR created and linked to the original bug report
```
