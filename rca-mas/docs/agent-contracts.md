# Agent Contracts

Defines what each agent does, what it receives, what it is allowed to do, what it must write, and what it must not do.

---

## Agent 1a — Investigation

### Role
Explore the codebase and determine the root cause of the bug described in the bug report. Form competing hypotheses. Gather evidence. Write a checkpoint file with all findings. Do NOT produce the final diagnosis JSON — that is Agent 1b's job.

Agent 1a runs without a JSON schema constraint. This gives it freedom to use all its turns for investigation rather than reserving a final turn for schema-valid output. The checkpoint file is its durable output.

### Inputs
| Input | Source | Description |
|---|---|---|
| System prompt + briefing | `RUN_DIR/agent1a_prompt.md` | Assembled by orchestrator: `prompts/investigation.md` + bug report + `briefing.md` + run metadata |
| Repo source files | `TARGET_REPO_ROOT` | Read-only access to full codebase via Read/Grep/Glob/Bash |

The prompt is assembled in `orchestrator.sh` in this order:

1. `prompts/investigation.md` — role, security block, strategy, checkpoint format, output spec
2. `## Bug Report` — contents of `bug.md`
3. `## Briefing` — contents of `briefing.md` (metadata, error sources, git history, deps, test mapping)
4. `## Run Metadata` — `RUN_ID`, `TARGET_REPO_ROOT`, `RUN_DIR`, `CHECKPOINT_PATH`, confidence thresholds

### Allowed Tools

- **Read** — read any source file in `TARGET_REPO_ROOT`
- **Grep** — search file contents
- **Glob** — list files matching a pattern
- **Bash** — read-only commands: `git log`, `git show`, `git diff`, `git blame`, `git status`, `grep`, `rg`, `find`, `cat`, `wc`, `head`, `tail`
- **Write** — only to `RUN_DIR/**` (checkpoint file only)

### Forbidden

- Edit source files in the repository
- Run tests or execute application code
- Network access (`curl`, `wget`, `ssh`)
- Read credential files (`.env`, `.pem`, `.key`, `id_rsa`, etc.)
- Write `diagnosis.json` — that is Agent 1b's job

### Confidence & Early Stop
Agent 1a tracks confidence as it investigates. When confidence exceeds `RCA_CONFIDENCE_STOP` (default `0.7`), it should write a final checkpoint and stop. It does not need to emit JSON — the final checkpoint write IS its stopping action.

### Output
File: `RUN_DIR/checkpoint.json`

Agent 1a writes this file at least twice: once early (after 2–3 files), and once as a final summary before stopping. The conclusion phase (Agent 1b) reads this file.

```json
{
  "hypothesis": "get_error_hint() constructs the error string unconditionally when show_envvar=True, without checking whether envvar is None. The guard `if self.show_envvar and self.envvar is not None` is missing.",
  "confidence": 0.85,
  "files_examined": ["src/click/core.py", "src/click/_utils.py", "tests/test_basic.py"],
  "call_chain": ["core.py:Option.type_cast_value()", "core.py:Option.get_error_hint()", "core.py:Option._resolve_envvar_value()"],
  "affected_files": ["src/click/core.py"],
  "supporting_evidence": [
    {
      "type": "code",
      "path": "src/click/core.py",
      "lines": "412-418",
      "note": "get_error_hint() includes envvar in error string without None check"
    }
  ],
  "rejected_hypotheses": [
    {"id": "h2", "reason": "error formatting is correct — problem is in the guard upstream"}
  ],
  "unknowns": ["whether the bug exists on Python 3.8 or only 3.9+"],
  "introducing_commit": "a3f9c12d...",
  "next_best_action": "Add `and self.envvar is not None` to the show_envvar guard at core.py:414"
}
```

### Timeout Recovery
If Agent 1a times out (SIGKILL), the orchestrator reads whatever checkpoint was last written. If only the seed checkpoint exists (confidence 0.0), Agent 1b will emit a minimal honest diagnosis. The pipeline never produces zero output.

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

- **Read** — checkpoint file and (sparingly) source files to verify a specific line
- **Grep** — only to confirm a single fact left ambiguous by the checkpoint
- **Glob** — only to locate a file the checkpoint named without a full path

### Forbidden

- Write to any file
- Bash commands
- Network access
- Read credential files
- Re-investigate beyond what the checkpoint already contains

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

### Timeout Recovery
If Agent 1b times out or fails, the orchestrator synthesises `diagnosis.json` directly from `checkpoint.json` using bash, setting confidence to `RCA_CONFIDENCE_CHECKPOINT` (default `0.4`) if the checkpoint was at seed level (0.0), or preserving the checkpoint's confidence otherwise.

### Status Values
| Value | Meaning |
|---|---|
| `ok` | Diagnosis produced normally |
| `partial` | Agent 1b timed out; diagnosis synthesised from checkpoint (confidence preserved) |
| `failed` | Agent 1b timed out and only the seed checkpoint existed; confidence is `RCA_CONFIDENCE_CHECKPOINT` |

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

Agent 2 does **not** have access to the raw repo. It works only from what Agent 1 found.

### Allowed Tools
- **Read** — `briefing.md` and `diagnosis.json` only

### Forbidden
- Grep, Glob, Bash
- Write to any repo file
- Read source files directly (must trust diagnosis.json evidence)
- Network access

### NO_FIX Rule
If `diagnosis.json` confidence is below `RCA_CONFIDENCE_NOFX` (default `0.5`), Agent 2 must emit `status: NO_FIX` and explain why a fix cannot be responsibly produced. This is preferable to generating a patch based on a weak diagnosis.

### Output
File: `RUN_DIR/solution.json` + `RUN_DIR/patches/*.diff`

```json
{
  "status": "COMPLETE",
  "confidence": 0.78,
  "fix_description": "Add a None check before including envvar in the error message. Change `if self.show_envvar` to `if self.show_envvar and self.envvar is not None`.",
  "affected_files": ["src/click/core.py"],
  "patches": ["patches/fix_core.diff"],
  "test_suggestion": "pytest tests/test_options.py -k test_show_envvar"
}
```

`NO_FIX` response:
```json
{
  "status": "NO_FIX",
  "confidence": 0.38,
  "reason": "Diagnosis confidence is below threshold. Root cause is suspected to be in the parser but evidence is insufficient to locate the specific lines."
}
```

### Status Values
| Value | Meaning |
|---|---|
| `COMPLETE` | Patch produced |
| `NO_FIX` | Confidence too low; no patch produced |
| `PARTIAL` | Patch produced but Agent 2 flagged uncertainty |

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
