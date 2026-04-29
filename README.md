# orchestration

Model-agnostic, `tmux`-based multi-agent orchestration for coding workflows.

Use prebuilt patterns (or define your own), assign different CLIs per role, and keep all coordination in a durable file protocol instead of fragile pane assumptions.

## Table Of Contents
- [Why This Exists](#why-this-exists)
- [Install](#install)
- [Quick Start](#quick-start)
- [Core Concepts](#core-concepts)
- [Built-in Patterns](#built-in-patterns)
- [Daily Commands](#daily-commands)
- [Safety Defaults](#safety-defaults)
- [Observability](#observability)
- [Known Issues](#known-issues)
- [Future Features](#future-features)
- [Documentation Map](#documentation-map)
- [Project Status](#project-status)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

## Why This Exists

Common multi-agent failures:
- Hardcoded pane targets break when layout changes.
- `send-keys` delivery is lossy and hard to audit.
- Role prompts get entangled with project-specific instructions.
- Team shape changes mid-session, but workflow scripts assume fixed teams.

This toolkit separates concerns:
- **Patterns** (`patterns/*.sh`): team composition and startup flow.
- **Roles** (`roles/core/*.md`): stable role identity and behavior.
- **Hats** (`roles/hats/*.md`): optional add-on responsibilities.
- **Protocol** (`roles/_protocol.md` + `lib/*.sh`): shared messaging and state.

## Install

```bash
cd ~/orchestration
./install.sh
```

Requirements:
- `tmux`
- `jq`
- one hasher: `shasum` or `sha1sum` or `cksum`

macOS example:

```bash
brew install tmux jq
```

## Quick Start

```bash
cd ~/your-project
orchestrate lean
```

Not sure which pattern to use? Run the interactive recommender:

```bash
orchestrate recommend
```

Then in another terminal:

```bash
orch-status --follow
```

Optional: drop project context before launching so agents know your stack:

```bash
mkdir -p .agents
cat > .agents/PROJECT_CONTEXT.md <<'EOF'
Stack: ...
Constraints: ...
EOF
```

Optional preflight before launching:

```bash
orch-preflight
# Repair required .agents files and stale roster pane targets:
orch-preflight --repair
```

## Core Concepts

- **Roster-driven routing**: agents find peers dynamically from `.agents/roster.json`.
- **Durable inbox protocol**: messages are written to JSONL inboxes first, then pane-notified.
- **Session-local state**: runtime state lives under `<project>/.agents/`.
- **Composable roles**: use core roles + hats instead of monolithic role variants.

## Built-in Patterns

```bash
orchestrate list
```

| Pattern | Team Shape | Use When |
|---|---|---|
| `lonely-coder` | 1 coder (with helper hats) | small focused change |
| `lean` | orchestrator + 2 coders | default for general feature work |
| `review-loop` | coder + reviewer | single-track with quality gate |
| `swarm [N]` | orchestrator + N coders | parallel speed over strict review |
| `ship-it [N]` | orchestrator + N coders + reviewer | parallel work with review gate |
| `plan-execute [N]` | orchestrator + architect + N coders + reviewer | design-first execution |
| `pipeline` | architect -> coder -> reviewer -> qa | strict linear stage flow |
| `debug-squad` | orchestrator + debugger + coder + qa | root-cause-first bug fixing |
| `spike` | researcher + architect | exploration and design only |
| `full-team` | orchestrator + architect + 2 coders + reviewer + qa | high-coordination large change |
| `freeform` | none | manual setup |

## Daily Commands

```bash
# Session
orchestrate <pattern>
orchestrate recommend                 # answer questions, get a pattern recommendation
orchestrate --yolo <pattern>          # skip model-choice prompts, use pattern role defaults (does not bypass permissions)
orchestrate --switch-client <pattern>
orchestrate --attach <pattern>
orch-preflight
orch-preflight --repair
add-agent <role> <model> [--id <agent-id>] [--hats <h1,h2>]
remove-agent <agent-id>
end-session [--keep-tmux]

# Messaging
orch-send <agent-id> "message"
orch-send <agent-id> --type TASK "objective: ...; definition_of_done: ...; required_reply: ..."
orch-send --broadcast "message"

# Task board
orch-task create "Work item" [--id t-1] [--depends t-parent]
orch-task list-available
orch-task claim <task-id> <agent-id>
orch-task complete <task-id> <agent-id> --note "done"
orch-task block <task-id> <agent-id> --reason "blocked"
orch-task unblock <task-id> <agent-id> --note "unblocked"
```

## Safety Defaults

- Permission bypass is **opt-in**.
- `orchestrate` now clears inherited `ORCH_SKIP_PERMISSIONS*` by default unless you explicitly choose bypass.
- `--yolo` skips the interactive model-choice prompts and uses each pattern's defaults. It does **not** enable permission bypass.
- `--dangerously-skip-permissions` is the actual bypass flag. It maps to each CLI's current bypass. For Codex CLI 0.125+, this is `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen`.
- `orchestrate` does not attach or switch your current tmux view by default. Use `--attach` outside tmux, or `--switch-client` inside tmux, when you want that behavior.
- Spawner hats are **opt-in** for the small default patterns. Use `ORCH_ENABLE_SPAWNER_HATS=1 orchestrate <pattern>` if you want agents prompted to spawn helper agents.
- To intentionally keep env overrides:

```bash
orchestrate --respect-env-skip-permissions <pattern>
```

- To explicitly enable bypass for a run:

```bash
orchestrate --dangerously-skip-permissions <pattern>
```

## Observability

```bash
orch-status
orch-status --follow
orch-status --follow-status
orch-enforce --on
orch-enforce --status
orch-enforce --off
```

By default, `orchestrate` prints the command to view the created tmux session instead of taking over your current terminal.

## Known Issues

Current known operational gaps:
- Agent compliance drift: some agents may repeatedly echo/check-inbox without executing work unless task prompts are explicit and enforced.
- Tmux delivery edge cases: pane notify can fail when target pane metadata is stale or shell/CLI state changes mid-send.
- Codex/Claude CLI UI gates can change between releases. `orch-preflight --repair` can repair local state, but account/quota/update prompts may still require operator action.
- Long-session state growth: runtime artifacts under `.agents/` may accumulate and need periodic cleanup in long-lived sessions.
- Operator UX friction: many commands/flags increase chance of orchestration mistakes.

Use [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for immediate workarounds and [docs/ROADMAP.md](docs/ROADMAP.md) for planned fixes.

## Future Features

Priority improvements planned:
- Guided control plane (`orch ui`) to reduce command memorization.
- Optional per-coder git worktrees for multi-coder sessions.
- Namespaced orchestration state (for example `ORCH_AGENTS_DIR=.agents-debug`) so multiple orchestration sessions can run safely in the same project.
- Stronger enforcement lifecycle (`TASK -> ACK/IN_PROGRESS -> DONE/BLOCKED`) with better anti-loop detection.
- Lower-noise automation (smarter nudges, clearer intervention prompts).
- Better session hygiene tooling for pruning/archive management.

## Documentation Map

- Overview and launch guide: this README
- Pattern selection and tradeoffs: [docs/PATTERNS.md](docs/PATTERNS.md)
- Operations and command flows: [docs/OPERATIONS.md](docs/OPERATIONS.md)
- Troubleshooting playbook: [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- Architecture and design decisions: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- Roadmap and known gaps: [docs/ROADMAP.md](docs/ROADMAP.md)

## Project Status

Current release: `v0.1.0`

Core features are stable for active development workflows.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md).

## License

MIT. See [LICENSE](LICENSE).
