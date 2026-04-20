# Architecture Notes

## Runtime model

Per-project runtime state lives under `<project>/.agents/`:
- `roster.json`: active/removed agents and pane targets.
- `inbox/*.jsonl`: per-agent message inbox.
- `inbox/*.archive.jsonl`: read history.
- `bus.md` and `status.md`: human-readable global timelines.
- `tasks.json`: shared dependency-aware task board.

## Why file-first messaging

Messages are persisted before pane delivery attempts. This gives:
- durability,
- replayability,
- recoverability when pane notification fails.

## Why dynamic roster routing

Pane indexes are unstable. Role scripts resolve recipients by role/id via roster lookups instead of static pane numbers.

## Locking approach

Uses atomic directory locks (`mkdir`) for portability (including macOS default Bash environments), with stale lock cleanup.

## Delivery behavior

All delivery modes write to inbox first; pane behavior is mode-dependent (`notify`, `push`, `silent`).
