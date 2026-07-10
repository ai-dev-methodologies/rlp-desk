#!/usr/bin/env bash
# Test Suite: codex TUI ready detection accepts both prompt glyphs
# Bug (dogfood 2026-07-10): codex 0.144 renders its input prompt as ❯ (U+276F);
# the worker/verifier launch ready-loops grepped only › (U+203A, the 0.141
# glyph), so a healthy 0.144 codex pane was declared "not ready after 30s",
# the instruction was never sent, and the campaign BLOCKED on a verdict
# timeout. The stall/paste path (~line 1484-1495) already accepted ❯ — the
# two launch ready-loops were the only stale sites.
# Also: that failure was reported as "Consensus verification failed after max
# rounds" / repeat_axis — factually wrong (round 1, infrastructure). The
# sentinel must say what happened and use the infra_failure category.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT/src/scripts/run_ralph_desk.zsh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

READY_PATTERN='[›❯]'

# --- Behavioral: the ready pattern must match both generations' pane text ---
printf '╭ workdir ─ main\n❯\n' | grep -qE "$READY_PATTERN" \
  && pass "behavioral: 0.144 pane (❯ prompt) matches the ready pattern" \
  || fail "behavioral: 0.144 pane (❯ prompt) does not match"
printf 'OpenAI Codex (v0.141.0)\n›\n' | grep -qE "$READY_PATTERN" \
  && pass "behavioral: 0.141 pane (› prompt) still matches" \
  || fail "behavioral: 0.141 pane (› prompt) no longer matches"
printf 'loading model catalog...\n' | grep -qE "$READY_PATTERN" \
  && fail "behavioral: promptless boot text wrongly matches" \
  || pass "behavioral: promptless boot text does not match (no false-ready)"

# --- Structural: BOTH launch ready-loops use the dual-glyph pattern ---
n_sites=$(grep -c "grep -qE '\[›❯\]'" "$RUN")
[[ "$n_sites" -eq 2 ]] \
  && pass "structural: both launch ready-loops accept ›|❯ ($n_sites sites)" \
  || fail "structural: expected 2 dual-glyph ready sites, got $n_sites"

# --- Structural: no launch ready-loop still greps the single legacy glyph ---
n_stale=$(grep -c "grep -q '›'" "$RUN")
[[ "$n_stale" -eq 0 ]] \
  && pass "structural: no single-glyph '›' ready grep remains" \
  || fail "structural: $n_stale stale single-glyph ready grep(s) remain"

# --- Structural: consensus hard-failure sentinel is accurate (infra, not max-rounds) ---
grep -q 'write_blocked_sentinel "Consensus verification failed (verifier/infra error before verdict)" "" "infra_failure"' "$RUN" \
  && pass "structural: consensus hard-failure sentinel says infra_failure with accurate reason" \
  || fail "structural: consensus hard-failure sentinel still claims max-rounds/repeat_axis"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
exit $(( FAIL > 0 ))
