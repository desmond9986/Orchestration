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
- [Terminal UI](#terminal-ui)
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
- `python3` for the full-screen `orch-tui` interactive interface

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
# If the tmux session is missing, run restore first instead of repair:
orch-restore
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
orch-tui                            # full-screen clickable control panel over existing commands
orch-tui --snapshot                 # print dashboard snapshot and exit
orchestrate <pattern>
orchestrate recommend                 # answer questions, get a pattern recommendation
orchestrate --yolo <pattern>          # skip model-choice prompts, use pattern role defaults (does not bypass permissions)
orchestrate --switch-client <pattern>
orchestrate --attach <pattern>
orchestrate --iterm-cc <pattern>      # attach with iTerm2 tmux control mode
orch-preflight
orch-preflight --repair
orch-restore                         # recreate missing tmux panes from .agents/roster.json
orch-restore --iterm-cc              # restore then attach with iTerm2 tmux control mode
bash "$ORCHESTRATION_HOME/lib/roster.sh" resume <agent-id>
add-agent <role> <model> [--id <agent-id>] [--hats <h1,h2>]
remove-agent <agent-id>
end-session [--keep-tmux]

# Messaging
orch-send <agent-id> "message"
orch-send <agent-id> --type TASK "objective: ...; definition_of_done: ...; required_reply: ..."
orch-send --broadcast "message"
orch-inbox peek <agent-id>              # operator-safe: does not archive unread messages
orch-inbox check <agent-id>             # mark unread as read/archive; use carefully

# Task board
orch-task create "Work item" [--id t-1] [--depends t-parent]
orch-task list-available
orch-task claim <task-id> <agent-id>
orch-task complete <task-id> <agent-id> --note "done"
orch-task block <task-id> <agent-id> --reason "blocked"
orch-task unblock <task-id> <agent-id> --note "unblocked"
```

## Terminal UI

`orch-tui` is a full-screen terminal control panel for operators who do not want to memorize every command. It supports keyboard navigation and mouse/click selection in terminals that support mouse reporting.

It is intentionally a thin wrapper: it reads `.agents` state for display and calls existing commands for actions. Missing capabilities should be added as CLI commands first, then surfaced in the TUI.

The default view is an ops-console layout: pages at the top, a large resource viewport, a responsive inspector for the selected row, a contextual action bar, `:` action picker, `/` page filtering, and expandable detail/output panes. New projects show a first-run Start Here banner before the pattern list.

Current screens:
- Session: browse/filter patterns, preview launch, launch selected pattern, restore, preflight, end session.
- Agents: list, add, nudge selected, peek inbox, explicitly mark unread as read, inspect roster metadata, remove.
- Messages: send, reply to selected sender, peek selected inbox, broadcast, view bus.
- Tasks: create, show selected, claim, complete, block, unblock, list available, list all.
- Health: preflight, repair, restore, roster, status board, recent bus, enforce status/on/off, logs.

```bash
orch-tui             # full-screen clickable terminal UI
orch-tui --snapshot  # plain text dashboard for scripts/tests
```

Useful controls: mouse-click tabs, rows, action buttons, and the output drawer when your terminal supports mouse reporting. Hover effects are intentionally disabled because terminal mouse-motion tracking can flicker under tmux/iTerm. Keyboard fallback: `1`-`5` switch pages, `j/k` move rows, `h/l` move actions, `Enter` runs or edits a form field, `s` submits a form, `:` opens the action picker, `?` opens help, `f` expands detail, `e` expands output, and `x` cancels a running command.

From the Session page, preview is the default action. Move to `Start selected` when you are ready to run `orchestrate --yolo <selected-pattern>`. Launch uses an inline-edit form with pattern, flags, args, and per-role model fields; forms show fixed controls and mark empty required fields. Models default to `ORCH_TUI_DEFAULT_MODEL`, then `ORCH_DEFAULT_MODEL`, then `codex`. Type `pattern` for a role to keep the pattern file default. `--yolo` does not bypass permissions; edit the launch-flags field if you need other `orchestrate` flags.

## Safety Defaults

- Permission bypass is **opt-in**.
- `orchestrate` now clears inherited `ORCH_SKIP_PERMISSIONS*` by default unless you explicitly choose bypass.
- `--yolo` skips the interactive model-choice prompts and uses each pattern's defaults. It does **not** enable permission bypass.
- `--dangerously-skip-permissions` is the actual bypass flag. It maps to each CLI's current bypass. For Codex CLI 0.125+, this is `codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen`.
- `orchestrate` does not attach or switch your current tmux view by default. Use `--attach` outside tmux, or `--switch-client` inside tmux, when you want that behavior.
- Use `--iterm-cc` or `-CC` outside tmux to attach through iTerm2 tmux control mode (`tmux -CC attach-session -t <session>`).
- `orch-restore` can rebuild a killed tmux session from live `.agents` state. It resumes the exact model chat when roster resume metadata exists; otherwise it restores panes from saved prompt context.
- Claude resume IDs are assigned automatically. Codex resume IDs are captured best-effort after the first prompt is delivered; if capture fails, restore falls back to a fresh Codex chat instead of using unsafe `--last`.
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
- Expand `orch-tui` with richer keyboard navigation, inline forms, and safer guided flows.
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
- Terminal UI guide: [docs/TUI.md](docs/TUI.md)
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
