#!/usr/bin/env bash
# Description: [max team] orchestrator + architect + 2 coders + reviewer + qa
# AskModels: orchestrator:claude architect:claude coder:claude reviewer:claude qa:claude
#
# Use when: you genuinely need all six roles simultaneously — large system
# changes where design, implementation, code review, AND real-env verification
# are all required in parallel. This is the exception, not the default.
#
# For most work, a focused pattern is better:
#   plan-execute  — needs design-first (orchestrator + architect + coders + reviewer)
#   ship-it       — needs quality gate but no dedicated architect
#   pipeline      — known linear process, no orchestrator overhead
#   debug-squad   — bug investigation
#
# 6 agents means 6 idle panes while each waits for the previous stage.
# Only reach for full-team when the parallel specialisation genuinely pays off.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="full-team"
export ORCH_TOTAL_AGENTS=6
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator "${ORCH_MODEL_orchestrator:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect    architect    "${ORCH_MODEL_architect:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1      coder        "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-2      coder        "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer     reviewer     "${ORCH_MODEL_reviewer:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" qa           qa           "${ORCH_MODEL_qa:-claude}"
