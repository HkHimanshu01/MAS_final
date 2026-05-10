# Development Guide

How to work on this codebase: add collectors, modify prompts, edit schemas, change report sections, debug runs, and keep tests passing.

---

## Before You Change Anything

Run the test suite to confirm your baseline is green:

```bash
cd rca-mas/
make lint    # bash -n syntax check on all scripts
make test    # all 4 test suites, no Claude required
```

Both must pass before and after every change. See [testing-guide.md](testing-guide.md) for full test documentation.

---

## Adding a Collector

Collectors are standalone bash scripts in `scripts/collectors/`. Each appends a section to `briefing.md`.

**Steps:**

1. Create `scripts/collectors/myname.sh`:

```bash
#!/usr/bin/env bash
# collectors/myname.sh — brief description
set -Eeuo pipefail

# Required env vars (set by briefing.sh before calling you):
# TARGET_REPO_ROOT, MENTIONED_FILES, TOOL_ROOT, RUN_DIR

printf '\n## My Section\n' >> "$BRIEFING"

# Do your work, append output
# Keep output concise — Agent 1 reads everything in briefing.md

printf '(done)\n' >> "$BRIEFING"
```

2. Register it in `scripts/briefing.sh` Phase 5 alongside the other collectors:

```bash
# In the collectors loop:
run_collector "myname" "${TOOL_ROOT}/scripts/collectors/myname.sh"
```

3. Add a section header check to `tests/test_briefing.sh`:

```bash
grep -q "^## My Section" "$BRIEFING" || fail "My Section missing from briefing"
```

4. Run `make test` to verify.

**Rules for collectors:**
- Never crash. All failures must be caught and written to `BRIEFING_WARNINGS`.
- Always write a section header (`## Section Name`) even if the section body is empty.
- Never write more than ~100 lines per section. Agent 1 reads everything.
- Use `timeout $RCA_COLLECTOR_TIMEOUT` — the orchestrator already wraps each collector, but internal operations should also respect timeouts.
- Never read credential files (`.env`, `.pem`, `.key`, etc.).

---

## Modifying a Prompt

Prompts live in `prompts/`. Each is a markdown file passed to Claude Code as the system prompt.

**What each prompt must contain:**
1. Role definition — what this agent is and what it must produce
2. Input description — exactly what files it has access to
3. Output format — the exact JSON schema it must emit
4. Security block — explicit instruction to treat bug.md as untrusted data
5. Output discipline block — what NOT to do (no partial commits, no self-modifying, etc.)

**After editing a prompt:**
- Run `make test` — smoke tests validate agent outputs against schemas
- Run `make run` — end-to-end with the example bug to confirm nothing breaks
- If changing output format, update the corresponding schema too (see below)

**Never:**
- Remove the security block from a prompt
- Tell an agent it can write to the target repo
- Give Agent 2 access to the raw repo (it must work only from diagnosis.json)

---

## Editing a Schema

Schemas live in `schemas/`. They define the JSON that each agent must emit.

**Steps:**

1. Edit the relevant schema file (`diagnosis.schema.json`, `solution.schema.json`, or `validation.schema.json`)
2. Update the corresponding prompt so the agent knows the new field
3. Update the orchestrator (`rca-mas.sh`) if it references the changed field
4. Update `report.md` assembly if a new field should appear in the report
5. Update `docs/schemas.md` (this file) with the new field
6. Run `make test` — `tests/test_json_schemas.sh` validates all schemas

**Adding a required field:** bump it as optional first, ship, then make it required in a follow-up. This avoids breaking existing run directories.

---

## Changing Report Sections

The report is assembled by the orchestrator (`rca-mas.sh`) from the three JSON files. All 11 sections are mandatory — if data is missing, the section must still appear with a fallback value like `UNKNOWN` or `SKIPPED`.

To add a section:
1. Add it to the assembly logic in `rca-mas.sh`
2. Add it to the section list in `tests/test_smoke_report_only.sh`
3. Add it to `examples/sample-report.md`
4. Update `docs/run-artifacts.md` if a new artifact backs the section

To remove a section: the same set of files must be updated, and the section must appear in the `## Next Action` report block telling developers it was removed.

---

## Tuning Parameters

All tunable parameters are in `config/defaults.env`. Never hardcode a number that appears in `defaults.env` anywhere else in the codebase.

**To change a default:** edit `defaults.env`. Every script that needs the value already sources it.

**To test a parameter change without editing defaults:** set the env var before running:

```bash
RCA_TURNS_S=30 RCA_TIMEOUT_S=360 bash rca-mas.sh bug.md
```

**Parameter naming convention:** `RCA_` prefix, category, name in SCREAMING_SNAKE_CASE.

---

## Debugging a Run

### Briefing problems

```bash
# Run briefing alone against a bug file
TARGET_REPO_ROOT=. \
  RUN_DIR=/tmp/debug-run \
  BRIEFING=/tmp/debug-run/briefing.md \
  ERRORS_TXT=/tmp/debug-run/errors.txt \
  LOG_FILE=/tmp/debug-run/log.jsonl \
  BUG_FILE=path/to/bug.md \
  bash scripts/briefing.sh

cat /tmp/debug-run/briefing.md
cat /tmp/debug-run/errors.txt
```

### Collector problems

Run a single collector directly:

```bash
TARGET_REPO_ROOT=/path/to/repo \
  MENTIONED_FILES="src/foo.py" \
  ERRORS_TXT=/tmp/errors.txt \
  BRIEFING=/tmp/briefing.md \
  bash scripts/collectors/errors.sh
```

### Agent output problems

If an agent produced bad JSON or wrong content:

```bash
# See raw output before schema validation
cat .rca-mas/runs/latest/raw_agent1_output.txt

# See all log events including warnings
cat .rca-mas/runs/latest/log.jsonl | jq .

# Check which fields are missing
jq 'keys' .rca-mas/runs/latest/diagnosis.json
```

### Keeping the worktree for patch debugging

```bash
RCA_KEEP_WORKTREE=1 bash rca-mas.sh bug.md --validate
# Worktree stays at: ../.rca-mas-worktrees/<RUN_ID>/
# Inspect manually, then remove:
git worktree remove --force ../.rca-mas-worktrees/<RUN_ID>
```

---

## Keeping Docs in Sync

When you change behavior, update the relevant doc:

| Change | Docs to update |
|---|---|
| New collector | `docs/briefing-and-collectors.md`, `docs/pipeline-flow.md` |
| New schema field | `docs/schemas.md` |
| New run artifact | `docs/run-artifacts.md` |
| New CLI flag or env var | `docs/cli-reference.md` |
| New agent | `docs/agent-contracts.md`, `docs/architecture.md`, `docs/pipeline-flow.md` |
| Security change | `docs/security-model.md` |
| Architecture decision | `docs/decisions.md` |

The `docs/index.md` table of contents is stable — only update it if you add or remove a doc file.

---

## File Naming Conventions

| Type | Convention | Example |
|---|---|---|
| Scripts | lowercase with hyphens | `briefing.sh`, `testrunner.sh` |
| Config vars | `RCA_` prefix, SCREAMING_SNAKE | `RCA_TURNS_S` |
| Schema files | `<name>.schema.json` | `diagnosis.schema.json` |
| Run artifacts | lowercase with underscores | `diagnosis.json`, `raw_agent1_output.txt` |
| Collector outputs in briefing | `## Title Case` headers | `## Git History` |
| Test files | `test_<name>.sh` | `test_briefing.sh` |

---

## Adding Tests

Tests live in `tests/`. Every new behavior needs a test.

- **Briefing logic:** `tests/test_briefing.sh` — assertions using a tiny controlled git repo
- **Individual collectors:** `tests/test_collectors.sh`
- **Schema validity:** `tests/test_json_schemas.sh`
- **End-to-end pipeline:** `tests/test_smoke_report_only.sh` — uses fixture JSON, no Claude
- **Real GitHub bugs:** `tests/test_real_repo_briefing.sh` — requires `test-repos/click/` clone

All tests follow the same pattern:

```bash
pass() { printf '  [PASS] %s\n' "$1"; (( PASS++ )) || true; }
fail() { printf '  [FAIL] %s\n' "$1"; (( FAIL++ )) || true; }
# ...
[ "$FAIL" -eq 0 ] || exit 1
```

See [testing-guide.md](testing-guide.md) for complete instructions.
