# Briefing and Collectors

`scripts/briefing.sh` and the four collectors in `collectors/` form the pure-bash scanning phase. Zero LLM calls. Runs in 3–30 seconds depending on repo size and platform.

---

## Purpose

Briefing scans the target repo and the bug report before Agent 1 runs. It produces two files:

- `briefing.md` — structured context for Agent 1 (git history, imports, error locations, test mapping)
- `errors.txt` — one search string per line, extracted from the bug report

Without briefing, Agent 1 spends 8–12 turns on orientation (where are the files? what test runner? who last touched this code?). Briefing gives it that for free.

---

## briefing.sh — How It Works

**Inputs (all from environment, not CLI args):**
- `BUG_FILE` — path to the bug report (set by orchestrator)
- `TARGET_REPO_ROOT` — the repo being analyzed
- `RUN_DIR` — where outputs are written
- `TOOL_ROOT` — where MAS scripts and config live
- All `RCA_*` config vars (sourced from `config/defaults.env`)

**Outputs:**
- `{RUN_DIR}/briefing.md`
- `{RUN_DIR}/errors.txt`

### Phase 1 — Extract search strings from bug report

Extracts both double-quoted and backtick-quoted strings of 5–200 characters:

```bash
grep -oE '"[^"]{5,200}"|`[^`]{5,200}`' "$BUG_FILE"
```

**Why both quote styles:** Real GitHub issues use both. `"TypeError: ..."` uses double quotes. `` `shell=True` `` or `` `prompt_suffix` `` use backticks. Extracting only double quotes misses 3 of 5 real-world bugs in the test fixture.

Strings are written to `errors.txt`, one per line, deduplicated, surrounding quotes stripped. `errors.sh` later searches the whole repo for each one.

**Important:** These are *search anchors*, not guaranteed error messages. A string like `"SAVE10"` (a discount code) or `` `--green` `` (a CLI option) will end up in `errors.txt` and may produce irrelevant search results. Agent 1 must weigh evidence, not assume every match is the bug location.

### Phase 2 — Extract and validate file paths

Extracts anything that looks like a file path from the bug report. Then applies five rejection rules:
1. Absolute paths (`/etc/passwd`) — rejected
2. Path traversal (`../../../secret`) — rejected
3. Secret file extensions (`.env`, `.pem`, `.key`, `id_rsa`, `.secret`, `.token`, `.passwd`, `.password`) — rejected
4. Unknown extension — rejected (only ~25 known source extensions accepted)
5. Not tracked by `git ls-files` — rejected in a git repo even if file exists on disk

Uses a **single `git ls-files` call** cached in `$_tracked` — no subprocess per file.

In non-git directories, falls back to filesystem existence check (`-f`).

### Phase 3 — File count and tier selection

Reuses `$_tracked` from Phase 2. Counts lines. Selects turn budget and timeout from `config/defaults.env`:

| File count | Tier | MAX_TURNS | TIMEOUT |
|---|---|---|---|
| < 100 | XS | 200 | 900s |
| 100–500 | S | 200 | 900s |
| 500–2000 | M | 200 | 900s |
| > 2000 | L | 200 | 900s |

Turns are an emergency cap in the current config; per-tier overrides remain available via `RCA_A1A_TURNS_*` and `RCA_A1A_TIMEOUT_*` in `defaults.env`.

### Phase 4 — Write metadata header

```
## Metadata
MAX_TURNS: 25
TIMEOUT: 300
FILE_COUNT: 149
REPO_TIER: S
MENTIONED_FILES: src/click/core.py
ERROR_COUNT: 2
TEST_COMMAND: UNKNOWN   ← placeholder, backfilled after testrunner.sh runs
```

### Phase 5 — Run collectors

Each collector runs as `timeout $RCA_COLLECTOR_TIMEOUT bash collector.sh`. If it times out or crashes, a warning is written to `## Briefing Warnings` and the pipeline continues. Nothing can abort briefing.

### Phase 6 — Backfill TEST_COMMAND

After `testrunner.sh` runs, it writes the detected command to `{RUN_DIR}/test_command.txt`. Briefing reads this and replaces `TEST_COMMAND: UNKNOWN` in the header using `awk` (safe for commands containing `/`, `&`, spaces — e.g. `go test ./...`).

---

## collectors/git.sh

**What it does:** Fetches recent git history and blame for files mentioned in the bug report.

**Outputs to briefing.md:**
- `### Recent merges` — last 10 merge commits within `RCA_GIT_LOOKBACK` window
- `### Log: <file>` — last 10 commits touching each mentioned file
- `### Blame (first 30 lines): <file>` — who last changed each line

**Tuning:** `RCA_GIT_LOOKBACK` in `config/defaults.env` (default: `"14 days ago"`). Widen for older bugs.

**Limitations:** Only looks back `RCA_GIT_LOOKBACK` days. Blame only covers first 30 lines. Squash-merged PRs may not appear in merge list.

---

## collectors/deps.sh

**What it does:** Traces top-level imports for mentioned Python, JS/TS, and Go files.

**Outputs to briefing.md:** `### Imports in: <file>` — up to 30 import lines per file.

**Supported languages:** Python (`import`/`from X import`), JS/TS/JSX/TSX/Vue/Svelte (`import`/`require`), Go (import blocks).

**Limitations:** Top-level imports only. No transitive dependencies. No dynamic imports. Ruby, PHP, Java, C# etc. get `(unsupported language for import tracing: .ext)`.

---

## collectors/errors.sh

**What it does:** Fixed-string search across the target repo for each line in `errors.txt`.

**Key behaviors:**
- Uses `rg -nF` if available, falls back to `grep -RFn`
- Excludes: `.git`, `.rca-mas`, `node_modules`, `.venv`, `venv`, `dist`, `build`, `coverage`
- Excludes the bug report file itself (via `BUG_SOURCE_FILE` path matching — both POSIX and Windows path formats)
- Output capped at `RCA_ERROR_GREP_LIMIT` lines per string (default: 50)
- If only the bug report matched, says `(no matches outside bug report)`

**Why bug.md is excluded:** The bug report always contains the strings being searched. Showing it as "evidence" would be circular — Agent 1 already has the bug report and should not mistake the QA description for source-code proof.

---

## collectors/testrunner.sh

**What it does:** Detects the test runner by checking config files. Never runs tests.

**Detection order:**
1. `pytest.ini` / `pyproject.toml` / `setup.cfg` → `pytest` (or `poetry run pytest` / `uv run pytest`)
2. `tox.ini` → `tox`
3. `noxfile.py` → `nox`
4. `go.mod` → `go test ./...`
5. `package.json` (parsed with `jq`) → `npx vitest`, `npx jest`, `pnpm test`, `yarn test`, `npm test`
6. `Makefile` with `test:` target → `make test`
7. Nothing found → `TEST_COMMAND: UNKNOWN`

Also maps mentioned source files to test files by naming convention (e.g. `src/cart/pricing.py` → `tests/test_pricing.py`).

Writes detected command to `{RUN_DIR}/test_command.txt` for header backfill.

---

## Performance Note

On Windows (MSYS2/Git-for-Windows), briefing takes ~25s because each `bash` subprocess and `git` process costs ~2-3s to start. On Linux/Mac the same code runs in 3–5s. This is platform overhead, not a code bug. The smoke test uses a fixture with no quoted strings to stay fast — real briefing quality is tested separately via `make test-real-briefing`.

---

## Real Repo Testing

The `tests/real_repos/click/` fixture (5 real `pallets/click` bugs) is the benchmark for briefing quality. See `docs/testing-real-github-bugs.md` for the full testing guide.

To run:
```bash
make test-real-briefing
```

This is separate from `make test` and requires the Click clone at `C:/MAS_final/test-repos/click` or `RCA_REAL_REPO_ROOT` override.
