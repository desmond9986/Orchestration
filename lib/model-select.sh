#!/usr/bin/env bash
# model-select.sh — interactive model-choice questionnaire for orchestrate.
#
# Reads the "# AskModels: role:default ..." metadata line from a pattern file,
# then prompts the user once per unique role. Exports ORCH_MODEL_<role> so
# pattern scripts can substitute model names without hardcoding them.
#
# Skipped when stdin is not a tty (piped/scripted invocations keep defaults).
#
# Sourced by orchestrate — not meant to be run directly.

# Valid model names for tab-completion hint in prompt.
KNOWN_MODELS=(claude codex gemini shell none)

# ask_model_choices <pattern_file>
# Side-effect: exports ORCH_MODEL_<role> for each role found in AskModels.
ask_model_choices() {
  local pattern_file="$1"

  # Pull the AskModels line (e.g. "# AskModels: orchestrator:claude coder:claude")
  local meta
  meta=$(grep -m1 '^# AskModels:' "$pattern_file" 2>/dev/null \
         | sed 's/^# AskModels: *//')
  [[ -n "$meta" ]] || return 0        # no metadata → skip questionnaire

  # Stdin must be a tty; otherwise use defaults silently.
  if [[ ! -t 0 ]]; then
    for pair in $meta; do
      local role="${pair%%:*}" default="${pair#*:}"
      local varname="ORCH_MODEL_${role}"
      [[ -z "${!varname:-}" ]] && export "ORCH_MODEL_${role}=${default}"
    done
    return 0
  fi

  printf "\n\033[1m[orchestrate] Choose models for this session\033[0m\n"
  printf "  Press Enter to accept the default shown in [brackets].\n"
  printf "  Available: %s\n\n" "$(IFS=", "; echo "${KNOWN_MODELS[*]}")"

  for pair in $meta; do
    local role="${pair%%:*}" default="${pair#*:}"
    local varname="ORCH_MODEL_${role}"

    # Honour an already-exported value (allows pre-setting via env).
    if [[ -n "${!varname:-}" ]]; then
      printf "  %-18s using pre-set: %s\n" "$role" "${!varname}"
      continue
    fi

    local answer
    printf "  Model for %-12s [%s]: " "$role" "$default"
    read -r answer </dev/tty
    answer="${answer:-$default}"
    export "ORCH_MODEL_${role}=${answer}"
    printf "    → %s\n" "$answer"
  done

  printf "\n"
}
