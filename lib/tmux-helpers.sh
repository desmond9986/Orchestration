#!/usr/bin/env bash
# Tmux session/pane helpers — sourced by spawn-agent.sh and patterns/*.sh.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd tmux

# Initialize a tmux session for orchestration. Idempotent.
# Args: session_name [working_dir]
init_session() {
  local session="$1"
  local cwd="${2:-$(project_root)}"
  if tmux has-session -t "$session" 2>/dev/null; then
    info "tmux session '$session' already exists, reusing"
  else
    tmux new-session -d -s "$session" -c "$cwd"
    ok "tmux session created: $session"
  fi
  echo "$session"
}

# Create a new pane in a session by splitting the last pane.
# Args: session_name
# Echoes the new tmux target (session:window.pane)
new_pane() {
  local session="$1"
  local cwd; cwd="$(project_root)"
  # Find last pane in window 0
  local last_pane
  last_pane=$(tmux list-panes -t "$session:0" -F "#{pane_index}" | tail -1)
  if [[ -z "$last_pane" ]]; then
    echo "$session:0.0"
    return
  fi
  # Split horizontally if pane count even, vertically if odd (rough tile)
  local count
  count=$(tmux list-panes -t "$session:0" | wc -l | tr -d ' ')
  if (( count % 2 == 0 )); then
    tmux split-window -h -t "$session:0.$last_pane" -c "$cwd"
  else
    tmux split-window -v -t "$session:0.$last_pane" -c "$cwd"
  fi
  tmux select-layout -t "$session:0" tiled >/dev/null
  local new_idx
  new_idx=$(tmux list-panes -t "$session:0" -F "#{pane_index}" | tail -1)
  echo "$session:0.$new_idx"
}

# Send a multi-line prompt to a pane reliably via paste-buffer.
# Args: target prompt_file
paste_to_pane() {
  local target="$1" file="$2"
  [[ -f "$file" ]] || die "prompt file missing: $file"
  local buf="orch-$(date +%s%N)"
  tmux load-buffer -b "$buf" "$file"
  tmux paste-buffer -b "$buf" -t "$target" -d
  tmux send-keys -t "$target" Enter
}

# Send a single command line to a pane (with Enter).
send_line() {
  local target="$1"; shift
  tmux send-keys -t "$target" "$*" Enter
}

# Set the title of a pane to its agent id (helps human navigate).
set_pane_title() {
  local target="$1" title="$2"
  tmux select-pane -t "$target" -T "$title" 2>/dev/null || true
}

# Kill a single pane.
kill_pane() {
  local target="$1"
  tmux kill-pane -t "$target" 2>/dev/null || true
}

# Kill the whole session.
kill_session() {
  local session="$1"
  tmux kill-session -t "$session" 2>/dev/null || true
}

# Attach (foreground) — if already inside tmux, switch instead.
attach_session() {
  local session="$1"
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$session"
  else
    tmux attach-session -t "$session"
  fi
}
