# orchestration

A model-agnostic, tmux-based toolkit for running multi-agent AI workflows.
Compose teams from atomic roles, swap model providers per agent, and add
or remove agents mid-session without breaking the protocol.

## Why

Multi-agent workflows break down because:
- Pane IDs shift — agents send to the wrong place
- tmux send-keys is easy to get wrong (forgotten Enter, escaping issues)
- Role definitions get tangled with project specifics
- Team shape varies per task, but scripts assume a fixed team

This toolkit solves those by separating four concerns:

| Layer | What it does | Varies by |
|---|---|---|
| **Patterns** (`patterns/*.sh`) | Initial team shape, CLI choices | Orchestration pattern |
| **Roles** (`roles/core/*.md`) | What an agent does, how it finds peers | Never — role is atomic |
| **Hats** (`roles/hats/*.md`) | Optional add-on duties (architect, qa, reviewer, spawner) | Composed at launch |
| **Protocol** (`roles/_protocol.md` + `lib/*.sh`) | How agents communicate | Never — shared rules |

## Install

```bash
cd ~/orchestration
./install.sh
```

Requires: `tmux`, `jq`. On macOS: `brew install tmux jq`.

Then open a new terminal (or `source ~/.zshrc`).

## Quickstart

```bash
cd ~/your-project
orchestrate lean                    # 1 orchestrator (with architect hat) + 2 coders
```

Tmux will attach automatically. One pane per agent. Each agent sees its
role, the communication protocol, project context, and their identity.

## Patterns

```bash
orchestrate list
```

Built-in:
- `lean` — orchestrator (architect hat) + 2 coders, one with spawner hat
- `swarm [N]` — orchestrator + N coders (default 3)
- `full-team` — orchestrator + architect + 2 coders + reviewer + qa
- `review-loop` — 1 coder + 1 reviewer
- `lonely-coder` — solo coder wearing spawner+qa+reviewer hats
- `debug-squad` — orchestrator + debugger + coder + qa
- `freeform` — empty session, add agents manually

Add your own: drop `patterns/<name>.sh` with the spawn calls you want.

## Mid-session changes

```bash
add-agent reviewer claude           # spawn a reviewer
add-agent coder codex --id coder-3  # add another coder using codex
add-agent qa claude --parent coder-1 --id coder-1.qa   # coder-1 spawns a QA sub-agent

remove-agent coder-2                # kill a pane, mark left in roster
```

Roles discover the team dynamically via `roster.sh find-role <role>` —
new agents appear automatically, left agents are skipped.

## Observing the session

```bash
orch-status                         # roster + recent status
orch-status --follow                # tail -f status board
orch-status --roster                # just the roster
orch-status --inbox <id>            # peek an agent's inbox
orch-status --log                   # delivery errors, retries
```

## Teardown

```bash
end-session                         # archive .agents/ and kill tmux
end-session --keep-tmux             # archive but keep panes alive
```

Archives land in `.agents/sessions/<timestamp>-<pattern>/`.

## Project context

Drop these in your project to seed every agent automatically:

```
your-project/
└── .agents/
    ├── PROJECT_CONTEXT.md    # injected into every agent's prompt
    ├── SPECS.md              # injected into every agent's prompt
    └── contracts/            # written to by architect, read by coders/reviewers
```

## Supported models

Defined in `lib/spawn-agent.sh::launch_cli_cmd()`:

- `claude` → Claude Code CLI
- `codex` → Codex CLI
- `gemini` → Gemini CLI
- `shell` / `none` → just prints the prompt (paste manually)

Unknown models fall back to `shell`. Add more by editing
`launch_cli_cmd()`.

## File layout

```
~/orchestration/
├── bin/                 # orchestrate, add-agent, remove-agent, end-session, orch-status
├── lib/                 # roster.sh, protocol.sh, spawn-agent.sh, tmux-helpers.sh, common.sh
├── roles/
│   ├── _protocol.md     # shared communication protocol (prefixed to every agent)
│   ├── core/            # atomic role definitions
│   └── hats/            # optional add-on duties
├── patterns/            # team compositions
├── install.sh
└── README.md
```

Per-project state lives in `<project>/.agents/` (roster, inboxes, status,
prompts, archived sessions). It's gitignored by default.

## Protocol at a glance

Agents communicate via file-based inboxes with tmux notifications:

```bash
# Send
bash $ORCHESTRATION_HOME/lib/protocol.sh send <to_id> <TYPE> "<payload>" --from <your_id>

# Receive
bash $ORCHESTRATION_HOME/lib/protocol.sh check-inbox <your_id>

# Broadcast
bash $ORCHESTRATION_HOME/lib/protocol.sh broadcast <TYPE> "<payload>" --from <your_id>

# Post to status board (visible to everyone)
bash $ORCHESTRATION_HOME/lib/protocol.sh status <your_id> "<message>"
```

Message types: `TASK`, `STATUS`, `DONE`, `BLOCKED`, `QUESTION`,
`REVIEW_REQUEST`, `VERDICT`, `INFO`.

## Customizing

- **Add a role:** drop `roles/core/<name>.md`, update patterns to use it
- **Add a hat:** drop `roles/hats/<name>.md`, pass `--hats <name>` at spawn
- **Add a pattern:** drop `patterns/<name>.sh`, call spawn-agent for each member
- **Add a model:** edit the `launch_cli_cmd` case in `lib/spawn-agent.sh`

## License

MIT — do whatever.
