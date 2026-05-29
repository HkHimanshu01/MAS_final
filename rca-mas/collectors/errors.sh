#!/usr/bin/env bash
# collectors/errors.sh — Single-pass fixed-string search across the target repo.
# Scans once with rg (preferred) or git grep (fallback); separates source hits from
# doc/test noise; ranks and caps source hits before writing to briefing.md.
#
# Inputs (env vars set by briefing.sh):
#   ERRORS_TXT          — path to file with one error string per line (pre-extracted)
#   TARGET_REPO_ROOT    — absolute path to repo being analysed
#   BUG_SOURCE_FILE     — absolute path to original bug.md (excluded from results)
#   RCA_ERROR_GREP_LIMIT — max source hits to show (default 80)
#
# Output: Markdown to stdout under ## Error Sources heading.
# Failure: exits 0. Never crashes the pipeline.
set -Eeuo pipefail
IFS=$'\n\t'

printf '## Error Sources\n\n'

MAX_HITS="${RCA_ERROR_GREP_LIMIT:-80}"
MAX_LINES_PER_FILE=10

# --- Guard: nothing to search ---
if [ ! -s "${ERRORS_TXT:-}" ]; then
  printf '### Search: (none)\n(no quoted strings extracted from bug report)\n\n'
  exit 0
fi

if [ ! -d "${TARGET_REPO_ROOT:-}" ]; then
  printf '(repo path not found — collector skipped)\n\n'
  exit 0
fi

# --- Temp dir ---
_tmp="$(mktemp -d)"
_src_hits="${_tmp}/src.txt"
_doc_hits="${_tmp}/doc.txt"
_tst_hits="${_tmp}/tst.txt"
: > "$_src_hits"; : > "$_doc_hits"; : > "$_tst_hits"
cleanup() { rm -rf "$_tmp"; }
trap cleanup EXIT

# --- Bug file exclusion patterns (forward-slash and backslash variants) ---
_bug_pat1="" _bug_pat2=""
if [ -n "${BUG_SOURCE_FILE:-}" ]; then
  _bug_basename="$(basename "$BUG_SOURCE_FILE")"
  _bug_dir="$(basename "$(dirname "$BUG_SOURCE_FILE")")"
  _bug_pat1="${_bug_dir}/${_bug_basename}"
  _bug_pat2="$(printf '%s\\%s' "$_bug_dir" "$_bug_basename")"
fi

_exclude_bug() {
  if [ -n "$_bug_pat1" ]; then
    grep -vF -e "$_bug_pat1" -e "$_bug_pat2" || true
  else
    cat
  fi
}

cd "$TARGET_REPO_ROOT"

# --- Choose backend ---
if command -v rg > /dev/null 2>&1; then
  _backend="rg"
elif git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  _backend="git-grep"
else
  printf '(neither rg nor git grep available — collector skipped)\n\n'
  exit 0
fi

# Source excludes: no docs, tests, lockfiles, build artifacts, virtualenvs
_RG_SRC_EXCLUDES=(
  --glob '!.git/**'
  --glob '!.rca-mas/**'
  --glob '!rca-mas/**'
  --glob '!docs/**' --glob '!doc/**'
  --glob '!test/**' --glob '!tests/**' --glob '!testing/**'
  --glob '!*.rst' --glob '!*.md' --glob '!*.txt'
  --glob '!*.lock' --glob '!package-lock.json' --glob '!poetry.lock'
  --glob '!Pipfile.lock' --glob '!yarn.lock' --glob '!pnpm-lock.yaml'
  --glob '!node_modules/**' --glob '!vendor/**'
  --glob '!dist/**' --glob '!build/**' --glob '!target/**'
  --glob '!coverage/**' --glob '!htmlcov/**'
  --glob '!__pycache__/**' --glob '!*.pyc' --glob '!*.min.js' --glob '!*.map'
  --glob '!venv/**' --glob '!.venv/**' --glob '!env/**' --glob '!site-packages/**'
)

_GIT_SRC_EXCLUDES=(
  ':(exclude).git/**' ':(exclude).rca-mas/**' ':(exclude)rca-mas/**'
  ':(exclude)docs/**' ':(exclude)doc/**'
  ':(exclude)test/**' ':(exclude)tests/**' ':(exclude)testing/**'
  ':(exclude)*.rst' ':(exclude)*.md' ':(exclude)*.txt'
  ':(exclude)*.lock' ':(exclude)package-lock.json' ':(exclude)poetry.lock'
  ':(exclude)Pipfile.lock' ':(exclude)yarn.lock' ':(exclude)pnpm-lock.yaml'
  ':(exclude)node_modules/**' ':(exclude)vendor/**'
  ':(exclude)dist/**' ':(exclude)build/**' ':(exclude)target/**'
  ':(exclude)coverage/**' ':(exclude)htmlcov/**'
  ':(exclude)__pycache__/**' ':(exclude)*.pyc' ':(exclude)*.min.js' ':(exclude)*.map'
  ':(exclude)venv/**' ':(exclude).venv/**' ':(exclude)env/**' ':(exclude)site-packages/**'
)

# --- Single scan: source ---
if [ "$_backend" = "rg" ]; then
  rg --fixed-strings --ignore-case --line-number --no-heading \
    "${_RG_SRC_EXCLUDES[@]}" \
    -f "$ERRORS_TXT" . 2>/dev/null \
    | _exclude_bug \
    > "$_src_hits" || true
else
  git grep -F -i -n -f "$ERRORS_TXT" -- . "${_GIT_SRC_EXCLUDES[@]}" 2>/dev/null \
    | _exclude_bug \
    > "$_src_hits" || true
fi

# --- Single scan: docs (counted, not shown) ---
if [ "$_backend" = "rg" ]; then
  rg --fixed-strings --ignore-case --line-number --no-heading \
    --glob 'docs/**' --glob 'doc/**' \
    --glob '*.rst' --glob '*.md' --glob '*.txt' \
    -f "$ERRORS_TXT" . 2>/dev/null \
    | _exclude_bug \
    > "$_doc_hits" || true
else
  git grep -F -i -n -f "$ERRORS_TXT" -- \
    'docs/**' 'doc/**' '*.rst' '*.md' '*.txt' 2>/dev/null \
    | _exclude_bug \
    > "$_doc_hits" || true
fi

# --- Single scan: tests (counted, not shown) ---
if [ "$_backend" = "rg" ]; then
  rg --fixed-strings --ignore-case --line-number --no-heading \
    --glob 'test/**' --glob 'tests/**' --glob 'testing/**' \
    -f "$ERRORS_TXT" . 2>/dev/null \
    | _exclude_bug \
    > "$_tst_hits" || true
else
  git grep -F -i -n -f "$ERRORS_TXT" -- \
    'test/**' 'tests/**' 'testing/**' 2>/dev/null \
    | _exclude_bug \
    > "$_tst_hits" || true
fi

_src_total="$(wc -l < "$_src_hits" | tr -d ' ')"
_doc_total="$(wc -l < "$_doc_hits" | tr -d ' ')"
_tst_total="$(wc -l < "$_tst_hits" | tr -d ' ')"

# --- Rank source hits: prefer src/ paths and error-handling lines ---
_ranked="${_tmp}/ranked.txt"
awk -F: '
  {
    score = 500
    path = $1
    content = $0
    if (path ~ /\.(py|js|ts|tsx|jsx|go|rs|java|kt|rb|php|c|cc|cpp|h|cs|swift)$/) score += 100
    if (path ~ /[\/\\](src|lib|core|pkg|internal)[\/\\]/)                         score += 80
    if (content ~ /(raise |throw |return |assert |panic\(|fail\(|except |catch )/) score += 60
    if (path ~ /(error|exception|handler|parser|validator|processor)/)             score += 30
    if (path ~ /(example|sample|fixture|mock|stub|fake)/)                          score -= 50
    printf "%06d:%s\n", (999999 - score), $0
  }
' "$_src_hits" \
  | sort \
  | cut -d: -f2- \
  | awk -F: -v cap="$MAX_LINES_PER_FILE" 'count[$1]++ < cap' \
  | head -n "$MAX_HITS" \
  > "$_ranked"

_shown="$(wc -l < "$_ranked" | tr -d ' ')"

# --- Also emit method definition hits (existing behaviour preserved) ---
# For each search term that looks like obj.method, show def <method> in src/.
_def_out="${_tmp}/defs.txt"
: > "$_def_out"
while IFS= read -r str; do
  [ -z "$str" ] && continue
  if printf '%s' "$str" | grep -qE '^\w+\.\w+$' && [ -d "${TARGET_REPO_ROOT}/src" ]; then
    _method="$(printf '%s' "$str" | sed 's/.*\.//')"
    if [ "$_backend" = "rg" ]; then
      rg --fixed-strings --line-number --no-heading \
        --glob '!.git/**' --glob '!.rca-mas/**' \
        -- "def ${_method}" src/ 2>/dev/null | head -10 \
        >> "$_def_out" || true
    else
      git grep -F -n -- "def ${_method}" -- src/ 2>/dev/null | head -10 \
        >> "$_def_out" || true
    fi
  fi
done < "$ERRORS_TXT"

# --- Output ---
_pattern_count="$(wc -l < "$ERRORS_TXT" | tr -d ' ')"

printf '### Summary\n\n'
printf -- '- Backend: %s\n'              "$_backend"
printf -- '- Patterns searched: %s\n'   "$_pattern_count"
printf -- '- Source hits found: %s\n'   "$_src_total"
printf -- '- Source hits shown: %s\n'   "$_shown"
printf -- '- Suppressed doc hits: %s\n' "$_doc_total"
printf -- '- Suppressed test hits: %s\n' "$_tst_total"
printf '\n'

printf '### Patterns searched\n\n'
while IFS= read -r _str; do
  [ -z "$_str" ] && continue
  printf '### Search: %s\n' "$_str"
done < "$ERRORS_TXT"
printf '\n'

printf '### Source hits\n\n'
if [ "$_shown" = "0" ]; then
  printf '(no matches outside bug report)\n'
else
  cat "$_ranked"
fi
printf '\n'

if [ -s "$_def_out" ]; then
  printf '### Definition hits (src/)\n\n'
  cat "$_def_out"
  printf '\n'
fi

if [ "$(( _doc_total + _tst_total ))" -gt 0 ]; then
  printf '### Suppressed low-signal hits\n\n'
  printf -- '- Docs / rst / markdown: %s\n' "$_doc_total"
  printf -- '- Tests and fixtures: %s\n'    "$_tst_total"
  printf '\n'
fi
