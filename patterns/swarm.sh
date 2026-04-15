#!/usr/bin/env bash
# Description: 1 orchestrator + N coders (default N=3). All coders run claude.
#
# Usage: orchestrate swarm [N]
# Use when: big parallelizable task with many independent subtasks.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

N="${1:-3}"
SESSION="swarm"

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator claude

for i in $(seq 1 "$N"); do
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" "coder-$i" coder claude
done

info "swarm ready: 1 orchestrator + $N coders"
