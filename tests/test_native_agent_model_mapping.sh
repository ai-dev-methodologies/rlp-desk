#!/usr/bin/env bash
# F-NATIVE — `--mode native` must map every claude model spec to a family alias
# before Agent(model=...), and every doc that promised pinned ids / effort for
# native must say what really happens.
#
# Why: the Agent tool's `model` accepts ONLY the aliases haiku|sonnet|opus|fable and
# has NO effort parameter (probed 2026-10-07: Agent(model="claude-sonnet-5-5") and
# Agent(model="sonnet:high") are both rejected with InputValidationError before any
# subagent is spawned). The native leader is an LLM executing src/commands/rlp-desk.md;
# there is no code path that builds the Agent model (src/node refuses native), so the
# mapping rule lives in the md and is pinned here:
#   S  the "Native Agent() model mapping" section exists, its table is exactly the four
#      family aliases (plus the dated alias-resolution snapshot), and its rules carry
#      the load-bearing phrases (effort dropped + logged, version pin not honored, no
#      family token -> BLOCKED, native promotion/stopping NOT guaranteed to match the tmux
#      leader, see follow-up F-NATIVE-LADDER);
#   D  the native dispatch snippets pass <worker_agent_alias> / <selected_verifier_agent_alias>
#      (never the raw <worker_model> / <selected_verifier_model>);
#   C  coverage guard: every claude spec the repo can hand to a native dispatch (ladder
#      keys/values in models.json, the Claude-only table cells, the shipped defaults,
#      the consensus claude-leg models) contains exactly one of the four family tokens,
#      so a new family without a table row fails here;
#   P  stale-claim pins: each place that told native users pinned ids / effort work now
#      carries the marker `native: family alias only, effort dropped`;
#   T/N the [1m] scope, the table wording, the governance defaults paragraph, the baseline.log
#      sentence, the tmux-qualified stop numbers, and a negative pin (N10) that no passage claims
#      native follows the tmux rung schedule. This addendum does NOT change native promotion or
#      stopping (step 3 and 7c stay as they are; follow-up F-NATIVE-LADDER).
REPO="$(cd "$(dirname "$0")/.." && pwd)"
MD="$REPO/src/commands/rlp-desk.md"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

echo "=== F-NATIVE: native Agent() model mapping ==="

# ---- S: the section --------------------------------------------------------------
SECTION="$(awk '/^### Native Agent\(\) model mapping$/ {f=1; next} f && /^##+ / {exit} f' "$MD")"
if [[ -z "$SECTION" ]]; then
  fail "S0: rlp-desk.md has no '### Native Agent() model mapping' section"
else
  pass "S0: '### Native Agent() model mapping' section present"
fi

ROWS="$(echo "$SECTION" | awk -F'|' '/^\| *`?(haiku|sonnet|opus|fable)`? *\|/ {
  for(i=1;i<=NF;i++){gsub(/^[ \t`]+|[ \t`]+$/,"",$i)}; print $2 "->" $4 "@" $5 }')"
EXPECT_ROWS=$'haiku->haiku@claude-haiku-4-5-20251001\nsonnet->sonnet@claude-sonnet-5-5\nopus->opus@claude-opus-5-5\nfable->fable@claude-fable-5-1'
if [[ "$ROWS" == "$EXPECT_ROWS" ]]; then
  pass "S1: mapping table = 4 family tokens -> the 4 Agent aliases, with the 2026-10-07 alias-resolution snapshot"
else
  fail "S1: mapping table rows (family->alias@snapshot) are '$(echo "$ROWS" | tr '\n' ';')', want '$(echo "$EXPECT_ROWS" | tr '\n' ';')'"
fi

for phrase in \
  'accepts ONLY the aliases' \
  'no effort parameter' \
  'probed 2026-10-07' \
  'InputValidationError' \
  'effort is dropped' \
  'effort_dropped=' \
  'version_pin_not_honored=' \
  'family alias' \
  'effort-only hop' \
  'native cannot map model' \
  '[1m]' \
  'use `--mode tmux`' \
  'baseline.log' \
  'measured 2026-09-27' \
  'family and version' \
  'both dispatch as `sonnet`' \
  'not guaranteed to match the tmux leader' \
  'and the Circuit Breaker section' \
  'Agent-tool probe of 2026-10-08' \
  'UNVERIFIED (2026-10-11)' \
  'claude-haiku-5-5'; do
  if echo "$SECTION" | grep -qF -- "$phrase"; then pass "S2: section contains '$phrase'"
  else fail "S2: section lacks the phrase '$phrase'"; fi
done

# ---- D: dispatch snippets --------------------------------------------------------
DISP="$(sed -n '/^If claude engine (default):/,/^If codex engine:/p' "$MD")"
if echo "$DISP" | grep -qF 'model=<worker_agent_alias>' && echo "$DISP" | grep -qF 'model=<selected_verifier_agent_alias>'; then
  pass "D1: worker and verifier dispatch snippets pass the mapped alias (model=<worker_agent_alias> / <selected_verifier_agent_alias>)"
else
  fail "D1: dispatch snippets must pass model=<worker_agent_alias> and model=<selected_verifier_agent_alias>"
fi
if echo "$DISP" | grep -qE 'model=<(worker_model|selected_verifier_model)>'; then
  fail "D2: a dispatch snippet still passes the raw spec (model=<worker_model> / <selected_verifier_model>) to Agent()"
else
  pass "D2: no dispatch snippet passes the raw spec to Agent(model=)"
fi
n_ref=$(echo "$DISP" | grep -cF 'Native Agent() model mapping')
if [[ "$n_ref" -ge 2 ]]; then pass "D3: both claude dispatch blocks point at the mapping section ($n_ref references)"
else fail "D3: the worker and verifier claude dispatch blocks must each reference 'Native Agent() model mapping' (found $n_ref)"; fi

# ---- C: coverage guard -------------------------------------------------------------
SPECS="$( {
  jq -r '.upgrades | to_entries[] | .key, .value' "$REPO/src/node/models.json"
  awk '/Model mapping — Claude-only/{f=1;next} /Model mapping — Cross-engine/{f=0} f && /^[[:space:]]*\| (LOW|MEDIUM|HIGH|CRITICAL) \|/ {
    n=split($0,c,"|"); for(i=3;i<=5;i++){gsub(/^[ \t]+|[ \t]+$/,"",c[i]); split(c[i],t," "); print t[1]} }' "$MD"
  grep -oE "(workerModel|verifierModel|finalVerifierModel): '[^']+'" "$REPO/src/node/run.mjs" | sed -E "s/.*: '([^']+)'/\1/"
  echo opus; echo claude-fable-5-1
} | grep -E '^(haiku|sonnet|opus|fable|claude-)' | sort -u)"
n_specs=$(echo "$SPECS" | grep -c .)
bad=""
while IFS= read -r spec; do
  [[ -z "$spec" ]] && continue
  base="${spec%%:*}"; base="${base%%\[*}"
  hits=0; for fam in haiku sonnet opus fable; do [[ "$base" == *"$fam"* ]] && hits=$((hits+1)); done
  [[ "$hits" -eq 1 ]] || bad="$bad [$spec]"
done <<< "$SPECS"
if [[ "$n_specs" -ge 12 && -z "$bad" ]]; then
  pass "C1: all $n_specs distinct claude specs (models.json, Claude-only table, defaults, consensus legs) contain exactly one family token"
else
  fail "C1: $n_specs distinct claude specs, those without exactly one family token:$bad (want >= 12 specs, none unmappable)"
fi

# ---- P: stale-claim pins (one marker per options block / prose block + the section reference) ----
MARK='native: family alias only, effort dropped'
# file|fixed-string locating exactly one line|label  (the LABEL is the last |-field; the locator may contain '|')
PINS=(
  "src/commands/rlp-desk.md|Version-pinned full ids (not the floating|brainstorm verifier block (per-US, final, consensus claude leg)"
  "src/commands/rlp-desk.md|#   --worker-model MODEL                   claude (haiku|sonnet|opus|claude-opus-5-5:high, effort optional) or codex|codex-installed options block"
  "src/commands/rlp-desk.md|#   --worker-model MODEL                   haiku|sonnet|opus, or full claude id with effort|claude-only options block"
  "src/commands/rlp-desk.md|- \`--worker-model MODEL\` (default: \`haiku\`) — Worker model. Format:|run options list"
  "src/commands/rlp-desk.md|  --worker-model MODEL                 Worker model: haiku|sonnet|opus|claude-opus-5-5:high|usage block"
  "src/scripts/init_ralph_desk.zsh|--worker-model MODEL                   haiku|sonnet|opus|fable, or full claude id|init options reference"
  "README.md|3. Select model (haiku/sonnet/opus|README native loop step 3"
  "README.md|Verifier minimum: claude sonnet (haiku cannot verify)|README verifier tiers"
  "README.md|Verifier cells are version-pinned ids so the tier does not drift|README recommended-config tables"
  "README.md|The engine is inferred automatically from the \`--worker-model\` value|README engine inference"
  "docs/rlp-desk/getting-started.md|| **Models** |getting-started Models row"
  "docs/rlp-desk/getting-started.md|These are the claude-only CLI defaults (governance §4).|getting-started defaults paragraph"
  "docs/rlp-desk/protocol-reference.md|**Claude engine** (default): uses \`Agent()\` in agent mode|protocol-reference claude engine"
  "src/governance.md|- Leader is an LLM — can dynamically route models|governance 5a Agent() section"
)
for pin in "${PINS[@]}"; do
  file="${pin%%|*}"; rest="${pin#*|}"
  label="${rest##*|}"; loc="${rest%|*}"
  line="$(grep -F -- "$loc" "$REPO/$file" | head -1)"
  if [[ -z "$line" ]]; then fail "P: locator not found in $file ($label): '$loc'"
  elif echo "$line" | grep -qF -- "$MARK"; then pass "P: $label carries the native marker"
  else fail "P: $label ($file) still promises pinned ids / effort for native — missing '$MARK'"; fi
done
# the dispatch steps and the consensus line point at the section (reference only, no marker)
REFS=(
  "Determine engine from \`--worker-model\` format:|native worker dispatch step (5)"
  "Determine engine from the selected verifier model format|native verifier dispatch step (7a)"
  "If primary engine is codex → cross-verifier uses claude, fixed per scope|consensus claude-leg fixed models (7b)"
)
for r in "${REFS[@]}"; do
  label="${r##*|}"; loc="${r%|*}"
  line="$(grep -F -- "$loc" "$MD" | head -1)"
  if [[ -z "$line" ]]; then fail "R: locator not found ($label): '$loc'"
  elif echo "$line" | grep -qF -- 'Native Agent() model mapping'; then pass "R: $label references the mapping section"
  else fail "R: $label does not reference 'Native Agent() model mapping'"; fi
done

# ---- T: [1m] scope and table wording ---------------------------------------------------
HONORED="$(grep -F -- 'honored as-is' "$MD" | head -1)"
if echo "$HONORED" | grep -qF 'tmux'; then pass "T3: the [1m] 'honored as-is' sentence is scoped to tmux"
else fail "T3: the '[1m] is honored as-is' sentence must say it holds under --mode tmux (native drops [1m])"; fi
nrow=$(echo "$SECTION" | awk -F'|' '/^\| *`(haiku|sonnet|opus|fable)` *\|/ { if ($3 ~ /any `claude-` id containing/) n++ } END{print n+0}')
if [[ "$nrow" -eq 4 ]]; then pass "T4: all 4 'Specs it covers' cells say 'any claude- id containing <family>' (rule 1 matches the family token anywhere)"
else fail "T4: the 'Specs it covers' cells must read 'any \`claude-\` id containing <family>' (found $nrow of 4)"; fi

# ---- N: conflict-sensitive pins (r5: the native-ladder pins N1-N4, N6, N9 were removed with the descope; N10 guards against re-adding the claim) ----
GOV="$REPO/src/governance.md"; PREF="$REPO/docs/rlp-desk/protocol-reference.md"; RD="$REPO/README.md"
GDEF="$(sed -n '/^These are the \*\*CLI defaults\*\*/,/^\*\*Worker auto-upgrade\*\*/p' "$GOV")"
if [[ "$GDEF" != *'therefore runs the tiers'* && "$GDEF" == *'--mode tmux'* && "$GDEF" == *'--mode native'* && "$GDEF" == *'flag-free native preset'* ]]; then pass "N5: governance §4 defaults paragraph separates the composed tmux recommendation from the flag-free native CLI defaults"
else fail "N5: governance §4 must not say a /rlp-desk campaign 'therefore runs the tiers'; it must separate the composed tmux recommendation from the native flag-free CLI defaults"; fi

BL="$(grep -F -- 'Baseline.log captures' "$MD" | head -1)"
if [[ "$BL" == *'[native]'* ]]; then pass "N7: the md baseline.log description mentions the [native] notice lines"
else fail "N7: 'Baseline.log captures 1 line per iteration' must mention the [native] model-mapping notice lines (rule 2 tees them into baseline.log)"; fi
if grep -qF 'tmux default path BLOCKS at failure #6' "$GOV"; then fail "N8: governance still says 'the tmux default path BLOCKS at failure #6' (true only for LOW/MEDIUM; HIGH/CRITICAL block at #4)"
elif grep -qF 'BLOCKS at failure #6 for a LOW or MEDIUM start' "$GOV"; then pass "N8: governance qualifies the #6 stop to LOW/MEDIUM (HIGH/CRITICAL at #4)"
else fail "N8: governance 7-3/4 item 4 must say the default path BLOCKS at #6 for a LOW or MEDIUM start and at #4 for HIGH/CRITICAL"; fi
# N10: negative pin. Native promotion/stopping is NOT changed by this addendum (follow-up F-NATIVE-LADDER):
# no native-applicable passage may claim that native follows the tmux rung schedule / has identical stop points.
claim=""
for f in "$MD" "$GOV" "$PREF" "$RD" "$REPO/src/model-upgrade-table.md"; do
  while IFS= read -r l; do claim="$claim [$(basename "$f"): ${l:0:70}]"; done < <(grep -iE 'follows? the (same|tmux) (rung|promotion)|same stop points|identical stop points|native has the same|same ceiling-landing window|in BOTH modes a ceiling|single native promotion' "$f")
done
if [[ -z "$claim" ]]; then pass "N10: no passage claims native follows the tmux rung schedule or has identical stop points (native ladder semantics unchanged, F-NATIVE-LADDER)"
else fail "N10: passage(s) claim native promotion/stopping equals tmux's:$claim"; fi
# N11: negative pin. Shipped files must not carry internal tracker ids (review-1 r5 F2): no F-NATIVE* / F-SAFETY
# under src/, docs/rlp-desk/ or README.md (the ids live in the plan and the ADR follow-ups only).
trk="$(grep -rnE 'F-NATIVE|F-SAFETY' "$REPO/src" "$REPO/docs/rlp-desk" "$REPO/README.md" 2>/dev/null | cut -c1-110 | tr '\n' ' ')"
if [[ -z "$trk" ]]; then pass "N11: no shipped file (src/, docs/rlp-desk/, README.md) carries an F-NATIVE* / F-SAFETY tracker id"
else fail "N11: internal tracker id(s) in shipped files: $trk"; fi
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] || exit 1
