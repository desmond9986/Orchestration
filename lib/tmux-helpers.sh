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

# Wait for a CLI in a pane to look ready for input.
#
# Two-stage poll:
#   1. Wait until pane's foreground command is no longer a shell (cli launched).
#   2. Wait until capture-pane output hash is stable for N consecutive samples
#      (cli has finished printing its banner and is in a read loop).
#
# Falls through to paste anyway on timeout — preserves previous sleep-based
# behavior as a hard cap.
#
# Env knobs:
#   ORCH_CLI_READY_MAX   — hard cap in seconds (default 8)
#   ORCH_CLI_READY_POLL  — poll interval in milliseconds (default 150)
#   ORCH_CLI_READY_STABLE — consecutive identical samples to declare idle (default 3)
#
# Usage: wait_for_cli_ready <target>
wait_for_cli_ready() {
  local target="$1"
  local max="${ORCH_CLI_READY_MAX:-8}"
  local poll_ms="${ORCH_CLI_READY_POLL:-150}"
  local need_stable="${ORCH_CLI_READY_STABLE:-3}"
  local start_ms deadline sleep_s
  start_ms=$(( $(date +%s) * 1000 ))
  deadline=$(( $(date +%s) + max ))
  sleep_s=$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')

  _cli_ready_log() {
    local mode="$1"
    local elapsed=$(( $(date +%s) * 1000 - start_ms ))
    log_line "CLI_READY mode=$mode wait_ms=$elapsed target=$target"
  }

  # Stage 1: wait for the pane's foreground process to leave the shell.
  while (( $(date +%s) < deadline )); do
    local cmd
    cmd=$(tmux display-message -p -t "$target" '#{pane_current_command}' 2>/dev/null || echo "")
    case "$cmd" in
      ""|bash|zsh|sh|fish|dash|ksh) sleep "$sleep_s" ;;
      *) break ;;
    esac
  done

  # Stage 2: wait for output to stop changing.
  local last="" streak=0
  while (( $(date +%s) < deadline )); do
    local h
    h=$(tmux capture-pane -p -t "$target" 2>/dev/null | shasum | awk '{print $1}')
    if [[ -n "$h" && "$h" == "$last" ]]; then
      streak=$((streak + 1))
      if (( streak >= need_stable )); then
        _cli_ready_log stable
        return 0
      fi
    else
      streak=1
      last="$h"
    fi
    sleep "$sleep_s"
  done
  # Hard cap hit — caller pastes anyway.
  _cli_ready_log timeout
  return 1
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
