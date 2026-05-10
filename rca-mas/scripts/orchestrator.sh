#!/usr/bin/env bash
# scripts/orchestrator.sh — Pipeline controller. Owns run lifecycle start to finish.
# Inputs: BUG_FILE, ISSUE_NUM, REPO_SLUG, VALIDATE, TARGET_REPO_ROOT, TOOL_ROOT (exported by rca-mas.sh).
# Outputs: RUN_DIR with all artifacts; prints report path on completion.
# Failure: always attempts to write report even if stages degrade.
set -Eeuo pipefail
IFS=$'\n\t'

# --- Source libs ---
# shellcheck source=../lib/log.sh
source "${TOOL_ROOT}/lib/log.sh"
# shellcheck source=../lib/json.sh
source "${TOOL_ROOT}/lib/json.sh"
# shellcheck source=../lib/paths.sh
source "${TOOL_ROOT}/lib/paths.sh"
# shellcheck source=../lib/cleanup.sh
source "${TOOL_ROOT}/lib/cleanup.sh"

# --- Source config (already sourced by rca-mas.sh but re-source for safety) ---
source "${TOOL_ROOT}/config/defaults.env"

# --- Source Claude helper (defines run_claude_schema) ---
# shellcheck source=./claude_json.sh
source "${TOOL_ROOT}/scripts/claude_json.sh"

# --- Determine mode ---
MODE="report-only"
[ "${VALIDATE:-0}" = "1" ] && MODE="validate"

# --- Generate run ID and init run dir ---
RUN_ID="$(make_run_id)"
init_run_dir "$RUN_ID"
update_latest_symlink

# --- Register cleanup trap ---
trap 'run_cleanup' EXIT

# --- Start logging ---
log_event "info" "orchestrator" "run started" "run_id=${RUN_ID}" "mode=${MODE}"
info "Run ${RUN_ID} starting (${MODE})"

# --- Collect tool versions ---
CLAUDE_VER="$(claude --version 2>/dev/null || echo 'unknown')"
GIT_VER="$(git --version 2>/dev/null | awk '{print $3}' || echo 'unknown')"
JQ_VER="$(jq --version 2>/dev/null || echo 'unknown')"
GH_VER="$(gh --version 2>/dev/null | head -1 | awk '{print $3}' || echo 'not-installed')"

# --- Write manifest.json ---
cat > "$MANIFEST" <<EOF
{
  "run_id": "${RUN_ID}",
  "mode": "${MODE}",
  "tool_root": "${TOOL_ROOT}",
  "target_repo_root": "${TARGET_REPO_ROOT}",
  "repo_remote_url": "$(git -C "${TARGET_REPO_ROOT}" remote get-url origin 2>/dev/null || echo 'unknown')",
  "git_head_sha": "$(git -C "${TARGET_REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo 'unknown')",
  "git_branch": "$(git -C "${TARGET_REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'unknown')",
  "bug_source": "${ISSUE_NUM:+github_issue}${BUG_FILE:+file}",
  "bug_source_file": "${BUG_FILE:-}",
  "issue_url": null,
  "expected_fix_commit": "${EXPECTED_FIX_SHA:-}",
  "started_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "ended_at": null,
  "stage_statuses": {
    "briefing": "pending",
    "agent1a": "pending",
    "agent1b": "pending",
    "agent2": "pending",
    "validation": "pending",
    "report": "pending"
  },
  "stage_durations_seconds": {
    "briefing": null,
    "agent1a": null,
    "agent1b": null,
    "agent2": null,
    "validation": null,
    "report": null
  },
  "cost_summary": "${COST_SUMMARY}",
  "tool_versions": {
    "claude": "${CLAUDE_VER}",
    "git": "${GIT_VER}",
    "jq": "${JQ_VER}",
    "gh": "${GH_VER}"
  }
}
EOF
log_event "info" "orchestrator" "manifest written" "run_id=${RUN_ID}"

# --- Resolve bug input ---
if [ -n "${ISSUE_NUM:-}" ]; then
  info "Fetching GitHub issue #${ISSUE_NUM}..."
  SLUG="${REPO_SLUG:-}"
  REPO_FLAG=""
  [ -n "$SLUG" ] && REPO_FLAG="--repo ${SLUG}"
  # shellcheck disable=SC2086
  gh issue view "$ISSUE_NUM" $REPO_FLAG \
    --json number,title,body,url,state,labels,author,createdAt,updatedAt \
    > "${RUN_DIR}/issue.json"
  jq -r '"# " + .title + "\n\n" + .body' "${RUN_DIR}/issue.json" > "${RUN_DIR}/bug.md"
  ISSUE_URL="$(jq -r '.url' "${RUN_DIR}/issue.json")"
  # Update manifest with issue URL
  tmp="$(mktemp)"
  jq --arg url "$ISSUE_URL" '.issue_url = $url | .bug_source = "github_issue"' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
  export BUG_FILE="${RUN_DIR}/bug.md"
  export BUG_INPUT_FILE="${RUN_DIR}/bug.md"
else
  # Save original path before overwriting BUG_FILE with the run copy
  export BUG_INPUT_FILE="$BUG_FILE"
  cp "$BUG_FILE" "${RUN_DIR}/bug.md"
  export BUG_FILE="${RUN_DIR}/bug.md"
fi

# --- Stage helper: record duration and update stage_statuses in manifest ---
_stage_start=0
stage_begin() {
  _stage_start="$(date +%s)"
}
stage_end() {
  local name="$1" status="$2"
  local dur=$(( $(date +%s) - _stage_start ))
  local tmp
  tmp="$(mktemp)"
  jq --arg n "$name" --arg s "$status" --argjson d "$dur" \
    '.stage_statuses[$n] = $s | .stage_durations_seconds[$n] = $d' \
    "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
  log_event "info" "$name" "stage complete" "status=${status}" "duration_seconds=${dur}"
}

# ============================================================
# STAGE: Briefing
# ============================================================
info "Briefing..."
stage_begin
source "${TOOL_ROOT}/scripts/briefing.sh"
stage_end "briefing" "ok"

# ============================================================
# STAGE: Agent 1a — Investigation (freetext; JSON checkpoint extracted from output)
# ============================================================
info "Agent 1a: investigation..."
stage_begin

# --- Read tier from briefing for turn/timeout selection ---
_REPO_TIER="$(grep '^REPO_TIER:' "$BRIEFING" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]' || echo 'XS')"
case "$_REPO_TIER" in
  S)  _A1A_TURNS="$RCA_A1A_TURNS_S";  _A1A_TIMEOUT="$RCA_A1A_TIMEOUT_S"  ;;
  M)  _A1A_TURNS="$RCA_A1A_TURNS_M";  _A1A_TIMEOUT="$RCA_A1A_TIMEOUT_M"  ;;
  L)  _A1A_TURNS="$RCA_A1A_TURNS_L";  _A1A_TIMEOUT="$RCA_A1A_TIMEOUT_L"  ;;
  *)  _A1A_TURNS="$RCA_A1A_TURNS_XS"; _A1A_TIMEOUT="$RCA_A1A_TIMEOUT_XS" ;;
esac

# --- Assemble agent1a_prompt.md ---
# Structure: investigation system prompt, then bug report, then briefing, then run metadata
{
  cat "${TOOL_ROOT}/prompts/investigation.md"
  printf '\n\n---\n\n## Bug Report\n\n'
  cat "$BUG_FILE"
  printf '\n\n---\n\n## Briefing\n\n'
  cat "$BRIEFING"
  printf '\n\n---\n\n'
  printf '## Run Metadata\n\n'
  printf 'RUN_ID: %s\n' "$RUN_ID"
  printf 'TARGET_REPO_ROOT: %s\n' "$TARGET_REPO_ROOT"
  printf 'RUN_DIR: %s\n' "$RUN_DIR"
  printf 'CHECKPOINT_PATH: %s\n' "$CHECKPOINT"
  printf 'CONFIDENCE_STOP: %s\n' "${RCA_CONFIDENCE_STOP}"
} > "$AGENT1A_PROMPT"

log_event "info" "agent1a" "prompt assembled" "turns=${_A1A_TURNS}" "timeout=${_A1A_TIMEOUT}" "tier=${_REPO_TIER}"

# --- Invoke Agent 1a under timeout ---
# Agent 1a: Read, Grep, Glob, Bash (read-only), Write (checkpoint only).
# Primary path: agent writes checkpoint.json via Write tool.
# Fallback: post-run extraction from agent1a_output.txt if Write was not reached.
_A1A_TOOLS="Read,Grep,Glob,Bash,Write"
_A1A_ALLOW=(
  "Bash(git log *)"
  "Bash(git show *)"
  "Bash(git blame *)"
  "Bash(git diff *)"
  "Bash(git status *)"
  "Bash(grep *)"
  "Bash(rg *)"
  "Bash(find *)"
  "Bash(cat *)"
  "Bash(wc *)"
  "Bash(head *)"
  "Bash(tail *)"
  "Write(${RUN_DIR}/**)"
)

_A1A_STATUS="ok"
export TOOL_ROOT RUN_DIR CHECKPOINT AGENT1A_PROMPT RCA_MODEL
export _A1A_TURNS _A1A_TOOLS
_A1A_ALLOW_SERIAL="$(printf '%s\0' "${_A1A_ALLOW[@]}" | base64)"
export _A1A_ALLOW_SERIAL

# Agent 1a raw output goes to agent1a_output.txt (plain text — no schema wrapper);
# we then extract the JSON checkpoint from that text into $CHECKPOINT.
# Using run_claude_freetext (no --json-schema) because schema-enforced output
# requires the model's final action to be text, not tool_use — hitting max_turns
# mid-investigation produces zero output when schema is enforced.
_A1A_RAW="${RUN_DIR}/agent1a_output.txt"
export _A1A_RAW

if ! timeout "${_A1A_TIMEOUT}" bash -c '
  source "${TOOL_ROOT}/lib/log.sh"
  source "${TOOL_ROOT}/lib/json.sh"
  source "${TOOL_ROOT}/scripts/claude_json.sh"
  readarray -d "" -t _allow < <(printf "%s" "$_A1A_ALLOW_SERIAL" | base64 -d)
  run_claude_freetext \
    "$AGENT1A_PROMPT" \
    "$_A1A_RAW" \
    "$_A1A_TURNS" \
    "$_A1A_TOOLS" \
    "${_allow[@]}"
' >> "$AGENT1A_LOG" 2>&1; then

  _A1A_STATUS="degraded"
  warn "Agent 1a failed or timed out"
  log_event "warn" "agent1a" "failed or timed out — checkpoint may be absent"
fi

# Fallback: if Agent 1a timed out or was killed before using the Write tool,
# try to extract a JSON checkpoint from its raw text output.
# Only runs if CHECKPOINT was not written by the agent itself.
if [ -f "$_A1A_RAW" ] && { [ ! -f "$CHECKPOINT" ] || ! jq -e . "$CHECKPOINT" > /dev/null 2>&1; }; then
  if extract_json_from_text "$_A1A_RAW" "$CHECKPOINT" 2>/dev/null; then
    log_event "info" "agent1a" "checkpoint recovered from text output (Write not reached)"
  fi
fi

# Ensure checkpoint is valid JSON — write seed if missing or corrupt
if [ ! -f "$CHECKPOINT" ] || ! jq -e . "$CHECKPOINT" > /dev/null 2>&1; then
  warn "Checkpoint missing or invalid after Agent 1a — writing seed"
  cat > "$CHECKPOINT" <<SEEDCP
{"hypothesis": "Agent 1a did not complete — no checkpoint written.", "confidence": 0.0, "files_examined": [], "call_chain": [], "affected_files": [], "supporting_evidence": [], "unknowns": ["Agent 1a timed out or failed before producing output"], "introducing_commit": null, "next_best_action": "Re-run the pipeline or investigate manually."}
SEEDCP
fi

stage_end "agent1a" "$_A1A_STATUS"
log_event "info" "agent1a" "investigation complete" "status=${_A1A_STATUS}"

# ============================================================
# STAGE: Agent 1b — Conclusion (schema-enforced, reads checkpoint)
# ============================================================
info "Agent 1b: conclusion..."
stage_begin

# --- Assemble agent1b_prompt.md ---
# Structure: conclusion system prompt + bug report + run metadata (with checkpoint path)
# Agent 1b does NOT receive the full briefing — it reads the checkpoint and bug report only.
{
  cat "${TOOL_ROOT}/prompts/diagnosis.md"
  printf '\n\n---\n\n## Bug Report\n\n'
  cat "$BUG_FILE"
  printf '\n\n---\n\n'
  printf '## Run Metadata\n\n'
  printf 'RUN_ID: %s\n' "$RUN_ID"
  printf 'TARGET_REPO_ROOT: %s\n' "$TARGET_REPO_ROOT"
  printf 'RUN_DIR: %s\n' "$RUN_DIR"
  printf 'CHECKPOINT_PATH: %s\n' "$CHECKPOINT"
  printf 'CONFIDENCE_STOP: %s\n' "${RCA_CONFIDENCE_STOP}"
  printf 'CONFIDENCE_CHECKPOINT: %s\n' "${RCA_CONFIDENCE_CHECKPOINT}"
} > "$AGENT1B_PROMPT"

log_event "info" "agent1b" "prompt assembled" "turns=${RCA_A1B_TURNS}" "timeout=${RCA_A1B_TIMEOUT}"

# --- Invoke Agent 1b under timeout ---
# Agent 1b: Read only (checkpoint + optionally a few source lines to verify).
# Grep/Glob available for light disambiguation. No Write, no Bash.
_A1B_TOOLS="Read,Grep,Glob"
_A1B_STATUS="ok"
export AGENT1B_PROMPT DIAGNOSIS_RAW DIAGNOSIS RCA_MODEL
_A1B_TURNS="${RCA_A1B_TURNS}"
_A1B_TIMEOUT="${RCA_A1B_TIMEOUT}"
export _A1B_TURNS _A1B_TOOLS

if ! timeout "${_A1B_TIMEOUT}" bash -c '
  source "${TOOL_ROOT}/lib/log.sh"
  source "${TOOL_ROOT}/lib/json.sh"
  source "${TOOL_ROOT}/scripts/claude_json.sh"
  run_claude_schema \
    "$AGENT1B_PROMPT" \
    "${TOOL_ROOT}/schemas/diagnosis.schema.json" \
    "$DIAGNOSIS_RAW" \
    "$DIAGNOSIS" \
    "$_A1B_TURNS" \
    "$_A1B_TOOLS"
' >> "$AGENT1B_LOG" 2>&1; then

  _A1B_STATUS="degraded"
  warn "Agent 1b failed or timed out — falling back to checkpoint synthesis"
  log_event "warn" "agent1b" "failed or timed out — checkpoint synthesis fallback"

  # Build a valid diagnosis.json from checkpoint fields + safe defaults
  _cp_hypo="$(jq -r '.hypothesis // "Could not determine root cause."' "$CHECKPOINT")"
  _cp_conf="$(jq -r '.confidence // 0' "$CHECKPOINT")"
  _cp_files="$(jq -c '.files_examined // []' "$CHECKPOINT")"
  _cp_chain="$(jq -c '.call_chain // []' "$CHECKPOINT")"
  _cp_affected="$(jq -c '.affected_files // []' "$CHECKPOINT")"
  _cp_unknowns="$(jq -c '.unknowns // ["Agent 1b timed out — diagnosis synthesised from checkpoint"]' "$CHECKPOINT")"
  _cp_commit="$(jq -c '.introducing_commit // null' "$CHECKPOINT")"
  _cp_nba="$(jq -r '.next_best_action // "Review checkpoint.json and extend investigation manually."' "$CHECKPOINT")"

  # If confidence is at seed level (0.0), use the checkpoint threshold instead
  if [ "$(printf '%.0f' "$(echo "${_cp_conf} * 100" | bc 2>/dev/null || echo '0')")" -eq 0 ]; then
    _cp_conf="${RCA_CONFIDENCE_CHECKPOINT}"
    _A1B_STATUS="failed"
  else
    _A1B_STATUS="partial"
  fi

  cat > "$DIAGNOSIS" <<PARTIAL
{
  "run_id": "${RUN_ID}",
  "root_cause": "PARTIAL — Agent 1b timed out. Best guess from investigation: ${_cp_hypo}",
  "selected_hypothesis_id": "h1",
  "hypotheses": [
    {
      "id": "h1",
      "summary": "${_cp_hypo}",
      "supporting_evidence": [],
      "contradicting_evidence": [],
      "confidence": ${_cp_conf}
    }
  ],
  "rejected_hypotheses": [],
  "affected_files": ${_cp_affected},
  "call_chain": ${_cp_chain},
  "files_examined": ${_cp_files},
  "unknowns": ${_cp_unknowns},
  "confidence": ${_cp_conf},
  "introducing_commit": ${_cp_commit},
  "next_best_action": "${_cp_nba}"
}
PARTIAL
  [ -f "$DIAGNOSIS_RAW" ] || cp "$DIAGNOSIS" "$DIAGNOSIS_RAW"
fi

stage_end "agent1b" "$_A1B_STATUS"

# --- Stamp run_id into diagnosis.json if it came back as a different value ---
_diag_run_id="$(jq -r '.run_id // ""' "$DIAGNOSIS" 2>/dev/null || true)"
if [ "$_diag_run_id" != "$RUN_ID" ]; then
  tmp="$(mktemp)"
  jq --arg r "$RUN_ID" '.run_id = $r' "$DIAGNOSIS" > "$tmp"
  mv "$tmp" "$DIAGNOSIS"
fi

# --- Log confidence for monitoring ---
_A1_CONF="$(jq -r '.confidence // 0' "$DIAGNOSIS" 2>/dev/null || echo '0')"
_A1_STATUS="${_A1B_STATUS}"
log_event "info" "agent1" "diagnosis complete" "confidence=${_A1_CONF}" "agent1a=${_A1A_STATUS}" "agent1b=${_A1B_STATUS}"

# ============================================================
# STAGE: Agent 2 — Solution (stub — Step 7)
# ============================================================
info "Agent 2: solution (stub)..."
stage_begin
cat > "$SOLUTION" <<STUB
{
  "run_id": "${RUN_ID}",
  "recommendation": "NO_FIX",
  "no_fix_reason": "Agent 2 not yet implemented (Step 7). Diagnosis confidence: ${_A1_CONF}.",
  "recommended_fix_id": null,
  "fixes": []
}
STUB
cp "$SOLUTION" "$SOLUTION_RAW"
stage_end "agent2" "stub"

# ============================================================
# STAGE: Validation (always skipped until Step 11)
# ============================================================
cat > "$VALIDATION" <<STUB
{
  "run_id": "${RUN_ID}",
  "status": "SKIPPED",
  "worktree_path": null,
  "applied_patch": false,
  "generated_test": false,
  "test_command": null,
  "commands_run": [],
  "failures": [],
  "regression_risk": "unknown",
  "notes": ["Run with --validate to apply patch in a worktree and run tests."]
}
STUB
stage_end "validation" "skipped"

# ============================================================
# STAGE: Cost summary
# ============================================================
# Extract turns used from conclusion phase raw JSON (agent1b produced diagnosis.raw.json)
_A1B_TURNS_USED="$(jq -r '.usage.output_tokens // .num_turns // 0' "$DIAGNOSIS_RAW" 2>/dev/null || echo '0')"

# Determine cost level: LOW / MEDIUM / HIGH
# Agent 1a is the expensive phase; agent1b is always small.
_COST_LEVEL="MEDIUM"
if [ "$_REPO_TIER" = "L" ] || \
   [ "${RCA_MODEL:-}" = "claude-opus-4-7" ]; then
  _COST_LEVEL="HIGH"
elif [ "$_REPO_TIER" = "XS" ] || [ "$_REPO_TIER" = "S" ]; then
  _COST_LEVEL="LOW"
fi

# Read stage durations from manifest
_DUR_BRIEFING="$(jq -r '.stage_durations_seconds.briefing // 0' "$MANIFEST" 2>/dev/null || echo '0')"
_DUR_A1A="$(jq -r '.stage_durations_seconds.agent1a // 0' "$MANIFEST" 2>/dev/null || echo '0')"
_DUR_A1B="$(jq -r '.stage_durations_seconds.agent1b // 0' "$MANIFEST" 2>/dev/null || echo '0')"
_DUR_AGENT2="$(jq -r '.stage_durations_seconds.agent2 // 0' "$MANIFEST" 2>/dev/null || echo '0')"
_DUR_TOTAL=$(( _DUR_BRIEFING + _DUR_A1A + _DUR_A1B + _DUR_AGENT2 ))

[ "$_DUR_TOTAL" -gt "$RCA_COST_WARN_SECONDS" ] && \
  warn "Total runtime ${_DUR_TOTAL}s exceeds threshold ${RCA_COST_WARN_SECONDS}s"

cat > "$COST_SUMMARY" <<COSTSUMMARY
{
  "run_id": "${RUN_ID}",
  "mode": "${MODE}",
  "model": "${RCA_MODEL:-claude-sonnet-4-6}",
  "repo_tier": "${_REPO_TIER}",
  "agent1a_max_turns": ${_A1A_TURNS},
  "agent1b_max_turns": ${RCA_A1B_TURNS},
  "agent1b_turns_used": ${_A1B_TURNS_USED},
  "agent2_max_turns": ${RCA_AGENT2_TURNS},
  "stage_durations_seconds": {
    "briefing": ${_DUR_BRIEFING},
    "agent1a": ${_DUR_A1A},
    "agent1b": ${_DUR_A1B},
    "agent2": ${_DUR_AGENT2},
    "validation": 0,
    "report": 0
  },
  "total_duration_seconds": ${_DUR_TOTAL},
  "validation_run": false,
  "token_counts": {
    "agent1a_input": null,
    "agent1a_output": null,
    "agent1b_input": null,
    "agent1b_output": null,
    "agent2_input": null,
    "agent2_output": null,
    "note": "populated if Claude raw output exposes usage fields; null otherwise"
  },
  "cost_level": "${_COST_LEVEL}",
  "authoritative": false,
  "note": "No exact dollar pricing. Cost level is relative based on model, tier, and turns used."
}
COSTSUMMARY

# ============================================================
# STAGE: Report
# ============================================================
info "Report..."
stage_begin
source "${TOOL_ROOT}/scripts/report.sh"
stage_end "report" "ok"

# --- Write ended_at to manifest ---
tmp="$(mktemp)"
jq --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '.ended_at = $t' "$MANIFEST" > "$tmp"
mv "$tmp" "$MANIFEST"

# --- Sync latest/ directory on Windows (no-op on symlink systems) ---
sync_latest

log_event "info" "orchestrator" "run complete" "run_id=${RUN_ID}" "report=${REPORT}"
info "Report: ${REPORT}"
printf '\n══════════════════════════════════════════\n'
printf ' RCA Report: %s\n' "$REPORT"
printf ' Run ID:     %s\n' "$RUN_ID"
printf '══════════════════════════════════════════\n'
