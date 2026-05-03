#!/usr/bin/env bash
# collectors/deps.sh — Best-effort import tracing for mentioned files (Python, JS/TS, Go).
# Inputs: MENTIONED_FILES (space-sep), TARGET_REPO_ROOT.
# Outputs: Markdown section to stdout.
# Failure: exits 0.
set -Eeuo pipefail
IFS=$'\n\t'

printf '## Dependencies\n\n'

if [ -z "${MENTIONED_FILES:-}" ]; then
  printf '(no files mentioned in bug report)\n\n'
  exit 0
fi

for f in $MENTIONED_FILES; do
  fullpath="${TARGET_REPO_ROOT}/${f}"
  [ -f "$fullpath" ] || continue

  ext="${f##*.}"
  printf '### Imports in: %s\n' "$f"

  case "$ext" in
    py)
      grep -nE '^\s*(import |from [a-zA-Z_][a-zA-Z0-9_.]*\s+import)' \
        "$fullpath" 2>/dev/null | head -30 || true
      ;;
    js|ts|jsx|tsx|vue|svelte)
      grep -nE '^\s*(import |require\()' \
        "$fullpath" 2>/dev/null | head -30 || true
      ;;
    go)
      # Extract Go import block
      awk '/^import \(/{p=1} p{print NR": "$0} /^\)/{p=0}' \
        "$fullpath" 2>/dev/null | head -30 || true
      # Single-line imports
      grep -nE '^import "' "$fullpath" 2>/dev/null | head -10 || true
      ;;
    *)
      printf '(unsupported language for import tracing: .%s)\n' "$ext"
      ;;
  esac
  printf '\n'
done
