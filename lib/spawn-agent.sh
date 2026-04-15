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

# For the FIRST agent, reuse pane 0.0; otherwise split.
existing_count=$(tmux list-panes -t "$SESSION:0" 2>/dev/null | wc -l | tr -d ' ')
active_count=$(jq '[.agents[] | select(.status=="active")] | length' "$(roster_file)")

if (( active_count == 0 )); then
  TARGET="$SESSION:0.0"
else
  TARGET=$(new_pane "$SESSION")
fi

set_pane_title "$TARGET" "$ID"

# Register in roster
ADD_ARGS=("$ID" "$ROLE" "$MODEL" "$TARGET")
[[ -n "$HATS" ]]   && ADD_ARGS+=("--hats" "$HATS")
[[ -n "$PARENT" ]] && ADD_ARGS+=("--parent" "$PARENT")
bash "$ROSTER_LIB" add "${ADD_ARGS[@]}" >/dev/null

# Launch the CLI bare — prompts are pasted via tmux paste-buffer afterward so
# we never hit argv length limits (ARG_MAX ~256KB on macOS, and some CLIs cap
# input well below that). Prompts grow with project context — passing the
# whole thing as one argv string is fragile.
launch_cli_cmd() {
  local model="$1"
  case "$model" in
    claude)     echo "claude" ;;
    codex)      echo "codex" ;;
    gemini)     echo "gemini chat" ;;
    shell|none) echo "cat '$PROMPT_FILE'" ;;
    *)
      warn "unknown model '$model' — falling back to 'shell' (prompt printed, not sent)"
      echo "cat '$PROMPT_FILE'"
      ;;
  esac
}

# How long to wait after launching a CLI before pasting the initial prompt.
# Override with ORCH_CLI_READY_WAIT=N (seconds). Default gives CLIs time to
# print their banner and enter the read loop.
CLI_READY_WAIT="${ORCH_CLI_READY_WAIT:-3}"

LAUNCH_CMD=$(launch_cli_cmd "$MODEL")

# Banner + CLI launch
send_line "$TARGET" "clear"
send_line "$TARGET" "echo '===== agent: $ID ($ROLE$([[ -n "$HATS" ]] && echo " +$HATS")) ====='"
send_line "$TARGET" "echo 'prompt: $PROMPT_FILE'"
send_line "$TARGET" "$LAUNCH_CMD"

# Paste the prompt as the agent's first input (only for real CLIs).
case "$MODEL" in
  shell|none) : ;;
  *)
    sleep "$CLI_READY_WAIT"
    paste_to_pane "$TARGET" "$PROMPT_FILE"
    ;;
esac

status_line "orchestration" "SPAWN $ID role=$ROLE model=$MODEL target=$TARGET hats=[$HATS]"
ok "spawned: $ID → $TARGET"
