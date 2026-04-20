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
#   notify  (default) — write to inbox, send "check inbox(<id>) from:<sender>" hint to pane
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

new_msg_id() { echo "msg-$(date +%s)-$$-$RANDOM-$RANDOM"; }

inbox_path()   { echo "$(inbox_dir)/$1.jsonl"; }
archive_path() { echo "$(inbox_dir)/$1.archive.jsonl"; }
inbox_lock()   { echo "$(inbox_dir)/$1.lock.d"; }
enforce_cfg_path() { echo "$(agents_dir)/enforce.json"; }
valid_agent_id() { [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]; }
normalize_agent_label() {
  local s="$1"
  # Keep labels shell-safe for pane hints without rejecting legacy caller names.
  s=$(printf "%s" "$s" | LC_ALL=C tr -cd 'A-Za-z0-9_-' )
  [[ -n "$s" ]] || s="unknown"
  printf "%s" "$s"
}

# Strip control chars before echoing values into interactive panes.
# Keeps logs readable and prevents terminal escape/control injection.
sanitize_for_pane() {
  printf "%s" "$1" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177'
}

schema_required_enabled() {
  [[ -f "$(enforce_cfg_path)" ]] || return 1
  jq -e '(.enabled == true) and (.schema_required == true)' "$(enforce_cfg_path)" >/dev/null 2>&1
}

payload_has_key() {
  local payload="$1" key="$2"
  printf "%s" "$payload" | grep -Eiq "(^|[^[:alnum:]_])\"?$key\"?[[:space:]]*[:=]"
}

validate_message_schema() {
  local type="$1" payload="$2"
  schema_required_enabled || return 0

  local missing=()
  case "$type" in
    TASK)
      payload_has_key "$payload" "objective" || missing+=("objective")
      payload_has_key "$payload" "definition_of_done" || missing+=("definition_of_done")
      payload_has_key "$payload" "required_reply" || missing+=("required_reply")
      ;;
    DONE)
      payload_has_key "$payload" "commit_hash" || missing+=("commit_hash")
      payload_has_key "$payload" "changed_files" || missing+=("changed_files")
      payload_has_key "$payload" "test_result" || missing+=("test_result")
      ;;
    *)
      return 0
      ;;
  esac

  if (( ${#missing[@]} > 0 )); then
    die "schema validation failed for $type — missing: $(IFS=,; echo "${missing[*]}"). Include key:value fields in payload."
  fi
}

pane_exists() {
  local target="$1"
  tmux display-message -p -t "$target" '#{pane_id}' >/dev/null 2>&1
}

canonical_target() {
  local target="$1"
  tmux display-message -p -t "$target" '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null || true
}

pane_agent_id() {
  local target="$1"
  tmux display-message -p -t "$target" '#{@orch_agent_id}' 2>/dev/null || true
}

probe_orch_meta_support() {
  if [[ -n "${_ORCH_META_PROBED:-}" ]]; then
    return 0
  fi
  _ORCH_META_PROBED=1
  local key="@orch_probe_$$"
  if tmux set-option -gq "$key" "1" 2>/dev/null && tmux display-message -p "#{${key}}" >/dev/null 2>&1; then
    _ORCH_META_SUPPORTED=1
    tmux set-option -gu "$key" 2>/dev/null || true
  else
    _ORCH_META_SUPPORTED=0
    warn "tmux pane metadata (@orch_agent_id) not available; auto-retarget reliability reduced"
    log_line "META_UNSUPPORTED: @orch_agent_id unavailable"
  fi
}

recover_target() {
  local target_hint="$1" id="$2"
  local session="${target_hint%%:*}"
  tmux has-session -t "$session" 2>/dev/null || return 1
  probe_orch_meta_support
  # Prefer stable pane metadata (@orch_agent_id).
  # Tab-delimited so titles/ids containing spaces match correctly.
  local recovered recovered_count
  recovered=$(tmux list-panes -t "$session" -F "#{session_name}:#{window_index}.#{pane_index}	#{@orch_agent_id}	#{pane_title}" 2>/dev/null \
    | awk -F'\t' -v aid="$id" '$2==aid{print $1}')
  recovered_count=$(printf "%s\n" "$recovered" | sed '/^$/d' | wc -l | tr -d ' ')
  if (( recovered_count == 1 )); then
    printf "%s" "$(printf "%s\n" "$recovered" | sed -n '1p')"
    return 0
  fi
  if (( recovered_count > 1 )); then
    local candidates
    candidates=$(printf "%s\n" "$recovered" | sed '/^$/d' | paste -sd',' -)
    log_line "RETARGET_AMBIGUOUS: $id via @orch_agent_id matches=$recovered_count candidates=$candidates"
    return 1
  fi

  # Optional legacy fallback by mutable pane title; disabled by default.
  if [[ "${ORCH_ALLOW_TITLE_RETARGET:-0}" == "1" ]]; then
    recovered=$(tmux list-panes -t "$session" -F "#{session_name}:#{window_index}.#{pane_index}	#{@orch_agent_id}	#{pane_title}" 2>/dev/null \
      | awk -F'\t' -v aid="$id" '$3==aid{print $1}')
    recovered_count=$(printf "%s\n" "$recovered" | sed '/^$/d' | wc -l | tr -d ' ')
    if (( recovered_count == 1 )); then
      printf "%s" "$(printf "%s\n" "$recovered" | sed -n '1p')"
      return 0
    fi
    if (( recovered_count > 1 )); then
      local title_candidates
      title_candidates=$(printf "%s\n" "$recovered" | sed '/^$/d' | paste -sd',' -)
      log_line "RETARGET_AMBIGUOUS: $id via pane_title matches=$recovered_count candidates=$title_candidates"
      return 1
    fi
  fi
  return 1
}

resolve_target() {
  local to="$1"
  probe_orch_meta_support
  local target
  target=$(bash "$ROSTER_LIB" target "$to" 2>/dev/null || true)
  if [[ -z "$target" || "$target" == "null" ]]; then
    return 1
  fi
  if pane_exists "$target"; then
    local canon
    canon=$(canonical_target "$target")
    [[ -n "$canon" ]] || canon="$target"
    # Trust existing target only when stable pane metadata confirms identity.
    local pid
    pid=$(pane_agent_id "$target")
    if [[ -n "$pid" && "$pid" == "$to" ]]; then
      if [[ "$canon" != "$target" ]]; then
        bash "$ROSTER_LIB" retarget "$to" "$canon" >/dev/null 2>&1 || true
        log_line "RETARGET_CANON: $to old=$target new=$canon"
      fi
      printf "%s" "$canon"
      return 0
    fi
    if [[ -n "$pid" && "$pid" != "$to" ]]; then
      log_line "TARGET_MISMATCH: $to target=$target has=$pid"
    else
      log_line "TARGET_UNVERIFIED: $to target=$target missing=@orch_agent_id"
    fi
  fi

  local recovered
  recovered=$(recover_target "$target" "$to" || true)
  if [[ -n "$recovered" ]]; then
    if bash "$ROSTER_LIB" retarget "$to" "$recovered" >/dev/null 2>&1; then
      log_line "RETARGET_OK: $to old=$target new=$recovered"
      status_line "orchestration" "RETARGET $to $target -> $recovered"
      printf "%s" "$recovered"
      return 0
    fi
  fi

  log_line "RETARGET_FAIL: $to old=$target"
  return 1
}

wait_for_delivery_token() {
  local target="$1" token="$2"
  local timeout_ms="${ORCH_NOTIFY_ACK_TIMEOUT_MS:-1200}"
  local poll_ms=120
  local deadline=$(( $(date +%s) * 1000 + timeout_ms ))
  while (( $(date +%s) * 1000 < deadline )); do
    if tmux capture-pane -p -t "$target" 2>/dev/null | grep -Fq "$token"; then
      return 0
    fi
    sleep "$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')"
  done
  return 1
}

wait_for_receiver_ack() {
  local id="$1" msg_id="$2"
  local timeout_ms="${ORCH_RECEIVER_ACK_TIMEOUT_MS:-5000}"
  local poll_ms=150
  local archive; archive=$(archive_path "$id")
  local deadline=$(( $(date +%s) * 1000 + timeout_ms ))
  while (( $(date +%s) * 1000 < deadline )); do
    if [[ -s "$archive" ]] && grep -Fq "\"id\":\"$msg_id\"" "$archive" 2>/dev/null; then
      return 0
    fi
    sleep "$(awk -v ms="$poll_ms" 'BEGIN { printf "%.3f", ms/1000 }')"
  done
  return 1
}

_append_inbox_locked() {
  local inbox="$1" line="$2"
  printf "%s\n" "$line" >> "$inbox"
}

deliver_notify() {
  # Send a short hint into the target pane so the agent knows to check inbox.
  # Uses mkdir-based lock to serialize concurrent notifies to the same pane
  # (prevents interleaving when two senders target the same agent).
  local target="$1" id="$2" from="${3:-unknown}" msg_id="${4:-unknown}"
  local safe_id safe_from
  safe_id=$(sanitize_for_pane "$id")
  safe_from=$(normalize_agent_label "$(sanitize_for_pane "$from")")
  safe_id="${safe_id//$'\n'/ }"; safe_id="${safe_id//$'\r'/ }"
  safe_from="${safe_from//$'\n'/ }"; safe_from="${safe_from//$'\r'/ }"
  tmux has-session -t "${target%%:*}" 2>/dev/null || return 1
  pane_exists "$target" || return 1

  # Atomic mkdir lock per target — portable (works on macOS + Linux).
  local lockdir="/tmp/orch-notify-${target//[^a-zA-Z0-9_]/_}.lock"
  local tries=0
  local max_tries="${ORCH_NOTIFY_LOCK_MAX_TRIES:-100}"
  while ! mkdir "$lockdir" 2>/dev/null; do
    # Stale lock recovery: if the lockdir is older than 5s, a previous caller
    # crashed or was killed between mkdir and cleanup. Forcibly remove it.
    if [[ -d "$lockdir" ]]; then
      local age
      local mtime
      mtime=$(stat -c %Y "$lockdir" 2>/dev/null || true)
      if [[ ! "$mtime" =~ ^[0-9]+$ ]]; then
        mtime=$(stat -f %m "$lockdir" 2>/dev/null || true)
      fi
      [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=$(date +%s)
      age=$(( $(date +%s) - mtime ))
      if (( age > 5 )); then
        warn "removing stale notify lock for $target (age ${age}s)"
        rm -rf "$lockdir"
        continue
      fi
    fi
    tries=$((tries + 1))
    if (( tries > max_tries )); then
      warn "notify lock timeout for $target"
      return 1
    fi
    sleep 0.1
  done
  # Ensure lockdir is cleaned up even if caller is interrupted (SIGINT/TERM).
  trap 'rm -rf "$lockdir"' INT TERM EXIT
  # Clear any partially typed line so notify never submits stale input.
  tmux send-keys -t "$target" C-u 2>/dev/null || { rm -rf "$lockdir"; trap - INT TERM EXIT; return 1; }
  sleep 0.1
  # Prefix with ':' so shell panes treat it as no-op, while CLIs still see the
  # human-readable hint text.
  local marker hint strict_ack
  marker="m$(printf "%s" "$msg_id" | cksum | awk '{print $1}')"
  strict_ack="${ORCH_NOTIFY_STRICT_ACK:-0}"
  hint=": check-inbox $safe_id from:$safe_from"
  # Only append the internal marker when strict marker-ack is enabled.
  # Otherwise keep pane hints clean to avoid confusion with real msg ids.
  if [[ "$strict_ack" == "1" ]]; then
    hint="$hint $marker"
  fi
  # Use check-inbox without shell glob chars so zsh panes do not error.
  tmux send-keys -t "$target" "$hint" 2>/dev/null || { rm -rf "$lockdir"; trap - INT TERM EXIT; return 1; }
  sleep 0.1
  tmux send-keys -t "$target" C-m 2>/dev/null || { rm -rf "$lockdir"; trap - INT TERM EXIT; return 1; }
  # Optional strict marker ack. Disabled by default because wrapped lines can
  # split marker text and create false negatives.
  if [[ "$strict_ack" == "1" ]]; then
    if ! wait_for_delivery_token "$target" "$marker"; then
      rm -rf "$lockdir"
      trap - INT TERM EXIT
      return 1
    fi
  fi
  # Let the CLI process before releasing the lock.
  sleep 0.1
  rm -rf "$lockdir"
  trap - INT TERM EXIT
  return 0
}

deliver_push() {
  # Paste the full message block into the target pane so the agent sees it
  # immediately without polling. Still writes to inbox as audit trail.
  local target="$1" json_line="$2"
  tmux has-session -t "${target%%:*}" 2>/dev/null || return 1
  pane_exists "$target" || return 1
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

  local buf
  buf="orch-msg-$(date +%s%N)"
  tmux load-buffer -b "$buf" "$tmpf"
  tmux paste-buffer -b "$buf" -t "$target" -d 2>/dev/null || { rm -f "$tmpf"; return 1; }
  tmux send-keys -t "$target" C-m 2>/dev/null || true
  if [[ "${ORCH_PUSH_STRICT_ACK:-0}" == "1" ]]; then
    if ! wait_for_delivery_token "$target" "id:$id"; then
      rm -f "$tmpf"
      return 1
    fi
  fi
  rm -f "$tmpf"
  return 0
}

cmd_send() {
  local to="$1" type="$2" payload="$3"; shift 3
  local from="${USER:-unknown}"
  type=$(printf "%s" "$type" | tr '[:lower:]' '[:upper:]')
  valid_agent_id "$to" || die "invalid recipient id '$to' (allowed: [A-Za-z0-9_-])"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from)
        from="$2"
        from=$(normalize_agent_label "$from")
        shift 2
        ;;
      *) die "unknown flag: $1" ;;
    esac
  done

  validate_message_schema "$type" "$payload"

  # Only gate on active roster membership here. Delivery reachability is
  # handled later so inbox writes remain durable even when tmux is unavailable.
  local target_hint
  target_hint=$(bash "$ROSTER_LIB" target "$to" 2>/dev/null || true)
  if [[ -z "$target_hint" || "$target_hint" == "null" ]]; then
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
  with_file_lock "$(inbox_lock "$to")" _append_inbox_locked "$inbox" "$json_line"

  # Mirror to human-readable bus log.
  bus_line "$from" "$to" "$type" "$msg_id" "$payload"
  status_line "$from" "SENT $type → $to (id=$msg_id)"

  case "$DELIVERY" in
    silent)
      ok "queued → $to [$type] id=$msg_id (silent)"
      ;;
    push)
      local target
      target=$(resolve_target "$to" 2>/dev/null || true)
      if [[ -z "$target" ]]; then
        warn "queued to inbox but no reachable tmux target for $to (mode=push)"
        log_line "DELIVER_FAIL: $to target=$target_hint msg=$msg_id mode=push"
        return 0
      fi
      if deliver_push "$target" "$json_line"; then
        ok "pushed → $to [$type] id=$msg_id"
      elif deliver_notify "$target" "$to" "$from" "$msg_id"; then
        warn "push failed, fell back to notify for $to"
      else
        local retry_target
        retry_target=$(resolve_target "$to" 2>/dev/null || true)
        if [[ -n "$retry_target" ]] && (deliver_push "$retry_target" "$json_line" || deliver_notify "$retry_target" "$to" "$from" "$msg_id"); then
          warn "first delivery failed, retry succeeded for $to on $retry_target"
        else
          warn "wrote to inbox but tmux delivery failed for $to ($target)"
          log_line "DELIVER_FAIL: $to target=$target msg=$msg_id mode=push"
        fi
      fi
      ;;
    notify|*)
      local target
      target=$(resolve_target "$to" 2>/dev/null || true)
      if [[ -z "$target" ]]; then
        warn "queued to inbox but no reachable tmux target for $to (mode=notify)"
        log_line "NOTIFY_FAIL: $to target=$target_hint msg=$msg_id"
        return 0
      fi
      if deliver_notify "$target" "$to" "$from" "$msg_id"; then
        ok "sent → $to [$type] id=$msg_id"
      else
        local retry_target
        retry_target=$(resolve_target "$to" 2>/dev/null || true)
        if [[ -n "$retry_target" ]] && deliver_notify "$retry_target" "$to" "$from" "$msg_id"; then
          warn "first notify failed, retry succeeded for $to on $retry_target"
        else
          warn "wrote to inbox but tmux notify failed for $to ($target)"
          log_line "NOTIFY_FAIL: $to target=$target msg=$msg_id"
        fi
      fi
      ;;
  esac

  if [[ "${ORCH_REQUIRE_RECEIVER_ACK:-0}" == "1" ]]; then
    if wait_for_receiver_ack "$to" "$msg_id"; then
      status_line "$from" "ACKED by $to (id=$msg_id)"
    else
      warn "receiver ack timeout for $to ($msg_id)"
      log_line "ACK_TIMEOUT: to=$to msg=$msg_id"
    fi
  fi
}

cmd_broadcast() {
  local type="$1" payload="$2"; shift 2
  local from
  from=$(normalize_agent_label "${USER:-unknown}")
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --from) from=$(normalize_agent_label "$2"); shift 2 ;;
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
  valid_agent_id "$id" || die "invalid id '$id' (allowed: [A-Za-z0-9_-])"
  local inbox; inbox=$(inbox_path "$id")
  local archive; archive=$(archive_path "$id")
  with_file_lock "$(inbox_lock "$id")" _check_inbox_locked "$id" "$inbox" "$archive"
}

_check_inbox_locked() {
  local id="$1" inbox="$2" archive="$3"
  # Atomic rename snapshots the current inbox and the lock prevents writer races.
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
  valid_agent_id "$id" || die "invalid id '$id' (allowed: [A-Za-z0-9_-])"
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
  valid_agent_id "$id" || die "invalid id '$id' (allowed: [A-Za-z0-9_-])"
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
  valid_agent_id "$id" || die "invalid id '$id' (allowed: [A-Za-z0-9_-])"
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
