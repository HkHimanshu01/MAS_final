#!/usr/bin/env bash
# tests/test_json_schemas.sh — Tests that fixture JSON files are valid and invalid.json fails.
# No Claude required.
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL: %s\n' "$1"; (( FAIL++ )) || true; }

source "${TOOL_ROOT}/lib/json.sh"

# Test valid fixtures parse cleanly
for fixture in sample_diagnosis sample_solution sample_solution_nofx sample_validation sample_cost_summary; do
  f="${TOOL_ROOT}/tests/fixtures/${fixture}.json"
  jq -e . "$f" > /dev/null 2>&1 && \
    pass "${fixture}.json is valid JSON" || \
    fail "${fixture}.json failed jq parse"
done

# Test assert_valid_json passes on valid file
assert_valid_json "${TOOL_ROOT}/tests/fixtures/sample_diagnosis.json" "sample_diagnosis" && \
  pass "assert_valid_json passes on valid JSON" || \
  fail "assert_valid_json failed on valid JSON"

# Test invalid.json is caught by jq (should fail)
jq -e . "${TOOL_ROOT}/tests/fixtures/invalid.json" > /dev/null 2>&1 && \
  fail "invalid.json should fail jq parse but passed" || \
  pass "invalid.json correctly fails jq parse"

# Test assert_valid_json dies on invalid file
(assert_valid_json "${TOOL_ROOT}/tests/fixtures/invalid.json" "invalid" 2>/dev/null) && \
  fail "assert_valid_json should fail on invalid.json but passed" || \
  pass "assert_valid_json correctly fails on invalid.json"

# Test jq_field reads a field safely
val="$(jq_field "${TOOL_ROOT}/tests/fixtures/sample_diagnosis.json" '.confidence')"
[ "$val" = "0.82" ] && pass "jq_field reads confidence correctly" || fail "jq_field returned wrong value: $val"

# Test jq_field returns empty on missing field (does not crash)
val="$(jq_field "${TOOL_ROOT}/tests/fixtures/sample_diagnosis.json" '.nonexistent_field')"
[ -z "$val" ] && pass "jq_field returns empty for missing field" || fail "jq_field should return empty for missing field"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
