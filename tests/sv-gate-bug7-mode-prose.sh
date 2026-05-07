#!/bin/zsh
# SV gate — P1 (native-agent-revert plan v7): slash-command mode-label contract.
#
# Six grep/awk guards verify that `src/commands/rlp-desk.md` preserves the
# canonical slash-command mode contract:
#   - `--mode native` is the default Native Agent() leader path.
#   - `--mode tmux` is the zsh leader (production) path.
#   - Legacy `--mode agent` redirects to native (deprecation prose only).
#   - Direct Node CLI `--mode agent` lives in its own contrast paragraph.
#   - Native Agent() Safety Contract block holds 4 sentinel phrases.
#   - Worker dispatch snippets retain `Agent(... mode="bypassPermissions" ...)`
#     and `Bash("codex exec ...")`.
#
# Pattern mirrored from tests/sv-gate-fast.sh.

set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
cd "$ROOT" || exit 1

PASS=0
FAIL=0
TOTAL=0

red()    { print -P "%F{red}$*%f"; }
green()  { print -P "%F{green}$*%f"; }
yellow() { print -P "%F{yellow}$*%f"; }
bold()   { print -P "%B$*%b"; }

guard() {
  local name="$1"; shift
  TOTAL=$(( TOTAL + 1 ))
  if "$@"; then
    green "  ✓ ${name}"
    PASS=$(( PASS + 1 ))
  else
    red "  ✗ ${name}"
    FAIL=$(( FAIL + 1 ))
  fi
}

bold "▶ P1 mode-prose contract guards"

FILE="src/commands/rlp-desk.md"

# Capture awk-windowed sections to tmp files (avoids variable word-splitting).
SAFETY_BLOCK=$(mktemp -t bug7-mode-prose-safety.XXXXXX)
DISP_CLAUDE=$(mktemp -t bug7-mode-prose-disp-claude.XXXXXX)
DISP_CODEX=$(mktemp -t bug7-mode-prose-disp-codex.XXXXXX)
OPTIONS_BLOCK=$(mktemp -t bug7-mode-prose-options.XXXXXX)
trap 'rm -f "$SAFETY_BLOCK" "$DISP_CLAUDE" "$DISP_CODEX" "$OPTIONS_BLOCK"' EXIT

# Use sed for ranges so the start line that *also* matches the stop pattern
# does not collapse the window to a single line (awk's classic gotcha).
sed -n '/^### Native Agent() Safety Contract/,/^#### Direct Node CLI/p' "$FILE" > "$SAFETY_BLOCK"
sed -n '/^If claude engine (default):/,/^If codex engine:/p'             "$FILE" > "$DISP_CLAUDE"
sed -n '/^If codex engine:/,/^- Agent returns synchronously/p'           "$FILE" > "$DISP_CODEX"
sed -n '/^Options (parse from/,/^- `--worker-model/p'                    "$FILE" > "$OPTIONS_BLOCK"

# 1. count-aware: --mode native 최소 5회 등장
NATIVE_COUNT=$(grep -c '\-\-mode native' "$FILE")
guard "G1 --mode native appears >=5 times (got ${NATIVE_COUNT})" \
  test "$NATIVE_COUNT" -ge 5

# 2. block-aware: Safety Contract block has all 4 sentinel phrases
guard "G2a Turn-keepalive sentinel inside Safety Contract block" \
  grep -qE 'Turn-keepalive.*every status report uses' "$SAFETY_BLOCK"
guard "G2b no-subagent_type sentinel inside Safety Contract block" \
  grep -q 'no `subagent_type` parameter' "$SAFETY_BLOCK"
guard "G2c bypassPermissions mandatory sentinel inside Safety Contract block" \
  grep -qE 'bypassPermissions.*mandatory' "$SAFETY_BLOCK"
guard "G2d long-running tmux recommendation inside Safety Contract block" \
  grep -qi 'long-running.*tmux' "$SAFETY_BLOCK"

# 3. Worker dispatch snippets preserved
guard "G3a claude worker dispatch retains Agent( call" \
  grep -q 'Agent(' "$DISP_CLAUDE"
guard "G3b claude worker dispatch retains bypassPermissions" \
  grep -q 'mode="bypassPermissions"' "$DISP_CLAUDE"
guard "G3c codex worker dispatch retains Bash codex exec" \
  grep -q 'Bash("codex exec' "$DISP_CODEX"

# 4. Options block exact match
guard "G4a Options block --mode line is the exact native|tmux form" \
  grep -qE '^- `--mode native\|tmux` \(default: `native`\)' "$OPTIONS_BLOCK"
NEG_HIT=$(grep -cE '^- `--mode agent\|tmux`' "$OPTIONS_BLOCK")
guard "G4b Options block has no stale --mode agent|tmux label (got ${NEG_HIT} stale)" \
  test "$NEG_HIT" -eq 0

# 5. Tmux IMPORTANT RULES contradiction removed
ALWAYS_HIT=$(grep -c 'always invokes node ~/.claude/ralph-desk/node/run.mjs run --mode tmux' "$FILE")
guard "G5 stale 'always invokes node' contradiction is gone (got ${ALWAYS_HIT} hits)" \
  test "$ALWAYS_HIT" -eq 0

# 6. Legacy redirect prose present
guard "G6 deprecation+redirect prose present" \
  grep -q 'Legacy.*--mode agent.*redirect' "$FILE"

print ""
bold "─────────────────────────────────────────────────"
if (( FAIL == 0 )); then
  green "▶ P1 mode-prose: ${PASS}/${TOTAL} pass"
  exit 0
else
  red "▶ P1 mode-prose: ${PASS}/${TOTAL} pass, ${FAIL} FAIL — DO NOT COMMIT"
  exit 1
fi
