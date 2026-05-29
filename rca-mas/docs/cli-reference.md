# CLI Reference

---

## Basic Usage

```bash
# Run from inside the repo you want to analyze
cd /path/to/target-repo
bash /path/to/rca-mas/rca-mas.sh bug.md
```

```bash
# With validation (applies patch in worktree, runs test suite)
bash /path/to/rca-mas/rca-mas.sh bug.md --validate
```

```bash
# Read the report after the run
cat .rca-mas/runs/latest/report.md
```

---

## Commands

### `rca-mas.sh <bug-file> [--validate]`

Run the full pipeline against the current directory (which must be the target repo).

| Argument | Required | Description |
|---|---|---|
| `<bug-file>` | Yes | Path to the bug report markdown file |
| `--validate` | No | Run Agent 2.5: apply patch in worktree and execute test suite |

**Exit codes:**
- `0` — pipeline completed (report written, even if confidence is low or fix is `NO_FIX`)
- `1` — fatal startup error (missing bug file, missing `TARGET_REPO_ROOT`, config error)

The pipeline does **not** exit non-zero if Agent 1 times out, if Agent 2 emits `NO_FIX`, or if Agent 2.5 tests fail. Partial success is still exit 0 — check the report for the actual outcome.

---

## Makefile Shortcuts

From inside `rca-mas/`:

```bash
make lint              # bash -n syntax check on all scripts
make test              # run all 4 automated test suites (no Claude)
make test-real-briefing  # run briefing against real pallets/click bugs
make run               # bash rca-mas.sh examples/bug.md
make run-validate      # bash rca-mas.sh examples/bug.md --validate
make report            # cat .rca-mas/runs/latest/report.md
make clean             # rm -rf .rca-mas/runs .rca-mas-worktrees
```

---

## Environment Variables

All variables are optional overrides. Set them before running to change behavior.

### Model

| Variable | Default | Description |
|---|---|---|
| `RCA_MODEL` | `""` (uses `claude-sonnet-4-6`) | Override the Claude model for all agents |

```bash
RCA_MODEL=claude-opus-4-7 bash rca-mas.sh bug.md
```

### Agent 1 — Diagnosis

| Variable | Default | Description |
|---|---|---|
| `RCA_A1A_TURNS_XS` | `200` | Max turns for repos with < 100 files (backstop; cost cap throttles) |
| `RCA_A1A_TURNS_S` | `200` | Max turns for repos with 100–499 files |
| `RCA_A1A_TURNS_M` | `200` | Max turns for repos with 500–1999 files |
| `RCA_A1A_TURNS_L` | `200` | Max turns for repos with ≥ 2000 files |
| `RCA_A1A_TIMEOUT_XS` | `900` | Wall-clock timeout (seconds) for XS tier |
| `RCA_A1A_TIMEOUT_S` | `900` | Wall-clock timeout (seconds) for S tier |
| `RCA_A1A_TIMEOUT_M` | `900` | Wall-clock timeout (seconds) for M tier |
| `RCA_A1A_TIMEOUT_L` | `900` | Wall-clock timeout (seconds) for L tier |
| `RCA_A1A_BUDGET_USD` | `10` | Per-agent cost cap (primary throttle; 0 disables) |
| `RCA_A1B_TURNS` | `20` | Synthesis turns for Agent 1b |
| `RCA_A1B_TIMEOUT` | `120` | Wall-clock timeout for Agent 1b |
| `RCA_A1B_BUDGET_USD` | `10` | Cost cap for Agent 1b |
| `RCA_CONFIDENCE_STOP` | `0.7` | Agent 1a stops early if confidence exceeds this |
| `RCA_CONFIDENCE_CHECKPOINT` | `0.4` | Confidence value written on timeout recovery |

### Agent 2 — Solution

| Variable | Default | Description |
|---|---|---|
| `RCA_AGENT2_TURNS` | `20` | Max turns for Agent 2 |
| `RCA_AGENT2_TIMEOUT` | `600` | Timeout in seconds for Agent 2 |
| `RCA_AGENT2_BUDGET_USD` | `10` | Cost cap for Agent 2 |
| `RCA_CONFIDENCE_NOFX` | `0.5` | Agent 2 emits NO_FIX if confidence is below this |
| `RCA_CONFIDENCE_WEAK_THRESHOLD` | `0.6` | Agent 2 marks `weak_evidence=true` below this confidence |

### Agent 2.5 — Validation

| Variable | Default | Description |
|---|---|---|
| `RCA_AGENT25_TURNS` | `15` | Max turns for Agent 2.5 |
| `RCA_AGENT25_TIMEOUT` | `1800` | Timeout in seconds for Agent 2.5 |
| `RCA_AGENT25_TEST_TIMEOUT` | `1200` | Timeout for test suite execution inside worktree |
| `RCA_KEEP_WORKTREE` | `0` | Set to `1` to keep the worktree after the run (for debugging) |

### Briefing / Collectors

| Variable | Default | Description |
|---|---|---|
| `RCA_GIT_LOOKBACK` | `"14 days ago"` | How far back `git.sh` looks in git history |
| `RCA_ERROR_GREP_LIMIT` | `50` | Max output lines per error string in `errors.sh` |
| `RCA_COLLECTOR_TIMEOUT` | `150` | Timeout per collector in seconds |

### Tier Breakpoints

| Variable | Default | Description |
|---|---|---|
| `RCA_TIER_XS` | `100` | File count upper bound for XS tier |
| `RCA_TIER_S` | `500` | File count upper bound for S tier |
| `RCA_TIER_M` | `2000` | File count upper bound for M tier |

### Paths

| Variable | Default | Description |
|---|---|---|
| `RCA_OUTPUT_DIR` | `".rca-mas"` | Output directory under target repo |
| `RCA_WORKTREE_DIR` | `"../.rca-mas-worktrees"` | Sibling directory for Agent 2.5 worktrees |

### Cost Monitoring

| Variable | Default | Description |
|---|---|---|
| `RCA_COST_WARN_SECONDS` | `900` | Log a warning if total runtime exceeds this |
| `RCA_COST_WARN_AGENT1_TURNS` | `40` | Log a warning if Agent 1 uses more than this many turns |

---

## Output Locations

After a run, all outputs are under:

```
<target-repo>/.rca-mas/runs/<RUN_ID>/
```

The `latest` symlink always points to the most recent run:

```
<target-repo>/.rca-mas/runs/latest/report.md
```

See [run-artifacts.md](run-artifacts.md) for a complete file listing.

---

## Copy-Paste Examples

```bash
# Quick run (no validation)
cd ~/projects/myapp
bash ~/tools/rca-mas/rca-mas.sh ~/Desktop/bug-report.md

# Run with validation
bash ~/tools/rca-mas/rca-mas.sh ~/Desktop/bug-report.md --validate

# Override model and increase turns for large repo
RCA_MODEL=claude-opus-4-7 RCA_TURNS_L=70 \
  bash ~/tools/rca-mas/rca-mas.sh bug.md

# Keep worktree for debugging a failed patch
RCA_KEEP_WORKTREE=1 bash ~/tools/rca-mas/rca-mas.sh bug.md --validate

# Run against a different repo without cd
TARGET_REPO_ROOT=/path/to/repo \
  bash ~/tools/rca-mas/rca-mas.sh bug.md

# Check briefing output without running agents
TARGET_REPO_ROOT=. \
  RUN_DIR=/tmp/test-run \
  BRIEFING=/tmp/test-run/briefing.md \
  ERRORS_TXT=/tmp/test-run/errors.txt \
  BUG_FILE=bug.md \
  bash scripts/briefing.sh && cat /tmp/test-run/briefing.md
```
