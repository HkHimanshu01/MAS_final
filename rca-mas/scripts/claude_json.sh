#!/usr/bin/env bash
# scripts/claude_json.sh — Shared Claude Code invocation helper.
# Inputs: prompt_file, schema_file, raw_file, final_file, max_turns, tools, [allow_rules...]
# Outputs: raw_file (Claude wrapper JSON), final_file (structured_output extracted).
# Failure: exits 1 on Claude error or invalid JSON extraction.
set -Eeuo pipefail
IFS=$'\n\t'

# Stub — full implementation in Step 6
run_claude_schema() {
  die "run_claude_schema not yet implemented (Step 6)"
}
