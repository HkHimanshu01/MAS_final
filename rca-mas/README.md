# RCA Compression MAS

Compresses a 30–60 minute bug investigation into a 3–8 minute automated report.

> Full content added at Step 9.

## Quick start

```bash
cd /path/to/your/repo
/path/to/rca-mas/rca-mas.sh examples/bug.md
cat .rca-mas/runs/latest/report.md
```

## Prerequisites

- `claude` (Claude Code CLI, logged in)
- `git`
- `jq`
- `gh` (optional — only for `--issue` mode)

## Modes

```bash
./rca-mas.sh bug.md                        # report-only (safe, never edits code)
./rca-mas.sh bug.md --validate             # validate fix in isolated worktree
./rca-mas.sh --issue 42 --repo owner/repo  # fetch GitHub issue as input
./rca-mas.sh --help
```

See [docs/index.md](docs/index.md) for full documentation.
