# Roadmap

## Priority 0 (Reliability Hardening)

- Enforce clearer agent lifecycle signals (`TASK -> ACK/IN_PROGRESS -> DONE/BLOCKED`) with task/message correlation.
- Reduce false-positive loops via event-offset tracking (not just recent-window heuristics).
- Improve intervention strategy so nudges guide execution instead of causing command-echo loops.
- Continue portability hardening for lock/retry behavior under CI and high contention.

## Priority 1 (Operator Experience)

- Guided control plane (`orch ui`) for launch, assignment, monitoring, and teardown.
- Command-palette style flows for common actions (spawn, assign, retarget, unblock).
- Safer defaults and clearer one-shot “dangerous mode” behavior.

## Priority 2 (Scale And Collaboration)

- Optional per-coder git worktrees for multi-coder sessions.
- Better cross-agent task ownership and handoff visibility.
- Session presets/templates for repeatable workflows.

## Known Gaps (Current)

- Pane notify can still fail in edge tmux states.
- Some agents may echo inbox checks instead of executing requested work without stricter policy prompts.
- Long sessions may need manual pruning of runtime artifacts.
- Complex orchestrations still require high operator discipline.
