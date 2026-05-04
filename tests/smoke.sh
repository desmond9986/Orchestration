#!/usr/bin/env bash
# Smoke tests for roster, protocol, and tasks libraries.
#
# Runs lib smoke coverage against a temp project dir. Includes isolated tmux
# suites for readiness, layout, and notify delivery behavior.
#
# Usage:
#   tests/smoke.sh                  # run all
#   tests/smoke.sh roster           # a single suite
#   tests/smoke.sh protocol
#   tests/smoke.sh tasks

set -uo pipefail  # deliberately NOT -e; we check each assertion explicitly

: "${ORCHESTRATION_HOME:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export ORCHESTRATION_HOME

PASS=0
FAIL=0

pass() { printf "  \033[32m✓\033[0m %s\n" "$*"; PASS=$((PASS+1)); }
fail() { printf "  \033[31m✗\033[0m %s\n" "$*"; FAIL=$((FAIL+1)); }

assert_eq() { # expected actual description
  if [[ "$1" == "$2" ]]; then pass "$3"
  else fail "$3 (expected='$1' actual='$2')"
  fi
}

assert_contains() { # haystack needle description
  if [[ "$1" == *"$2"* ]]; then pass "$3"
  else fail "$3 (needle='$2' not in: $1)"
  fi
}

assert_not_contains() { # haystack needle description
  if [[ "$1" != *"$2"* ]]; then pass "$3"
  else fail "$3 (unexpected needle='$2' in: $1)"
  fi
}

assert_fails() { # description, command...
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then fail "$desc (expected failure but succeeded)"
  else pass "$desc"
  fi
}

# Writes the new project dir path to global ORCH_PROJECT. Do not call via $()
# — the export needs to land in the caller's shell, not a subshell.
fresh_project() {
  ORCH_PROJECT=$(mktemp -d)
  export ORCH_PROJECT
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init smoke >/dev/null
}

# ── roster ────────────────────────────────────────────────────────────────
test_roster() {
  printf "\n\033[1mroster\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"

  bash "$ORCHESTRATION_HOME/lib/roster.sh" add a1 coder claude "s:0.0" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add a2 coder codex  "s:0.1" \
    --resume-provider codex --resume-id 019de80b-e52e-7682-a818-a17496aa0140 --resume-mode exact >/dev/null

  local out
  out=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role coder | tr '\n' ' ')
  assert_eq "a1 a2 " "$out" "find-role lists both coders"

  assert_eq "s:0.0" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target a1)" \
    "target returns active agent's target"
  assert_eq "019de80b-e52e-7682-a818-a17496aa0140" \
    "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" resume a2 | jq -r '.id')" \
    "resume returns stored chat id"

  bash "$ORCHESTRATION_HOME/lib/roster.sh" set-resume a2 codex 019de80b-e52e-7682-a818-a17496aa0141 --mode exact >/dev/null
  assert_eq "019de80b-e52e-7682-a818-a17496aa0141" \
    "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" resume a2 | jq -r '.id')" \
    "set-resume updates stored chat id"

  bash "$ORCHESTRATION_HOME/lib/roster.sh" remove a1 >/dev/null
  assert_eq "" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target a1)" \
    "target returns empty for removed agent (#3)"
  assert_eq "s:0.0" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target-any a1)" \
    "target-any still resolves removed agent for archival reads"

  assert_fails "resume of removed agent id is rejected" \
    bash "$ORCHESTRATION_HOME/lib/roster.sh" resume a1
  assert_fails "resume of unknown agent id is rejected" \
    bash "$ORCHESTRATION_HOME/lib/roster.sh" resume does-not-exist

  assert_fails "remove of unknown agent id is rejected" \
    bash "$ORCHESTRATION_HOME/lib/roster.sh" remove does-not-exist

  rm -rf "$dir"
}

# ── protocol ─────────────────────────────────────────────────────────────
test_protocol() {
  printf "\n\033[1mprotocol\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add a1 coder claude "s:0.0" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add a2 coder codex  "s:0.1" >/dev/null

  # Sending to an active agent should write JSONL inbox even if tmux delivery fails.
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" send a2 TASK "hello" --from a1 >/dev/null 2>&1 || true
  local line
  line=$(head -1 "$dir/.agents/inbox/a2.jsonl")
  assert_contains "$line" '"from":"a1"' "inbox JSONL has from field"
  assert_contains "$line" '"to":"a2"'   "inbox JSONL has to field"
  assert_contains "$line" '"type":"TASK"' "inbox JSONL has type field"
  assert_contains "$line" '"payload":"hello"' "inbox JSONL has payload"

  # Remove a2 — subsequent sends must fail before writing inbox (#3).
  bash "$ORCHESTRATION_HOME/lib/roster.sh" remove a2 >/dev/null
  local sz_before sz_after
  sz_before=$(wc -l < "$dir/.agents/inbox/a2.jsonl" | tr -d ' ')
  assert_fails "send to removed agent is rejected" \
    bash "$ORCHESTRATION_HOME/lib/protocol.sh" send a2 TASK "orphan" --from a1
  sz_after=$(wc -l < "$dir/.agents/inbox/a2.jsonl" | tr -d ' ')
  assert_eq "$sz_before" "$sz_after" "inbox not appended when target is inactive (#3)"

  # peek-inbox renders readably.
  local peek
  peek=$(bash "$ORCHESTRATION_HOME/lib/protocol.sh" peek-inbox a2)
  assert_contains "$peek" "hello" "peek-inbox renders payload"
  assert_contains "$peek" "[TASK]" "peek-inbox renders type"
  assert_contains "$peek" "FROM: a1" "peek-inbox renders sender"
  assert_contains "$peek" "TO:   a2" "peek-inbox renders recipient"
  local inbox_peek
  inbox_peek=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-inbox" peek a2)
  assert_contains "$inbox_peek" "hello" "orch-inbox peek renders payload"
  local read_out
  read_out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-inbox" check a2)
  assert_contains "$read_out" "FROM: a1" "check-inbox renders sender"
  assert_contains "$read_out" "TO:   a2" "check-inbox renders recipient"
  local arch
  arch=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-inbox" archive a2)
  assert_contains "$arch" "hello" "check-archive renders archived payload"
  assert_contains "$arch" "FROM: a1" "check-archive renders sender"

  rm -rf "$dir"
}

# ── protocol notify via tmux ─────────────────────────────────────────────
# Exercises the real notify path with isolated tmux socket:
# - sender hint is printed
# - notify does not auto-run check-inbox
# - metacharacter ids do not get executed as shell fragments
# - stale roster target is auto-recovered by pane title
# - generated message ids are unique under burst sends
test_protocol_notify_tmux() {
  printf "\n\033[1mprotocol notify (tmux)\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-proto-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_proto_tmux() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }
  trap cleanup_proto_tmux RETURN

  ORCH_PROJECT=$(mktemp -d)
  export ORCH_PROJECT
  local sess="proto-$$"
  tmux new-session -d -s "$sess" -c "$ORCH_PROJECT" -x 120 -y 30
  tmux split-window -h -t "$sess:0.0" -c "$ORCH_PROJECT"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$sess" >/dev/null

  local to_id="rcvr"
  local sender_target="$sess:0.0"
  local rcvr_target="$sess:0.1"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add sender coder claude "$sender_target" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add "$to_id" coder claude "$rcvr_target" >/dev/null
  tmux set-option -p -t "$sender_target" @orch_agent_id sender >/dev/null 2>&1 || true
  tmux set-option -p -t "$rcvr_target" @orch_agent_id "$to_id" >/dev/null 2>&1 || true

  # Notify must not execute whatever text is currently typed in the receiver pane.
  tmux send-keys -t "$rcvr_target" "touch prehint_should_not_run"

  # Notify should queue the message and hint in pane, without auto-reading inbox.
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" send "$to_id" INFO "m1" --from sender >/dev/null 2>&1 || true
  if [[ -f "$ORCH_PROJECT/prehint_should_not_run" ]]; then
    fail "notify must not submit pre-typed receiver input"
  else
    pass "notify does not submit pre-typed receiver input"
  fi
  local tries=0
  local max_tries=60
  local inbox_file
  inbox_file="$ORCH_PROJECT/.agents/inbox/$to_id.jsonl"
  local arch_file
  arch_file="$ORCH_PROJECT/.agents/inbox/$to_id.archive.jsonl"
  while (( tries < max_tries )); do
    local inbox_lines=0
    [[ -f "$inbox_file" ]] && inbox_lines=$(wc -l < "$inbox_file" | tr -d ' ')
    if (( inbox_lines >= 1 )); then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  local inbox_lines=0 arch_lines=0
  [[ -f "$inbox_file" ]] && inbox_lines=$(wc -l < "$inbox_file" | tr -d ' ')
  [[ -f "$arch_file" ]] && arch_lines=$(wc -l < "$arch_file" | tr -d ' ')
  assert_eq "1" "$inbox_lines" "notify keeps message unread by default"
  assert_eq "0" "$arch_lines" "notify does not archive without check-inbox"

  # Wait for the hint text to appear in the pane (lock + sleeps add latency).
  local pane="" sender_pane=""
  tries=0
  while (( tries < max_tries )); do
    pane=$(tmux capture-pane -p -t "$rcvr_target" 2>/dev/null)
    [[ "$pane" == *"check-inbox"* ]] && break
    sleep 0.1
    tries=$((tries + 1))
  done
  sender_pane=$(tmux capture-pane -p -t "$sender_target" 2>/dev/null)
  assert_contains "$pane" "check-inbox" "notify prints check-inbox hint in receiver pane"
  assert_contains "$pane" "from:sender" "notify hint includes sender id"
  if [[ "$sender_pane" == *"check-inbox"* ]]; then
    fail "notify must target receiver pane, not sender pane"
  else
    pass "notify targets receiver pane only"
  fi

  # Metacharacter ids are rejected by whitelist validation.
  local evil_id='evil; touch pwned_marker'
  assert_fails "reject metacharacter agent id" \
    bash "$ORCHESTRATION_HOME/lib/roster.sh" add "$evil_id" coder claude "$rcvr_target"

  # Sender labels are normalized, so shell expansion cannot execute in pane.
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" send "$to_id" INFO "m-from" --from '$(touch pwned_by_from)' >/dev/null 2>&1 || true
  if [[ -f "$ORCH_PROJECT/pwned_by_from" ]]; then
    fail "notify from label must not execute shell expansion"
  else
    pass "notify from label is shell-safe"
  fi

  # Auto-retarget: stale pane target should recover by pane title and deliver.
  local heal_id="heal"
  tmux select-pane -t "$rcvr_target" -T "$heal_id"
  tmux set-option -p -t "$rcvr_target" @orch_agent_id "$heal_id" >/dev/null 2>&1 || true
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add "$heal_id" coder claude "$sess:0.99" >/dev/null
  ORCH_ALLOW_TITLE_RETARGET=1 bash "$ORCHESTRATION_HOME/lib/protocol.sh" send "$heal_id" INFO "m3" --from sender >/dev/null 2>&1 || true
  local healed_target
  healed_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target "$heal_id")
  assert_eq "$rcvr_target" "$healed_target" "stale target auto-retargets by pane title"
  assert_contains "$(tail -n 20 "$ORCH_PROJECT/.agents/log.md")" "RETARGET_" \
    "retarget event logged"

  # Burst send: ids should remain unique.
  local burst_id="burst"
  tmux select-pane -t "$sender_target" -T "$burst_id"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add "$burst_id" coder claude "$sender_target" >/dev/null
  local n=80 i
  for (( i=1; i<=n; i++ )); do
    bash "$ORCHESTRATION_HOME/lib/protocol.sh" send "$burst_id" INFO "b-$i" --from sender >/dev/null 2>&1 || true
  done
  local uniq_count total_count burst_inbox
  burst_inbox="$ORCH_PROJECT/.agents/inbox/$burst_id.jsonl"
  uniq_count=$(jq -r '.id' "$burst_inbox" | sort | uniq | wc -l | tr -d ' ')
  total_count=$(jq -r '.id' "$burst_inbox" | wc -l | tr -d ' ')
  assert_eq "$total_count" "$uniq_count" "burst send generates unique message ids"

  rm -rf "$ORCH_PROJECT"
  trap - RETURN
  cleanup_proto_tmux
}

# ── tasks ────────────────────────────────────────────────────────────────
test_tasks() {
  printf "\n\033[1mtasks\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add c1 coder claude "s:0.0" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add c2 coder codex  "s:0.1" >/dev/null

  bash "$ORCHESTRATION_HOME/lib/tasks.sh" create "A" --id t-a >/dev/null
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" create "B" --id t-b --depends t-a >/dev/null

  # Deps hide t-b from list-available
  local avail
  avail=$(bash "$ORCHESTRATION_HOME/lib/tasks.sh" list-available | tr -s ' ')
  assert_contains "$avail" "t-a" "list-available shows t-a"
  if [[ "$avail" != *"t-b"* ]]; then
    pass "list-available hides dep-blocked t-b"
  else
    fail "list-available must hide t-b"
  fi

  # Atomic claim
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-a c1 >/dev/null
  assert_fails "double-claim rejected" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-a c2
  assert_fails "claim with unmet deps rejected" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-b c2

  # Complete unblocks dependent
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" complete t-a c1 --note "done" >/dev/null 2>&1
  avail=$(bash "$ORCHESTRATION_HOME/lib/tasks.sh" list-available | tr -s ' ')
  assert_contains "$avail" "t-b" "complete unblocks dependent"

  # #2: only owner can block a claimed task
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-b c2 >/dev/null
  assert_fails "non-owner cannot block claimed task (#2)" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" block t-b c1 --reason "pirate"
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" block t-b c2 --reason "api down" >/dev/null 2>&1
  local status
  status=$(jq -r '.tasks[] | select(.id=="t-b") | .status' "$dir/.agents/tasks.json")
  assert_eq "blocked" "$status" "block by owner succeeds"

  # #1: blocked is NOT in list-available
  avail=$(bash "$ORCHESTRATION_HOME/lib/tasks.sh" list-available | tr -s ' ')
  if [[ "$avail" != *"t-b"* ]]; then
    pass "blocked task not in list-available (#1)"
  else
    fail "blocked task must not appear in list-available (#1)"
  fi

  # #1: cannot re-claim blocked directly
  assert_fails "cannot claim a blocked task (#1)" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-b c2

  # #2: cannot block a done task
  assert_fails "cannot block a completed task (#2)" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" block t-a c1 --reason "too late"

  # #2: block on non-existent task fails
  assert_fails "block on missing task id fails (#2)" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" block t-nope c1 --reason "ghost"

  # unblock → pending → claimable
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" unblock t-b c2 --note "resolved" >/dev/null 2>&1
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-b c1 >/dev/null
  status=$(jq -r '.tasks[] | select(.id=="t-b") | .status' "$dir/.agents/tasks.json")
  assert_eq "claimed" "$status" "unblocked task can be re-claimed"

  # Blocked-then-complete bypass: claim → block → complete must NOT transition
  # a blocked task straight to done. The lifecycle is blocked → unblock → done.
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" create "C" --id t-c >/dev/null
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" claim t-c c1 >/dev/null
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" block t-c c1 --reason "api down" >/dev/null 2>&1
  assert_fails "cannot complete a blocked task (blocked→done bypass)" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" complete t-c c1 --note "oops"
  status=$(jq -r '.tasks[] | select(.id=="t-c") | .status' "$dir/.agents/tasks.json")
  assert_eq "blocked" "$status" "blocked task stays blocked after rejected complete"

  # Cannot complete a task that was never claimed.
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" create "D" --id t-d >/dev/null
  assert_fails "cannot complete a pending (never claimed) task" \
    bash "$ORCHESTRATION_HOME/lib/tasks.sh" complete t-d c1

  rm -rf "$dir"
}

# ── concurrency ──────────────────────────────────────────────────────────
test_concurrency() {
  printf "\n\033[1mconcurrency\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"

  # 1. Roster add race: 20 parallel adds must all land (or cleanly fail with
  # "already exists" — none silently dropped due to lost-update).
  local n=20
  for i in $(seq 1 "$n"); do
    bash "$ORCHESTRATION_HOME/lib/roster.sh" add "agent-$i" coder claude "s:0.$i" \
      >/dev/null 2>&1 &
  done
  wait
  local count
  count=$(jq '.agents | length' "$dir/.agents/roster.json")
  assert_eq "$n" "$count" "20 parallel adds all land (no lost-update race)"

  # 2. Concurrent sends during check-inbox: a send arriving mid-read must not
  # be silently truncated. We run many send/read cycles and assert that the
  # sum of (inbox + archive + rendered) lines equals the number of sends.
  fresh_project; dir="$ORCH_PROJECT"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add sender coder claude "s:0.0" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add rcvr   coder claude "s:0.1" >/dev/null

  local sends=50
  (
    for i in $(seq 1 "$sends"); do
      bash "$ORCHESTRATION_HOME/lib/protocol.sh" send rcvr INFO "msg-$i" --from sender \
        >/dev/null 2>&1
    done
  ) &
  local sender_pid=$!
  # Race check-inbox against the sends — spin a few readers concurrently.
  local reads=0
  while kill -0 "$sender_pid" 2>/dev/null; do
    bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox rcvr \
      >>"$dir/reader.out" 2>/dev/null
    reads=$((reads+1))
  done
  wait "$sender_pid"
  # Drain whatever arrived after the last read.
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox rcvr \
    >>"$dir/reader.out" 2>/dev/null

  # Count "msg-N" payloads across rendered output + archive — must equal sends.
  local archived
  archived=$(wc -l < "$dir/.agents/inbox/rcvr.archive.jsonl" 2>/dev/null | tr -d ' ')
  local inbox_left=0
  if [[ -f "$dir/.agents/inbox/rcvr.jsonl" ]]; then
    inbox_left=$(wc -l < "$dir/.agents/inbox/rcvr.jsonl" | tr -d ' ')
  fi
  # Rendered and archived contain the same messages — use archive + any
  # remaining inbox as the durable count.
  local total=$((archived + inbox_left))
  assert_eq "$sends" "$total" "no messages lost across concurrent send + check-inbox"

  rm -rf "$dir"
}

# ── spawn layout ─────────────────────────────────────────────────────────
# Tests the pane-assignment logic in spawn-agent.sh.
# Uses an isolated tmux server so it never touches live sessions.
test_spawn_layout() {
  printf "\n\033[1mspawn layout\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  # Source helpers so roster_file() and friends are available.
  set +e
  source "$ORCHESTRATION_HOME/lib/common.sh"
  source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
  set +e

  # Wrap tmux through an isolated server so test panes never appear live.
  # Resolve the real tmux binary path before overriding PATH.
  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-layout-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_layout() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  local sess="layout-$$"

  # ── split layout (>4 agents): each agent must get a unique pane ──────
  # Don't use fresh_project — it inits a 'smoke' session which would collide.
  ORCH_PROJECT=$(mktemp -d)
  export ORCH_PROJECT
  tmux new-session -d -s "$sess" -c "$ORCH_PROJECT" -x 220 -y 50
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$sess" >/dev/null

  export ORCH_TOTAL_AGENTS=6
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator none --session "$sess"
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect    architect    none --session "$sess"
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1      coder        none --session "$sess"
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-2      coder        none --session "$sess"

  local targets distinct
  targets=$(jq -r '.agents[].target' "$(roster_file)")
  distinct=$(echo "$targets" | sort -u | wc -l | tr -d ' ')
  assert_eq "4" "$distinct" "split layout: 4 agents → 4 distinct panes"

  local orch_target arch_target
  orch_target=$(jq -r '.agents[] | select(.id=="orchestrator") | .target' "$(roster_file)")
  arch_target=$(jq -r '.agents[] | select(.id=="architect")    | .target' "$(roster_file)")
  assert_contains "$orch_target" ":0." "split layout: orchestrator lands in window 0"
  assert_contains "$arch_target" ":1." "split layout: non-orchestrator lands in window 1"

  # If the base orchestrator pane is already occupied by a non-shell process,
  # spawn must allocate a fresh pane instead of typing launch commands into it.
  tmux kill-session -t "$sess" 2>/dev/null || true
  ORCH_PROJECT=$(mktemp -d)
  export ORCH_PROJECT
  tmux new-session -d -s "$sess" -c "$ORCH_PROJECT" -x 220 -y 50
  tmux send-keys -t "$sess:0.0" "clear && tail -f /dev/null" Enter
  local tries=0
  while (( tries < 30 )); do
    if [[ "$(tmux display-message -p -t "$sess:0.0" '#{pane_current_command}' 2>/dev/null)" == "tail" ]]; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$sess" >/dev/null
  export ORCH_TOTAL_AGENTS=6
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator none --session "$sess"
  orch_target=$(jq -r '.agents[] | select(.id=="orchestrator") | .target' "$(roster_file)")
  if [[ "$orch_target" != "$sess:0.0" ]]; then
    pass "split layout: orchestrator avoids reusing non-shell pane 0.0"
  else
    fail "split layout: orchestrator must not reuse non-shell pane 0.0"
  fi

  unset ORCH_TOTAL_AGENTS
  rm -rf "$ORCH_PROJECT"
  tmux kill-session -t "$sess" 2>/dev/null || true

  # ── set -u safety: skip-permissions var unset must not crash ─────────
  local rc=0
  bash -c '
    set -euo pipefail
    source "$ORCHESTRATION_HOME/lib/common.sh"
    # Simulate launch_cli_cmd with no ORCH_SKIP_PERMISSIONS_coder exported.
    unset ORCH_SKIP_PERMISSIONS_coder 2>/dev/null || true
    ROLE=coder
    role_var="ORCH_SKIP_PERMISSIONS_${ROLE}"
    skip="${!role_var:-}"
    skip="${skip:-${ORCH_SKIP_PERMISSIONS:-0}}"
    echo "$skip"
  ' >/dev/null || rc=$?
  assert_eq "0" "$rc" "skip-permissions: unset per-role var does not crash under set -u"

  # Cross-project safety: reusing the same tmux session name across different
  # project roots must fail fast (prevents messages leaking between projects).
  local proj_a proj_b rc2=0
  proj_a=$(mktemp -d)
  proj_b=$(mktemp -d)
  export ORCH_PROJECT="$proj_a"
  tmux new-session -d -s collide -c "$proj_a"
  bash -c '
    set -euo pipefail
    export ORCHESTRATION_HOME="'"$ORCHESTRATION_HOME"'"
    export ORCH_PROJECT="'"$proj_b"'"
    source "$ORCHESTRATION_HOME/lib/common.sh"
    source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
    init_session collide >/dev/null
  ' >/dev/null 2>&1 || rc2=$?
  if (( rc2 != 0 )); then
    pass "cross-project session name collision is rejected"
  else
    fail "cross-project session name collision must be rejected"
  fi
  tmux kill-session -t collide 2>/dev/null || true
  rm -rf "$proj_a" "$proj_b"

  cleanup_layout
}

test_present_session() {
  printf "\n\033[1mpresent session\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  set +e
  source "$ORCHESTRATION_HOME/lib/common.sh"
  source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
  set +e

  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-present-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nif [[ "$1" == "-CC" ]]; then echo "TMUX_CC $*"; exit 0; fi\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_present() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  local proj
  proj=$(mktemp -d)
  export ORCH_PROJECT="$proj"
  tmux new-session -d -s alpha -c "$proj"
  tmux new-session -d -s beta  -c "$proj"

  local rc out
  rc=0
  out=$(TMUX=1 bash -c '
    export ORCHESTRATION_HOME="'"$ORCHESTRATION_HOME"'"
    export ORCH_PROJECT="'"$proj"'"
    source "$ORCHESTRATION_HOME/lib/common.sh"
    source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
    present_session beta
  ' 2>&1) || rc=$?
  assert_eq "0" "$rc" "present_session inside tmux exits cleanly"
  assert_contains "$out" "switch with: tmux switch-client -t 'beta'" \
    "present_session inside tmux prints manual switch guidance by default"

  rc=0
  out=$(TMUX= bash -c '
    export ORCHESTRATION_HOME="'"$ORCHESTRATION_HOME"'"
    export ORCH_PROJECT="'"$proj"'"
    source "$ORCHESTRATION_HOME/lib/common.sh"
    source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
    present_session beta
  ' 2>&1) || rc=$?
  assert_eq "0" "$rc" "present_session outside tmux exits cleanly by default"
  assert_contains "$out" "attach with: tmux attach-session -t 'beta'" \
    "present_session outside tmux prints attach guidance by default"

  rc=0
  out=$(TMUX= ORCH_AUTO_ATTACH_ITERM_CC=1 bash -c '
    export ORCHESTRATION_HOME="'"$ORCHESTRATION_HOME"'"
    export ORCH_PROJECT="'"$proj"'"
    source "$ORCHESTRATION_HOME/lib/common.sh"
    source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
    present_session beta
  ' 2>&1) || rc=$?
  assert_eq "0" "$rc" "present_session supports iTerm control-mode attach outside tmux"
  assert_contains "$out" "TMUX_CC -CC attach-session -t beta" \
    "present_session runs tmux -CC attach-session for iTerm control mode"

  rc=0
  out=$(TMUX=1 ORCH_AUTO_ATTACH_ITERM_CC=1 bash -c '
    export ORCHESTRATION_HOME="'"$ORCHESTRATION_HOME"'"
    export ORCH_PROJECT="'"$proj"'"
    source "$ORCHESTRATION_HOME/lib/common.sh"
    source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
    present_session beta
  ' 2>&1) || rc=$?
  assert_eq "0" "$rc" "present_session does not run iTerm control mode inside tmux"
  assert_contains "$out" "run outside tmux: tmux -CC attach-session -t 'beta'" \
    "present_session prints safe iTerm control-mode command inside tmux"

  local proj_flags
  proj_flags=$(mktemp -d)
  rc=0
  out=$(cd "$proj_flags" && bash "$ORCHESTRATION_HOME/bin/orchestrate" --iterm-cc --no-attach freeform 2>&1) || rc=$?
  assert_eq "0" "$rc" "orchestrate parses --iterm-cc --no-attach"
  assert_not_contains "$out" "TMUX_CC" "orchestrate --no-attach cancels prior --iterm-cc"
  assert_contains "$out" "iTerm control mode: tmux -CC attach-session -t 'freeform'" \
    "orchestrate --no-attach prints iTerm control-mode guidance"
  tmux kill-session -t freeform 2>/dev/null || true
  rm -rf "$proj_flags"

  proj_flags=$(mktemp -d)
  rc=0
  out=$(cd "$proj_flags" && bash "$ORCHESTRATION_HOME/bin/orchestrate" --no-attach -CC freeform 2>&1) || rc=$?
  assert_eq "0" "$rc" "orchestrate parses --no-attach -CC"
  assert_contains "$out" "TMUX_CC -CC attach-session -t freeform" \
    "orchestrate -CC wins when it is the last presentation flag"
  tmux kill-session -t freeform 2>/dev/null || true
  rm -rf "$proj_flags"

  tmux kill-session -t alpha 2>/dev/null || true
  tmux kill-session -t beta 2>/dev/null || true
  rm -rf "$proj"
  cleanup_present
}

test_pattern_defaults() {
  printf "\n\033[1mpattern defaults\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-patterns-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_patterns() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  local proj hats
  proj=$(mktemp -d)
  ORCH_PROJECT="$proj" ORCH_MODEL_coder=none bash "$ORCHESTRATION_HOME/patterns/lonely-coder.sh" >/dev/null
  hats=$(jq -r '.agents[] | select(.id=="coder-1") | .hats | join(",")' "$proj/.agents/roster.json")
  assert_eq "qa,reviewer" "$hats" "lonely-coder does not include spawner hat by default"
  tmux kill-session -t lonely-coder 2>/dev/null || true
  rm -rf "$proj"

  proj=$(mktemp -d)
  ORCH_PROJECT="$proj" ORCH_MODEL_orchestrator=none ORCH_MODEL_coder=none \
    bash "$ORCHESTRATION_HOME/patterns/lean.sh" >/dev/null
  hats=$(jq -r '.agents[] | select(.id=="coder-1") | .hats | join(",")' "$proj/.agents/roster.json")
  assert_eq "" "$hats" "lean coder-1 does not include spawner hat by default"
  tmux kill-session -t lean 2>/dev/null || true
  rm -rf "$proj"

  proj=$(mktemp -d)
  ORCH_PROJECT="$proj" ORCH_ENABLE_SPAWNER_HATS=1 ORCH_MODEL_orchestrator=none ORCH_MODEL_coder=none \
    bash "$ORCHESTRATION_HOME/patterns/lean.sh" >/dev/null
  hats=$(jq -r '.agents[] | select(.id=="coder-1") | .hats | join(",")' "$proj/.agents/roster.json")
  assert_eq "spawner" "$hats" "lean coder-1 includes spawner hat when explicitly enabled"
  tmux kill-session -t lean 2>/dev/null || true
  rm -rf "$proj"

  cleanup_patterns
}

test_tmux_send_helpers() {
  printf "\n\033[1mtmux send helpers\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  local sock="orch-send-$$"
  local sess="send-test"
  set +e
  source "$ORCHESTRATION_HOME/lib/common.sh"
  source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
  set +e

  tmux() { command tmux -L "$sock" "$@"; }
  cleanup_send() {
    unset -f tmux 2>/dev/null || true
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  export ORCH_PROJECT
  ORCH_PROJECT=$(mktemp -d)
  ensure_agents_dir

  tmux new-session -d -s "$sess" -c "$ORCH_PROJECT" -x 80 -y 24
  local target="$sess:0.0"
  local marker_file="$ORCH_PROJECT/send-line-marker"

  send_line "$target" "printf x >> '$marker_file'"
  for _ in {1..30}; do
    [[ "$(cat "$marker_file" 2>/dev/null || true)" == "x" ]] && break
    sleep 0.1
  done
  assert_eq "x" "$(cat "$marker_file" 2>/dev/null)" \
    "send_line executes shell command exactly once"

  local long_path="$ORCH_PROJECT/.agents/prompts/path with spaces/agent.md"
  send_bootstrap_message "$target" \
    "BOOTSTRAP agent=agent-one context_file=$long_path loaded. Follow your Getting Started steps." \
    2 100 >/dev/null 2>&1 || true
  assert_contains "$(tail -5 "$(log_file)")" "BOOTSTRAP ok target=$target" \
    "bootstrap verification uses short marker and does not time out on wrapped paths"

  rm -rf "$ORCH_PROJECT"
  cleanup_send
}

# ── orch-tui ─────────────────────────────────────────────────────────────
test_tui() {
  printf "\n\033[1morch-tui\033[0m\n"

  local dir out bin_dir orig_path
  dir=$(mktemp -d)
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-tui" --snapshot 2>&1)
  assert_contains "$out" "session: none" "orch-tui snapshot handles project without session"
  assert_contains "$out" "no active .agents/roster.json" "orch-tui snapshot explains missing roster"

  out=$(ORCHESTRATION_HOME="$ORCHESTRATION_HOME" ORCH_PROJECT="$dir" PYTHONPATH="$ORCHESTRATION_HOME" python3 - <<'PY'
from lib.orch_tui import App

app = object.__new__(App)
app.section_index = 0
app.row_index = 0
app.filters = {}

state = app.state()
rows = app.current_rows(state)
print("has_session:" + str(state["has_session"]))
print("has_roster:" + str(state["has_roster"]))
print("first_run:" + str(state["first_run"]))
print("rows:" + str(len(rows)))
for row in rows:
    print("row:" + str(row.get("title", "")) + "|" + str(row.get("value", "")))
for line in app.inspector_lines(state, rows, 120):
    print(line)
app.output = []
app.message = ""
app.restore_panes()
print("restore_guard:" + app.message)
PY
)
  assert_contains "$out" "row:Session bootstrap|No active session." \
    "orch-tui session rows include bootstrap guidance when no roster"
  assert_contains "$out" "first_run:True" \
    "orch-tui detects first-run projects with no roster"
  assert_contains "$out" "Pick this pattern and run Start selected to bootstrap a new session." \
    "orch-tui session inspector suggests start selected first-run"
  assert_contains "$out" "Restore panes is only available when .agents/roster.json exists." \
    "orch-tui session inspector explains restore limitation"
  assert_contains "$out" "restore_guard:restore unavailable: no .agents/roster.json" \
    "orch-tui restore action is guarded when no roster exists"

  rm -rf "$dir"

  dir=$(mktemp -d)
  export ORCH_PROJECT="$dir"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init tui-smoke >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder none tui-smoke:0.0 >/dev/null
  mkdir -p "$dir/.agents/inbox"
  printf '{"id":"m1","read":false,"payload":"hello"}\n' > "$dir/.agents/inbox/coder-1.jsonl"
  printf '{"id":"old","read":false,"payload":"archived"}\n' > "$dir/.agents/inbox/coder-1.archive.jsonl"
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-tui" --snapshot 2>&1)
  assert_contains "$out" "session: tui-smoke" "orch-tui snapshot shows session name"
  assert_contains "$out" "active agents: 1" "orch-tui snapshot shows active agent count"
  assert_contains "$out" "unread inbox messages: 1" "orch-tui snapshot shows unread inbox count"
  assert_contains "$out" "coder-1" "orch-tui snapshot includes roster agent"

  out=$(ORCHESTRATION_HOME="$ORCHESTRATION_HOME" ORCH_PROJECT="$dir" PYTHONPATH="$ORCHESTRATION_HOME" python3 - <<'PY'
from lib.orch_tui import App

app = object.__new__(App)
app.section_index = 1
app.row_index = 0
app.filters = {}
state = app.state()
rows = app.current_rows(state)
print("unread_total:" + str(state["unread"]))
print("agent_unread:" + str(state["agent_unread"].get("coder-1", 0)))
if rows:
    print("agent_row:" + str(rows[0].get("title", "") + "|" + str(rows[0].get("value", ""))))
    print("agent_status:" + str(rows[0].get("status", "")))
for line in app.inspector_lines(state, rows, 120):
    print(line)
PY
)
  assert_contains "$out" "agent_unread:1" "orch-tui computes per-agent unread totals"
  assert_contains "$out" "agent_row:coder-1|coder | none | unread 1 | tui-smoke:0.0" \
    "orch-tui agents row includes per-agent unread count"
  assert_contains "$out" "agent_status:warn" "orch-tui agents with unread messages are highlighted"
  assert_contains "$out" "unread: 1" "orch-tui agent inspector shows per-agent unread count"
  rm -rf "$dir"

  out=$(bash "$ORCHESTRATION_HOME/bin/orch-tui" --help 2>&1)
  assert_contains "$out" "thin control surface" "orch-tui help states wrapper design rule"

  out=$(ORCHESTRATION_HOME="$ORCHESTRATION_HOME" PYTHONPATH="$ORCHESTRATION_HOME" python3 - <<'PY'
import lib.orch_tui as tui
from lib.orch_tui import Action, App, ClickZone
app = object.__new__(App)
fields = app.launch_form_fields("lean")
fields[0].value = "review-loop"
refreshed, selected = app.refresh_launch_form_fields(fields, 0)
print("selected", selected)
print("keys", " ".join(field.key for field in refreshed))

clicked = {"count": 0}
def cb():
    clicked["count"] += 1

zone = ClickZone(2, 4, 3, 10, cb, "row")
print("contains_inside:" + str(zone.contains(2, 4)))
print("contains_outside:" + str(zone.contains(4, 4)))
app.click_zones = [zone]
app.message = ""
original_getmouse = tui.curses.getmouse
tui.curses.getmouse = lambda: (0, 6, 3, 0, 0)
app.handle_mouse()
print("motion_only_clicked:" + str(clicked["count"]))
tui.curses.getmouse = lambda: (0, 6, 3, 0, tui.curses.BUTTON1_PRESSED)
app.handle_mouse()
print("pressed_clicked:" + str(clicked["count"]))
tui.curses.getmouse = lambda: (0, 6, 3, 0, tui.curses.BUTTON1_RELEASED)
app.handle_mouse()
print("released_clicked:" + str(clicked["count"]))
tui.curses.getmouse = lambda: (0, 6, 3, 0, tui.curses.BUTTON1_CLICKED)
app.handle_mouse()
tui.curses.getmouse = original_getmouse
print("mouse_clicked:" + str(clicked["count"]))
print("mouse_message:" + app.message)
print("button_label:" + app.action_button_label(Action("Run", lambda _app: None, risk="mutating"), ">"))

class FakeScreen:
    def __init__(self):
        self.lines = []
    def getmaxyx(self):
        return (42, 150)
    def addstr(self, y, x, value, attr=0):
        self.lines.append(str(value))
    def move(self, y, x):
        pass

fake = FakeScreen()
app.stdscr = fake
original_color_pair = tui.curses.color_pair
tui.curses.color_pair = lambda _idx: 0
app.draw_form_overlay(
    42,
    150,
    "Unit Form",
    [tui.FormField("name", "Name", "", "required", True)],
    0,
    "Missing required: Name",
    lambda values: ["$ unit-preview"],
)
tui.curses.color_pair = original_color_pair
print("form_footer:" + str(any("[Enter Edit/Save] [s Submit]" in line for line in fake.lines)))
print("form_required:" + str(any("REQUIRED" in line for line in fake.lines)))
PY
)
  assert_contains "$out" "model_reviewer" \
    "orch-tui launch form refreshes role fields after pattern edit"
  assert_not_contains "$out" "model_orchestrator" \
    "orch-tui launch form removes stale role fields after pattern edit"
  assert_contains "$out" "contains_inside:True" \
    "orch-tui click zone includes its bounds"
  assert_contains "$out" "contains_outside:False" \
    "orch-tui click zone excludes outside coordinates"
  assert_contains "$out" "motion_only_clicked:0" \
    "orch-tui mouse movement does not run click callbacks"
  assert_contains "$out" "pressed_clicked:0" \
    "orch-tui mouse press does not run click callbacks before release"
  assert_contains "$out" "released_clicked:0" \
    "orch-tui mouse release does not run click callbacks without click event"
  assert_contains "$out" "mouse_clicked:1" \
    "orch-tui mouse handler dispatches click zones"
  assert_contains "$out" "mouse_message:clicked row" \
    "orch-tui mouse handler records clicked target"
  assert_contains "$out" "button_label:[> + Run]" \
    "orch-tui action buttons expose risk and selection markers"
  assert_contains "$out" "form_footer:True" \
    "orch-tui form overlay renders fixed controls footer"
  assert_contains "$out" "form_required:True" \
    "orch-tui form overlay marks empty required fields"

  if ! command -v tmux >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped full-screen interactive checks (tmux/python3 missing)\n"
    return 0
  fi

  local real_tmux sock sess target
  real_tmux=$(command -v tmux)
  sock="orch-tui-$$"
  tmux() { command "$real_tmux" -L "$sock" "$@"; }
  cleanup_tui_tmux() {
    unset -f tmux 2>/dev/null || true
    command "$real_tmux" -L "$sock" kill-server 2>/dev/null || true
  }
  local tui_key_delay=0.2
  local tui_wait_delay=0.1
  local tui_wait_tries=30
  tui_wait_for_file() {
    local file="$1" tries="${2:-$tui_wait_tries}" delay="${3:-$tui_wait_delay}"
    local attempt=0
    while (( attempt < tries )); do
      if [[ -f "$file" ]]; then
        return 0
      fi
      sleep "$delay"
      attempt=$((attempt + 1))
    done
    return 1
  }
  tui_send_keys() {
    local target=$1
    shift
    local key
    for key in "$@"; do
      tmux send-keys -t "$target" "$key"
      sleep "$tui_key_delay"
    done
  }

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  orig_path="$PATH"
  cat > "$bin_dir/orchestrate" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
env | grep '^ORCH_MODEL_' | sort >> "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orchestrate"
  sess="tui-dispatch-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/args.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" / "swarm" Enter l Enter j j Enter "*" Enter s
  tui_wait_for_file "$dir/args.out" || fail "orch-tui wait for args output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui wait for tui exit status"
  assert_contains "$(cat "$dir/args.out" 2>/dev/null || true)" "[--yolo]" \
    "orch-tui selected pattern start uses non-interactive launch flags"
  assert_contains "$(cat "$dir/args.out" 2>/dev/null || true)" "[swarm]" \
    "orch-tui full-screen session starts selected pattern"
  assert_contains "$(cat "$dir/args.out" 2>/dev/null || true)" "[*]" \
    "orch-tui extra args do not glob-expand"
  assert_contains "$(cat "$dir/args.out" 2>/dev/null || true)" "ORCH_MODEL_coder=codex" \
    "orch-tui pattern launch defaults model override to codex"
  assert_contains "$(cat "$dir/args.out" 2>/dev/null || true)" "ORCH_MODEL_orchestrator=codex" \
    "orch-tui pattern launch applies model override to all pattern roles"
  assert_contains "$(cat "$dir/exit.out" 2>/dev/null || true)" "exit:0" \
    "orch-tui full-screen session exits cleanly"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orchestrate" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orchestrate"
  sess="tui-first-run-banner-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -x 150 -y 42 -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/banner.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tmux capture-pane -p -t "$target" > "$dir/banner.capture"
  assert_contains "$(cat "$dir/banner.capture" 2>/dev/null || true)" "Start Here" \
    "orch-tui first-run screen renders Start Here banner on tall terminals"
  assert_contains "$(cat "$dir/banner.capture" 2>/dev/null || true)" "Quick actions:" \
    "orch-tui first-run banner renders quick actions"
  assert_contains "$(cat "$dir/banner.capture" 2>/dev/null || true)" "Actions (click):" \
    "orch-tui action bar labels clickable controls"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui first-run banner test waits for tui exit"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-preflight" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'preflight:%s\n' "$*" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-preflight"
  sess="tui-health-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/preflight.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 5 Enter
  tui_wait_for_file "$dir/preflight.out" || fail "orch-tui health test waits for preflight output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui health test waits for tui exit status"
  assert_contains "$(cat "$dir/preflight.out" 2>/dev/null || true)" "preflight:" \
    "orch-tui full-screen health preflight dispatches existing command"
  assert_contains "$(cat "$dir/exit.out" 2>/dev/null || true)" "exit:0" \
    "orch-tui full-screen health exits cleanly"
  rm -rf "$dir"
  rm -rf "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/add-agent" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/add-agent"
  sess="tui-add-agent-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/add.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 2 Enter j Enter C-u "claude" Enter s
  tui_wait_for_file "$dir/add.out" || fail "orch-tui add-agent test waits for command output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui add-agent test waits for tui exit status"
  assert_contains "$(cat "$dir/add.out" 2>/dev/null || true)" "[coder]" \
    "orch-tui add agent form submits default role"
  assert_contains "$(cat "$dir/add.out" 2>/dev/null || true)" "[claude]" \
    "orch-tui add agent form submits edited model field"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-send" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-send"
  mkdir -p "$dir/.agents"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-send","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  sess="tui-send-message-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/send.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 3 Enter j j Enter "hello from tui" Enter s
  tui_wait_for_file "$dir/send.out" || fail "orch-tui send test waits for command output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui send test waits for tui exit status"
  assert_contains "$(cat "$dir/send.out" 2>/dev/null || true)" "[--type]" \
    "orch-tui send form dispatches command with type flag"
  assert_contains "$(cat "$dir/send.out" 2>/dev/null || true)" "[coder-1]" \
    "orch-tui send form defaults recipient to selected agent id"
  assert_contains "$(cat "$dir/send.out" 2>/dev/null || true)" "[hello from tui]" \
    "orch-tui send form dispatches typed payload"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-send" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-send"
  mkdir -p "$dir/.agents"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-nudge","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  sess="tui-nudge-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/nudge.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 2 l Enter s
  tui_wait_for_file "$dir/nudge.out" || fail "orch-tui nudge test waits for command output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui nudge test waits for tui exit status"
  assert_contains "$(cat "$dir/nudge.out" 2>/dev/null || true)" "[--type]" \
    "orch-tui nudge form dispatches command"
  assert_contains "$(cat "$dir/nudge.out" 2>/dev/null || true)" "[coder-1]" \
    "orch-tui nudge form defaults to selected agent"
  assert_contains "$(cat "$dir/nudge.out" 2>/dev/null || true)" "check your inbox now" \
    "orch-tui nudge form uses default reminder message"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-send" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-send"
  mkdir -p "$dir/.agents/inbox"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-reply","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  printf '{"id":"m1","read":false,"from":"coder-2","type":"INFO","payload":"hello"}\n' > "$dir/.agents/inbox/coder-1.jsonl"
  sess="tui-reply-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/reply.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 3 l Enter j j Enter "ack via tui" Enter s
  tui_wait_for_file "$dir/reply.out" || fail "orch-tui reply test waits for command output"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui reply test waits for tui exit status"
  assert_contains "$(cat "$dir/reply.out" 2>/dev/null || true)" "[--type]" \
    "orch-tui reply form dispatches command"
  assert_contains "$(cat "$dir/reply.out" 2>/dev/null || true)" "[coder-2]" \
    "orch-tui reply form defaults target from selected message"
  assert_contains "$(cat "$dir/reply.out" 2>/dev/null || true)" "[ack via tui]" \
    "orch-tui reply form dispatches typed payload"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-preflight" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'preflight:%s\n' "$*" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-preflight"
  sess="tui-palette-cancel-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/preflight.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" : "preflight" Enter q q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui action picker cancel waits for tui exit"
  assert_eq "" "$(cat "$dir/preflight.out" 2>/dev/null || true)" \
    "orch-tui action picker does not auto-run fuzzy match"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-preflight" <<'EOF_STUB'
#!/usr/bin/env bash
printf 'preflight:%s\n' "$*" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-preflight"
  sess="tui-palette-run-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/preflight.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" : "preflight" Enter Enter
  sleep 0.5
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/preflight.out" || fail "orch-tui action picker run waits for preflight output"
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui action picker run waits for tui exit"
  assert_contains "$(cat "$dir/preflight.out" 2>/dev/null || true)" "preflight:" \
    "orch-tui action picker dispatches selected action"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  cat > "$bin_dir/orch-preflight" <<'EOF_STUB'
#!/usr/bin/env bash
trap 'printf "terminated\n" > "$ORCH_TUI_CANCEL_OUT"; exit 143' TERM
printf 'started\n' > "$ORCH_TUI_STUB_OUT"
while :; do sleep 0.1 & wait $!; done
EOF_STUB
  chmod +x "$bin_dir/orch-preflight"
  sess="tui-cancel-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/preflight.out' ORCH_TUI_CANCEL_OUT='$dir/cancel.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 5 Enter
  tui_wait_for_file "$dir/preflight.out" || fail "orch-tui long-running command starts"
  tui_send_keys "$target" x
  tui_wait_for_file "$dir/cancel.out" || fail "orch-tui long-running command cancellation marker"
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui long-running command waits for tui exit"
  assert_contains "$(cat "$dir/preflight.out" 2>/dev/null || true)" "started" \
    "orch-tui starts long-running command in background"
  assert_contains "$(cat "$dir/cancel.out" 2>/dev/null || true)" "terminated" \
    "orch-tui x cancels running command"
  assert_contains "$(cat "$dir/exit.out" 2>/dev/null || true)" "exit:0" \
    "orch-tui exits after cancelling running command"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  mkdir -p "$dir/.agents/inbox"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-tasks","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  cat > "$dir/.agents/tasks.json" <<EOF_TASKS
{"tasks":[{"id":"t-1","title":"Build task tab","status":"claimed","owner":"coder-1","depends_on":[],"note":"render inspector"}]}
EOF_TASKS
  sess="tui-tasks-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 4
  sleep 0.5
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui task tab renders without crashing"
  assert_contains "$(cat "$dir/exit.out" 2>/dev/null || true)" "exit:0" \
    "orch-tui task tab renders without crashing"
  rm -rf "$dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  mkdir -p "$dir/.agents/inbox"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-task-action","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  cat > "$dir/.agents/tasks.json" <<EOF_TASKS
{"tasks":[{"id":"t-1","title":"Inspect selected task","status":"pending","owner":null,"depends_on":[]}]}
EOF_TASKS
  cat > "$bin_dir/orch-task" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-task"
  sess="tui-task-action-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/task.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 4 l Enter Enter
  sleep 0.5
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui task action exits"
  assert_contains "$(cat "$dir/task.out" 2>/dev/null || true)" "[show]" \
    "orch-tui task action runs orch-task show"
  assert_contains "$(cat "$dir/task.out" 2>/dev/null || true)" "[t-1]" \
    "orch-tui task action defaults to selected task"
  assert_contains "$(cat "$dir/exit.out" 2>/dev/null || true)" "exit:0" \
    "orch-tui selected task action exits cleanly"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  mkdir -p "$dir/.agents/inbox"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-task-owner","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"},{"id":"coder-2","role":"coder","model":"codex","target":"tui:0.1","status":"active"}]}
EOF_ROSTER
  cat > "$dir/.agents/tasks.json" <<EOF_TASKS
{"tasks":[{"id":"t-2","title":"Owned task","status":"claimed","owner":"coder-2","depends_on":[]}]}
EOF_TASKS
  cat > "$bin_dir/orch-task" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-task"
  sess="tui-task-owner-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/owner.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 4 l l l Enter s
  sleep 0.5
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui task owner action exits"
  assert_contains "$(cat "$dir/owner.out" 2>/dev/null || true)" "[complete]" \
    "orch-tui complete action dispatches"
  assert_contains "$(cat "$dir/owner.out" 2>/dev/null || true)" "[coder-2]" \
    "orch-tui task owner action defaults to selected task owner"
  rm -rf "$dir" "$bin_dir"

  dir=$(mktemp -d)
  bin_dir=$(mktemp -d)
  mkdir -p "$dir/.agents/inbox"
  cat > "$dir/.agents/roster.json" <<EOF_ROSTER
{"session":"tui-inbox","agents":[{"id":"coder-1","role":"coder","model":"codex","target":"tui:0.0","status":"active"}]}
EOF_ROSTER
  cat > "$dir/.agents/tasks.json" <<EOF_TASKS
{"tasks":[]}
EOF_TASKS
  cat > "$bin_dir/orch-inbox" <<'EOF_STUB'
#!/usr/bin/env bash
printf '[%s]\n' "$@" > "$ORCH_TUI_STUB_OUT"
EOF_STUB
  chmod +x "$bin_dir/orch-inbox"
  sess="tui-inbox-$$"
  target="$sess:0.0"
  tmux new-session -d -s "$sess" -c "$dir" \
    "ORCHESTRATION_HOME='$ORCHESTRATION_HOME' ORCH_TUI_BIN_HOME='$bin_dir' ORCH_TUI_STUB_OUT='$dir/inbox.out' '$ORCHESTRATION_HOME/bin/orch-tui'; printf 'exit:%s\n' \"\$?\" > '$dir/exit.out'"
  sleep 0.5
  tui_send_keys "$target" 2 l l l Enter Enter Enter
  sleep 0.5
  tui_send_keys "$target" q
  tui_wait_for_file "$dir/exit.out" || fail "orch-tui inbox action exits"
  assert_eq "" "$(cat "$dir/inbox.out" 2>/dev/null || true)" \
    "orch-tui mark-read requires explicit confirmation"
  rm -rf "$dir" "$bin_dir"
  export PATH="$orig_path"
  cleanup_tui_tmux
}

# ── tmux readiness poll ──────────────────────────────────────────────────
# Skips if tmux is unavailable. Uses an isolated tmux server via -L so it
# doesn't touch any live session.
test_tmux_ready() {
  printf "\n\033[1mtmux readiness\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  local sock="orch-smoke-$$"
  local sess="ready-test"
  # Source libs. common.sh enables set -e; wrap assertions accordingly.
  # shellcheck source=../lib/tmux-helpers.sh
  set +e
  source "$ORCHESTRATION_HOME/lib/common.sh"
  source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"
  set +e

  # Redirect tmux client calls through the isolated socket.
  tmux() { command tmux -L "$sock" "$@"; }
  cleanup_tmux() {
    unset -f tmux 2>/dev/null || true
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  tmux new-session -d -s "$sess" -x 80 -y 24
  local target="$sess:0.0"
  local rc

  # log_line writes to .agents/log.md under project_root — give it a scratch home.
  export ORCH_PROJECT
  ORCH_PROJECT=$(mktemp -d)
  ensure_agents_dir

  # Case 1: pane stays at the shell — readiness should time out fast.
  rc=0
  ORCH_CLI_READY_MAX=1 ORCH_CLI_READY_POLL=100 ORCH_CLI_READY_STABLE=2 \
    wait_for_cli_ready "$target" || rc=$?
  assert_eq "1" "$rc" "times out when pane stays at the shell"
  assert_contains "$(tail -1 "$(log_file)")" "CLI_READY mode=timeout" \
    "logs CLI_READY mode=timeout on hard-cap"

  # Case 2: launch an idle, non-shell command (tail -f /dev/null). It prints
  # nothing, so the output hash stabilises immediately → function returns 0.
  tmux send-keys -t "$target" "clear && tail -f /dev/null" Enter
  rc=0
  ORCH_CLI_READY_MAX=5 ORCH_CLI_READY_POLL=100 ORCH_CLI_READY_STABLE=2 \
    wait_for_cli_ready "$target" || rc=$?
  assert_eq "0" "$rc" "detects readiness when foreground cmd is not a shell and output is stable"
  assert_contains "$(tail -1 "$(log_file)")" "CLI_READY mode=stable" \
    "logs CLI_READY mode=stable on success"

  rm -rf "$ORCH_PROJECT"
  cleanup_tmux
}

# ── end-session ──────────────────────────────────────────────────────────
test_end_session() {
  printf "\n\033[1mend-session\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add e1 coder claude "s:0.0" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/tasks.sh" create "work" --id t-e >/dev/null
  bash "$ORCHESTRATION_HOME/lib/protocol.sh" send e1 INFO "hello" --from e1 \
    >/dev/null 2>&1 || true

  # --keep-tmux must leave the live control plane intact.
  bash "$ORCHESTRATION_HOME/bin/end-session" --keep-tmux >/dev/null 2>&1

  if [[ -f "$dir/.agents/roster.json" ]]; then
    pass "--keep-tmux preserves roster.json"
  else
    fail "--keep-tmux must not remove roster.json"
  fi

  if [[ -d "$dir/.agents/inbox" ]]; then
    pass "--keep-tmux preserves inbox dir"
  else
    fail "--keep-tmux must not remove inbox dir"
  fi

  if [[ -f "$dir/.agents/tasks.json" ]]; then
    pass "--keep-tmux preserves tasks.json"
  else
    fail "--keep-tmux must not remove tasks.json"
  fi

  # Archive snapshot must also exist.
  local archive
  archive=$(find "$dir/.agents/sessions" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
  if [[ -n "$archive" && -f "$archive/roster.json" ]]; then
    pass "--keep-tmux writes archive snapshot"
  else
    fail "--keep-tmux must write archive snapshot"
  fi

  rm -rf "$dir"
}

# ── model-select ─────────────────────────────────────────────────────────
test_model_select() {
  printf "\n\033[1mmodel-select\033[0m\n"

  # _yn_to_1 must work under bash 3.2 (no ${1,,}).
  local r
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 y')
  assert_eq "1" "$r" "_yn_to_1 y → 1"
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 Y')
  assert_eq "1" "$r" "_yn_to_1 Y → 1"
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 yes')
  assert_eq "1" "$r" "_yn_to_1 yes → 1"
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 YES')
  assert_eq "1" "$r" "_yn_to_1 YES → 1"
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 n')
  assert_eq "0" "$r" "_yn_to_1 n → 0"
  r=$(bash -c 'source "$ORCHESTRATION_HOME/lib/model-select.sh"; _yn_to_1 ""')
  assert_eq "0" "$r" "_yn_to_1 empty → 0"

  # Non-interactive (stdin not a tty): defaults exported, no prompts.
  local out
  out=$(bash -c '
    source "$ORCHESTRATION_HOME/lib/model-select.sh"
    ask_model_choices "$ORCHESTRATION_HOME/patterns/lean.sh"
    echo "$ORCH_MODEL_orchestrator $ORCH_SKIP_PERMISSIONS_orchestrator $ORCH_MODEL_coder $ORCH_SKIP_PERMISSIONS_coder"
  ')
  assert_eq "claude 0 claude 0" "$out" "non-interactive: pattern defaults applied"

  # Pre-set env vars are honoured and not overwritten.
  out=$(bash -c '
    export ORCH_MODEL_coder=codex
    export ORCH_SKIP_PERMISSIONS_coder=1
    source "$ORCHESTRATION_HOME/lib/model-select.sh"
    ask_model_choices "$ORCHESTRATION_HOME/patterns/lean.sh"
    echo "$ORCH_MODEL_orchestrator $ORCH_SKIP_PERMISSIONS_orchestrator $ORCH_MODEL_coder $ORCH_SKIP_PERMISSIONS_coder"
  ')
  assert_eq "claude 0 codex 1" "$out" "non-interactive: pre-set env respected"

  out=$(bash -c '
    export ORCH_SKIP_PERMISSIONS=1
    source "$ORCHESTRATION_HOME/lib/model-select.sh"
    ask_model_choices "$ORCHESTRATION_HOME/patterns/lean.sh"
    echo "$ORCH_MODEL_orchestrator $ORCH_SKIP_PERMISSIONS_orchestrator $ORCH_MODEL_coder $ORCH_SKIP_PERMISSIONS_coder"
  ')
  assert_eq "claude 1 claude 1" "$out" "non-interactive: global skip permissions applies to roles"

  # Pattern with no AskModels line: function returns without exporting anything.
  out=$(bash -c '
    source "$ORCHESTRATION_HOME/lib/model-select.sh"
    ask_model_choices "$ORCHESTRATION_HOME/patterns/freeform.sh"
    echo "${ORCH_MODEL_coder:-unset}"
  ')
  assert_eq "unset" "$out" "pattern without AskModels: no exports"
}

# ── orch-enforce ─────────────────────────────────────────────────────────
test_enforce() {
  printf "\n\033[1morch-enforce\033[0m\n"
  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m skipped (tmux not installed)\n"
    return 0
  fi

  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-enforce-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_enforce_tmux() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }
  trap cleanup_enforce_tmux RETURN

  local dir sess
  dir=$(mktemp -d)
  sess="enf-$$"
  export ORCH_PROJECT="$dir"
  tmux new-session -d -s "$sess" -c "$dir" -x 120 -y 30
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$sess" >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder codex "$sess:0.0" >/dev/null
  tmux set-option -p -t "$sess:0.0" @orch_agent_id coder-1 >/dev/null 2>&1 || true

  mkdir -p "$dir/.agents/inbox"
  printf '{"id":"m1","ts":"%s","from":"orchestrator","to":"coder-1","type":"TASK","payload":"x","read":false}\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    > "$dir/.agents/inbox/coder-1.jsonl"

  local out rc
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --once 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-enforce --once exits cleanly"
  assert_contains "$out" "nudged=1" "orch-enforce nudges agents with unread inbox"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --on --interval 1 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-enforce --on starts loop"
  assert_contains "$out" "started" "orch-enforce reports started"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --status 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-enforce --status is zero when running"
  assert_contains "$out" "ON" "orch-enforce status shows ON"
  assert_contains "$out" "schema_required=true" "orch-enforce enables schema-required policy"

  # With schema enforcement on, malformed TASK/DONE must be rejected.
  assert_fails "schema rejects malformed TASK payload" \
    bash -c 'cd "'"$dir"'" && ORCH_DELIVERY=silent bash "'"$ORCHESTRATION_HOME"'/lib/protocol.sh" send coder-1 TASK "hello" --from orchestrator'
  bash -c 'cd "'"$dir"'" && ORCH_DELIVERY=silent bash "'"$ORCHESTRATION_HOME"'/lib/protocol.sh" send coder-1 TASK "objective: ship; definition_of_done: tests pass; required_reply: ACK" --from orchestrator' \
    >/dev/null 2>&1 || fail "schema accepts valid TASK payload"
  assert_fails "schema rejects malformed DONE payload" \
    bash -c 'cd "'"$dir"'" && ORCH_DELIVERY=silent bash "'"$ORCHESTRATION_HOME"'/lib/protocol.sh" send coder-1 DONE "done" --from coder-1'
  bash -c 'cd "'"$dir"'" && ORCH_DELIVERY=silent bash "'"$ORCHESTRATION_HOME"'/lib/protocol.sh" send coder-1 DONE "commit_hash: abc123; changed_files: a,b; test_result: pass" --from coder-1' \
    >/dev/null 2>&1 || fail "schema accepts valid DONE payload"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --off 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-enforce --off stops loop"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --status 2>&1) || rc=$?
  assert_eq "1" "$rc" "orch-enforce --status is non-zero when off"
  assert_contains "$out" "OFF" "orch-enforce status shows OFF"

  # With enforce OFF, schema gate should no longer block free-form payloads.
  bash -c 'cd "'"$dir"'" && ORCH_DELIVERY=silent bash "'"$ORCHESTRATION_HOME"'/lib/protocol.sh" send coder-1 TASK "free form task allowed when enforce off" --from orchestrator' \
    >/dev/null 2>&1 || fail "schema is disabled when enforce is off"

  rm -rf "$dir"
  trap - RETURN
  cleanup_enforce_tmux
}

# ── orch-preflight ───────────────────────────────────────────────────────
test_preflight() {
  printf "\n\033[1morch-preflight\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"
  local out rc
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-preflight" 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-preflight exits cleanly on initialized project"
  assert_contains "$out" "Overall: PASS" "orch-preflight reports PASS"

  # Duplicate ids should be flagged as a hard failure.
  local roster="$dir/.agents/roster.json"
  jq '.agents += [{"id":"a1","role":"coder","model":"codex","target":"x:0.0","status":"active"},{"id":"a1","role":"coder","model":"codex","target":"x:0.1","status":"active"}]' \
    "$roster" > "$roster.tmp" && mv "$roster.tmp" "$roster"
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-preflight" 2>&1) || rc=$?
  assert_eq "1" "$rc" "orch-preflight fails on duplicate ids"
  assert_contains "$out" "duplicate agent id(s): a1" "orch-preflight reports duplicate ids"

  rm -rf "$dir"

  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m repair retarget skipped (tmux not installed)\n"
    return 0
  fi

  local real_tmux; real_tmux=$(command -v tmux)
  local sock="orch-preflight-$$"
  local bin_dir; bin_dir=$(mktemp -d)
  printf '#!/bin/bash\nexec "%s" -L "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_preflight_tmux() {
    export PATH="$orig_path"
    rm -rf "$bin_dir"
    command tmux -L "$sock" kill-server 2>/dev/null || true
  }

  dir=$(mktemp -d)
  export ORCH_PROJECT="$dir"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init missing-pf >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder codex missing-pf:0.0 >/dev/null
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-preflight" --repair 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-preflight --repair exits cleanly when tmux session is missing"
  assert_contains "$out" "run orch-restore" "orch-preflight --repair points missing session to orch-restore"
  assert_eq "coder-1" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" exists coder-1 && echo coder-1)" \
    "orch-preflight --repair keeps active roster entries when session is missing"
  rm -rf "$dir"

  dir=$(mktemp -d)
  export ORCH_PROJECT="$dir"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init pf >/dev/null
  tmux new-session -d -s pf -c "$dir" -x 100 -y 30
  tmux split-window -h -t pf:0.0 -c "$dir"
  tmux set-option -p -t pf:0.1 @orch_agent_id coder-1 >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder codex pf:0.99 >/dev/null
  rm -f "$dir/.agents/tasks.json" "$dir/.agents/tasks.notify.json"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-preflight" --repair 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-preflight --repair exits cleanly"
  assert_contains "$out" "coder-1 target pf:0.99 -> pf:0.1" \
    "orch-preflight --repair retargets stale roster target"
  assert_eq "pf:0.1" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target coder-1)" \
    "orch-preflight --repair persists repaired target"
  [[ -f "$dir/.agents/tasks.json" ]] && pass "orch-preflight --repair creates tasks.json" \
    || fail "orch-preflight --repair creates tasks.json"
  [[ -f "$dir/.agents/tasks.notify.json" ]] && pass "orch-preflight --repair creates tasks.notify.json" \
    || fail "orch-preflight --repair creates tasks.notify.json"

  rm -rf "$dir"
  cleanup_preflight_tmux
}

# ── orch-restore ────────────────────────────────────────────────────────
test_restore() {
  printf "\n\033[1morch-restore\033[0m\n"

  if ! command -v tmux >/dev/null 2>&1; then
    printf "  \033[33m—\033[0m restore skipped (tmux not installed)\n"
    return 0
  fi

  local real_tmux; real_tmux=$(command -v tmux)
  local bin_dir; bin_dir=$(mktemp -d)
  local sock="$bin_dir/tmux.sock"
  printf '#!/bin/bash\nif [[ "$1" == "-CC" ]]; then echo "TMUX_CC $*"; exit 0; fi\nexec "%s" -S "%s" "$@"\n' "$real_tmux" "$sock" > "$bin_dir/tmux"
  chmod +x "$bin_dir/tmux"
  local orig_path="$PATH"
  export PATH="$bin_dir:$PATH"

  cleanup_restore_tmux() {
    export PATH="$orig_path"
    command tmux -S "$sock" kill-server 2>/dev/null || true
    rm -rf "$bin_dir"
  }

  local dir; dir=$(mktemp -d)
  export ORCH_PROJECT="$dir"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init restore-smoke >/dev/null
  mkdir -p "$dir/.agents/prompts"
  printf 'RESTORE_MARKER_ORCH\n' > "$dir/.agents/prompts/orchestrator.md"
  printf 'RESTORE_MARKER_CODER\n' > "$dir/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add orchestrator orchestrator none restore-smoke:0.99 >/dev/null
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder none restore-smoke:1.99 >/dev/null

  local out rc
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-restore exits cleanly after tmux session loss"
  assert_contains "$out" "restore complete: restored=2" "orch-restore reports restored panes"

  local orch_target coder_target orch_meta coder_meta orch_capture coder_capture
  orch_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target orchestrator)
  coder_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target coder-1)
  orch_meta=$(tmux display-message -p -t "$orch_target" '#{@orch_agent_id}' 2>/dev/null || true)
  coder_meta=$(tmux display-message -p -t "$coder_target" '#{@orch_agent_id}' 2>/dev/null || true)
  assert_eq "orchestrator" "$orch_meta" "orch-restore sets orchestrator pane metadata"
  assert_eq "coder-1" "$coder_meta" "orch-restore sets coder pane metadata"

  orch_capture=$(tmux capture-pane -p -t "$orch_target" 2>/dev/null || true)
  coder_capture=$(tmux capture-pane -p -t "$coder_target" 2>/dev/null || true)
  assert_contains "$orch_capture" "RESTORE_MARKER_ORCH" "orch-restore reuses existing orchestrator prompt"
  assert_contains "$coder_capture" "RESTORE_MARKER_CODER" "orch-restore reuses existing coder prompt"

  local coder_window_target
  coder_window_target="${coder_target%.*}"
  tmux select-pane -t "$coder_target"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" retarget coder-1 "$coder_window_target.99" >/dev/null
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-restore exits cleanly with same-session stale target"
  assert_eq "$coder_target" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target coder-1)" \
    "orch-restore canonicalizes same-session stale target"

  coder_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target coder-1)
  tmux set-option -p -t "$coder_target" @orch_agent_id "" 2>/dev/null || true
  tmux send-keys -t "$coder_target" "tail -f /dev/null" Enter
  local tries=0
  while (( tries < 30 )); do
    if [[ "$(tmux display-message -p -t "$coder_target" '#{pane_current_command}' 2>/dev/null)" == "tail" ]]; then
      break
    fi
    sleep 0.1
    tries=$((tries + 1))
  done
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach 2>&1) || rc=$?
  if (( rc != 0 )); then
    pass "orch-restore refuses to duplicate occupied untagged roster target"
  else
    fail "orch-restore must refuse occupied untagged roster target"
  fi
  assert_contains "$out" "Refusing to duplicate" \
    "orch-restore explains occupied untagged target refusal"

  local dir_flags
  dir_flags=$(mktemp -d)
  export ORCH_PROJECT="$dir_flags"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init restore-flags >/dev/null
  mkdir -p "$dir_flags/.agents/prompts"
  printf 'RESTORE_FLAGS\n' > "$dir_flags/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder none restore-flags:0.99 >/dev/null
  rc=0
  out=$(cd "$dir_flags" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --iterm-cc --no-attach 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-restore parses --iterm-cc --no-attach"
  assert_not_contains "$out" "TMUX_CC" "orch-restore --no-attach cancels prior --iterm-cc"
  tmux kill-session -t restore-flags 2>/dev/null || true
  rm -rf "$dir_flags"

  dir_flags=$(mktemp -d)
  export ORCH_PROJECT="$dir_flags"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init restore-flags >/dev/null
  mkdir -p "$dir_flags/.agents/prompts"
  printf 'RESTORE_FLAGS\n' > "$dir_flags/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder none restore-flags:0.99 >/dev/null
  rc=0
  out=$(cd "$dir_flags" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach -CC 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-restore parses --no-attach -CC"
  assert_contains "$out" "TMUX_CC -CC attach-session -t restore-flags" \
    "orch-restore -CC wins when it is the last presentation flag"
  tmux kill-session -t restore-flags 2>/dev/null || true
  rm -rf "$dir_flags"

  local dir_resume claude_resume resume_target resume_capture resume_capture_flat codex_resume
  dir_resume=$(mktemp -d)
  export ORCH_PROJECT="$dir_resume"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init resume-claude >/dev/null
  ORCH_TOTAL_AGENTS=1 ORCH_CLI_READY_MAX=1 ORCH_KICKOFF_FALLBACK_ENTER=0 ORCH_LAUNCH_ECHO_ONLY=1 \
    bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" claude-1 coder claude --session resume-claude >/dev/null
  claude_resume=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" resume claude-1 | jq -r '.id // ""')
  if [[ "$claude_resume" =~ ^[0-9a-f-]{36}$ ]]; then
    pass "spawn-agent stores generated Claude resume id"
  else
    fail "spawn-agent stores generated Claude resume id"
  fi
  resume_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target claude-1)
  resume_capture=$(tmux capture-pane -p -t "$resume_target" 2>/dev/null || true)
  assert_contains "$resume_capture" "ORCH_LAUNCH_CMD: claude --session-id '$claude_resume'" \
    "spawn-agent starts Claude with stored session id"
  tmux kill-session -t resume-claude 2>/dev/null || true
  ORCH_CLI_READY_MAX=1 ORCH_KICKOFF_FALLBACK_ENTER=0 ORCH_LAUNCH_ECHO_ONLY=1 \
    bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach >/dev/null
  resume_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target claude-1)
  resume_capture=$(tmux capture-pane -p -t "$resume_target" 2>/dev/null || true)
  assert_contains "$resume_capture" "ORCH_LAUNCH_CMD: claude --resume '$claude_resume'" \
    "orch-restore resumes Claude with stored session id"
  tmux kill-session -t resume-claude 2>/dev/null || true
  rm -rf "$dir_resume"

  dir_resume=$(mktemp -d)
  export ORCH_PROJECT="$dir_resume"
  codex_resume="019de80b-e52e-7682-a818-a17496aa0140"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init resume-codex >/dev/null
  mkdir -p "$dir_resume/.agents/prompts"
  printf 'CODEX_RESUME\n' > "$dir_resume/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder codex resume-codex:0.99 \
    --resume-provider codex --resume-id "$codex_resume" --resume-mode exact >/dev/null
  ORCH_CLI_READY_MAX=1 ORCH_CODEX_GATE_MAX=1 ORCH_LAUNCH_ECHO_ONLY=1 \
    bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach >/dev/null
  resume_target=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target coder-1)
  resume_capture=$(tmux capture-pane -p -t "$resume_target" 2>/dev/null || true)
  assert_contains "$resume_capture" "ORCH_LAUNCH_CMD: codex resume --no-alt-screen" \
    "orch-restore resumes Codex when exact resume id is stored"
  resume_capture_flat=$(printf "%s" "$resume_capture" | tr -d '\n')
  assert_contains "$resume_capture_flat" "$codex_resume" \
    "orch-restore includes stored Codex resume id"
  tmux kill-session -t resume-codex 2>/dev/null || true
  rm -rf "$dir_resume"

  local dir_concurrent pid1 pid2 rc1 rc2 pane_count
  dir_concurrent=$(mktemp -d)
  export ORCH_PROJECT="$dir_concurrent"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init restore-concurrent >/dev/null
  mkdir -p "$dir_concurrent/.agents/prompts"
  printf 'CONCURRENT_RESTORE\n' > "$dir_concurrent/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder none restore-concurrent:0.99 >/dev/null
  tmux new-session -d -s restore-concurrent -c "$dir_concurrent"
  (cd "$dir_concurrent" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach > "$dir_concurrent/out1" 2>&1) & pid1=$!
  (cd "$dir_concurrent" && bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach > "$dir_concurrent/out2" 2>&1) & pid2=$!
  rc1=0; wait "$pid1" || rc1=$?
  rc2=0; wait "$pid2" || rc2=$?
  assert_eq "0" "$rc1" "concurrent orch-restore first process exits cleanly"
  assert_eq "0" "$rc2" "concurrent orch-restore second process exits cleanly"
  pane_count=$(tmux list-panes -t restore-concurrent -F '#{@orch_agent_id}' 2>/dev/null \
    | awk '$0 == "coder-1" { n++ } END { print n + 0 }')
  assert_eq "1" "$pane_count" "concurrent orch-restore does not duplicate live agent panes"
  tmux kill-session -t restore-concurrent 2>/dev/null || true
  rm -rf "$dir_concurrent"

  local dir_fail
  printf '#!/usr/bin/env bash\nexit 42\n' > "$bin_dir/codex"
  chmod +x "$bin_dir/codex"
  dir_fail=$(mktemp -d)
  export ORCH_PROJECT="$dir_fail"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" init resume-fail >/dev/null
  mkdir -p "$dir_fail/.agents/prompts"
  printf 'CODEX_FAIL\n' > "$dir_fail/.agents/prompts/coder-1.md"
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add coder-1 coder codex resume-fail:0.99 \
    --resume-provider codex --resume-id bad-resume-id --resume-mode exact >/dev/null
  rc=0
  out=$(cd "$dir_fail" && ORCH_CLI_READY_MAX=1 ORCH_CODEX_GATE_MAX=1 \
    bash "$ORCHESTRATION_HOME/bin/orch-restore" --no-attach 2>&1) || rc=$?
  if (( rc != 0 )); then
    pass "orch-restore fails when resumed Codex CLI is not ready"
  else
    fail "orch-restore should fail when resumed Codex CLI is not ready"
  fi
  assert_contains "$out" "Codex prompt/trust detection timed out" \
    "orch-restore reports resumed Codex readiness failure"
  tmux kill-session -t resume-fail 2>/dev/null || true
  rm -rf "$dir_fail"

  rm -rf "$dir"
  cleanup_restore_tmux
}

# ── run ──────────────────────────────────────────────────────────────────
SUITE="${1:-all}"
case "$SUITE" in
  roster)       test_roster ;;
  protocol)     test_protocol ;;
  tasks)        test_tasks ;;
  tmux)         test_tmux_ready ;;
  concurrency)  test_concurrency ;;
  end-session)  test_end_session ;;
  model-select) test_model_select ;;
  enforce)      test_enforce ;;
  preflight)    test_preflight ;;
  restore)      test_restore ;;
  present-session) test_present_session ;;
  pattern-defaults) test_pattern_defaults ;;
  tmux-send)    test_tmux_send_helpers ;;
  tui)          test_tui ;;
  spawn-layout) test_spawn_layout ;;
  protocol-notify-tmux) test_protocol_notify_tmux ;;
  all)          test_roster; test_protocol; test_protocol_notify_tmux; test_tasks; test_concurrency; test_end_session; test_model_select; test_enforce; test_preflight; test_restore; test_present_session; test_pattern_defaults; test_tmux_send_helpers; test_tui; test_spawn_layout; test_tmux_ready ;;
  *) echo "unknown suite: $SUITE"; exit 2 ;;
esac

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
