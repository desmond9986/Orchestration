#!/usr/bin/env bash
# Description: 1 orchestrator (wears architect hat) + 2 coders (one with spawner)
#
# Use when: small team, no dedicated architect/reviewer, but want the option
# for a coder to spawn its own QA sub-agent.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="lean"
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator claude --hats architect
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1      coder        claude --hats spawner
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-2      coder        codex
