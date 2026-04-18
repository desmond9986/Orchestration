# Communication Protocol (shared by all agents)

You are one agent in a team. You communicate with other agents through a
file-based protocol with tmux notifications. The helpers below encapsulate
the bug-prone parts — **use them, do not craft tmux commands yourself.**

## Core Rules

1. **Always re-read the roster before messaging.** Pane IDs and team composition
   can change mid-session. Never trust a cached ID.
2. **Use the helper scripts.** They handle Enter keys, delivery checks, and
   logging automatically.
3. **Every message has a type.** Be explicit about what you want.
4. **Status updates go to the shared status board** (`.agents/status.md`) via
   `protocol.sh status`. That's a file anyone can read — it is not a
   broadcast message. Direct peer notification uses `send` or `broadcast`,
   which are separate channels.

## Discovering Your Team

```bash
# See every active agent (id, role, model, target, hats)
bash "$ORCHESTRATION_HOME/lib/roster.sh" list-active

# Find all agents of a given role
bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role reviewer
bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role coder

# Check if a specific agent is alive
bash "$ORCHESTRATION_HOME/lib/roster.sh" exists coder-2
```

## Sending a Message

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" send <to_id> <TYPE> "<payload>" --from <your_id>
```

**Message types** (use these consistently):

| Type | Meaning |
|---|---|
| `TASK` | Assignment from orchestrator to a worker |
| `STATUS` | Progress update |
| `DONE` | Task complete (include a brief summary in payload) |
| `BLOCKED` | Cannot proceed (include what's blocking) |
| `QUESTION` | Needs clarification |
| `REVIEW_REQUEST` | Worker → reviewer, asking for audit |
| `VERDICT` | Reviewer → requester: `PASS`, `FAIL`, or `PARTIAL` with findings |
| `INFO` | Anything else (broadcast-worthy info) |

## Receiving Messages

Two delivery modes, controlled by `ORCH_DELIVERY` env var:

- `notify` (default) — you see `check inbox(<your_id>) from:<sender>` in your pane.
- `push` — the full message text is pasted directly into your pane;
  no need to poll.

Regardless of mode, the durable inbox is JSONL at
`.agents/inbox/<your_id>.jsonl`. At the start of each work cycle, or when you
see the `check inbox` hint, run:

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox <your_id>
```

This renders unread messages in human-readable form and archives them to
`.agents/inbox/<your_id>.archive.jsonl`. Always act on your messages before
starting new work.

## Posting Status

Write to the shared status board so the human and your teammates can follow:

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" status <your_id> "what you're doing"
```

Do this:
- When you start a task
- Every few minutes during long work
- When you hit a blocker
- When you finish

## Shared Task List

For multi-step work, the team uses a shared task list at `.agents/tasks.json`.
Claims are atomic; dependents auto-unblock when a task completes.

```bash
# See what you can pick up
bash "$ORCHESTRATION_HOME/lib/tasks.sh" list-available --for <your_id>

# Claim one (atomic — only one agent wins)
bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim <task_id> <your_id>

# Mark done (broadcasts STATUS to any task whose deps just cleared)
bash "$ORCHESTRATION_HOME/lib/tasks.sh" complete <task_id> <your_id> --note "<summary>"

# Block if you can't proceed (only the claimer may block a claimed task)
bash "$ORCHESTRATION_HOME/lib/tasks.sh" block <task_id> <your_id> --reason "<why>"

# Reopen a blocked task once the blocker is resolved. Task returns to pending,
# owner is cleared, and availability is broadcast so any free worker can claim.
bash "$ORCHESTRATION_HOME/lib/tasks.sh" unblock <task_id> <your_id> --note "<resolution>"
```

`blocked` is terminal until `unblock` — a blocked task does not appear in
`list-available` and cannot be re-claimed directly.

Orchestrators/architects `create` tasks with `--depends <id,id>` to express
ordering. Workers prefer `list-available` over being hand-assigned individual
tasks — it removes a scheduling hop.

## Handling Gaps

Your team composition is **not fixed**. If a role you expect is absent:

- **No orchestrator?** Work autonomously from the human's instructions.
  Post frequent status so the human can steer.
- **No reviewer?** Self-review or request human review.
- **No qa?** Do your own real-environment verification before DONE.

Do not assume a role exists — always check the roster.

## Observability (what the human sees)

Every message you send (via `protocol.sh send` or `broadcast`) is
automatically mirrored to `.agents/bus.md` — the shared message bus.
The human watches this file to follow the whole conversation in real time.

This means you **do not need to CC the human** on messages; they see
everything. But do post periodic STATUS updates via
`protocol.sh status <your_id> "<msg>"` so the summary status board
(`.agents/status.md`) stays readable as a high-level timeline.

## Fail-Safe Logging

If something goes wrong (delivery failure, missing agent, unexpected state):

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" status <your_id> "ERROR: <what>"
```

The helper scripts also write to `$(project_root)/.agents/log.md` on their own
when delivery fails. Surface issues rather than retrying silently.
