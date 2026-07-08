#!/usr/bin/env bash
# Test Suite: metadata.json consensus field must derive from unified CONSENSUS_MODE
# Bug: line ~3464 wrote `--argjson consensus "${VERIFY_CONSENSUS:-0}"`, but v0.16+
# unified consensus control into CONSENSUS_MODE (off|all|final-only). Legacy
# VERIFY_CONSENSUS/FINAL_CONSENSUS are only mapped INTO CONSENSUS_MODE at module
# top (not read directly by the metadata writer), so a campaign started with
# `--consensus all|final-only` or `--final-consensus` has CONSENSUS_MODE active
# while VERIFY_CONSENSUS stays 0 -> metadata.json falsely reports consensus: 0.
#
# Contract (decided, not redesigned here): metadata.json `consensus` stays a
# 0/1 number. It must be 1 iff CONSENSUS_MODE != "off", else 0.
#
# The DEBUG gate at line ~3508 has the same legacy-var bug: it checks
# VERIFY_CONSENSUS instead of CONSENSUS_MODE, so the consensus_flow debug line
# never fires for CLI-driven consensus modes. Fixed gate must fire iff
# CONSENSUS_MODE != "off" and mention the active mode.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
assert_eq() {
  local got="$1" expected="$2" label="$3"
  if [[ "$got" == "$expected" ]]; then pass "$label"; else fail "$label (got '$got', expected '$expected')"; fi
}

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# Helper: given a slug, create an isolated scaffold dir and echo it back.
# The runner writes metadata.json (and the hash-free "$SLUG.current" analytics
# pointer, IMP-03) early in main(), before scaffold validation fails on the
# missing prompts/context/memory files -- so the process exits fast (~0.1s)
# and metadata.json is already on disk by then. Same "start, capture, exit
# fast" harness style as test_us005_final_consensus.sh's AC1-L1-5 / L3-E2E-2.
_new_scaffold() {
  local slug="$1"
  local tmp
  tmp="$(mktemp -d)"; TMPDIRS+=("$tmp")
  mkdir -p "$tmp/.rlp-desk/logs/$slug"
  echo "$tmp"
}

# Helper: read the `consensus` field out of a scaffold's metadata.json via the
# analytics pointer file. Echoes NO_POINTER / NO_METADATA on missing files so
# assert_eq failures are self-explanatory instead of silently empty.
_read_consensus() {
  local tmp="$1" slug="$2"
  local pointer="$tmp/.rlp-desk/analytics/${slug}.current"
  if [[ ! -f "$pointer" ]]; then
    echo "NO_POINTER"
    return
  fi
  local analytics_dir
  analytics_dir="$(cat "$pointer")"
  if [[ ! -f "$analytics_dir/metadata.json" ]]; then
    echo "NO_METADATA"
    return
  fi
  jq -r '.consensus' "$analytics_dir/metadata.json" 2>/dev/null || echo "JQ_ERROR"
}

echo "=== Consensus metadata.json mode reproducer ==="
echo ""

# ============================================================
# (a) happy: --consensus all -> metadata consensus == 1
# ============================================================
A_TMP=$(_new_scaffold "consall")
LOOP_NAME=consall ROOT="$A_TMP" TMUX=test zsh "$RUN" --consensus all >/dev/null 2>&1 || true
assert_eq "$(_read_consensus "$A_TMP" consall)" "1" "(a) --consensus all -> metadata.json consensus == 1"

# ============================================================
# (b) happy: --final-consensus (legacy flag -> CONSENSUS_MODE=final-only) -> 1
# ============================================================
B_TMP=$(_new_scaffold "consfc")
LOOP_NAME=consfc ROOT="$B_TMP" TMUX=test zsh "$RUN" --final-consensus >/dev/null 2>&1 || true
assert_eq "$(_read_consensus "$B_TMP" consfc)" "1" "(b) --final-consensus -> metadata.json consensus == 1"

# ============================================================
# (c) negative: no consensus flags -> 0
# ============================================================
C_TMP=$(_new_scaffold "consnone")
LOOP_NAME=consnone ROOT="$C_TMP" TMUX=test zsh "$RUN" >/dev/null 2>&1 || true
assert_eq "$(_read_consensus "$C_TMP" consnone)" "0" "(c) no consensus flags -> metadata.json consensus == 0"

# ============================================================
# (d) legacy env: VERIFY_CONSENSUS=1 -> 1 (via CONSENSUS_MODE, not the legacy var)
# ============================================================
D_TMP=$(_new_scaffold "conslegacy")
LOOP_NAME=conslegacy ROOT="$D_TMP" TMUX=test VERIFY_CONSENSUS=1 zsh "$RUN" >/dev/null 2>&1 || true
assert_eq "$(_read_consensus "$D_TMP" conslegacy)" "1" "(d) VERIFY_CONSENSUS=1 (legacy env) -> metadata.json consensus == 1"

# ============================================================
# (e) boundary: --consensus off explicitly -> 0
# ============================================================
E_TMP=$(_new_scaffold "consoff")
LOOP_NAME=consoff ROOT="$E_TMP" TMUX=test zsh "$RUN" --consensus off >/dev/null 2>&1 || true
assert_eq "$(_read_consensus "$E_TMP" consoff)" "0" "(e) --consensus off (explicit) -> metadata.json consensus == 0"

echo ""

# ============================================================
# (f) DEBUG gate: DEBUG=1 + --consensus final-only -> debug.log has a
# consensus_flow line mentioning the active mode (final-only), not gated by
# the legacy VERIFY_CONSENSUS var.
# ============================================================
F_SLUG="consdbg"
F_TMP=$(_new_scaffold "$F_SLUG")
LOOP_NAME="$F_SLUG" ROOT="$F_TMP" TMUX=test DEBUG=1 \
  zsh "$RUN" --consensus final-only >/dev/null 2>&1 || true
F_POINTER="$F_TMP/.rlp-desk/analytics/${F_SLUG}.current"
F_DEBUG_LOG=""
if [[ -f "$F_POINTER" ]]; then
  F_DEBUG_LOG="$(cat "$F_POINTER")/debug.log"
fi
if [[ -f "$F_DEBUG_LOG" ]]; then
  F_COUNT=$(grep -c "consensus_flow" "$F_DEBUG_LOG" 2>/dev/null) || F_COUNT=0
  F_MODE_COUNT=$(grep "consensus_flow" "$F_DEBUG_LOG" 2>/dev/null | grep -c "final-only") || F_MODE_COUNT=0
  if [[ "$F_COUNT" -ge 1 && "$F_MODE_COUNT" -ge 1 ]]; then
    pass "(f) DEBUG=1 + --consensus final-only -> debug.log has consensus_flow line mentioning final-only"
  else
    fail "(f) debug.log missing consensus_flow/final-only line (content: '$(cat "$F_DEBUG_LOG" 2>/dev/null)')"
  fi
else
  fail "(f) debug.log not found at expected path '$F_DEBUG_LOG'"
fi

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
