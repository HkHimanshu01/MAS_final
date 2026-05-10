#!/usr/bin/env bash
# lib/json.sh — jq helpers used across the pipeline.
# Inputs: file paths passed as arguments.
# Outputs: extracted values or exits 1 on invalid JSON.

# Extract the last valid JSON object from free-text output.
# Agent 1a outputs prose then a JSON block; we want that block.
# Strategy: find the last line starting with '{', read from there to EOF,
# try progressively shorter suffixes until jq accepts it.
extract_json_from_text() {
  local text_file="$1" out_file="$2"
  local text line_count last_json_line candidate

  [ -f "$text_file" ] || return 1

  # Find the last line that starts with '{' (the JSON object start)
  last_json_line="$(grep -n '^{' "$text_file" | tail -1 | cut -d: -f1)"
  [ -n "$last_json_line" ] || return 1

  # Extract from that line to EOF and try to parse as JSON
  candidate="$(tail -n +"$last_json_line" "$text_file")"
  if printf '%s\n' "$candidate" | jq -e . > /dev/null 2>&1; then
    printf '%s\n' "$candidate" | jq -e . > "$out_file"
    return 0
  fi

  # If multi-line JSON is wrapped in markdown fences, strip them and retry
  candidate="$(tail -n +"$last_json_line" "$text_file" \
    | sed '/^```/d')"
  if printf '%s\n' "$candidate" | jq -e . > /dev/null 2>&1; then
    printf '%s\n' "$candidate" | jq -e . > "$out_file"
    return 0
  fi

  return 1
}

# Extract .structured_output from Claude wrapper; fall back to .result if null.
# .structured_output is always a JSON object — write as-is.
# .result may be a JSON-encoded string (double-serialized) when the model emits
# a JSON object as its text response. Detect this and unwrap with jq -r before saving.
extract_structured() {
  local raw_file="$1" out_file="$2"
  local val val_type

  val="$(jq -e '.structured_output' "$raw_file" 2>/dev/null)" || true
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="$(jq -e '.result' "$raw_file" 2>/dev/null)" || true
  fi
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    return 1
  fi

  # If the extracted value is a JSON string (double-serialized), unwrap it.
  val_type="$(printf '%s\n' "$val" | jq -r 'type' 2>/dev/null || echo 'unknown')"
  if [ "$val_type" = "string" ]; then
    printf '%s\n' "$val" | jq -r '.' > "$out_file"
  else
    printf '%s\n' "$val" > "$out_file"
  fi
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
