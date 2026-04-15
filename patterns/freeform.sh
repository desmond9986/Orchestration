#!/usr/bin/env bash
# Description: Empty session. You spawn agents manually with add-agent.
#
# Use when: you don't know the team shape upfront, or the session will
# evolve over time. Starts with just a shell pane ready for you to add
# agents when needed.

set -euo pipefail
: "${ORCHESTRATION_HOME:=$HOME/orchestration}"
source "$ORCHESTRATION_HOME/lib/common.sh"
source "$ORCHESTRATION_HOME/lib/tmux-helpers.sh"

SESSION="freeform"
bash "$ORCHESTRATION_HOME/lib/roster.sh" init "$SESSION"
init_session "$SESSION" >/dev/null

info "freeform session ready. Add agents with:"
info "  add-agent <role> <model> [--hats ...] [--id ...]"
info "Example: add-agent orchestrator claude"
