#!/usr/bin/env bash
# Description: strict sequential stages — architect → coder → reviewer → qa, no orchestrator
# AskModels: architect:claude coder:claude reviewer:claude qa:claude
#
# Use when: the work is a known linear process with clear stage gates and
# you don't want an orchestrator in the loop — each stage hands off
# explicitly to the next via TASK messages and task dependencies.
#
# How sequencing works (no orchestrator — stages self-coordinate):
#   1. Architect reads brief from inbox/human, writes contract, sends TASK to coder
#   2. Coder claims task (deps: architect's task done), implements, sends REVIEW_REQUEST
#   3. Reviewer audits, sends VERDICT; on PASS sends TASK to qa
#   4. QA verifies on real env, posts DONE to status board
#
# The human seeds the pipeline by sending the architect their brief:
#   orch-send architect --type TASK "Design <feature>. Coder is coder-1."
#
# Use plan-execute instead if you want an orchestrator managing the stages.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="pipeline"
export ORCH_TOTAL_AGENTS=4

bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" architect architect "${ORCH_MODEL_architect:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1   coder     "${ORCH_MODEL_coder:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" reviewer  reviewer  "${ORCH_MODEL_reviewer:-claude}"
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" qa        qa        "${ORCH_MODEL_qa:-claude}"

info "pipeline ready: architect → coder-1 → reviewer → qa"
info "seed the pipeline: orch-send architect --type TASK \"<brief>\""
