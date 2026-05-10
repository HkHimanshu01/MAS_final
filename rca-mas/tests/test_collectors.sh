#!/usr/bin/env bash
# tests/test_collectors.sh — Tests for real collector behavior.
# No Claude required. Uses a tiny controlled temp repo — NOT the MAS source tree.
# Each collector is tested against known, deterministic input so results are stable
# regardless of how many commits the MAS repo has.
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL: %s\n' "$1"; (( FAIL++ )) || true; }

_TEST_BASE="${HOME}/.rca-mas-test-collectors-$$"
mkdir -p "$_TEST_BASE"
TMPDIR_RUN="${_TEST_BASE}/run"
mkdir -p "$TMPDIR_RUN"
trap 'rm -rf "$_TEST_BASE"' EXIT

source "${TOOL_ROOT}/config/defaults.env"

# ---------------------------------------------------------------------------
# Build a tiny controlled target repo — collectors run against THIS, not $TOOL_ROOT
# ---------------------------------------------------------------------------
TINY_REPO="${_TEST_BASE}/repo"
mkdir -p "${TINY_REPO}/src" "${TINY_REPO}/tests"

git config --global --add safe.directory "$TINY_REPO" 2>/dev/null || true
git init -q "$TINY_REPO"
git -C "$TINY_REPO" config user.email "test@test.com"
git -C "$TINY_REPO" config user.name "Test"

cat > "${TINY_REPO}/src/main.py" <<'PYEOF'
import os
import sys
from pathlib import Path

def process(item):
    return item
PYEOF

cat > "${TINY_REPO}/tests/test_main.py" <<'PYEOF'
def test_process():
    pass
PYEOF

printf '[pytest]\n' > "${TINY_REPO}/pytest.ini"

git -C "$TINY_REPO" add src/main.py tests/test_main.py pytest.ini
git -C "$TINY_REPO" commit -q -m "init"

# Known error string that exists in src/main.py
MATCH_STR="UniqueMatchableSearchString"
printf '# %s\n' "$MATCH_STR" >> "${TINY_REPO}/src/main.py"
git -C "$TINY_REPO" add src/main.py
git -C "$TINY_REPO" commit -q -m "add marker string"

export TARGET_REPO_ROOT="$TINY_REPO"
export TOOL_ROOT
export ERRORS_TXT="${TMPDIR_RUN}/errors.txt"
export TEST_CMD_FILE="${TMPDIR_RUN}/test_command.txt"
export MENTIONED_FILES="src/main.py"
export BUG_SOURCE_FILE=""

orig_target="$TARGET_REPO_ROOT"

# ---------------------------------------------------------------------------
# Basic: each collector exits 0 and produces output with correct header
# ---------------------------------------------------------------------------
for col in git deps errors testrunner; do
  out="$(bash "${TOOL_ROOT}/collectors/${col}.sh" 2>/dev/null)" \
    && pass "collectors/${col}.sh exits 0" \
    || fail "collectors/${col}.sh crashed"
  [ -n "$out" ] \
    && pass "collectors/${col}.sh produces output" \
    || fail "collectors/${col}.sh produced no output"
done

for col_header in "git.sh:## Git History" "deps.sh:## Dependencies" \
                  "errors.sh:## Error Sources" "testrunner.sh:## Test Mapping"; do
  col="${col_header%%:*}"; hdr="${col_header#*:}"
  out="$(bash "${TOOL_ROOT}/collectors/${col}" 2>/dev/null || true)"
  printf '%s\n' "$out" | grep -q "^${hdr}" \
    && pass "${col} has ${hdr} header" \
    || fail "${col} missing ${hdr} header"
done

# ---------------------------------------------------------------------------
# errors.sh — empty errors.txt → graceful message
# ---------------------------------------------------------------------------
: > "$ERRORS_TXT"
out="$(bash "${TOOL_ROOT}/collectors/errors.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -q "no quoted strings" \
  && pass "errors.sh handles empty errors.txt gracefully" \
  || fail "errors.sh did not handle empty errors.txt gracefully"

# ---------------------------------------------------------------------------
# errors.sh — multi-word string preserved intact
# ---------------------------------------------------------------------------
printf 'TypeError: Cannot read properties of undefined (reading discount_value)\n' \
  > "$ERRORS_TXT"
out="$(bash "${TOOL_ROOT}/collectors/errors.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -qF "TypeError: Cannot read properties" \
  && pass "errors.sh preserves full multi-word string in output" \
  || fail "errors.sh did not preserve full multi-word string"

# ---------------------------------------------------------------------------
# errors.sh — output is bounded
# ---------------------------------------------------------------------------
printf 'src\n' > "$ERRORS_TXT"
out="$(bash "${TOOL_ROOT}/collectors/errors.sh" 2>/dev/null || true)"
lc="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
max=$(( RCA_ERROR_GREP_LIMIT + 10 ))
[ "$lc" -le "$max" ] \
  && pass "errors.sh output bounded (${lc} lines <= ${max})" \
  || fail "errors.sh output unbounded (${lc} lines > ${max})"

# ---------------------------------------------------------------------------
# errors.sh — string found only in bug report → "no matches outside bug report"
# ---------------------------------------------------------------------------
BUG_ONLY_STR="xXThisStringExistsOnlyInBugReportXx"
printf '%s\n' "$BUG_ONLY_STR" > "${TMPDIR_RUN}/errors_nomatch.txt"
BUG_ABS="${TMPDIR_RUN}/bug_nomatch.md"
printf 'Bug report mentions "%s"\n' "$BUG_ONLY_STR" > "$BUG_ABS"

export ERRORS_TXT="${TMPDIR_RUN}/errors_nomatch.txt"
export BUG_SOURCE_FILE="$BUG_ABS"

out="$(bash "${TOOL_ROOT}/collectors/errors.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -q "no matches outside bug report" \
  && pass "errors.sh reports 'no matches outside bug report' when string found only in bug" \
  || fail "errors.sh did not report 'no matches outside bug report'"

export ERRORS_TXT="${TMPDIR_RUN}/errors.txt"
export BUG_SOURCE_FILE=""

# ---------------------------------------------------------------------------
# errors.sh — bug.md excluded from results when BUG_SOURCE_FILE is set
# ---------------------------------------------------------------------------
BUG2="${TMPDIR_RUN}/bug2.md"
printf 'Bug: "%s" observed\n' "$MATCH_STR" > "$BUG2"
printf '%s\n' "$MATCH_STR" > "${TMPDIR_RUN}/errors2.txt"

export ERRORS_TXT="${TMPDIR_RUN}/errors2.txt"
export BUG_SOURCE_FILE="$BUG2"

out="$(bash "${TOOL_ROOT}/collectors/errors.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -qF "src/main.py" \
  && pass "errors.sh finds match in source file" \
  || fail "errors.sh did not find match in source file"
printf '%s\n' "$out" | grep -qF "bug2.md" \
  && fail "errors.sh should exclude bug.md but it appeared in output" \
  || pass "errors.sh correctly excludes bug.md from results"

export ERRORS_TXT="${TMPDIR_RUN}/errors.txt"
export BUG_SOURCE_FILE=""

# ---------------------------------------------------------------------------
# testrunner.sh — UNKNOWN for empty repo
# ---------------------------------------------------------------------------
TMPDIR_NOPROJ="${_TEST_BASE}/noproj"
mkdir -p "$TMPDIR_NOPROJ"
export TARGET_REPO_ROOT="$TMPDIR_NOPROJ"
out="$(bash "${TOOL_ROOT}/collectors/testrunner.sh" 2>/dev/null || true)"
export TARGET_REPO_ROOT="$orig_target"
printf '%s\n' "$out" | grep -q "TEST_COMMAND: UNKNOWN" \
  && pass "testrunner.sh reports UNKNOWN for empty repo" \
  || fail "testrunner.sh should report UNKNOWN for empty repo"

# ---------------------------------------------------------------------------
# testrunner.sh — detects pytest from pytest.ini
# ---------------------------------------------------------------------------
TMPDIR_PY="${_TEST_BASE}/pyrepo"
mkdir -p "$TMPDIR_PY" && touch "${TMPDIR_PY}/pytest.ini"
export TARGET_REPO_ROOT="$TMPDIR_PY"
out="$(bash "${TOOL_ROOT}/collectors/testrunner.sh" 2>/dev/null || true)"
export TARGET_REPO_ROOT="$orig_target"
printf '%s\n' "$out" | grep -q "TEST_COMMAND: pytest" \
  && pass "testrunner.sh detects pytest from pytest.ini" \
  || fail "testrunner.sh did not detect pytest"

# ---------------------------------------------------------------------------
# testrunner.sh — detects go test ./... from go.mod
# ---------------------------------------------------------------------------
TMPDIR_GO="${_TEST_BASE}/gorepo"
mkdir -p "$TMPDIR_GO"
printf 'module example.com/mymod\ngo 1.21\n' > "${TMPDIR_GO}/go.mod"
export TARGET_REPO_ROOT="$TMPDIR_GO"
out="$(bash "${TOOL_ROOT}/collectors/testrunner.sh" 2>/dev/null || true)"
export TARGET_REPO_ROOT="$orig_target"
printf '%s\n' "$out" | grep -qF "TEST_COMMAND: go test ./..." \
  && pass "testrunner.sh detects 'go test ./...' from go.mod" \
  || fail "testrunner.sh did not detect go test"

# ---------------------------------------------------------------------------
# testrunner.sh — go test ./... written safely to TEST_CMD_FILE
# ---------------------------------------------------------------------------
TMPDIR_GO2="${_TEST_BASE}/gorepo2"
mkdir -p "$TMPDIR_GO2"
printf 'module example.com/mymod\ngo 1.21\n' > "${TMPDIR_GO2}/go.mod"
TC_FILE="${TMPDIR_RUN}/tc_go.txt"
export TARGET_REPO_ROOT="$TMPDIR_GO2"
export TEST_CMD_FILE="$TC_FILE"
bash "${TOOL_ROOT}/collectors/testrunner.sh" > /dev/null 2>&1 || true
export TARGET_REPO_ROOT="$orig_target"
export TEST_CMD_FILE="${TMPDIR_RUN}/test_command.txt"

tc_val="$(cat "$TC_FILE" 2>/dev/null || true)"
[ "$tc_val" = "go test ./..." ] \
  && pass "TEST_CMD_FILE correctly contains 'go test ./...'" \
  || fail "TEST_CMD_FILE has unexpected value: '${tc_val}'"

# ---------------------------------------------------------------------------
# deps.sh — empty MENTIONED_FILES → graceful
# ---------------------------------------------------------------------------
export MENTIONED_FILES=""
out="$(bash "${TOOL_ROOT}/collectors/deps.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -q "no files mentioned" \
  && pass "deps.sh handles empty MENTIONED_FILES gracefully" \
  || fail "deps.sh did not handle empty MENTIONED_FILES gracefully"

# ---------------------------------------------------------------------------
# git.sh — runs gracefully with no MENTIONED_FILES
# ---------------------------------------------------------------------------
out="$(bash "${TOOL_ROOT}/collectors/git.sh" 2>/dev/null || true)"
printf '%s\n' "$out" | grep -q "no files mentioned\|Recent merges" \
  && pass "git.sh runs gracefully with no MENTIONED_FILES" \
  || fail "git.sh failed with no MENTIONED_FILES"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
