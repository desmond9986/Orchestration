#!/usr/bin/env bash
# install.sh — set up the orchestration toolkit on this machine.
#
# - Checks dependencies (tmux, jq)
# - Adds ORCHESTRATION_HOME + PATH to your shell rc (zsh or bash)
# - Makes all scripts executable
#
# Re-running is safe.

set -euo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export ORCHESTRATION_HOME="$SCRIPT_DIR"

BLUE='\033[34m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
info()  { printf "${BLUE}[install]${RESET} %s\n" "$*"; }
ok()    { printf "${GREEN}[install]${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}[install]${RESET} %s\n" "$*"; }
die()   { printf "${RED}[install]${RESET} %s\n" "$*" >&2; exit 1; }

info "checking dependencies..."
for cmd in tmux jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    warn "$cmd is not installed. Install with: brew install $cmd"
    MISSING_DEPS=1
  else
    ok "found: $cmd"
  fi
done
# CLI readiness polling hashes tmux pane content. Any of these works;
# shasum ships with macOS, sha1sum with GNU coreutils, cksum is POSIX.
if command -v shasum >/dev/null 2>&1 \
   || command -v sha1sum >/dev/null 2>&1 \
   || command -v cksum >/dev/null 2>&1; then
  ok "found: shasum/sha1sum/cksum (pane hasher)"
else
  warn "no pane hasher available (shasum, sha1sum, or cksum)"
  MISSING_DEPS=1
fi
if [[ "${MISSING_DEPS:-0}" -eq 1 ]]; then
  die "please install missing dependencies, then re-run ./install.sh"
fi

info "making scripts executable..."
chmod +x "$SCRIPT_DIR/bin/"* "$SCRIPT_DIR/lib/"*.sh "$SCRIPT_DIR/patterns/"*.sh
ok "done"

# Detect shell rc
SHELL_NAME=$(basename "${SHELL:-/bin/zsh}")
case "$SHELL_NAME" in
  zsh)  RC="$HOME/.zshrc" ;;
  bash) RC="$HOME/.bashrc" ;;
  *)    RC="$HOME/.profile" ;;
esac
info "shell detected: $SHELL_NAME (rc: $RC)"

BLOCK_START="# >>> orchestration >>>"
BLOCK_END="# <<< orchestration <<<"

if grep -q "$BLOCK_START" "$RC" 2>/dev/null; then
  ok "orchestration block already present in $RC — leaving it alone"
else
  cat >> "$RC" <<EOF

$BLOCK_START
export ORCHESTRATION_HOME="$SCRIPT_DIR"
export PATH="\$ORCHESTRATION_HOME/bin:\$PATH"
$BLOCK_END
EOF
  ok "added ORCHESTRATION_HOME + PATH to $RC"
fi

echo ""
ok "installation complete!"
echo ""
echo "Next steps:"
echo "  1. Open a new terminal (or run: source $RC)"
echo "  2. Verify: orchestrate --help"
echo "  3. Start a session: cd /your/project && orchestrate lean"
echo ""
echo "Commands available:"
echo "  orchestrate <pattern>       start a session"
echo "  orchestrate list            list available patterns"
echo "  add-agent <role> <model>    add an agent mid-session"
echo "  remove-agent <id>           remove an agent"
echo "  orch-status                 show roster + recent status"
echo "  orch-status --follow        tail the status board"
echo "  orch-doctor                 control-plane health check"
echo "  orch-enforce --on           start enforcement loop"
echo "  end-session                 archive + tear down"
