#!/usr/bin/env bash
# Smoke tests for roster, protocol, and tasks libraries.
#
# Runs each lib against a temp project dir. No tmux delivery is exercised —
# we only verify file-state correctness and the state machines. Push delivery,
# spawn-agent, and end-session are covered separately by manual runs.
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

  rm -rf "$dir"
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

  rm -rf "$dir"
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

  # Case 1: pane stays at the shell — readiness should time out fast.
  rc=0
  ORCH_CLI_READY_MAX=1 ORCH_CLI_READY_POLL=100 ORCH_CLI_READY_STABLE=2 \
    wait_for_cli_ready "$target" || rc=$?
  assert_eq "1" "$rc" "times out when pane stays at the shell"

  # Case 2: launch an idle, non-shell command (tail -f /dev/null). It prints
  # nothing, so the output hash stabilises immediately → function returns 0.
  tmux send-keys -t "$target" "clear && tail -f /dev/null" Enter
  rc=0
  ORCH_CLI_READY_MAX=5 ORCH_CLI_READY_POLL=100 ORCH_CLI_READY_STABLE=2 \
    wait_for_cli_ready "$target" || rc=$?
  assert_eq "0" "$rc" "detects readiness when foreground cmd is not a shell and output is stable"

  cleanup_tmux
}

# ── run ──────────────────────────────────────────────────────────────────
SUITE="${1:-all}"
case "$SUITE" in
  roster)   test_roster ;;
  protocol) test_protocol ;;
  tasks)    test_tasks ;;
  tmux)     test_tmux_ready ;;
  all)      test_roster; test_protocol; test_tasks; test_tmux_ready ;;
  *) echo "unknown suite: $SUITE"; exit 2 ;;
esac

printf "\n%d passed, %d failed\n" "$PASS" "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
