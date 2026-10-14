#!/bin/zsh
# SV gate — P1 (native-agent-revert plan v7): slash-command mode-label contract.
#
# 23 grep/awk guards (G1-G8, some looped per-file) verify that
# `src/commands/rlp-desk.md` preserves the canonical slash-command mode
# contract:
#   - `--mode native` is the default Native Agent() leader path.
#   - `--mode tmux` is the zsh leader (production) path.
#   - Legacy `--mode agent` redirects to native (deprecation prose only).
#   - Direct Node CLI `--mode agent` lives in its own contrast paragraph.
#   - Native Agent() Safety Contract block holds 4 sentinel phrases.
#   - Worker dispatch snippets retain `Agent(... mode="bypassPermissions" ...)`
#     and `Bash("OMX_STATE_ROOT='...' codex exec ...")`.
#   - No `subagent_type=` leaks back into governance.md/rlp-desk.md/docs (G7).
#   - The safety block states the real permission mechanism (subagents inherit the
#     leader session's permission mode; `mode=` is ignored), carries no
#     unconditional-immunity claim and recommends no mode (G2c', G2e-G2i, G8a/G8b).
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
guard "G2c' bypassPermissions-is-ignored sentinel inside Safety Contract block" \
  grep -qE 'bypassPermissions.*ignored' "$SAFETY_BLOCK"
guard "G2d long-running tmux recommendation inside Safety Contract block" \
  grep -qi 'long-running.*tmux' "$SAFETY_BLOCK"
# Addendum-5: the block states the real mechanism and nothing stronger.
guard "G2e inherited-permission-mode sentence inside Safety Contract block" \
  grep -q "inherit the leader session.s permission mode" "$SAFETY_BLOCK"
STALE_HIT=$(grep -cE -e 'fails to suppress' -e 'bypassPermissions.*mandatory' -e "under the platform's bypass" -e 'overrode .bypassPermissions' "$FILE" || true)
guard "G2f no stale bypass-claim phrase anywhere in rlp-desk.md (got ${STALE_HIT})" \
  test "${STALE_HIT:-0}" -eq 0
# Q1 guard: facts only. Pins this narrow word list on lines about the permission mode; it does not
# prove "facts only" in general.
REC_HIT=$(grep -i 'permission mode' "$SAFETY_BLOCK" | grep -ciE -e 'recommend' -e 'should' -e 'must start' -e 'start the leader' -e 'use bypass' -e 'run the leader in' -e 'pick ' -e 'choose ' || true)
guard "G2g no mode recommendation on a permission-mode line in the Safety Contract block (got ${REC_HIT})" \
  test "${REC_HIT:-0}" -eq 0
BANNED_HIT=$(grep -ciE -e 'run non-interactively' -e 'structurally immune' -e 'cannot surface' "$SAFETY_BLOCK" || true)
guard "G2h no unconditional-immunity wording inside Safety Contract block (got ${BANNED_HIT})" \
  test "${BANNED_HIT:-0}" -eq 0
PANE_HIT=$(grep -c 'no tmux pane' "$SAFETY_BLOCK" || true)
ITEM4_HIT=$(grep -c 'item 4' "$SAFETY_BLOCK" || true)
guard "G2i block separates 'no tmux pane' from the permission-prompt pointer 'item 4' (pane ${PANE_HIT}, item4 ${ITEM4_HIT})" \
  test "$(( ${PANE_HIT:-0} > 0 && ${ITEM4_HIT:-0} > 0 ))" -eq 1

# 3. Worker dispatch snippets preserved
guard "G3a claude worker dispatch retains Agent( call" \
  grep -q 'Agent(' "$DISP_CLAUDE"
guard "G3b claude worker dispatch retains bypassPermissions" \
  grep -q 'mode="bypassPermissions"' "$DISP_CLAUDE"
# Pin re-derived 2026-09-04: every real codex dispatch template in rlp-desk.md
# is `Bash("OMX_STATE_ROOT='...' codex exec ...")`, not a bare `Bash("codex exec`
# — the OMX_STATE_ROOT prefix isolates the campaign's codex launch from the
# operator's interactive omx state (F1.18, docs/rlp-desk/failure-modes.md) and
# has been present on every template since before this pin was written, so the
# old bare-prefix grep never matched (verified failing on HEAD too, not a
# regression from any single change) — reviewed decision, updated to match.
guard "G3c codex worker dispatch retains Bash OMX_STATE_ROOT codex exec" \
  grep -q 'Bash("OMX_STATE_ROOT=.*codex exec' "$DISP_CODEX"

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

# 7. D-2 regression guard: subagent_type must never reappear in Agent() examples
# (commit 920a31c removed it from rlp-desk.md; governance.md + docs must stay in sync).
# rlp-desk.md keeps exactly one reference — the prohibition prose itself — so it is
# excluded here and checked separately with an allow-count of 1.
for DOC in src/governance.md docs/rlp-desk/architecture.md docs/rlp-desk/protocol-reference.md; do
  HIT=$(grep -c 'subagent_type=' "$DOC" 2>/dev/null || true)
  guard "G7 no subagent_type= in ${DOC} (got ${HIT:-0})" \
    test "${HIT:-0}" -eq 0
done
RLP_DESK_MD_HITS=$(grep -c 'subagent_type=' "$FILE")
guard "G7 rlp-desk.md has exactly 1 subagent_type= mention (prohibition prose only, got ${RLP_DESK_MD_HITS})" \
  test "$RLP_DESK_MD_HITS" -eq 1

# 8. Addendum-5: the inheritance fact is carried by governance §5a and architecture.md too.
guard "G8a governance.md states that subagents inherit the leader session's permission mode" \
  grep -q "inherit the leader session.s permission mode" src/governance.md
ARCH_AUTO=$(grep -c 'Autonomous execution' docs/rlp-desk/architecture.md || true)
ARCH_INH=$(grep -c "inherit the leader session.s permission mode" docs/rlp-desk/architecture.md || true)
guard "G8b architecture.md: no 'Autonomous execution' comment, states inheritance (autonomous ${ARCH_AUTO}, inherit ${ARCH_INH})" \
  test "$(( ${ARCH_AUTO:-0} == 0 && ${ARCH_INH:-0} > 0 ))" -eq 1

print ""
bold "─────────────────────────────────────────────────"
if (( FAIL == 0 )); then
  green "▶ P1 mode-prose: ${PASS}/${TOTAL} pass"
  exit 0
else
  red "▶ P1 mode-prose: ${PASS}/${TOTAL} pass, ${FAIL} FAIL — DO NOT COMMIT"
  exit 1
fi
