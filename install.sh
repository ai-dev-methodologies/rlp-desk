#!/bin/bash
set -euo pipefail

# =============================================================================
# RLP Desk Installer
#
# Installs the RLP Desk slash command and support files into ~/.claude/
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main/install.sh | bash
#
# Safe to run multiple times (idempotent).
# =============================================================================

REPO_URL="https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main"
CLAUDE_DIR="$HOME/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
DESK_DIR="$CLAUDE_DIR/ralph-desk"

echo ""
echo "  RLP Desk Installer"
echo "  ==================="
echo ""

# Create directories
mkdir -p "$COMMANDS_DIR"
mkdir -p "$DESK_DIR"

# Download slash command
echo "  Downloading slash command..."
curl -sSL "$REPO_URL/src/commands/rlp-desk.md" -o "$COMMANDS_DIR/rlp-desk.md"

# Download init script
echo "  Downloading init script..."
curl -sSL "$REPO_URL/src/scripts/init_ralph_desk.zsh" -o "$DESK_DIR/init_ralph_desk.zsh"
chmod +x "$DESK_DIR/init_ralph_desk.zsh"

# Download tmux runner script
echo "  Downloading tmux runner script..."
curl -sSL "$REPO_URL/src/scripts/run_ralph_desk.zsh" -o "$DESK_DIR/run_ralph_desk.zsh"
chmod +x "$DESK_DIR/run_ralph_desk.zsh"

# Download governance protocol
echo "  Downloading governance protocol..."
curl -sSL "$REPO_URL/src/governance.md" -o "$DESK_DIR/governance.md"

# Check tmux availability
if ! command -v tmux &>/dev/null; then
  echo ""
  echo "  [warn] tmux not found. Tmux execution mode (--mode tmux) will not be available."
  echo "         Install tmux to use lean mode: https://github.com/tmux/tmux/wiki/Installing"
fi

echo ""
echo "  Done! Installed to:"
echo ""
echo "    Slash command:  $COMMANDS_DIR/rlp-desk.md"
echo "    Init script:    $DESK_DIR/init_ralph_desk.zsh"
echo "    Tmux runner:    $DESK_DIR/run_ralph_desk.zsh"
echo "    Governance:     $DESK_DIR/governance.md"
echo ""
echo "  Usage:"
echo "    1. Open Claude Code in your project directory"
echo "    2. Run: /rlp-desk brainstorm \"your task description\""
echo "    3. Run: /rlp-desk run <slug>"
echo "    4. Run: /rlp-desk run <slug> --mode tmux  (lean mode)"
echo ""
