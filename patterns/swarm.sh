#!/usr/bin/env bash
# Description: 1 orchestrator + N coders (default N=3). All coders run claude.
# AskModels: orchestrator:claude coder:claude
#
# Usage: orchestrate swarm [N]
# Use when: big parallelizable task with many independent subtasks.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

N="${1:-3}"
SESSION="swarm"
export ORCH_TOTAL_AGENTS=$(( N + 1 ))  # orchestrator + N coders

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator "${ORCH_MODEL_orchestrator:-claude}"

for i in $(seq 1 "$N"); do
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" "coder-$i" coder "${ORCH_MODEL_coder:-claude}"
done

info "swarm ready: 1 orchestrator + $N coders"
