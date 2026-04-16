#!/usr/bin/env bash
# Description: orchestrator + N coders (default 2) + reviewer quality gate
# AskModels: orchestrator:claude coder:claude reviewer:claude
#
# Usage: orchestrate ship-it [N_coders]   (default N=2)
#
# Use when: you have a large parallelizable task where correctness matters —
# parallel coders race through subtasks and a single reviewer validates
# everything before it ships. The reviewer sees all output and can flag
# cross-coder inconsistencies that no individual coder would catch.
#
# This is swarm + a quality gate. Use swarm when you don't need the gate;
# use ship-it when you do.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

N="${1:-2}"
SESSION="ship-it"
export ORCH_TOTAL_AGENTS=$(( N + 2 ))  # orchestrator + N coders + reviewer

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator "${ORCH_MODEL_orchestrator:-claude}"

for i in $(seq 1 "$N"); do
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" "coder-$i" coder "${ORCH_MODEL_coder:-claude}"
done

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer reviewer "${ORCH_MODEL_reviewer:-claude}"

info "ship-it ready: orchestrator + $N coder(s) + reviewer"
info "reviewer validates all output before completion — coders send REVIEW_REQUEST when done"
