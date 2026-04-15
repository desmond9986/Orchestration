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

## You talking to agents

```bash
orch-send <agent_id> "<message>"                      # default type=INFO
orch-send <agent_id> --type TASK "<message>"          # custom type
orch-send --broadcast "<message>"                     # to everyone active
```

All `orch-send` messages show up as `from:human` in the bus so agents
know the instruction came from you, not from the orchestrator.

You can also just switch to an agent's tmux pane and chat with them
directly through their CLI — that's outside the protocol and doesn't
appear in the bus.

## Observing the session

Three complementary views:

| View | What | Command |
|---|---|---|
| **Message bus** | Full payload of every message, chronological | `orch-status --follow` |
| **Status board** | One-line events (SENT, ASSIGNED, DONE...) | `orch-status --follow-status` |
| **Live dashboard** | Per-agent pane content — see what each is doing RIGHT NOW | `orch-watch` |

```bash
orch-status                         # roster + last 20 bus messages
orch-status --follow                # tail -f bus (live message stream)
orch-status --bus                   # full bus log
orch-status --status                # summary status board
orch-status --roster                # just the roster
orch-status --inbox <id>            # peek an agent's unread inbox
orch-status --log                   # delivery errors / retries

orch-watch                          # live dashboard (refresh every 2s)
orch-watch 3 10                     # refresh every 3s, show 10 lines per pane
```

**Tip:** open three terminals —
1. The orchestration tmux session itself
2. `orch-watch` to see if anyone is stuck
3. `orch-status --follow` to follow the message stream

## Shared task list

For multi-step work, agents coordinate through `.agents/tasks.json` instead
of ad-hoc TASK messages:

```bash
orch-task create "Design auth schema" --id t-schema
orch-task create "Implement codec"    --depends t-schema
orch-task create "Write tests"        --depends t-schema

orch-task list-available              # only shows tasks whose deps are done
orch-task claim t-schema architect    # atomic — only one agent wins
orch-task complete t-schema architect --note "schema.md committed"
# → any task whose deps just cleared (t-codec, t-tests here) is announced
#   via STATUS broadcast so a free worker can claim it next

# If you hit a blocker, flag it — blocked tasks are hidden from
# list-available and can't be re-claimed until explicitly reopened:
orch-task block   t-codec coder-1 --reason "upstream API is down"
orch-task unblock t-codec coder-1 --note   "API back up"
```

Claim conflicts are safe (mkdir-based mutex). Workers can self-serve from
`list-available` instead of being hand-assigned.

## Delivery modes

By default, `protocol.sh send` writes to the target's JSONL inbox and prints
`# CHECK INBOX (<id>)` in their pane — the agent polls. Set `ORCH_DELIVERY=push`
to paste the full message directly into the target pane (no polling needed):

```bash
export ORCH_DELIVERY=push    # in your shell, before spawning
orchestrate lean
```

Push mode is more responsive; notify mode is quieter and lets the agent batch.
Inbox remains the audit trail either way.

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

## Cross-model communication

Agents using different models (Claude + Codex + Gemini, etc.) can message
each other freely. The protocol is file-based (inbox + bus log + tmux
notify), so the only thing each agent needs is the ability to run bash —
which every major AI CLI supports. A Claude coder and a Codex coder can
both `find-role coder`, see each other in the roster, and send messages
through the exact same commands.

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
├── bin/                 # orchestrate, add-agent, remove-agent, end-session,
│                        # orch-status, orch-send, orch-watch, orch-task
├── lib/                 # roster.sh, protocol.sh, tasks.sh, spawn-agent.sh,
│                        # tmux-helpers.sh, common.sh
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

## Design decisions

Why the toolkit is shaped the way it is. Each call-out is a fork in the road
where the less-obvious option won.

### Roles as markdown prompts, not CLI-native skills
Every modern agent CLI has its own skill/extension system (Claude Code
Skills, Codex skills, Gemini extensions, …). They're good for different
problems than this one. Two reasons role files stay as plain markdown:

1. **Seeded, not activated.** A role must be present in the agent's context
   from the very first message — the agent *is* the role. Skills are
   conditionally loaded at runtime based on the CLI's own routing logic;
   that's the wrong trigger for identity.
2. **One format across models.** A mixed team (Claude + Codex + Gemini) all
   gets the exact same role prompt pasted at launch, no per-CLI porting.
   The role says "you are a coder," not "here's a skill you might invoke."

Skills still make sense *inside* a role — an agent wearing the `coder` role
is free to call whatever Claude Skills / Codex skills its CLI exposes while
doing the work.

### Core + hats composition, not monolithic role files
Real sessions vary: sometimes the orchestrator also does architecture;
sometimes an architect is separate; sometimes a coder wears qa+reviewer hats
solo. Splitting `core/<role>.md` (atomic identity) from `hats/<name>.md`
(optional add-on duties, composed at launch via `--hats`) means the role
library doesn't explode combinatorially as team shapes shift.

### Dynamic roster lookup, not hardcoded pane IDs
Tmux pane indices shift whenever a pane is added or removed. Every role
re-reads `.agents/roster.json` via `roster.sh find-role <role>` before
messaging. New agents appear automatically; departed agents are skipped.
This is the single biggest source of "agent sent to the wrong place" bugs
that the toolkit exists to eliminate.

### File-based inbox + tmux notify, not raw tmux send-keys
Pure tmux send-keys loses messages when a pane is busy, mangles multi-line
payloads, and has no audit trail. Writing to `.agents/inbox/<id>.jsonl`
first (durable), then notifying via tmux, gives us: delivery even when the
target is mid-thought, a replayable audit log, and a recovery path if
tmux delivery fails.

### JSONL for inboxes, markdown for bus/status
Two different readers, two different formats:
- **Inbox** is parsed by agents → JSONL (`{id,ts,from,to,type,payload,read}`),
  one object per line, queryable with `jq`. No regex on `[MSG ...]` headers.
- **Bus + status** are read by humans → markdown timelines.
- **Payload** stays a plain string — agents write prose, not structured data.

### Two delivery modes (`notify` / `push`), selectable per session
- `notify` (default): write inbox, print `# CHECK INBOX`. Agent polls when
  convenient → quieter, lets the agent batch.
- `push`: write inbox **and** paste the full message into the target pane
  via `tmux load-buffer`/`paste-buffer -d`. No polling → more responsive.

Inbox is written either way, so the audit trail is uniform.

### Shared task list with atomic claims, not pure orchestrator-assigns
Hand-assignment through the orchestrator is a bottleneck. A shared
`.agents/tasks.json` with `claim`/`complete` lets free workers self-serve
(`list-available`) while orchestrators focus on sequencing and unblocking.
Dependents auto-unblock on complete via a STATUS broadcast.

### mkdir-based mutex, not `flock`
macOS's default bash is 3.2 and ships without `flock`. `mkdir` is atomic on
all POSIX filesystems, works everywhere, and needs no dependency. Stale
locks (>60s) are reaped automatically so a crashed agent can't wedge the
task list.

### Per-project state under `.agents/`, gitignored
All session state (roster, inboxes, tasks, bus, archives) lives in the
project directory, not in `~/orchestration/`. This lets the toolkit be
shared across projects while each project has its own isolated session.
`.agents/` is gitignored by default.

### Three observability layers, not one
`bus.md` (every message, full payload), `status.md` (one-line events), and
`orch-watch` (live pane tails) each answer a different question: "what was
said?", "where are we?", "is anyone stuck?". None of them subsumes the
others in practice.

## Customizing

- **Add a role:** drop `roles/core/<name>.md`, update patterns to use it
- **Add a hat:** drop `roles/hats/<name>.md`, pass `--hats <name>` at spawn
- **Add a pattern:** drop `patterns/<name>.sh`, call spawn-agent for each member
- **Add a model:** edit the `launch_cli_cmd` case in `lib/spawn-agent.sh`

## License

MIT — do whatever.
