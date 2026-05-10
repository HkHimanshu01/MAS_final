#!/usr/bin/env bash
# scripts/claude_json.sh — Shared Claude Code invocation helper.
# Provides run_claude_schema() (schema-enforced output) and run_claude_freetext()
# (free-text investigation, no schema) used by all agents.
# Never uses --bare or dangerous permission modes.
set -Eeuo pipefail
IFS=$'\n\t'

# Use CLAUDE_BIN if set by rca-mas.sh (absolute path, survives subshell PATH differences).
# Fall back to bare 'claude' for callers that invoke claude_json.sh directly.
_CLAUDE="${CLAUDE_BIN:-claude}"

# run_claude_freetext — invoke Claude Code without a schema for free-text investigation.
#
# Usage:
#   run_claude_freetext \
#     "$PROMPT_FILE"    # path to assembled prompt (passed via -p)
#     "$OUTPUT_FILE"    # where to write Claude's full text output (stdout+stderr)
#     "$MAX_TURNS"      # integer max turns
#     "$TOOLS"          # comma-separated tool list
#     ["$ALLOW_1" ...]  # optional --allowedTools rules
#
# Returns: 0 on success, 1 on any failure.
# Output is raw text (not JSON). The prompt must instruct Claude to write a
# checkpoint JSON file itself — that file is the investigation's durable output.
run_claude_freetext() {
  local prompt_file="$1"
  local output_file="$2"
  local max_turns="$3"
  local tools="$4"
  shift 4
  local allow_rules=("$@")

  [ -f "$prompt_file" ] || { warn "run_claude_freetext: prompt_file not found: $prompt_file"; return 1; }
  [ -n "$max_turns" ]   || { warn "run_claude_freetext: max_turns is empty"; return 1; }
  [ -n "$tools" ]       || { warn "run_claude_freetext: tools is empty"; return 1; }

  local model_flag=()
  if [ -n "${RCA_MODEL:-}" ]; then
    model_flag=(--model "${RCA_MODEL}")
  fi

  local allowed_flags=()
  for rule in "${allow_rules[@]}"; do
    allowed_flags+=(--allowedTools "$rule")
  done

  # Use stream-json and pipe directly through jq to extract assistant text turns.
  # Avoids buffering the full stream (potentially 5-50MB) in a bash variable.
  # stream-json streams every event as a JSON line; we filter for assistant text
  # content and write it to output_file as it arrives.
  # --output-format text only writes on clean end_turn; it emits an error string
  # (not the investigation) when max_turns is hit mid-tool-use, so stream-json is needed.
  local raw_file
  raw_file="${output_file}.stream"

  local exit_code=0
  "$_CLAUDE" \
    -p "$(cat "$prompt_file")" \
    --output-format stream-json \
    --verbose \
    --max-turns "$max_turns" \
    --tools "$tools" \
    "${model_flag[@]}" \
    "${allowed_flags[@]}" \
    > "$raw_file" 2>&1 || exit_code=$?

  # Extract all assistant text blocks from the saved stream and write to output_file.
  jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' \
    "$raw_file" \
    2>/dev/null \
    > "$output_file" || true

  # Write session_id and stop_reason sidecars so the caller can resume if needed.
  jq -r 'select(.type == "system") | .session_id // empty' \
    "$raw_file" 2>/dev/null | head -1 > "${output_file}.session_id" || true
  jq -r 'select(.type == "result") | .stop_reason // empty' \
    "$raw_file" 2>/dev/null | head -1 > "${output_file}.stop_reason" || true

  if [ $exit_code -ne 0 ]; then
    warn "run_claude_freetext: claude exited $exit_code (text extracted to $output_file)"
    # Non-zero exit is acceptable for max_turns — we may still have usable text
    return 1
  fi

  return 0
}

# run_claude_schema — invoke Claude Code with a schema, extract structured output.
#
# Usage:
#   run_claude_schema \
#     "$PROMPT_FILE"    # path to assembled prompt (passed via -p)
#     "$SCHEMA_FILE"    # path to JSON schema for --json-schema
#     "$RAW_FILE"       # where to write full Claude wrapper JSON
#     "$FINAL_FILE"     # where to write extracted structured_output
#     "$MAX_TURNS"      # integer max turns
#     "$TOOLS"          # comma-separated tool list e.g. "Read,Grep,Glob,Bash"
#     ["$ALLOW_1" ...]  # optional --allowedTools rules (one string per bash arg)
#                       #   e.g. 'Bash(git log *)' 'Bash(git blame *)' 'Write(.rca-mas/runs/**)'
#
# Returns: 0 on success, 1 on any failure.
# On timeout/failure the caller is responsible for checkpoint recovery.
run_claude_schema() {
  local prompt_file="$1"
  local schema_file="$2"
  local raw_file="$3"
  local final_file="$4"
  local max_turns="$5"
  local tools="$6"
  shift 6
  local allow_rules=("$@")   # zero or more allowedTools rules

  # Validate inputs
  [ -f "$prompt_file" ]  || { warn "run_claude_schema: prompt_file not found: $prompt_file"; return 1; }
  [ -f "$schema_file" ]  || { warn "run_claude_schema: schema_file not found: $schema_file"; return 1; }
  [ -n "$max_turns" ]    || { warn "run_claude_schema: max_turns is empty"; return 1; }
  [ -n "$tools" ]        || { warn "run_claude_schema: tools is empty"; return 1; }

  # Resolve model flag: use RCA_MODEL if set
  local model_flag=()
  if [ -n "${RCA_MODEL:-}" ]; then
    model_flag=(--model "${RCA_MODEL}")
  fi

  # Build allowedTools flags (one --allowedTools per rule)
  local allowed_flags=()
  for rule in "${allow_rules[@]}"; do
    allowed_flags+=(--allowedTools "$rule")
  done

  # Invoke Claude.
  # Prompt passed via -p; --output-format json gives us a JSON wrapper with structured_output.
  # --json-schema enforces the output shape.
  # --max-turns caps agentic turns.
  # --tools declares which tools the agent may see.
  # --allowedTools (per rule) restricts Bash sub-commands and write paths.
  local exit_code=0
  "$_CLAUDE" \
    -p "$(cat "$prompt_file")" \
    --output-format json \
    --json-schema "$(cat "$schema_file")" \
    --max-turns "$max_turns" \
    --tools "$tools" \
    "${model_flag[@]}" \
    "${allowed_flags[@]}" \
    > "$raw_file" 2>&1 \
    || exit_code=$?

  if [ $exit_code -ne 0 ]; then
    warn "run_claude_schema: claude exited $exit_code (raw output saved to $raw_file)"
    return 1
  fi

  # Verify raw_file is valid JSON (claude may have written partial output on interrupt)
  if ! jq -e . "$raw_file" > /dev/null 2>&1; then
    warn "run_claude_schema: raw output is not valid JSON: $raw_file"
    return 1
  fi

  # Extract structured output; fall back to .result if .structured_output is null
  if ! extract_structured "$raw_file" "$final_file"; then
    warn "run_claude_schema: could not extract structured_output or result from $raw_file"
    return 1
  fi

  # Validate extracted output is valid JSON
  if ! jq -e . "$final_file" > /dev/null 2>&1; then
    warn "run_claude_schema: extracted output is not valid JSON: $final_file"
    return 1
  fi

  return 0
}
