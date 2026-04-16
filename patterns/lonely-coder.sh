#!/usr/bin/env bash
# Description: Solo coder wearing spawner+qa+reviewer hats. No team.
# AskModels: coder:claude
#
# Use when: you want a single agent that covers everything — implements,
# self-reviews, verifies on real env, and can spawn sub-agents on demand.
# Good for quick fixes where spinning up a full team is overkill.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="lonely-coder"
export ORCH_TOTAL_AGENTS=1
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1 coder "${ORCH_MODEL_coder:-claude}" --hats spawner,qa,reviewer
