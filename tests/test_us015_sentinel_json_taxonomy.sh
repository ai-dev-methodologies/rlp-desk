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
DOCS="$ROOT_REPO/docs/protocol-reference.md"

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
for cat in metric_failure cross_us_dep context_limit infra_failure repeat_axis mission_abort; do
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
# AC4: 12 zsh callsites all pass a 3rd-arg category (no missing categories)
# Note: codex Architect originally counted 11 but grep finds 12 callsites.
# Each must explicitly pass a category (no implicit default fallback).
# ----------------------------------------------------------------------------
zsh_callsites=$(grep -cE 'write_blocked_sentinel ' "$RUN")
if [[ "$zsh_callsites" -eq 12 ]]; then
  pass "AC4-a: 12 zsh write_blocked_sentinel callsites (matches Architect/grep)"
else
  fail "AC4-a: expected 12 callsites, got $zsh_callsites"
fi
# All callsites must pass a category as 3rd arg. Look for the 6 known categories.
sites_with_category=$(grep -cE 'write_blocked_sentinel.*"(metric_failure|cross_us_dep|context_limit|infra_failure|repeat_axis|mission_abort)"' "$RUN")
sites_with_dynamic=$(grep -cE 'write_blocked_sentinel.*"\$_(verdict|signal)_cat"' "$RUN")
total_categorized=$(( sites_with_category + sites_with_dynamic ))
if [[ "$total_categorized" -eq 12 ]]; then
  pass "AC4-b: all 12 zsh callsites pass an explicit category (literal=$sites_with_category, dynamic=$sites_with_dynamic)"
else
  fail "AC4-b: only $total_categorized of 12 callsites have category (literal=$sites_with_category, dynamic=$sites_with_dynamic)"
fi

# ----------------------------------------------------------------------------
# AC5: Node side — 4 BLOCKED branches all pass classification
# ----------------------------------------------------------------------------
node_callsites=$(grep -cE "writeSentinel\\(paths\\.blockedSentinel" "$LOOP")
# 4 BLOCKED branches (verifier, model_upgrade, flywheel_inconclusive, flywheel_exhausted)
# + 1 lane strict-mode BLOCKED (P1-E R4) = 5.
if [[ "$node_callsites" -eq 5 ]]; then
  pass "AC5-a: 5 Node writeSentinel(blockedSentinel) callsites (4 P1-D + 1 P1-E lane strict)"
else
  fail "AC5-a: expected 5 callsites, got $node_callsites"
fi
sites_with_classify=$(grep -cE "writeSentinel\\(paths\\.blockedSentinel.*_classifyBlock|writeSentinel\\(paths\\.blockedSentinel.*blockedClassification|writeSentinel\\(paths\\.blockedSentinel.*laneClassification" "$LOOP")
if [[ "$sites_with_classify" -eq 5 ]]; then
  pass "AC5-b: all 5 Node callsites pass classification (P1-D 4 + P1-E lane 1)"
else
  fail "AC5-b: only $sites_with_classify of 5 Node callsites pass classification"
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
# AC9: Wrapper jq one-liner branch works
# ----------------------------------------------------------------------------
TMP_WR_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us015-wrap-XXXX")
TMP_WR_SENT="$TMP_WR_DIR/wrap-blocked.md"
ITERATION=2 BLOCKED_SENTINEL="$TMP_WR_SENT" SLUG="wrap-test" CURRENT_US="US-002" \
  zsh -c "
source '$LIB' 2>/dev/null
log() { :; }
log_error() { :; }
atomic_write() { cat > \"\$1\"; }
write_blocked_sentinel 'API down' '' 'infra_failure'
"
got_action=$(jq -r '.suggested_action' "$TMP_WR_DIR/wrap-blocked.json" 2>/dev/null)
if [[ "$got_action" == "restart" ]]; then
  pass "AC9: wrapper jq retrieves suggested_action=restart for infra_failure"
else
  fail "AC9: jq returned '$got_action'"
fi
rm -rf "$TMP_WR_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
