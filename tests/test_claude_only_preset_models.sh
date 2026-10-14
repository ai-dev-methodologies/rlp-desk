#!/usr/bin/env bash
# F-PRESET — the claude-only recommended TMUX run commands must carry the
# per-complexity --worker-model / --verifier-model from the "Model mapping —
# Claude-only" table.
#
# Why: a bare `/rlp-desk run <slug> --mode tmux --debug` runs the shipped
# defaults: worker `haiku`, per-US verifier `sonnet` (normalized to
# `sonnet:medium`, a floating alias that matches no table per-US cell), i.e.
# none of the table's MEDIUM/HIGH/CRITICAL tiers. The final verifier needs NO
# flag: its default `claude-fable-5-1` already resolves to
# `claude-fable-5-1:max` (run_ralph_desk.zsh bare-alias arm; Node
# BARE_ALIAS_NORMALIZATION), which equals the table's Final cell — guard G2.
#
# Scope: tmux presets ONLY. The native preset stays WITHOUT model flags: the
# native leader dispatches Agent(model=<value>) verbatim and the Agent tool's
# `model` is an alias enum with no effort parameter, so a pinned id such as
# `claude-sonnet-5-5:medium` could break a native campaign at iteration 1
# (finding F-NATIVE in the addendum). Guards M2 / N3 / I2 pin "native unchanged".
#
# Surfaces: (1) src/commands/rlp-desk.md  — the codex-NOT-installed block
# (★ tmux preset; native preset unchanged); (2) src/scripts/init_ralph_desk.zsh
# print_run_presets() — the no-codex branch (4 tmux lines, one per complexity,
# plus the unchanged native line).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MD="$REPO/src/commands/rlp-desk.md"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== F-PRESET: claude-only tmux presets carry per-complexity models ==="

# -- the Claude-only table (source of truth), parsed once ------------------
# Lines: "<COMPLEXITY>|<Worker>|<per-US Verifier>|<Final (first token)>"
TABLE="$(awk '/Model mapping — Claude-only/{f=1;next} /Model mapping — Cross-engine/{f=0} f && /^[[:space:]]*\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {
  n=split($0, c, "|"); for(i=1;i<=n;i++){gsub(/^[ \t]+|[ \t]+$/,"",c[i])}
  split(c[5], fin, " "); print c[2] "|" c[3] "|" c[4] "|" fin[1] }' "$MD")"

echo "--- G: table / premise guards (GREEN before and after) ---"
EXPECT_TABLE=$'LOW|claude-haiku-5-5:medium|claude-sonnet-5-5:high|claude-fable-5-1:max\nMEDIUM|claude-sonnet-5-5:medium|claude-opus-5-5:low|claude-fable-5-1:max\nHIGH|claude-sonnet-5-5:high|claude-opus-5-5:high|claude-fable-5-1:max\nCRITICAL|claude-opus-5-5:high|claude-opus-5-5:max|claude-fable-5-1:max'
if [[ "$TABLE" == "$EXPECT_TABLE" ]]; then
  pass "G1: Claude-only table rows parse to the expected 4 tiers"
else
  fail "G1: Claude-only table drifted. got: $(echo "$TABLE" | tr '\n' ';')"
fi

RUNSH="$REPO/src/scripts/run_ralph_desk.zsh"; CB="$REPO/src/node/cli/command-builder.mjs"; RJ="$REPO/src/node/run.mjs"
if grep -qE 'fable\|claude-fable-5-1\)[[:space:]]+model_val="claude-fable-5-1:max"' "$RUNSH" \
   && grep -qF "['claude-fable-5-1', 'claude-fable-5-1:max']" "$CB" \
   && grep -qE "finalVerifierModel: 'claude-fable-5-1'" "$RJ" \
   && grep -qE 'FINAL_VERIFIER_MODEL="\$\{FINAL_VERIFIER_MODEL:-claude-fable-5-1\}"' "$RUNSH"; then
  pass "G2: default final verifier claude-fable-5-1 normalizes to claude-fable-5-1:max (zsh + Node) = table Final cell, so no --final-verifier-model flag is needed"
else
  fail "G2: final-verifier default no longer resolves to claude-fable-5-1:max — the presets would need --final-verifier-model again"
fi
if grep -qE 'sonnet\)[[:space:]]+model_val="sonnet:medium"' "$RUNSH" \
   && grep -qF "['sonnet', 'sonnet:medium']" "$CB" \
   && grep -qE "verifierModel: 'sonnet'" "$RJ" \
   && ! echo "$TABLE" | awk -F'|' '{print $3}' | grep -qx 'sonnet:medium'; then
  pass "G3: default per-US verifier resolves to the floating sonnet:medium, which is no table per-US cell, so --verifier-model stays in the presets"
else
  fail "G3: default per-US verifier premise changed (sonnet -> sonnet:medium, absent from the table's per-US column)"
fi

# -- md: codex-NOT-installed block ------------------------------------------
BLOCK="$(awk '/\*\*If codex is NOT installed\*\* — show claude-only presets/{f=1} f && /# Full options reference:/{exit} f' "$MD")"
RUN_LINES="$(echo "$BLOCK" | grep -E '^[[:space:]]*/rlp-desk run ')"
TMUX_LINE="$(echo "$RUN_LINES" | grep -- '--mode tmux' | head -1)"
NATIVE_LINE="$(echo "$RUN_LINES" | grep -- '--mode native' | head -1)"

echo "--- M: rlp-desk.md claude-only block ---"
n_run=$(echo "$RUN_LINES" | grep -c '/rlp-desk run')
if [[ "$n_run" -eq 2 && -n "$TMUX_LINE" && -n "$NATIVE_LINE" ]]; then
  pass "M0: block holds exactly the 2 claude-only run presets (tmux ★ + native)"
else
  fail "M0: expected 2 run presets (tmux + native) in the codex-NOT-installed block, found $n_run"
fi

miss=""
for f in '--worker-model <Worker>' '--verifier-model <Verifier>'; do
  echo "$TMUX_LINE" | grep -qF -- "$f" || miss="$miss [$f]"
done
if [[ -z "$miss" ]]; then pass "M1: ★ tmux preset carries --worker-model <Worker> --verifier-model <Verifier>"
else fail "M1: ★ tmux preset lacks:$miss (line: '$(echo "$TMUX_LINE" | sed 's/^[[:space:]]*//')')"; fi

if [[ "$(echo "$NATIVE_LINE" | sed 's/^[[:space:]]*//')" == '/rlp-desk run <actual-slug> --mode native --debug' ]]; then
  pass "M2 (guard): native preset unchanged (no model flags; F-NATIVE)"
else
  fail "M2: native preset must stay '/rlp-desk run <actual-slug> --mode native --debug', got: '$(echo "$NATIVE_LINE" | sed 's/^[[:space:]]*//')'"
fi

for phrase in \
  'Compose the recommended run command from the Claude-only table row' \
  'needs no flag' \
  'show the four tmux rows instead of choosing one' \
  'for the campaign complexity decided in step 7' \
  'Never show the user a literal'; do
  if echo "$BLOCK" | grep -qF -- "$phrase"; then pass "M3: compose instruction contains '$phrase'"
  else fail "M3: compose instruction missing phrase '$phrase'"; fi
done

echo "--- N: negative / guards (GREEN before and after) ---"
if echo "$RUN_LINES" | grep -qiE 'gpt|codex|spark|consensus'; then
  fail "N1: claude-only run presets must not mention codex/gpt/spark/consensus"
else pass "N1: claude-only run presets mention no codex/gpt/spark/consensus"; fi
OPTREF="$(awk '/\*\*If codex is NOT installed\*\* — show claude-only presets/{f=1} f && /^##+ /{exit} f' "$MD")"
if echo "$OPTREF" | grep -qF -- '--with-self-verification' && echo "$OPTREF" | grep -qF -- '--final-verifier-model MODEL'; then
  pass "N2: options reference still lists --with-self-verification and --final-verifier-model"
else fail "N2: options reference lost --with-self-verification or --final-verifier-model"; fi
if echo "$NATIVE_LINE" | grep -qE -- '--(worker|verifier|final-verifier)-model'; then
  fail "N3: md native preset must carry no pinned model flag (F-NATIVE)"
else pass "N3: md native preset carries no pinned model flag"; fi

# -- init: print_run_presets() no-codex branch -------------------------------
FN_BODY="$(awk '
  /^print_run_presets\(\) \{/ { in_fn=1; depth=0 }
  in_fn { for (i=1;i<=length($0);i++){c=substr($0,i,1); if(c=="{")depth++; else if(c=="}"){depth--; if(depth==0){print;in_fn=0;next}}} print }
' "$INIT")"
ZSH_BIN="$(command -v zsh)"
run_presets_without_codex() {
  local tmpdir; tmpdir="$(mktemp -d)"
  printf '%s\n' "$FN_BODY" > "$tmpdir/fn.zsh"; printf '\nprint_run_presets "%s"\n' "$1" >> "$tmpdir/fn.zsh"
  # Empty PATH dir: `command -v codex` fails on any host (codex in /usr/local/bin or elsewhere).
  mkdir "$tmpdir/empty"; PATH="$tmpdir/empty" "$ZSH_BIN" -f "$tmpdir/fn.zsh" 2>/dev/null
  rm -rf "$tmpdir"
}
OUT="$(run_presets_without_codex testslug)"

echo "--- I: init_ralph_desk.zsh no-codex presets ---"
if [[ -z "$FN_BODY" ]]; then fail "I0: print_run_presets() not found"; fi
while IFS="|" read -r cx w v _; do
  [[ -z "$cx" ]] && continue
  tm="/rlp-desk run testslug --mode tmux --worker-model $w --verifier-model $v --debug"
  if echo "$OUT" | grep -qxF -- "$tm"; then pass "I1: init tmux preset for $cx"; else fail "I1: init tmux preset for $cx missing: $tm"; fi
done <<< "$TABLE"
if echo "$OUT" | grep -qxF -- '/rlp-desk run testslug --debug' \
   && ! echo "$OUT" | grep -E '^/rlp-desk run ' | grep -v -- '--mode tmux' | grep -qE -- '--(worker|verifier|final-verifier)-model'; then
  pass "I2 (guard): init native line unchanged ('/rlp-desk run testslug --debug') and no non-tmux line carries a pinned model flag"
else
  fail "I2: init native line changed or a non-tmux preset carries a pinned model flag (F-NATIVE)"
fi
if echo "$OUT" | grep -qxF -- '/rlp-desk run testslug --mode tmux --debug'; then
  fail "I3: bare model-less tmux claude-only preset still printed (must carry the per-complexity flags)"
else pass "I3: no bare model-less tmux claude-only preset in init output"; fi
if echo "$OUT" | grep -qF 'use the line for the campaign complexity brainstorm reported'; then pass "I5: init header names the campaign complexity (not per-US Risk)"; else fail "I5: init header must say 'use the line for the campaign complexity brainstorm reported'"; fi
if echo "$OUT" | grep -qF 'npm install -g @openai/codex'; then pass "I4 (guard): codex install recommendation kept"; else fail "I4: codex install recommendation lost"; fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
