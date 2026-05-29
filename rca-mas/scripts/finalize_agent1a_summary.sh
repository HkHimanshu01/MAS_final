#!/usr/bin/env bash
# scripts/finalize_agent1a_summary.sh — Force a no-tool finalization turn from Agent 1a.
#
# Resumes the Agent 1a session (if session_id known) and requests a structured
# FINAL FINDINGS summary with no tools available. Runs for every Agent 1a run
# to standardize output regardless of stop_reason.
#
# Usage:
#   finalize_agent1a_summary.sh <run_dir> <tool_root>
#
# Inputs (read from run_dir):
#   agent1a_meta.env           — session_id, stop_reason, exit_code
#   agent1a_output.txt         — existing assistant text (appended to)
#
# Outputs (written to run_dir):
#   agent1a_forced_summary.json   — raw json output from finalization claude call
#   agent1a_forced_summary.stderr — stderr from finalization claude call
#   agent1a_findings.md           — canonical FINAL FINDINGS (written/overwritten when valid)
#   agent1a_output.txt            — appended with finalization result
#   agent1a_quality.env           — updated: agent1a_finalization=ok|failed|skipped
#
# Returns: always 0 — pipeline must continue regardless of finalization outcome.
set -Eeuo pipefail
IFS=$'\n\t'

_RUN_DIR="${1:-}"
_TOOL_ROOT="${2:-}"

if [ -z "$_RUN_DIR" ] || [ -z "$_TOOL_ROOT" ]; then
  printf 'finalize_agent1a_summary.sh: missing arguments\n' >&2
  exit 1
fi

_META_ENV="${_RUN_DIR}/agent1a_meta.env"
_OUTPUT_TXT="${_RUN_DIR}/agent1a_output.txt"
_FINDINGS_MD="${_RUN_DIR}/agent1a_findings.md"
_SUMMARY_JSON="${_RUN_DIR}/agent1a_forced_summary.json"
_SUMMARY_STDERR="${_RUN_DIR}/agent1a_forced_summary.stderr"
_QUALITY_ENV="${_RUN_DIR}/agent1a_quality.env"
_FORCE_SUMMARY_PROMPT="${_TOOL_ROOT}/prompts/agent1a_force_summary.md"

_FINALIZATION_STATUS="skipped"

# Read metadata
_SESSION_ID=""
_STOP_REASON=""
if [ -f "$_META_ENV" ]; then
  # shellcheck disable=SC1090
  _SESSION_ID="$(grep '^session_id=' "$_META_ENV" 2>/dev/null | cut -d= -f2- | head -1 || true)"
  _STOP_REASON="$(grep '^stop_reason=' "$_META_ENV" 2>/dev/null | cut -d= -f2- | head -1 || true)"
fi

# If no session_id, skip resume — quality gate and recovery handle the rest
if [ -z "$_SESSION_ID" ]; then
  printf 'finalize_agent1a_summary.sh: no session_id in agent1a_meta.env — skipping resume finalization (recovery will run)\n' >&2
  _FINALIZATION_STATUS="skipped"
else
  # Load model flag
  _MODEL_FLAG=()
  if [ -n "${RCA_MODEL:-}" ]; then
    _MODEL_FLAG=(--model "${RCA_MODEL}")
  fi

  # Ensure prompt file exists
  if [ ! -f "$_FORCE_SUMMARY_PROMPT" ]; then
    printf 'finalize_agent1a_summary.sh: force summary prompt not found: %s\n' "$_FORCE_SUMMARY_PROMPT" >&2
    _FINALIZATION_STATUS="failed"
  else
    # Run no-tool finalization via --resume
    _FINALIZE_EXIT=0
    "${CLAUDE_BIN:-claude}" \
      --resume "$_SESSION_ID" \
      -p \
      --output-format json \
      --max-turns 1 \
      --tools "" \
      "${_MODEL_FLAG[@]}" \
      < "$_FORCE_SUMMARY_PROMPT" \
      > "$_SUMMARY_JSON" \
      2> "$_SUMMARY_STDERR" \
      || _FINALIZE_EXIT=$?

    if [ "$_FINALIZE_EXIT" -ne 0 ] || [ ! -s "$_SUMMARY_JSON" ]; then
      printf 'finalize_agent1a_summary.sh: finalization call failed (exit=%s)\n' "$_FINALIZE_EXIT" >&2
      # Surface the stderr so it appears in agent1a.log for diagnosis
      if [ -s "$_SUMMARY_STDERR" ]; then
        printf 'finalize_agent1a_summary.sh: claude stderr follows:\n' >&2
        cat "$_SUMMARY_STDERR" >&2
      fi
      printf '## FORCED FINALIZATION FAILED\nExit code: %s\n' "$_FINALIZE_EXIT" >> "$_OUTPUT_TXT" || true
      _FINALIZATION_STATUS="failed"
    else
      # Extract text from json output (claude --output-format json result field)
      _FINAL_TEXT="$(jq -r '.result // .text // empty' "$_SUMMARY_JSON" 2>/dev/null || true)"

      if [ -n "$_FINAL_TEXT" ]; then
        # Check if it has FINAL FINDINGS section
        if printf '%s' "$_FINAL_TEXT" | grep -q 'FINAL FINDINGS'; then
          # Write canonical findings file
          printf '%s\n' "$_FINAL_TEXT" > "$_FINDINGS_MD"
          # Append to output txt with clear delimiter
          {
            printf '\n\n---\n\n## FORCED FINAL FINDINGS SUMMARY\n\n'
            printf '%s\n' "$_FINAL_TEXT"
          } >> "$_OUTPUT_TXT"
          _FINALIZATION_STATUS="ok"
        else
          # Has text but no FINAL FINDINGS section — append anyway and mark weak
          {
            printf '\n\n---\n\n## FORCED FINALIZATION OUTPUT (no FINAL FINDINGS section)\n\n'
            printf '%s\n' "$_FINAL_TEXT"
          } >> "$_OUTPUT_TXT"
          # Still write findings if we got something
          printf '%s\n' "$_FINAL_TEXT" > "$_FINDINGS_MD"
          _FINALIZATION_STATUS="ok"
        fi
      else
        printf '## FORCED FINALIZATION PRODUCED NO TEXT\n' >> "$_OUTPUT_TXT" || true
        _FINALIZATION_STATUS="failed"
      fi
    fi
  fi
fi

# Update quality env — preserve existing fields, update finalization field
_EXISTING_QUALITY=""
_EXISTING_RECOVERY=""
if [ -f "$_QUALITY_ENV" ]; then
  _EXISTING_QUALITY="$(grep '^agent1a_quality=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
  _EXISTING_RECOVERY="$(grep '^agent1a_recovery=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
fi
{
  printf '%s\n' "${_EXISTING_QUALITY:-agent1a_quality=pending}"
  printf 'agent1a_finalization=%s\n' "$_FINALIZATION_STATUS"
  printf '%s\n' "${_EXISTING_RECOVERY:-agent1a_recovery=skipped}"
} > "$_QUALITY_ENV"

exit 0
