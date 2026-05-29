# AI-Powered Bug Diagnosis and Resolution

Compresses a 30–60 minute developer bug investigation into a 3–8 minute automated report.

A QA tester writes a `bug.md` (or files a GitHub issue), runs one command from inside the target repo, and a developer gets a structured report with root cause, evidence, a proposed fix diff, and next actions. Optionally, the fix is applied in an isolated git worktree and the test suite is run — without ever touching the working tree.

## How it works

```text
bug.md → briefing (bash repo scan) → Agent 1a investigation → Agent 1b diagnosis
       → Agent 2 solution (patch) → Agent 2.5 validation (--validate only) → report.md
```

Each stage receives only the previous stage's output (context funnel). The pipeline never commits, pushes, deploys, or edits the working tree.

## Prerequisites

| Tool | Required for | Install |
| --- | --- | --- |
| [`claude`](https://docs.claude.com/en/docs/claude-code) | All agents — Claude Code CLI, logged in | `claude auth login` |
| `git` | Always | system package |
| `jq` | JSON extraction | system package |
| `rg` (ripgrep) | Faster error grep (falls back to `git grep`) | optional but recommended |
| `gh` | `--issue` mode only | `gh auth login` |
| `bash` 4+ | Always | macOS/Linux native; on Windows use MSYS2 / Git Bash |

## Install

Drop the folder anywhere — it's self-contained. There's no install step.

```bash
git clone <your-fork-or-zip-source> rca-mas
# or copy the rca-mas/ folder onto disk
chmod +x rca-mas/rca-mas.sh
```

## Quick start

```bash
# 1. Go to the repo you want to analyze
cd /path/to/your/repo

# 2. Run the pipeline against a bug report
bash /path/to/rca-mas/rca-mas.sh /path/to/bug.md

# 3. Read the report
cat .rca-mas/runs/latest/report.md
```

You can try it immediately against the bundled example:

```bash
cd rca-mas
bash run.sh run        # runs against examples/bug.md inside this repo itself
bash run.sh report     # prints the latest report
```

## Modes

```bash
# Report only — never edits code, always safe
./rca-mas.sh bug.md

# Apply patch in isolated git worktree, run test suite
./rca-mas.sh bug.md --validate

# Fetch a GitHub issue as the bug input
./rca-mas.sh --issue 42 --repo pallets/click

# Help
./rca-mas.sh --help
```

## Use from Claude Code chat

If you would rather drive MAS from chat than from the terminal, drop the `rca-mas/` folder into your target repo and append [templates/CLAUDE.md.snippet](templates/CLAUDE.md.snippet) to that repo's `CLAUDE.md`. Then in chat, plain-English prompts work:

- *use rca-mas to find the issue in `bug.md`*
- *use rca-mas to diagnose the bug I just pasted*
- *show me the last rca-mas report*

The snippet tells Claude Code to run `bash ./rca-mas/rca-mas.sh <bug>`, tail `log.jsonl` while it runs, and surface `report.md` + `patches/fix.diff` at the end without applying anything. Without the snippet, the same prompt template still works — you just paste it verbatim each time.

When `rca-mas/` lives inside the target repo, the briefing and error-grep collectors automatically exclude `rca-mas/**` and `.rca-mas/**` so the tool never analyses itself. Add both paths to your target repo's `.gitignore`.

`--validate` runs Agent 2.5 inside a git worktree under `../.rca-mas-worktrees/`. The main working tree is never touched. See [docs/validation-worktree.md](docs/validation-worktree.md) for the full lifecycle.

## Bug report format

Free-form markdown is fine. Headings the agents look for:

```markdown
# Bug: <short summary>

## Steps to reproduce
1. ...

## Expected behaviour
...

## Actual behaviour
...
Stack trace / error messages here.

## Environment
- Version / branch / OS

## Additional context
- File paths or function names you suspect
```

See [examples/bug.md](examples/bug.md) for a complete sample and [examples/sample-report.md](examples/sample-report.md) for what the pipeline produces.

## Output

After a run, everything is under the **target repo**, not under `rca-mas/`:

```text
<target-repo>/.rca-mas/runs/
├── <RUN_ID>/
│   ├── report.md              ← the human-readable report
│   ├── briefing.md            ← repo scan output (no LLM)
│   ├── diagnosis.json         ← Agent 1 output
│   ├── solution.json          ← Agent 2 output
│   ├── validation.json        ← Agent 2.5 output (if --validate)
│   ├── patches/fix.diff       ← extracted patch (apply with git apply)
│   ├── log.jsonl              ← structured event log
│   └── *.raw.json             ← raw Claude responses for debugging
└── latest -> <RUN_ID>/        ← symlink to most recent run
```

Full file-by-file breakdown in [docs/run-artifacts.md](docs/run-artifacts.md).

## Configuration

All tunables live in [config/defaults.env](config/defaults.env). Override any of them at the command line:

```bash
# Switch model
RCA_MODEL=claude-opus-4-7 bash rca-mas.sh bug.md

# Increase turn budget for a large repo
RCA_TURNS_L=70 bash rca-mas.sh bug.md

# Keep the worktree after validation (for debugging)
RCA_KEEP_WORKTREE=1 bash rca-mas.sh bug.md --validate
```

Full env var table in [docs/cli-reference.md](docs/cli-reference.md).

## Safety / what it will never do

- **Never** commits, pushes, tags, or opens PRs
- **Never** edits files in your working tree (Agent 2.5 works in a worktree)
- **Never** reads `.env`, `.pem`, `.key`, `id_rsa`, or credential files
- **Never** runs `curl`, `wget`, `ssh`, `scp`
- All denials enforced by [.claude/settings.json](.claude/settings.json)

See [docs/security-model.md](docs/security-model.md) for the full trust model.

## Development

```bash
# Syntax check all scripts (~5s)
bash run.sh lint

# Fast subset: lint + schemas + smoke (~2 min, use while coding)
bash run.sh test-fast

# All 4 synthetic suites (~6 min, step gate before each new step)
bash run.sh test

# Real GitHub bugs from pallets/click (~3 min, pre-lock gate)
bash run.sh test-real-repo
```

Real-repo tests require a Click clone — default location `C:/MAS_final/test-repos/click`, override with `RCA_REAL_REPO_ROOT`:

```bash
git clone https://github.com/pallets/click /tmp/click
RCA_REAL_REPO_ROOT=/tmp/click bash run.sh test-real-repo
```

Same targets work with `make` if installed. Full testing guide: [docs/testing-guide.md](docs/testing-guide.md).

## Documentation

| Doc | Read when |
| --- | --- |
| [docs/index.md](docs/index.md) | You want the full reading order |
| [docs/architecture.md](docs/architecture.md) | Understanding system boundaries and pipeline |
| [docs/pipeline-flow.md](docs/pipeline-flow.md) | Stage-by-stage execution detail |
| [docs/cli-reference.md](docs/cli-reference.md) | All flags and env vars |
| [docs/agent-contracts.md](docs/agent-contracts.md) | Agent roles, tools, schemas |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Something failed — symptoms and fixes |
| [docs/qa-to-dev-flow.md](docs/qa-to-dev-flow.md) | How this fits into a QA-to-dev workflow |

For contributors: [code_practices.md](code_practices.md), [architecture.md](architecture.md) (locked), [CLAUDE.md](CLAUDE.md).

## Status

V1 architecture is **locked**. Briefing, Agent 1a/1b investigation and diagnosis, Agent 2 solution, report rendering and the GitHub `--issue` input path are complete; Agent 2.5 worktree verification is the active build target. See [docs/decisions.md](docs/decisions.md) for what was kept vs. cut.
