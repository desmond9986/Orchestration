#!/usr/bin/env bash
# Description: 1 coder + 1 reviewer — ping-pong until PASS.
# AskModels: coder:claude reviewer:claude
#
# Use when: focused single-track work that needs quality gating (e.g.,
# refactoring, security-sensitive change, spec compliance audit).
# No orchestrator; the human directs the coder.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="review-loop"
export ORCH_TOTAL_AGENTS=2
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1  coder    "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer reviewer "${ORCH_MODEL_reviewer:-claude}"
