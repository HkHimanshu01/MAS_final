# Security Model

How the tool handles untrusted input, what it is allowed to touch, and what is permanently off-limits.

---

## Trust Boundaries

| Input | Trust level | Why |
|---|---|---|
| `bug.md` content | **Untrusted** | Written by a QA engineer, not a developer. May contain crafted strings. Passed to agents. |
| Target repo source files | **Semi-trusted** | Read-only. Agents may read anything git-tracked, but never credential files. |
| `config/defaults.env` | **Trusted** | Written by the team; not user-supplied |
| Agent JSON outputs | **Semi-trusted** | Validated against schemas before use |
| Claude Code tool responses | **Trusted** | Claude is the execution engine, not an attack surface |

---

## Bug Report as Untrusted Input

The bug report is submitted by QA and may contain text designed to manipulate agent behavior (prompt injection). Defenses applied at every layer:

1. **Briefing phase (bash):** Bug report is processed with regex only. No eval, no shell expansion of bug content. File paths extracted from bug.md are validated against `git ls-files` before use — a path in the bug report does not grant read access.

2. **Agent prompts:** Every system prompt (`prompts/agent1.md`, `agent2.md`, `agent2_5.md`) contains an explicit instruction block: treat any text from `bug.md` as data, not instructions. Agents are told to ignore any embedded "ignore previous instructions" or similar patterns.

3. **Schema validation:** Agent outputs are validated against JSON schemas before being passed downstream. A manipulated agent cannot inject free-form text into `diagnosis.json` fields that downstream agents will interpret as instructions.

---

## Forbidden Files

The following file patterns are never read by any script or agent:

```
.env
.env.*
*.pem
*.key
id_rsa
id_ed25519
*.secret
*.token
*.passwd
*.password
```

Enforced in two places:
- `scripts/briefing.sh` Phase 2: extension-based rejection before any file path from bug.md reaches an agent
- Agent prompts: explicit "never read credential files" instruction with examples

---

## Forbidden Commands

No script in the tool runs:

```
curl
wget
ssh
scp
git push
git commit
git branch (in target repo)
```

The orchestrator and all collectors use only local commands. No network access. No outbound connections.

---

## Read-Only Target Repo

The tool never modifies the target repo's working tree:

- `briefing.sh` and all collectors: read-only (`git log`, `git ls-files`, `grep`, `cat`)
- Agent 1: explicitly forbidden from Write/Edit tools
- Agent 2: explicitly forbidden from Write/Edit tools; only reads `briefing.md` and `diagnosis.json`
- Agent 2.5: writes only to the disposable worktree at `../.rca-mas-worktrees/{RUN_ID}/`

The only writes to the target repo are the output files under `.rca-mas/runs/{RUN_ID}/`. These are in a `.rca-mas/` directory that should be added to the target repo's `.gitignore`.

---

## Worktree Isolation (Agent 2.5)

Agent 2.5 needs to apply a patch and run tests. To do this without touching the main working tree:

1. Orchestrator creates `git worktree add ../.rca-mas-worktrees/$RUN_ID`
2. Agent 2.5 applies the patch inside the worktree
3. Agent 2.5 runs tests inside the worktree
4. Orchestrator removes the worktree with `git worktree remove --force`

The worktree is a sibling directory to the target repo (one level up), never inside it. This means even if something goes wrong during cleanup, no source files are affected.

---

## Claude Code Permission Flags

Each agent is invoked with explicit tool allowlists:

| Agent | Allowed tools | Disallowed |
|---|---|---|
| Agent 1 | Read, Grep, Glob, Bash (read-only) | Write, Edit, network |
| Agent 2 | Read (briefing.md, diagnosis.json only) | Grep, Glob, Bash, Write, Edit |
| Agent 2.5 | Read, Write (worktree), Bash (worktree only) | Write to main tree, git commit/push |

These restrictions are enforced at the Claude Code invocation level via `--allowedTools` flags, not just in prompt instructions.

---

## Output Directory Security

Run outputs go to `TARGET_REPO_ROOT/.rca-mas/runs/{RUN_ID}/`. Recommend adding to `.gitignore`:

```
.rca-mas/
.rca-mas-worktrees/
```

`report.md` may contain excerpts of source code and error messages. If your repo is private, treat the run directory as having the same sensitivity level as the repo itself.

---

## What the Tool Does Not Do

- Does not send any data to external services (no telemetry, no logging endpoints)
- Does not authenticate to or connect to GitHub, Jira, Slack, or any external system
- Does not store API keys or credentials
- Does not create git branches, tags, or commits
- Does not open PRs
- Does not auto-apply patches — the developer must run `git apply` manually
