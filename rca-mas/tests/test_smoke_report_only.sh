#!/usr/bin/env bash
# tests/test_smoke_report_only.sh — End-to-end smoke test using fixture JSON.
# No Claude required. Verifies full pipeline exits 0 and produces expected outputs.
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL: %s\n' "$1"; (( FAIL++ )) || true; }

# Use a minimal fixture bug file with no quoted error strings or file paths —
# this keeps briefing fast (no rg scans) for the smoke test.
# Real briefing quality is tested in test_briefing.sh and test_collectors.sh.
cd "$TOOL_ROOT"

# Snapshot which source files are already dirty before the pipeline runs.
# The pipeline must not ADD new modifications — pre-existing changes are irrelevant.
_pre_dirty="$(git status --porcelain -- rca-mas.sh scripts/ lib/ collectors/ prompts/ schemas/ config/ 2>/dev/null | grep -v '^??' | awk '{print $2}' | sort || true)"

bash rca-mas.sh tests/fixtures/smoke_bug.md && pass "Pipeline exits 0" || fail "Pipeline exited non-zero"

LATEST=".rca-mas/runs/latest"

# Test latest exists (symlink on Linux/Mac, directory on Windows)
[ -L "$LATEST" ] || [ -d "$LATEST" ] && pass "latest exists (symlink or directory)" || fail "latest missing"
[ -d "$LATEST" ] && pass "latest is accessible as directory" || fail "latest is not accessible as directory"

# Test required output files exist
for f in manifest.json log.jsonl bug.md briefing.md errors.txt \
          diagnosis.json solution.json validation.json cost_summary.json report.md; do
  [ -f "${LATEST}/${f}" ] && pass "${f} exists" || fail "${f} missing"
done

# Test manifest is valid JSON with required fields
for field in .run_id .mode .started_at .tool_versions; do
  val="$(jq -r "$field" "${LATEST}/manifest.json" 2>/dev/null || true)"
  [ -n "$val" ] && [ "$val" != "null" ] && \
    pass "manifest has field $field" || \
    fail "manifest missing field $field"
done

# Test ended_at is set (run completed)
val="$(jq -r '.ended_at' "${LATEST}/manifest.json" 2>/dev/null || true)"
[ -n "$val" ] && [ "$val" != "null" ] && \
  pass "manifest.ended_at is set" || \
  fail "manifest.ended_at is null (run may not have completed)"

# Test all JSON outputs are valid
for f in manifest.json diagnosis.json solution.json validation.json cost_summary.json; do
  jq -e . "${LATEST}/${f}" > /dev/null 2>&1 && \
    pass "${f} is valid JSON" || \
    fail "${f} is invalid JSON"
done

# Test report.md has all 11 required sections
required_sections=(
  "## Status"
  "## Root Cause"
  "## Confidence"
  "## Evidence"
  "## Affected Files"
  "## Proposed Fix"
  "## Patch Files"
  "## Validation"
  "## Cost / Runtime"
  "## Unknowns / Risks"
  "## Next Action"
)
for section in "${required_sections[@]}"; do
  grep -q "$section" "${LATEST}/report.md" && \
    pass "report.md has '$section'" || \
    fail "report.md missing '$section'"
done

# Test the pipeline did not modify source files during its run.
# Compare post-run dirty set against pre-run snapshot — only new modifications are a problem.
_post_dirty="$(git status --porcelain -- rca-mas.sh scripts/ lib/ collectors/ prompts/ schemas/ config/ 2>/dev/null | grep -v '^??' | awk '{print $2}' | sort || true)"
_new_dirty="$(comm -13 <(printf '%s\n' "$_pre_dirty") <(printf '%s\n' "$_post_dirty") || true)"
[ -z "$_new_dirty" ] \
  && pass "Pipeline did not modify source files during run" \
  || fail "Pipeline modified source files it should not touch: $_new_dirty"

# Cleanup
rm -rf .rca-mas/runs .rca-mas-worktrees 2>/dev/null || true

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
