#!/usr/bin/env bash
# tests/test_briefing.sh — Tests for real briefing.sh behavior.
# No Claude required. Uses a tiny temp repo for controlled assertions.
set -Eeuo pipefail
IFS=$'\n\t'

PASS=0; FAIL=0
TOOL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export TOOL_ROOT

pass() { printf 'PASS: %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf 'FAIL: %s\n' "$1"; (( FAIL++ )) || true; }

source "${TOOL_ROOT}/config/defaults.env"
source "${TOOL_ROOT}/lib/log.sh"

# ---------------------------------------------------------------------------
# Build a tiny target repo with controlled contents
# ---------------------------------------------------------------------------
# Create test dirs under the user's home to avoid Windows ownership issues
# with /tmp dirs owned by BUILTIN\Administrators in some shell contexts.
_TEST_BASE="${HOME}/.rca-mas-test-$$"
mkdir -p "$_TEST_BASE"
TINY_REPO="${_TEST_BASE}/repo"
TMPDIR_RUN="${_TEST_BASE}/run"
mkdir -p "$TINY_REPO" "$TMPDIR_RUN"
trap 'rm -rf "$_TEST_BASE"' EXIT

# Create repo structure
mkdir -p "${TINY_REPO}/src/cart" "${TINY_REPO}/tests"

# Mark the test repo as safe (handles Windows safe-directory restrictions).
# Write to the user's actual global gitconfig rather than overriding HOME,
# so subprocess git calls (in briefing.sh and collectors) also respect it.
git config --global --add safe.directory "$TINY_REPO" 2>/dev/null || true

git init -q "$TINY_REPO"
git -C "$TINY_REPO" config user.email "test@test.com"
git -C "$TINY_REPO" config user.name "Test"

# Source file with the target error string inside it
cat > "${TINY_REPO}/src/cart/pricing.py" <<'PYEOF'
def apply_discount(cart, code):
    discount = lookup_discount(code)
    # Bug: no None guard
    total = cart.subtotal - discount.discount_value
    return total
PYEOF

# Test file
cat > "${TINY_REPO}/tests/test_pricing.py" <<'PYEOF'
def test_apply_discount():
    pass
PYEOF

# pytest config
printf '[pytest]\n' > "${TINY_REPO}/pytest.ini"

# Stage and commit tracked files
git -C "$TINY_REPO" add src/cart/pricing.py tests/test_pricing.py pytest.ini
git -C "$TINY_REPO" commit -q -m "init"

# Untracked file — should NOT appear in MENTIONED_FILES
cat > "${TINY_REPO}/src/cart/untracked.py" <<'PYEOF'
# This file is intentionally untracked
PYEOF

# Bug report that mentions src/cart/pricing.py and contains both double-quoted
# and backtick-quoted strings. Both should appear in errors.txt.
cat > "${TINY_REPO}/bug.md" <<'BUGEOF'
# Bug: discount not applied

User reports cart total is wrong.
Error observed: "TypeError: discount_value not found"
Also seen: `discount_value` is None when code is not recognised.

File: src/cart/pricing.py
BUGEOF

# ---------------------------------------------------------------------------
# Run briefing against the tiny repo
# ---------------------------------------------------------------------------
export TARGET_REPO_ROOT="$TINY_REPO"
export RUN_DIR="$TMPDIR_RUN"
export BRIEFING="${TMPDIR_RUN}/briefing.md"
export ERRORS_TXT="${TMPDIR_RUN}/errors.txt"
export LOG_FILE="${TMPDIR_RUN}/log.jsonl"
export BUG_FILE="${TINY_REPO}/bug.md"
touch "$LOG_FILE"

bash "${TOOL_ROOT}/scripts/briefing.sh" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Basic output existence
# ---------------------------------------------------------------------------
[ -f "$BRIEFING" ]   && pass "briefing.md created"   || fail "briefing.md not created"
[ -f "$ERRORS_TXT" ] && pass "errors.txt created"    || fail "errors.txt not created"
[ -s "$BRIEFING" ]   && pass "briefing.md non-empty"  || fail "briefing.md is empty"

# ---------------------------------------------------------------------------
# Metadata section — all 7 fields
# ---------------------------------------------------------------------------
grep -q "^## Metadata"      "$BRIEFING" && pass "## Metadata section present"    || fail "## Metadata missing"
grep -q "^MAX_TURNS:"       "$BRIEFING" && pass "MAX_TURNS present"              || fail "MAX_TURNS missing"
grep -q "^TIMEOUT:"         "$BRIEFING" && pass "TIMEOUT present"                || fail "TIMEOUT missing"
grep -q "^FILE_COUNT:"      "$BRIEFING" && pass "FILE_COUNT present"             || fail "FILE_COUNT missing"
grep -q "^REPO_TIER:"       "$BRIEFING" && pass "REPO_TIER present"              || fail "REPO_TIER missing"
grep -q "^TEST_COMMAND:"    "$BRIEFING" && pass "TEST_COMMAND present"           || fail "TEST_COMMAND missing"
grep -q "^MENTIONED_FILES:" "$BRIEFING" && pass "MENTIONED_FILES present"        || fail "MENTIONED_FILES missing"
grep -q "^ERROR_COUNT:"     "$BRIEFING" && pass "ERROR_COUNT present"            || fail "ERROR_COUNT missing"

tier="$(grep '^REPO_TIER:' "$BRIEFING" | awk '{print $2}')"
case "$tier" in
  XS|S|M|L) pass "REPO_TIER is valid enum (${tier})" ;;
  *)         fail "REPO_TIER invalid: '${tier}'"      ;;
esac

fc="$(grep '^FILE_COUNT:' "$BRIEFING" | awk '{print $2}')"
[[ "$fc" =~ ^[0-9]+$ ]] && pass "FILE_COUNT is numeric (${fc})" || fail "FILE_COUNT not numeric: '${fc}'"

# ---------------------------------------------------------------------------
# TEST_COMMAND — detected from pytest.ini
# ---------------------------------------------------------------------------
grep -q "^TEST_COMMAND: pytest" "$BRIEFING" \
  && pass "TEST_COMMAND correctly detected as pytest" \
  || fail "TEST_COMMAND should be pytest, got: $(grep '^TEST_COMMAND:' "$BRIEFING" || true)"

# ---------------------------------------------------------------------------
# Collector sections present
# ---------------------------------------------------------------------------
grep -q "^## Git History"       "$BRIEFING" && pass "## Git History present"       || fail "## Git History missing"
grep -q "^## Dependencies"      "$BRIEFING" && pass "## Dependencies present"      || fail "## Dependencies missing"
grep -q "^## Error Sources"     "$BRIEFING" && pass "## Error Sources present"     || fail "## Error Sources missing"
grep -q "^## Test Mapping"      "$BRIEFING" && pass "## Test Mapping present"      || fail "## Test Mapping missing"
grep -q "^## Briefing Warnings" "$BRIEFING" && pass "## Briefing Warnings present" || fail "## Briefing Warnings missing"

# ---------------------------------------------------------------------------
# Error extraction — multi-word string preserved
# ---------------------------------------------------------------------------
[ -s "$ERRORS_TXT" ] \
  && pass "errors.txt non-empty" \
  || fail "errors.txt empty — no quoted strings extracted"

grep -qF "TypeError: discount_value not found" "$ERRORS_TXT" \
  && pass "Double-quoted multi-word string preserved intact in errors.txt" \
  || fail "Double-quoted multi-word string not preserved in errors.txt"

# Backtick-quoted strings must also be extracted
grep -qF "discount_value" "$ERRORS_TXT" \
  && pass "Backtick-quoted string extracted into errors.txt" \
  || fail "Backtick-quoted string not extracted — briefing.sh backtick regex missing"

# ---------------------------------------------------------------------------
# Tracked file accepted — untracked file rejected
# ---------------------------------------------------------------------------
mf="$(grep '^MENTIONED_FILES:' "$BRIEFING" | sed 's/^MENTIONED_FILES: //')"
echo "$mf" | grep -qF "src/cart/pricing.py" \
  && pass "Tracked file src/cart/pricing.py accepted in MENTIONED_FILES" \
  || fail "Tracked file src/cart/pricing.py missing from MENTIONED_FILES"

echo "$mf" | grep -qF "src/cart/untracked.py" \
  && fail "Untracked file src/cart/untracked.py should be rejected but appeared in MENTIONED_FILES" \
  || pass "Untracked file src/cart/untracked.py correctly rejected"

# ---------------------------------------------------------------------------
# Error Sources — finds match in source file, NOT in bug.md
# ---------------------------------------------------------------------------
# pricing.py contains "discount_value" so errors.sh should find it there
grep -qF "pricing.py" "$BRIEFING" \
  && pass "Error Sources found match in src/cart/pricing.py" \
  || fail "Error Sources did not find match in src/cart/pricing.py"

# bug.md must NOT appear as evidence in Error Sources
# (it's the input, not evidence)
if grep -q "## Error Sources" "$BRIEFING"; then
  # Extract the Error Sources section and check for bug.md reference
  error_section="$(awk '/^## Error Sources/,/^## [A-Z]/' "$BRIEFING" | head -30)"
  if printf '%s\n' "$error_section" | grep -qF "bug.md"; then
    fail "bug.md should not appear as evidence in Error Sources"
  else
    pass "bug.md correctly excluded from Error Sources evidence"
  fi
fi

# ---------------------------------------------------------------------------
# Source → Test mapping
# ---------------------------------------------------------------------------
grep -qF "src/cart/pricing.py -> tests/test_pricing.py" "$BRIEFING" \
  && pass "src/cart/pricing.py correctly mapped to tests/test_pricing.py" \
  || fail "src/cart/pricing.py not mapped to test file"

# ---------------------------------------------------------------------------
# Dangerous paths rejected
# ---------------------------------------------------------------------------
POISON_BUG="${_TEST_BASE}/poison_bug.md"
cat > "$POISON_BUG" <<'BUGEOF'
Error in /etc/passwd and ../../../etc/shadow and .env and id_rsa
Also check src/cart/untracked.py which is not tracked.
BUGEOF
export BUG_FILE="$POISON_BUG"
B4="${TMPDIR_RUN}/briefing4.md"; E4="${TMPDIR_RUN}/errors4.txt"
export BRIEFING="$B4" ERRORS_TXT="$E4"

bash "${TOOL_ROOT}/scripts/briefing.sh" 2>/dev/null \
  && pass "Dangerous-path bug does not crash" \
  || fail "Dangerous-path bug crashed"

grep -q "/etc/passwd" "$B4" 2>/dev/null \
  && fail "Absolute path /etc/passwd should be rejected" \
  || pass "Absolute path /etc/passwd correctly rejected"

mf4="$(grep '^MENTIONED_FILES:' "$B4" || true)"
printf '%s\n' "$mf4" | grep -q '\.env' \
  && fail ".env should be rejected" \
  || pass ".env correctly rejected"

# ---------------------------------------------------------------------------
# Empty bug report — no crash
# ---------------------------------------------------------------------------
EMPTY_BUG="${_TEST_BASE}/empty_bug.md"
touch "$EMPTY_BUG"
export BUG_FILE="$EMPTY_BUG"
B5="${TMPDIR_RUN}/briefing5.md"; E5="${TMPDIR_RUN}/errors5.txt"
export BRIEFING="$B5" ERRORS_TXT="$E5"

bash "${TOOL_ROOT}/scripts/briefing.sh" 2>/dev/null \
  && pass "Empty bug report does not crash" \
  || fail "Empty bug report crashed"

[ -f "$B5" ] && pass "briefing.md created for empty bug" || fail "briefing.md not created for empty bug"
[ -f "$E5" ] && pass "errors.txt created for empty bug"  || fail "errors.txt not created for empty bug"
[ -s "$E5" ] \
  && fail "errors.txt should be empty for empty bug but has content" \
  || pass "errors.txt empty for empty bug"

# ---------------------------------------------------------------------------
# Non-git directory — filesystem fallback
# ---------------------------------------------------------------------------
NONGIT="${_TEST_BASE}/nongit"
mkdir -p "${NONGIT}/lib"
printf 'def foo(): pass\n' > "${NONGIT}/lib/utils.py"
NONGIT_BUG="${_TEST_BASE}/nongit_bug.md"
printf 'Error in lib/utils.py: "SomeError occurred"\n' > "$NONGIT_BUG"

export TARGET_REPO_ROOT="$NONGIT"
export BUG_FILE="$NONGIT_BUG"
B6="${TMPDIR_RUN}/briefing6.md"; E6="${TMPDIR_RUN}/errors6.txt"
export BRIEFING="$B6" ERRORS_TXT="$E6"

bash "${TOOL_ROOT}/scripts/briefing.sh" 2>/dev/null \
  && pass "Non-git repo does not crash" \
  || fail "Non-git repo crashed"

mf6="$(grep '^MENTIONED_FILES:' "$B6" || true)"
printf '%s\n' "$mf6" | grep -qF "lib/utils.py" \
  && pass "Filesystem fallback accepts existing file in non-git repo" \
  || fail "Filesystem fallback did not accept lib/utils.py in non-git repo"

# Restore for any later sections
export TARGET_REPO_ROOT="$TINY_REPO"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
