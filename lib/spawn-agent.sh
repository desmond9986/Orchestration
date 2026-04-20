#!/usr/bin/env bash
# Spawn a single agent: compose prompt, create pane, launch CLI, register.
#
# Usage:
#   spawn-agent.sh <id> <role> <model> [--hats h1,h2] [--parent <id>] [--session <name>]
#
# Requires an already-initialized roster (roster.sh init ...).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/tmux-helpers.sh"

ROSTER_LIB="$(dirname "${BASH_SOURCE[0]}")/roster.sh"

ID="${1:?id required}"; shift
ROLE="${1:?role required}"; shift
MODEL="${1:?model required}"; shift
[[ "$ID" =~ ^[A-Za-z0-9_-]+$ ]] || die "invalid agent id '$ID' (allowed: [A-Za-z0-9_-])"

HATS=""
PARENT=""
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hats)    HATS="$2"; shift 2 ;;
    --parent)  PARENT="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    *) die "unknown flag: $1" ;;
  esac
done
if [[ -n "$PARENT" && ! "$PARENT" =~ ^[A-Za-z0-9_-]+$ ]]; then
  die "invalid parent id '$PARENT' (allowed: [A-Za-z0-9_-])"
fi

# Resolve session from roster if not given
if [[ -z "$SESSION" ]]; then
  [[ -f "$(roster_file)" ]] || die "no roster — init first or pass --session"
  SESSION=$(bash "$ROSTER_LIB" session)
fi

ensure_agents_dir

# Validate role file exists
ROLE_FILE="$ORCHESTRATION_HOME/roles/core/$ROLE.md"
[[ -f "$ROLE_FILE" ]] || die "role file missing: $ROLE_FILE"

# Compose prompt file
PROMPT_FILE="$(prompts_dir)/$ID.md"
{
  echo "# Your Agent Identity"
  echo ""
  echo "You are agent **\`$ID\`** in a multi-agent orchestration session."
  echo ""
  echo "- Role: \`$ROLE\`"
  echo "- Model: \`$MODEL\`"
  [[ -n "$HATS" ]] && echo "- Hats: \`$HATS\`"
  [[ -n "$PARENT" ]] && echo "- Parent agent: \`$PARENT\`"
  echo "- Project root: \`$(project_root)\`"
  echo "- Agents dir: \`$(agents_dir)\`"
  echo "- Orchestration home: \`$ORCHESTRATION_HOME\`"
  echo ""
  echo "---"
  echo ""
  cat "$ORCHESTRATION_HOME/roles/_protocol.md"
  echo ""
  echo "---"
  echo ""
  cat "$ROLE_FILE"

  if [[ -n "$HATS" ]]; then
    IFS=',' read -ra HAT_LIST <<< "$HATS"
    for hat in "${HAT_LIST[@]}"; do
      local_hat_file="$ORCHESTRATION_HOME/roles/hats/$hat.md"
      if [[ -f "$local_hat_file" ]]; then
        echo ""
        echo "---"
        echo ""
        cat "$local_hat_file"
      else
        warn "hat file missing: $local_hat_file (skipping)"
      fi
    done
  fi

  # Project context if present
  if [[ -f "$(agents_dir)/PROJECT_CONTEXT.md" ]]; then
    echo ""
    echo "---"
    echo ""
    echo "# Project Context"
    echo ""
    cat "$(agents_dir)/PROJECT_CONTEXT.md"
  fi

  if [[ -f "$(agents_dir)/SPECS.md" ]]; then
    echo ""
    echo "---"
    echo ""
    echo "# Specs / Contracts"
    echo ""
    cat "$(agents_dir)/SPECS.md"
  fi

  echo ""
  echo "---"
  echo ""
  echo "## Getting Started"
  echo ""
  echo "1. Run: \`bash \$ORCHESTRATION_HOME/lib/roster.sh list-active\` to see your team."
  echo "2. Check your inbox: \`bash \$ORCHESTRATION_HOME/lib/protocol.sh check-inbox $ID\`"
  echo "3. Announce yourself: \`bash \$ORCHESTRATION_HOME/lib/protocol.sh status $ID \"ready\"\`"
  echo "4. Await instructions from the human or orchestrator."
} > "$PROMPT_FILE"

# Ensure session exists
init_session "$SESSION" >/dev/null

# Layout decision driven by ORCH_TOTAL_AGENTS (set by the pattern before spawning):
#   ≤ 4 agents → single window, all panes tiled in window 0
#   > 4 agents → orchestrator solo in window 0, everyone else in window 1
#                (overflow to window 2 after 4 panes in window 1)
# If ORCH_TOTAL_AGENTS is unset (e.g. freeform), default to split layout.
total="${ORCH_TOTAL_AGENTS:-999}"
WIN=0
TARGET=""
CREATED_NEW_PANE=0

_allocate_target_and_register() {
  _is_shell_pane() {
    local t="$1"
    local cmd
    cmd=$(tmux display-message -p -t "$t" '#{pane_current_command}' 2>/dev/null || echo "")
    case "$cmd" in
      bash|zsh|sh|fish|dash|ksh) return 0 ;;
      *) return 1 ;;
    esac
  }

  if bash "$ROSTER_LIB" exists "$ID" >/dev/null 2>&1; then
    die "agent already exists: $ID"
  fi
  if (( total <= 4 )); then
    active_count=$(jq '[.agents[] | select(.status=="active")] | length' "$(roster_file)")
    if (( active_count == 0 )); then
      if _is_shell_pane "$SESSION:0.0"; then
        TARGET="$SESSION:0.0"
      else
        TARGET=$(new_pane "$SESSION" 0)
        CREATED_NEW_PANE=1
      fi
    else
      TARGET=$(new_pane "$SESSION" 0)
      CREATED_NEW_PANE=1
    fi
  else
    if [[ "$ROLE" == "orchestrator" ]]; then
      TARGET="$SESSION:0.0"
    else
      ensure_window "$SESSION" 1
      pane_count_1=$(tmux list-panes -t "$SESSION:1" 2>/dev/null | wc -l | tr -d ' ')
      if (( pane_count_1 < 4 )); then
        WIN=1
      else
        ensure_window "$SESSION" 2
        WIN=2
      fi
      # Use roster occupancy, not pane count.
      agents_in_win=$(jq --arg pat "$SESSION:$WIN\\." \
        '[.agents[] | select(.status=="active") | select(.target != null) | select(.target | test($pat))] | length' \
        "$(roster_file)")
      if (( agents_in_win == 0 )); then
        if [[ "${ORCH_NEVER_REUSE_EMPTY_PANE:-0}" == "1" ]]; then
          TARGET=$(new_pane "$SESSION" "$WIN")
          CREATED_NEW_PANE=1
        else
          if _is_shell_pane "$SESSION:$WIN.0"; then
            TARGET="$SESSION:$WIN.0"
          else
            TARGET=$(new_pane "$SESSION" "$WIN")
            CREATED_NEW_PANE=1
          fi
        fi
      else
        TARGET=$(new_pane "$SESSION" "$WIN")
        CREATED_NEW_PANE=1
      fi
    fi
  fi

  set_pane_title "$TARGET" "$ID"
  if (( total <= 4 )); then
    tmux rename-window -t "$SESSION:0" "agents" 2>/dev/null || true
  elif [[ "$ROLE" == "orchestrator" ]]; then
    tmux rename-window -t "$SESSION:0" "orchestrator" 2>/dev/null || true
  else
    tmux rename-window -t "$SESSION:$WIN" "agents" 2>/dev/null || true
  fi

  ADD_ARGS=("$ID" "$ROLE" "$MODEL" "$TARGET")
  [[ -n "$HATS" ]]   && ADD_ARGS+=("--hats" "$HATS")
  [[ -n "$PARENT" ]] && ADD_ARGS+=("--parent" "$PARENT")
  if ! bash "$ROSTER_LIB" add "${ADD_ARGS[@]}" >/dev/null; then
    if [[ "$CREATED_NEW_PANE" == "1" ]]; then
      kill_pane "$TARGET"
    fi
    die "failed to register spawned agent '$ID'"
  fi
}
with_file_lock "$(agents_dir)/spawn.lock.d" _allocate_target_and_register

# Build the CLI launch command.
# For claude: role is loaded via --append-system-prompt-file (reliable, no
# paste timing issues with the welcome dialog). A short kick-off message is
# sent after the CLI is ready instead of pasting the full file.
# For codex/others: paste the prompt file the old way (no equivalent flag).
launch_cli_cmd() {
  local model="$1"
  # Per-role var wins; fall back to global flag; default to 0.
  # Nested ${!var:-${other:-0}} is not reliable in bash 3.2; resolve in steps.
  local role_var="ORCH_SKIP_PERMISSIONS_${ROLE}"
  local skip="${!role_var:-}"
  skip="${skip:-${ORCH_SKIP_PERMISSIONS:-0}}"
  case "$model" in
    claude)
      local flags="--append-system-prompt-file '$PROMPT_FILE'"
      if [[ "$skip" == "1" ]]; then flags="--dangerously-skip-permissions $flags"; fi
      echo "claude $flags"
      ;;
    codex)
      if [[ "$skip" == "1" ]]; then echo "codex --yolo"
      else echo "codex"; fi
      ;;
    gemini)     echo "gemini chat" ;;
    shell|none) echo "cat '$PROMPT_FILE'" ;;
    *)
      warn "unknown model '$model' — falling back to 'shell' (prompt printed, not sent)"
      echo "cat '$PROMPT_FILE'"
      ;;
  esac
}

LAUNCH_CMD=$(launch_cli_cmd "$MODEL")

# Banner + CLI launch
send_line "$TARGET" "clear"
send_line "$TARGET" "echo '===== agent: $ID ($ROLE$([[ -n "$HATS" ]] && echo " +$HATS")) ====='"
send_line "$TARGET" "echo 'prompt: $PROMPT_FILE'"
send_line "$TARGET" "$LAUNCH_CMD"

# Deliver the role context to the agent once it's ready.
case "$MODEL" in
  shell|none) : ;;
  claude)
    # Role already in system prompt via --append-system-prompt-file.
    # Wait for startup rendering to settle.
    wait_for_cli_ready "$TARGET" || warn "CLI readiness timed out for $ID"
    # Dismiss trust-folder dialog if present (new/untrusted directories).
    # Submit key selects "Yes, I trust this folder".
    if tmux capture-pane -p -t "$TARGET" 2>/dev/null | grep -q "trust this folder"; then
      ensure_submit_enter "$TARGET" || true
    fi
    # Claude usage-limit gate: acknowledge option 1 so pane is not left hanging
    # at the modal forever. This does not bypass limits; it just clears prompt UI.
    if tmux capture-pane -p -t "$TARGET" 2>/dev/null | grep -q "Stop and wait for limit to reset"; then
      tmux send-keys -t "$TARGET" "1"
      ensure_submit_enter "$TARGET" || true
      log_line "CLAUDE_LIMIT_GATE: id=$ID target=$TARGET action=select_wait"
    fi
    # Wait specifically for the ❯ input prompt to be visible.
    # wait_for_cli_ready can return on a transient stable state (blank screen
    # between trust dismissal and the actual chat UI appearing). Checking for
    # ❯ ensures we don't send the kick-off too early.
    if wait_for_input_prompt "$TARGET"; then
      send_message_submit "$TARGET" "You are now active. Follow your Getting Started steps." || true
    else
      fallback="${ORCH_KICKOFF_FALLBACK_ENTER:-1}"
      if [[ "$fallback" == "1" ]]; then
        sleep 1
        warn "input prompt not visible for $ID — sending delayed kickoff fallback"
        log_line "KICKOFF_FALLBACK: id=$ID target=$TARGET reason=input_prompt_timeout"
        send_message_submit "$TARGET" "You are now active. Follow your Getting Started steps." || true
      else
        warn "input prompt not visible for $ID — skipped kickoff Enter"
        log_line "KICKOFF_SKIPPED: id=$ID target=$TARGET reason=input_prompt_timeout"
      fi
    fi
    ;;
  *)
    # codex / gemini: paste the full prompt file as the first message.
    wait_for_cli_ready "$TARGET" || warn "CLI readiness timed out for $ID — pasting anyway"
    paste_to_pane "$TARGET" "$PROMPT_FILE"
    # Optional additional submit burst for stubborn draft states.
    if [[ "${ORCH_PASTE_EXTRA_ENTER:-1}" == "1" ]]; then
      ensure_submit_enter "$TARGET" "${ORCH_PASTE_EXTRA_ENTER_MAX:-2}" "${ORCH_PASTE_EXTRA_ENTER_DELAY_MS:-300}" || true
      submit_until_draft_clears "$TARGET" "${ORCH_PASTE_EXTRA_DRAFT_MAX:-8}" "${ORCH_PASTE_EXTRA_DRAFT_DELAY_MS:-350}" || true
    fi
    ;;
esac

status_line "orchestration" "SPAWN $ID role=$ROLE model=$MODEL target=$TARGET hats=[$HATS]"
ok "spawned: $ID → $TARGET"
