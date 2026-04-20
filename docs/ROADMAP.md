# Roadmap

## Near-term

- Better session UX (`orch ui` / guided command flows).
- Optional per-coder worktrees for multi-coder sessions.
- Stronger watchdog lifecycle tracking (`TASK -> ACK/IN_PROGRESS -> DONE/BLOCKED`).
- Smarter anti-loop detection and lower-noise nudging.

## Known gaps

- Pane-notify can still fail in edge tmux states.
- Some agents may echo inbox checks instead of executing requested work without stricter policy prompts.
- Long sessions may need manual pruning of runtime artifacts.
