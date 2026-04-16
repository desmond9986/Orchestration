#!/usr/bin/env bash
# Inter-agent communication protocol — encapsulates the bug-prone tmux bits.
#
# Usage:
#   protocol.sh send <to_id> <TYPE> "<payload>" [--from <from_id>]
#   protocol.sh check-inbox <your_id>      # prints + archives unread messages
#   protocol.sh peek-inbox <your_id>       # prints without archiving
#   protocol.sh check-archive <your_id>    # prints archived messages
#   protocol.sh broadcast <TYPE> "<payload>" [--from <id>]    # send to all active
#   protocol.sh status <your_id> "<msg>"   # write to status board
#
# Delivery modes (env ORCH_DELIVERY):
#   notify  (default) — write to inbox, print "# CHECK INBOX" in target pane
#   push              — write to inbox AND paste the full message into target pane
#   silent            — write to inbox only, no tmux interaction
#
#
# Inbox format: JSON Lines (.jsonl). One object per message:
#   {"id","ts","from","to","type","payload","read":false}
#
# Message types (convention, not enforced):
#   TASK STATUS DONE BLOCKED QUESTION REVIEW_REQUEST VERDICT INFO

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_cmd jq
require_cmd tmux

ROSTER_LIB="$(dirname "${BASH_SOURCE[0]}")/roster.sh"
DELIVERY="${ORCH_DELIVERY:-notify}"

CMD="${1:-help}"; shift || true

new_msg_id() { echo "msg-$(date +%s)-$RANDOM"; }

inbox_path()   { echo "$(inbox_dir)/$1.jsonl"; }
archive_path() { echo "$(inbox_dir)/$1.archive.jsonl"; }

# Strip control chars before echoing values into interactive panes.
# Keeps logs readable and prevents terminal escape/control injection.
sanitize_for_pane() {
  printf "%s" "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

deliver_notify() {
  # Minimal notification: blank line + "# CHECK INBOX (id)".
  local target="$1" id="$2" from="${3:-unknown}"
  local safe_id safe_from
  safe_id=$(sanitize_for_pane "$id")
  safe_from=$(sanitize_for_pane "$from")
  safe_id="${safe_id//$'\n'/ }"; safe_id="${safe_id//$'\r'/ }"
  safe_from="${safe_from//$'\n'/ }"; safe_from="${safe_from//$'\r'/ }"
  tmux has-session -t "${target%%:*}" 2>/dev/null || return 1
  # Clear any partially typed line so notify never submits stale input.
  tmux send-keys -t "$target" C-u 2>/dev/null || return 1
  tmux send-keys -t "$target" "# CHECK INBOX ($safe_id) from:$safe_from" 2>/dev/null || return 1
  tmux send-keys -t "$target" C-m 2>/dev/null || return 1
  return 0
}

deliver_push() {
  # Paste the full message block into the target pane so the agent sees it
  # immediately without polling. Still writes to inbox as audit trail.
  local target="$1" json_line="$2"
  tmux has-session -t "${target%%:*}" 2>/dev/null || return 1
  local from to type id payload
  from=$(jq -r '.from'    <<<"$json_line")
  to=$(jq -r '.to'        <<<"$json_line")
  type=$(jq -r '.type'    <<<"$json_line")
  id=$(jq -r '.id'        <<<"$json_line")
  payload=$(jq -r '.payload' <<<"$json_line")

  local tmpf; tmpf=$(mktemp)
  {
    printf "\n# ─── INCOMING [%s] from:%s type:%s id:%s ───\n" \
      "$(ts_short)" "$from" "$type" "$id"
    printf "%s\n" "$payload"
    printf "# ─── END (reply: orch-send %s \"...\" or via protocol.sh send) ───\n" "$from"
  } > "$tmpf"

  local buf="orch-msg-$(date +%s%N)"
  tmux load-buffer -b "$buf" "$tmpf"
  tmux paste-buffer -b "$buf" -t "$target" -d 2>/dev/null || { rm -f "$tmpf"; return 1; }
  tmux send-keys -t "$target" C-m 2>/dev/null || true
  rm -f "$tmpf"
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
    log_line "SEND_FAIL: target unknown or agent inactive for $to (from=$from type=$type)"
    die "no active agent in roster: $to (check 'roster.sh list' — may have left)"
  fi

  local msg_id; msg_id=$(new_msg_id)
  local inbox; inbox=$(inbox_path "$to")
  mkdir -p "$(inbox_dir)"

  local json_line
  json_line=$(jq -c -n \
    --arg id "$msg_id" --arg ts "$(ts)" \
    --arg from "$from" --arg to "$to" \
    --arg type "$type" --arg payload "$payload" \
    '{id:$id, ts:$ts, from:$from, to:$to, type:$type, payload:$payload, read:false}')
  printf "%s\n" "$json_line" >> "$inbox"

  # Mirror to human-readable bus log.
  bus_line "$from" "$to" "$type" "$msg_id" "$payload"
  status_line "$from" "SENT $type → $to (id=$msg_id)"

  case "$DELIVERY" in
    silent)
      ok "queued → $to [$type] id=$msg_id (silent)"
      ;;
    push)
      if deliver_push "$target" "$json_line"; then
        ok "pushed → $to [$type] id=$msg_id"
      elif deliver_notify "$target" "$to" "$from"; then
        warn "push failed, fell back to notify for $to"
      else
        warn "wrote to inbox but tmux delivery failed for $to ($target)"
        log_line "DELIVER_FAIL: $to target=$target msg=$msg_id mode=push"
      fi
      ;;
    notify|*)
      if deliver_notify "$target" "$to" "$from"; then
        ok "sent → $to [$type] id=$msg_id"
      else
        warn "wrote to inbox but tmux notify failed for $to ($target)"
        log_line "NOTIFY_FAIL: $to target=$target msg=$msg_id"
      fi
      ;;
  esac
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
  local ids
  ids=$(jq -r '.agents[] | select(.status=="active") | .id' "$(roster_file)")
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    [[ "$id" == "$from" ]] && continue
    cmd_send "$id" "$type" "$payload" --from "$from"
  done <<< "$ids"
}

cmd_check_inbox() {
  local id="$1"
  local inbox; inbox=$(inbox_path "$id")
  local archive; archive=$(archive_path "$id")
  # Atomic rename snapshots the current inbox. Any concurrent send's >> will
  # create a new inbox file and append there safely — the read/archive here
  # operates on the snapshot in isolation, so no messages are dropped by a
  # race between cat and truncate.
  local snapshot="${inbox}.reading.$$"
  if ! mv "$inbox" "$snapshot" 2>/dev/null; then
    echo "(inbox empty)"
    return 0
  fi
  if [[ ! -s "$snapshot" ]]; then
    rm -f "$snapshot"
    echo "(inbox empty)"
    return 0
  fi
  jq -r '
    "\n[\(.ts)] id=\(.id) type=[\(.type)]\nFROM: \(.from)\nTO:   \(.to)\n\(.payload)\n[END]"
  ' "$snapshot"
  cat "$snapshot" >> "$archive"
  rm -f "$snapshot"
  status_line "$id" "INBOX READ"
}

cmd_peek_inbox() {
  local id="$1"
  local inbox; inbox=$(inbox_path "$id")
  if [[ ! -s "$inbox" ]]; then
    echo "(inbox empty)"
  else
    jq -r '
      "\n[\(.ts)] id=\(.id) type=[\(.type)]\nFROM: \(.from)\nTO:   \(.to)\n\(.payload)\n[END]"
    ' "$inbox"
  fi
}

cmd_check_archive() {
  local id="$1"
  local archive; archive=$(archive_path "$id")
  if [[ ! -s "$archive" ]]; then
    echo "(archive empty)"
  else
    jq -r '
      "\n[\(.ts)] id=\(.id) type=[\(.type)]\nFROM: \(.from)\nTO:   \(.to)\n\(.payload)\n[END]"
    ' "$archive"
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
  check-archive) cmd_check_archive "$@" ;;
  status)       cmd_status "$@" ;;
  help|-h|--help) cmd_help ;;
  *) die "unknown command: $CMD (try: protocol.sh help)" ;;
esac
