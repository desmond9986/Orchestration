#!/usr/bin/env bash
# Roster management — agents join/leave a live registry.
#
# Usage:
#   roster.sh init <session_name>
#   roster.sh add <id> <role> <model> <target> [--hats h1,h2] [--parent <id>]
#   roster.sh remove <id>
#   roster.sh retarget <id> <target>   # update tmux target for active agent
#   roster.sh list           # all agents (active + left)
#   roster.sh list-active    # only active
#   roster.sh find-role <role>      # IDs of active agents with this role
#   roster.sh target <id>           # tmux target (active agents only)
#   roster.sh target-any <id>       # tmux target regardless of status (archival)
#   roster.sh exists <id>           # exit 0 if active, 1 otherwise
#   roster.sh session               # current session name
#   roster.sh show <id>             # full json record for one agent

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq

CMD="${1:-help}"; shift || true

cmd_init() {
  local session="${1:-orchestration}"
  ensure_agents_dir
  if [[ -f "$(roster_file)" ]]; then
    die "roster already exists at $(roster_file). Run 'end-session' first."
  fi
  jq -n --arg s "$session" --arg t "$(ts)" \
    '{session:$s, started:$t, agents:[]}' > "$(roster_file)"
  ok "roster initialized: session=$session"
}

roster_lock() { echo "$(agents_dir)/roster.lock.d"; }
valid_agent_id() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }

_do_add() {
  local id="$1" role="$2" model="$3" target="$4"; shift 4
  local hats="[]" parent="null"
  valid_agent_id "$id" || die "invalid agent id '$id' (allowed: [A-Za-z0-9_-])"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --hats) hats=$(echo "$2" | jq -R 'split(",")'); shift 2 ;;
      --parent)
        valid_agent_id "$2" || die "invalid parent id '$2' (allowed: [A-Za-z0-9_-])"
        parent=$(jq -n --arg p "$2" '$p')
        shift 2
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  [[ -f "$(roster_file)" ]] || die "no roster — run 'roster.sh init <session>' first"
  if cmd_exists_quiet "$id"; then
    die "agent already exists: $id"
  fi
  local tmp
  tmp=$(mktemp)
  jq --arg id "$id" --arg role "$role" --arg model "$model" \
     --arg target "$target" --arg t "$(ts)" \
     --argjson hats "$hats" --argjson parent "$parent" \
     '.agents += [{
        id:$id, role:$role, model:$model, target:$target,
        hats:$hats, parent:$parent, status:"active", joined:$t
      }]' "$(roster_file)" > "$tmp" && mv "$tmp" "$(roster_file)"
  ok "added: $id ($role, $model) → $target"
}

_do_remove() {
  local id="$1"
  [[ -f "$(roster_file)" ]] || die "no roster"
  # Verify the agent exists (any status) before mutating; otherwise `jq`
  # produces an unchanged file and we'd falsely report success.
  local found
  found=$(jq -r --arg id "$id" \
    '.agents[] | select(.id==$id) | .id' "$(roster_file)")
  [[ -n "$found" ]] || die "no such agent: $id"
  local tmp; tmp=$(mktemp)
  jq --arg id "$id" --arg t "$(ts)" \
    '(.agents[] | select(.id==$id) | .status) = "left" |
     (.agents[] | select(.id==$id) | .left) = $t' \
    "$(roster_file)" > "$tmp" && mv "$tmp" "$(roster_file)"
  ok "removed: $id"
}

_do_retarget() {
  local id="$1" target="$2"
  [[ -f "$(roster_file)" ]] || die "no roster"
  local found
  found=$(jq -r --arg id "$id" \
    '.agents[] | select(.id==$id and .status=="active") | .id' "$(roster_file)")
  [[ -n "$found" ]] || die "no active agent to retarget: $id"
  local tmp; tmp=$(mktemp)
  jq --arg id "$id" --arg target "$target" --arg t "$(ts)" \
    '(.agents[] | select(.id==$id and .status=="active") | .target) = $target |
     (.agents[] | select(.id==$id and .status=="active") | .retargeted) = $t' \
    "$(roster_file)" > "$tmp" && mv "$tmp" "$(roster_file)"
  ok "retargeted: $id -> $target"
}

# Mutations are serialized through the roster lock — concurrent add/remove
# used to race through read-modify-write and drop entries.
cmd_add()    { with_file_lock "$(roster_lock)" _do_add "$@"; }
cmd_remove() { with_file_lock "$(roster_lock)" _do_remove "$@"; }
cmd_retarget(){ with_file_lock "$(roster_lock)" _do_retarget "$@"; }

cmd_list() {
  jq -r '.agents[] | "\(.id)\t\(.role)\t\(.model)\t\(.target)\t\(.status)"' \
    "$(roster_file)" | column -t -s $'\t'
}

cmd_list_active() {
  jq -r '.agents[] | select(.status=="active") |
         "\(.id)\t\(.role)\t\(.model)\t\(.target)\t[\(.hats|join(","))]"' \
    "$(roster_file)" | column -t -s $'\t'
}

cmd_find_role() {
  local role="$1"
  jq -r --arg r "$role" \
    '.agents[] | select(.status=="active" and .role==$r) | .id' \
    "$(roster_file)"
}

cmd_target() {
  local id="$1"
  jq -r --arg id "$id" \
    '.agents[] | select(.id==$id and .status=="active") | .target' \
    "$(roster_file)"
}

cmd_target_any() {
  local id="$1"
  jq -r --arg id "$id" \
    '.agents[] | select(.id==$id) | .target' \
    "$(roster_file)"
}

cmd_exists_quiet() {
  local id="$1"
  [[ -f "$(roster_file)" ]] || return 1
  local found
  found=$(jq -r --arg id "$id" \
    '.agents[] | select(.id==$id and .status=="active") | .id' \
    "$(roster_file)")
  [[ -n "$found" ]]
}

cmd_exists() {
  cmd_exists_quiet "$1"
}

cmd_session() {
  jq -r '.session' "$(roster_file)"
}

cmd_show() {
  local id="$1"
  jq --arg id "$id" '.agents[] | select(.id==$id)' "$(roster_file)"
}

cmd_help() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "$CMD" in
  init)        cmd_init "$@" ;;
  add)         cmd_add "$@" ;;
  remove)      cmd_remove "$@" ;;
  retarget)    cmd_retarget "$@" ;;
  list)        cmd_list ;;
  list-active) cmd_list_active ;;
  find-role)   cmd_find_role "$@" ;;
  target)      cmd_target "$@" ;;
  target-any)  cmd_target_any "$@" ;;
  exists)      cmd_exists "$@" ;;
  session)     cmd_session ;;
  show)        cmd_show "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $CMD (try: roster.sh help)" ;;
esac
