#!/usr/bin/env python3
"""Full-screen terminal UI for orchestration.

The UI is intentionally a control surface: it reads .agents state for display
and executes the existing CLI commands for actions.
"""

from __future__ import annotations

import curses
import json
import locale
import os
import select
import shlex
import subprocess
import threading
import textwrap
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable


ORCH_HOME = Path(os.environ.get("ORCHESTRATION_HOME", str(Path.home() / "orchestration")))
PROJECT = Path(os.environ.get("ORCH_PROJECT", os.getcwd())).resolve()
BIN_HOME = Path(os.environ.get("ORCH_TUI_BIN_HOME", str(ORCH_HOME / "bin")))


@dataclass
class Page:
    name: str
    key: str
    title: str
    subtitle: str


@dataclass
class Action:
    label: str
    handler: Callable[["App"], None]
    hint: str = ""
    risk: str = "safe"


PAGES = [
    Page("Session", "1", "Pattern Browser", "Choose a squad shape, then start or restore the tmux session."),
    Page("Agents", "2", "Agent Roster", "Inspect live agents, inboxes, and roster metadata."),
    Page("Messages", "3", "Message Bus", "Send durable messages without memorizing orch-send flags."),
    Page("Tasks", "4", "Task Board", "Create, claim, complete, block, and review shared work."),
    Page("Health", "5", "Health Desk", "Preflight, repair, restore, and enforcement controls."),
]


class Glyphs:
    def __init__(self):
        lang = f"{locale.getpreferredencoding(False)} {os.environ.get('LANG', '')}".lower()
        ascii_forced = os.environ.get("ORCH_TUI_ASCII", "") == "1"
        unicode_ok = not ascii_forced and "utf" in lang
        if unicode_ok:
            self.tl, self.tr, self.bl, self.br = "╭", "╮", "╰", "╯"
            self.h, self.v, self.cross = "─", "│", "┼"
            self.dot, self.arrow, self.check = "•", "›", "✓"
        else:
            self.tl, self.tr, self.bl, self.br = "+", "+", "+", "+"
            self.h, self.v, self.cross = "-", "|", "+"
            self.dot, self.arrow, self.check = "*", ">", "ok"


GLYPHS = Glyphs()


def agents_dir() -> Path:
    return PROJECT / ".agents"


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text())
    except Exception:
        return default


def tail_lines(path: Path, n: int) -> list[str]:
    try:
        return path.read_text(errors="replace").splitlines()[-n:]
    except Exception:
        return []


def read_inbox_messages(limit: int = 80) -> list[dict]:
    inbox = agents_dir() / "inbox"
    messages: list[dict] = []
    if not inbox.exists():
        return messages
    for path in sorted(inbox.glob("*.jsonl")):
        if path.name.endswith(".archive.jsonl"):
            continue
        agent_id = path.name[:-6]
        try:
            lines = path.read_text(errors="replace").splitlines()
        except Exception:
            continue
        for line in lines[-limit:]:
            try:
                msg = json.loads(line)
            except Exception:
                continue
            msg["inbox"] = agent_id
            messages.append(msg)
    messages.sort(key=lambda msg: (msg.get("read") is not False, str(msg.get("ts", ""))))
    return messages[:limit]


PATTERN_ORDER = [
    "lean",
    "lonely-coder",
    "plan-execute",
    "ship-it",
    "debug-squad",
    "spike",
    "pipeline",
    "review-loop",
    "swarm",
    "full-team",
    "freeform",
]


def pattern_metadata() -> list[dict]:
    pattern_dir = ORCH_HOME / "patterns"
    items: list[dict] = []
    for path in pattern_dir.glob("*.sh"):
        meta = parse_pattern(path)
        if meta:
            items.append(meta)
    order = {name: idx for idx, name in enumerate(PATTERN_ORDER)}
    return sorted(items, key=lambda item: (order.get(item["name"], 999), item["name"]))


def parse_pattern(path: Path) -> dict:
    name = path.stem
    desc = ""
    usage = f"orchestrate {name}"
    use_when: list[str] = []
    ask_models = ""
    mode = ""
    try:
        lines = path.read_text(errors="replace").splitlines()
    except Exception:
        return {"name": name, "description": "", "usage": usage, "use_when": "", "models": ""}

    for line in lines[:36]:
        stripped = line.strip()
        if not stripped.startswith("#"):
            continue
        text = stripped[1:].strip()
        if not text:
            if mode == "use":
                mode = ""
            continue
        if text.startswith("Description:"):
            mode = "desc"
            desc = text.split(":", 1)[1].strip()
            continue
        if text.startswith("AskModels:"):
            mode = ""
            ask_models = text.split(":", 1)[1].strip()
            continue
        if text.startswith("Usage:"):
            mode = ""
            usage = text.split(":", 1)[1].strip()
            continue
        if text.startswith("Use when:"):
            mode = "use"
            use_when.append(text.split(":", 1)[1].strip())
            continue
        if mode == "desc" and not text.startswith(("Use when:", "Usage:", "AskModels:")):
            desc = f"{desc} {text}".strip()
            continue
        if mode == "use" and not text.startswith(("Flow:", "How ", "Output:", "After ", "For most work")):
            use_when.append(text)

    return {
        "name": name,
        "description": desc.replace("[max team] ", ""),
        "usage": usage,
        "use_when": " ".join(use_when),
        "models": ask_models,
    }


def resolve_cmd(cmd: str) -> str:
    candidate = BIN_HOME / cmd
    if candidate.exists() and os.access(candidate, os.X_OK):
        return str(candidate)
    return cmd


def command_label(args: Iterable[str]) -> str:
    return " ".join(shlex.quote(a) for a in args)


def default_model() -> str:
    return os.environ.get("ORCH_TUI_DEFAULT_MODEL") or os.environ.get("ORCH_DEFAULT_MODEL") or "codex"


def match_query(value: str, query: str) -> bool:
    if not query:
        return True
    return query.lower() in value.lower()


def fuzzy_score(value: str, query: str) -> int:
    if not query:
        return 1
    value_l = value.lower()
    query_l = query.lower()
    pos = 0
    score = 0
    for char in query_l:
        found = value_l.find(char, pos)
        if found < 0:
            return 0
        score += 3 if found == pos else 1
        pos = found + 1
    if query_l in value_l:
        score += 8
    return score


class App:
    def __init__(self, stdscr):
        self.stdscr = stdscr
        self.section_index = 0
        self.action_index = 0
        self.row_index = 0
        self.output: list[str] = []
        self.output_scroll = 0
        self.message = "Ready"
        self.expanded_output = False
        self.expanded_detail = False
        self.show_help = False
        self.filters: dict[str, str] = {}
        self.click_zones: list[tuple[int, int, int, int, Callable[[], None]]] = []
        self.output_lock = threading.Lock()
        self.command_proc: subprocess.Popen | None = None
        self.command_thread: threading.Thread | None = None
        self.command_started = 0.0
        self.command_cmd = ""

    def run(self):
        curses.curs_set(0)
        curses.mousemask(curses.ALL_MOUSE_EVENTS | curses.REPORT_MOUSE_POSITION)
        self.stdscr.keypad(True)
        self.stdscr.timeout(250)
        self.init_colors()
        while True:
            self.render()
            key = self.stdscr.getch()
            if self.handle_key(key):
                self.cancel_running_command()
                return

    def handle_key(self, key: int) -> bool:
        if key == -1:
            return False
        if self.show_help:
            self.show_help = False
            return False
        if key in (ord("x"), ord("X")) and self.command_running():
            self.cancel_running_command()
            return False
        if key in (ord("q"), ord("Q")):
            return True
        if key in (ord("?"),):
            self.show_help = True
            return False
        if key in (ord("r"), ord("R")):
            self.message = "Refreshed"
            return False
        if key in (ord("e"), ord("E"), ord("o"), ord("O")):
            self.expanded_output = not self.expanded_output
            self.expanded_detail = False
            self.output_scroll = 0
            return False
        if key in (ord("f"), ord("F")):
            self.expanded_detail = not self.expanded_detail
            self.expanded_output = False
            return False
        if key == 27:
            self.expanded_output = False
            self.expanded_detail = False
            return False
        if key in (ord(":"),):
            if self.command_running():
                self.message = "command already running; press x to cancel"
                return False
            self.command_palette()
            return False
        if key in (ord("/"),):
            self.set_filter()
            return False
        if key in (ord("c"), ord("C")):
            self.filters[self.page().name] = ""
            return False
        if ord("1") <= key <= ord("5"):
            self.select_section(key - ord("1"))
            return False
        if key == 9:
            self.select_section((self.section_index + 1) % len(PAGES))
            return False
        if key == getattr(curses, "KEY_BTAB", 353):
            self.select_section((self.section_index - 1) % len(PAGES))
            return False
        actions = self.actions()
        if key in (curses.KEY_RIGHT, ord("l")) and actions:
            self.action_index = (self.action_index + 1) % len(actions)
            return False
        if key in (curses.KEY_LEFT, ord("h")) and actions:
            self.action_index = (self.action_index - 1) % len(actions)
            return False
        if self.expanded_output and key in (curses.KEY_DOWN, ord("j")):
            self.output_scroll = max(0, self.output_scroll - 1)
            return False
        if self.expanded_output and key in (curses.KEY_UP, ord("k")):
            self.output_scroll = self.output_scroll + 1
            return False
        if self.expanded_output and key in (curses.KEY_NPAGE,):
            self.output_scroll = max(0, self.output_scroll - 8)
            return False
        if self.expanded_output and key in (curses.KEY_PPAGE,):
            self.output_scroll = self.output_scroll + 8
            return False
        if key in (curses.KEY_DOWN, ord("j")):
            self.move_row(1)
            return False
        if key in (curses.KEY_UP, ord("k")):
            self.move_row(-1)
            return False
        if key in (curses.KEY_NPAGE,):
            self.move_row(8)
            return False
        if key in (curses.KEY_PPAGE,):
            self.move_row(-8)
            return False
        if key in (curses.KEY_ENTER, 10, 13) and actions:
            if self.command_running():
                self.message = "command already running; press x to cancel"
                return False
            self.expanded_output = False
            self.expanded_detail = False
            actions[self.action_index].handler(self)
            return False
        if key == curses.KEY_MOUSE:
            self.handle_mouse()
        return False

    def init_colors(self):
        curses.start_color()
        curses.use_default_colors()
        # Low-noise palette: neutral text, one blue focus, yellow/red only for risk.
        curses.init_pair(1, curses.COLOR_BLACK, curses.COLOR_WHITE)
        curses.init_pair(2, curses.COLOR_BLUE, -1)
        curses.init_pair(3, curses.COLOR_WHITE, -1)
        curses.init_pair(4, curses.COLOR_YELLOW, -1)
        curses.init_pair(5, curses.COLOR_RED, -1)
        curses.init_pair(6, curses.COLOR_WHITE, curses.COLOR_BLUE)
        curses.init_pair(7, curses.COLOR_WHITE, -1)
        curses.init_pair(8, curses.COLOR_WHITE, -1)

    def page(self) -> Page:
        return PAGES[self.section_index]

    def state(self) -> dict:
        roster = read_json(agents_dir() / "roster.json", {})
        tasks = read_json(agents_dir() / "tasks.json", {"tasks": []})
        agents = [a for a in roster.get("agents", []) if a.get("status") == "active"]
        messages = read_inbox_messages()
        unread = sum(1 for msg in messages if msg.get("read") is False)
        task_counts = {"pending": 0, "claimed": 0, "blocked": 0, "done": 0}
        for task in tasks.get("tasks", []):
            status = task.get("status")
            if status in task_counts:
                task_counts[status] += 1
        return {
            "session": roster.get("session") or "none",
            "agents": agents,
            "messages": messages,
            "tasks": tasks.get("tasks", []),
            "unread": unread,
            "task_counts": task_counts,
            "has_session": bool(roster.get("session")),
        }

    def actions(self) -> list[Action]:
        return [
            self.session_actions,
            self.agent_actions,
            self.message_actions,
            self.task_actions,
            self.health_actions,
        ][self.section_index]()

    def session_actions(self) -> list[Action]:
        return [
            Action("Preview launch", lambda app: app.preview_pattern_launch(), "show command without running"),
            Action("Start selected", lambda app: app.start_pattern(), "orchestrate --yolo <selected-pattern>", "mutating"),
            Action("Restore panes", lambda app: app.run_lifecycle_cmd(["orch-restore", "--no-attach"]), risk="mutating"),
            Action("Show iTerm cmd", lambda app: app.show_command(["orch-restore", "--iterm-cc"]), "copy/run outside TUI"),
            Action("Preflight", lambda app: app.run_cmd(["orch-preflight"])),
            Action("End session", lambda app: app.end_session(), risk="destructive"),
        ]

    def agent_actions(self) -> list[Action]:
        return [
            Action("Add agent", lambda app: app.add_agent(), "add-agent", "mutating"),
            Action("Nudge selected", lambda app: app.nudge_selected_agent(), "ask agent to check inbox", "mutating"),
            Action("Peek inbox", lambda app: app.peek_inbox()),
            Action("Mark read", lambda app: app.check_inbox(), "destructive: archives unread", "destructive"),
            Action("Roster", lambda app: app.show_roster_metadata(), "orch-status --roster"),
            Action("Remove agent", lambda app: app.remove_agent(), "remove-agent", "destructive"),
        ]

    def message_actions(self) -> list[Action]:
        return [
            Action("Send", lambda app: app.send_message(), "orch-send <agent>", "mutating"),
            Action("Reply", lambda app: app.reply_to_selected_message(), "reply to selected message sender", "mutating"),
            Action("Peek selected", lambda app: app.peek_selected_message_inbox(), "peek selected inbox"),
            Action("Broadcast", lambda app: app.broadcast_message(), risk="mutating"),
            Action("Recent bus", lambda app: app.run_cmd(["orch-status"])),
            Action("Full bus", lambda app: app.run_cmd(["orch-status", "--bus"])),
        ]

    def task_actions(self) -> list[Action]:
        return [
            Action("Create", lambda app: app.create_task(), risk="mutating"),
            Action("Show selected", lambda app: app.show_selected_task(), "orch-task show <task>"),
            Action("Claim", lambda app: app.claim_task(), risk="mutating"),
            Action("Complete", lambda app: app.complete_task(), risk="mutating"),
            Action("Block", lambda app: app.block_task(), risk="mutating"),
            Action("Unblock", lambda app: app.unblock_task(), risk="mutating"),
            Action("Available", lambda app: app.run_cmd(["orch-task", "list-available"])),
            Action("Available for agent", lambda app: app.available_for_agent(), "orch-task list-available --for <agent>"),
            Action("All tasks", lambda app: app.run_cmd(["orch-task", "list"])),
        ]

    def health_actions(self) -> list[Action]:
        return [
            Action("Preflight", lambda app: app.run_cmd(["orch-preflight"])),
            Action("Repair", lambda app: app.run_cmd(["orch-preflight", "--repair"]), "orch-preflight --repair", "mutating"),
            Action("Restore", lambda app: app.run_lifecycle_cmd(["orch-restore", "--no-attach"]), risk="mutating"),
            Action("Roster", lambda app: app.run_cmd(["orch-status", "--roster"])),
            Action("Status board", lambda app: app.run_cmd(["orch-status", "--status"])),
            Action("Recent bus", lambda app: app.run_cmd(["orch-status"])),
            Action("Enforce status", lambda app: app.run_cmd(["orch-enforce", "--status"])),
            Action("Enforce on", lambda app: app.run_cmd(["orch-enforce", "--on"]), risk="mutating"),
            Action("Enforce off", lambda app: app.run_cmd(["orch-enforce", "--off"]), risk="mutating"),
            Action("Log", lambda app: app.run_cmd(["orch-status", "--log"])),
        ]

    def render(self):
        self.click_zones = []
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()
        if h < 24 or w < 88:
            self.addstr(0, 0, f"orch-tui needs at least 88x24; current {w}x{h}", curses.color_pair(5) | curses.A_BOLD)
            self.addstr(2, 0, "Resize the terminal or run: orch-tui --snapshot")
            self.stdscr.refresh()
            return
        state = self.state()
        self.draw_shell(h, w, state)
        if self.show_help:
            self.draw_help_overlay(h, w)
        self.stdscr.refresh()

    def draw_shell(self, h: int, w: int, state: dict):
        self.draw_header(w, state)
        self.draw_tabs(w)
        if self.expanded_output:
            self.draw_expanded_output(h, w)
        elif self.expanded_detail:
            self.draw_expanded_detail(h, w, state)
        else:
            self.draw_page(h, w, state)
        self.draw_action_bar(h, w)
        self.draw_footer(h, w)

    def draw_header(self, w: int, state: dict):
        self.fill(0, 0, w, " ", curses.color_pair(1) | curses.A_BOLD)
        self.addstr(0, 2, "ORCHESTRATION", curses.color_pair(1) | curses.A_BOLD)
        self.addstr(0, 18, self.clip(str(PROJECT), max(10, w - 56)), curses.color_pair(1))
        right = f"session {state['session']}"
        self.addstr(0, max(2, w - len(right) - 2), right, curses.color_pair(1) | curses.A_BOLD)

        counts = state["task_counts"]
        chips = [
            (f"agents {len(state['agents'])}", 8),
            (f"unread {state['unread']}", 4 if state["unread"] else 3),
            (f"pending {counts['pending']}", 8),
            (f"claimed {counts['claimed']}", 3),
            (f"blocked {counts['blocked']}", 5 if counts["blocked"] else 8),
            (f"done {counts['done']}", 8),
        ]
        x = 2
        for label, color in chips:
            x = self.draw_chip(2, x, label, color) + 1
        filter_text = self.current_filter()
        if filter_text:
            self.addstr(2, max(x + 2, w - len(filter_text) - 14), f"filter: {filter_text}", curses.color_pair(4))
        self.hline(4, 0, w)

    def draw_tabs(self, w: int):
        x = 2
        for idx, page in enumerate(PAGES):
            selected = idx == self.section_index
            attr = curses.color_pair(6) | curses.A_BOLD if selected else self.muted_attr()
            label = f" {page.key} {page.name} "
            self.addstr(5, x, label, attr)
            self.click_zones.append((5, x, 5, x + len(label), lambda i=idx: self.select_section(i)))
            x += len(label) + 1
        self.hline(6, 0, w)

    def draw_page(self, h: int, w: int, state: dict):
        top = 8
        bottom_reserved = 8 if self.output else 5
        body_h = max(8, h - top - bottom_reserved)
        show_inspector = w >= 112
        main_w = int(w * 0.64) if show_inspector else w - 4
        inspector_w = w - main_w - 5
        self.draw_panel(top, 2, body_h, main_w, self.page().title)
        self.draw_page_header(top, 4, main_w - 4)
        rows = self.current_rows(state)
        visible_rows = max(0, body_h - (5 if show_inspector else 6))
        self.clamp_row(rows)
        self.draw_rows(top + 4, 4, visible_rows, main_w - 4, rows)
        if show_inspector:
            self.draw_panel(top, main_w + 3, body_h, inspector_w, "Inspector")
            self.draw_inspector(top + 2, main_w + 5, body_h - 3, inspector_w - 4, state, rows)
        else:
            self.addstr(top + body_h - 2, 4, "narrow view: press f for selected detail", self.muted_attr())
        self.draw_output_drawer(h, w)

    def draw_page_header(self, y: int, x: int, width: int):
        page = self.page()
        self.addstr(y + 1, x, self.clip(page.subtitle, width), curses.color_pair(8) | curses.A_BOLD)
        hints = {
            "Session": "j/k chooses pattern. Start selected uses highlighted row; / filters.",
            "Agents": "j/k select agent. Enter runs selected action. / filters rows.",
            "Messages": "Unread inbox items are shown first. Use Send/Broadcast below.",
            "Tasks": "j/k select task. Use actions below to mutate via orch-task.",
            "Health": "Run checks left-to-right: preflight, repair, restore, enforce.",
        }
        self.addstr(y + 2, x, self.clip(hints.get(page.name, ""), width), self.muted_attr())
        self.addstr(y + 3, x, self.clip(self.column_header(width), width), self.muted_attr() | curses.A_BOLD)

    def column_header(self, width: int) -> str:
        title_w = max(12, min(24, width // 3))
        value = {
            "Session": "description / state",
            "Agents": "role | model | pane target",
            "Messages": "payload / bus line",
            "Tasks": "status | owner | title",
            "Health": "current value",
        }.get(self.page().name, "value")
        return f"  {'type':<8} {'item':<{title_w}} {value}"

    def current_rows(self, state: dict) -> list[dict]:
        section = self.page().name
        query = self.current_filter().lower()
        if section == "Session":
            rows = [
                {
                    "kind": "pattern",
                    "title": item["name"],
                    "value": item["description"],
                    "status": "ok" if item["name"] == "lean" else "info",
                    "raw": item,
                }
                for item in pattern_metadata()
            ]
            rows.extend([
                {"kind": "metric", "title": "Current session", "value": state["session"], "status": "ok" if state["has_session"] else "warn"},
                {"kind": "metric", "title": "Project", "value": str(PROJECT), "status": "dim"},
            ])
        elif section == "Agents":
            rows = [
                {
                    "kind": "agent",
                    "title": agent.get("id", ""),
                    "value": f"{agent.get('role','')} | {agent.get('model','')} | {agent.get('target','')}",
                    "status": "ok",
                    "raw": agent,
                }
                for agent in state["agents"]
            ]
        elif section == "Messages":
            messages = sorted(state["messages"], key=lambda msg: (msg.get("read") is not False, msg.get("ts", "")))
            rows = [
                {
                    "kind": "message",
                    "title": f"{msg.get('inbox','?')} <- {msg.get('from','?')} [{msg.get('type','INFO')}]",
                    "value": str(msg.get("payload", "")),
                    "status": "warn" if msg.get("read") is False else "dim",
                    "raw": msg,
                }
                for msg in messages
            ]
            rows.extend({"kind": "bus", "title": line, "value": "", "status": "dim"} for line in tail_lines(agents_dir() / "bus.md", 18))
        elif section == "Tasks":
            rows = [
                {
                    "kind": "task",
                    "title": task.get("id", ""),
                    "value": f"{task.get('status','')} | {task.get('owner') or '-'} | {task.get('title','')}",
                    "status": self.task_status(task.get("status", "")),
                    "raw": task,
                }
                for task in state.get("tasks", [])
            ]
        elif section == "Health":
            counts = state["task_counts"]
            rows = [
                {"kind": "check", "title": "Roster present", "value": state["session"], "status": "ok" if state["has_session"] else "warn"},
                {"kind": "check", "title": "Active agents", "value": str(len(state["agents"])), "status": "ok" if state["agents"] else "warn"},
                {"kind": "check", "title": "Unread inbox", "value": str(state["unread"]), "status": "warn" if state["unread"] else "ok"},
                {"kind": "check", "title": "Blocked tasks", "value": str(counts["blocked"]), "status": "bad" if counts["blocked"] else "ok"},
                {"kind": "check", "title": "Recent log", "value": "Latest .agents/log.md", "status": "info"},
            ]
            rows.extend({"kind": "log", "title": line, "value": "", "status": "dim"} for line in tail_lines(agents_dir() / "log.md", 14))
        else:
            rows = []
        if query:
            rows = [row for row in rows if query in f"{row.get('title','')} {row.get('value','')}".lower()]
        return rows

    def draw_rows(self, y: int, x: int, height: int, width: int, rows: list[dict]):
        if not rows:
            for offset, line in enumerate(self.empty_lines()[:height]):
                self.addstr(y + offset, x, self.clip(line, width), curses.color_pair(4) if offset == 0 else self.muted_attr())
            return
        start = 0
        if self.row_index >= height:
            start = self.row_index - height + 1
        for offset, row in enumerate(rows[start:start + height]):
            idx = start + offset
            selected = idx == self.row_index
            attr = curses.color_pair(6) | curses.A_BOLD if selected else self.status_attr(row.get("status", "info"))
            marker = GLYPHS.arrow if selected else " "
            badge = self.row_badge(row)
            title_w = max(12, min(24, width // 3))
            left = self.clip(str(row.get("title", "")), title_w)
            right_w = max(10, width - title_w - len(badge) - 5)
            right = self.clip(str(row.get("value", "")), right_w)
            line = f"{marker} {badge:<8} {left:<{title_w}} {right}"
            self.addstr(y + offset, x, self.clip(line.ljust(width), width), attr)
            self.click_zones.append((y + offset, x, y + offset, x + width, lambda i=idx: self.select_row(i)))

    def empty_lines(self) -> list[str]:
        if self.current_filter():
            return [
                f"No matches for filter: {self.current_filter()}",
                "Press c to clear the filter or / to change it.",
            ]
        page = self.page().name
        return {
            "Session": ["No patterns found.", "Check ORCHESTRATION_HOME/patterns or run orchestrate list."],
            "Agents": ["No active agents.", "Use Restore panes if a session exists, or Add agent to grow the roster."],
            "Messages": ["No unread inbox messages.", "Use Recent bus or Full bus for protocol history."],
            "Tasks": ["No tasks yet.", "Run Create to add a task or Available to check the board."],
            "Health": ["No health rows.", "Run Preflight to inspect the project state."],
        }.get(page, ["No rows."])

    @staticmethod
    def row_badge(row: dict) -> str:
        kind = str(row.get("kind", ""))
        if kind == "message":
            return "UNREAD" if row.get("raw", {}).get("read") is False else "MSG"
        if kind == "task":
            return str(row.get("raw", {}).get("status") or "TASK").upper()[:8]
        return {
            "pattern": "PATTERN",
            "metric": "STATE",
            "agent": "AGENT",
            "bus": "BUS",
            "check": "CHECK",
            "log": "LOG",
        }.get(kind, kind.upper()[:8] or "ROW")

    def draw_inspector(self, y: int, x: int, height: int, width: int, state: dict, rows: list[dict]):
        lines = self.inspector_lines(state, rows, width)
        for idx, line in enumerate(lines[:height]):
            attr = curses.A_BOLD if idx == 0 else curses.A_NORMAL
            self.addstr(y + idx, x, self.clip(line, width), attr)

    def inspector_lines(self, state: dict, rows: list[dict], width: int) -> list[str]:
        section = self.page().name
        selected = rows[self.row_index] if rows and self.row_index < len(rows) else None
        if section == "Session":
            if selected and selected.get("kind") == "pattern":
                pattern = selected.get("raw", {})
                lines = [
                    f"Pattern {pattern.get('name','')}",
                    "",
                    "What it starts:",
                    *textwrap.wrap(str(pattern.get("description", "")), width=width),
                    "",
                    f"Run: {pattern.get('usage','')}",
                ]
                use_when = str(pattern.get("use_when", ""))
                if use_when:
                    lines.extend(["", "Use when:", *textwrap.wrap(use_when, width=width)])
                models = str(pattern.get("models", ""))
                if models:
                    lines.extend(["", "Pattern defaults:", *textwrap.wrap(models, width=width)])
                    lines.extend(["", f"TUI launch default: all roles -> {default_model()}"])
                return lines
            return [
                "What to do here",
                "Pick a pattern row, then run Start selected.",
                "Use / to filter names/descriptions.",
                "Restore when tmux panes disappeared.",
                "Preflight before debugging weird state.",
                "End session archives runtime files.",
                "",
                "Recent output: press e/o",
                "Full detail: press f",
            ]
        if section == "Agents":
            if not selected:
                return ["No agent selected", "Add an agent or restore a session."]
            agent = selected.get("raw", {})
            return [
                f"Agent {agent.get('id','')}",
                f"role:   {agent.get('role','')}",
                f"model:  {agent.get('model','')}",
                f"target: {agent.get('target','')}",
                f"resume: {agent.get('resume','') or '-'}",
                f"hats:   {', '.join(agent.get('hats', []) or []) or '-'}",
                "",
                "Use Peek inbox before assuming an agent is stuck.",
            ]
        if section == "Messages":
            if selected and selected.get("kind") == "message":
                msg = selected.get("raw", {})
                return [
                    f"Message {msg.get('id','')}",
                    f"to:   {msg.get('inbox','')}",
                    f"from: {msg.get('from','')}",
                    f"type: {msg.get('type','')}",
                    f"read: {msg.get('read')}",
                    "",
                    *textwrap.wrap(str(msg.get("payload", "")), width=width),
                ]
            return ["Message bus", "Send and broadcast keep inbox durability.", "Use recent/full bus for protocol history."]
        if section == "Tasks":
            if not selected:
                return ["No task selected", "Create or list tasks first."]
            task = selected.get("raw", {})
            return [
                f"Task {task.get('id','')}",
                f"status: {task.get('status','')}",
                f"owner:  {task.get('owner') or '-'}",
                f"deps:   {', '.join(task.get('depends_on', []) or []) or '-'}",
                "",
                *textwrap.wrap(str(task.get("title", "")), width=width),
                "",
                *textwrap.wrap(str(task.get("note", "")), width=width),
            ]
        if section == "Health":
            return [
                "Operator flow",
                "1. Preflight",
                "2. Repair if stale files/targets appear",
                "3. Restore if panes disappeared",
                "4. Turn enforce on if agents drift",
                "",
                "This page should explain action, not dump noise.",
            ]
        return []

    def draw_expanded_detail(self, h: int, w: int, state: dict):
        rows = self.current_rows(state)
        self.draw_panel(8, 2, h - 11, w - 4, f"{self.page().title} expanded")
        lines = self.expanded_lines(state, rows, w - 8)
        for idx, line in enumerate(lines[: h - 15]):
            self.addstr(10 + idx, 4, self.clip(line, w - 8), curses.A_NORMAL)
        self.addstr(h - 4, 4, "Press f or Esc to collapse", curses.color_pair(4))

    def expanded_lines(self, state: dict, rows: list[dict], width: int) -> list[str]:
        lines = [self.page().subtitle, ""]
        lines.extend(self.inspector_lines(state, rows, width))
        return lines or ["No content"]

    def draw_output_drawer(self, h: int, w: int):
        output = self.output_snapshot()
        if not output:
            y = h - 4
            self.fill(y, 0, w, " ")
            action = self.actions()[self.action_index] if self.actions() else None
            hint = ""
            if action:
                hint = action.hint or {"safe": "read-only", "mutating": "changes state", "destructive": "requires confirmation"}.get(action.risk, "")
                hint = f" | action {action.label}: {hint}"
            self.addstr(y, 2, self.clip(f"{self.message}{hint}", w - 4), self.muted_attr())
            return
        y = h - 7
        self.draw_panel(y, 2, 4, w - 4, "Output")
        lines = output[-2:]
        for idx, line in enumerate(lines[:2]):
            self.addstr(y + 1 + idx, 4, self.clip(line, w - 8), curses.color_pair(8))
        footer = "e/o expands output"
        if self.command_running():
            footer = f"running {self.spinner()} {self.elapsed_label()} | press x to cancel | e/o expands output"
        self.addstr(y + 3, 4, self.clip(footer, w - 8), curses.color_pair(4))

    def draw_expanded_output(self, h: int, w: int):
        self.draw_panel(8, 2, h - 11, w - 4, "Command Output")
        lines = self.output_snapshot() or [self.message]
        max_lines = h - 15
        max_scroll = max(0, len(lines) - max_lines)
        self.output_scroll = min(max(self.output_scroll, 0), max_scroll)
        start = max(0, len(lines) - max_lines - self.output_scroll)
        visible = lines[start:start + max_lines]
        for idx, line in enumerate(visible):
            self.addstr(10 + idx, 4, self.clip(line, w - 8))
        scroll = f" | scroll {self.output_scroll}/{max_scroll}" if max_scroll else ""
        footer = f"j/k or PgUp/PgDn scroll{scroll} | e/o or Esc collapse"
        if self.command_running():
            footer = f"running {self.spinner()} {self.elapsed_label()} | press x to cancel | {footer}"
        self.addstr(h - 4, 4, self.clip(footer, w - 8), curses.color_pair(4))

    def draw_action_bar(self, h: int, w: int):
        y = h - 3
        self.fill(y, 0, w, " ")
        actions = self.actions()
        if not actions:
            return
        start = max(0, self.action_index - 2)
        x = 2
        if start > 0:
            self.addstr(y, x, "<", self.muted_attr())
            x += 2
        for idx in range(start, len(actions)):
            action = actions[idx]
            selected = idx == self.action_index
            attr = self.action_attr(action, selected)
            marker = GLYPHS.arrow if selected else " "
            label = f" {marker} {self.action_badge(action)}{action.label} "
            if x + len(label) >= w - 2:
                hidden = len(actions) - idx
                overflow = f" +{hidden} more >"
                if x + len(overflow) >= w - 2:
                    overflow = " >"
                self.addstr(y, x, overflow, curses.color_pair(4))
                break
            self.addstr(y, x, label, attr)
            self.click_zones.append((y, x, y, x + len(label), lambda i=idx: self.run_action(i)))
            x += len(label) + 1

    def action_attr(self, action: Action, selected: bool) -> int:
        if selected:
            return curses.color_pair(6) | curses.A_BOLD
        if action.risk == "destructive":
            return curses.color_pair(5) | curses.A_BOLD
        if action.risk == "mutating":
            return curses.color_pair(8)
        return self.muted_attr()

    @staticmethod
    def action_badge(action: Action) -> str:
        return {"destructive": "! ", "mutating": "+ ", "safe": ""}.get(action.risk, "")

    def draw_footer(self, h: int, w: int):
        if self.command_running():
            footer = f" RUNNING {self.spinner()} {self.command_cmd} ({self.elapsed_label()}) | x cancel | e output | q quit "
        else:
            footer = " ? help | : actions | / filter | c clear | Tab/1-5 page | h/l action | j/k row | Enter run | f detail | e output | q quit "
        self.fill(h - 1, 0, w, " ", curses.color_pair(1))
        self.addstr(h - 1, 1, self.clip(footer, w - 2), curses.color_pair(1))

    def draw_help_overlay(self, h: int, w: int):
        oh = min(18, h - 4)
        ow = min(76, w - 8)
        y = max(2, (h - oh) // 2)
        x = max(2, (w - ow) // 2)
        self.draw_panel(y, x, oh, ow, "Help")
        lines = [
            "This TUI follows the same model as good ops TUIs:",
            "tabs/pages for resources, selected-row inspector, action bar, command jump.",
            "",
            "1-5 / Tab      change page",
            "j/k or arrows   move selected row",
            "h/l             move selected action",
            "Enter           run selected action",
            ":               searchable action picker",
            "/               filter current page",
            "c               clear current filter",
            "f               expand current detail page",
            "e/o             expand command output",
            "j/k PgUp/PgDn   scroll expanded output",
            "x               cancel running command",
            "r               refresh state",
            "q               quit",
            "",
            "Press any key to close help.",
        ]
        for idx, line in enumerate(lines[: oh - 2]):
            self.addstr(y + 1 + idx, x + 2, self.clip(line, ow - 4), curses.color_pair(8))

    def draw_panel(self, y: int, x: int, height: int, width: int, title: str):
        if height < 3 or width < 8:
            return
        for row in range(y, y + height):
            self.fill(row, x, width, " ")
        border = self.border_attr()
        self.addstr(y, x, GLYPHS.tl + GLYPHS.h * (width - 2) + GLYPHS.tr, border)
        for row in range(y + 1, y + height - 1):
            self.addstr(row, x, GLYPHS.v, border)
            self.addstr(row, x + width - 1, GLYPHS.v, border)
        self.addstr(y + height - 1, x, GLYPHS.bl + GLYPHS.h * (width - 2) + GLYPHS.br, border)
        label = f" {title} "
        self.addstr(y, x + 2, self.clip(label, width - 4), curses.color_pair(7) | curses.A_BOLD)

    def draw_chip(self, y: int, x: int, label: str, color: int) -> int:
        text = f" {label} "
        attr = curses.color_pair(color)
        if color in (4, 5):
            attr |= curses.A_BOLD
        self.addstr(y, x, text, attr)
        return x + len(text)

    def handle_mouse(self):
        try:
            _, mx, my, _, bstate = curses.getmouse()
        except curses.error:
            return
        if not (bstate & curses.BUTTON1_CLICKED or bstate & curses.BUTTON1_RELEASED):
            return
        for y1, x1, y2, x2, callback in self.click_zones:
            if y1 <= my <= y2 and x1 <= mx <= x2:
                callback()
                return

    def select_section(self, idx: int):
        self.section_index = idx
        self.action_index = 0
        self.row_index = 0
        self.expanded_output = False
        self.expanded_detail = False

    def select_row(self, idx: int):
        self.row_index = max(0, idx)

    def run_action(self, idx: int):
        if self.command_running():
            self.message = "command already running; press x to cancel"
            return
        actions = self.actions()
        if 0 <= idx < len(actions):
            self.action_index = idx
            self.expanded_output = False
            self.expanded_detail = False
            actions[idx].handler(self)

    def move_row(self, delta: int):
        rows = self.current_rows(self.state())
        if not rows:
            self.row_index = 0
            return
        self.row_index = min(max(0, self.row_index + delta), len(rows) - 1)

    def clamp_row(self, rows: list[dict]):
        if not rows:
            self.row_index = 0
        else:
            self.row_index = min(max(0, self.row_index), len(rows) - 1)

    def current_filter(self) -> str:
        return self.filters.get(self.page().name, "")

    def set_filter(self):
        query = self.prompt("Filter current page", self.current_filter())
        self.filters[self.page().name] = query
        self.row_index = 0

    def command_palette(self):
        query = self.prompt("Command")
        if not query:
            return
        candidates: list[tuple[int, int, Action]] = []
        for page_idx, page in enumerate(PAGES):
            old_idx = self.section_index
            self.section_index = page_idx
            for action in self.actions():
                haystack = f"{page.name} {action.label} {action.hint}"
                score = fuzzy_score(haystack, query)
                if score:
                    candidates.append((score, page_idx, action))
            self.section_index = old_idx
        if not candidates:
            self.output = [f"No command matched: {query}"]
            self.message = "No command matched"
            return
        selected = self.pick_command(query, sorted(candidates, key=lambda item: item[0], reverse=True)[:12])
        if not selected:
            self.message = "command cancelled"
            return
        _score, page_idx, action = selected
        self.select_section(page_idx)
        actions = self.actions()
        for idx, candidate in enumerate(actions):
            if candidate.label == action.label:
                self.action_index = idx
                break
        action.handler(self)

    def pick_command(self, query: str, candidates: list[tuple[int, int, Action]]) -> tuple[int, int, Action] | None:
        selected = 0
        while True:
            self.stdscr.erase()
            h, w = self.stdscr.getmaxyx()
            self.draw_shell(h, w, self.state())
            self.draw_command_picker(h, w, query, candidates, selected)
            self.stdscr.refresh()
            key = self.stdscr.getch()
            if key in (27, ord("q"), ord("Q")):
                return None
            if key in (curses.KEY_DOWN, ord("j")):
                selected = min(selected + 1, len(candidates) - 1)
                continue
            if key in (curses.KEY_UP, ord("k")):
                selected = max(selected - 1, 0)
                continue
            if key in (curses.KEY_NPAGE,):
                selected = min(selected + 6, len(candidates) - 1)
                continue
            if key in (curses.KEY_PPAGE,):
                selected = max(selected - 6, 0)
                continue
            if key in (curses.KEY_ENTER, 10, 13):
                return candidates[selected]

    def draw_command_picker(self, h: int, w: int, query: str, candidates: list[tuple[int, int, Action]], selected: int):
        oh = min(max(10, len(candidates) + 5), h - 4)
        ow = min(88, w - 8)
        y = max(2, (h - oh) // 2)
        x = max(2, (w - ow) // 2)
        self.draw_panel(y, x, oh, ow, "Action Picker")
        self.addstr(y + 1, x + 2, self.clip(f"Query: {query}", ow - 4), curses.color_pair(4) | curses.A_BOLD)
        self.addstr(y + 2, x + 2, "Select an action, then press Enter. Esc/q cancels.", self.muted_attr())
        max_rows = oh - 5
        for idx, (_score, page_idx, action) in enumerate(candidates[:max_rows]):
            attr = curses.color_pair(6) | curses.A_BOLD if idx == selected else self.action_attr(action, False)
            marker = GLYPHS.arrow if idx == selected else " "
            risk = {"safe": "READ", "mutating": "WRITE", "destructive": "DANGER"}.get(action.risk, action.risk.upper())
            label = f"{marker} {PAGES[page_idx].name:<8} {risk:<6} {action.label:<20} {action.hint}"
            self.addstr(y + 4 + idx, x + 2, self.clip(label, ow - 4), attr)
        if len(candidates) > max_rows:
            self.addstr(y + oh - 2, x + 2, f"+{len(candidates) - max_rows} more matches, refine the query", curses.color_pair(4))

    def prompt(self, label: str, default: str = "") -> str:
        h, w = self.stdscr.getmaxyx()
        prompt = f"{label}"
        if default:
            prompt += f" [{self.clip(default, max(8, w // 3))}]"
        prompt += ": "
        self.fill(h - 2, 0, w, " ", curses.color_pair(4))
        self.addstr(h - 2, 1, self.clip(prompt, w - 2), curses.color_pair(4) | curses.A_BOLD)
        input_x = min(len(prompt) + 1, max(1, w - 24))
        input_width = max(8, w - input_x - 2)
        curses.curs_set(1)
        curses.echo()
        self.stdscr.move(h - 2, input_x)
        try:
            raw = self.stdscr.getstr(h - 2, input_x, input_width)
            value = raw.decode(errors="replace").strip()
        except Exception:
            value = ""
        curses.noecho()
        curses.curs_set(0)
        return value or default

    def confirm(self, label: str, expected: str) -> bool:
        value = self.prompt(label, "")
        return value == expected

    def output_snapshot(self) -> list[str]:
        with self.output_lock:
            return list(self.output)

    def set_output(self, lines: list[str]):
        with self.output_lock:
            self.output = lines[-200:]

    def append_output(self, line: str):
        with self.output_lock:
            self.output.append(line)
            self.output = self.output[-200:]

    def command_running(self) -> bool:
        return bool(self.command_thread and self.command_thread.is_alive())

    def elapsed_label(self) -> str:
        if not self.command_started:
            return "0s"
        return f"{int(time.monotonic() - self.command_started)}s"

    def spinner(self) -> str:
        if not self.command_started:
            return ""
        return "|/-\\"[int((time.monotonic() - self.command_started) * 4) % 4]

    def cancel_running_command(self):
        proc = self.command_proc
        if proc and proc.poll() is None:
            try:
                proc.terminate()
                self.append_output("cancel requested")
                self.message = "cancel requested"
            except Exception as exc:
                self.append_output(f"cancel failed: {exc}")
                self.message = "cancel failed"

    def run_cmd(self, args: list[str], timeout: int = 90, extra_env: dict[str, str] | None = None):
        if self.command_running():
            self.message = "command already running; press x to cancel"
            return
        resolved = [resolve_cmd(args[0]), *args[1:]]
        env = os.environ.copy()
        env["ORCHESTRATION_HOME"] = str(ORCH_HOME)
        env["ORCH_PROJECT"] = str(PROJECT)
        if extra_env:
            env.update(extra_env)
        self.command_cmd = command_label(args)
        self.command_started = time.monotonic()
        self.output_scroll = 0
        lines = [f"$ {self.command_cmd}"]
        if extra_env:
            lines.append("env: " + " ".join(f"{k}={v}" for k, v in sorted(extra_env.items())))
        lines.append("running...")
        self.set_output(lines)
        self.message = f"running: {self.command_cmd}"
        self.expanded_output = True
        self.command_thread = threading.Thread(
            target=self.command_worker,
            args=(args, resolved, env, timeout),
            daemon=True,
        )
        self.command_thread.start()

    def command_worker(self, args: list[str], resolved: list[str], env: dict[str, str], timeout: int | None):
        label = command_label(args)
        try:
            proc = subprocess.Popen(
                resolved,
                cwd=str(PROJECT),
                env=env,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                bufsize=1,
            )
            self.command_proc = proc
            deadline = time.monotonic() + timeout if timeout else None
            while True:
                if proc.stdout:
                    ready, _, _ = select.select([proc.stdout], [], [], 0.1)
                    if ready:
                        line = proc.stdout.readline()
                        if line:
                            self.append_output(line.rstrip())
                            continue
                rc = proc.poll()
                if rc is not None:
                    if proc.stdout:
                        rest = proc.stdout.read()
                        for line in rest.splitlines():
                            self.append_output(line)
                    self.append_output(f"exit={rc}")
                    self.message = f"ran: {label}"
                    break
                if deadline and time.monotonic() > deadline:
                    proc.kill()
                    self.append_output(f"timed out after {timeout}s")
                    self.message = "command timed out"
                    break
        except Exception as exc:
            self.set_output([f"$ {label}", f"error: {exc}"])
            self.message = "command failed to start"
        finally:
            self.command_proc = None
            self.command_started = 0.0

    def run_lifecycle_cmd(self, args: list[str], extra_env: dict[str, str] | None = None):
        self.run_cmd(args, timeout=None, extra_env=extra_env)

    def show_command(self, args: list[str]):
        self.output = [
            f"$ {command_label(args)}",
            "",
            "This command needs direct terminal control.",
            "Run it outside orch-tui instead of through captured curses output.",
        ]
        self.message = f"command preview: {command_label(args)}"

    def start_pattern(self):
        pattern = self.selected_pattern_name() or self.prompt("Pattern", "lean")
        launch_flags = self.prompt("Launch flags before pattern", "--yolo")
        model_choice = self.prompt("Model for all roles (type pattern to keep defaults)", default_model())
        pattern_args = self.prompt("Pattern args after pattern", "")
        extra_env = self.model_override_env(model_choice, self.pattern_raw(pattern))
        try:
            args = ["orchestrate"]
            if launch_flags:
                args.extend(shlex.split(launch_flags))
            if any(flag in ("--attach", "--iterm-cc", "--cc", "-CC") for flag in args[1:]):
                args.append(pattern)
                if pattern_args:
                    args.extend(shlex.split(pattern_args))
                self.show_command(args)
                return
            args.append(pattern)
            if pattern_args:
                args.extend(shlex.split(pattern_args))
        except ValueError as exc:
            self.output = [f"Invalid args: {exc}"]
            return
        self.run_lifecycle_cmd(args, extra_env=extra_env)

    def preview_pattern_launch(self):
        pattern = self.selected_pattern_name() or "lean"
        rows = self.current_rows(self.state())
        selected = rows[self.row_index] if rows and self.row_index < len(rows) else {}
        raw = selected.get("raw", {}) if selected.get("kind") == "pattern" else {}
        command = ["orchestrate", "--yolo", pattern]
        model_env = self.model_override_env(default_model(), raw)
        lines = [
            f"Selected pattern: {pattern}",
            f"Default launch: {command_label(command)}",
            "",
            "--yolo skips model prompts and uses role defaults.",
            "--yolo does not bypass permissions.",
            f"TUI model default: {default_model()}",
        ]
        if model_env:
            lines.extend(["", "Model override env:", *[f"{k}={v}" for k, v in sorted(model_env.items())]])
        usage = raw.get("usage")
        if usage:
            lines.extend(["", f"Pattern usage: {usage}"])
        use_when = raw.get("use_when")
        if use_when:
            lines.extend(["", "Use when:", *textwrap.wrap(str(use_when), width=72)])
        self.output = lines
        self.message = f"preview: {command_label(command)}"

    def model_override_env(self, model_choice: str, raw: dict | None = None) -> dict[str, str]:
        choice = (model_choice or "").strip()
        if not choice or choice.lower() in ("pattern", "default", "defaults", "-"):
            return {}
        if raw is None:
            rows = self.current_rows(self.state())
            selected = rows[self.row_index] if rows and self.row_index < len(rows) else {}
            raw = selected.get("raw", {}) if selected.get("kind") == "pattern" else {}
        models = str(raw.get("models", ""))
        env: dict[str, str] = {}
        for pair in models.split():
            if ":" not in pair:
                continue
            role = pair.split(":", 1)[0].strip()
            if role:
                env[f"ORCH_MODEL_{role}"] = choice
        return env

    @staticmethod
    def pattern_raw(name: str) -> dict:
        for item in pattern_metadata():
            if item.get("name") == name:
                return item
        return {}

    def selected_pattern_name(self) -> str:
        if self.page().name != "Session":
            return ""
        rows = self.current_rows(self.state())
        if rows and self.row_index < len(rows):
            selected = rows[self.row_index]
            if selected.get("kind") == "pattern":
                return str(selected.get("title", ""))
        return ""

    def end_session(self):
        confirm = self.prompt("Type end to archive and tear down", "")
        if confirm == "end":
            self.run_cmd(["end-session"])
        else:
            self.output = ["cancelled"]

    def add_agent(self):
        role = self.prompt("Role", "coder")
        model = self.prompt("Model", default_model())
        agent_id = self.prompt("Agent id (optional)", "")
        hats = self.prompt("Hats comma-list (optional)", "")
        parent = self.prompt("Parent id (optional)", "")
        if not model:
            self.output = ["cancelled: model is required"]
            return
        args = ["add-agent", role, model]
        if agent_id:
            args += ["--id", agent_id]
        if hats:
            args += ["--hats", hats]
        if parent:
            args += ["--parent", parent]
        self.run_cmd(args)

    def remove_agent(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        if agent_id and self.confirm(f"Type remove {agent_id} to confirm", f"remove {agent_id}"):
            self.run_cmd(["remove-agent", agent_id])

    def nudge_selected_agent(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        message = self.prompt(
            "Message",
            "Please check your inbox now, reply through orch-send/status, and report task/blockers.",
        )
        if agent_id and message:
            self.run_cmd(["orch-send", agent_id, "--type", "INFO", message])

    def show_roster_metadata(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        if agent_id:
            self.run_cmd(["orch-status", "--roster"])

    def peek_inbox(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        if agent_id:
            self.run_cmd(["orch-inbox", "peek", agent_id])

    def check_inbox(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        if agent_id and self.confirm(f"Type mark-read {agent_id} to archive unread", f"mark-read {agent_id}"):
            self.run_cmd(["orch-inbox", "check", agent_id])

    def send_message(self):
        agent_id = self.prompt("Agent id", self.selected_agent_id())
        msg_type = self.prompt("Type", "INFO")
        message = self.prompt("Message", "")
        if agent_id and message:
            self.run_cmd(["orch-send", agent_id, "--type", msg_type, message])

    def reply_to_selected_message(self):
        msg = self.selected_message()
        default_target = ""
        if msg:
            default_target = str(msg.get("from") or "")
            if default_target in ("", "human", "unknown"):
                default_target = str(msg.get("inbox") or "")
        agent_id = self.prompt("Reply target", default_target)
        msg_type = self.prompt("Type", "INFO")
        message = self.prompt("Message", "")
        if agent_id and message:
            self.run_cmd(["orch-send", agent_id, "--type", msg_type, message])

    def peek_selected_message_inbox(self):
        msg = self.selected_message()
        default_inbox = str(msg.get("inbox") or "") if msg else self.selected_agent_id()
        agent_id = self.prompt("Inbox agent id", default_inbox)
        if agent_id:
            self.run_cmd(["orch-inbox", "peek", agent_id])

    def broadcast_message(self):
        msg_type = self.prompt("Type", "INFO")
        message = self.prompt("Message", "")
        if message:
            self.run_cmd(["orch-send", "--broadcast", "--type", msg_type, message])

    def create_task(self):
        title = self.prompt("Title", "")
        task_id = self.prompt("Task id (optional)", "")
        deps = self.prompt("Depends on comma-list (optional)", "")
        if not title:
            return
        args = ["orch-task", "create", title]
        if task_id:
            args += ["--id", task_id]
        if deps:
            args += ["--depends", deps]
        self.run_cmd(args)

    def show_selected_task(self):
        task_id = self.prompt("Task id", self.selected_task_id())
        if task_id:
            self.run_cmd(["orch-task", "show", task_id])

    def claim_task(self):
        task_id = self.prompt("Task id", self.selected_task_id())
        agent = self.prompt("Agent id", self.selected_agent_id())
        if task_id and agent:
            self.run_cmd(["orch-task", "claim", task_id, agent])

    def complete_task(self):
        task_id = self.prompt("Task id", self.selected_task_id())
        agent = self.prompt("Agent id", self.selected_task_owner() or self.selected_agent_id())
        note = self.prompt("Note (optional)", "")
        if task_id and agent:
            self.run_cmd(["orch-task", "complete", task_id, agent, "--note", note])

    def block_task(self):
        task_id = self.prompt("Task id", self.selected_task_id())
        agent = self.prompt("Agent id", self.selected_task_owner() or self.selected_agent_id())
        reason = self.prompt("Reason", "")
        if task_id and agent and reason:
            self.run_cmd(["orch-task", "block", task_id, agent, "--reason", reason])

    def unblock_task(self):
        task_id = self.prompt("Task id", self.selected_task_id())
        agent = self.prompt("Agent id", self.selected_task_owner() or self.selected_agent_id())
        note = self.prompt("Note (optional)", "")
        if task_id and agent:
            self.run_cmd(["orch-task", "unblock", task_id, agent, "--note", note])

    def available_for_agent(self):
        agent = self.prompt("Agent id", self.selected_agent_id())
        if agent:
            self.run_cmd(["orch-task", "list-available", "--for", agent])

    def selected_agent_id(self) -> str:
        state = self.state()
        if self.page().name == "Agents":
            rows = self.current_rows(state)
            if rows and self.row_index < len(rows):
                return str(rows[self.row_index].get("title", ""))
        agents = state.get("agents", [])
        return str(agents[0].get("id", "")) if agents else ""

    def selected_task_id(self) -> str:
        if self.page().name != "Tasks":
            return ""
        rows = self.current_rows(self.state())
        if rows and self.row_index < len(rows):
            return str(rows[self.row_index].get("title", ""))
        return ""

    def selected_task_owner(self) -> str:
        if self.page().name != "Tasks":
            return ""
        rows = self.current_rows(self.state())
        if rows and self.row_index < len(rows):
            selected = rows[self.row_index]
            if selected.get("kind") == "task":
                owner = selected.get("raw", {}).get("owner")
                return str(owner) if owner else ""
        return ""

    def selected_message(self) -> dict:
        if self.page().name != "Messages":
            return {}
        rows = self.current_rows(self.state())
        if rows and self.row_index < len(rows):
            selected = rows[self.row_index]
            if selected.get("kind") == "message":
                return selected.get("raw", {})
        return {}

    @staticmethod
    def task_status(status: str) -> str:
        return {"done": "ok", "claimed": "ok", "blocked": "bad", "pending": "info"}.get(status, "dim")

    def status_attr(self, status: str) -> int:
        return {
            "ok": curses.color_pair(3),
            "warn": curses.color_pair(4),
            "bad": curses.color_pair(5),
            "info": curses.color_pair(8),
            "dim": curses.A_DIM,
        }.get(status, curses.A_NORMAL)

    @staticmethod
    def muted_attr() -> int:
        return curses.color_pair(8) | curses.A_DIM

    @staticmethod
    def border_attr() -> int:
        return curses.color_pair(2) | curses.A_DIM

    def addstr(self, y: int, x: int, value: str, attr: int = 0):
        h, w = self.stdscr.getmaxyx()
        if 0 <= y < h and 0 <= x < w:
            try:
                self.stdscr.addstr(y, x, value[: max(0, w - x - 1)], attr)
            except curses.error:
                pass

    def hline(self, y: int, x: int, width: int):
        self.addstr(y, x, GLYPHS.h * max(0, width), self.border_attr())

    def fill(self, y: int, x: int, width: int, char: str, attr: int = 0):
        self.addstr(y, x, char * max(0, width), attr)

    @staticmethod
    def clip(value: str, width: int) -> str:
        if width <= 0:
            return ""
        value = value.replace("\t", "  ").replace("\n", " ")
        if len(value) <= width:
            return value
        return value[: max(0, width - 1)] + "…"


def main(stdscr):
    App(stdscr).run()


if __name__ == "__main__":
    curses.wrapper(main)
