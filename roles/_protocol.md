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
4. **Status updates are broadcast.** Write to the status board often so the
   human and other agents can follow along.

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

When you see `# CHECK INBOX (<your_id>)` in your terminal, or at the start of
each work cycle, run:

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox <your_id>
```

This prints unread messages and archives them. Always act on your messages
before starting new work.

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
