# Validation Worktree

How Agent 2.5 applies the patch and runs tests without touching the main working tree.

---

## Why a Worktree

Agent 2.5 needs to apply a patch and run tests. Doing this in the main working tree would:
- Modify files the developer has open
- Risk leaving the repo in a dirty state if the run is interrupted
- Make it impossible to run two validations concurrently

A git worktree solves all three: it shares the same git object store as the main repo but has its own working directory and checkout. Cleanup is a single `git worktree remove` command.

---

## Worktree Location

```
<target-repo>/          ← TARGET_REPO_ROOT (never modified)
../.rca-mas-worktrees/  ← sibling directory (created by orchestrator)
    └── <RUN_ID>/       ← one worktree per run
```

The worktree is placed one level above the target repo — it is never inside it. If `TARGET_REPO_ROOT` is `/home/user/projects/myapp`, the worktree is at `/home/user/projects/.rca-mas-worktrees/20260504-101523/`.

---

## Lifecycle

### 1. Creation (orchestrator)

```bash
git worktree add "../.rca-mas-worktrees/$RUN_ID" HEAD
```

Creates a worktree at the current HEAD commit (same state as the main working tree's latest commit). Unstaged changes in the main tree are **not** present in the worktree — the worktree starts from a clean committed state.

### 2. Patch Application (Agent 2.5)

Agent 2.5 receives the path to the worktree and the path to the patch files in `solution.json`. It runs:

```bash
cd ../.rca-mas-worktrees/$RUN_ID
git apply /path/to/run/patches/fix_core.diff
```

If the patch fails to apply (`git apply` exits non-zero), Agent 2.5 writes `validation.json` with `status: ERROR` and `patch_applied: false`. The worktree is still cleaned up normally.

### 3. Test Execution (Agent 2.5)

After a successful patch application, Agent 2.5 runs the test command from `TEST_COMMAND`:

```bash
cd ../.rca-mas-worktrees/$RUN_ID
timeout $RCA_AGENT25_TEST_TIMEOUT pytest tests/
```

The test output is captured and summarised in `validation.json`. Full output is available in `raw_agent25_output.txt`.

If tests time out (exit 124), Agent 2.5 writes `status: ERROR` and notes the timeout.

### 4. Cleanup (orchestrator)

After Agent 2.5 completes, the orchestrator removes the worktree:

```bash
git worktree remove --force "../.rca-mas-worktrees/$RUN_ID"
```

The `--force` flag handles the case where the worktree has uncommitted changes (from the applied patch). The git object store in the main repo is unaffected.

---

## Keeping the Worktree for Debugging

Set `RCA_KEEP_WORKTREE=1` before running:

```bash
RCA_KEEP_WORKTREE=1 bash rca-mas.sh bug.md --validate
```

The worktree stays after the run. You can inspect the patched state:

```bash
ls ../.rca-mas-worktrees/
cd ../.rca-mas-worktrees/<RUN_ID>
git diff HEAD          # shows the applied patch
pytest tests/ -v      # run tests again manually
```

To remove it manually:

```bash
git worktree remove --force ../.rca-mas-worktrees/<RUN_ID>
# Or if the worktree directory was already deleted:
git worktree prune
```

---

## What Agent 2.5 Is Allowed to Do

| Allowed | Forbidden |
|---|---|
| Read files in the worktree | Read files in the main working tree |
| Write files in the worktree | Write to the main working tree |
| Apply patch with `git apply` | `git commit` |
| Run test suite with `timeout` | `git push` |
| Read `solution.json` and patch files | `git branch`, `git checkout` in main repo |
| Write `validation.json` to `RUN_DIR` | Network access |

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `RCA_WORKTREE_DIR` | `"../.rca-mas-worktrees"` | Parent directory for all worktrees |
| `RCA_KEEP_WORKTREE` | `0` | Set to `1` to skip cleanup after the run |
| `RCA_AGENT25_TEST_TIMEOUT` | `1200` | Seconds allowed for test suite execution |
| `RCA_AGENT25_TURNS` | `15` | Max turns for Agent 2.5 |
| `RCA_AGENT25_TIMEOUT` | `1800` | Wall-clock timeout for the entire Agent 2.5 stage |

---

## Common Failures

### Patch does not apply

```json
{ "status": "ERROR", "patch_applied": false }
```

Likely causes:
- The patch was generated against a different commit than the current HEAD
- A line-ending mismatch (CRLF vs LF on Windows)
- The patch target file was moved or deleted since the patch was generated

Fix: inspect the diff manually and apply with `patch -p1` or edit and apply by hand.

```bash
cat .rca-mas/runs/latest/patches/*.diff
git apply --check .rca-mas/runs/latest/patches/*.diff  # dry run
```

### Tests fail after patch applies

```json
{ "status": "FAIL", "test_output_summary": "1 failed" }
```

This is the most useful outcome — it tells you the patch is wrong or incomplete. Keep the worktree (`RCA_KEEP_WORKTREE=1`) and investigate:

```bash
cd ../.rca-mas-worktrees/<RUN_ID>
pytest tests/ -v        # run again with verbose output
pytest tests/ -v -x     # stop on first failure
```

### Test suite times out

Increase `RCA_AGENT25_TEST_TIMEOUT`:

```bash
RCA_AGENT25_TEST_TIMEOUT=300 bash rca-mas.sh bug.md --validate
```

Or run the test command directly in the worktree after using `RCA_KEEP_WORKTREE=1`.

### Worktree directory already exists

If a previous run was interrupted before cleanup:

```bash
git worktree list                      # see all worktrees
git worktree remove --force ../.rca-mas-worktrees/<OLD_RUN_ID>
git worktree prune                     # clean stale entries
```
