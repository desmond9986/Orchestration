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
orch-preflight --repair
```

Use `orch-preflight --repair` when panes were reordered, tmux targets look stale, or required `.agents` files are missing. It recreates required task-state files and retargets active roster entries by matching live tmux pane metadata (`@orch_agent_id`).

If the tmux session was closed or killed but `<project>/.agents` still exists:

```bash
orch-restore
```

Run `orch-restore` first when the tmux session itself is missing. Use `orch-preflight --repair` after panes are live again or when only pane targets are stale.

`orch-restore` rebuilds missing panes from `.agents/roster.json`, keeps inbox/task state, and retargets the roster. If the roster has exact resume metadata, it resumes the saved model chat; otherwise it relaunches the agent from `.agents/prompts/<agent-id>.md`.

Claude resume IDs are generated before launch and stored in the roster. Codex resume IDs are captured best-effort from Codex session files after the first prompt is delivered. If a Codex resume ID is missing, restore starts a fresh Codex chat instead of using unsafe `codex resume --last`.

Inspect or manually set resume metadata:

```bash
bash "$ORCHESTRATION_HOME/lib/roster.sh" resume coder-1
bash "$ORCHESTRATION_HOME/lib/roster.sh" set-resume coder-1 codex <session-id> --mode exact
```

## 2) Launch

```bash
orch-tui
orchestrate lean
orchestrate --switch-client lean
orchestrate --iterm-cc lean
```

Use `orch-tui` when you want a full-screen guided terminal control panel with keyboard and mouse/click navigation. It reads existing `.agents` state and calls the same commands shown in this guide; it does not replace the CLI workflow.

Use `--switch-client` only when launching from a tmux pane and you want the current tmux client to move to the new orchestration session. Without it, the launcher prints the switch command so existing tmux/iTerm views are not replaced unexpectedly.

Use `--iterm-cc` or `-CC` from a normal iTerm shell when you want iTerm2 tmux control mode. It runs `tmux -CC attach-session -t <session>` after launch. Do not run it from inside an existing tmux pane.

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

### Recovering a closed tmux session

From the project root:

```bash
orch-restore
```

If you are outside tmux and want to attach immediately:

```bash
orch-restore --attach
```

For iTerm2 tmux control mode:

```bash
orch-restore --iterm-cc
# alias:
orch-restore -CC
```

If you are already inside tmux, avoid `--switch-client` unless you intentionally want to move the current tmux client to the restored session.

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
- `--yolo` skips the questionnaire and uses pattern defaults. It does **not** mean permission bypass by itself.
- `--dangerously-skip-permissions` enables bypass for that run.
- `--respect-env-skip-permissions` keeps existing `ORCH_SKIP_PERMISSIONS*` env values.

Codex CLI mapping:

```bash
# normal
codex --no-alt-screen

# with --dangerously-skip-permissions / ORCH_SKIP_PERMISSIONS=1
codex --dangerously-bypass-approvals-and-sandbox --no-alt-screen
```
