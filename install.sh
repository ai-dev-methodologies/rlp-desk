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
mkdir -p "$DESK_DIR/docs/internal"
mkdir -p "$DESK_DIR/docs/blueprints"

# Runtime files
echo "  Downloading runtime files..."
curl -sSL "$REPO_URL/src/commands/rlp-desk.md" -o "$COMMANDS_DIR/rlp-desk.md"
curl -sSL "$REPO_URL/src/scripts/init_ralph_desk.zsh" -o "$DESK_DIR/init_ralph_desk.zsh"
curl -sSL "$REPO_URL/src/scripts/run_ralph_desk.zsh" -o "$DESK_DIR/run_ralph_desk.zsh"
curl -sSL "$REPO_URL/src/scripts/lib_ralph_desk.zsh" -o "$DESK_DIR/lib_ralph_desk.zsh"
curl -sSL "$REPO_URL/src/governance.md" -o "$DESK_DIR/governance.md"
curl -sSL "$REPO_URL/src/model-upgrade-table.md" -o "$DESK_DIR/model-upgrade-table.md"
chmod +x "$DESK_DIR/init_ralph_desk.zsh" "$DESK_DIR/run_ralph_desk.zsh" "$DESK_DIR/lib_ralph_desk.zsh"

# Reference docs
echo "  Downloading reference docs..."
curl -sSL "$REPO_URL/README.md" -o "$DESK_DIR/README.md"
curl -sSL "$REPO_URL/install.sh" -o "$DESK_DIR/install.sh"
curl -sSL "$REPO_URL/docs/architecture.md" -o "$DESK_DIR/docs/architecture.md"
curl -sSL "$REPO_URL/docs/getting-started.md" -o "$DESK_DIR/docs/getting-started.md"
curl -sSL "$REPO_URL/docs/protocol-reference.md" -o "$DESK_DIR/docs/protocol-reference.md"
curl -sSL "$REPO_URL/docs/TODO-verification-next.md" -o "$DESK_DIR/docs/TODO-verification-next.md"
curl -sSL "$REPO_URL/docs/internal/verification-policy-gap-analysis.md" -o "$DESK_DIR/docs/internal/verification-policy-gap-analysis.md"
curl -sSL "$REPO_URL/docs/internal/verification-strategy-research.md" -o "$DESK_DIR/docs/internal/verification-strategy-research.md"
curl -sSL "$REPO_URL/docs/blueprints/blueprint-v0.4-evolution.md" -o "$DESK_DIR/docs/blueprints/blueprint-v0.4-evolution.md"

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
