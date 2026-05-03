#!/usr/bin/env bash
# lib/json.sh — jq helpers used across the pipeline.
# Inputs: file paths passed as arguments.
# Outputs: extracted values or exits 1 on invalid JSON.

# Extract .structured_output from Claude wrapper; fall back to .result if null.
extract_structured() {
  local raw_file="$1" out_file="$2"
  local val
  val="$(jq -e '.structured_output' "$raw_file" 2>/dev/null)" || true
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    val="$(jq -e '.result' "$raw_file" 2>/dev/null)" || true
  fi
  if [ -z "$val" ] || [ "$val" = "null" ]; then
    return 1
  fi
  printf '%s\n' "$val" > "$out_file"
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
