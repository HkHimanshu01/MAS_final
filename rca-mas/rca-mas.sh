#!/usr/bin/env bash
# rca-mas.sh — Entry point for RCA Compression MAS.
# Usage: ./rca-mas.sh <bug.md> [--validate]
#        ./rca-mas.sh --issue <NUM> [--repo owner/repo] [--validate]
# Inputs: bug file or GitHub issue number, optional flags.
# Outputs: delegates to scripts/orchestrator.sh.
set -Eeuo pipefail
IFS=$'\n\t'

die()  { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf '[rca-mas] WARNING: %s\n' "$*" >&2; }
info() { printf '[rca-mas] %s\n' "$*" >&2; }

# Resolve TOOL_ROOT to the directory containing this script
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TOOL_ROOT

# Source config
# shellcheck source=config/defaults.env
source "${TOOL_ROOT}/config/defaults.env"

usage() {
  cat >&2 <<EOF
RCA Compression MAS — compress a bug investigation into a 3-8 minute report.

Usage:
  $(basename "$0") <bug.md>                        Report-only mode (safe, never edits code)
  $(basename "$0") <bug.md> --validate             Validate fix in isolated git worktree
  $(basename "$0") --issue <NUM>                   Fetch GitHub issue as bug input
  $(basename "$0") --issue <NUM> --repo <slug>     Fetch issue from explicit repo
  $(basename "$0") --help                          Show this help

Examples:
  $(basename "$0") examples/bug.md
  $(basename "$0") examples/bug.md --validate
  $(basename "$0") --issue 5234 --repo pallets/flask

Environment overrides (export before running):
  RCA_MODEL=claude-opus-4-7     Use a different Claude model
  RCA_TURNS_S=30                Override turn budget for S-tier repos
  RCA_KEEP_WORKTREE=1           Keep validation worktree after run

Output:
  .rca-mas/runs/<RUN_ID>/report.md
  .rca-mas/runs/latest/         -> most recent run

EOF
}

# --- Parse arguments ---
BUG_FILE=""
ISSUE_NUM=""
REPO_SLUG=""
VALIDATE=0

if [ $# -eq 0 ]; then
  usage
  exit 1
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      usage
      exit 0
      ;;
    --validate)
      VALIDATE=1
      shift
      ;;
    --issue)
      [ -n "${2:-}" ] || die "--issue requires a number"
      ISSUE_NUM="$2"
      shift 2
      ;;
    --repo)
      [ -n "${2:-}" ] || die "--repo requires owner/repo"
      REPO_SLUG="$2"
      shift 2
      ;;
    -*)
      die "Unknown flag: $1. Run with --help for usage."
      ;;
    *)
      if [ -n "$BUG_FILE" ]; then
        die "Unexpected argument: $1"
      fi
      BUG_FILE="$1"
      shift
      ;;
  esac
done

# --- Mutual exclusion ---
if [ -n "$BUG_FILE" ] && [ -n "$ISSUE_NUM" ]; then
  die "Cannot use both a bug file and --issue. Use one or the other."
fi

if [ -n "$REPO_SLUG" ] && [ -z "$ISSUE_NUM" ]; then
  die "--repo requires --issue"
fi

# --- Require at least one input ---
if [ -z "$BUG_FILE" ] && [ -z "$ISSUE_NUM" ]; then
  die "Provide a bug file or --issue <NUM>. Run with --help for usage."
fi

# --- Validate bug file exists ---
if [ -n "$BUG_FILE" ] && [ ! -f "$BUG_FILE" ]; then
  die "Bug file not found: $BUG_FILE"
fi

# --- Prerequisite checks ---
command -v git    >/dev/null 2>&1 || die "git is required but not found. Install git."
command -v jq     >/dev/null 2>&1 || die "jq is required but not found. Install jq."
command -v claude >/dev/null 2>&1 || die "Claude Code CLI is required but not found. Run: claude auth login"
# Resolve absolute path once here so subshells invoked by orchestrator/timeout
# never fail with "command not found" due to PATH differences.
CLAUDE_BIN="$(command -v claude)"
export CLAUDE_BIN

# rg (ripgrep) is strongly recommended — errors collector falls back to git grep without it,
# but rg is significantly faster on Windows/MSYS2.
command -v rg >/dev/null 2>&1 \
  || warn "rg (ripgrep) not found — errors collector will use git grep (slower). Install ripgrep for best performance."

if [ -n "$ISSUE_NUM" ]; then
  command -v gh >/dev/null 2>&1 || die "gh (GitHub CLI) is required for --issue. Install gh and run: gh auth login"
fi

# --- Export for orchestrator ---
export BUG_FILE ISSUE_NUM REPO_SLUG VALIDATE
export TARGET_REPO_ROOT
TARGET_REPO_ROOT="$(pwd)"

# --- Hand off to orchestrator ---
exec "${TOOL_ROOT}/scripts/orchestrator.sh"
