#!/usr/bin/env bash
# scripts/recover_agent1a_findings.sh — Fallback: synthesise Agent 1a findings from evidence.
#
# Called when forced finalization failed, session_id was missing, or quality gate
# marked findings as weak. Uses a no-tools Claude call (no --resume) over the
# captured evidence transcript to produce agent1a_findings.md.
#
# Usage:
#   recover_agent1a_findings.sh <run_dir> <tool_root>
#
# Inputs (from run_dir):
#   bug.md                  — original bug report (via RUN_DIR/bug.md)
#   briefing.md             — repo briefing
#   agent1a_output.txt      — assistant text from investigation
#   agent1a_evidence.txt    — full tool calls + tool results transcript
#
# Outputs (written to run_dir):
#   agent1a_recovery_summary.json   — raw json from recovery claude call
#   agent1a_recovery_summary.stderr — stderr from recovery claude call
#   agent1a_findings.md             — written/overwritten when recovery succeeds
#   agent1a_quality.env             — updated: agent1a_recovery=ok|failed
#
# Returns: always 0 — pipeline must continue.
set -Eeuo pipefail
IFS=$'\n\t'

_RUN_DIR="${1:-}"
_TOOL_ROOT="${2:-}"

if [ -z "$_RUN_DIR" ] || [ -z "$_TOOL_ROOT" ]; then
  printf 'recover_agent1a_findings.sh: missing arguments\n' >&2
  exit 1
fi

_BUG_MD="${_RUN_DIR}/bug.md"
_BRIEFING_MD="${_RUN_DIR}/briefing.md"
_OUTPUT_TXT="${_RUN_DIR}/agent1a_output.txt"
_EVIDENCE_TXT="${_RUN_DIR}/agent1a_evidence.txt"
_FINDINGS_MD="${_RUN_DIR}/agent1a_findings.md"
_RECOVERY_JSON="${_RUN_DIR}/agent1a_recovery_summary.json"
_RECOVERY_STDERR="${_RUN_DIR}/agent1a_recovery_summary.stderr"
_QUALITY_ENV="${_RUN_DIR}/agent1a_quality.env"
_RECOVER_PROMPT="${_TOOL_ROOT}/prompts/agent1a_recover_from_evidence.md"

_RECOVERY_STATUS="failed"

if [ ! -f "$_RECOVER_PROMPT" ]; then
  printf 'recover_agent1a_findings.sh: recovery prompt not found: %s\n' "$_RECOVER_PROMPT" >&2
else
  # Assemble recovery prompt with full context
  _ASSEMBLED_PROMPT="$(
    cat "$_RECOVER_PROMPT"
    printf '\n\n---\n\n## Bug Report\n\n'
    cat "$_BUG_MD" 2>/dev/null || printf '(bug.md not found)\n'
    printf '\n\n---\n\n## Briefing (excerpt)\n\n'
    # Include only first 3000 chars of briefing to stay within token budget
    head -c 3000 "$_BRIEFING_MD" 2>/dev/null || printf '(briefing.md not found)\n'
    printf '\n\n---\n\n## Agent 1a Assistant Text\n\n'
    cat "$_OUTPUT_TXT" 2>/dev/null || printf '(agent1a_output.txt not found)\n'
    printf '\n\n---\n\n## Agent 1a Evidence Transcript\n\n'
    # Include up to 12000 chars of evidence — prefer tail (most recent tool results)
    _EV_SIZE="$(wc -c < "$_EVIDENCE_TXT" 2>/dev/null || printf '0')"
    if [ "${_EV_SIZE:-0}" -gt 12000 ]; then
      printf '... [evidence truncated — showing last 12000 bytes]\n\n'
      tail -c 12000 "$_EVIDENCE_TXT" 2>/dev/null || true
    else
      cat "$_EVIDENCE_TXT" 2>/dev/null || printf '(agent1a_evidence.txt not found)\n'
    fi
  )"

  # Load model flag
  _MODEL_FLAG=()
  if [ -n "${RCA_MODEL:-}" ]; then
    _MODEL_FLAG=(--model "${RCA_MODEL}")
  fi

  _RECOVER_EXIT=0
  claude \
    -p "$_ASSEMBLED_PROMPT" \
    --output-format json \
    --max-turns 1 \
    --tools "" \
    "${_MODEL_FLAG[@]}" \
    > "$_RECOVERY_JSON" \
    2> "$_RECOVERY_STDERR" \
    || _RECOVER_EXIT=$?

  if [ "$_RECOVER_EXIT" -ne 0 ] || [ ! -s "$_RECOVERY_JSON" ]; then
    printf 'recover_agent1a_findings.sh: recovery call failed (exit=%s)\n' "$_RECOVER_EXIT" >&2
    _RECOVERY_STATUS="failed"
  else
    _RECOVERY_TEXT="$(jq -r '.result // .text // empty' "$_RECOVERY_JSON" 2>/dev/null || true)"
    if [ -n "$_RECOVERY_TEXT" ]; then
      printf '%s\n' "$_RECOVERY_TEXT" > "$_FINDINGS_MD"
      _RECOVERY_STATUS="ok"
    else
      _RECOVERY_STATUS="failed"
    fi
  fi
fi

# If all recovery paths failed, write a minimal findings file with weak notice
if [ "$_RECOVERY_STATUS" = "failed" ] || [ ! -s "$_FINDINGS_MD" ]; then
  {
    printf '## FINAL FINDINGS\n\n'
    printf '> **WARNING: Agent 1a recovery failed. Findings below are synthesised from partial evidence only.**\n\n'
    printf '### Root cause\n'
    printf 'Could not determine root cause. See agent1a_evidence.txt for raw tool results.\n\n'
    printf '### Affected files\n'
    printf '- Unknown — see evidence transcript\n\n'
    printf '### Key evidence\n'
    printf '- See agent1a_evidence.txt for captured tool results\n\n'
    printf '### Alternative considered\n'
    printf '- N/A — insufficient evidence for analysis\n\n'
    printf '### Recommended fix\n'
    printf '- Manual investigation required\n\n'
    printf '### Confidence\n'
    printf '0.00\n'
  } > "$_FINDINGS_MD"
  _RECOVERY_STATUS="failed"
fi

# Update quality env — preserve existing fields, update recovery field
_EXISTING_QUALITY=""
_EXISTING_FINALIZATION=""
if [ -f "$_QUALITY_ENV" ]; then
  _EXISTING_QUALITY="$(grep '^agent1a_quality=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
  _EXISTING_FINALIZATION="$(grep '^agent1a_finalization=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
fi
{
  printf '%s\n' "${_EXISTING_QUALITY:-agent1a_quality=pending}"
  printf '%s\n' "${_EXISTING_FINALIZATION:-agent1a_finalization=skipped}"
  printf 'agent1a_recovery=%s\n' "$_RECOVERY_STATUS"
} > "$_QUALITY_ENV"

exit 0
