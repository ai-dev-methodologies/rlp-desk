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

# v5.7 §4.4: REPO_URL overridable for offline/local testing (test fixture).
REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main}"
CLAUDE_DIR="$HOME/.claude"
COMMANDS_DIR="$CLAUDE_DIR/commands"
DESK_DIR="$CLAUDE_DIR/ralph-desk"
NODE_DIR="$DESK_DIR/node"

# v5.7 §4.4 / Q3: Node ≥16 preflight (matches scripts/postinstall.js policy).
if command -v node &>/dev/null; then
  NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]" 2>/dev/null || echo 0)
  if [[ "$NODE_MAJOR" -lt 16 ]]; then
    echo "  [warn] Node.js >= 16 required for the Node leader (--mode tmux flywheel/SV)."
    echo "         Found Node $NODE_MAJOR. Continuing zsh install; --mode tmux features will be unavailable."
  fi
else
  echo "  [warn] node not found in PATH. Node leader features (--flywheel, --with-self-verification in tmux) unavailable."
  echo "         Install Node.js >= 16: https://nodejs.org/"
fi

echo ""
echo "  RLP Desk Installer"
echo "  ==================="
echo ""

# Create directories
mkdir -p "$COMMANDS_DIR"
mkdir -p "$DESK_DIR"
mkdir -p "$DESK_DIR/docs/rlp-desk/internal"
mkdir -p "$DESK_DIR/docs/rlp-desk/blueprints"
mkdir -p "$DESK_DIR/docs/rlp-desk/plans"
mkdir -p "$NODE_DIR"

# v5.7 §4.10 helpers — chmod-before-curl (unlock prior install) + chmod a-w
# (lock down). Hard-fail per Architect (no `2>/dev/null || true` swallowing).
unlock_target() {
  local target="$1"
  if [[ -e "$target" ]]; then
    chmod u+w "$target" || {
      echo "  [install] FATAL: cannot unlock existing $target. Filesystem may be read-only."
      exit 1
    }
  fi
}
lock_target() {
  local target="$1"
  if ! chmod a-w "$target" 2>/dev/null; then
    echo "  [install] WARNING: chmod a-w failed on $target. Filesystem may not honor POSIX mode bits (WSL1/NTFS); cross-session edit protection unavailable."
  fi
}
fetch() {
  local url="$1" target="$2"
  unlock_target "$target"
  curl -fsSL "$url" -o "$target" || {
    echo "  [install] FATAL: download failed for $url"
    exit 1
  }
  lock_target "$target"
}

# Runtime files
echo "  Downloading runtime files..."
fetch "$REPO_URL/src/commands/rlp-desk.md" "$COMMANDS_DIR/rlp-desk.md"
fetch "$REPO_URL/src/scripts/init_ralph_desk.zsh" "$DESK_DIR/init_ralph_desk.zsh"
fetch "$REPO_URL/src/scripts/run_ralph_desk.zsh" "$DESK_DIR/run_ralph_desk.zsh"
fetch "$REPO_URL/src/scripts/lib_ralph_desk.zsh" "$DESK_DIR/lib_ralph_desk.zsh"
fetch "$REPO_URL/src/governance.md" "$DESK_DIR/governance.md"
fetch "$REPO_URL/src/model-upgrade-table.md" "$DESK_DIR/model-upgrade-table.md"

# v5.7 §4.4 — Node leader files (manifest-driven, prevents drift).
echo "  Downloading Node leader runtime via MANIFEST.txt..."
MANIFEST_TMP=$(mktemp)
unlock_target "$NODE_DIR/MANIFEST.txt"
curl -fsSL "$REPO_URL/src/node/MANIFEST.txt" -o "$MANIFEST_TMP" || {
  echo "  [install] WARNING: src/node/MANIFEST.txt unavailable. Node leader features will be missing."
  echo "             Update install.sh from a 0.12.0+ source if upgrading."
  MANIFEST_TMP=""
}
if [[ -n "$MANIFEST_TMP" && -s "$MANIFEST_TMP" ]]; then
  cp "$MANIFEST_TMP" "$NODE_DIR/MANIFEST.txt"
  while IFS= read -r relpath; do
    [[ -z "$relpath" ]] && continue
    target="$NODE_DIR/$relpath"
    mkdir -p "$(dirname "$target")"
    fetch "$REPO_URL/src/node/$relpath" "$target"
  done < "$MANIFEST_TMP"
  lock_target "$NODE_DIR/MANIFEST.txt"
  rm -f "$MANIFEST_TMP"
fi

# Note: chmod +x is NOT needed — runtime files are invoked via `zsh script.zsh`
# or `node script.mjs`, never directly. lock_target above already chmod a-w'd
# them; an explicit chmod +x would re-add write to other.

# Reference docs (v5.7 §4.4 follow-up: same fetch() helper handles unlock+lock
# so reference-doc upgrade-over-installed-and-locked file does not silently fail).
echo "  Downloading reference docs..."
fetch "$REPO_URL/README.md" "$DESK_DIR/README.md"
fetch "$REPO_URL/install.sh" "$DESK_DIR/install.sh"
fetch "$REPO_URL/docs/rlp-desk/architecture.md" "$DESK_DIR/docs/rlp-desk/architecture.md"
fetch "$REPO_URL/docs/rlp-desk/getting-started.md" "$DESK_DIR/docs/rlp-desk/getting-started.md"
fetch "$REPO_URL/docs/rlp-desk/protocol-reference.md" "$DESK_DIR/docs/rlp-desk/protocol-reference.md"
fetch "$REPO_URL/docs/rlp-desk/TODO-verification-next.md" "$DESK_DIR/docs/rlp-desk/TODO-verification-next.md"
fetch "$REPO_URL/docs/rlp-desk/multi-mission-orchestration.md" "$DESK_DIR/docs/rlp-desk/multi-mission-orchestration.md"
# Dev meta docs (v5.7 §4.15: under docs/rlp-desk/ to avoid mixing with user docs)
fetch "$REPO_URL/docs/rlp-desk/internal/verification-policy-gap-analysis.md" "$DESK_DIR/docs/rlp-desk/internal/verification-policy-gap-analysis.md"
fetch "$REPO_URL/docs/rlp-desk/internal/verification-strategy-research.md" "$DESK_DIR/docs/rlp-desk/internal/verification-strategy-research.md"
fetch "$REPO_URL/docs/rlp-desk/blueprints/blueprint-flywheel-enhancement.md" "$DESK_DIR/docs/rlp-desk/blueprints/blueprint-flywheel-enhancement.md"
fetch "$REPO_URL/docs/rlp-desk/blueprints/blueprint-pivot-step.md" "$DESK_DIR/docs/rlp-desk/blueprints/blueprint-pivot-step.md"
fetch "$REPO_URL/docs/rlp-desk/blueprints/plan-flywheel-enhancement.md" "$DESK_DIR/docs/rlp-desk/blueprints/plan-flywheel-enhancement.md"
fetch "$REPO_URL/docs/rlp-desk/blueprints/sv-architecture-rethink.md" "$DESK_DIR/docs/rlp-desk/blueprints/sv-architecture-rethink.md"

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
