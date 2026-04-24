# Operations Guide

## Session lifecycle

1. Prepare context.
2. Launch a pattern.
3. Coordinate work.
4. End and archive.

## 1) Prepare context

```bash
mkdir -p .agents/contracts
cat > .agents/PROJECT_CONTEXT.md <<'EOF_CTX'
Stack: ...
Constraints: ...
EOF_CTX
```

Optional:

```bash
orch-preflight
```

## 2) Launch

```bash
orchestrate lean
orchestrate --switch-client lean
```

Use `--switch-client` only when launching from a tmux pane and you want the current tmux client to move to the new orchestration session. Without it, the launcher prints the switch command so existing tmux/iTerm views are not replaced unexpectedly.

## 3) Coordinate

### Messaging

```bash
orch-send orchestrator --type TASK "objective: ...; definition_of_done: ...; required_reply: ..."
orch-send coder-1 --type QUESTION "..."
orch-send --broadcast "..."
```

### Tasks

```bash
orch-task create "Design schema" --id t-schema
orch-task create "Implement API" --id t-api --depends t-schema
orch-task list-available
orch-task claim t-schema architect
orch-task complete t-schema architect --note "done"
```

### Monitoring

```bash
orch-status --follow
orch-enforce --on --interval 60
```

## 4) End

```bash
end-session
# or
end-session --keep-tmux
```

## Delivery modes

Set before starting the session:

```bash
export ORCH_DELIVERY=notify  # default
export ORCH_DELIVERY=push
export ORCH_DELIVERY=silent
```

- `notify`: inbox write + pane nudge.
- `push`: inbox write + direct pane paste.
- `silent`: inbox write only.

## Model and permissions controls

- `orchestrate` prompts role-by-role for model and permission bypass (interactive mode).
- `--yolo` skips questionnaire and uses pattern defaults.
- `--dangerously-skip-permissions` enables bypass for that run.
- `--respect-env-skip-permissions` keeps existing `ORCH_SKIP_PERMISSIONS*` env values.
