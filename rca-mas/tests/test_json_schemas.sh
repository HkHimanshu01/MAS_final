#!/usr/bin/env bash
# tests/test_json_schemas.sh — Schema file validity, fixture validation against schemas,
#   lib/json.sh helper correctness, and rejection of invalid inputs.
# Inputs: schemas/*.schema.json, tests/fixtures/*.json
# Outputs: PASS/FAIL lines to stdout; exits 1 if any assertion fails.
# Failure: non-zero exit if any check fails; no Claude required.
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMAS="${TOOL_ROOT}/schemas"
FIXTURES="${TOOL_ROOT}/tests/fixtures"

pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL: %s\n' "$1"; (( FAIL++ )) || true; }

source "${TOOL_ROOT}/lib/log.sh"
source "${TOOL_ROOT}/lib/json.sh"

# Validate multiple schema/instance pairs in a single Python process.
# Avoids one Python startup per call (~3-5s each on Windows).
# Usage: validate_schemas_batch "schema1:instance1" "schema2:instance2" ...
# Each pair that passes increments PASS; each failure increments FAIL.
# Detect the real Python executable (python3 is a stub on some Windows setups).
_PYTHON=""
for _py in python3 python python3.exe python.exe; do
  if command -v "$_py" > /dev/null 2>&1 \
     && "$_py" -c "import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)" 2>/dev/null; then
    _PYTHON="$_py"
    break
  fi
done

# Validate multiple schema/instance pairs in a single Python process.
# Avoids one Python startup per call (~3-5s each on Windows).
# Emits "PASS:<basename>" or "FAIL:<basename>" per pair.
validate_schemas_batch() {
  local pairs=("$@")
  local py_args=()
  for pair in "${pairs[@]}"; do
    py_args+=("${pair%%:*}" "${pair#*:}")
  done

  "$_PYTHON" - "${py_args[@]}" 2>/dev/null <<'PYEOF'
import sys, json, os
try:
    import jsonschema
except ImportError:
    print("ERROR: jsonschema not installed", file=sys.stderr)
    sys.exit(2)

args = sys.argv[1:]
i = 0
while i < len(args) - 1:
    schema_path, instance_path = args[i], args[i+1]
    i += 2
    fname = os.path.basename(instance_path)
    try:
        with open(schema_path) as f:
            schema = json.load(f)
        with open(instance_path) as f:
            instance = json.load(f)
        jsonschema.validate(instance, schema)
        print("PASS:" + fname)
    except Exception:
        print("FAIL:" + fname)
PYEOF
}

# Helper: validate one schema/instance pair; returns 0 if valid, 1 if invalid.
# Used only for the negative test (expect failure) — single call is fine there.
validate_against_schema() {
  local schema="$1" instance="$2"
  jsonschema "$schema" -i "$instance" > /dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Section 1 — Schema files are valid JSON
# ---------------------------------------------------------------------------
printf '\n--- Schema files are valid JSON ---\n'

for schema in diagnosis solution validation; do
  f="${SCHEMAS}/${schema}.schema.json"
  if [ ! -f "$f" ]; then
    fail "${schema}.schema.json missing"
  else
    jq -e . "$f" > /dev/null 2>&1 \
      && pass "${schema}.schema.json is valid JSON" \
      || fail "${schema}.schema.json failed jq parse"
  fi
done

# ---------------------------------------------------------------------------
# Section 2 — Schema files have required top-level fields
# ---------------------------------------------------------------------------
printf '\n--- Schema files have required structural fields ---\n'

for schema in diagnosis solution validation; do
  f="${SCHEMAS}/${schema}.schema.json"
  [ -f "$f" ] || continue

  jq -e '.type == "object"' "$f" > /dev/null 2>&1 \
    && pass "${schema}.schema.json: type is object" \
    || fail "${schema}.schema.json: type is not object"

  jq -e '.required | type == "array" and length > 0' "$f" > /dev/null 2>&1 \
    && pass "${schema}.schema.json: required array present and non-empty" \
    || fail "${schema}.schema.json: required array missing or empty"

  jq -e '.additionalProperties == false' "$f" > /dev/null 2>&1 \
    && pass "${schema}.schema.json: additionalProperties is false" \
    || fail "${schema}.schema.json: additionalProperties not set to false"
done

# Check diagnosis has expected required fields
for field in run_id root_cause selected_hypothesis_id hypotheses rejected_hypotheses \
             affected_files call_chain files_examined unknowns confidence \
             introducing_commit next_best_action; do
  jq -e --arg f "$field" '.required | index($f) != null' \
    "${SCHEMAS}/diagnosis.schema.json" > /dev/null 2>&1 \
    && pass "diagnosis schema requires: $field" \
    || fail "diagnosis schema missing required field: $field"
done

# Check solution has expected required fields
for field in run_id recommendation confidence no_fix_reason recommended_fix_id fixes \
             weak_evidence weak_evidence_reason; do
  jq -e --arg f "$field" '.required | index($f) != null' \
    "${SCHEMAS}/solution.schema.json" > /dev/null 2>&1 \
    && pass "solution schema requires: $field" \
    || fail "solution schema missing required field: $field"
done

# Check validation has expected required fields
for field in run_id status worktree_path applied_patch generated_test \
             test_command commands_run failures regression_risk notes; do
  jq -e --arg f "$field" '.required | index($f) != null' \
    "${SCHEMAS}/validation.schema.json" > /dev/null 2>&1 \
    && pass "validation schema requires: $field" \
    || fail "validation schema missing required field: $field"
done

# Check enums are correctly defined
jq -e '.properties.recommendation.enum == ["FIX","NO_FIX"]' \
  "${SCHEMAS}/solution.schema.json" > /dev/null 2>&1 \
  && pass "solution schema: recommendation enum is [FIX, NO_FIX]" \
  || fail "solution schema: recommendation enum incorrect"

jq -e '.properties.status.enum | length == 8' \
  "${SCHEMAS}/validation.schema.json" > /dev/null 2>&1 \
  && pass "validation schema: status enum has 8 values" \
  || fail "validation schema: status enum has wrong number of values"

jq -e '.properties.confidence.minimum == 0 and .properties.confidence.maximum == 1' \
  "${SCHEMAS}/diagnosis.schema.json" > /dev/null 2>&1 \
  && pass "diagnosis schema: confidence bounded 0-1" \
  || fail "diagnosis schema: confidence bounds missing"

# ---------------------------------------------------------------------------
# Section 3 — Fixture files are valid JSON (jq parse)
# ---------------------------------------------------------------------------
printf '\n--- Fixture files are valid JSON ---\n'

for fixture in sample_diagnosis sample_solution sample_solution_nofx \
               sample_validation sample_validation_pass sample_cost_summary; do
  f="${FIXTURES}/${fixture}.json"
  if [ ! -f "$f" ]; then
    fail "${fixture}.json missing"
  else
    jq -e . "$f" > /dev/null 2>&1 \
      && pass "${fixture}.json is valid JSON" \
      || fail "${fixture}.json failed jq parse"
  fi
done

# ---------------------------------------------------------------------------
# Section 4 — Valid fixtures pass schema validation (batched — one Python startup)
# ---------------------------------------------------------------------------
printf '\n--- Valid fixtures pass schema validation ---\n'

_batch_results="$(validate_schemas_batch \
  "${SCHEMAS}/diagnosis.schema.json:${FIXTURES}/sample_diagnosis.json" \
  "${SCHEMAS}/solution.schema.json:${FIXTURES}/sample_solution.json" \
  "${SCHEMAS}/solution.schema.json:${FIXTURES}/sample_solution_nofx.json" \
  "${SCHEMAS}/validation.schema.json:${FIXTURES}/sample_validation.json" \
  "${SCHEMAS}/validation.schema.json:${FIXTURES}/sample_validation_pass.json" \
)"

_check_batch() {
  local fixture_path="$1" label="$2"
  local fname
  fname="$(basename "$fixture_path")"
  if printf '%s\n' "$_batch_results" | grep -qF "PASS:${fname}"; then
    pass "${label} validates against schema"
  elif printf '%s\n' "$_batch_results" | grep -qF "FAIL:${fname}"; then
    fail "${label} failed schema validation"
  else
    fail "${label} — no result from batch validator"
  fi
}

_check_batch "${FIXTURES}/sample_diagnosis.json"       "sample_diagnosis.json"
_check_batch "${FIXTURES}/sample_solution.json"        "sample_solution.json (FIX)"
_check_batch "${FIXTURES}/sample_solution_nofx.json"   "sample_solution_nofx.json (NO_FIX)"
_check_batch "${FIXTURES}/sample_validation.json"      "sample_validation.json (SKIPPED)"
_check_batch "${FIXTURES}/sample_validation_pass.json" "sample_validation_pass.json (TESTS_PASSED)"

# ---------------------------------------------------------------------------
# Section 5 — Invalid fixtures fail schema validation
# ---------------------------------------------------------------------------
printf '\n--- Invalid fixtures fail schema validation ---\n'

# invalid.json — broken JSON syntax must fail jq parse
jq -e . "${FIXTURES}/invalid.json" > /dev/null 2>&1 \
  && fail "invalid.json should fail jq parse but passed" \
  || pass "invalid.json correctly fails jq parse"

# sample_diagnosis_invalid.json — missing required fields + confidence > 1
validate_against_schema "${SCHEMAS}/diagnosis.schema.json" \
  "${FIXTURES}/sample_diagnosis_invalid.json" \
  && fail "sample_diagnosis_invalid.json should fail schema validation but passed" \
  || pass "sample_diagnosis_invalid.json correctly fails diagnosis schema validation"

# ---------------------------------------------------------------------------
# Section 6 — lib/json.sh helpers
# ---------------------------------------------------------------------------
printf '\n--- lib/json.sh helper functions ---\n'

# assert_valid_json passes on valid file
assert_valid_json "${FIXTURES}/sample_diagnosis.json" "sample_diagnosis" \
  && pass "assert_valid_json passes on valid JSON" \
  || fail "assert_valid_json failed on valid JSON"

# assert_valid_json exits non-zero on invalid JSON
( assert_valid_json "${FIXTURES}/invalid.json" "invalid" 2>/dev/null ) \
  && fail "assert_valid_json should fail on invalid.json but passed" \
  || pass "assert_valid_json correctly fails on invalid.json"

# jq_field reads a known field
val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.confidence')"
[ "$val" = "0.82" ] \
  && pass "jq_field reads .confidence correctly (0.82)" \
  || fail "jq_field returned wrong value for .confidence: '$val'"

# jq_field reads nested field
val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.hypotheses[0].id')"
[ "$val" = "h1" ] \
  && pass "jq_field reads nested field .hypotheses[0].id correctly (h1)" \
  || fail "jq_field returned wrong value for .hypotheses[0].id: '$val'"

# jq_field returns empty (not an error) for missing field
val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.nonexistent_field')"
[ -z "$val" ] \
  && pass "jq_field returns empty string for missing field" \
  || fail "jq_field should return empty for missing field, got: '$val'"

# extract_structured extracts .structured_output when present
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
printf '{"structured_output": {"run_id": "x", "confidence": 0.9}}' > "$tmp_raw"
extract_structured "$tmp_raw" "$tmp_out" \
  && val="$(jq -r '.run_id' "$tmp_out")" \
  && [ "$val" = "x" ] \
  && pass "extract_structured reads .structured_output" \
  || fail "extract_structured failed to read .structured_output"
rm -f "$tmp_raw" "$tmp_out"

# extract_structured falls back to .result when .structured_output is null
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
printf '{"structured_output": null, "result": {"run_id": "y"}}' > "$tmp_raw"
extract_structured "$tmp_raw" "$tmp_out" \
  && val="$(jq -r '.run_id' "$tmp_out")" \
  && [ "$val" = "y" ] \
  && pass "extract_structured falls back to .result when structured_output is null" \
  || fail "extract_structured fallback to .result failed"
rm -f "$tmp_raw" "$tmp_out"

# extract_structured returns non-zero when both fields absent/null
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
printf '{"structured_output": null, "result": null}' > "$tmp_raw"
extract_structured "$tmp_raw" "$tmp_out" \
  && fail "extract_structured should return non-zero when both fields are null" \
  || pass "extract_structured correctly returns non-zero when both fields are null"
rm -f "$tmp_raw" "$tmp_out"

# extract_structured unwraps double-serialized .result (JSON string containing JSON object)
# This happens when Claude returns a JSON object as its text response via --output-format json.
# Use jq to build the fixture so the inner JSON is correctly escaped.
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
jq -n '{"structured_output": null, "result": "{\"run_id\": \"z\", \"confidence\": 0.8}"}' > "$tmp_raw"
extract_structured "$tmp_raw" "$tmp_out" \
  && val="$(jq -r '.run_id' "$tmp_out" 2>/dev/null)" \
  && [ "$val" = "z" ] \
  && pass "extract_normalize_json: unwraps double-serialized .result string" \
  || fail "extract_normalize_json: failed to unwrap double-serialized .result string"
rm -f "$tmp_raw" "$tmp_out"

# extract_normalize_json: fenced JSON string in .result
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
# Build a .result string that contains ```json\n{...}\n```
jq -n '{"structured_output": null, "result": "```json\n{\"run_id\": \"fenced\", \"confidence\": 0.7}\n```"}' > "$tmp_raw"
extract_normalize_json "$tmp_raw" "$tmp_out" \
  && val="$(jq -r '.run_id' "$tmp_out" 2>/dev/null)" \
  && [ "$val" = "fenced" ] \
  && pass "extract_normalize_json: unwraps fenced JSON in .result string" \
  || fail "extract_normalize_json: failed to unwrap fenced JSON in .result string"
rm -f "$tmp_raw" "$tmp_out"

# extract_normalize_json: raw top-level object (no envelope)
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
printf '{"run_id": "raw", "confidence": 0.5}' > "$tmp_raw"
extract_normalize_json "$tmp_raw" "$tmp_out" \
  && val="$(jq -r '.run_id' "$tmp_out" 2>/dev/null)" \
  && [ "$val" = "raw" ] \
  && pass "extract_normalize_json: handles raw top-level object" \
  || fail "extract_normalize_json: failed on raw top-level object"
rm -f "$tmp_raw" "$tmp_out"

# extract_normalize_json: plain prose string in .result is rejected
tmp_raw="$(mktemp)"
tmp_out="$(mktemp)"
jq -n '{"structured_output": null, "result": "this is not json at all"}' > "$tmp_raw"
extract_normalize_json "$tmp_raw" "$tmp_out" \
  && fail "extract_normalize_json: should reject plain prose .result string" \
  || pass "extract_normalize_json: correctly rejects plain prose .result string"
rm -f "$tmp_raw" "$tmp_out"

# ---------------------------------------------------------------------------
# Section 6b — validate_diagnosis_json
# ---------------------------------------------------------------------------
printf '\n--- validate_diagnosis_json ---\n'

# valid diagnosis passes
tmp_diag="$(mktemp)"
cp "${FIXTURES}/sample_diagnosis.json" "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null)"
[ -z "$err" ] \
  && pass "validate_diagnosis_json: valid sample_diagnosis passes" \
  || fail "validate_diagnosis_json: valid sample_diagnosis failed with: $err"
rm -f "$tmp_diag"

# missing required field is rejected
tmp_diag="$(mktemp)"
jq 'del(.root_cause)' "${FIXTURES}/sample_diagnosis.json" > "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_diagnosis_json: rejects missing root_cause field" \
  || fail "validate_diagnosis_json: should reject missing root_cause"
rm -f "$tmp_diag"

# confidence out of range is rejected
tmp_diag="$(mktemp)"
jq '.confidence = 1.5' "${FIXTURES}/sample_diagnosis.json" > "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_diagnosis_json: rejects confidence > 1" \
  || fail "validate_diagnosis_json: should reject confidence 1.5"
rm -f "$tmp_diag"

# hypotheses as empty array is rejected
tmp_diag="$(mktemp)"
jq '.hypotheses = []' "${FIXTURES}/sample_diagnosis.json" > "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_diagnosis_json: rejects empty hypotheses array" \
  || fail "validate_diagnosis_json: should reject empty hypotheses"
rm -f "$tmp_diag"

# root_cause that looks like stringified JSON is rejected
tmp_diag="$(mktemp)"
jq '.root_cause = "{\"foo\": 1}"' "${FIXTURES}/sample_diagnosis.json" > "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_diagnosis_json: rejects stringified-JSON root_cause" \
  || fail "validate_diagnosis_json: should reject stringified-JSON root_cause"
rm -f "$tmp_diag"

# selected_hypothesis_id references a non-existent hypothesis id
tmp_diag="$(mktemp)"
jq '.selected_hypothesis_id = "h99"' "${FIXTURES}/sample_diagnosis.json" > "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_diagnosis_json: rejects selected_hypothesis_id not in hypotheses" \
  || fail "validate_diagnosis_json: should reject selected_hypothesis_id missing from hypotheses"
rm -f "$tmp_diag"

# selected_hypothesis_id that matches a real hypothesis id passes
tmp_diag="$(mktemp)"
cp "${FIXTURES}/sample_diagnosis.json" "$tmp_diag"
err="$(validate_diagnosis_json "$tmp_diag" 2>/dev/null || true)"
[ -z "$err" ] \
  && pass "validate_diagnosis_json: accepts valid selected_hypothesis_id" \
  || fail "validate_diagnosis_json: valid selected_hypothesis_id rejected with: $err"
rm -f "$tmp_diag"

# ---------------------------------------------------------------------------
# Section 6c — validate_solution_json (Agent 2)
# ---------------------------------------------------------------------------
printf '\n--- validate_solution_json ---\n'

# Baseline: valid FIX fixture passes
tmp_sol="$(mktemp)"
cp "${FIXTURES}/sample_solution.json" "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -z "$err" ] \
  && pass "validate_solution_json: valid FIX sample passes" \
  || fail "validate_solution_json: valid FIX sample rejected with: $err"
rm -f "$tmp_sol"

# Baseline: valid NO_FIX fixture passes
tmp_sol="$(mktemp)"
cp "${FIXTURES}/sample_solution_nofx.json" "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -z "$err" ] \
  && pass "validate_solution_json: valid NO_FIX sample passes" \
  || fail "validate_solution_json: valid NO_FIX sample rejected with: $err"
rm -f "$tmp_sol"

# FIX with confidence < 0.5 must be rejected
tmp_sol="$(mktemp)"
jq '.confidence = 0.3' "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects FIX with confidence < 0.5" \
  || fail "validate_solution_json: should reject FIX with low confidence"
rm -f "$tmp_sol"

# FIX with empty fixes array must be rejected
tmp_sol="$(mktemp)"
jq '.fixes = []' "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects FIX with empty fixes" \
  || fail "validate_solution_json: should reject FIX with no fixes"
rm -f "$tmp_sol"

# FIX with recommended_fix_id not in fixes[].id
tmp_sol="$(mktemp)"
jq '.recommended_fix_id = "fix99"' "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects recommended_fix_id not in fixes[].id" \
  || fail "validate_solution_json: should reject mismatched recommended_fix_id"
rm -f "$tmp_sol"

# FIX with unified_diff missing diff --git header
tmp_sol="$(mktemp)"
jq '.fixes[0].unified_diff = "--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-old\n+new"' \
  "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects unified_diff missing diff --git header" \
  || fail "validate_solution_json: should reject diff without diff --git header"
rm -f "$tmp_sol"

# FIX with markdown-fenced diff
tmp_sol="$(mktemp)"
jq '.fixes[0].unified_diff = "```diff\ndiff --git a/foo.py b/foo.py\n--- a/foo.py\n+++ b/foo.py\n@@ -1 +1 @@\n-old\n+new\n```"' \
  "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects markdown-fenced unified_diff" \
  || fail "validate_solution_json: should reject fenced diff"
rm -f "$tmp_sol"

# NO_FIX with non-empty fixes array
tmp_sol="$(mktemp)"
jq '.recommendation = "NO_FIX" | .no_fix_reason = "test"' \
  "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects NO_FIX with non-empty fixes" \
  || fail "validate_solution_json: should reject NO_FIX with fixes"
rm -f "$tmp_sol"

# NO_FIX with empty no_fix_reason
tmp_sol="$(mktemp)"
jq '.no_fix_reason = ""' "${FIXTURES}/sample_solution_nofx.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects NO_FIX with empty no_fix_reason" \
  || fail "validate_solution_json: should reject NO_FIX without reason"
rm -f "$tmp_sol"

# weak_evidence=true with null weak_evidence_reason
tmp_sol="$(mktemp)"
jq '.weak_evidence = true | .weak_evidence_reason = null' \
  "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects weak_evidence=true with null reason" \
  || fail "validate_solution_json: should reject weak_evidence=true without reason"
rm -f "$tmp_sol"

# weak_evidence=false with non-null weak_evidence_reason
tmp_sol="$(mktemp)"
jq '.weak_evidence = false | .weak_evidence_reason = "leftover from prior run"' \
  "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects weak_evidence=false with non-null reason" \
  || fail "validate_solution_json: should reject weak_evidence=false with reason"
rm -f "$tmp_sol"

# confidence out of range
tmp_sol="$(mktemp)"
jq '.confidence = 1.5' "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects confidence > 1" \
  || fail "validate_solution_json: should reject confidence 1.5"
rm -f "$tmp_sol"

# bad recommendation enum
tmp_sol="$(mktemp)"
jq '.recommendation = "MAYBE"' "${FIXTURES}/sample_solution.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects unknown recommendation value" \
  || fail "validate_solution_json: should reject recommendation=MAYBE"
rm -f "$tmp_sol"

# stringified JSON in no_fix_reason
tmp_sol="$(mktemp)"
jq '.no_fix_reason = "{\"nested\":\"json\"}"' "${FIXTURES}/sample_solution_nofx.json" > "$tmp_sol"
err="$(validate_solution_json "$tmp_sol" 2>/dev/null || true)"
[ -n "$err" ] \
  && pass "validate_solution_json: rejects stringified JSON in no_fix_reason" \
  || fail "validate_solution_json: should reject stringified JSON contamination"
rm -f "$tmp_sol"

# ---------------------------------------------------------------------------
# Section 6d — CLAUDE_BIN propagation
# ---------------------------------------------------------------------------
printf '\n--- CLAUDE_BIN propagation ---\n'

# When CLAUDE_BIN is unset, scripts fall back to bare 'claude' — test that they
# do not hard-error during sourcing (the fallback is syntactically correct).
(
  unset CLAUDE_BIN 2>/dev/null || true
  source "${TOOL_ROOT}/scripts/claude_json.sh" 2>/dev/null
  [ "${_CLAUDE}" = "claude" ]
) \
  && pass "CLAUDE_BIN: unset falls back to bare 'claude' in claude_json.sh" \
  || fail "CLAUDE_BIN: fallback to bare 'claude' broken in claude_json.sh"

# When CLAUDE_BIN is set to a known path, _CLAUDE picks it up.
(
  export CLAUDE_BIN="/fake/path/to/claude"
  source "${TOOL_ROOT}/scripts/claude_json.sh" 2>/dev/null
  [ "${_CLAUDE}" = "/fake/path/to/claude" ]
) \
  && pass "CLAUDE_BIN: set value propagates to _CLAUDE in claude_json.sh" \
  || fail "CLAUDE_BIN: set value not picked up by claude_json.sh"

# No bare runtime 'claude' calls remain (resolver/docs/tests excepted)
_bare_calls="$(grep -rn \
  --include='*.sh' \
  -E '(^|[[:space:]])claude[[:space:]]' \
  "${TOOL_ROOT}/scripts/" "${TOOL_ROOT}/lib/" \
  | grep -v 'CLAUDE_BIN\|_CLAUDE\|#\|\.sh:.*claude_json\|run_claude\|command -v claude\|echo.*claude\|warn.*claude\|printf.*claude' \
  | grep -v 'test_\|tests/' \
  || true)"
[ -z "$_bare_calls" ] \
  && pass "CLAUDE_BIN: no bare runtime 'claude' calls in scripts/ or lib/" \
  || fail "CLAUDE_BIN: bare runtime 'claude' calls found:
$_bare_calls"

# ---------------------------------------------------------------------------
# Section 7 — Key fixture field values (regression guard)
# ---------------------------------------------------------------------------
printf '\n--- Fixture field value regression checks ---\n'

# diagnosis
val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.selected_hypothesis_id')"
[ "$val" = "h1" ] \
  && pass "sample_diagnosis: selected_hypothesis_id is h1" \
  || fail "sample_diagnosis: selected_hypothesis_id unexpected: '$val'"

val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.hypotheses | length')"
[ "$val" = "2" ] \
  && pass "sample_diagnosis: hypotheses array has 2 items" \
  || fail "sample_diagnosis: hypotheses count unexpected: '$val'"

val="$(jq_field "${FIXTURES}/sample_diagnosis.json" '.affected_files[0]')"
[ "$val" = "src/cart/pricing.py" ] \
  && pass "sample_diagnosis: affected_files[0] is src/cart/pricing.py" \
  || fail "sample_diagnosis: affected_files[0] unexpected: '$val'"

# solution FIX
val="$(jq_field "${FIXTURES}/sample_solution.json" '.recommendation')"
[ "$val" = "FIX" ] \
  && pass "sample_solution: recommendation is FIX" \
  || fail "sample_solution: recommendation unexpected: '$val'"

val="$(jq_field "${FIXTURES}/sample_solution.json" '.fixes[0].risk')"
[ "$val" = "low" ] \
  && pass "sample_solution: fixes[0].risk is low" \
  || fail "sample_solution: fixes[0].risk unexpected: '$val'"

# solution NO_FIX
val="$(jq_field "${FIXTURES}/sample_solution_nofx.json" '.recommendation')"
[ "$val" = "NO_FIX" ] \
  && pass "sample_solution_nofx: recommendation is NO_FIX" \
  || fail "sample_solution_nofx: recommendation unexpected: '$val'"

val="$(jq_field "${FIXTURES}/sample_solution_nofx.json" '.fixes | length')"
[ "$val" = "0" ] \
  && pass "sample_solution_nofx: fixes array is empty" \
  || fail "sample_solution_nofx: fixes array should be empty, got: '$val'"

val="$(jq_field "${FIXTURES}/sample_solution_nofx.json" '.no_fix_reason')"
[ -n "$val" ] \
  && pass "sample_solution_nofx: no_fix_reason is set" \
  || fail "sample_solution_nofx: no_fix_reason should be non-empty"

# validation SKIPPED
val="$(jq_field "${FIXTURES}/sample_validation.json" '.status')"
[ "$val" = "SKIPPED" ] \
  && pass "sample_validation: status is SKIPPED" \
  || fail "sample_validation: status unexpected: '$val'"

val="$(jq -r '.applied_patch' "${FIXTURES}/sample_validation.json")"
[ "$val" = "false" ] \
  && pass "sample_validation: applied_patch is false" \
  || fail "sample_validation: applied_patch unexpected: '$val'"

# validation TESTS_PASSED
val="$(jq_field "${FIXTURES}/sample_validation_pass.json" '.status')"
[ "$val" = "TESTS_PASSED" ] \
  && pass "sample_validation_pass: status is TESTS_PASSED" \
  || fail "sample_validation_pass: status unexpected: '$val'"

val="$(jq_field "${FIXTURES}/sample_validation_pass.json" '.applied_patch')"
[ "$val" = "true" ] \
  && pass "sample_validation_pass: applied_patch is true" \
  || fail "sample_validation_pass: applied_patch unexpected: '$val'"

# ---------------------------------------------------------------------------
printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
