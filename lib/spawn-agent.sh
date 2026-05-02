#!/usr/bin/env bash
# Spawn a single agent: compose prompt, create pane, launch CLI, register.
#
# Usage:
#   spawn-agent.sh <id> <role> <model> [--hats h1,h2] [--parent <id>] [--session <name>]
#   spawn-agent.sh <id> <role> <model> --restore-existing [--session <name>]
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
RESTORE_EXISTING=0
RESUME_PROVIDER=""
RESUME_ID=""
RESUME_MODE="none"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hats)    HATS="$2"; shift 2 ;;
    --parent)  PARENT="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --restore-existing) RESTORE_EXISTING=1; shift ;;
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

PROMPT_FILE="$(prompts_dir)/$ID.md"

shell_quote() {
  printf "'%s'" "$(printf "%s" "$1" | sed "s/'/'\\\\''/g")"
}

new_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
    return 0
  fi
  local h
  h=$(date +%s%N 2>/dev/null | "${_PANE_HASH[@]}" | awk '{print $1}')
  printf "%s-%s-%s-%s-%s\n" "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}"
}

PROMPT_RUN_TOKEN="orch-$ID-$(new_uuid)"

load_or_prepare_resume_metadata() {
  if [[ "$RESTORE_EXISTING" == "1" ]]; then
    local resume
    resume=$(bash "$ROSTER_LIB" resume "$ID" 2>/dev/null || echo '{}')
    RESUME_PROVIDER=$(printf "%s" "$resume" | jq -r '.provider // ""')
    RESUME_ID=$(printf "%s" "$resume" | jq -r '.id // ""')
    RESUME_MODE=$(printf "%s" "$resume" | jq -r '.mode // "none"')
    return 0
  fi

  case "$MODEL" in
    claude)
      RESUME_PROVIDER="claude"
      RESUME_ID="$(new_uuid)"
      RESUME_MODE="exact"
      ;;
    codex)
      RESUME_PROVIDER="codex"
      RESUME_MODE="none"
      ;;
    *)
      RESUME_PROVIDER=""
      RESUME_ID=""
      RESUME_MODE="none"
      ;;
  esac
}

load_or_prepare_resume_metadata

compose_prompt_file() {
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
  echo "- Launch token: \`$PROMPT_RUN_TOKEN\`"
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
}

# During restore, keep the original prompt if it still exists. That preserves
# the exact context the agent was bootstrapped with before the tmux session died.
if [[ "$RESTORE_EXISTING" == "1" && -f "$PROMPT_FILE" ]]; then
  info "restore: reusing prompt file for $ID"
else
  compose_prompt_file
fi

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
RESTORE_ALREADY_LIVE=0

_allocate_target_and_register() {
  local already_active=0
  if bash "$ROSTER_LIB" exists "$ID" >/dev/null 2>&1; then
    already_active=1
  fi
  if [[ "$RESTORE_EXISTING" == "1" && "$already_active" != "1" ]]; then
    die "cannot restore inactive or missing agent: $ID"
  fi
  if [[ "$RESTORE_EXISTING" != "1" && "$already_active" == "1" ]]; then
    die "agent already exists: $ID"
  fi

  if [[ "$RESTORE_EXISTING" == "1" ]]; then
    local existing_target restore_win pane_meta live_count live_targets live_targets_count
    live_targets=$(tmux list-panes -t "$SESSION" -F '#{session_name}:#{window_index}.#{pane_index}	#{@orch_agent_id}' 2>/dev/null \
      | awk -F'\t' -v id="$ID" '$2 == id { print $1 }')
    live_targets_count=$(printf "%s\n" "$live_targets" | sed '/^$/d' | wc -l | tr -d ' ')
    if [[ "$live_targets_count" == "1" ]]; then
      TARGET=$(printf "%s\n" "$live_targets" | sed -n '1p')
      bash "$ROSTER_LIB" retarget "$ID" "$TARGET" >/dev/null
      RESTORE_ALREADY_LIVE=1
      return 0
    elif [[ "$live_targets_count" != "0" ]]; then
      die "multiple live panes already advertise agent id '$ID'; refusing to restore duplicate"
    fi

    existing_target=$(bash "$ROSTER_LIB" target "$ID" 2>/dev/null || true)
    restore_win=0
    if [[ "$existing_target" =~ ^[^:]+:([0-9]+)\. ]]; then
      restore_win="${BASH_REMATCH[1]}"
    elif (( total > 4 )) && [[ "$ROLE" != "orchestrator" ]]; then
      restore_win=1
    fi
    WIN="$restore_win"
    ensure_window "$SESSION" "$WIN"
    live_count=$(tmux list-panes -t "$SESSION:$WIN" -F '#{@orch_agent_id}' 2>/dev/null \
      | sed '/^$/d' | wc -l | tr -d ' ')
    pane_meta=$(tmux display-message -p -t "$SESSION:$WIN.0" '#{@orch_agent_id}' 2>/dev/null || true)
    if (( live_count == 0 )) && is_shell_pane "$SESSION:$WIN.0" && [[ -z "$pane_meta" ]]; then
      TARGET="$SESSION:$WIN.0"
    else
      TARGET=$(new_pane "$SESSION" "$WIN")
      CREATED_NEW_PANE=1
    fi
    set_pane_title "$TARGET" "$ID"
    if (( total <= 4 )); then
      tmux rename-window -t "$SESSION:0" "agents" 2>/dev/null || true
    elif [[ "$ROLE" == "orchestrator" ]]; then
      tmux rename-window -t "$SESSION:0" "orchestrator" 2>/dev/null || true
    else
      tmux rename-window -t "$SESSION:$WIN" "agents" 2>/dev/null || true
    fi
    if ! bash "$ROSTER_LIB" retarget "$ID" "$TARGET" >/dev/null; then
      if [[ "$CREATED_NEW_PANE" == "1" ]]; then
        kill_pane "$TARGET"
      fi
      die "failed to retarget restored agent '$ID'"
    fi
    return 0
  fi

  if (( total <= 4 )); then
    active_count=$(jq '[.agents[] | select(.status=="active")] | length' "$(roster_file)")
    if (( active_count == 0 )); then
      if is_shell_pane "$SESSION:0.0"; then
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
      if is_shell_pane "$SESSION:0.0"; then
        TARGET="$SESSION:0.0"
      else
        TARGET=$(new_pane "$SESSION" 0)
        CREATED_NEW_PANE=1
      fi
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
          if is_shell_pane "$SESSION:$WIN.0"; then
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
  [[ -n "$RESUME_PROVIDER" ]] && ADD_ARGS+=("--resume-provider" "$RESUME_PROVIDER")
  [[ -n "$RESUME_ID" ]]       && ADD_ARGS+=("--resume-id" "$RESUME_ID")
  [[ -n "$RESUME_MODE" ]]     && ADD_ARGS+=("--resume-mode" "$RESUME_MODE")
  if ! bash "$ROSTER_LIB" add "${ADD_ARGS[@]}" >/dev/null; then
    if [[ "$CREATED_NEW_PANE" == "1" ]]; then
      kill_pane "$TARGET"
    fi
    die "failed to register spawned agent '$ID'"
  fi
}
with_file_lock "$(agents_dir)/spawn.lock.d" _allocate_target_and_register

if [[ "$RESTORE_ALREADY_LIVE" == "1" ]]; then
  status_line "orchestration" "RESTORE_SKIPPED_ALREADY_LIVE $ID role=$ROLE model=$MODEL target=$TARGET"
  ok "already live: $ID → $TARGET"
  exit 0
fi

# Build the CLI launch command.
# For claude: role is loaded via --append-system-prompt-file (reliable, no
# paste timing issues with the welcome dialog). A short kick-off message is
# sent after the CLI is ready instead of pasting the full file.
# For codex/others: paste the prompt file the old way (no equivalent flag).
launch_cli_cmd() {
  local model="$1"
  # Per-role var wins; fall back to global flag; default to 0.
  # Global ORCH_SKIP_PERMISSIONS=1 is an explicit launch-wide bypass and must
  # not be cancelled by model-select's per-role default of 0.
  local role_var="ORCH_SKIP_PERMISSIONS_${ROLE}"
  local role_skip="${!role_var:-0}"
  local global_skip="${ORCH_SKIP_PERMISSIONS:-0}"
  local skip=0
  if [[ "$global_skip" == "1" || "$role_skip" == "1" ]]; then
    skip=1
  fi
  case "$model" in
    claude)
      local flags="--append-system-prompt-file $(shell_quote "$PROMPT_FILE")"
      if [[ "$skip" == "1" ]]; then flags="--dangerously-skip-permissions $flags"; fi
      if [[ "$RESTORE_EXISTING" == "1" && "$RESUME_MODE" == "exact" && -n "$RESUME_ID" ]]; then
        echo "claude --resume $(shell_quote "$RESUME_ID") $flags"
        return
      fi
      if [[ "$RESUME_MODE" == "exact" && -n "$RESUME_ID" ]]; then
        echo "claude --session-id $(shell_quote "$RESUME_ID") $flags"
        return
      fi
      echo "claude $flags"
      ;;
    codex)
      local flags="--no-alt-screen"
      if [[ "$skip" == "1" ]]; then
        flags="--dangerously-bypass-approvals-and-sandbox $flags"
      fi
      if [[ "$RESTORE_EXISTING" == "1" && "$RESUME_MODE" == "exact" && -n "$RESUME_ID" ]]; then
        echo "codex resume $flags $(shell_quote "$RESUME_ID")"
        return
      fi
      if [[ "$skip" == "1" ]]; then
        echo "codex $flags"
      else
        echo "codex $flags"
      fi
      ;;
    gemini)     echo "gemini chat" ;;
    shell|none) echo "cat $(shell_quote "$PROMPT_FILE")" ;;
    *)
      warn "unknown model '$model' — falling back to 'shell' (prompt printed, not sent)"
      echo "cat $(shell_quote "$PROMPT_FILE")"
      ;;
  esac
}

capture_codex_resume_id() {
  [[ "$MODEL" == "codex" ]] || return 0
  [[ "$RESTORE_EXISTING" != "1" ]] || return 0
  local codex_home sessions_dir marker_id marker_project marker_token found sid max poll_ms delay_s i
  codex_home="${CODEX_HOME:-$HOME/.codex}"
  sessions_dir="$codex_home/sessions"
  [[ -d "$sessions_dir" ]] || return 0
  marker_id="You are agent **\`$ID\`**"
  marker_project="- Project root: \`$(project_root)\`"
  marker_token="- Launch token: \`$PROMPT_RUN_TOKEN\`"
  max="${ORCH_CODEX_RESUME_CAPTURE_MAX:-5}"
  poll_ms="${ORCH_CODEX_RESUME_CAPTURE_POLL_MS:-400}"
  [[ "$max" =~ ^[0-9]+$ ]] || max=5
  [[ "$poll_ms" =~ ^[0-9]+$ ]] || poll_ms=400
  delay_s=$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')
  for (( i=1; i<=max; i++ )); do
    found=$(
      find "$sessions_dir" -type f -name '*.jsonl' -mtime -2 -print 2>/dev/null \
        | while IFS= read -r f; do
            grep -Fq -- "$marker_id" "$f" 2>/dev/null || continue
            grep -Fq -- "$marker_project" "$f" 2>/dev/null || continue
            grep -Fq -- "$marker_token" "$f" 2>/dev/null || continue
            m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
            printf "%s\t%s\n" "$m" "$f"
          done \
        | sort -nr \
        | head -n 1 \
        | cut -f2-
    )
    [[ -n "$found" ]] && break
    sleep "$delay_s"
  done
  [[ -n "$found" ]] || { log_line "RESUME_CAPTURE_MISS: id=$ID model=codex"; return 0; }
  sid=$(head -n 1 "$found" | jq -r '.payload.id // .id // empty' 2>/dev/null || true)
  [[ -n "$sid" ]] || { log_line "RESUME_CAPTURE_NO_ID: id=$ID model=codex file=$found"; return 0; }
  bash "$ROSTER_LIB" set-resume "$ID" codex "$sid" --mode exact >/dev/null || true
  log_line "RESUME_CAPTURED: id=$ID model=codex resume_id=$sid file=$found"
  status_line "orchestration" "RESUME_CAPTURED $ID model=codex resume_id=$sid"
}

LAUNCH_CMD=$(launch_cli_cmd "$MODEL")
if [[ "${ORCH_LAUNCH_ECHO_ONLY:-0}" == "1" ]]; then
  LAUNCH_CMD="printf '%s\n' $(shell_quote "ORCH_LAUNCH_CMD: $LAUNCH_CMD")"
fi
BOOTSTRAP_TOKEN="BOOTSTRAP agent=$ID context_file=$PROMPT_FILE"

# Banner + CLI launch
send_line "$TARGET" "clear"
send_line "$TARGET" "echo '===== agent: $ID ($ROLE$([[ -n "$HATS" ]] && echo " +$HATS")) ====='"
send_line "$TARGET" "echo 'prompt: $PROMPT_FILE'"
send_line "$TARGET" "$LAUNCH_CMD"

# Deliver the role context to the agent once it's ready.
case "$MODEL" in
  shell|none)
    # `cat "$PROMPT_FILE"` can return to the shell before tmux capture observes
    # the rendered prompt. Wait briefly so restore/tests see the expected pane.
    prompt_marker=$(sed -n '/[^[:space:]]/{p;q;}' "$PROMPT_FILE" 2>/dev/null || true)
    if [[ -n "$prompt_marker" ]]; then
      for _prompt_wait in {1..30}; do
        pane_contains_text "$TARGET" "$prompt_marker" && break
        sleep 0.1
      done
    fi
    ;;
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
      send_message_submit "$TARGET" "1" || true
      log_line "CLAUDE_LIMIT_GATE: id=$ID target=$TARGET action=select_wait"
    fi
    # Wait specifically for the ❯ input prompt to be visible.
    # wait_for_cli_ready can return on a transient stable state (blank screen
    # between trust dismissal and the actual chat UI appearing). Checking for
    # ❯ ensures we don't send the kick-off too early.
    if wait_for_input_prompt "$TARGET"; then
      send_bootstrap_message "$TARGET" "$BOOTSTRAP_TOKEN loaded. Read it now and follow your Getting Started steps." || true
    else
      fallback="${ORCH_KICKOFF_FALLBACK_ENTER:-1}"
      if [[ "$fallback" == "1" ]]; then
        sleep 1
        warn "input prompt not visible for $ID — sending delayed kickoff fallback"
        log_line "KICKOFF_FALLBACK: id=$ID target=$TARGET reason=input_prompt_timeout"
        send_bootstrap_message "$TARGET" "$BOOTSTRAP_TOKEN loaded. Read it now and follow your Getting Started steps." || true
      else
        warn "input prompt not visible for $ID — skipped kickoff Enter"
        log_line "KICKOFF_SKIPPED: id=$ID target=$TARGET reason=input_prompt_timeout"
      fi
    fi
    ;;
  *)
    # codex / gemini: paste the full prompt file as the first message.
    wait_for_cli_ready "$TARGET" || warn "CLI readiness timed out for $ID — pasting anyway"
    if [[ "$MODEL" == "codex" ]]; then
      codex_state=$(wait_for_codex_prompt_or_gate "$TARGET" "${ORCH_CODEX_GATE_MAX:-12}" || true)
      if [[ "$codex_state" == "trust" ]]; then
        send_message_submit "$TARGET" "1" || true
        log_line "CODEX_TRUST_GATE: id=$ID target=$TARGET action=select_continue"
        wait_for_input_prompt "$TARGET" "${ORCH_CODEX_PROMPT_MAX:-15}" \
          || warn "Codex input prompt timed out for $ID after trust gate"
      elif [[ "$codex_state" == "timeout" ]]; then
        warn "Codex prompt/trust detection timed out for $ID"
        log_line "CODEX_GATE_TIMEOUT: id=$ID target=$TARGET"
        if [[ "${ORCH_LAUNCH_ECHO_ONLY:-0}" != "1" && "$RESTORE_EXISTING" == "1" && "$RESUME_MODE" == "exact" && -n "$RESUME_ID" ]]; then
          status_line "orchestration" "RESTORE_FAILED $ID role=$ROLE model=$MODEL target=$TARGET reason=codex_resume_timeout"
          exit 1
        fi
      fi
    fi
    if is_shell_pane "$TARGET" && [[ "${ORCH_LAUNCH_ECHO_ONLY:-0}" == "1" ]]; then
      log_line "PROMPT_SKIPPED: id=$ID target=$TARGET reason=launch_echo_only"
    elif is_shell_pane "$TARGET"; then
      warn "CLI exited before prompt delivery for $ID — skipping prompt/bootstrap"
      log_line "PROMPT_SKIPPED: id=$ID target=$TARGET reason=cli_exited"
      if [[ "$RESTORE_EXISTING" == "1" ]]; then
        status_line "orchestration" "RESTORE_FAILED $ID role=$ROLE model=$MODEL target=$TARGET reason=cli_exited"
        exit 1
      fi
      status_line "orchestration" "SPAWN_FAILED $ID role=$ROLE model=$MODEL target=$TARGET reason=cli_exited"
      ok "spawned: $ID → $TARGET"
      exit 0
    elif [[ "$MODEL" == "codex" && "$RESTORE_EXISTING" == "1" && "$RESUME_MODE" == "exact" && -n "$RESUME_ID" ]]; then
      send_bootstrap_message "$TARGET" "RESTORED agent=$ID resume_id=$RESUME_ID. Check your inbox and continue from the prior session." || true
      log_line "PROMPT_SKIPPED: id=$ID target=$TARGET model=$MODEL reason=resumed_session"
    else
      paste_to_pane "$TARGET" "$PROMPT_FILE"
      # Optional additional submit burst for stubborn draft states.
      if [[ "${ORCH_PASTE_EXTRA_ENTER:-1}" == "1" ]]; then
        ensure_submit_enter "$TARGET" "${ORCH_PASTE_EXTRA_ENTER_MAX:-2}" "${ORCH_PASTE_EXTRA_ENTER_DELAY_MS:-300}" || true
        submit_until_draft_clears "$TARGET" "${ORCH_PASTE_EXTRA_DRAFT_MAX:-8}" "${ORCH_PASTE_EXTRA_DRAFT_DELAY_MS:-350}" || true
      fi
    fi
    if [[ "${ORCH_LAUNCH_ECHO_ONLY:-0}" == "1" ]]; then
      :
    elif [[ "$MODEL" == "codex" ]]; then
      log_line "PROMPT_DELIVERED: id=$ID target=$TARGET model=$MODEL"
      capture_codex_resume_id
    else
      send_bootstrap_message "$TARGET" "$BOOTSTRAP_TOKEN loaded. Follow your Getting Started steps." || true
    fi
    ;;
esac

if [[ "$RESTORE_EXISTING" == "1" ]]; then
  status_line "orchestration" "RESTORE $ID role=$ROLE model=$MODEL target=$TARGET hats=[$HATS]"
  ok "restored: $ID → $TARGET"
else
  status_line "orchestration" "SPAWN $ID role=$ROLE model=$MODEL target=$TARGET hats=[$HATS]"
  ok "spawned: $ID → $TARGET"
fi
