#!/usr/bin/env zsh
# US-001 (v0.22.3): confirmation-mode verification — resume deadlock fix.
#
# A campaign restarted over an already-verified deliverable cannot honestly
# produce fresh write_test/verify_red evidence, so the codex Worker Process
# Audit failed every round and the stale-context guard blocked (2x: linelog,
# slugify). The leader now derives verification_mode=confirmation from
# durable state (verified ledger SHA anchor + clean tree) and injects it into
# the verifier prompts as the sole authoritative channel; in confirmation
# mode the audit demands fresh timestamped GREEN evidence, not RED.
#
# Threat model (PRD): anti-laziness gate vs cooperative-but-sloppy worker —
# NOT a Byzantine boundary. Fail-closed everywhere: any missing/malformed
# anchor → build mode.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Fixture repo: 2 commits so SHA-match vs mismatch is testable.
FIX="$TMP/fix"; mkdir -p "$FIX"; cd "$FIX"
git init -q; git config user.email t@t; git config user.name t
echo one > a.txt; git add a.txt; git commit -qm c1; SHA1=$(git rev-parse HEAD)
echo two >> a.txt; git commit -qam c2; SHA2=$(git rev-parse HEAD)
PRD="$FIX/prd.md"
printf '### US-001: First\n- AC1: x\n### US-002: Second\n- AC1: y\n' > "$PRD"

# Driver: run derive_verification_mode in a clean zsh sourcing lib.
derive() { # $1=ledger $2=prd $3=root
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    derive_verification_mode "$1" "$2" "$3"
  ' _ "$1" "$2" "$3"
}
mode_of(){ derive "$@" | head -1 | cut -d'|' -f1; }

L="$TMP/ledger.jsonl"
mkln(){ : > "$L"; for j in "$@"; do print -r -- "$j" >> "$L"; done; }

print -r -- "-- behavioral: 2x2x2 truth table (only complete+match+clean => confirmation)"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA2\"}" "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"$SHA2\"}"
[[ $(mode_of "$L" "$PRD" "$FIX") == confirmation ]] \
  && ok "complete coverage + SHA match + clean tree -> confirmation" \
  || no "complete+match+clean should be confirmation (got: $(derive "$L" "$PRD" "$FIX"))"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA2\"}"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "incomplete coverage -> build" || no "incomplete coverage should be build"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA1\"}" "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"$SHA1\"}"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "SHA mismatch (HEAD moved since verify) -> build" || no "SHA mismatch should be build"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA2\"}" "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"$SHA2\"}"
echo dirty >> "$FIX/a.txt"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "tracked-dirty tree -> build" || no "dirty tree should be build"
git -C "$FIX" checkout -q -- a.txt
touch "$FIX/untracked.tmp"
[[ $(mode_of "$L" "$PRD" "$FIX") == confirmation ]] \
  && ok "untracked-only noise stays confirmation (--untracked-files=no)" \
  || no "untracked-only file must not demote to build"
rm -f "$FIX/untracked.tmp"

print -r -- "-- behavioral: degenerate anchors fail CLOSED to build"
mkln "{\"us_id\":\"US-001\",\"iter\":1}" "{\"us_id\":\"US-002\",\"iter\":2}"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "ledger lines without commit field -> build" || no "missing commit must be build"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA2\"}" "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\"}"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "malformed/unresolvable SHA -> build" || no "bogus SHA must be build"
: > "$L"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "empty ledger -> build" || no "empty ledger must be build"
[[ $(mode_of "$TMP/nonexistent.jsonl" "$PRD" "$FIX") == build ]] \
  && ok "missing ledger -> build" || no "missing ledger must be build"

print -r -- "-- behavioral: ALL completion record shape"
mkln "{\"us_id\":\"ALL\",\"iter\":3,\"commit\":\"$SHA2\",\"coverage\":[\"US-001\",\"US-002\"]}"
[[ $(mode_of "$L" "$PRD" "$FIX") == confirmation ]] \
  && ok "valid ALL record (full coverage + matching SHA) -> confirmation" \
  || no "valid ALL record should be confirmation (got: $(derive "$L" "$PRD" "$FIX"))"
mkln "{\"us_id\":\"ALL\",\"iter\":3,\"commit\":\"$SHA2\",\"coverage\":[\"US-001\"]}"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "ALL record with coverage subset -> build" || no "coverage subset must be build"

print -r -- "-- behavioral: adversarial — worker-writable strings never flip the mode"
mkln "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA1\"}"
DC="$TMP/done-claim.json"; SIG="$TMP/iter-signal.json"
printf '{"us_id":"ALL","verification_mode":"confirmation"}' > "$DC"
printf '{"us_id":"ALL","verification_mode":"confirmation"}' > "$SIG"
[[ $(mode_of "$L" "$PRD" "$FIX") == build ]] \
  && ok "confirmation strings in done-claim/iter-signal do not flip build->confirmation" \
  || no "derivation must ignore worker-writable files entirely"

print -r -- "-- behavioral: ledger appends carry SHA and the file is locked between appends"
LEDGER_OUT="$TMP/append.jsonl"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
  ITERATION=4; ROOT="'"$FIX"'"; VERIFIED_LEDGER="'"$LEDGER_OUT"'"
  _append_verified_ledger "US-001"
  _append_verified_ledger_all "US-001,US-002"
'
jq -e --arg s "$SHA2" 'select(.us_id=="US-001") | .commit==$s' "$LEDGER_OUT" >/dev/null 2>&1 \
  && ok "per-US append records current HEAD SHA" || no "per-US append missing commit SHA"
jq -e --arg s "$SHA2" 'select(.us_id=="ALL") | .commit==$s and (.coverage==["US-001","US-002"])' "$LEDGER_OUT" >/dev/null 2>&1 \
  && ok "ALL record carries SHA + coverage array" || no "ALL record missing SHA/coverage"
perms=$(stat -f %Lp "$LEDGER_OUT" 2>/dev/null || stat -c %a "$LEDGER_OUT")
[[ "$perms" == "444" ]] \
  && ok "ledger is 0444 between appends (append-then-lock)" || no "ledger not locked (perms=$perms)"

print -r -- "-- structural: leader wiring + prompt channel"
grep -q "derive_verification_mode" "$RUN" \
  && ok "run_ralph_desk.zsh calls derive_verification_mode" || no "leader never derives the mode"
grep -q "verification_mode=" "$RUN" \
  && ok "leader logs [FLOW] verification_mode=" || no "no [FLOW] verification_mode log"
grep -q "Verification Mode (leader-derived, authoritative)" "$RUN" \
  && ok "verifier prompt carries the leader mode line" || no "prompt mode line missing"
grep -q "Iteration window start" "$RUN" \
  && ok "verifier prompt carries the iteration window start" || no "iteration window missing from prompt"
grep -q "ONLY from this prompt" "$RUN" \
  && ok "prompt pins mode channel: read ONLY from prompt (iter-signal/done-claim ignored)" \
  || no "single-channel instruction missing"
grep -q "_append_verified_ledger_all" "$LIB" \
  && ok "ALL completion record writer exists in lib" || no "_append_verified_ledger_all missing"

print -r -- "-- structural: audit contract text (template + governance)"
grep -q "confirmation" "$INIT" && grep -qi "confirmation mode" "$INIT" \
  && ok "verifier template 10.5 documents the confirmation contract" \
  || no "template lacks confirmation contract"
grep -qi "confirmation mode" "$GOV" && grep -q "verify_existing" "$GOV" \
  && ok "governance defines confirmation as leader-gated superset of verify_existing" \
  || no "governance lacks confirmation contract"

print -r -- "-- structural: AC3 regression — PR-A operator recovery stays intact"
grep -q "_validate_operator_recovery_artifacts" "$RUN" \
  && ok "PR-A validation still wired at startup" || no "PR-A wiring gone"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
