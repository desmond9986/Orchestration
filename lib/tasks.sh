#!/usr/bin/env bash
# Shared task list — atomic claim, dependency-aware unblocking.
#
# Usage:
#   tasks.sh create <title> [--id <id>] [--depends <id,id,...>] [--note <text>]
#   tasks.sh claim  <task_id> <agent_id>                 # atomic claim (flock)
#   tasks.sh complete <task_id> <agent_id> [--note <text>]
#   tasks.sh block    <task_id> <agent_id> --reason <text>
#   tasks.sh unblock  <task_id> <agent_id> [--note <text>]
#   tasks.sh list                        # all tasks
#   tasks.sh list-available [--for <agent_id>]   # pending only, no unmet deps
#   tasks.sh show <task_id>
#
# State machine:
#   pending → claimed (owner set) → done
#   claimed → blocked (owner flags it) → pending (via unblock)
#   done and blocked are terminal until explicitly transitioned.
#
# Deps: a task is "available" only when every task in depends_on is done.
# When a task transitions to done, any dependents that became fully unblocked
# are announced to active orchestrator/coder agents only (throttled INFO).
#
# Storage: .agents/tasks.json
#   { tasks: [ {id, title, status, owner, depends_on, note, created,
#               claimed_at, completed_at, blocked_reason} ] }
#
# Locking: mkdir-based mutex on .agents/tasks.lock.d (atomic on POSIX,
# portable across macOS/Linux without needing flock).

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq

PROTOCOL_LIB="$(dirname "${BASH_SOURCE[0]}")/protocol.sh"

tasks_file() { echo "$(agents_dir)/tasks.json"; }
tasks_lock() { echo "$(agents_dir)/tasks.lock.d"; }
notify_state_file() { echo "$(agents_dir)/tasks.notify.json"; }
notify_cooldown_sec() { echo "${ORCH_TASK_NOTIFY_COOLDOWN_SEC:-300}"; }

ensure_tasks_file() {
  ensure_agents_dir
  if [[ ! -f "$(tasks_file)" ]]; then
    jq -n '{tasks:[]}' > "$(tasks_file)"
  fi
  if [[ ! -f "$(notify_state_file)" ]]; then
    jq -n '{last:{}}' > "$(notify_state_file)"
  fi
}

# Run a task-list mutation under the shared mutex.
with_lock() {
  ensure_tasks_file
  with_file_lock "$(tasks_lock)" "$@"
}

_write_tasks() {
  # Replace tasks.json atomically with the JSON piped in on stdin.
  local tmp; tmp=$(mktemp)
  cat > "$tmp"
  mv "$tmp" "$(tasks_file)"
}

new_task_id() {
  local n
  n=$(jq -r '.tasks | length' "$(tasks_file)")
  printf "t-%03d" "$((n + 1))"
}

_do_create() {
  local title="$1"; shift
  local id="" depends="[]" note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --id)      id="$2"; shift 2 ;;
      --depends) depends=$(echo "$2" | jq -R 'split(",") | map(select(length>0))'); shift 2 ;;
      --note)    note="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -z "$id" ]] && id=$(new_task_id)

  if jq -e --arg id "$id" '.tasks[] | select(.id==$id)' "$(tasks_file)" >/dev/null; then
    die "task already exists: $id"
  fi

  jq --arg id "$id" --arg title "$title" --arg note "$note" \
     --arg t "$(ts)" --argjson deps "$depends" \
     '.tasks += [{
        id:$id, title:$title, status:"pending", owner:null,
        depends_on:$deps, note:$note, created:$t,
        claimed_at:null, completed_at:null, blocked_reason:null
      }]' "$(tasks_file)" | _write_tasks
  ok "task created: $id — $title"
  echo "$id"
}

_deps_done() {
  # Return 0 if all deps of given task id are done.
  local task_id="$1"
  local unmet
  unmet=$(jq -r --arg id "$task_id" '
    (.tasks | map({key:.id, value:.status}) | from_entries) as $by
    | (.tasks[] | select(.id==$id) | .depends_on[]?)
    | select($by[.] != "done")
  ' "$(tasks_file)")
  [[ -z "$unmet" ]]
}

_active_notify_recipients() {
  jq -r '
    .agents[]
    | select(.status=="active")
    | select(.role=="orchestrator" or .role=="coder")
    | .id
  ' "$(roster_file)" 2>/dev/null
}

_notify_available_throttled() {
  local task_id="$1" from_id="$2" reason="$3"
  local cooldown now key last
  cooldown=$(notify_cooldown_sec)
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=300
  now=$(date +%s)
  key="$reason:$task_id"
  last=$(jq -r --arg k "$key" '.last[$k] // 0' "$(notify_state_file)" 2>/dev/null || echo 0)
  [[ "$last" =~ ^[0-9]+$ ]] || last=0

  if (( now - last < cooldown )); then
    return 0
  fi

  local id payload
  payload="task $task_id now available; claim with: bash \$ORCHESTRATION_HOME/lib/tasks.sh claim $task_id <agent_id>"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    [[ "$id" == "$from_id" ]] && continue
    bash "$PROTOCOL_LIB" send "$id" INFO "$payload" --from "$from_id" 2>/dev/null || true
  done < <(_active_notify_recipients)

  local tmp; tmp=$(mktemp)
  jq --arg k "$key" --argjson now "$now" '.last[$k]=$now' "$(notify_state_file)" > "$tmp" && mv "$tmp" "$(notify_state_file)"
}

_do_claim() {
  local task_id="$1" agent="$2"
  local row
  row=$(jq -c --arg id "$task_id" '.tasks[] | select(.id==$id)' "$(tasks_file)")
  [[ -n "$row" ]] || die "no such task: $task_id"

  local status owner
  status=$(jq -r '.status' <<<"$row")
  owner=$(jq -r '.owner'  <<<"$row")

  case "$status" in
    pending) : ;;
    blocked) die "task $task_id is blocked — run 'tasks.sh unblock' first" ;;
    claimed) die "task $task_id already claimed by $owner" ;;
    done)    die "task $task_id already done" ;;
    *)       die "task $task_id in unknown status: $status" ;;
  esac

  _deps_done "$task_id" || die "task $task_id has unmet dependencies"

  jq --arg id "$task_id" --arg owner "$agent" --arg t "$(ts)" '
    (.tasks[] | select(.id==$id)) |= (
      .status = "claimed" | .owner = $owner |
      .claimed_at = $t | .blocked_reason = null
    )
  ' "$(tasks_file)" | _write_tasks
  ok "claimed: $task_id by $agent"
}

_do_complete() {
  local task_id="$1" agent="$2"; shift 2
  local note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local row status owner
  row=$(jq -c --arg id "$task_id" '.tasks[] | select(.id==$id)' "$(tasks_file)")
  [[ -n "$row" ]] || die "no such task: $task_id"
  status=$(jq -r '.status' <<<"$row")
  owner=$(jq -r '.owner'  <<<"$row")

  case "$status" in
    claimed) : ;;
    pending) die "task $task_id is not claimed — run 'tasks.sh claim' first" ;;
    blocked) die "task $task_id is blocked — run 'tasks.sh unblock' before completing" ;;
    done)    die "task $task_id is already done" ;;
    *)       die "task $task_id in unknown status: $status" ;;
  esac
  [[ "$owner" == "$agent" ]] || die "task $task_id is owned by $owner, not $agent"

  jq --arg id "$task_id" --arg t "$(ts)" --arg note "$note" '
    (.tasks[] | select(.id==$id)) |= (
      .status = "done" | .completed_at = $t |
      (if $note != "" then .note = $note else . end)
    )
  ' "$(tasks_file)" | _write_tasks
  ok "completed: $task_id by $agent"

  # Find dependents that just became available — announce in targeted, throttled INFO.
  local newly_ready
  newly_ready=$(jq -r --arg id "$task_id" '
    (.tasks | map({key:.id, value:.status}) | from_entries) as $by
    | .tasks[]
    | select(.status=="pending")
    | select([.depends_on[]? | $by[.] == "done"] | all)
    | select(.depends_on | index($id))
    | .id
  ' "$(tasks_file)")

  for rid in $newly_ready; do
    _notify_available_throttled "$rid" "$agent" "deps_ready"
  done
}

_do_block() {
  local task_id="$1" agent="$2"; shift 2
  local reason=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --reason) reason="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -n "$reason" ]] || die "--reason required"

  local row status owner
  row=$(jq -c --arg id "$task_id" '.tasks[] | select(.id==$id)' "$(tasks_file)")
  [[ -n "$row" ]] || die "no such task: $task_id"
  status=$(jq -r '.status' <<<"$row")
  owner=$(jq -r '.owner'  <<<"$row")

  case "$status" in
    claimed)
      [[ "$owner" == "$agent" ]] \
        || die "only the owner can block a claimed task (owner=$owner)"
      ;;
    pending) : ;;  # any agent may preemptively block a pending task
    blocked) die "task $task_id is already blocked" ;;
    done)    die "task $task_id is done — cannot block a completed task" ;;
    *)       die "task $task_id in unknown status: $status" ;;
  esac

  jq --arg id "$task_id" --arg r "$reason" '
    (.tasks[] | select(.id==$id)) |= (
      .status = "blocked" | .blocked_reason = $r
    )
  ' "$(tasks_file)" | _write_tasks
  warn "blocked: $task_id ($reason)"
}

_do_unblock() {
  local task_id="$1" agent="$2"; shift 2
  local note=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --note) note="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local row status
  row=$(jq -c --arg id "$task_id" '.tasks[] | select(.id==$id)' "$(tasks_file)")
  [[ -n "$row" ]] || die "no such task: $task_id"
  status=$(jq -r '.status' <<<"$row")
  [[ "$status" == "blocked" ]] \
    || die "task $task_id is not blocked (status=$status)"

  jq --arg id "$task_id" --arg note "$note" '
    (.tasks[] | select(.id==$id)) |= (
      .status = "pending" | .owner = null | .blocked_reason = null |
      (if $note != "" then .note = $note else . end)
    )
  ' "$(tasks_file)" | _write_tasks
  ok "unblocked: $task_id by $agent"

  # Announce that the task is available again (targeted/throttled).
  _notify_available_throttled "$task_id" "$agent" "unblocked"
}

cmd_create()   { with_lock _do_create   "$@"; }
cmd_claim()    { with_lock _do_claim    "$@"; }
cmd_complete() { with_lock _do_complete "$@"; }
cmd_block()    { with_lock _do_block    "$@"; }
cmd_unblock()  { with_lock _do_unblock  "$@"; }

cmd_list() {
  ensure_tasks_file
  jq -r '
    .tasks[] |
    "\(.id)\t\(.status)\t\(.owner // "-")\t\(.depends_on | join(",") // "")\t\(.title)"
  ' "$(tasks_file)" | column -t -s $'\t'
}

cmd_list_available() {
  ensure_tasks_file
  local for_agent=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --for) for_agent="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  if [[ -n "$for_agent" ]]; then
    : "$for_agent"
  fi
  jq -r '
    (.tasks | map({key:.id, value:.status}) | from_entries) as $by
    | .tasks[]
    | select(.status=="pending")
    | select([.depends_on[]? | $by[.] == "done"] | all)
    | "\(.id)\t\(.status)\t\(.title)"
  ' "$(tasks_file)" | column -t -s $'\t'
}

cmd_show() {
  ensure_tasks_file
  local id="$1"
  jq --arg id "$id" '.tasks[] | select(.id==$id)' "$(tasks_file)"
}

cmd_help() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

CMD="${1:-help}"; shift || true
case "$CMD" in
  create)         cmd_create "$@" ;;
  claim)          cmd_claim "$@" ;;
  complete)       cmd_complete "$@" ;;
  block)          cmd_block "$@" ;;
  unblock)        cmd_unblock "$@" ;;
  list)           cmd_list ;;
  list-available) cmd_list_available "$@" ;;
  show)           cmd_show "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $CMD (try: tasks.sh help)" ;;
esac
