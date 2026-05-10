#!/usr/bin/env bash
# scripts/check_agent1a_quality.sh — Quality gate for Agent 1a findings.
#
# Evaluates agent1a_findings.md and marks quality ok or weak.
# Never fails the pipeline — only writes agent1a_quality.env.
#
# Usage:
#   check_agent1a_quality.sh <run_dir>
#
# Outputs:
#   agent1a_quality.env  — agent1a_quality=ok|weak (and preserves existing fields)
#
# Quality is marked WEAK if any of:
#   - agent1a_findings.md missing or empty
#   - no FINAL FINDINGS section
#   - fewer than 800 bytes
#   - no Root cause / Recommended fix / Confidence section
#   - no path:line, file path (src/, lib/, pkg/ etc.), function name, or class name
#   - only narration ("let me inspect", "I'll check", "now I will", "let me look")
#
# Returns: always 0.
set -Eeuo pipefail
IFS=$'\n\t'

_RUN_DIR="${1:-}"

if [ -z "$_RUN_DIR" ]; then
  printf 'check_agent1a_quality.sh: missing run_dir argument\n' >&2
  exit 1
fi

_FINDINGS_MD="${_RUN_DIR}/agent1a_findings.md"
_QUALITY_ENV="${_RUN_DIR}/agent1a_quality.env"

_QUALITY="ok"
_REASONS=()

# Check 1: file missing or empty
if [ ! -s "$_FINDINGS_MD" ]; then
  _QUALITY="weak"
  _REASONS+=("findings file missing or empty")
else
  _CONTENT="$(cat "$_FINDINGS_MD")"
  _SIZE="$(wc -c < "$_FINDINGS_MD" | tr -d '[:space:]')"

  # Check 2: no FINAL FINDINGS section
  if ! printf '%s' "$_CONTENT" | grep -qi 'FINAL FINDINGS'; then
    _QUALITY="weak"
    _REASONS+=("no FINAL FINDINGS section")
  fi

  # Check 3: fewer than 800 bytes
  if [ "${_SIZE:-0}" -lt 800 ]; then
    _QUALITY="weak"
    _REASONS+=("findings too short (${_SIZE} bytes < 800)")
  fi

  # Check 4: missing required sections
  if ! printf '%s' "$_CONTENT" | grep -qi 'Root cause'; then
    _QUALITY="weak"
    _REASONS+=("missing Root cause section")
  fi
  if ! printf '%s' "$_CONTENT" | grep -qi 'Recommended fix'; then
    _QUALITY="weak"
    _REASONS+=("missing Recommended fix section")
  fi
  if ! printf '%s' "$_CONTENT" | grep -qi 'Confidence'; then
    _QUALITY="weak"
    _REASONS+=("missing Confidence section")
  fi

  # Check 5: no concrete code references
  # Looks for: path:line, src/foo.py, lib/bar.go, function(), ClassName, or similar
  if ! printf '%s' "$_CONTENT" | grep -qE \
      '([a-zA-Z0-9_/.-]+\.[a-z]{1,6}:[0-9]+|[a-zA-Z0-9_/-]+\.(py|go|ts|js|rb|java|c|h|cpp|rs|sh)|\bdef \w+|\bfunc \w+|\bclass \w+|\bfunction \w+)'; then
    _QUALITY="weak"
    _REASONS+=("no file:line, file path, function, or class references found")
  fi

  # Check 6: only narration — all non-empty lines start with hedging phrases
  _NARRATION_ONLY=true
  while IFS= read -r _line; do
    # Skip blank lines and markdown headers
    [ -z "$_line" ] && continue
    [[ "$_line" =~ ^[#\-\*\>] ]] && continue
    # If any non-empty, non-header line doesn't match narration patterns, it's substantive
    if ! printf '%s' "$_line" | grep -qiE \
        '^(let me |i.ll |now i |i will |i.m going to |looking at |checking |reading |examining |i need to |i should |i can see|i have read)'; then
      _NARRATION_ONLY=false
      break
    fi
  done < "$_FINDINGS_MD"
  if [ "$_NARRATION_ONLY" = "true" ]; then
    _QUALITY="weak"
    _REASONS+=("all content is narration with no concrete findings")
  fi
fi

# Preserve existing finalization and recovery fields
_EXISTING_FINALIZATION=""
_EXISTING_RECOVERY=""
if [ -f "$_QUALITY_ENV" ]; then
  _EXISTING_FINALIZATION="$(grep '^agent1a_finalization=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
  _EXISTING_RECOVERY="$(grep '^agent1a_recovery=' "$_QUALITY_ENV" 2>/dev/null | head -1 || true)"
fi

{
  printf 'agent1a_quality=%s\n' "$_QUALITY"
  printf '%s\n' "${_EXISTING_FINALIZATION:-agent1a_finalization=skipped}"
  printf '%s\n' "${_EXISTING_RECOVERY:-agent1a_recovery=skipped}"
  if [ "${#_REASONS[@]}" -gt 0 ]; then
    printf 'agent1a_quality_reasons=%s\n' "$(IFS=';'; printf '%s' "${_REASONS[*]}")"
  fi
} > "$_QUALITY_ENV"

exit 0
