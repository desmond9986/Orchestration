# Terminal UI

`orch-tui` is a full-screen terminal control panel for the existing orchestration CLI. It supports keyboard navigation and mouse/click selection in terminals that support mouse reporting.

The interaction model is closer to an ops console than a command menu: top-level pages, a large resource viewport, an inspector panel for the selected row on wide terminals, a contextual action bar, searchable action picker, page filters, and expandable output/detail views.

It is not a second orchestration engine. It reads current `.agents` state for display and calls the existing command surface for actions.

## Start

```bash
orch-tui
```

Interactive mode requires `python3` because the full-screen UI uses Python curses. Plain snapshot output remains shell-only:

For scripts and tests:

```bash
orch-tui --snapshot
```

## Design Rule

The CLI remains the source of truth.

If the TUI needs a capability that does not exist yet, add a normal command first, then call that command from `orch-tui`.

Allowed:
- Read `.agents/roster.json`, `.agents/tasks.json`, `.agents/status.md`, `.agents/bus.md`, and `.agents/inbox/*.jsonl`.
- Call `orchestrate`, `add-agent`, `remove-agent`, `orch-send`, `orch-inbox`, `orch-task`, `orch-status`, `orch-preflight`, `orch-restore`, `orch-enforce`, and `end-session`.

Avoid:
- Directly editing `roster.json`.
- Directly creating/killing panes.
- Implementing separate task logic.
- Implementing separate restore logic.
- Special TUI-only behavior that differs from the CLI.

## Current Screens

- Session: browse/filter patterns, preview launch, launch selected pattern, restore, iTerm control-mode restore, preflight, end session.
- Agents: list, add, nudge selected, peek inbox, explicitly mark unread as read, inspect roster metadata, remove.
- Messages: send, reply to selected sender, peek selected inbox, broadcast, show recent/full bus.
- Tasks: create, show selected, claim, complete, block, unblock, list available, list available for agent, list all.
- Health: preflight, repair, restore, roster, status board, recent bus, enforce status/on/off, log view.

## Interactive Controls

- `1`-`5` or `Tab`: switch pages.
- `j`/`k` or arrow keys: move selected row.
- In expanded output, `j`/`k` and `PageUp`/`PageDown`: scroll command output.
- `h`/`l` or left/right arrows: move selected action.
- `Enter`: run the selected action.
- `:`: searchable action picker across all pages.
- `/`: filter the current page.
- `c`: clear the current page filter.
- `f`: expand the current detail page.
- `e` or `o`: expand command output.
- `x`: cancel a currently running command.
- `?`: show help overlay.
- `r`: refresh state.
- `q`: quit.

## Pattern Launching

The Session page lists the available `patterns/*.sh` entries with descriptions and selection guidance. The default Session action is `Preview launch`; move to `Start selected` when you are ready to start panes, then confirm launch flags and optional pattern args.

The default launch flag is `--yolo` so the TUI can start patterns non-interactively. Pattern files still declare their CLI defaults, many of which are `claude`, but the TUI asks for a model override before launch. That model defaults to `ORCH_TUI_DEFAULT_MODEL`, then `ORCH_DEFAULT_MODEL`, then `codex`. Type `pattern` in the model prompt to keep the pattern file defaults. If you enter attach/control-mode flags such as `--iterm-cc` or `--attach`, the TUI shows the command instead of running it inside curses.

## Layout Notes

- Narrow terminals hide the inspector to preserve list space. Press `f` to open selected-row detail.
- The output drawer stays collapsed until a command runs. Press `e`/`o` to expand recent command output.
- Commands run in the background with a live output drawer. Press `x` to terminate the running command.
- Row badges and action risk markers are textual, not color-only: `UNREAD`, `CLAIMED`, `DANGER`, `WRITE`, and similar labels remain understandable in low-color terminals.
- The action picker never executes the top fuzzy match automatically. Type `:`, enter a query, select a visible result, then press `Enter`.

## Scope

This first version uses a small Python curses frontend plus the existing shell command surface. A future version can move to a richer TUI framework, but it should keep the same rule: command wrappers first, UI second.
