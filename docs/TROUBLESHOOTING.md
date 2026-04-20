# Troubleshooting

## Known behavior to expect

- Agents can sometimes respond with protocol echoes instead of actionable execution when instructions are vague.
- Notify delivery can appear intermittent if tmux target metadata is stale.
- High parallel churn can expose lock wait/retry behavior.

If this impacts throughput, use stricter `TASK` payloads and run `orch-enforce --on` during active sessions.

## Agent not responding

```bash
orch-status --inbox <agent-id>
orch-status --log
orch-status --follow
```

If pane is at shell prompt, the CLI likely exited; restart CLI in that pane and resend pending instructions.

## Message queued but not visible in pane

This is usually a tmux target/notify issue. Check:

```bash
orch-status --log
bash "$ORCHESTRATION_HOME/lib/roster.sh" list-active
```

Then nudge directly:

```bash
bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox <agent-id>
```

## Lock timeout

```bash
ls .agents/*.lock.d .agents/*/*.lock.d 2>/dev/null || true
```

Stale lock dirs can be removed if no active command is using them.

## Duplicate agent IDs

```bash
orch-preflight
```

Fix by removing/re-adding the duplicated entry via `remove-agent` / `add-agent`.

## Task board inconsistent

```bash
jq . .agents/tasks.json
```

If corrupted, recover from `.agents/sessions/<timestamp>/tasks.json`.
