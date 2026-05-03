#!/usr/bin/env bash
# scripts/briefing.sh — Pure bash repo scan. Zero LLM calls.
# Inputs: BUG_FILE, TARGET_REPO_ROOT, RUN_DIR, TOOL_ROOT, RCA_* config vars.
# Outputs: BRIEFING (briefing.md), ERRORS_TXT (errors.txt).
# Failure: logs warnings for each failed collector, never crashes pipeline.
set -Eeuo pipefail
IFS=$'\n\t'

source "${TOOL_ROOT}/config/defaults.env"
source "${TOOL_ROOT}/lib/log.sh"

info "Briefing: scanning repo..."

# ---------------------------------------------------------------------------
# 1. Extract quoted error strings from bug report → errors.txt
# ---------------------------------------------------------------------------
# Match double-quoted strings of 5–200 chars (preserves spaces and punctuation)
: > "$ERRORS_TXT"
if [ -s "${BUG_FILE:-}" ]; then
  grep -oE '"[^"]{5,200}"' "$BUG_FILE" 2>/dev/null \
    | sed 's/^"//; s/"$//' \
    | sort -u \
    >> "$ERRORS_TXT" || true
fi
ERROR_COUNT=0
if [ -s "$ERRORS_TXT" ]; then
  ERROR_COUNT="$(wc -l < "$ERRORS_TXT" | tr -d ' ')"
fi

# ---------------------------------------------------------------------------
# 2. Extract and validate file paths from bug report
# ---------------------------------------------------------------------------
# Match paths: optional leading word chars, then path segments with slashes
MENTIONED_FILES=""
if [ -s "${BUG_FILE:-}" ]; then
  raw_paths="$(grep -oE '[a-zA-Z0-9_.-][a-zA-Z0-9_./-]*\.[a-zA-Z]{1,10}(:[0-9]+(:[0-9]+)?)?' \
    "$BUG_FILE" 2>/dev/null | sort -u || true)"

  # Determine if we are inside a git repo (single subprocess, cached for reuse)
  _is_git=0
  _tracked=""
  if git -C "$TARGET_REPO_ROOT" rev-parse --git-dir > /dev/null 2>&1; then
    _is_git=1
    _tracked="$(git -C "$TARGET_REPO_ROOT" ls-files 2>/dev/null || true)"
  fi

  while IFS= read -r p; do
    [ -z "$p" ] && continue
    # Strip optional :line:col suffix for validation
    clean="${p%%:*}"
    # Reject absolute paths
    [[ "$clean" == /* ]] && continue
    # Reject path traversal
    [[ "$clean" == *..* ]] && continue
    # Reject secret files
    case "$clean" in
      *.env|*.pem|*.key|*id_rsa*|*.secret|*.token|*.passwd|*.password) continue ;;
    esac
    # Accept only known source extensions
    ext="${clean##*.}"
    case "$ext" in
      py|js|ts|tsx|jsx|go|java|rb|php|rs|cs|kt|swift|vue|svelte|html|css|scss|sql|json|yml|yaml|toml|sh|md) ;;
      *) continue ;;
    esac
    # Validation:
    # - In a git repo: accept only tracked files (git ls-files is authoritative).
    #   Untracked files are rejected even if they exist on disk.
    # - Not a git repo: accept if the file exists on the filesystem.
    if [ "$_is_git" -eq 1 ]; then
      printf '%s\n' "$_tracked" | grep -qxF "$clean" \
        && MENTIONED_FILES="${MENTIONED_FILES} ${clean}" || true
    elif [ -f "${TARGET_REPO_ROOT}/${clean}" ]; then
      MENTIONED_FILES="${MENTIONED_FILES} ${clean}"
    fi
  done <<< "$raw_paths"
fi
MENTIONED_FILES="${MENTIONED_FILES# }"  # trim leading space

# ---------------------------------------------------------------------------
# 3. File count + tier selection (values from config, not hardcoded)
# ---------------------------------------------------------------------------
FILE_COUNT=0
# Reuse _tracked + _is_git already set above (avoids a second git subprocess)
if [ "${_is_git:-0}" -eq 1 ]; then
  FILE_COUNT="$(printf '%s\n' "$_tracked" | grep -c . 2>/dev/null || true)"
  FILE_COUNT="${FILE_COUNT:-0}"
fi
if [ "$FILE_COUNT" -eq 0 ]; then
  # Fallback: find, excluding generated dirs
  FILE_COUNT="$(find "$TARGET_REPO_ROOT" -type f \
    \( -path '*/.git/*' \
    -o -path '*/.rca-mas/*' \
    -o -path '*/node_modules/*' \
    -o -path '*/.venv/*' \
    -o -path '*/venv/*' \
    -o -path '*/dist/*' \
    -o -path '*/build/*' \
    -o -path '*/coverage/*' \
    -o -path '*/.next/*' \
    -o -path '*/.turbo/*' \
    \) -prune -o -type f -print 2>/dev/null \
    | wc -l | tr -d ' ')" || FILE_COUNT=0
fi

if   [ "$FILE_COUNT" -lt "${RCA_TIER_XS}" ]; then
  REPO_TIER="XS"; MAX_TURNS="${RCA_TURNS_XS}"; TIMEOUT="${RCA_TIMEOUT_XS}"
elif [ "$FILE_COUNT" -lt "${RCA_TIER_S}" ]; then
  REPO_TIER="S";  MAX_TURNS="${RCA_TURNS_S}";  TIMEOUT="${RCA_TIMEOUT_S}"
elif [ "$FILE_COUNT" -lt "${RCA_TIER_M}" ]; then
  REPO_TIER="M";  MAX_TURNS="${RCA_TURNS_M}";  TIMEOUT="${RCA_TIMEOUT_M}"
else
  REPO_TIER="L";  MAX_TURNS="${RCA_TURNS_L}";  TIMEOUT="${RCA_TIMEOUT_L}"
fi

# Export for orchestrator to pick up after briefing
export MAX_TURNS TIMEOUT REPO_TIER

# ---------------------------------------------------------------------------
# 4. Write briefing.md header
# ---------------------------------------------------------------------------
{
  printf '# Briefing\n\n'
  printf '## Metadata\n'
  printf 'MAX_TURNS: %s\n'       "$MAX_TURNS"
  printf 'TIMEOUT: %s\n'         "$TIMEOUT"
  printf 'FILE_COUNT: %s\n'      "$FILE_COUNT"
  printf 'REPO_TIER: %s\n'       "$REPO_TIER"
  printf 'MENTIONED_FILES: %s\n' "${MENTIONED_FILES:-(none)}"
  printf 'ERROR_COUNT: %s\n\n'   "$ERROR_COUNT"
} > "$BRIEFING"

# Placeholder TEST_COMMAND — testrunner collector will overwrite this section
printf 'TEST_COMMAND: UNKNOWN\n\n' >> "$BRIEFING"

# ---------------------------------------------------------------------------
# 5. Run each collector with timeout; continue on failure
# ---------------------------------------------------------------------------
BRIEFING_WARNINGS=""

run_collector() {
  local name="$1" script="${TOOL_ROOT}/collectors/${1}.sh"
  local t_start t_end duration
  t_start="$(date +%s)"

  local output
  if output="$(
    export TARGET_REPO_ROOT TOOL_ROOT MENTIONED_FILES ERRORS_TXT \
           RCA_GIT_LOOKBACK RCA_ERROR_GREP_LIMIT RCA_COLLECTOR_TIMEOUT \
           BUG_SOURCE_FILE BUG_INPUT_FILE
    timeout "${RCA_COLLECTOR_TIMEOUT}" bash "$script" 2>&1
  )"; then
    t_end="$(date +%s)"
    duration=$(( t_end - t_start ))
    # Deduplicate within this collector's output only, then append
    printf '%s\n' "$output" \
      | awk '!seen[$0]++' \
      >> "$BRIEFING"
    unset seen
    log_event "info" "briefing" "collector ok" "collector=${name}" "duration_seconds=${duration}"
  else
    local ec=$?
    t_end="$(date +%s)"
    duration=$(( t_end - t_start ))
    local reason="exit ${ec}"
    [ $ec -eq 124 ] && reason="timeout after ${RCA_COLLECTOR_TIMEOUT}s"
    warn "Collector ${name} failed: ${reason}"
    BRIEFING_WARNINGS="${BRIEFING_WARNINGS}\n- collector ${name}: ${reason}"
    log_event "warn" "briefing" "collector failed" "collector=${name}" "reason=${reason}"
    printf '## %s\n(collector failed: %s)\n\n' "$name" "$reason" >> "$BRIEFING"
  fi
}

export TEST_CMD_FILE="${RUN_DIR}/test_command.txt"
printf 'UNKNOWN\n' > "$TEST_CMD_FILE"

# Export the ORIGINAL bug file path (before orchestrator copied it to RUN_DIR)
# so errors.sh can exclude it from search results.
# BUG_INPUT_FILE is set by orchestrator; fall back to BUG_FILE if not set.
export BUG_SOURCE_FILE
_src="${BUG_INPUT_FILE:-${BUG_FILE}}"
if command -v readlink > /dev/null 2>&1; then
  BUG_SOURCE_FILE="$(readlink -f "${_src}" 2>/dev/null || printf '%s' "${_src}")"
else
  BUG_SOURCE_FILE="${_src}"
fi

run_collector "git"
run_collector "deps"
run_collector "errors"
run_collector "testrunner"

# Backfill TEST_COMMAND in header from what testrunner detected.
# Use awk with a variable — safe for commands containing /, &, spaces, dots.
DETECTED_TEST_CMD="$(cat "$TEST_CMD_FILE" 2>/dev/null || printf 'UNKNOWN')"
_tmp_brief="$(mktemp)"
awk -v cmd="$DETECTED_TEST_CMD" \
  '/^TEST_COMMAND: UNKNOWN$/ { print "TEST_COMMAND: " cmd; next } { print }' \
  "$BRIEFING" > "$_tmp_brief" && mv "$_tmp_brief" "$BRIEFING"

# ---------------------------------------------------------------------------
# 6. Append warnings section
# ---------------------------------------------------------------------------
{
  printf '\n## Briefing Warnings\n'
  if [ -n "$BRIEFING_WARNINGS" ]; then
    printf '%b\n' "$BRIEFING_WARNINGS"
  else
    printf '(none)\n'
  fi
} >> "$BRIEFING"

log_event "info" "briefing" "briefing complete" \
  "file_count=${FILE_COUNT}" "tier=${REPO_TIER}" \
  "mentioned_files=${MENTIONED_FILES:-none}" "error_count=${ERROR_COUNT}"

info "Briefing: ${FILE_COUNT} files, tier=${REPO_TIER}, turns=${MAX_TURNS}, errors=${ERROR_COUNT}"
