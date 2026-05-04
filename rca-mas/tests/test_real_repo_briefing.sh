#!/usr/bin/env bash
# tests/test_real_repo_briefing.sh — Real-repo briefing quality test.
# Runs briefing against 5 real pallets/click bugs and scores output.
# Not part of default make test — run via: make test-real-briefing
# Requires: full clone at RCA_REAL_REPO_ROOT or C:/MAS_final/test-repos/click
# No Claude calls. No agents. Briefing only.
set -Eeuo pipefail
IFS=$'\n\t'

TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TOOL_ROOT
FIXTURE_DIR="${TOOL_ROOT}/tests/real_repos/click"

# ---------------------------------------------------------------------------
# Locate clone
# ---------------------------------------------------------------------------
CLONE_DEFAULT="C:/MAS_final/test-repos/click"
REPO="${RCA_REAL_REPO_ROOT:-${CLONE_DEFAULT}}"

if [ ! -d "$REPO/.git" ]; then
  printf 'SKIP: real repo clone not found at %s\n' "$REPO" >&2
  printf 'Run: git clone https://github.com/pallets/click "%s"\n' "$REPO" >&2
  printf 'Or set: export RCA_REAL_REPO_ROOT=/path/to/click\n' >&2
  exit 0
fi

source "${TOOL_ROOT}/config/defaults.env"
source "${TOOL_ROOT}/lib/log.sh"

# ---------------------------------------------------------------------------
# Scoring helpers
# ---------------------------------------------------------------------------
TOTAL_PASS=0; TOTAL_PARTIAL=0; TOTAL_FAIL=0
_score=0; _hard_failed=0

pass_hard()    { printf '  [HARD-OK]  %s\n' "$1"; }
fail_hard()    { printf '  [HARD-FAIL] %s\n' "$1"; _hard_failed=1; }
pass_quality() { printf '  [+SIGNAL]  %s\n' "$1"; (( _score++ )) || true; }
skip_quality() { printf '  [-SIGNAL]  %s\n' "$1"; }

score_bug() {
  local bug_num="$1"
  local briefing="$2"
  local errors_txt="$3"
  local fix_files_path="${FIXTURE_DIR}/expected/bug${bug_num}_fix_files.txt"
  local expected_score
  expected_score="$(jq -r '.expected_briefing_score' \
    "${FIXTURE_DIR}/expected/bug${bug_num}_metadata.json" 2>/dev/null || echo 'PASS')"

  _score=0; _hard_failed=0

  # --- Hard checks ---
  [ -f "$briefing" ]      && pass_hard "briefing.md exists"   || fail_hard "briefing.md missing"
  [ -f "$errors_txt" ]    && pass_hard "errors.txt exists"    || fail_hard "errors.txt missing"

  if [ -f "$briefing" ]; then
    grep -q "^## Metadata"      "$briefing" && pass_hard "Metadata section present"  || fail_hard "Metadata section missing"
    grep -q "^MAX_TURNS:"       "$briefing" && pass_hard "MAX_TURNS present"         || fail_hard "MAX_TURNS missing"
    grep -q "^TEST_COMMAND:"    "$briefing" && pass_hard "TEST_COMMAND present"       || fail_hard "TEST_COMMAND missing"
    grep -q "^## Briefing Warnings" "$briefing" && pass_hard "Warnings section present" || fail_hard "Warnings section missing"

    # TEST_COMMAND must be pytest for click
    grep -q "^TEST_COMMAND: pytest" "$briefing" \
      && pass_hard "TEST_COMMAND=pytest detected" \
      || fail_hard "TEST_COMMAND is not pytest (got: $(grep '^TEST_COMMAND:' "$briefing" || echo unknown))"

    # bug.md must not appear in Error Sources
    if grep -q "^## Error Sources" "$briefing"; then
      err_section="$(awk '/^## Error Sources/,/^## [A-Z]/' "$briefing" | head -40)"
      printf '%s\n' "$err_section" | grep -qF "bug${bug_num}.md" \
        && fail_hard "bug.md appeared in Error Sources (circular evidence)" \
        || pass_hard "bug.md excluded from Error Sources"
    fi

    # --- Quality signals ---
    while IFS= read -r fix_file; do
      [ -z "$fix_file" ] && continue
      # MENTIONED_FILES signal
      grep -qF "$fix_file" "$briefing" \
        && pass_quality "Expected file '$fix_file' found in briefing" \
        || skip_quality "Expected file '$fix_file' not in briefing"
    done < "$fix_files_path"

    # Error Sources section non-empty
    err_section="$(awk '/^## Error Sources/,/^## [A-Z]/' "$briefing" | grep -v '^##' | grep -v '^$' || true)"
    [ -n "$err_section" ] \
      && pass_quality "Error Sources section has content" \
      || skip_quality "Error Sources section is empty"

    # Git History non-empty
    git_section="$(awk '/^## Git History/,/^## [A-Z]/' "$briefing" | grep -v '^##' | grep -v '^(no files\|not a git)' | grep -v '^$' || true)"
    [ -n "$git_section" ] \
      && pass_quality "Git History section has content" \
      || skip_quality "Git History section empty"

    # Test Mapping present
    grep -q "^## Test Mapping" "$briefing" \
      && pass_quality "Test Mapping section present" \
      || skip_quality "Test Mapping section missing"
  fi

  # --- Verdict ---
  if [ "$_hard_failed" -eq 1 ]; then
    printf '  RESULT: FAIL (hard check failed)\n'
    (( TOTAL_FAIL++ )) || true
  elif [ "$_score" -ge 2 ]; then
    printf '  RESULT: PASS (score=%d, expected=%s)\n' "$_score" "$expected_score"
    (( TOTAL_PASS++ )) || true
  else
    printf '  RESULT: PARTIAL (score=%d, expected=%s)\n' "$_score" "$expected_score"
    (( TOTAL_PARTIAL++ )) || true
  fi
}

# ---------------------------------------------------------------------------
# Run briefing for one bug
# ---------------------------------------------------------------------------
run_briefing_for_bug() {
  local bug_num="$1"
  local pre_fix_ref fix_sha bug_file run_dir briefing errors_txt log_file

  pre_fix_ref="$(cat "${FIXTURE_DIR}/expected/bug${bug_num}_pre_fix_ref.txt")"
  fix_sha="$(cat "${FIXTURE_DIR}/expected/bug${bug_num}_fix_sha.txt")"
  bug_file="${FIXTURE_DIR}/bugs/bug${bug_num}.md"
  run_dir="$(mktemp -d)"

  briefing="${run_dir}/briefing.md"
  errors_txt="${run_dir}/errors.txt"
  log_file="${run_dir}/log.jsonl"
  touch "$log_file"

  printf '\n=== Bug %d === (pre-fix: %s)\n' "$bug_num" "${pre_fix_ref:0:12}"

  # Checkout pre-fix state
  git -C "$REPO" checkout "$pre_fix_ref" -q 2>/dev/null || {
    printf '  ERROR: checkout failed for %s\n' "$pre_fix_ref"
    return 1
  }

  # Run briefing
  TARGET_REPO_ROOT="$REPO" \
  RUN_DIR="$run_dir" \
  BRIEFING="$briefing" \
  ERRORS_TXT="$errors_txt" \
  LOG_FILE="$log_file" \
  BUG_FILE="$bug_file" \
  BUG_INPUT_FILE="$bug_file" \
  bash "${TOOL_ROOT}/scripts/briefing.sh" 2>/dev/null || true

  # Score
  score_bug "$bug_num" "$briefing" "$errors_txt"

  # Show key metadata from briefing
  if [ -f "$briefing" ]; then
    printf '  --- Metadata ---\n'
    grep -E "^(FILE_COUNT|REPO_TIER|MAX_TURNS|MENTIONED_FILES|ERROR_COUNT|TEST_COMMAND):" \
      "$briefing" | sed 's/^/    /'
    printf '  --- errors.txt ---\n'
    if [ -s "$errors_txt" ]; then
      cat "$errors_txt" | sed 's/^/    /'
    else
      printf '    (empty)\n'
    fi
  fi

  rm -rf "$run_dir"
}

# ---------------------------------------------------------------------------
# Main — run all 5 bugs
# ---------------------------------------------------------------------------
printf 'RCA MAS — Real-Repo Briefing Test\n'
printf 'Repo:    %s\n' "$REPO"
printf 'Fixture: %s\n' "$FIXTURE_DIR"
printf 'Bugs:    5 (pallets/click)\n\n'

# Save current HEAD to restore after tests
_orig_head="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo 'UNKNOWN')"

for bug_num in 1 2 3 4 5; do
  run_briefing_for_bug "$bug_num"
done

# Restore repo to original HEAD
git -C "$REPO" checkout "$_orig_head" -q 2>/dev/null || \
  git -C "$REPO" checkout main -q 2>/dev/null || true

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n============================================================\n'
printf ' SUMMARY: %d PASS  %d PARTIAL  %d FAIL\n' \
  "$TOTAL_PASS" "$TOTAL_PARTIAL" "$TOTAL_FAIL"
printf ' Expected: Bug1=PASS Bug2=PASS Bug3=PASS/PARTIAL Bug4=PARTIAL Bug5=PARTIAL\n'
printf '============================================================\n'

# Save scorecard
SCORECARD_DIR="${REPO}/.rca-mas/real-repo-tests/latest"
mkdir -p "$SCORECARD_DIR"
cat > "${SCORECARD_DIR}/briefing_scorecard.json" <<EOF
{
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "repo": "pallets/click",
  "total_pass": ${TOTAL_PASS},
  "total_partial": ${TOTAL_PARTIAL},
  "total_fail": ${TOTAL_FAIL}
}
EOF
printf 'Scorecard: %s\n' "${SCORECARD_DIR}/briefing_scorecard.json"

# Exit non-zero only if any hard check failed
[ "$TOTAL_FAIL" -eq 0 ] || exit 1
