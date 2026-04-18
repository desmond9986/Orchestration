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
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add a2 coder codex  "s:0.1" >/dev/null

  local out
  out=$(bash "$ORCHESTRATION_HOME/lib/roster.sh" find-role coder | tr '\n' ' ')
  assert_eq "a1 a2 " "$out" "find-role lists both coders"

  assert_eq "s:0.0" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target a1)" \
    "target returns active agent's target"

  bash "$ORCHESTRATION_HOME/lib/roster.sh" remove a1 >/dev/null
  assert_eq "" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target a1)" \
    "target returns empty for removed agent (#3)"
  assert_eq "s:0.0" "$(bash "$ORCHESTRATION_HOME/lib/roster.sh" target-any a1)" \
    "target-any still resolves removed agent for archival reads"

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
  local read_out
  read_out=$(bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-inbox a2)
  assert_contains "$read_out" "FROM: a1" "check-inbox renders sender"
  assert_contains "$read_out" "TO:   a2" "check-inbox renders recipient"
  local arch
  arch=$(bash "$ORCHESTRATION_HOME/lib/protocol.sh" check-archive a2)
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
  [[ "$avail" != *"t-b"* ]] && pass "list-available hides dep-blocked t-b" \
                             || fail "list-available must hide t-b"

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
  [[ "$avail" != *"t-b"* ]] && pass "blocked task not in list-available (#1)" \
                             || fail "blocked task must not appear in list-available (#1)"

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
  local rendered archived
  rendered=$(grep -c '^msg-' "$dir/reader.out" 2>/dev/null || echo 0)
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

  [[ -f "$dir/.agents/roster.json" ]] \
    && pass "--keep-tmux preserves roster.json" \
    || fail "--keep-tmux must not remove roster.json"

  [[ -d "$dir/.agents/inbox" ]] \
    && pass "--keep-tmux preserves inbox dir" \
    || fail "--keep-tmux must not remove inbox dir"

  [[ -f "$dir/.agents/tasks.json" ]] \
    && pass "--keep-tmux preserves tasks.json" \
    || fail "--keep-tmux must not remove tasks.json"

  # Archive snapshot must also exist.
  local archive
  archive=$(ls -d "$dir/.agents/sessions"/*/  2>/dev/null | head -1)
  [[ -n "$archive" && -f "${archive}roster.json" ]] \
    && pass "--keep-tmux writes archive snapshot" \
    || fail "--keep-tmux must write archive snapshot"

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

  # Pattern with no AskModels line: function returns without exporting anything.
  out=$(bash -c '
    source "$ORCHESTRATION_HOME/lib/model-select.sh"
    ask_model_choices "$ORCHESTRATION_HOME/patterns/freeform.sh"
    echo "${ORCH_MODEL_coder:-unset}"
  ')
  assert_eq "unset" "$out" "pattern without AskModels: no exports"
}

# ── orch-doctor ──────────────────────────────────────────────────────────
test_doctor() {
  printf "\n\033[1morch-doctor\033[0m\n"
  fresh_project; local dir="$ORCH_PROJECT"

  # No active agents is degraded (not broken).
  local out rc
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-doctor" 2>&1) || rc=$?
  assert_eq "10" "$rc" "doctor exits 10 for degraded sessions"
  assert_contains "$out" "Overall: DEGRADED" "doctor prints DEGRADED overall"

  # JSON mode should mirror overall status.
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-doctor" --json 2>/dev/null) || rc=$?
  assert_eq "10" "$rc" "doctor --json preserves degraded exit code"
  assert_eq "DEGRADED" "$(jq -r '.overall' <<<"$out")" "doctor --json exposes overall"

  # Active agent with unreachable pane should be broken.
  bash "$ORCHESTRATION_HOME/lib/roster.sh" add broken coder codex "no-such-session-$$:99.99" >/dev/null
  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-doctor" 2>&1) || rc=$?
  assert_eq "20" "$rc" "doctor exits 20 for broken sessions"
  assert_contains "$out" "tmux target unreachable" "doctor reports unreachable tmux target"

  rm -rf "$dir"
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

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --off 2>&1) || rc=$?
  assert_eq "0" "$rc" "orch-enforce --off stops loop"

  rc=0
  out=$(cd "$dir" && bash "$ORCHESTRATION_HOME/bin/orch-enforce" --status 2>&1) || rc=$?
  assert_eq "1" "$rc" "orch-enforce --status is non-zero when off"
  assert_contains "$out" "OFF" "orch-enforce status shows OFF"

  rm -rf "$dir"
  trap - RETURN
  cleanup_enforce_tmux
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
  doctor)       test_doctor ;;
  enforce)      test_enforce ;;
  spawn-layout) test_spawn_layout ;;
  protocol-notify-tmux) test_protocol_notify_tmux ;;
  all)          test_roster; test_protocol; test_protocol_notify_tmux; test_tasks; test_concurrency; test_end_session; test_model_select; test_doctor; test_enforce; test_spawn_layout; test_tmux_ready ;;
  *) echo "unknown suite: $SUITE"; exit 2 ;;
esac

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
