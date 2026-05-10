#!/usr/bin/env bash
# collectors/errors.sh — Fixed-string search for each quoted string across the target repo.
# Quoted strings from the bug report may be error messages, UI text, codes, or values —
# they are search anchors, not necessarily exceptions.
# Inputs: ERRORS_TXT (one string per line), RCA_ERROR_GREP_LIMIT, TARGET_REPO_ROOT,
#         BUG_SOURCE_FILE (absolute path — excluded from results to avoid self-reference).
# Outputs: Markdown section to stdout.
# Failure: exits 0. Every no-match search uses || true.
set -Eeuo pipefail
IFS=$'\n\t'

printf '## Error Sources\n\n'

: "${RCA_ERROR_GREP_LIMIT:=50}"
LIMIT="${RCA_ERROR_GREP_LIMIT}"

if [ ! -s "${ERRORS_TXT:-}" ]; then
  printf '(no quoted strings extracted from bug report)\n\n'
  exit 0
fi

# Resolve bug source file to an absolute path for exclusion comparison.
# BUG_SOURCE_FILE may be unset if called directly without briefing.sh context.
_bug_abs="${BUG_SOURCE_FILE:-}"

while IFS= read -r str; do
  [ -z "$str" ] && continue
  printf '### Search: %s\n' "$str"

  # Run fixed-string search; exclude generated dirs and the bug file itself.
  # rg path: use --glob exclusions + post-filter bug file line.
  # grep path: use --exclude-dir + post-filter bug file line.
  if command -v rg > /dev/null 2>&1; then
    raw="$(rg -nF --max-count="${LIMIT}" \
      --glob '!.git' \
      --glob '!.rca-mas' \
      --glob '!node_modules' \
      --glob '!.venv' \
      --glob '!venv' \
      --glob '!dist' \
      --glob '!build' \
      --glob '!coverage' \
      -- "$str" "$TARGET_REPO_ROOT" \
      2>/dev/null | head -"${LIMIT}" || true)"
  else
    raw="$(grep -RFn \
      --exclude-dir='.git' \
      --exclude-dir='.rca-mas' \
      --exclude-dir='node_modules' \
      --exclude-dir='.venv' \
      --exclude-dir='venv' \
      --exclude-dir='dist' \
      --exclude-dir='build' \
      --exclude-dir='coverage' \
      -- "$str" "$TARGET_REPO_ROOT" \
      2>/dev/null | head -"${LIMIT}" || true)"
  fi

  # Filter out the bug report file itself — it always contains the strings
  # and adds no diagnostic value.
  # Path format note: rg on Windows outputs C:/path\to\file or C:\path\to\file;
  # BUG_SOURCE_FILE uses /c/path/to/file (POSIX). We match by the last two path
  # components (parent dir + filename) using grep -F on both slash styles.
  if [ -n "$_bug_abs" ] && [ -n "$raw" ]; then
    _bug_basename="$(basename "$_bug_abs")"
    _bug_dir="$(basename "$(dirname "$_bug_abs")")"
    # Build match patterns for both forward-slash and backslash path separators
    # (rg on Windows may output either form)
    _pat1="${_bug_dir}/${_bug_basename}"
    _pat2="$(printf '%s\\%s' "$_bug_dir" "$_bug_basename")"
    filtered="$(printf '%s\n' "$raw" \
      | grep -vF -e "$_pat1" -e "$_pat2" \
      || true)"
  else
    filtered="$raw"
  fi

  if [ -n "$filtered" ]; then
    # Exclude changelog/doc files — they add noise, not diagnostic signal.
    filtered="$(printf '%s\n' "$filtered" \
      | grep -vE '\.(rst|md|txt|changelog|CHANGES|NEWS|HISTORY)' \
      || true)"
  fi

  if [ -n "$filtered" ]; then
    # Prioritise: src/ hits first, then tests, then everything else (mutually exclusive).
    _src="$(printf '%s\n'  "$filtered" | grep -E '[/\\]src[/\\]'              || true)"
    _tst="$(printf '%s\n'  "$filtered" | grep -vE '[/\\]src[/\\]' | grep -E '[/\\]test' || true)"
    _rest="$(printf '%s\n' "$filtered" | grep -vE '[/\\]src[/\\]|[/\\]test'  || true)"
    # Concatenate in priority order, drop empty sections.
    _ordered="$(printf '%s\n' "$_src" "$_tst" "$_rest" | grep -v '^$' || true)"
    printf '%s\n' "$_ordered"
  else
    printf '(no matches outside bug report)\n'
  fi

  # If the search term looks like a method call (x.method or obj.method), also
  # emit definition hits from src/ so Agent 1 sees the implementation, not just callers.
  # Use a fixed path instead of mktemp to avoid one extra subprocess on Windows.
  if printf '%s' "$str" | grep -qE '^\w+\.\w+$' && [ -d "${TARGET_REPO_ROOT}/src" ]; then
    _method="$(printf '%s' "$str" | sed 's/.*\.//')"
    _def_out=""
    if command -v rg > /dev/null 2>&1; then
      _def_out="$(rg -nF --glob '!.git' --glob '!.rca-mas' \
        -- "def ${_method}" "${TARGET_REPO_ROOT}/src" \
        2>/dev/null | head -10 || true)"
    else
      _def_out="$(grep -RFn --exclude-dir='.git' --exclude-dir='.rca-mas' \
        -- "def ${_method}" "${TARGET_REPO_ROOT}/src" \
        2>/dev/null | head -10 || true)"
    fi
    if [ -n "$_def_out" ]; then
      printf '### Definition: def %s (in src/)\n' "$_method"
      printf '%s\n' "$_def_out"
      printf '\n'
    fi
  fi

  printf '\n'
done < "$ERRORS_TXT"
