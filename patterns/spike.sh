#!/usr/bin/env bash
# Description: researcher explores codebase, architect synthesises design — no implementation
# AskModels: researcher:claude architect:claude
#
# Use when: you're about to start something significant and want a plan
# before burning tokens on implementation. The researcher maps the current
# state (what exists, constraints, risks); the architect turns that into a
# design doc and contract. Human decides whether and how to proceed.
#
# Output: .agents/contracts/research-<topic>.md (researcher)
#         .agents/contracts/<feature>.md         (architect)
#
# After a spike, continue with plan-execute (has coders + reviewer) or
# promote the spike agents using add-agent.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="spike"
export ORCH_TOTAL_AGENTS=2

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" researcher researcher "${ORCH_MODEL_researcher:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect  architect  "${ORCH_MODEL_architect:-claude}"

info "spike ready: researcher + architect (no coders — explore first, implement later)"
info "seed: orch-send researcher --type TASK \"Research <topic>. Report to architect.\""
