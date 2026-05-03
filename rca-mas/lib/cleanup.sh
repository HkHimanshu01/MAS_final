#!/usr/bin/env bash
# lib/cleanup.sh — Worktree cleanup trap.
# Inputs: WORKTREE_PATH set via register_worktree; RCA_KEEP_WORKTREE controls behaviour.
# Outputs: Removes worktree on EXIT unless RCA_KEEP_WORKTREE=1.

WORKTREE_PATH=""

register_worktree() {
  WORKTREE_PATH="$1"
}

run_cleanup() {
  if [ -z "$WORKTREE_PATH" ]; then
    return 0
  fi
  if [ "${RCA_KEEP_WORKTREE:-0}" = "1" ]; then
    warn "Keeping worktree at ${WORKTREE_PATH} (RCA_KEEP_WORKTREE=1)"
    return 0
  fi
  if [ -d "$WORKTREE_PATH" ]; then
    git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || rm -rf "$WORKTREE_PATH"
  fi
}
