#!/usr/bin/env bash
# Test suite: US-006 — Init run command presets
# AC1 (3 tests) + AC2 (3 tests) + AC3 (3 tests) + L3 E2E (2 tests) = 11 total

INIT="${INIT:-src/scripts/init_ralph_desk.zsh}"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

echo "=== US-006: Init run command presets ==="
echo "Target: $INIT"
echo ""

# ── Function extraction ──────────────────────────────────────────────────────
# Extract print_run_presets() body from init script for unit isolation
FN_BODY="$(awk '
  /^print_run_presets\(\) \{/ { in_fn=1; depth=0 }
  in_fn {
    for (i=1; i<=length($0); i++) {
      c = substr($0, i, 1)
      if (c == "{") depth++
      else if (c == "}") {
        depth--
        if (depth == 0) { print; in_fn=0; next }
      }
    }
    print
  }
' "$INIT")"

if [[ -z "$FN_BODY" ]]; then
  echo "  ERROR: print_run_presets() not found in $INIT — all unit tests will FAIL (expected RED before implementation)"
fi

# ── Unit test helpers ────────────────────────────────────────────────────────

# Run print_run_presets with a fake codex binary in PATH
run_presets_with_codex() {
  local slug="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  mkdir -p "$tmpdir/bin"
  printf '#!/bin/sh\nexit 0\n' > "$tmpdir/bin/codex"
  chmod +x "$tmpdir/bin/codex"
  printf '%s\n' "$FN_BODY" > "$tmpdir/fn.zsh"
  printf '\nprint_run_presets "%s"\n' "$slug" >> "$tmpdir/fn.zsh"
  local output
  output="$(PATH="$tmpdir/bin:$PATH" zsh -f "$tmpdir/fn.zsh" 2>/dev/null)"
  rm -rf "$tmpdir"
  echo "$output"
}

# Run print_run_presets without codex (restricted PATH)
run_presets_without_codex() {
  local slug="$1"
  local tmpdir
  tmpdir="$(mktemp -d)"
  printf '%s\n' "$FN_BODY" > "$tmpdir/fn.zsh"
  printf '\nprint_run_presets "%s"\n' "$slug" >> "$tmpdir/fn.zsh"
  local output
  output="$(PATH="/usr/local/bin:/usr/bin:/bin" zsh -f "$tmpdir/fn.zsh" 2>/dev/null)"
  rm -rf "$tmpdir"
  echo "$output"
}

# ── AC1: codex detected → cross-engine presets first ────────────────────────
echo "--- AC1: codex detected → cross-engine presets ---"

# AC1-L1-1: output contains --worker-model gpt-5.4 when codex detected
test_ac1_l1_1() {
  if [[ -z "$FN_BODY" ]]; then fail "AC1-L1-1: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  if echo "$out" | grep -qF -- '--worker-model gpt-5.4'; then
    pass "AC1-L1-1: codex detected → output contains --worker-model gpt-5.4"
  else
    fail "AC1-L1-1: codex detected → --worker-model gpt-5.4 not found in output"
  fi
}

# AC1-L1-2: cross-engine preset appears before claude-only preset
test_ac1_l1_2() {
  if [[ -z "$FN_BODY" ]]; then fail "AC1-L1-2: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  local line_gpt line_basic
  line_gpt=$(echo "$out" | grep -n 'gpt-5.4' | head -1 | cut -d: -f1)
  # find the first /rlp-desk run line that has NO gpt/codex/spark (pure claude-only line)
  line_basic=$(echo "$out" | grep -n '/rlp-desk run' | grep -v 'gpt\|codex\|spark\|consensus' | head -1 | cut -d: -f1)
  if [[ -n "$line_gpt" && -n "$line_basic" ]] && (( line_gpt < line_basic )); then
    pass "AC1-L1-2: cross-engine preset (line $line_gpt) before claude-only (line $line_basic)"
  else
    fail "AC1-L1-2: cross-engine not first (gpt=$line_gpt, claude-only=$line_basic)"
  fi
}

# AC1-L1-3: actual slug name used, no <slug> placeholder
test_ac1_l1_3() {
  if [[ -z "$FN_BODY" ]]; then fail "AC1-L1-3: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "myproject")"
  local has_slug has_placeholder
  has_slug=$(echo "$out" | grep -c 'myproject')
  has_placeholder=$(echo "$out" | grep -c '<slug>')
  if (( has_slug >= 1 && has_placeholder == 0 )); then
    pass "AC1-L1-3: actual slug 'myproject' used ($has_slug times), no <slug> placeholder"
  else
    fail "AC1-L1-3: slug check failed (myproject=$has_slug, <slug>=$has_placeholder)"
  fi
}

# AC1-L1-4: first codex preset uses --final-consensus (not --verify-consensus)
# PRD AC1: "cross-engine + final-consensus preset shown first"
# --final-consensus runs consensus only on final ALL verify (cost-effective)
# --verify-consensus runs consensus on every per-US verify (expensive)
test_ac1_l1_4() {
  if [[ -z "$FN_BODY" ]]; then fail "AC1-L1-4: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  local first_run_line
  first_run_line=$(echo "$out" | grep -m1 '/rlp-desk run')
  if echo "$first_run_line" | grep -qF -- '--final-consensus'; then
    pass "AC1-L1-4: first codex preset uses --final-consensus"
  else
    fail "AC1-L1-4: first codex preset must use --final-consensus, got: '$first_run_line'"
  fi
}

test_ac1_l1_1
test_ac1_l1_2
test_ac1_l1_3
test_ac1_l1_4

# ── AC2: codex not detected → tmux first + install recommendation ────────────
echo ""
echo "--- AC2: codex not detected → tmux + install recommendation ---"

# AC2-L1-1: first /rlp-desk run command uses --mode tmux
test_ac2_l1_1() {
  if [[ -z "$FN_BODY" ]]; then fail "AC2-L1-1: function missing"; return; fi
  local out
  out="$(run_presets_without_codex "testslug")"
  local first_run
  first_run=$(echo "$out" | grep -m1 '/rlp-desk run')
  if echo "$first_run" | grep -qF -- '--mode tmux'; then
    pass "AC2-L1-1: first run command is tmux mode: $first_run"
  else
    fail "AC2-L1-1: first run command not tmux mode: '$first_run'"
  fi
}

# AC2-L1-2: codex install recommendation present
test_ac2_l1_2() {
  if [[ -z "$FN_BODY" ]]; then fail "AC2-L1-2: function missing"; return; fi
  local out
  out="$(run_presets_without_codex "testslug")"
  if echo "$out" | grep -qF 'npm install -g @openai/codex'; then
    pass "AC2-L1-2: codex install recommendation 'npm install -g @openai/codex' present"
  else
    fail "AC2-L1-2: codex install recommendation missing"
  fi
}

# AC2-L1-3: no gpt-5.4 preset shown when codex not installed
test_ac2_l1_3() {
  if [[ -z "$FN_BODY" ]]; then fail "AC2-L1-3: function missing"; return; fi
  local out
  out="$(run_presets_without_codex "testslug")"
  local gpt_count
  gpt_count=$(echo "$out" | grep -c -- '--worker-model gpt-5.4')
  if (( gpt_count == 0 )); then
    pass "AC2-L1-3: no gpt-5.4 run preset when codex not installed"
  else
    fail "AC2-L1-3: unexpected gpt-5.4 preset shown without codex (count=$gpt_count)"
  fi
}

test_ac2_l1_1
test_ac2_l1_2
test_ac2_l1_3

# ── AC3: full option list with defaults ──────────────────────────────────────
echo ""
echo "--- AC3: full option list with defaults ---"

# AC3-L1-1: --worker-model listed with default annotation
test_ac3_l1_1() {
  if [[ -z "$FN_BODY" ]]; then fail "AC3-L1-1: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  if echo "$out" | grep -qE -- '--worker-model.*(default|sonnet)'; then
    pass "AC3-L1-1: --worker-model listed with default annotation"
  else
    fail "AC3-L1-1: --worker-model missing or no default annotation"
  fi
}

# AC3-L1-2: --verifier-model listed with default annotation
test_ac3_l1_2() {
  if [[ -z "$FN_BODY" ]]; then fail "AC3-L1-2: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  if echo "$out" | grep -qE -- '--verifier-model.*(default|opus)'; then
    pass "AC3-L1-2: --verifier-model listed with default annotation"
  else
    fail "AC3-L1-2: --verifier-model missing or no default annotation"
  fi
}

# AC3-L1-3: --max-iter listed with default annotation
test_ac3_l1_3() {
  if [[ -z "$FN_BODY" ]]; then fail "AC3-L1-3: function missing"; return; fi
  local out
  out="$(run_presets_with_codex "testslug")"
  if echo "$out" | grep -qE -- '--max-iter.*(default|100)'; then
    pass "AC3-L1-3: --max-iter listed with default annotation"
  else
    fail "AC3-L1-3: --max-iter missing or no default annotation"
  fi
}

test_ac3_l1_1
test_ac3_l1_2
test_ac3_l1_3

# ── L3 E2E: Full init run ────────────────────────────────────────────────────
echo ""
echo "--- L3 E2E: Full init output ---"

L3_BASE="$(mktemp -d)"
trap 'rm -rf "$L3_BASE"' EXIT

# L3-E2E-1: full init with codex → gpt-5.4 preset in output
test_l3_e2e_1() {
  local test_dir="$L3_BASE/e2e1"
  mkdir -p "$test_dir"
  local bin_dir="$test_dir/bin"
  mkdir -p "$bin_dir"
  printf '#!/bin/sh\nexit 0\n' > "$bin_dir/codex"
  chmod +x "$bin_dir/codex"
  local output
  output=$(ROOT="$test_dir" PATH="$bin_dir:$PATH" zsh "$INIT" "testslug-e2e" 2>/dev/null)
  if echo "$output" | grep -qF 'gpt-5.4'; then
    pass "L3-E2E-1: full init with codex → gpt-5.4 preset present in output"
  else
    fail "L3-E2E-1: gpt-5.4 missing in init output (last 8 lines: $(echo "$output" | tail -8 | tr '\n' '|'))"
  fi
}

# L3-E2E-2: full init without codex → install recommendation in output
# Use env -i + zsh -f to prevent startup files from restoring dotfiles PATH
test_l3_e2e_2() {
  local test_dir="$L3_BASE/e2e2"
  mkdir -p "$test_dir"
  # Exclude /opt/homebrew/bin to hide codex (codex is there); jq is at /usr/bin/jq
  local safe_path="/usr/local/bin:/usr/bin:/bin"
  local output
  output=$(env -i ROOT="$test_dir" HOME="$HOME" PATH="$safe_path" zsh -f "$INIT" "testslug-e2e" 2>/dev/null)
  if echo "$output" | grep -qF 'npm install -g @openai/codex'; then
    pass "L3-E2E-2: full init without codex → install recommendation shown"
  else
    fail "L3-E2E-2: install recommendation missing (last 8 lines: $(echo "$output" | tail -8 | tr '\n' '|'))"
  fi
}

test_l3_e2e_1
test_l3_e2e_2

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

(( FAIL > 0 )) && exit 1
exit 0
