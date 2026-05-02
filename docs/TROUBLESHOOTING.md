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

## Tmux session closed or killed

If `<project>/.agents/roster.json` still exists, rebuild the missing panes:

```bash
orch-restore
```

This keeps durable state (`.agents/inbox`, `.agents/tasks.json`, `.agents/status.md`). If exact resume metadata exists in `.agents/roster.json`, it resumes the saved model chat; otherwise it relaunches each active agent from its saved prompt file.

Check resume metadata:

```bash
bash "$ORCHESTRATION_HOME/lib/roster.sh" resume <agent-id>
```

Use `orch-restore` when you want panes recreated. `orch-preflight --repair` is for validating state and retargeting live panes; when the whole tmux session is missing it now leaves active roster entries untouched and points you here.

## Message queued but not visible in pane

This is usually a tmux target/notify issue. Check:

```bash
orch-status --log
bash "$ORCHESTRATION_HOME/lib/roster.sh" list-active
orch-preflight --repair
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

## Pane reordered or roster target stale

If you changed tmux layout, moved panes, or restored a session and roster targets no longer match:

```bash
orch-preflight --repair
bash "$ORCHESTRATION_HOME/lib/roster.sh" list-active
```

Repair uses tmux pane metadata (`@orch_agent_id`) to rewrite stale active-agent targets in `.agents/roster.json`.

## Task board inconsistent

```bash
jq . .agents/tasks.json
```

If corrupted, recover from `.agents/sessions/<timestamp>/tasks.json`.
