#!/usr/bin/env bash
# Description: orchestrator + architect + 2 coders + reviewer + qa. No hats.
# AskModels: orchestrator:claude architect:claude coder:claude reviewer:claude qa:claude
#
# Use when: complex multi-component work where specialized roles pay off —
# the architect writes contracts, coders implement, reviewer audits, qa
# verifies on real env.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="full-team"
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator "${ORCH_MODEL_orchestrator:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect    architect    "${ORCH_MODEL_architect:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1      coder        "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-2      coder        "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer     reviewer     "${ORCH_MODEL_reviewer:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" qa           qa           "${ORCH_MODEL_qa:-claude}"
