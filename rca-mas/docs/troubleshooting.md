# Troubleshooting

Symptoms, likely causes, and exact fix steps for common failures.

---

## Briefing Problems

### `briefing.md` is empty or missing

**Symptom:** Run completes but `briefing.md` is 0 bytes or absent.

**Causes and fixes:**
1. `BUG_FILE` not set or points to wrong path → check that `rca-mas.sh` received the correct bug file argument
2. `TARGET_REPO_ROOT` is wrong → confirm you `cd`'d into the target repo before running
3. Script exited early due to permission error → check `log.jsonl` for ERROR-level events

```bash
cat .rca-mas/runs/latest/log.jsonl | jq 'select(.level=="error")'
```

---

### `TEST_COMMAND: UNKNOWN` in briefing.md

**Symptom:** Briefing completes but `TEST_COMMAND` is `UNKNOWN`.

**Causes and fixes:**
1. No test framework config file found → the target repo uses an unconventional test setup; manually set `TEST_COMMAND` in briefing.md before running agents, or add detection logic to `collectors/testrunner.sh`
2. `testrunner.sh` timed out → check `## Briefing Warnings` section in briefing.md; increase `RCA_COLLECTOR_TIMEOUT`

```bash
grep "TEST_COMMAND\|Briefing Warnings" .rca-mas/runs/latest/briefing.md
```

---

### `MENTIONED_FILES: (none)` when bug report mentions files

**Symptom:** Briefing runs fine but no files appear in `MENTIONED_FILES`.

**Causes and fixes:**
1. The file mentioned in the bug report is not git-tracked (e.g. it's a user's script, not repo code) → expected behavior; Agent 1 will find the file via Grep instead
2. The file has an unrecognised extension → add the extension to the allowed list in `briefing.sh` Phase 2
3. The file path in the bug report uses Windows-style backslashes → briefing.sh uses POSIX regex; convert to forward slashes in the bug report

---

### Collector warnings in briefing

**Symptom:** `## Briefing Warnings` section lists one or more collector failures.

```
## Briefing Warnings
- collector git: timeout after 30s
- collector deps: exit 1
```

**For timeout:**
- Increase `RCA_COLLECTOR_TIMEOUT` (default 30s): `RCA_COLLECTOR_TIMEOUT=60 bash rca-mas.sh bug.md`
- On Windows/MSYS2, collector startup is slow. 60s is a reasonable value for large repos.

**For non-zero exit:**
- Run the collector directly to see the error:

```bash
TARGET_REPO_ROOT=/path/to/repo \
  MENTIONED_FILES="src/foo.py" \
  ERRORS_TXT=/tmp/errors.txt \
  BRIEFING=/tmp/b.md \
  bash scripts/collectors/deps.sh
```

---

## Agent Problems

### `diagnosis.json` has `confidence: 0.4` and capped

**Symptom:** Agent 1b produced a diagnosis but confidence is exactly 0.4.

**Cause:** The orchestrator caps confidence at 0.4 whenever `agent1a_quality` is `weak` or `failed` (see `agent1a_quality.env`). The diagnosis itself may still be high quality — Claude returned 0.8+ — but the cap is applied because the upstream evidence was thin.

**Action:**

```bash
# See why quality was weak:
cat .rca-mas/runs/latest/agent1a_quality.env
grep "quality gate" .rca-mas/runs/latest/log.jsonl | jq -r '.msg'

# See the actual checkpoint shape passed to Agent 1b:
grep "checkpoint shape" .rca-mas/runs/latest/log.jsonl | jq -r '.info // .msg'
```

If the quality was weak due to a hard bug, options:

1. Bump turn budget: `RCA_A1A_TURNS_S=40 bash rca-mas.sh bug.md`
2. Try Opus: `RCA_MODEL=claude-opus-4-7 bash rca-mas.sh bug.md`

---

### `diagnosis.json` has `confidence: 0.0` and `root_cause: "Agent 1b failed to produce valid diagnosis..."`

**Symptom:** The placeholder fail-closed diagnosis. Agent 1b could not produce a schema-valid response, even after one repair attempt.

**Cause:** Either (a) the checkpoint was a degraded seed (Agent 1a write phase failed — Claude returned no valid JSON), or (b) Agent 1b's Claude call returned output that could not be normalised or validated, and the repair attempt also failed.

**Investigation:**

```bash
RUN=.rca-mas/runs/latest

# What did Agent 1a hand to 1b?
jq '._degraded_seed // false' $RUN/checkpoint.json
jq 'keys' $RUN/checkpoint.json

# Agent 1b meta tells you the failure mode:
cat $RUN/agent1b_meta.env

# Look at the invalid output if it was preserved:
cat $RUN/diagnosis.invalid.json 2>/dev/null || echo "no invalid file"
cat $RUN/diagnosis.invalid.txt 2>/dev/null

# Was the raw output even non-empty?
wc -c $RUN/agent1b_raw.json
```

**Fixes:**

1. If `_degraded_seed=true`, Agent 1a's write phase failed. Re-run with `RCA_MODEL=claude-opus-4-7` for a more deterministic JSON writer.
2. If `agent1b_raw.json` is empty, the Claude call timed out or hit a rate limit. Re-run.
3. If `agent1b_raw.json` is non-empty but validation failed, inspect `diagnosis.invalid.txt` for the schema error and consider whether the prompt or schema needs adjustment.

---

### `solution.json` has `status: NO_FIX`

**Symptom:** Agent 2 refused to produce a patch.

**Cause:** `diagnosis.json` confidence was below `RCA_CONFIDENCE_NOFX` (default 0.5). This is intentional — a bad patch is worse than no patch.

**Fix:** The diagnosis quality is insufficient. Options:
1. Review `diagnosis.json` manually. If the root cause looks correct despite the low score, you can lower the threshold: `RCA_CONFIDENCE_NOFX=0.35 bash rca-mas.sh bug.md`
2. Add more context to the bug report and re-run
3. Switch to `claude-opus-4-7` for better diagnosis quality

```bash
jq '{status, confidence, root_cause}' .rca-mas/runs/latest/diagnosis.json
```

---

### Agent output is not valid JSON

**Symptom:** `jq` errors on `diagnosis.json` or schema validation fails.

**Cause:** Claude produced text that `extract_normalize_json` could not parse.

**Fix:**

1. Check the raw Agent 1b output:

   ```bash
   cat .rca-mas/runs/latest/agent1b_raw.json | jq '.'
   ```

2. The extractor handles: `.structured_output` (object or stringified), `.result` (object or stringified), fenced markdown, and raw top-level objects. If none of those match (e.g. the response is pure prose), the orchestrator runs one repair pass with `prompts/agent1b_repair.md`. Check `agent1b_repair_raw.json` if present.
3. If both attempts failed, see the "Agent 1b failed to produce valid diagnosis" section above.

---

## Patch / Validation Problems

### `validation.json` has `status: ERROR` (patch didn't apply)

**Symptom:** Agent 2.5 could not apply the patch.

**Causes and fixes:**
1. Base commit mismatch — the patch was written against a different version of the file → re-run the full pipeline from scratch against the current HEAD
2. Patch format issue — check the diff:
   ```bash
   cat .rca-mas/runs/latest/patches/*.diff
   git apply --check .rca-mas/runs/latest/patches/*.diff
   ```
3. File path in patch is wrong → inspect `raw_agent2_output.txt` and manually edit the diff header

---

### `validation.json` has `status: FAIL` (tests failed)

**Symptom:** Patch applied cleanly but tests failed.

**This is expected information, not a tool failure.** The patch is likely incomplete or wrong. Options:
1. Read `test_output_summary` in `validation.json` to see which tests failed
2. Keep the worktree to investigate: `RCA_KEEP_WORKTREE=1 bash rca-mas.sh bug.md --validate`
3. The patch is a starting point — apply it manually, fix the remaining failures, and commit

```bash
jq '{status, test_command, test_output_summary}' .rca-mas/runs/latest/validation.json
```

---

## Test Suite Problems

### `make test` fails on `test_briefing.sh`

```bash
bash tests/test_briefing.sh 2>&1 | grep FAIL
```

Common causes:
- Briefing logic changed without updating the test assertions
- `git` not available in PATH
- Temp directory from previous failed test not cleaned up: `rm -rf /tmp/rca-mas-test-*`

### `make lint` fails

```bash
bash -n scripts/briefing.sh
```

Run `bash -n` on each script until you find the syntax error.

---

## Platform-Specific

### Windows / MSYS2: collectors are slow

Briefing takes 15–30s on Windows due to bash and git process startup overhead. This is expected. Increase `RCA_COLLECTOR_TIMEOUT`:

```bash
RCA_COLLECTOR_TIMEOUT=60 bash rca-mas.sh bug.md
```

### Windows: `latest` symlink not found

Windows may not support symlinks without developer mode. Check:

```powershell
ls .rca-mas\runs\
```

If `latest` is a file rather than a symlink, the orchestrator fell back to writing `latest` as a text file containing the RUN_ID. Read it with:

```bash
cat .rca-mas/runs/latest
# Then read the actual run:
cat .rca-mas/runs/$(cat .rca-mas/runs/latest)/report.md
```

---

## Reading the Log

`log.jsonl` is the most complete record of what happened:

```bash
# All events, formatted
cat .rca-mas/runs/latest/log.jsonl | jq .

# Warnings only
cat .rca-mas/runs/latest/log.jsonl | jq 'select(.level == "warn")'

# Timeline of stages
cat .rca-mas/runs/latest/log.jsonl | jq '{ts, stage, msg}'

# How long each stage took
cat .rca-mas/runs/latest/log.jsonl | jq 'select(.duration_seconds != null) | {stage, duration_seconds}'
```
