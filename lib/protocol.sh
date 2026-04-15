#!/usr/bin/env bash
# Inter-agent communication protocol — encapsulates the bug-prone tmux bits.
#
# Usage:
#   protocol.sh send <to_id> <TYPE> "<payload>" [--from <from_id>]
#   protocol.sh check-inbox <your_id>      # prints + archives unread messages
#   protocol.sh peek-inbox <your_id>       # prints without archiving
#   protocol.sh broadcast <TYPE> "<payload>" [--from <id>]    # send to all active
#   protocol.sh status <your_id> "<msg>"   # write to status board
#
# Message types (convention, not enforced):
#   TASK STATUS DONE BLOCKED QUESTION REVIEW_REQUEST VERDICT INFO

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq
require_cmd tmux

ROSTER_LIB="$(dirname "${BASH_SOURCE[0]}")/roster.sh"

CMD="${1:-help}"; shift || true

new_msg_id() { echo "msg-$(date +%s)-$RANDOM"; }

deliver_notify() {
  # Try to deliver notification to a tmux pane. Returns 0 on success.
  local target="$1" id="$2"
  if ! tmux has-session -t "${target%%:*}" 2>/dev/null; then
    return 1
  fi
  # Use load-buffer + paste-buffer for safety with multi-line / special chars.
  tmux send-keys -t "$target" "" Enter 2>/dev/null || return 1
  tmux send-keys -t "$target" "# CHECK INBOX ($id)" Enter 2>/dev/null || return 1
  return 0
}

cmd_send() {
  local to="$1" type="$2" payload="$3"; shift 3
  local from="${USER:-unknown}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  local target
  target=$(bash "$ROSTER_LIB" target "$to" 2>/dev/null || true)
  if [[ -z "$target" || "$target" == "null" ]]; then
    log_line "SEND_FAIL: target unknown for $to (from=$from type=$type)"
    die "no such agent in roster: $to"
  fi

  local msg_id; msg_id=$(new_msg_id)
  local inbox="$(inbox_dir)/$to.md"
  mkdir -p "$(inbox_dir)"
  {
    printf "\n[MSG from:%s to:%s type:%s id:%s ts:%s]\n" \
      "$from" "$to" "$type" "$msg_id" "$(ts)"
    printf "%s\n" "$payload"
    printf "[END]\n"
  } >> "$inbox"

  if deliver_notify "$target" "$to"; then
    ok "sent → $to [$type] id=$msg_id"
    status_line "$from" "SENT $type → $to (id=$msg_id)"
  else
    warn "wrote to inbox but tmux notify failed for $to ($target)"
    log_line "NOTIFY_FAIL: $to target=$target msg=$msg_id"
  fi
}

cmd_broadcast() {
  local type="$1" payload="$2"; shift 2
  local from="${USER:-unknown}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from="$2"; shift 2 ;;
      *) die "unknown flag: $1" ;;
    esac
  done
  local ids; ids=$(bash "$ROSTER_LIB" find-role "" 2>/dev/null || true)
  ids=$(jq -r '.agents[] | select(.status=="active") | .id' "$(roster_file)")
  for id in $ids; do
    [[ "$id" == "$from" ]] && continue
    cmd_send "$id" "$type" "$payload" --from "$from"
  done
}

cmd_check_inbox() {
  local id="$1"
  local inbox="$(inbox_dir)/$id.md"
  local archive="$(inbox_dir)/$id.archive.md"
  if [[ ! -s "$inbox" ]]; then
    echo "(inbox empty)"
    return 0
  fi
  cat "$inbox"
  cat "$inbox" >> "$archive"
  : > "$inbox"
  status_line "$id" "INBOX READ"
}

cmd_peek_inbox() {
  local id="$1"
  local inbox="$(inbox_dir)/$id.md"
  if [[ ! -s "$inbox" ]]; then
    echo "(inbox empty)"
  else
    cat "$inbox"
  fi
}

cmd_status() {
  local id="$1" msg="$2"
  status_line "$id" "$msg"
}

cmd_help() {
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

case "$CMD" in
  send)         cmd_send "$@" ;;
  broadcast)    cmd_broadcast "$@" ;;
  check-inbox)  cmd_check_inbox "$@" ;;
  peek-inbox)   cmd_peek_inbox "$@" ;;
  status)       cmd_status "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $CMD (try: protocol.sh help)" ;;
esac
