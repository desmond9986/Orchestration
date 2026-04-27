#!/usr/bin/env bash
# model-select.sh — interactive model-choice questionnaire for orchestrate.
#
# Reads the "# AskModels: role:default ..." metadata line from a pattern file,
# then prompts once per unique role:
#   1. Which model?
#   2. Skip permissions? (adds --dangerously-skip-permissions / --yolo)
#
# Exports per-role:
#   ORCH_MODEL_<role>              — model name
#   ORCH_SKIP_PERMISSIONS_<role>   — "1" or "0"
#
# spawn-agent.sh treats ORCH_SKIP_PERMISSIONS=1 as a launch-wide bypass.
# Per-role ORCH_SKIP_PERMISSIONS_<role>=1 can also opt in one role.
#
# Skipped when stdin is not a tty (piped/scripted invocations keep defaults).
#
# Sourced by orchestrate — not meant to be run directly.

KNOWN_MODELS=(claude codex gemini shell none)

# _yn_to_1 <answer>  — normalises y/yes/1 (case-insensitive) → "1", else → "0"
# Uses glob patterns instead of ${1,,} to stay compatible with bash 3.2.
_yn_to_1() {
  case "$1" in
    [yY]|[yY][eE][sS]|1) echo "1" ;;
    *) echo "0" ;;
  esac
}

# ask_model_choices <pattern_file>
# Side-effects: exports ORCH_MODEL_<role> and ORCH_SKIP_PERMISSIONS_<role>
# for each role found in the AskModels metadata line.
ask_model_choices() {
  local pattern_file="$1"

  local meta
  meta=$(grep -m1 '^# AskModels:' "$pattern_file" 2>/dev/null || true)
  meta=$(printf "%s" "$meta" | sed 's/^# AskModels: *//')
  [[ -n "$meta" ]] || return 0

  # Non-interactive: apply defaults silently, honour pre-set env vars.
  if [[ ! -t 0 ]]; then
    for pair in $meta; do
      local role="${pair%%:*}" default="${pair#*:}"
      local mv="ORCH_MODEL_${role}" pv="ORCH_SKIP_PERMISSIONS_${role}"
      [[ -z "${!mv:-}" ]] && export "ORCH_MODEL_${role}=${default}"
      [[ -z "${!pv:-}" ]] && export "ORCH_SKIP_PERMISSIONS_${role}=${ORCH_SKIP_PERMISSIONS:-0}"
    done
    return 0
  fi

  printf "\n\033[1m[orchestrate] Configure agents for this session\033[0m\n"
  printf "  Enter to accept defaults [in brackets].\n"
  printf "  Models: %s\n\n" "$(IFS=", "; echo "${KNOWN_MODELS[*]}")"

  for pair in $meta; do
    local role="${pair%%:*}" default="${pair#*:}"
    local mv="ORCH_MODEL_${role}" pv="ORCH_SKIP_PERMISSIONS_${role}"

    # Model question
    if [[ -n "${!mv:-}" ]]; then
      printf "  %-14s model: pre-set → %s\n" "$role" "${!mv}"
    else
      local answer
      printf "  %-14s model [%s]: " "$role" "$default"
      read -r answer </dev/tty
      answer="${answer:-$default}"
      export "ORCH_MODEL_${role}=${answer}"
    fi

    # Permissions question (skip if already set via env)
    if [[ -n "${!pv:-}" ]]; then
      local label; [[ "${!pv}" == "1" ]] && label="yes" || label="no"
      printf "  %-14s skip permissions: pre-set → %s\n" "" "$label"
    else
      local skip_answer
      printf "  %-14s skip permissions (y/N): " ""
      read -r skip_answer </dev/tty
      export "ORCH_SKIP_PERMISSIONS_${role}=$(_yn_to_1 "${skip_answer:-n}")"
    fi

    printf "\n"
  done
}
