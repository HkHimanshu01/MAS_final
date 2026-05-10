# Click Real-Repo Test Fixture

**Repo:** `pallets/click`
**Purpose:** Quality benchmark for all MAS testing from Step 4.5 through Step 12.
**Status:** Locked — do not change bug selection or expected files without updating this README.

---

## What this is

Five real closed bugs from `pallets/click` with known fix commits. Used to verify that the MAS produces useful output on real production code, not just synthetic test repos.

These same 5 bugs are reused at every quality checkpoint:

| Step | What is tested |
|---|---|
| 4.5 | Briefing quality — does briefing.md surface the right signals? |
| 6 | Agent 1 diagnosis — does diagnosis.affected_files match fix files? |
| 7 | Agent 2 fix quality — does patches/fix.diff target the right file? |
| 8 | Report usefulness — is report.md readable and actionable? |
| 11 | Validation — does the patch apply and do tests pass? |
| 12 | Final end-to-end scoring across all 5 bugs |

---

## Clone setup (one-time)

```bash
git clone https://github.com/pallets/click C:/MAS_final/test-repos/click
```

Override clone location:
```bash
export RCA_REAL_REPO_ROOT=/path/to/click
```

The clone is NOT committed to this repo (gitignored via `test-repos/`).

---

## The 5 bugs

| Bug | Issue | PR | Difficulty | Fix SHA (full) | Pre-fix ref (full) | Source files |
|---|---|---|---|---|---|---|
| 1 | [#2971](https://github.com/pallets/click/issues/2971) | [#2972](https://github.com/pallets/click/pull/2972) | Easy | `0be2bd385064053bb75f92db317de128db729d52` | `c88f333de440c5066ff563f784a6561f4713cf78` | `src/click/core.py` |
| 2 | [#3039](https://github.com/pallets/click/issues/3039) | [#3055](https://github.com/pallets/click/pull/3055) | Easy | `7d7183604158f064390539d83d4a19a978c6b08a` | `35e6a78646c58a8cc1ba3cda603a6bd4fb87f9d5` | `src/click/_termui_impl.py` |
| 3 | [#3071](https://github.com/pallets/click/issues/3071) | [#3079](https://github.com/pallets/click/pull/3079) | Medium | `27aaed3fe5bcd6adedd6e91de234914af9859cf1` | `2ed395b0b5ac4d56553ff715335f456f812cdc78` | `src/click/core.py` |
| 4 | [#3066](https://github.com/pallets/click/issues/3066) | [#3068](https://github.com/pallets/click/pull/3068) | Medium/Hard | `6a1c0d077311f180b356965914e2de5b9e0fdb44` | `7d7183604158f064390539d83d4a19a978c6b08a` | `src/click/core.py` |
| 5 | [#3019](https://github.com/pallets/click/issues/3019) | [#3021](https://github.com/pallets/click/pull/3021) | Hard | `8533c966b84783718e74286aa7b098f3ff1e9221` | `5f86603a84e12bdec1584c15c9f982740e613c45` | `src/click/termui.py` |

---

## Running the briefing test

```bash
make test-real-briefing
```

Or directly:
```bash
bash tests/test_real_repo_briefing.sh
```

Skips gracefully if clone is missing.

---

## Fixture layout

```
tests/real_repos/click/
├── README.md                   ← this file
├── scoring_contract.md         ← scoring rules for each step
├── bugs/
│   ├── bug1.md                 ← GitHub issue #2971 text (input to MAS)
│   ├── bug2.md                 ← GitHub issue #3039 text
│   ├── bug3.md                 ← GitHub issue #3071 text
│   ├── bug4.md                 ← GitHub issue #3066 text
│   └── bug5.md                 ← GitHub issue #3019 text
└── expected/
    ├── bugN_fix_sha.txt        ← full SHA of the fix commit (1 line)
    ├── bugN_pre_fix_ref.txt    ← full SHA of the pre-fix checkout (1 line)
    ├── bugN_fix_files.txt      ← source files changed by fix (1 per line)
    └── bugN_metadata.json      ← difficulty, URLs, root cause, expected score
```

---

## Repo facts

| Fact | Value |
|---|---|
| Tracked files | 149 → S-tier (25 turns, 300s) |
| Test command | pytest (detected via pyproject.toml) |
| Total commits | 3097 |
| Clone style | Full clone |
