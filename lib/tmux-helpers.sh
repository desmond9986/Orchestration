#!/usr/bin/env bash
# Tmux session/pane helpers — sourced by spawn-agent.sh and patterns/*.sh.

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd tmux

# Pick a pane-content hasher once. shasum ships with macOS; sha1sum with
# GNU coreutils; cksum is POSIX and present everywhere. The readiness poll
# only needs a stable fingerprint, not cryptographic strength.
if command -v shasum  >/dev/null 2>&1; then _PANE_HASH=(shasum)
elif command -v sha1sum >/dev/null 2>&1; then _PANE_HASH=(sha1sum)
else _PANE_HASH=(cksum)
fi

# Initialize a tmux session for orchestration. Idempotent.
# Args: session_name [working_dir]
init_session() {
  local session="$1"
  local cwd="${2:-$(project_root)}"
  local cwd_real
  cwd_real=$(cd "$cwd" 2>/dev/null && pwd -P || echo "$cwd")
  _path_fingerprint() {
    local p="$1"
    stat -f '%d:%i' "$p" 2>/dev/null || stat -c '%d:%i' "$p" 2>/dev/null || echo ""
  }
  if tmux has-session -t "$session" 2>/dev/null; then
    local existing_path existing_real existing_fp cwd_fp
    existing_path=$(tmux display-message -p -t "$session:0.0" '#{pane_current_path}' 2>/dev/null || echo "")
    existing_real=$(cd "$existing_path" 2>/dev/null && pwd -P || echo "$existing_path")
    existing_fp=$(_path_fingerprint "$existing_real")
    cwd_fp=$(_path_fingerprint "$cwd_real")
    # On case-insensitive filesystems (common on macOS), the same directory can
    # appear with different letter casing. Prefer inode/device fingerprint match.
    local same_project=0
    if [[ -n "$existing_fp" && -n "$cwd_fp" && "$existing_fp" == "$cwd_fp" ]]; then
      same_project=1
    elif [[ -n "$existing_real" && "$existing_real" == "$cwd_real" ]]; then
      same_project=1
    fi
    if (( same_project == 0 )) && [[ -n "$existing_real" && "${ORCH_ALLOW_CROSS_PROJECT_SESSION_REUSE:-0}" != "1" ]]; then
      die "tmux session '$session' already exists for another project: $existing_real (current: $cwd_real). Use a different session name or set ORCH_ALLOW_CROSS_PROJECT_SESSION_REUSE=1"
    fi
    info "tmux session '$session' already exists, reusing"
  else
    tmux new-session -d -s "$session" -c "$cwd"
    ok "tmux session created: $session"
  fi
  echo "$session"
}

# Ensure a tmux window exists in a session. Creates it if absent.
# Args: session_name window_index
ensure_window() {
  local session="$1" win="$2"
  local cwd; cwd="$(project_root)"
  if ! tmux list-windows -t "$session" -F "#{window_index}" 2>/dev/null | grep -qx "$win"; then
    tmux new-window -d -t "$session:$win" -c "$cwd"
    ok "tmux window $win created in session $session"
  fi
}

# Create a new pane in a session by splitting the last pane in the given window.
# Args: session_name [window_index=0]
# Echoes the new tmux target (session:window.pane)
new_pane() {
  local session="$1"
  local win="${2:-0}"
  local cwd; cwd="$(project_root)"
  # Find last pane in target window
  local last_pane
  last_pane=$(tmux list-panes -t "$session:$win" -F "#{pane_index}" 2>/dev/null | tail -1)
  if [[ -z "$last_pane" ]]; then
    echo "$session:$win.0"
    return
  fi
  # Split horizontally if pane count even, vertically if odd (rough tile)
  local count
  count=$(tmux list-panes -t "$session:$win" 2>/dev/null | wc -l | tr -d ' ')
  if (( count % 2 == 0 )); then
    tmux split-window -h -t "$session:$win.$last_pane" -c "$cwd"
  else
    tmux split-window -v -t "$session:$win.$last_pane" -c "$cwd"
  fi
  tmux select-layout -t "$session:$win" tiled >/dev/null
  local new_idx
  new_idx=$(tmux list-panes -t "$session:$win" -F "#{pane_index}" | tail -1)
  echo "$session:$win.$new_idx"
}

# Send a multi-line prompt to a pane reliably via paste-buffer.
# Args: target prompt_file
pane_hash() {
  local target="$1"
  tmux capture-pane -p -t "$target" 2>/dev/null | "${_PANE_HASH[@]}" | awk '{print $1}'
}

# Single submit key path (CR) used consistently across helpers.
send_submit_key() {
  local target="$1"
  tmux send-keys -t "$target" C-m
}

# Ensure Enter is delivered and observed by pane-state change.
# Retries Enter when content appears unchanged (e.g. pasted draft not submitted).
# Env knobs:
#   ORCH_SUBMIT_ENTER_MAX      default 3 attempts
#   ORCH_SUBMIT_ENTER_DELAY_MS default 300ms between attempts
ensure_submit_enter() {
  local target="$1"
  local max="${2:-${ORCH_SUBMIT_ENTER_MAX:-3}}"
  local delay_ms="${3:-${ORCH_SUBMIT_ENTER_DELAY_MS:-300}}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=3
  [[ "$delay_ms" =~ ^[0-9]+$ ]] || delay_ms=300
  local delay_s
  delay_s=$(awk -v ms="$delay_ms" 'BEGIN { printf "%.3f", ms/1000 }')

  local before after i
  before="$(pane_hash "$target")"
  for (( i=1; i<=max; i++ )); do
    send_submit_key "$target"
    sleep "$delay_s"
    after="$(pane_hash "$target")"
    if [[ -n "$after" && "$after" != "$before" ]]; then
      log_line "SUBMIT_ENTER ok target=$target attempts=$i"
      return 0
    fi
  done
  warn "submit enter did not observe pane change for $target after $max attempts"
  log_line "SUBMIT_ENTER timeout target=$target attempts=$max"
  return 1
}

# Best-effort detector for unsent pasted drafts in CLI UIs.
# Currently tuned for Codex's visible "[Pasted Content ...]" marker.
has_pending_pasted_draft() {
  local target="$1"
  # Match active input line style: "> ... [Pasted Content N chars]"
  # We intentionally only inspect recent lines to avoid historical matches.
  tmux capture-pane -p -t "$target" 2>/dev/null | tail -n 8 \
    | grep -qE '^> .*\[Pasted Content [0-9]+ chars\]'
}

# Try to submit pasted draft until UI marker disappears.
submit_until_draft_clears() {
  local target="$1"
  local max="${2:-${ORCH_SUBMIT_DRAFT_CLEAR_MAX:-6}}"
  local delay_ms="${3:-${ORCH_SUBMIT_DRAFT_CLEAR_DELAY_MS:-350}}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=6
  [[ "$delay_ms" =~ ^[0-9]+$ ]] || delay_ms=350
  local delay_s
  delay_s=$(awk -v ms="$delay_ms" 'BEGIN { printf "%.3f", ms/1000 }')
  local i
  for (( i=1; i<=max; i++ )); do
    if ! has_pending_pasted_draft "$target"; then
      log_line "DRAFT_CLEAR ok target=$target attempts=$i"
      return 0
    fi
    send_submit_key "$target"
    sleep "$delay_s"
  done
  warn "pasted draft marker still visible for $target after $max attempts"
  log_line "DRAFT_CLEAR timeout target=$target attempts=$max"
  return 1
}

# Send one message line and submit with retry.
# Args: target message
send_message_submit() {
  local target="$1"; shift
  tmux send-keys -t "$target" "$*"
  ensure_submit_enter "$target"
}

pane_contains_text() {
  local target="$1" needle="$2"
  tmux capture-pane -p -t "$target" 2>/dev/null | grep -Fq "$needle"
}

# Send a visible bootstrap/audit message and verify it appeared in the pane.
# This gives operators a consistent visible confirmation across model CLIs.
send_bootstrap_message() {
  local target="$1" message="$2"
  local max="${3:-${ORCH_BOOTSTRAP_MAX_ATTEMPTS:-4}}"
  local delay_ms="${4:-${ORCH_BOOTSTRAP_DELAY_MS:-350}}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=4
  [[ "$delay_ms" =~ ^[0-9]+$ ]] || delay_ms=350
  local delay_s
  delay_s=$(awk -v ms="$delay_ms" 'BEGIN { printf "%.3f", ms/1000 }')
  local i
  for (( i=1; i<=max; i++ )); do
    tmux send-keys -t "$target" "$message"
    ensure_submit_enter "$target" || true
    sleep "$delay_s"
    if pane_contains_text "$target" "$message"; then
      log_line "BOOTSTRAP ok target=$target attempts=$i"
      return 0
    fi
  done
  warn "bootstrap message not confirmed in pane for $target after $max attempts"
  log_line "BOOTSTRAP timeout target=$target attempts=$max"
  return 1
}

# Send a multi-line prompt to a pane reliably via paste-buffer.
# Args: target prompt_file
paste_to_pane() {
  local target="$1" file="$2"
  [[ -f "$file" ]] || die "prompt file missing: $file"
  local buf
  buf="orch-$(date +%s%N)"
  tmux load-buffer -b "$buf" "$file"
  tmux paste-buffer -b "$buf" -t "$target" -d
  ensure_submit_enter "$target" || true
  submit_until_draft_clears "$target" || true
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
  # Stable metadata for orchestration recovery even if the CLI later changes
  # the visible pane title.
  tmux set-option -p -t "$target" @orch_agent_id "$title" 2>/dev/null || true
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
    h=$(tmux capture-pane -p -t "$target" 2>/dev/null | "${_PANE_HASH[@]}" | awk '{print $1}')
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

# Wait until the claude input prompt (❯) is visible in the pane.
# More reliable than wait_for_cli_ready for the period between trust-dialog
# dismissal and the chat input becoming ready: hash can briefly stabilise on
# an intermediate (blank/loading) screen before the prompt appears.
#
# Usage: wait_for_input_prompt <target> [max_seconds]
wait_for_input_prompt() {
  local target="$1"
  local max="${2:-${ORCH_CLI_READY_MAX:-8}}"
  local deadline=$(( $(date +%s) + max ))
  while (( $(date +%s) < deadline )); do
    # Match the bare chat input prompt (❯ with optional trailing spaces/cursor)
    # but NOT the trust-dialog option line (❯ 1. Yes, I trust this folder).
    if tmux capture-pane -p -t "$target" 2>/dev/null | grep -qE '^❯[[:space:]]*$'; then
      return 0
    fi
    sleep 0.3
  done
  return 1
}

# Present a session to the user without destructively hijacking an existing tmux
# client. Outside tmux this may attach; inside tmux it prints how to switch.
present_session() {
  local session="$1"
  if [[ -n "${TMUX:-}" ]]; then
    if [[ "${ORCH_AUTO_SWITCH_IN_TMUX:-0}" == "1" ]]; then
      tmux switch-client -t "$session" 2>/dev/null || true
    else
      info "session '$session' ready"
      info "already inside tmux — switch with: tmux switch-client -t '$session'"
      info "or press Ctrl-B, S to pick a session"
    fi
  else
    if [[ "${ORCH_AUTO_ATTACH_OUTSIDE_TMUX:-1}" == "1" ]]; then
      tmux attach-session -t "$session"
    else
      info "session '$session' ready"
      info "attach with: tmux attach-session -t '$session'"
    fi
  fi
}
