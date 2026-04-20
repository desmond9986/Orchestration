#!/usr/bin/env bash
# Common helpers sourced by all lib/bin scripts.
# Defines colors, error helpers, project root resolution, and shared paths.

set -euo pipefail

: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
export ORCHESTRATION_HOME

# Resolve project root: current dir (where .agents/ lives or will live)
project_root() {
  echo "${ORCH_PROJECT:-$PWD}"
}

agents_dir() {
  echo "$(project_root)/.agents"
}

roster_file()  { echo "$(agents_dir)/roster.json"; }
status_file()  { echo "$(agents_dir)/status.md"; }
bus_file()     { echo "$(agents_dir)/bus.md"; }
log_file()     { echo "$(agents_dir)/log.md"; }
inbox_dir()    { echo "$(agents_dir)/inbox"; }
prompts_dir()  { echo "$(agents_dir)/prompts"; }
contracts_dir(){ echo "$(agents_dir)/contracts"; }

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_short() { date +"%H:%M:%S"; }

# Color helpers (skip if not a tty)
# shellcheck disable=SC2034
if [[ -t 1 ]]; then
  C_RESET='\033[0m'; C_DIM='\033[2m'; C_RED='\033[31m'; C_GREEN='\033[32m'
  C_YELLOW='\033[33m'; C_BLUE='\033[34m'; C_BOLD='\033[1m'
else
  C_RESET=''; C_DIM=''; C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''
fi

info()  { printf "${C_BLUE}[orch]${C_RESET} %s\n" "$*"; }
ok()    { printf "${C_GREEN}[orch]${C_RESET} %s\n" "$*"; }
warn()  { printf "${C_YELLOW}[orch]${C_RESET} %s\n" "$*" >&2; }
die()   { printf "${C_RED}[orch]${C_RESET} %s\n" "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing dependency: $1"
}

ensure_agents_dir() {
  mkdir -p "$(agents_dir)" "$(inbox_dir)" "$(prompts_dir)" "$(contracts_dir)"
  [[ -f "$(status_file)" ]] || : > "$(status_file)"
  [[ -f "$(bus_file)" ]] || : > "$(bus_file)"
  [[ -f "$(log_file)" ]] || : > "$(log_file)"
}

bus_line() {
  # Append a full chronological message record to the shared bus log.
  # Args: from to type id payload
  local from="$1" to="$2" type="$3" id="$4"; shift 4
  local payload="$*"
  {
    printf "\n[%s] %s → %s  [%s]  id=%s\n" "$(ts_short)" "$from" "$to" "$type" "$id"
    printf "%s\n" "$payload" | sed 's/^/  /'
  } >> "$(bus_file)"
}

log_line() {
  local msg="$*"
  printf "[%s] %s\n" "$(ts)" "$msg" >> "$(log_file)"
}

status_line() {
  local agent="$1"; shift
  local msg="$*"
  printf "[%s][%s] %s\n" "$(ts_short)" "$agent" "$msg" >> "$(status_file)"
}

# File-based mutex using mkdir (atomic on POSIX, portable across macOS/Linux,
# no dependency on flock). Usage:
#
#   with_file_lock <lock_dir_path> <fn> [fn_args...]
#
# Spins up to 10s before giving up. Stale locks older than 60s are reaped so a
# crashed process cannot wedge the mutex forever.
with_file_lock() {
  _mtime_epoch() {
    local p="$1" m=""
    m=$(stat -c %Y "$p" 2>/dev/null || true)
    if [[ "$m" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$m"
      return 0
    fi
    m=$(stat -f %m "$p" 2>/dev/null || true)
    if [[ "$m" =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$m"
      return 0
    fi
    date +%s
  }

  local lock="$1"; shift
  local waited=0
  local max_wait_loops="${ORCH_LOCK_MAX_WAIT_LOOPS:-300}"  # 30s at 100ms
  local stale_sec="${ORCH_LOCK_STALE_SEC:-60}"
  [[ "$max_wait_loops" =~ ^[0-9]+$ ]] || max_wait_loops=300
  [[ "$stale_sec" =~ ^[0-9]+$ ]] || stale_sec=60
  while ! mkdir "$lock" 2>/dev/null; do
    if [[ -d "$lock" ]]; then
      local age
      age=$(( $(date +%s) - $(_mtime_epoch "$lock") ))
      if (( age > stale_sec )); then
        rmdir "$lock" 2>/dev/null || true
        continue
      fi
    fi
    sleep 0.1
    waited=$((waited + 1))
    (( waited > max_wait_loops )) && die "could not acquire lock at $lock after $((max_wait_loops/10))s"
  done
  # The wrapped command may call `die` (→ exit) or fail under `set -e`. Either
  # path skips the normal rmdir below, so register an EXIT trap to guarantee
  # the lock is released even when the shell is about to exit.
  trap 'rmdir "'"$lock"'" 2>/dev/null || true' EXIT
  local rc=0
  "$@" || rc=$?
  rmdir "$lock" 2>/dev/null || true
  trap - EXIT
  return $rc
}
