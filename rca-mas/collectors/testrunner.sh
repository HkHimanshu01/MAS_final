#!/usr/bin/env bash
# collectors/testrunner.sh — Detect test command; map mentioned src files to test files.
# Inputs: MENTIONED_FILES (space-sep), TARGET_REPO_ROOT.
# Outputs: Markdown section to stdout (includes TEST_COMMAND: line).
# Failure: exits 0. Never runs tests — detection only.
set -Eeuo pipefail
IFS=$'\n\t'

printf '## Test Mapping\n\n'

TEST_CMD="UNKNOWN"

# --- Detect test runner ---
# Python
if [ -f "${TARGET_REPO_ROOT}/pytest.ini" ] \
|| [ -f "${TARGET_REPO_ROOT}/pyproject.toml" ] \
|| [ -f "${TARGET_REPO_ROOT}/setup.cfg" ]; then
  if   [ -f "${TARGET_REPO_ROOT}/poetry.lock" ]; then TEST_CMD="poetry run pytest"
  elif command -v uv > /dev/null 2>&1 \
    && [ -f "${TARGET_REPO_ROOT}/uv.lock" ];     then TEST_CMD="uv run pytest"
  else                                                TEST_CMD="pytest"
  fi
elif [ -f "${TARGET_REPO_ROOT}/tox.ini" ];        then TEST_CMD="tox"
elif [ -f "${TARGET_REPO_ROOT}/noxfile.py" ];     then TEST_CMD="nox"

# Go
elif [ -f "${TARGET_REPO_ROOT}/go.mod" ];         then TEST_CMD="go test ./..."

# JS/TS — check package.json test script
elif [ -f "${TARGET_REPO_ROOT}/package.json" ]; then
  # vitest / jest check
  if command -v jq > /dev/null 2>&1; then
    test_script="$(jq -r '.scripts.test // empty' \
      "${TARGET_REPO_ROOT}/package.json" 2>/dev/null || true)"
    if [ -n "$test_script" ]; then
      case "$test_script" in
        *vitest*)  TEST_CMD="npx vitest" ;;
        *jest*)    TEST_CMD="npx jest"   ;;
        *)
          if   [ -f "${TARGET_REPO_ROOT}/pnpm-lock.yaml" ]; then TEST_CMD="pnpm test"
          elif [ -f "${TARGET_REPO_ROOT}/yarn.lock" ];       then TEST_CMD="yarn test"
          else                                                    TEST_CMD="npm test"
          fi
          ;;
      esac
    else
      TEST_CMD="npm test"
    fi
  else
    TEST_CMD="npm test"
  fi

# Makefile fallback
elif [ -f "${TARGET_REPO_ROOT}/Makefile" ] \
  && grep -q '^test:' "${TARGET_REPO_ROOT}/Makefile" 2>/dev/null; then
  TEST_CMD="make test"
fi

# Write detected command back for briefing.sh header backfill
[ -n "${TEST_CMD_FILE:-}" ] && printf '%s\n' "$TEST_CMD" > "$TEST_CMD_FILE"

printf 'TEST_COMMAND: %s\n\n' "$TEST_CMD"

# --- Map mentioned source files to test files ---
if [ -n "${MENTIONED_FILES:-}" ]; then
  printf '### Source → Test mapping\n'
  for f in $MENTIONED_FILES; do
    base="$(basename "$f")"
    dir="$(dirname "$f")"
    stem="${base%.*}"
    ext="${base##*.}"

    # Convention-based candidates
    candidates=()
    case "$ext" in
      py)
        candidates=(
          "tests/test_${stem}.py"
          "test_${stem}.py"
          "${dir}/test_${stem}.py"
          "tests/${stem}_test.py"
        )
        ;;
      js|ts|jsx|tsx)
        candidates=(
          "${stem}.test.${ext}"
          "${stem}.spec.${ext}"
          "__tests__/${stem}.test.${ext}"
          "__tests__/${stem}.spec.${ext}"
          "${dir}/${stem}.test.${ext}"
        )
        ;;
      go)
        candidates=(
          "${dir}/${stem}_test.go"
        )
        ;;
    esac

    found=""
    for c in "${candidates[@]+"${candidates[@]}"}"; do
      if [ -f "${TARGET_REPO_ROOT}/${c}" ]; then
        found="$c"
        break
      fi
    done

    if [ -n "$found" ]; then
      printf '  %s -> %s\n' "$f" "$found"
    else
      printf '  %s -> (no test file found by convention)\n' "$f"
    fi
  done
  printf '\n'
fi
