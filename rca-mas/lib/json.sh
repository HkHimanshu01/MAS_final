#!/usr/bin/env bash
# lib/json.sh — jq helpers used across the pipeline.
# Inputs: file paths passed as arguments.
# Outputs: extracted values or exits 1 on invalid/unexpected JSON.

# Extract the last valid JSON object from free-text output.
# Agent 1a outputs prose then a JSON block; we want that block.
# Strategy: find the last line starting with '{', read from there to EOF,
# try progressively shorter suffixes until jq accepts it.
extract_json_from_text() {
  local text_file="$1" out_file="$2"
  local last_json_line candidate

  [ -f "$text_file" ] || return 1

  last_json_line="$(grep -n '^{' "$text_file" | tail -1 | cut -d: -f1)"
  [ -n "$last_json_line" ] || return 1

  candidate="$(tail -n +"$last_json_line" "$text_file")"
  if printf '%s\n' "$candidate" | jq -e . > /dev/null 2>&1; then
    printf '%s\n' "$candidate" | jq -e . > "$out_file"
    return 0
  fi

  # Strip markdown fences and retry
  candidate="$(tail -n +"$last_json_line" "$text_file" | sed '/^```/d')"
  if printf '%s\n' "$candidate" | jq -e . > /dev/null 2>&1; then
    printf '%s\n' "$candidate" | jq -e . > "$out_file"
    return 0
  fi

  return 1
}

# extract_normalize_json — extract a JSON object from a Claude output envelope.
#
# Handles all envelope forms Claude may produce:
#   1. {"structured_output": <object>}       — preferred schema path
#   2. {"result": <object>}                  — object in .result
#   3. {"result": "<json string>"}           — double-serialised string
#   4. {"result": "```json\n{...}\n```"}     — fenced JSON string
#   5. <object> at top level (raw, no wrap)  — used in some test paths
#
# Rejects:
#   - arrays, numbers, null, plain prose strings
#   - nested stringified JSON inside extracted fields
#
# Returns: 0 and writes to out_file on success; 1 on any failure.
extract_normalize_json() {
  local raw_file="$1" out_file="$2"
  local val val_type inner

  [ -f "$raw_file" ] || return 1

  # --- Reject Claude error envelopes early ---
  # When Claude returns max_turns/error/timeout without a result, the envelope has
  # is_error=true and no .result or .structured_output. The raw object would
  # otherwise look like a valid top-level JSON object in the fallback branch below,
  # so we'd extract telemetry fields (duration_ms, session_id, etc.) as if they
  # were the structured output. Reject any Claude-wrapper-shaped object explicitly.
  if jq -e '
    (.is_error == true) or
    (.subtype == "error_max_turns") or
    (.subtype == "error" and (.type == "result")) or
    ((has("type") and .type == "result" and has("session_id") and has("duration_ms") and (has("result") | not) and (has("structured_output") | not)))
  ' "$raw_file" > /dev/null 2>&1; then
    return 1
  fi

  # --- Try .structured_output first (schema-enforced path) ---
  val="$(jq -e '.structured_output' "$raw_file" 2>/dev/null)" || true
  if [ -n "$val" ] && [ "$val" != "null" ]; then
    val_type="$(printf '%s\n' "$val" | jq -r 'type' 2>/dev/null || echo 'unknown')"
    if [ "$val_type" = "object" ]; then
      printf '%s\n' "$val" > "$out_file"
      return 0
    fi
    # structured_output may be a stringified or fenced JSON string — unwrap it
    if [ "$val_type" = "string" ]; then
      inner="$(printf '%s\n' "$val" | jq -r '.' 2>/dev/null)" || true
      inner="$(printf '%s\n' "$inner" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | sed '/^[[:space:]]*$/d')"
      if printf '%s\n' "$inner" | jq -e 'type == "object"' > /dev/null 2>&1; then
        printf '%s\n' "$inner" | jq '.' > "$out_file" 2>/dev/null && return 0
      fi
    fi
  fi

  # --- Try .result ---
  val="$(jq -e '.result' "$raw_file" 2>/dev/null)" || true
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    # --- Case 5: no envelope — raw top-level object (only if neither key exists) ---
    # If structured_output or result keys are present but null, it's a failed envelope — reject.
    if jq -e 'has("structured_output") or has("result")' "$raw_file" > /dev/null 2>&1; then
      return 1
    fi
    val_type="$(jq -r 'type' "$raw_file" 2>/dev/null || echo 'unknown')"
    if [ "$val_type" = "object" ]; then
      jq '.' "$raw_file" > "$out_file" 2>/dev/null && return 0
    fi
    return 1
  fi

  val_type="$(printf '%s\n' "$val" | jq -r 'type' 2>/dev/null || echo 'unknown')"

  # --- Case 2: .result is already an object ---
  if [ "$val_type" = "object" ]; then
    printf '%s\n' "$val" > "$out_file"
    return 0
  fi

  # --- Cases 3 & 4: .result is a string (double-serialised or fenced) ---
  if [ "$val_type" = "string" ]; then
    # jq -r strips the outer quotes, giving us raw string content
    inner="$(printf '%s\n' "$val" | jq -r '.' 2>/dev/null)" || return 1

    # Strip markdown fences if present: ```json ... ``` or ``` ... ```
    inner="$(printf '%s\n' "$inner" | sed 's/^```[a-z]*$//' | sed 's/^```$//' | sed '/^[[:space:]]*$/d')"

    # Try to parse what remains as JSON
    if printf '%s\n' "$inner" | jq -e 'type == "object"' > /dev/null 2>&1; then
      printf '%s\n' "$inner" | jq '.' > "$out_file" 2>/dev/null && return 0
    fi
  fi

  return 1
}

# Keep legacy name as alias so existing callers (tests, Agent 1a checkpoint write) still work.
extract_structured() {
  extract_normalize_json "$@"
}

# validate_diagnosis_json — check a candidate file against the diagnosis schema.
#
# Checks (in order):
#   1. file exists and is valid JSON
#   2. top-level type is object
#   3. all required schema fields are present and non-null
#   4. string fields are non-empty strings
#   5. confidence is a number in [0,1]
#   6. arrays are arrays (hypotheses, affected_files, files_examined, etc.)
#   7. no required field contains raw JSON string (stringified nested object)
#
# Usage: validate_diagnosis_json <candidate_file>
# Returns: 0 on valid, 1 on invalid (writes reason to stdout).
validate_diagnosis_json() {
  local file="$1"
  local reason=""

  # 1. exists and parses
  if [ ! -f "$file" ]; then
    printf 'file not found: %s\n' "$file"; return 1
  fi
  if ! jq -e . "$file" > /dev/null 2>&1; then
    printf 'not valid JSON\n'; return 1
  fi

  # 2. top-level object
  if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
    printf 'top-level type is not object\n'; return 1
  fi

  # 3 & 4. required string fields present and non-empty
  # Use an array to avoid IFS-dependent word splitting (caller may have IFS=$'\n\t').
  local str_fields=(run_id root_cause selected_hypothesis_id next_best_action)
  for f in "${str_fields[@]}"; do
    reason="$(jq -r --arg f "$f" '
      if has($f) | not then "missing field: \($f)"
      elif .[$f] == null then "null field: \($f)"
      elif (.[$f] | type) != "string" then "field not a string: \($f)"
      elif (.[$f] | length) == 0 then "empty string field: \($f)"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  done

  # 5. confidence is number in [0,1]
  reason="$(jq -r '
    if has("confidence") | not then "missing field: confidence"
    elif (.confidence | type) != "number" then "confidence is not a number"
    elif .confidence < 0 or .confidence > 1 then "confidence out of range [0,1]: \(.confidence)"
    else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 6. array fields
  local arr_fields=(hypotheses rejected_hypotheses affected_files call_chain files_examined unknowns)
  for f in "${arr_fields[@]}"; do
    reason="$(jq -r --arg f "$f" '
      if has($f) | not then "missing field: \($f)"
      elif (.[$f] | type) != "array" then "field not an array: \($f)"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  done

  # 7. hypotheses array has at least one entry
  reason="$(jq -r '
    if (.hypotheses | length) == 0 then "hypotheses array is empty" else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 8. no required string field looks like stringified JSON (starts with { or [)
  for f in root_cause next_best_action; do
    reason="$(jq -r --arg f "$f" '
      if (.[$f] | ltrimstr(" ") | startswith("{")) or (.[$f] | ltrimstr(" ") | startswith("["))
      then "field \($f) appears to contain stringified JSON"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  done

  # 9. selected_hypothesis_id must reference an id that exists in hypotheses[]
  reason="$(jq -r '
    .selected_hypothesis_id as $sel |
    if (.hypotheses | map(.id) | index($sel)) == null
    then "selected_hypothesis_id \"\($sel)\" not found in hypotheses[].id"
    else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  return 0
}

# validate_solution_json — check a candidate Agent 2 solution.json against the
# solution schema plus semantic rules.
#
# Schema checks (matches schemas/solution.schema.json):
#   1. file exists and is valid JSON object
#   2. required top-level fields present and correctly typed
#   3. recommendation ∈ {FIX, NO_FIX}
#   4. confidence is a number in [0,1]
#   5. weak_evidence is a boolean
#   6. fixes is an array
#
# Semantic checks (beyond JSON schema):
#   7. If recommendation == "FIX":
#       - confidence ≥ 0.50 (RCA_CONFIDENCE_NOFX threshold)
#       - fixes has ≥1 entry
#       - recommended_fix_id matches a fixes[].id
#       - no_fix_reason is null
#       - each fix has a unified_diff that contains "diff --git", "--- ", "+++ ", "@@" markers
#       - no fix's unified_diff contains markdown fences (```)
#       - each fix's risk ∈ {low, medium, high}
#   8. If recommendation == "NO_FIX":
#       - fixes is empty array
#       - recommended_fix_id is null
#       - no_fix_reason is a non-empty string
#   9. If weak_evidence == true:
#       - weak_evidence_reason is a non-empty string
#  10. If weak_evidence == false:
#       - weak_evidence_reason is null
#  11. No stringified-JSON contamination in string fields
#
# Usage: validate_solution_json <candidate_file>
# Returns: 0 on valid, 1 on invalid (writes reason to stdout).
validate_solution_json() {
  local file="$1"
  local reason=""

  # 1. exists and parses
  if [ ! -f "$file" ]; then
    printf 'file not found: %s\n' "$file"; return 1
  fi
  if ! jq -e . "$file" > /dev/null 2>&1; then
    printf 'not valid JSON\n'; return 1
  fi
  if ! jq -e 'type == "object"' "$file" > /dev/null 2>&1; then
    printf 'top-level type is not object\n'; return 1
  fi

  # 2. required string fields present and non-empty
  local str_fields=(run_id recommendation)
  for f in "${str_fields[@]}"; do
    reason="$(jq -r --arg f "$f" '
      if has($f) | not then "missing field: \($f)"
      elif .[$f] == null then "null field: \($f)"
      elif (.[$f] | type) != "string" then "field not a string: \($f)"
      elif (.[$f] | length) == 0 then "empty string field: \($f)"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  done

  # 3. recommendation enum
  reason="$(jq -r '
    if (.recommendation == "FIX" or .recommendation == "NO_FIX") then ""
    else "recommendation must be FIX or NO_FIX (got: \(.recommendation))" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 4. confidence number in [0,1]
  reason="$(jq -r '
    if has("confidence") | not then "missing field: confidence"
    elif (.confidence | type) != "number" then "confidence is not a number"
    elif .confidence < 0 or .confidence > 1 then "confidence out of range [0,1]: \(.confidence)"
    else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 5. weak_evidence boolean
  reason="$(jq -r '
    if has("weak_evidence") | not then "missing field: weak_evidence"
    elif (.weak_evidence | type) != "boolean" then "weak_evidence is not a boolean"
    else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 6. fixes array
  reason="$(jq -r '
    if has("fixes") | not then "missing field: fixes"
    elif (.fixes | type) != "array" then "fixes is not an array"
    else "" end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # Read recommendation for semantic branching
  local rec
  rec="$(jq -r '.recommendation' "$file" 2>/dev/null)"

  # 7. FIX-specific semantic rules
  if [ "$rec" = "FIX" ]; then
    reason="$(jq -r '
      .recommended_fix_id as $rid |
      if .confidence < 0.5 then "FIX with confidence < 0.5 (\(.confidence)) — must be NO_FIX"
      elif (.fixes | length) == 0 then "FIX with empty fixes array"
      elif ($rid | type) != "string" or ($rid | length) == 0 then "FIX with missing or empty recommended_fix_id"
      elif (.fixes | map(.id) | index($rid)) == null then "recommended_fix_id \"\($rid)\" not found in fixes[].id"
      elif .no_fix_reason != null then "FIX must have no_fix_reason = null (got: \(.no_fix_reason | tojson))"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

    # Check each fix's unified_diff and risk
    local fix_count
    fix_count="$(jq -r '.fixes | length' "$file" 2>/dev/null || echo 0)"
    local i
    for ((i=0; i<fix_count; i++)); do
      reason="$(jq -r --argjson i "$i" '
        .fixes[$i] as $fx |
        if ($fx.unified_diff | type) != "string" or ($fx.unified_diff | length) == 0 then "fixes[\($i)].unified_diff is empty or not a string"
        elif ($fx.unified_diff | contains("```")) then "fixes[\($i)].unified_diff contains markdown fences"
        elif ($fx.unified_diff | contains("diff --git ")) | not then "fixes[\($i)].unified_diff missing \"diff --git \" header"
        elif ($fx.unified_diff | contains("--- ")) | not then "fixes[\($i)].unified_diff missing \"--- \" header"
        elif ($fx.unified_diff | contains("+++ ")) | not then "fixes[\($i)].unified_diff missing \"+++ \" header"
        elif ($fx.unified_diff | contains("@@")) | not then "fixes[\($i)].unified_diff missing \"@@\" hunk marker"
        elif ($fx.risk == "low" or $fx.risk == "medium" or $fx.risk == "high") | not then "fixes[\($i)].risk must be low|medium|high (got: \($fx.risk))"
        elif ($fx.affected_files | type) != "array" or ($fx.affected_files | length) == 0 then "fixes[\($i)].affected_files must be a non-empty array"
        else "" end
      ' "$file" 2>/dev/null)"
      if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
    done
  fi

  # 8. NO_FIX-specific semantic rules
  if [ "$rec" = "NO_FIX" ]; then
    reason="$(jq -r '
      if (.fixes | length) != 0 then "NO_FIX with non-empty fixes array"
      elif .recommended_fix_id != null then "NO_FIX must have recommended_fix_id = null (got: \(.recommended_fix_id | tojson))"
      elif (.no_fix_reason | type) != "string" or (.no_fix_reason | length) == 0 then "NO_FIX requires non-empty no_fix_reason"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  fi

  # 9 & 10. weak_evidence_reason consistency with weak_evidence flag
  reason="$(jq -r '
    if .weak_evidence == true then
      (if (.weak_evidence_reason | type) != "string" or (.weak_evidence_reason | length) == 0
       then "weak_evidence=true requires non-empty weak_evidence_reason"
       else "" end)
    else
      (if .weak_evidence_reason != null
       then "weak_evidence=false requires weak_evidence_reason = null (got: \(.weak_evidence_reason | tojson))"
       else "" end)
    end
  ' "$file" 2>/dev/null)"
  if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi

  # 11. No stringified-JSON contamination in critical string fields
  for f in run_id no_fix_reason weak_evidence_reason; do
    reason="$(jq -r --arg f "$f" '
      if .[$f] != null and (.[$f] | type) == "string"
         and ((.[$f] | ltrimstr(" ") | startswith("{")) or (.[$f] | ltrimstr(" ") | startswith("[")))
      then "field \($f) appears to contain stringified JSON"
      else "" end
    ' "$file" 2>/dev/null)"
    if [ -n "$reason" ]; then printf '%s\n' "$reason"; return 1; fi
  done

  return 0
}

# Read one field safely; returns empty string if missing (never errors).
jq_field() {
  local file="$1" query="$2"
  jq -r "$query // empty" "$file" 2>/dev/null || true
}

# Assert file is valid JSON; calls die if not.
assert_valid_json() {
  local file="$1" label="${2:-$1}"
  jq -e . "$file" > /dev/null 2>&1 || die "Invalid JSON in $label"
}
