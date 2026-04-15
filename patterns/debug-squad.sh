#!/usr/bin/env bash
# Description: orchestrator + coder + debugger + qa — focused on diagnosing
# and fixing a tricky bug.
#
# Use when: you have a bug that's already been unsuccessfully attempted.
# The debugger agent is tasked with root-cause analysis before the coder
# writes a fix, and qa verifies on real env.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"

SESSION="debug-squad"
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"

bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" orchestrator orchestrator claude
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" debugger     debugger     claude
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" coder-1      coder        claude
bash "$ORCHESTRATION_HOME/lib/spawn-agent.sh" qa           qa           claude
