#!/usr/bin/env bash
# Description: architect designs first, then coders implement, reviewer closes loop
# AskModels: orchestrator:claude architect:claude coder:claude reviewer:claude
#
# Usage: orchestrate plan-execute [N_coders]   (default N=1)
#
# Use when: the task needs upfront design before any code is written —
# new features, cross-component changes, anything where a bad contract
# will cost more to fix later than to design correctly now.
#
# Flow: orchestrator assigns → architect writes contract → coder(s) implement
#       → reviewer audits → orchestrator ships.
# The architect and reviewer are distinct roles so design decisions and
# code quality are evaluated independently.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

N="${1:-1}"
SESSION="plan-execute"
export ORCH_TOTAL_AGENTS=$(( N + 3 ))  # orchestrator + architect + N coders + reviewer

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator "${ORCH_MODEL_orchestrator:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect    architect    "${ORCH_MODEL_architect:-claude}"

for i in $(seq 1 "$N"); do
  bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" "coder-$i" coder "${ORCH_MODEL_coder:-claude}"
done

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer reviewer "${ORCH_MODEL_reviewer:-claude}"

info "plan-execute ready: orchestrator + architect + $N coder(s) + reviewer"
info "suggested flow: orchestrate → architect writes contract → coder(s) claim tasks → reviewer audits → done"
