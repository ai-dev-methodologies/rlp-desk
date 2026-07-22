#!/usr/bin/env bash
# Test Suite: US-015 — R3 P1-D Sentinel JSON taxonomy + Write Order Contract
# Validates:
#   - JSON sidecar has correct schema with reason_category + recoverable + suggested_action
#   - 6 reason_category values are emitted from the right sources (Node + zsh)
#   - markdown sentinel still works (backward-compat) — first line `BLOCKED: <us_id>`
#   - Write Order Contract — JSON written before markdown (zsh + Node both)
#   - Cross-US token list matches `cross_us_dep`, others match `metric_failure`
#   - Wrapper-friendly contract: `jq .reason_category` returns the primary category
#   - 14 zsh callsites all pass a category (no missing default)

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
GOV="$ROOT_REPO/src/governance.md"
DOCS="$ROOT_REPO/docs/rlp-desk/protocol-reference.md"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  local file="$1" pat="$2" n
  n=$(grep -cE -- "$pat" "$file" 2>/dev/null) || n=0
  printf '%s' "$n"
}
assert_one() {
  local n; n=$(_match_count "$1" "$2")
  [[ "$n" -ge 1 ]] && pass "$3" || fail "$3 (matches=0)"
}

echo "=== US-015: R3 P1-D Sentinel JSON taxonomy + Write Order Contract ==="
echo

# ----------------------------------------------------------------------------
# AC1: governance §1f Failure Taxonomy section + 6 reason_category values
# ----------------------------------------------------------------------------
assert_one "$GOV" 'Failure Taxonomy \(P1-D\)' \
  "AC1-a: governance §1f Failure Taxonomy section present"
for cat in metric_failure cross_us_dep contract_violation context_limit infra_failure repeat_axis mission_abort external_fact; do
  assert_one "$GOV" "$cat" "AC1-b/$cat: governance enumerates $cat"
done
assert_one "$GOV" 'reason_category.*PRIMARY' \
  "AC1-c: governance enforces reason_category as PRIMARY for wrapper branching"
assert_one "$GOV" 'failure_category.*SECONDARY' \
  "AC1-d: governance enforces failure_category as SECONDARY (diagnostic only)"

# ----------------------------------------------------------------------------
# AC2: Cross-US token list documented + zsh helper present
# ----------------------------------------------------------------------------
assert_one "$LIB" '_classify_cross_us_or_metric' \
  "AC2-a: zsh helper _classify_cross_us_or_metric defined"
assert_one "$LIB" 'depends on US-' \
  "AC2-b: zsh helper includes 'depends on US-' token"
assert_one "$LIB" 'cross-US' \
  "AC2-c: zsh helper includes 'cross-US' token"
assert_one "$LIB" '신규 US-' \
  "AC2-d: zsh helper includes Korean '신규 US-' token"
assert_one "$LOOP" 'CROSS_US_TOKEN_RE' \
  "AC2-e: Node CROSS_US_TOKEN_RE defined"
assert_one "$LOOP" '_classifyBlock' \
  "AC2-f: Node _classifyBlock helper defined"

# ----------------------------------------------------------------------------
# AC3: zsh write_blocked_sentinel emits JSON sidecar + correct write order
# ----------------------------------------------------------------------------
assert_one "$LIB" 'json_path="\$\{BLOCKED_SENTINEL%.md\}.json"' \
  "AC3-a: JSON sidecar path derived from BLOCKED_SENTINEL"
assert_one "$LIB" '_blocked_recoverable_for_category' \
  "AC3-b: recoverable derivation helper present"
assert_one "$LIB" '_blocked_action_for_category' \
  "AC3-c: suggested_action derivation helper present"
assert_one "$LIB" 'Write Order Contract' \
  "AC3-d: Write Order Contract documented in lib"

# Behavioural: actually run write_blocked_sentinel and inspect the two files.
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us015-XXXX")
trap "rm -rf '$TMP_DIR'" EXIT
TMP_SENT="$TMP_DIR/test-blocked.md"
TMP_JSON="$TMP_DIR/test-blocked.json"
ITERATION=4 BLOCKED_SENTINEL="$TMP_SENT" SLUG="us015-test" CURRENT_US="US-007" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'AC3 unsatisfiable: depends on US-009 batch' '' 'cross_us_dep'
"
if [[ -f "$TMP_SENT" && -f "$TMP_JSON" ]]; then
  pass "AC3-e: both markdown and JSON sidecar written"
else
  fail "AC3-e: missing files (markdown=$([[ -f $TMP_SENT ]] && echo yes || echo no), json=$([[ -f $TMP_JSON ]] && echo yes || echo no))"
fi

# AC3-f: markdown first line wrapper contract
got_first=$(head -1 "$TMP_SENT")
if [[ "$got_first" == "BLOCKED: US-007" ]]; then
  pass "AC3-f: markdown first line is 'BLOCKED: <us_id>'"
else
  fail "AC3-f: got '$got_first'"
fi
# AC3-g: markdown includes Category line
got_cat=$(grep -m1 '^Category:' "$TMP_SENT" | sed 's/^Category: //')
if [[ "$got_cat" == "cross_us_dep" ]]; then
  pass "AC3-g: markdown includes Category line"
else
  fail "AC3-g: got '$got_cat'"
fi

# AC3-h: JSON sidecar has all required fields
if command -v jq >/dev/null 2>&1; then
  json_cat=$(jq -r '.reason_category' "$TMP_JSON" 2>/dev/null)
  json_recov=$(jq -r '.recoverable' "$TMP_JSON" 2>/dev/null)
  json_action=$(jq -r '.suggested_action' "$TMP_JSON" 2>/dev/null)
  json_us=$(jq -r '.us_id' "$TMP_JSON" 2>/dev/null)
  json_iter=$(jq -r '.blocked_at_iter' "$TMP_JSON" 2>/dev/null)
  json_slug=$(jq -r '.slug' "$TMP_JSON" 2>/dev/null)
  json_sv=$(jq -r '.schema_version' "$TMP_JSON" 2>/dev/null)
  if [[ "$json_cat" == "cross_us_dep" && "$json_recov" == "true" && "$json_action" == "retry_after_fix" \
        && "$json_us" == "US-007" && "$json_iter" == "4" && "$json_slug" == "us015-test" \
        && "$json_sv" == "2.0" ]]; then
    pass "AC3-h: JSON sidecar fully populated (jq verified)"
  else
    fail "AC3-h: JSON fields wrong (cat=$json_cat, recov=$json_recov, action=$json_action, us=$json_us, iter=$json_iter, slug=$json_slug, sv=$json_sv)"
  fi
else
  fail "AC3-h: jq not available, cannot verify JSON sidecar"
fi
rm -rf "$TMP_DIR"

# ----------------------------------------------------------------------------
# AC4: every zsh callsite passes an explicit category (no missing categories).
# Count grew to 26 as recovery/prompt-guard BLOCKED paths were added
# (v0.15.0 Bug #7/#8 fix + signal-protocol enhancement), then dropped to 25 in
# request-b ②: the Bug #8 F-8 auto-commit hard-BLOCK was downgraded to
# warn+carryover+CONTINUE (a gitignored evidence artifact is now recoverable via
# a scoped `git add -f`, and a genuinely unrecoverable git state must not kill an
# otherwise-complete campaign — the Verifier remains the completeness gate).
# request-j: grew 27 → 39 as fail-fast infra_failure BLOCKs were added for
# pane-session pinning (② create_session + replace_worker_pane guards) and the
# model-capacity stall cap (①). request-l: grew 39 → 47 for leader pane width +
# canonical geometry BLOCKs (create_session ×4 [split-width + geometry × inside/
# outside], replace_worker_pane ×3 [split-width verifier/worker fallbacks +
# geometry], consensus ×1 [geometry]). The invariant is unchanged: total callsites
# == categorized callsites (no implicit default). Category is passed either inline
# (single-line calls) or on the last continuation line (multi-line calls).
# ----------------------------------------------------------------------------
zsh_callsites=$(grep -cE 'write_blocked_sentinel ' "$RUN")
if [[ "$zsh_callsites" -eq 47 ]]; then
  pass "AC4-a: 47 zsh write_blocked_sentinel callsites (27 pre-request-j + 12 request-j pane-pinning/capacity + 8 request-l width/geometry fail-fast BLOCKs)"
else
  fail "AC4-a: expected 47 callsites, got $zsh_callsites"
fi
# All callsites must pass one of the 6 known categories. Inline calls carry it
# on the call line; multi-line calls carry it on a standalone continuation line.
sites_with_category=$(grep -cE 'write_blocked_sentinel.*"(metric_failure|cross_us_dep|context_limit|infra_failure|repeat_axis|mission_abort)"' "$RUN")
sites_with_dynamic=$(grep -cE 'write_blocked_sentinel.*"\$_(verdict|signal)_cat"' "$RUN")
sites_with_continuation=$(grep -cE '^[[:space:]]*"(metric_failure|cross_us_dep|context_limit|infra_failure|repeat_axis|mission_abort)"[[:space:]]*$' "$RUN")
total_categorized=$(( sites_with_category + sites_with_dynamic + sites_with_continuation ))
if [[ "$total_categorized" -eq 47 ]]; then
  pass "AC4-b: all 47 zsh callsites pass an explicit category (literal=$sites_with_category, dynamic=$sites_with_dynamic, continuation=$sites_with_continuation)"
else
  fail "AC4-b: only $total_categorized of 47 callsites have category (literal=$sites_with_category, dynamic=$sites_with_dynamic, continuation=$sites_with_continuation)"
fi

# ----------------------------------------------------------------------------
# AC5: Node side — 4 BLOCKED branches all pass classification
# ----------------------------------------------------------------------------
node_callsites=$(grep -cE "writeSentinel\\(paths\\.blockedSentinel" "$LOOP")
# Grew to 9 BLOCKED callsites (v0.22.7 US-001 added the commit-integrity
# oracle-exhaustion BLOCK). Each passes a classification argument that is
# derived from _classifyBlock — either inline, or via a local classification
# variable computed on the preceding line (lines that pass a bare
# `, classification, paths` arg).
if [[ "$node_callsites" -eq 9 ]]; then
  pass "AC5-a: 9 Node writeSentinel(blockedSentinel) callsites"
else
  fail "AC5-a: expected 9 callsites, got $node_callsites"
fi
sites_with_classify=$(grep -cE "writeSentinel\\(paths\\.blockedSentinel.*_classifyBlock|writeSentinel\\(paths\\.blockedSentinel.*blockedClassification|writeSentinel\\(paths\\.blockedSentinel.*laneClassification|writeSentinel\\(paths\\.blockedSentinel.*malformedClassification|writeSentinel\\(paths\\.blockedSentinel.*, classification, paths" "$LOOP")
if [[ "$sites_with_classify" -eq 9 ]]; then
  pass "AC5-b: all 9 Node callsites pass classification"
else
  fail "AC5-b: only $sites_with_classify of 9 Node callsites pass classification"
fi

# ----------------------------------------------------------------------------
# AC6: Cross-US token classifier works for all listed tokens
# ----------------------------------------------------------------------------
classify() {
  local text="$1"
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
_classify_cross_us_or_metric '$text'
"
}
for token in "depends on US-009" "blocking US-002" "awaits US-003" "post-iter US-005" "requires US-007" "cross-US measurement" "US-005 산출물" "신규 US-008"; do
  out=$(classify "$token")
  if [[ "$out" == "cross_us_dep" ]]; then
    pass "AC6/$token: classified as cross_us_dep"
  else
    fail "AC6/$token: got '$out', expected 'cross_us_dep'"
  fi
done
out=$(classify "metric M1 missed by 0.05")
if [[ "$out" == "metric_failure" ]]; then
  pass "AC6-default: metric phrasing classified as metric_failure"
else
  fail "AC6-default: got '$out', expected 'metric_failure'"
fi

# ----------------------------------------------------------------------------
# AC7: docs/protocol-reference.md documents schema + write order + tokens
# ----------------------------------------------------------------------------
assert_one "$DOCS" 'Blocked Sentinel JSON Schema' \
  "AC7-a: docs has schema section"
assert_one "$DOCS" 'Write Order Contract' \
  "AC7-b: docs has Write Order Contract section"
assert_one "$DOCS" 'reason_category. is PRIMARY' \
  "AC7-c: docs marks reason_category as PRIMARY"
assert_one "$DOCS" 'depends on US-' \
  "AC7-d: docs lists cross-US tokens"

# ----------------------------------------------------------------------------
# AC8: Race-condition fixture — markdown exists ⇒ JSON exists invariant
# Verify by ordering: write JSON first (sleep 0), then markdown. Reader sees
# either both files or only JSON, never markdown-only.
# ----------------------------------------------------------------------------
TMP_RACE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us015-race-XXXX")
TMP_RACE_SENT="$TMP_RACE_DIR/race-blocked.md"
ITERATION=1 BLOCKED_SENTINEL="$TMP_RACE_SENT" SLUG="race-test" CURRENT_US="US-001" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'race-condition test' '' 'metric_failure'
"
TMP_RACE_JSON="$TMP_RACE_DIR/race-blocked.json"
if [[ -f "$TMP_RACE_SENT" && -f "$TMP_RACE_JSON" ]]; then
  json_mtime=$(stat -f %m "$TMP_RACE_JSON" 2>/dev/null || stat -c %Y "$TMP_RACE_JSON" 2>/dev/null)
  md_mtime=$(stat -f %m "$TMP_RACE_SENT" 2>/dev/null || stat -c %Y "$TMP_RACE_SENT" 2>/dev/null)
  if [[ "$json_mtime" -le "$md_mtime" ]]; then
    pass "AC8: markdown exists ⇒ JSON exists invariant (json_mtime=$json_mtime ≤ md_mtime=$md_mtime)"
  else
    fail "AC8: markdown mtime precedes JSON mtime (md=$md_mtime, json=$json_mtime) — write order broken"
  fi
else
  fail "AC8: invariant broken (markdown=$([[ -f $TMP_RACE_SENT ]] && echo yes || echo no), json=$([[ -f $TMP_RACE_JSON ]] && echo yes || echo no))"
fi
rm -rf "$TMP_RACE_DIR"

# ----------------------------------------------------------------------------
# AC9: Wrapper jq one-liner branch works. vision-adopt §2 (fail-fast wins): the
# infra_failure CATEGORY DEFAULT is now recoverable=false + investigate (was
# true + restart). The genuinely-transient infra callsites override at the
# callsite to recoverable=true + restart — verified here too and pinned by
# tests/test_recoverable_parity.sh.
# ----------------------------------------------------------------------------
TMP_WR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us015-wrap-XXXX")
TMP_WR_SENT="$TMP_WR_DIR/wrap-blocked.md"
ITERATION=2 BLOCKED_SENTINEL="$TMP_WR_SENT" SLUG="wrap-test" CURRENT_US="US-002" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'pane dead' '' 'infra_failure'
"
got_action=$(jq -r '.suggested_action' "$TMP_WR_DIR/wrap-blocked.json" 2>/dev/null)
got_recov=$(jq -r '.recoverable' "$TMP_WR_DIR/wrap-blocked.json" 2>/dev/null)
if [[ "$got_action" == "investigate" && "$got_recov" == "false" ]]; then
  pass "AC9-a: infra_failure category default is recoverable=false + investigate (fail-fast)"
else
  fail "AC9-a: got action='$got_action' recoverable='$got_recov'"
fi

# Override path: a transient infra callsite passes recoverable=true + restart.
TMP_WR_SENT2="$TMP_WR_DIR/wrap-blocked2.md"
ITERATION=2 BLOCKED_SENTINEL="$TMP_WR_SENT2" SLUG="wrap-test" CURRENT_US="US-002" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'API unavailable after retries' '' 'infra_failure' 'infra' 'true' 'restart'
"
ovr_action=$(jq -r '.suggested_action' "$TMP_WR_DIR/wrap-blocked2.json" 2>/dev/null)
ovr_recov=$(jq -r '.recoverable' "$TMP_WR_DIR/wrap-blocked2.json" 2>/dev/null)
if [[ "$ovr_action" == "restart" && "$ovr_recov" == "true" ]]; then
  pass "AC9-b: transient infra override → recoverable=true + restart"
else
  fail "AC9-b: got action='$ovr_action' recoverable='$ovr_recov'"
fi
rm -rf "$TMP_WR_DIR"

# ----------------------------------------------------------------------------
# AC10: request-d ③ — BLOCKED cause field (infra|contract_gap|defect). A closed
# 3-value operator-routing field, distinct from reason_category, emitted into the
# JSON sidecar alongside failure_category. Optional 4th arg to
# write_blocked_sentinel; default infra; unrecognized value degrades to infra.
# ----------------------------------------------------------------------------
assert_one "$LIB" 'local cause="\$\{4:-infra\}"' \
  "AC10-a: zsh write_blocked_sentinel takes optional 4th cause arg (default infra)"
assert_one "$LIB" 'infra|contract_gap|defect' \
  "AC10-b: zsh enforces the closed cause set"
assert_one "$LIB" 'cause: \$cause' \
  "AC10-c: zsh JSON sidecar emits the cause field"
assert_one "$LOOP" "\\['infra', 'contract_gap', 'defect'\\]" \
  "AC10-d: Node writeSentinel enforces the closed cause set in the sidecar"
assert_one "$LOOP" "cause = 'defect'" \
  "AC10-e: Node _classifyBlock maps a malformed artifact to cause=defect"
# The malformed-artifact zsh callsite is classified defect (conservative
# classification per request-d ③; all other callsites default to infra).
assert_one "$RUN" 'verify_partial_malformed.*"repeat_axis" "defect"' \
  "AC10-f: zsh malformed-artifact callsite passes cause=defect"

# Behavioural: default cause = infra when the 4th arg is omitted.
TMP_C_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us015-cause-XXXX")
TMP_C_SENT="$TMP_C_DIR/c-blocked.md"
ITERATION=1 BLOCKED_SENTINEL="$TMP_C_SENT" SLUG="cause-test" CURRENT_US="US-001" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'infra-ish block' '' 'infra_failure'
"
got_cause=$(jq -r '.cause' "$TMP_C_DIR/c-blocked.json" 2>/dev/null)
if [[ "$got_cause" == "infra" ]]; then
  pass "AC10-g: default cause is infra when 4th arg omitted"
else
  fail "AC10-g: got '$got_cause'"
fi

# Behavioural: explicit cause=defect honored.
TMP_C2="$TMP_C_DIR/c2-blocked.md"
ITERATION=1 BLOCKED_SENTINEL="$TMP_C2" SLUG="cause-test" CURRENT_US="US-002" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'malformed artifact' '' 'repeat_axis' 'defect'
"
got_cause2=$(jq -r '.cause' "$TMP_C_DIR/c2-blocked.json" 2>/dev/null)
[[ "$got_cause2" == "defect" ]] && pass "AC10-h: explicit cause=defect honored" || fail "AC10-h: got '$got_cause2'"

# Behavioural: unrecognized cause degrades to infra (closed set).
TMP_C3="$TMP_C_DIR/c3-blocked.md"
ITERATION=1 BLOCKED_SENTINEL="$TMP_C3" SLUG="cause-test" CURRENT_US="US-003" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'bad cause value' '' 'metric_failure' 'nonsense'
"
got_cause3=$(jq -r '.cause' "$TMP_C_DIR/c3-blocked.json" 2>/dev/null)
[[ "$got_cause3" == "infra" ]] && pass "AC10-i: unrecognized cause degrades to infra" || fail "AC10-i: got '$got_cause3'"
rm -rf "$TMP_C_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
