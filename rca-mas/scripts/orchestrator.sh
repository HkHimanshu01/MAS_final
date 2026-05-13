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
CLAUDE_VER="$("${CLAUDE_BIN:-claude}" --version 2>/dev/null || echo 'unknown')"
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
# STAGE: Agent 1a — Investigation
# Flow:
#   1. Assemble prompt
#   2. Run toolful investigation (set -e safe exit capture)
#   3. Extract stream: text, evidence, metadata
#   4. Run forced no-tool finalization via --resume
#   5. Quality gate (first pass)
#   6. If weak, run recovery from evidence
#   7. Quality gate (second pass, final)
#   8. Write checkpoint from findings + evidence
# Non-zero Claude exit is recoverable — never stops this flow.
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
{
  cat "${TOOL_ROOT}/prompts/investigation.md"
  printf '\n\n---\n\n## Bug Report\n\n'
  cat "$BUG_FILE"
  printf '\n\n---\n\n## Briefing\n\n'
  cat "$BRIEFING"
  printf '\n\n---\n\n## Run Metadata\n\n'
  printf 'RUN_ID: %s\n' "$RUN_ID"
  printf 'TARGET_REPO_ROOT: %s\n' "$TARGET_REPO_ROOT"
  printf 'RUN_DIR: %s\n' "$RUN_DIR"
  printf 'CONFIDENCE_STOP: %s\n' "${RCA_CONFIDENCE_STOP}"
} > "$AGENT1A_PROMPT"

log_event "info" "agent1a" "prompt assembled" "turns=${_A1A_TURNS}" "timeout=${_A1A_TIMEOUT}" "tier=${_REPO_TIER}"

# --- Step 2: Toolful investigation (set -e safe) ---
# Agent 1a uses Read/Grep/Glob/Bash only. Never Write. Never edits files.
# max_turns is an emergency cap — agent writes FINAL FINDINGS when confident.
# stderr is kept separate from stream-json stdout.
_A1A_TOOLS="Read,Grep,Glob,Bash"
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
  "Bash(ls *)"
  "Bash(sed *)"
)

_A1A_STATUS="ok"
_A1A_STREAM="${AGENT1A_STREAM}"         # agent1a_output.txt.stream
_A1A_STDERR="${AGENT1A_STDERR}"         # agent1a_stderr.txt
_A1A_OUTPUT="${AGENT1A_OUTPUT}"         # agent1a_output.txt
_A1A_EVIDENCE="${AGENT1A_EVIDENCE}"     # agent1a_evidence.txt
_A1A_META_ENV="${AGENT1A_META_ENV}"     # agent1a_meta.env
_A1A_QUALITY_ENV="${AGENT1A_QUALITY_ENV}" # agent1a_quality.env
_A1A_FINDINGS="${AGENT1A_FINDINGS}"     # agent1a_findings.md

# Build allowed-tools flags inline (no subshell serialization needed — we call claude directly)
_A1A_ALLOW_FLAGS=()
for _rule in "${_A1A_ALLOW[@]}"; do
  _A1A_ALLOW_FLAGS+=(--allowedTools "$_rule")
done

_A1A_MODEL_FLAG=()
[ -n "${RCA_MODEL:-}" ] && _A1A_MODEL_FLAG=(--model "${RCA_MODEL}")

# set -e safe capture: initialize exit_code=0, let || capture non-zero
_A1A_EXIT=0
timeout "${_A1A_TIMEOUT}" "${CLAUDE_BIN:-claude}" \
  -p "$(cat "$AGENT1A_PROMPT")" \
  --output-format stream-json \
  --verbose \
  --max-turns "${_A1A_TURNS}" \
  --tools "${_A1A_TOOLS}" \
  "${_A1A_MODEL_FLAG[@]}" \
  "${_A1A_ALLOW_FLAGS[@]}" \
  > "${_A1A_STREAM}" \
  2> "${_A1A_STDERR}" \
  || _A1A_EXIT=$?

if [ "$_A1A_EXIT" -ne 0 ]; then
  # Non-zero exit is expected on max_turns (stop_reason=tool_use) — not a fatal error.
  # stop_reason and session_id extraction below determines recovery path.
  _A1A_STATUS="degraded"
  log_event "warn" "agent1a" "investigation phase exited non-zero" "exit=${_A1A_EXIT}"
fi

# --- Step 3: Extract stream artifacts ---
# Validate stream is non-empty and contains a result event before extracting.
# A partial stream (timeout mid-run) may have assistant text but no result event.
if [ ! -s "${_A1A_STREAM}" ]; then
  log_event "warn" "agent1a" "stream file is empty — Claude produced no output" "exit=${_A1A_EXIT}"
  _A1A_STATUS="degraded"
elif ! jq -e 'select(.type == "result")' "${_A1A_STREAM}" > /dev/null 2>&1; then
  log_event "warn" "agent1a" "stream has no result event — likely truncated by timeout" "exit=${_A1A_EXIT}"
  _A1A_STATUS="degraded"
fi

_A1A_EXTRACT_FAILED=0
bash "${TOOL_ROOT}/scripts/extract_agent1a_stream.sh" \
  "${_A1A_STREAM}" \
  "${_A1A_OUTPUT}" \
  "${_A1A_EVIDENCE}" \
  "${_A1A_META_ENV}" \
  "${_A1A_EXIT}" \
  >> "${AGENT1A_LOG}" 2>&1 || _A1A_EXTRACT_FAILED=$?
if [ "$_A1A_EXTRACT_FAILED" -ne 0 ]; then
  log_event "warn" "agent1a" "stream extraction script failed" "exit=${_A1A_EXTRACT_FAILED}"
  _A1A_STATUS="degraded"
fi

# Read metadata extracted from stream
_A1A_SESSION_ID="$(grep '^session_id=' "${_A1A_META_ENV}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
_A1A_STOP_REASON="$(grep '^stop_reason=' "${_A1A_META_ENV}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
log_event "info" "agent1a" "stream extracted" \
  "stop_reason=${_A1A_STOP_REASON}" \
  "session_id_present=$([ -n "${_A1A_SESSION_ID}" ] && echo yes || echo no)"

# --- Step 4: Forced no-tool finalization ---
# Always runs when session_id is available. Standardises output regardless of stop_reason.
# Appends FINAL FINDINGS to agent1a_output.txt and writes agent1a_findings.md.
_A1A_FINALIZE_FAILED=0
bash "${TOOL_ROOT}/scripts/finalize_agent1a_summary.sh" \
  "${RUN_DIR}" \
  "${TOOL_ROOT}" \
  >> "${AGENT1A_LOG}" 2>&1 || _A1A_FINALIZE_FAILED=$?
if [ "$_A1A_FINALIZE_FAILED" -ne 0 ]; then
  log_event "warn" "agent1a" "finalization script exited non-zero" "exit=${_A1A_FINALIZE_FAILED}"
  _A1A_STATUS="degraded"
fi

# --- Step 5: Quality gate (first pass) ---
_A1A_QUALITY_FAILED=0
bash "${TOOL_ROOT}/scripts/check_agent1a_quality.sh" \
  "${RUN_DIR}" \
  >> "${AGENT1A_LOG}" 2>&1 || _A1A_QUALITY_FAILED=$?
if [ "$_A1A_QUALITY_FAILED" -ne 0 ]; then
  log_event "warn" "agent1a" "quality check script exited non-zero" "exit=${_A1A_QUALITY_FAILED}"
fi

_A1A_QUALITY="$(grep '^agent1a_quality=' "${_A1A_QUALITY_ENV}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
if [ "${_A1A_QUALITY}" = "weak" ] || [ -z "${_A1A_QUALITY}" ]; then
  log_event "warn" "agent1a" "quality gate (pass 1): WEAK" "quality=${_A1A_QUALITY:-unknown}"
  warn "Agent 1a quality is weak after pass 1 — running evidence recovery"
else
  log_event "info" "agent1a" "quality gate (pass 1): ok" "quality=${_A1A_QUALITY}"
fi

# --- Steps 6-7: Recovery + second quality gate if weak ---
if [ "${_A1A_QUALITY}" = "weak" ] || [ -z "${_A1A_QUALITY}" ]; then
  _A1A_RECOVER_FAILED=0
  bash "${TOOL_ROOT}/scripts/recover_agent1a_findings.sh" \
    "${RUN_DIR}" \
    "${TOOL_ROOT}" \
    >> "${AGENT1A_LOG}" 2>&1 || _A1A_RECOVER_FAILED=$?
  if [ "$_A1A_RECOVER_FAILED" -ne 0 ]; then
    log_event "warn" "agent1a" "recovery script exited non-zero" "exit=${_A1A_RECOVER_FAILED}"
  fi

  # Re-run quality gate after recovery
  bash "${TOOL_ROOT}/scripts/check_agent1a_quality.sh" \
    "${RUN_DIR}" \
    >> "${AGENT1A_LOG}" 2>&1 || true

  _A1A_QUALITY="$(grep '^agent1a_quality=' "${_A1A_QUALITY_ENV}" 2>/dev/null | cut -d= -f2- | head -1 || true)"
  if [ "${_A1A_QUALITY}" = "weak" ] || [ -z "${_A1A_QUALITY}" ]; then
    log_event "warn" "agent1a" "quality gate (pass 2): still WEAK — proceeding with degraded signal" "quality=${_A1A_QUALITY:-unknown}"
    warn "Agent 1a quality is still weak after recovery — Agent 1b will cap confidence at 0.4"
    _A1A_STATUS="degraded"
  else
    log_event "info" "agent1a" "quality gate (pass 2): ok after recovery" "quality=${_A1A_QUALITY}"
  fi
fi

# Ensure agent1a_quality.env always exists
touch "${_A1A_QUALITY_ENV}" 2>/dev/null || true

# --- Step 8: Write checkpoint from findings + evidence ---
# Checkpoint writer receives: findings.md (primary), evidence.txt (fallback), bug.md, briefing.md
_A1A_WRITE_PROMPT="${RUN_DIR}/agent1a_write_prompt.md"
_A1A_WRITE_OUTPUT="${RUN_DIR}/agent1a_write_output.txt"

{
  cat "${TOOL_ROOT}/prompts/investigation_write.md"
  printf '\n\n---\n\n## 1. agent1a_findings.md (canonical findings)\n\n'
  if [ -s "${_A1A_FINDINGS}" ]; then
    cat "${_A1A_FINDINGS}"
  else
    printf '(agent1a_findings.md is empty — use evidence transcript below)\n'
  fi
  printf '\n\n---\n\n## 2. agent1a_evidence.txt (tool calls and tool results)\n\n'
  if [ -s "${_A1A_EVIDENCE}" ]; then
    # Cap evidence at 8000 chars to avoid prompt overflow — prefer recent entries (tail)
    _EV_SIZE="$(wc -c < "${_A1A_EVIDENCE}" | tr -d '[:space:]')"
    if [ "${_EV_SIZE:-0}" -gt 8000 ]; then
      printf '... [evidence truncated — showing last 8000 bytes]\n\n'
      tail -c 8000 "${_A1A_EVIDENCE}"
    else
      cat "${_A1A_EVIDENCE}"
    fi
  else
    printf '(agent1a_evidence.txt is empty)\n'
  fi
  printf '\n\n---\n\n## Run Metadata\n\n'
  printf 'CHECKPOINT_PATH: %s\n' "$CHECKPOINT"
  printf 'TARGET_REPO_ROOT: %s\n' "$TARGET_REPO_ROOT"
} > "$_A1A_WRITE_PROMPT"

# No Write tool needed — Claude outputs raw JSON as its response text.
# --output-format json wraps the response; we extract .result and write it with bash.
# This avoids interactive permission prompts entirely.
_A1A_WRITE_EXIT=0
timeout 180 "${CLAUDE_BIN:-claude}" \
  -p "$(cat "$_A1A_WRITE_PROMPT")" \
  --output-format json \
  --max-turns 1 \
  --tools "" \
  "${_A1A_MODEL_FLAG[@]}" \
  > "${_A1A_WRITE_OUTPUT}.json" \
  2> "${_A1A_WRITE_OUTPUT}.stderr" \
  || _A1A_WRITE_EXIT=$?

if [ "$_A1A_WRITE_EXIT" -ne 0 ]; then
  log_event "warn" "agent1a" "write phase exited non-zero" "exit=${_A1A_WRITE_EXIT}"
fi

# Extract the response text (.result field) and write it as checkpoint.json.
# The prompt instructs Claude to output raw JSON only — validate before saving.
_A1A_WRITE_RESULT="$(jq -r '.result // empty' "${_A1A_WRITE_OUTPUT}.json" 2>/dev/null || true)"

# Also try extract_normalize_json as fallback (handles stringified/fenced JSON)
if [ -z "$_A1A_WRITE_RESULT" ] || ! printf '%s\n' "$_A1A_WRITE_RESULT" | jq -e . > /dev/null 2>&1; then
  _A1A_WRITE_TMP="${RUN_DIR}/agent1a_write_normalized.json"
  if extract_normalize_json "${_A1A_WRITE_OUTPUT}.json" "$_A1A_WRITE_TMP" 2>/dev/null; then
    _A1A_WRITE_RESULT="$(cat "$_A1A_WRITE_TMP")"
    log_event "info" "agent1a" "checkpoint extracted via normalize fallback"
  fi
fi

if [ -n "$_A1A_WRITE_RESULT" ] && printf '%s\n' "$_A1A_WRITE_RESULT" | jq -e . > /dev/null 2>&1; then
  printf '%s\n' "$_A1A_WRITE_RESULT" > "$CHECKPOINT"
  log_event "info" "agent1a" "checkpoint written" "bytes=${#_A1A_WRITE_RESULT}"
else
  log_event "error" "agent1a" "write phase produced no valid JSON — checkpoint will be a degraded seed" "exit=${_A1A_WRITE_EXIT}"
  warn "Agent 1a write phase failed to produce valid JSON checkpoint"
  _A1A_STATUS="degraded"
fi

# --- Ensure checkpoint is valid JSON — write degraded seed if missing or corrupt ---
# This seed is explicitly marked as a failure artifact, not silent fake data.
# Agent 1b will see confidence=0.0 and quality=failed and cap accordingly.
if [ ! -f "$CHECKPOINT" ] || ! jq -e . "$CHECKPOINT" > /dev/null 2>&1; then
  log_event "error" "agent1a" "checkpoint missing or invalid — writing degraded seed; Agent 1b will receive 0.0 confidence placeholder"
  warn "Checkpoint missing or invalid after Agent 1a write phase — writing degraded seed"
  _A1A_STATUS="degraded"
  jq -n \
    --arg hint "Agent 1a investigation did not produce a valid checkpoint. See agent1a_findings.md and agent1a_evidence.txt." \
    '{
      "hypothesis": $hint,
      "confidence": 0.0,
      "files_examined": [],
      "call_chain": [],
      "affected_files": [],
      "supporting_evidence": [],
      "unknowns": ["checkpoint writer did not produce valid JSON"],
      "introducing_commit": null,
      "next_best_action": "Inspect agent1a_findings.md and agent1a_evidence.txt in the run directory.",
      "_degraded_seed": true
    }' > "$CHECKPOINT"
  # Force quality to failed so Agent 1b caps confidence at 0.4
  printf 'agent1a_quality=failed\nagent1a_finalization=failed\nagent1a_recovery=failed\n' > "${_A1A_QUALITY_ENV}"
fi

stage_end "agent1a" "$_A1A_STATUS"
log_event "info" "agent1a" "investigation complete" \
  "status=${_A1A_STATUS}" \
  "quality=${_A1A_QUALITY:-unknown}" \
  "stop_reason=${_A1A_STOP_REASON:-unknown}"

# ============================================================
# STAGE: Agent 1b — Conclusion (schema-enforced, reads checkpoint)
#
# Flow:
#   1. Assert checkpoint exists and is valid
#   2. Assemble prompt (system + bug report + checkpoint inline)
#   3. Invoke Claude — no tools, no bash -c, stdout/stderr separated
#   4. Normalise output (extract_normalize_json handles all envelope forms)
#   5. Validate against diagnosis schema
#   6. If invalid: one repair attempt
#   7. If repair fails: fail-closed — do not write diagnosis.json
#   8. Atomic write only after validation passes
#   9. Write meta env, quality env, sidecars always
# ============================================================
info "Agent 1b: conclusion..."
stage_begin

_A1B_STATUS="ok"
_A1B_FAILURE_REASON=""
_A1B_RESULT_TYPE="none"
_A1B_NORMALIZED="false"
_A1B_SCHEMA_VALID="false"
_A1B_REPAIR_ATTEMPTED="false"
_A1B_REPAIR_SUCCESS="false"

# Helper: write agent1b_meta.env (always called, even on failure)
_write_a1b_meta() {
  cat > "$AGENT1B_META_ENV" <<METAENV
exit_code=${1:-1}
result_type=${_A1B_RESULT_TYPE}
normalized=${_A1B_NORMALIZED}
schema_valid=${_A1B_SCHEMA_VALID}
repair_attempted=${_A1B_REPAIR_ATTEMPTED}
repair_success=${_A1B_REPAIR_SUCCESS}
failure_reason=${_A1B_FAILURE_REASON}
METAENV
}

# Helper: write agent1b_quality.env
_write_a1b_quality() {
  printf 'agent1b_quality=%s\n' "$1" > "$AGENT1B_QUALITY_ENV"
}

# --- Step 1: Assert checkpoint ---
# Checks: file exists, is valid JSON object, is not a degraded seed, has at least one
# meaningful field (hypothesis or root_cause) so Agent 1b has real signal to work with.
if [ ! -f "$CHECKPOINT" ] || ! jq -e 'type == "object"' "$CHECKPOINT" > /dev/null 2>&1; then
  _A1B_FAILURE_REASON="checkpoint missing or not a JSON object"
  warn "Agent 1b: ${_A1B_FAILURE_REASON}"
  log_event "error" "agent1b" "checkpoint invalid" "reason=${_A1B_FAILURE_REASON}"
  _write_a1b_meta 1
  _write_a1b_quality "failed"
  _A1B_STATUS="failed"
elif jq -e '._degraded_seed == true' "$CHECKPOINT" > /dev/null 2>&1; then
  _A1B_FAILURE_REASON="checkpoint is a degraded seed (Agent 1a write phase failed) — no real findings to synthesise"
  warn "Agent 1b: ${_A1B_FAILURE_REASON}"
  log_event "error" "agent1b" "checkpoint is degraded seed" "reason=${_A1B_FAILURE_REASON}"
  _write_a1b_meta 1
  _write_a1b_quality "failed"
  _A1B_STATUS="failed"
elif ! jq -e '
  ((.hypothesis | type == "string" and length > 0) or
   (.root_cause | type == "string" and length > 0) or
   (.call_chain | type == "array" and length > 0) or
   (.files_examined | type == "array" and length > 0))
' "$CHECKPOINT" > /dev/null 2>&1; then
  _A1B_FAILURE_REASON="checkpoint is an empty or near-empty object — no investigative signal"
  warn "Agent 1b: ${_A1B_FAILURE_REASON}"
  log_event "error" "agent1b" "checkpoint has no useful fields" "reason=${_A1B_FAILURE_REASON}"
  _write_a1b_meta 1
  _write_a1b_quality "failed"
  _A1B_STATUS="failed"
fi

# --- Step 1b: Log checkpoint shape ---
# Tells the operator what Agent 1b is about to receive. Helps diagnose downstream
# failures: a "rich" checkpoint (hypotheses array + root_cause) maps 1:1 onto the
# diagnosis schema; a "legacy" checkpoint (hypothesis singular only) requires
# Agent 1b to synthesise the structure per its prompt's mapping rules.
if [ "$_A1B_STATUS" != "failed" ]; then
  _cp_shape="$(jq -r '
    {
      has_root_cause: (has("root_cause") and (.root_cause | type == "string") and (.root_cause | length > 0)),
      has_hypothesis: (has("hypothesis") and (.hypothesis | type == "string") and (.hypothesis | length > 0)),
      has_hypotheses_array: (has("hypotheses") and (.hypotheses | type == "array") and (.hypotheses | length > 0)),
      has_selected_id: (has("selected_hypothesis_id") and (.selected_hypothesis_id | type == "string") and (.selected_hypothesis_id | length > 0)),
      has_supporting_evidence: (has("supporting_evidence") and (.supporting_evidence | type == "array") and (.supporting_evidence | length > 0)),
      affected_files_count: (.affected_files // [] | length),
      files_examined_count: (.files_examined // [] | length),
      call_chain_length: (.call_chain // [] | length),
      checkpoint_confidence: (.confidence // 0)
    } | to_entries | map("\(.key)=\(.value)") | join(" ")
  ' "$CHECKPOINT" 2>/dev/null || echo "shape_extract_failed")"
  log_event "info" "agent1b" "checkpoint shape" "${_cp_shape}"
fi

# --- Step 2: Assemble prompt ---
# Agent 1b receives: system prompt + bug report + checkpoint content inline.
# Does NOT receive briefing.md, evidence transcripts, or raw repo context.
if [ "$_A1B_STATUS" != "failed" ]; then
  _cp_quality="$(grep '^agent1a_quality=' "${AGENT1A_QUALITY_ENV:-/dev/null}" 2>/dev/null | cut -d= -f2- || echo 'unknown')"
  {
    cat "${TOOL_ROOT}/prompts/diagnosis.md"
    printf '\n\n---\n\n## Bug Report\n\n'
    cat "$BUG_FILE"
    printf '\n\n---\n\n## Checkpoint (Agent 1a findings)\n\n'
    cat "$CHECKPOINT"
    printf '\n\n---\n\n## Run Metadata\n\n'
    printf 'RUN_ID: %s\n' "$RUN_ID"
    printf 'CHECKPOINT_QUALITY: %s\n' "${_cp_quality}"
    printf 'CONFIDENCE_STOP: %s\n' "${RCA_CONFIDENCE_STOP}"
  } > "$AGENT1B_PROMPT"
  log_event "info" "agent1b" "prompt assembled" "turns=${RCA_A1B_TURNS}" "timeout=${RCA_A1B_TIMEOUT}" "checkpoint_quality=${_cp_quality}"
fi

# --- Step 3: Invoke Claude (no tools, no bash -c, separated stderr) ---
_A1B_EXIT=0
_A1B_SCHEMA="${TOOL_ROOT}/schemas/diagnosis.schema.json"

if [ "$_A1B_STATUS" != "failed" ]; then
  timeout "${RCA_A1B_TIMEOUT}" \
    "${CLAUDE_BIN:-claude}" \
      -p "$(cat "$AGENT1B_PROMPT")" \
      --output-format json \
      --json-schema "$(cat "$_A1B_SCHEMA")" \
      --max-turns "${RCA_A1B_TURNS}" \
      "${_A1A_MODEL_FLAG[@]}" \
    > "$AGENT1B_RAW" \
    2> "$AGENT1B_STDERR" \
    || _A1B_EXIT=$?

  if [ "$_A1B_EXIT" -ne 0 ]; then
    _A1B_STATUS="degraded"
    _A1B_FAILURE_REASON="claude exited ${_A1B_EXIT}"
    log_event "warn" "agent1b" "claude exited non-zero" "exit=${_A1B_EXIT}"
  fi
fi

# --- Step 4: Normalise output ---
_A1B_TMP="${RUN_DIR}/diagnosis.json.tmp"
if [ "$_A1B_STATUS" != "failed" ] && [ -s "$AGENT1B_RAW" ]; then
  if extract_normalize_json "$AGENT1B_RAW" "$_A1B_TMP" 2>/dev/null; then
    _A1B_NORMALIZED="true"
    _A1B_RESULT_TYPE="extracted"
  else
    _A1B_FAILURE_REASON="could not extract JSON object from Claude output"
    log_event "warn" "agent1b" "normalisation failed" "reason=${_A1B_FAILURE_REASON}"
    [ "$_A1B_STATUS" = "ok" ] && _A1B_STATUS="degraded"
  fi
else
  [ "$_A1B_STATUS" != "failed" ] && _A1B_FAILURE_REASON="claude produced no output (exit=${_A1B_EXIT})"
  [ "$_A1B_STATUS" = "ok" ] && _A1B_STATUS="degraded"
fi

# --- Step 5: Validate ---
_A1B_VALIDATION_ERR=""
if [ "$_A1B_NORMALIZED" = "true" ]; then
  # Stamp run_id; cap confidence at 0.4 when checkpoint quality was weak/failed
  _tmp_stamp="$(mktemp)"
  _cp_q="$(grep '^agent1a_quality=' "${AGENT1A_QUALITY_ENV:-/dev/null}" 2>/dev/null | cut -d= -f2- || echo '')"
  if [ "$_cp_q" = "weak" ] || [ "$_cp_q" = "failed" ]; then
    jq --arg r "$RUN_ID" '
      .run_id = $r |
      if .confidence > 0.4 then .confidence = 0.4 else . end
    ' "$_A1B_TMP" > "$_tmp_stamp" 2>/dev/null && mv "$_tmp_stamp" "$_A1B_TMP" || true
    log_event "info" "agent1b" "confidence capped at 0.4 (checkpoint_quality=${_cp_q})"
  else
    jq --arg r "$RUN_ID" '.run_id = $r' "$_A1B_TMP" > "$_tmp_stamp" 2>/dev/null \
      && mv "$_tmp_stamp" "$_A1B_TMP" || true
  fi

  # validate_diagnosis_json exits 1 on validation error and writes the reason to stdout.
  # The trailing || true prevents set -e from killing the orchestrator on a captured non-zero.
  _A1B_VALIDATION_ERR="$(validate_diagnosis_json "$_A1B_TMP" 2>/dev/null || true)"
  if [ -z "$_A1B_VALIDATION_ERR" ]; then
    _A1B_SCHEMA_VALID="true"
  else
    log_event "warn" "agent1b" "schema validation failed" "reason=${_A1B_VALIDATION_ERR}"
    # Preserve invalid candidate for debugging
    cp "$_A1B_TMP" "${RUN_DIR}/diagnosis.invalid.json" 2>/dev/null || true
  fi
fi

# --- Step 6: Repair attempt (one shot) ---
if [ "$_A1B_SCHEMA_VALID" != "true" ] && [ "$_A1B_STATUS" != "failed" ]; then
  _A1B_REPAIR_ATTEMPTED="true"
  log_event "info" "agent1b" "attempting repair" "validation_error=${_A1B_VALIDATION_ERR}"

  _A1B_REPAIR_PROMPT="${RUN_DIR}/agent1b_repair_prompt.md"
  {
    cat "${TOOL_ROOT}/prompts/agent1b_repair.md"
    printf '\n\n---\n\n## Checkpoint\n\n'
    cat "$CHECKPOINT"
    printf '\n\n---\n\n## Bug Report\n\n'
    cat "$BUG_FILE"
    printf '\n\n---\n\n## Previous invalid output\n\n'
    cat "${RUN_DIR}/diagnosis.invalid.json" 2>/dev/null || printf '(none — extraction failed)\n'
    printf '\n\n---\n\n## Validation error\n\n%s\n' "${_A1B_VALIDATION_ERR:-extraction failed}"
    printf '\n\n---\n\n## Run Metadata\n\nRUN_ID: %s\n' "$RUN_ID"
  } > "$_A1B_REPAIR_PROMPT"

  _A1B_REPAIR_EXIT=0
  timeout "${RCA_A1B_TIMEOUT}" \
    "${CLAUDE_BIN:-claude}" \
      -p "$(cat "$_A1B_REPAIR_PROMPT")" \
      --output-format json \
      --json-schema "$(cat "$_A1B_SCHEMA")" \
      --max-turns 1 \
      "${_A1A_MODEL_FLAG[@]}" \
    > "$AGENT1B_REPAIR_RAW" \
    2> "$AGENT1B_REPAIR_STDERR" \
    || _A1B_REPAIR_EXIT=$?

  _A1B_REPAIR_TMP="${RUN_DIR}/diagnosis_repair.json.tmp"
  if [ "$_A1B_REPAIR_EXIT" -eq 0 ] && [ -s "$AGENT1B_REPAIR_RAW" ] \
      && extract_normalize_json "$AGENT1B_REPAIR_RAW" "$_A1B_REPAIR_TMP" 2>/dev/null; then
    _tmp_stamp="$(mktemp)"
    jq --arg r "$RUN_ID" '.run_id = $r' "$_A1B_REPAIR_TMP" > "$_tmp_stamp" 2>/dev/null \
      && mv "$_tmp_stamp" "$_A1B_REPAIR_TMP" || true

    _A1B_REPAIR_ERR="$(validate_diagnosis_json "$_A1B_REPAIR_TMP" 2>/dev/null || true)"
    if [ -z "$_A1B_REPAIR_ERR" ]; then
      _A1B_REPAIR_SUCCESS="true"
      _A1B_SCHEMA_VALID="true"
      mv "$_A1B_REPAIR_TMP" "$_A1B_TMP"
      log_event "info" "agent1b" "repair succeeded"
    else
      _A1B_FAILURE_REASON="repair validation failed: ${_A1B_REPAIR_ERR}"
      printf '%s\n' "$_A1B_REPAIR_ERR" > "${RUN_DIR}/diagnosis.invalid.txt"
      log_event "warn" "agent1b" "repair validation failed" "reason=${_A1B_REPAIR_ERR}"
    fi
  else
    _A1B_FAILURE_REASON="repair Claude call failed or produced no output (exit=${_A1B_REPAIR_EXIT})"
    log_event "warn" "agent1b" "repair call failed" "exit=${_A1B_REPAIR_EXIT}"
  fi
fi

# --- Step 7: Fail-closed if still invalid ---
if [ "$_A1B_SCHEMA_VALID" != "true" ]; then
  _A1B_STATUS="failed"
  [ -z "$_A1B_FAILURE_REASON" ] && _A1B_FAILURE_REASON="diagnosis could not be validated"
  _write_a1b_meta "${_A1B_EXIT:-1}"
  _write_a1b_quality "failed"
  stage_end "agent1b" "failed"
  warn "Agent 1b failed to produce valid diagnosis.json. See ${AGENT1B_RAW}, ${RUN_DIR}/diagnosis.invalid.*, ${AGENT1B_STDERR}."
  log_event "error" "agent1b" "fail-closed: skipping Agent 2 and report" "reason=${_A1B_FAILURE_REASON}"
  # Write a minimal diagnosis.json with failure status so report.sh can still render
  jq -n \
    --arg rid "$RUN_ID" \
    --arg reason "${_A1B_FAILURE_REASON}" \
    '{
      "run_id": $rid,
      "root_cause": ("Agent 1b failed to produce valid diagnosis. " + $reason),
      "selected_hypothesis_id": "h1",
      "hypotheses": [{"id":"h1","summary":"Agent 1b failed","supporting_evidence":[],"contradicting_evidence":[],"confidence":0.0}],
      "rejected_hypotheses": [],
      "affected_files": [],
      "call_chain": [],
      "files_examined": [],
      "unknowns": [$reason],
      "confidence": 0.0,
      "introducing_commit": null,
      "next_best_action": "Inspect agent1b_raw.json and agent1b_stderr.txt in the run directory."
    }' > "$DIAGNOSIS"
  [ -f "$AGENT1B_RAW" ] && cp "$AGENT1B_RAW" "$DIAGNOSIS_RAW" || cp "$DIAGNOSIS" "$DIAGNOSIS_RAW"
else
  # --- Step 8: Atomic write after validation ---
  mv "$_A1B_TMP" "$DIAGNOSIS"
  [ -f "$AGENT1B_RAW" ] && cp "$AGENT1B_RAW" "$DIAGNOSIS_RAW" || cp "$DIAGNOSIS" "$DIAGNOSIS_RAW"
  _write_a1b_meta "${_A1B_EXIT:-0}"
  _write_a1b_quality "ok"
  log_event "info" "agent1b" "diagnosis written" "validation=passed"
fi

# Clean up tmp files
rm -f "$_A1B_TMP" "${RUN_DIR}/diagnosis_repair.json.tmp" 2>/dev/null || true

stage_end "agent1b" "$_A1B_STATUS"

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
