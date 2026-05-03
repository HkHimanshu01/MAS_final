#!/usr/bin/env bash
# collectors/git.sh — Recent git history and blame for files mentioned in bug report.
# Inputs: MENTIONED_FILES (space-sep), RCA_GIT_LOOKBACK, TARGET_REPO_ROOT.
# Outputs: Markdown section to stdout.
# Failure: exits 0 — briefing.sh wraps with timeout and continues on failure.
set -Eeuo pipefail
IFS=$'\n\t'

printf '## Git History\n\n'

# Apply defaults for vars that may not be exported to subprocess
: "${RCA_GIT_LOOKBACK:=14 days ago}"

# Require git repo
if ! git -C "$TARGET_REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
  printf '(not a git repository)\n\n'
  exit 0
fi

# Recent merges to default branch (last 10)
printf '### Recent merges\n'
git -C "$TARGET_REPO_ROOT" log --merges \
  --since="${RCA_GIT_LOOKBACK}" \
  --pretty=format:'%h %ad %s' \
  --date=short \
  -n 10 2>/dev/null || true
printf '\n\n'

# Per-file history for mentioned files
if [ -n "${MENTIONED_FILES:-}" ]; then
  for f in $MENTIONED_FILES; do
    printf '### Log: %s\n' "$f"
    git -C "$TARGET_REPO_ROOT" log \
      --since="${RCA_GIT_LOOKBACK}" \
      --pretty=format:'%h %ad %an: %s' \
      --date=short \
      -n 10 -- "$f" 2>/dev/null || true
    printf '\n'

    # Blame: first 30 lines only — signal, not full file
    if git -C "$TARGET_REPO_ROOT" ls-files --error-unmatch "$f" \
         > /dev/null 2>&1; then
      printf '### Blame (first 30 lines): %s\n' "$f"
      git -C "$TARGET_REPO_ROOT" blame -L 1,30 --date=short "$f" \
        2>/dev/null | head -30 || true
      printf '\n'
    fi
  done
else
  printf '(no files mentioned in bug report)\n\n'
fi
