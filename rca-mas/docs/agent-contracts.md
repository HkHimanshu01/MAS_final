# Agent Contracts

Defines what each agent does, what it receives, what it is allowed to do, what it must write, and what it must not do.

---

## Agent 1a — Investigation

### Role
Explore the codebase and determine the root cause of the bug described in the bug report. Form competing hypotheses. Gather evidence. Write structured FINAL FINDINGS. Do NOT write files. Do NOT produce checkpoint JSON — that is the checkpoint-write phase's job.

Agent 1a runs without a JSON schema constraint. It uses Read/Grep/Glob/Bash tools to investigate. Every assistant turn must include a FINDINGS LEDGER updating its current hypothesis and evidence. When confidence reaches ≥0.70, it writes a FINAL FINDINGS section and stops using tools.

After Agent 1a, the orchestrator runs forced finalization (no-tool resume), quality gate, optional evidence recovery, and checkpoint writing. This flow guarantees checkpoint.json is always produced — even if Agent 1a hits max_turns mid-tool-use.

### Inputs
| Input | Source | Description |
|---|---|---|
| System prompt + briefing | `RUN_DIR/agent1a_prompt.md` | Assembled by orchestrator: `prompts/investigation.md` + bug report + `briefing.md` + run metadata |
| Repo source files | `TARGET_REPO_ROOT` | Read-only access to full codebase via Read/Grep/Glob/Bash |

The prompt is assembled in `orchestrator.sh` in this order:

1. `prompts/investigation.md` — role, security block, FINDINGS LEDGER rule, investigation policy, FINAL FINDINGS format
2. `## Bug Report` — contents of `bug.md`
3. `## Briefing` — contents of `briefing.md` (metadata, error sources, git history, deps, test mapping)
4. `## Run Metadata` — `RUN_ID`, `TARGET_REPO_ROOT`, `RUN_DIR`, confidence threshold

### Allowed Tools

- **Read** — read any source file in `TARGET_REPO_ROOT`
- **Grep** — search file contents
- **Glob** — list files matching a pattern
- **Bash** — read-only commands: `git log`, `git show`, `git diff`, `git blame`, `git status`, `grep`, `rg`, `find`, `cat`, `wc`, `head`, `tail`, `ls`, `sed`

### Forbidden

- **Write** — Agent 1a must never write any file
- Edit source files in the repository
- Run tests or execute application code
- Network access (`curl`, `wget`, `ssh`)
- Read credential files (`.env`, `.pem`, `.key`, `id_rsa`, etc.)
- Write `checkpoint.json` or `diagnosis.json` — those are downstream phases

### Confidence & Early Stop
Agent 1a tracks confidence in every FINDINGS LEDGER entry. When confidence reaches `RCA_CONFIDENCE_STOP` (default `0.7`), it writes FINAL FINDINGS and stops using tools. max_turns is an emergency cap, not the stopping mechanism.

### Output text format (FINDINGS LEDGER every turn, FINAL FINDINGS at stop)

Every assistant turn must begin with a FINDINGS LEDGER:
```
## FINDINGS LEDGER
- Current hypothesis:
- Evidence found:
- Affected files:
- Confidence:
- Next action:
- Reason for next action:
```

When ready to stop (confidence ≥0.70 or turns exhausted), write:
```
## FINAL FINDINGS

### Root cause
One precise paragraph.

### Affected files
- path:line/function — relevance

### Key evidence
- path:line/function — observed fact

### Alternative considered
Alternative and why less likely.

### Recommended fix
Concrete code-level change.

### Confidence
0.00–1.00
```

### Run artifacts produced
After the orchestrator processes Agent 1a, the run directory contains:

| File | Description |
|---|---|
| `agent1a_output.txt.stream` | Raw stream-json JSONL from claude |
| `agent1a_stderr.txt` | stderr from claude invocation (separate from stream) |
| `agent1a_output.txt` | Extracted assistant text + appended finalization output |
| `agent1a_evidence.txt` | Full evidence transcript: text, tool calls, tool results, result metadata |
| `agent1a_findings.md` | Canonical FINAL FINDINGS — primary checkpoint writer input |
| `agent1a_meta.env` | `session_id=`, `stop_reason=`, `result_subtype=`, `exit_code=` |
| `agent1a_quality.env` | `agent1a_quality=ok\|weak`, `agent1a_finalization=ok\|failed\|skipped`, `agent1a_recovery=ok\|failed\|skipped` |

### stop_reason=tool_use is recoverable
If max_turns is hit mid-tool-use (stop_reason=tool_use), the orchestrator resumes with `--resume <session_id> --tools "" --max-turns 1` and requests FINAL FINDINGS. This is the forced finalization step. stop_reason=tool_use is NOT a pipeline failure.

### Timeout Recovery
If forced finalization fails or session_id is unavailable, the recovery script synthesises findings from the evidence transcript using a no-tools no-resume Claude call. The pipeline never produces zero output.

---

## Agent 1b — Conclusion

### Role
Read the checkpoint written by Agent 1a, synthesise it into the required structured diagnosis JSON, and stop. Do not re-investigate. This phase exists entirely to guarantee that the diagnosis JSON is produced — the investigation is already complete.

Agent 1b runs under `--json-schema` enforcement with a small turn budget (default 5 turns). It reads the checkpoint, reads the bug report, and emits the diagnosis in one structured pass.

### Inputs
| Input | Source | Description |
|---|---|---|
| System prompt + bug report + metadata | `RUN_DIR/agent1b_prompt.md` | Assembled by orchestrator: `prompts/diagnosis.md` + bug report + run metadata (with checkpoint path) |
| Checkpoint | `RUN_DIR/checkpoint.json` | Written by Agent 1a — the investigation's findings |

Agent 1b does **not** receive the full briefing. It works from the checkpoint and bug report only. This keeps its context small and its task focused.

### Allowed Tools

Agent 1b runs with no tools enabled (`--tools ""`). It is a pure synthesis step: read the checkpoint, emit the diagnosis JSON. No Read, no Grep, no Glob, no Bash.

### Forbidden

- Write to any file
- All tools (Read, Grep, Glob, Bash) — Agent 1b is synthesis-only
- Network access
- Read credential files
- Re-investigate beyond what the checkpoint already contains

### Checkpoint contract (data flow from Agent 1a)

The checkpoint that Agent 1a writes (via the checkpoint-write phase) is structured to map 1:1 onto the diagnosis schema. Agent 1b is expected to copy fields through verbatim with minimal transformation. Specifically:

| Checkpoint field | Diagnosis field | Action |
|---|---|---|
| `root_cause` | `root_cause` | Copy verbatim (preferred) |
| `hypothesis` (legacy fallback) | `root_cause` | Copy if `root_cause` is absent |
| `hypotheses[]` | `hypotheses[]` | Copy verbatim with id/summary/supporting_evidence/contradicting_evidence/confidence |
| `selected_hypothesis_id` | `selected_hypothesis_id` | Copy verbatim |
| `affected_files`, `call_chain`, `files_examined`, `unknowns`, `rejected_hypotheses` | same | Copy verbatim |
| `confidence` | `confidence` | Copy, then orchestrator caps at 0.4 if `agent1a_quality` is weak/failed |
| `introducing_commit` | `introducing_commit` | Copy verbatim (string or null) |
| `next_best_action` | `next_best_action` | Copy verbatim |
| `run_id` (from Run Metadata, not checkpoint) | `run_id` | Set to the orchestrator-supplied RUN_ID |
| `supporting_evidence` (top-level) | — | Backup source for `hypotheses[].supporting_evidence` when checkpoint lacks the hypotheses array |

If the checkpoint only has the legacy shape (`hypothesis` singular string + top-level `supporting_evidence`), Agent 1b synthesises exactly one hypothesis with id `"h1"` containing the supporting_evidence and uses `hypothesis` as `root_cause`. See `prompts/diagnosis.md` for the explicit mapping rules.

The orchestrator logs the checkpoint shape (`log.jsonl` event `agent1b checkpoint shape`) so operators can see whether the checkpoint is rich or legacy before diagnosis runs.

### Output
File: `RUN_DIR/diagnosis.json` (schema-validated by `schemas/diagnosis.schema.json`)

```json
{
  "run_id": "1778052942-fed9049",
  "root_cause": "get_error_hint() in the Option class includes envvar in the error message without first checking whether envvar is None. The guard `if self.show_envvar and self.envvar is not None` is missing.",
  "selected_hypothesis_id": "h1",
  "hypotheses": [
    {
      "id": "h1",
      "summary": "Missing None check in get_error_hint() — confirmed by code at core.py:414",
      "supporting_evidence": [
        { "type": "code", "path": "src/click/core.py", "lines": "412-418", "note": "get_error_hint() constructs the error string unconditionally when show_envvar=True" }
      ],
      "contradicting_evidence": [],
      "confidence": 0.82
    }
  ],
  "rejected_hypotheses": [
    { "id": "h2", "reason": "Bug is in error formatting — formatting is correct, problem is upstream" }
  ],
  "affected_files": ["src/click/core.py"],
  "call_chain": ["core.py:Option.type_cast_value()", "core.py:Option.get_error_hint()"],
  "files_examined": ["src/click/core.py", "src/click/_utils.py"],
  "unknowns": [],
  "confidence": 0.82,
  "introducing_commit": null,
  "next_best_action": "Add a None guard at core.py:414 before constructing the error string"
}
```

### Failure handling

Agent 1b is **fail-closed**: if Claude's output cannot be extracted, normalised, or validated against the schema, and a one-shot repair attempt also fails, the orchestrator writes a placeholder diagnosis with `confidence: 0.0` and `root_cause: "Agent 1b failed to produce valid diagnosis. <reason>"`. No diagnosis is fabricated from the checkpoint by bash.

The chain inside Agent 1b stage:

1. Assert checkpoint gates: file exists → valid JSON object → not a `_degraded_seed` → has at least one useful field (`hypothesis`, `root_cause`, `call_chain`, or `files_examined` non-empty). Any gate failure marks the stage `failed` and writes a placeholder diagnosis.
2. Log the checkpoint shape (see `log.jsonl` for `agent1b checkpoint shape` event) so operators see what fields are present before diagnosis runs.
3. Assemble prompt: `prompts/diagnosis.md` + bug report + checkpoint inline + run metadata (RUN_ID, CHECKPOINT_QUALITY, CONFIDENCE_STOP).
4. Call Claude with `--json-schema` enforced and `--max-turns 5`.
5. Extract via `extract_normalize_json` (handles structured_output object/string, .result object/string, raw top-level object, fenced markdown JSON).
6. Stamp `run_id` and cap confidence at 0.4 if `agent1a_quality` was weak or failed.
7. Validate against `diagnosis.schema.json` via `validate_diagnosis_json`.
8. If invalid, run one repair pass with `prompts/agent1b_repair.md` + the prior invalid output + the validation error.
9. Atomic write to `diagnosis.json` only after schema validation passes. On total failure, write the placeholder diagnosis described above.

### Stage statuses

| Value | Meaning |
|---|---|
| `ok` | Diagnosis produced, schema-valid, written atomically |
| `degraded` | Diagnosis produced via repair attempt or after Claude exited non-zero with usable output |
| `failed` | All extraction/validation paths exhausted; placeholder diagnosis written with confidence 0.0 |

---

## Agent 2 — Solution

### Role
Read the diagnosis and produce a concrete fix as a unified diff. Do not re-investigate — the diagnosis is the authority. If the diagnosis confidence is too low, say so explicitly.

### Inputs
| Input | Source | Description |
|---|---|---|
| System prompt | `prompts/agent2.md` | Role, output format, NO_FIX rules, security rules |
| `briefing.md` | `RUN_DIR/briefing.md` | Repo context (for file structure reference) |
| `diagnosis.json` | `RUN_DIR/diagnosis.json` | Root cause, evidence, affected files |

Agent 2 does **not** have access to the raw repo. It works only from what Agent 1 found. The orchestrator inlines both `briefing.md` and `diagnosis.json` into the assembled prompt; Agent 2 receives no tool access.

### Allowed Tools

None — Agent 2 runs as pure synthesis. The system prompt forbids tool use; the orchestrator does not pass `--allowedTools` rules. `--max-turns` is set to 3 (configurable via `RCA_AGENT2_TURNS`) to give Claude headroom for internal thinking turns before emitting the schema-conformant JSON.

### Forbidden

- All tools (Read, Grep, Glob, Bash, Write, Edit)
- Repo inspection of any kind
- Patch application or test execution (those belong to Agent 2.5, optional)
- Network access
- Read credential files

### Decision rule

- `diagnosis.confidence < RCA_CONFIDENCE_NOFX` (default 0.5) → must emit `recommendation: "NO_FIX"`
- Evidence too thin for a safe unified diff → emit `recommendation: "NO_FIX"`
- Otherwise → emit `recommendation: "FIX"` with a valid unified diff

### Weak-evidence handling

The orchestrator computes a `WEAK_EVIDENCE` flag before invoking Claude:

- True when `diagnosis.confidence < RCA_CONFIDENCE_WEAK_THRESHOLD` (default 0.6) **or** `agent1a_quality` was `weak` or `failed`
- Passed into the prompt's Run Metadata along with a human-readable `WEAK_EVIDENCE_REASON`

When `WEAK_EVIDENCE: true`, Agent 2 may still emit FIX, but the prompt instructs it to:

- Set `weak_evidence: true` and populate `weak_evidence_reason` from metadata
- Cap its own `confidence` at 0.5
- Set every `fixes[].risk` to `medium` or `high`
- Add a `manual_review_notes` entry calling out the weak-evidence concern

After Claude returns, the orchestrator **enforces** the `weak_evidence` flag (it overwrites whatever Claude wrote with the orchestrator-computed value via `jq`). The validator then rejects any inconsistency (e.g., `weak_evidence=true` with null `weak_evidence_reason`).

### Output

File: `RUN_DIR/solution.json` (schema-validated by `schemas/solution.schema.json`).
File: `RUN_DIR/patches/fix.diff` (extracted unified diff of the recommended fix, only when `recommendation: "FIX"`).

```json
{
  "run_id": "1778750267-c88f333",
  "recommendation": "FIX",
  "confidence": 0.90,
  "no_fix_reason": null,
  "recommended_fix_id": "fix1",
  "weak_evidence": false,
  "weak_evidence_reason": null,
  "fixes": [
    {
      "id": "fix1",
      "description": "Guard the env-var hint in Option.get_error_hint so it is only appended when self.envvar is not None.",
      "why_this_fixes_root_cause": "Mirrors the help-output path which already guards on envvars being non-empty.",
      "unified_diff": "diff --git a/src/click/core.py b/src/click/core.py\n--- a/src/click/core.py\n+++ b/src/click/core.py\n@@ -2682,7 +2682,7 @@\n-        if self.show_envvar:\n+        if self.show_envvar and self.envvar is not None:\n             result += f\" (env var: '{self.envvar}')\"\n",
      "affected_files": ["src/click/core.py"],
      "risk": "low",
      "expected_tests": ["tests/test_options.py::test_show_envvar"],
      "manual_review_notes": []
    }
  ]
}
```

`NO_FIX` response:

```json
{
  "run_id": "1778741516-c88f333",
  "recommendation": "NO_FIX",
  "confidence": 0.0,
  "no_fix_reason": "Diagnosis confidence 0.35 is below the NO_FIX threshold (0.50). Investigation localised the symptom to src/auth/session.py but could not identify the offending function. Next investigation step: trace caller of validate_session() in src/auth/middleware.py.",
  "recommended_fix_id": null,
  "weak_evidence": true,
  "weak_evidence_reason": "Diagnosis confidence 0.35 is below the weak-evidence threshold (0.60).",
  "fixes": []
}
```

### Agent 2 stage statuses

| Value | Meaning |
|---|---|
| `ok` | Solution produced and schema-valid (FIX or NO_FIX both qualify as `ok` if validation passed) |
| `degraded` | Claude exited non-zero, but normalised output passed validation (or repair succeeded) |
| `failed` | All extraction/validation paths exhausted; placeholder NO_FIX with confidence 0.0 written |

### Agent 2 failure handling

Agent 2 is **fail-closed**: if Claude returns no valid output, normalisation fails, or schema validation fails after one repair attempt, the orchestrator writes a placeholder NO_FIX solution with `confidence: 0.0` and `no_fix_reason` describing the failure. No fabricated patch is ever written.

### Agent 2 sidecar artifacts

| File | When |
|---|---|
| `agent2_raw.json` | Always |
| `agent2_stderr.txt` | Always |
| `agent2_meta.env` | Always (exit_code, normalized, schema_valid, repair_attempted, repair_success, solution_status, failure_reason) |
| `agent2_quality.env` | Always (`agent2_quality=ok` or `agent2_quality=failed`) |
| `agent2_repair_*` | Only when initial Claude call failed validation |
| `solution.invalid.json` / `.txt` | Only on validation failure (debug aid) |
| `solution.json` | Schema-validated solution or fail-closed placeholder |
| `patches/fix.diff` | Only when `recommendation: "FIX"` |

---

## Agent 2.5 — Validation

### Role
Apply the proposed patch in an isolated worktree, run the existing test suite, and report whether the fix passes. Do not evaluate the fix conceptually — only run the tests and report what happens.

### Inputs
| Input | Source | Description |
|---|---|---|
| System prompt | `prompts/agent2_5.md` | Role, worktree rules, test execution, output format |
| `solution.json` | `RUN_DIR/solution.json` | Patch locations, test suggestion |
| `patches/*.diff` | `RUN_DIR/patches/` | Unified diffs to apply |

### Allowed Tools
- **Read** — files in the worktree
- **Write** — files in the worktree only (never the main working tree)
- **Bash** — `git apply`, test runner (`pytest`, `go test`, etc.), `patch` command — worktree only

### Forbidden
- Write to `TARGET_REPO_ROOT` main working tree
- `git commit`, `git push`, `git branch`
- Network access
- Modifying the patch files themselves

### Worktree Location
`../.rca-mas-worktrees/$RUN_ID/` — sibling to `TARGET_REPO_ROOT`, never inside it.

The orchestrator creates and removes this worktree. Agent 2.5 only works inside it.

### Output
File: `RUN_DIR/validation.json`

```json
{
  "status": "PASS",
  "test_command": "pytest tests/test_options.py -k test_show_envvar",
  "test_output_summary": "3 passed in 0.8s",
  "patch_applied": true,
  "worktree_path": "../.rca-mas-worktrees/20260504-101523"
}
```

### Status Values
| Value | Meaning |
|---|---|
| `PASS` | Patch applied cleanly; all tests passed |
| `FAIL` | Patch applied but tests failed |
| `ERROR` | Patch did not apply (conflict, wrong base, missing file) |
| `SKIPPED` | Agent 2.5 not invoked (no `--validate` flag or `NO_FIX` upstream) |

### Cleanup
After Agent 2.5 completes, the orchestrator removes the worktree directory. Set `RCA_KEEP_WORKTREE=1` to retain it for debugging.

---

## Confidence Score Reference

| Score | Label | Interpretation |
|---|---|---|
| 0.9–1.0 | HIGH | Root cause confirmed with multiple independent evidence points |
| 0.7–0.89 | HIGH | Strong evidence; Agent 1a stops early here |
| 0.5–0.69 | MEDIUM | Plausible root cause; some uncertainty |
| 0.4–0.49 | LOW | Best guess after investigation; often from timeout recovery |
| < 0.4 | LOW | Weak evidence; Agent 2 should emit `NO_FIX` |
