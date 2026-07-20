#!/usr/bin/env zsh
# US-001 — leader-side done-claim commit-integrity oracle: zsh behavioral tests.
#
# Sources the REAL lib helpers (_commit_oracle_check, _commit_oracle_tracked_dirty,
# _oracle_bump, _oracle_register_fail) and drives the SHARED parity matrix
# (tests/fixtures/commit-oracle/matrix.json — the same matrix
# tests/node/test-done-claim-commit-oracle.test.mjs feeds the Node pure predicate,
# AC1.6) against REAL temp git repos. Also exercises the fix-contract renderer
# (US-003 jq fallback chain), the ORACLE_FAIL_CAP force-verifier decision, and the
# call-site ordering (oracle BEFORE the pre-gate).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
MATRIX="$REPO/tests/fixtures/commit-oracle/matrix.json"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

_g(){ git -C "$1" "${@:2}" >/dev/null 2>&1; }
_grev(){ git -C "$1" rev-parse "${2:-HEAD}" 2>/dev/null; }

# Build a real git repo realizing a matrix recipe. Prints a tab line:
#   <root>\t<iter_start_head>\t<done_claim_file>\t<preexisting_csv>
build_repo(){
  local name="$1" commitStep="$2" commitSha="$3" advance="$4" dirty="$5"
  local R="$TMP/$name"; mkdir -p "$R"
  _g "$R" init
  _g "$R" config user.email t@e.com; _g "$R" config user.name t; _g "$R" config commit.gpgsign false
  local ISH="" PRE=""
  [[ "$advance" != "first-commit" ]] && { echo v1 > "$R/a.txt"; _g "$R" add a.txt; _g "$R" commit -m baseline; }
  case "$advance" in
    prior-only-lie)
      echo v1 > "$R/b.txt"; _g "$R" add b.txt; _g "$R" commit -m prior
      ISH=$(_grev "$R")            # snapshot == current HEAD; NO new commit this iter
      ;;
    none)
      ISH=$(_grev "$R") ;;         # snapshot == current HEAD; NO new commit this iter
    this-iter)
      ISH=$(_grev "$R")
      echo v1 > "$R/b.txt"; _g "$R" add b.txt; _g "$R" commit -m worker ;;
    first-commit)
      ISH=""                       # repo had no commits at iteration start
      echo v1 > "$R/b.txt"; _g "$R" add b.txt; _g "$R" commit -m worker ;;
  esac
  local HEADSHA; HEADSHA=$(_grev "$R")
  case "$dirty" in
    tracked)     echo v2 > "$R/a.txt" ;;                      # tracked file left modified
    untracked)   echo noise > "$R/scratch.log" ;;             # untracked cruft only
    preexisting) echo wip > "$R/a.txt"; PRE="a.txt" ;;        # dirty tracked file, declared preexisting
  esac
  local SHA=""
  case "$commitSha" in
    head)        SHA="$HEADSHA" ;;
    bogus)       SHA="dddddddddddddddddddddddddddddddddddddddd" ;;
    unreachable) SHA=$(git -C "$R" commit-tree "$(git -C "$R" rev-parse HEAD^{tree})" -m sib 2>/dev/null) ;;
    absent)      SHA="" ;;
  esac
  local DC="$R/done-claim.json"
  if [[ "$commitStep" == "true" ]]; then
    if [[ "$commitSha" == "absent" ]]; then
      jq -n '{execution_steps:[{step:"commit",exit_code:0}]}' > "$DC"
    else
      jq -n --arg s "$SHA" '{execution_steps:[{step:"commit",exit_code:0,commit_sha:$s}]}' > "$DC"
    fi
  else
    jq -n '{execution_steps:[{step:"test",exit_code:0}]}' > "$DC"
  fi
  printf '%s\t%s\t%s\t%s\n' "$R" "$ISH" "$DC" "$PRE"
}

# Invoke the REAL _commit_oracle_check in a clean sourced-lib zsh.
run_check(){ # $1=root $2=iter_start_head $3=done_claim $4=preexisting_csv
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$1"'"
    CAMPAIGN_PREEXISTING_DIRTY="'"$4"'"
    _commit_oracle_check "'"$3"'" "'"$2"'"; rc=$?
    print "RC=$rc ASSERTED=${ORACLE_ASSERTED} REASON=${ORACLE_REASON}"
  '
}

print -r -- "== shared parity matrix (zsh _commit_oracle_check vs real git) =="
_n=$(jq '.scenarios | length' "$MATRIX")
for (( i=0; i<_n; i++ )); do
  name=$(jq -r ".scenarios[$i].name" "$MATRIX")
  # GIT-FC (IMP-09): gitError rows need a shimmed git failure (rc 2 / infra) and
  # are asserted in the dedicated GIT-FC block below, not this asserted/ok loop.
  [[ "$(jq -r ".scenarios[$i].gitError // false" "$MATRIX")" == "true" ]] && continue
  cS=$(jq -r ".scenarios[$i].commitStep" "$MATRIX")
  cSha=$(jq -r ".scenarios[$i].commitSha" "$MATRIX")
  adv=$(jq -r ".scenarios[$i].advance" "$MATRIX")
  dty=$(jq -r ".scenarios[$i].dirty" "$MATRIX")
  eAss=$(jq -r ".scenarios[$i].expectAsserted" "$MATRIX")
  eOk=$(jq -r ".scenarios[$i].expectOk" "$MATRIX")
  line=$(build_repo "$name" "$cS" "$cSha" "$adv" "$dty")
  R="${line%%$'\t'*}"; rest="${line#*$'\t'}"
  ISH="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"
  DC="${rest%%$'\t'*}"; PRE="${rest#*$'\t'}"
  out=$(run_check "$R" "$ISH" "$DC" "$PRE")
  # expected RC: ok=true → 0 ; ok=false → 1
  want_rc=$([[ "$eOk" == "true" ]] && echo 0 || echo 1)
  want_ass=$([[ "$eAss" == "true" ]] && echo 1 || echo 0)
  if [[ "$out" == *"RC=$want_rc"* && "$out" == *"ASSERTED=$want_ass"* ]]; then
    ok "$name (rc=$want_rc asserted=$want_ass)"
  else
    no "$name — want rc=$want_rc asserted=$want_ass; got: $out"
  fi
done

print -r -- "== _commit_oracle_tracked_dirty excludes untracked + preexisting =="
line=$(build_repo tdirty true head this-iter untracked)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ROOT="'"$R"'"; CAMPAIGN_PREEXISTING_DIRTY=""
  df=$(_commit_oracle_tracked_dirty); print "DIRTY=[$df]"
')
[[ "$out" == *"DIRTY=[]"* ]] && ok "untracked-only → no tracked worker files" \
  || no "untracked-only should yield empty tracked list (got: $out)"

print -r -- "== _oracle_register_fail: COMMIT-INTEGRITY contract via US-003 jq chain =="
LOGS="$TMP/logs"; mkdir -p "$LOGS"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  LOGS_DIR="'"$LOGS"'"; ORACLE_FAILURES=0; _ORACLE_FAIL_US=""; ORACLE_FAIL_CAP=3
  ORACLE_REASON="head_not_advanced+claimed_sha_absent"
  ORACLE_DETAIL="HEAD did not advance beyond the iteration-start snapshot (abc123); claimed commit deadbeef01 does not resolve."
  _oracle_register_fail 7 US-001; rc=$?
  print "RC=$rc"
')
C="$LOGS/iter-007.fix-contract.md"
[[ "$out" == *"RC=0"* ]] && ok "1st oracle fail → returns 0 (short-circuit)" \
  || no "1st oracle fail should return 0 (got: $out)"
[[ -f "$C" ]] && ok "fix contract written" || no "fix contract missing"
grep -q "COMMIT-INTEGRITY FAILURE" "$C" 2>/dev/null && ok "heading present" || no "heading missing"
# The US-003 jq fallback chain renders .id (COMMIT-INTEGRITY) + .description (detail).
grep -q "COMMIT-INTEGRITY\]\?.*does not resolve\|COMMIT-INTEGRITY.*does not resolve" "$C" 2>/dev/null \
  && ok "detail rendered via jq fallback chain" \
  || { grep -q "does not resolve" "$C" 2>/dev/null && ok "detail rendered via jq fallback chain" || no "detail not rendered (contract: $(cat "$C" 2>/dev/null))"; }

print -r -- "== _oracle_bump: same-US cap forces a verifier round on the 3rd fail =="
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  ORACLE_FAILURES=0; _ORACLE_FAIL_US=""; ORACLE_FAIL_CAP=3
  _oracle_bump US-001; print "b1=$?"
  _oracle_bump US-001; print "b2=$?"
  _oracle_bump US-001; print "b3=$?"
')
[[ "$out" == *"b1=0"* && "$out" == *"b2=0"* && "$out" == *"b3=1"* ]] \
  && ok "cap: fails 1,2 short-circuit (0); fail 3 forces verifier (1)" \
  || no "cap decision wrong (got: $out)"

print -r -- "== call-site ordering: oracle runs BEFORE the pre-gate =="
# Structural: in the verify case, _commit_oracle_check must appear before run_pregate.
oline=$(grep -n '_commit_oracle_check "\$DONE_CLAIM_FILE"' "$RUN" | head -1 | cut -d: -f1)
pline=$(grep -n 'run_pregate "\$ITERATION" "\$SLUG"' "$RUN" | head -1 | cut -d: -f1)
if [[ -n "$oline" && -n "$pline" && "$oline" -lt "$pline" ]]; then
  ok "oracle call (L$oline) precedes pre-gate L1 (L$pline)"
else
  no "oracle must precede the pre-gate (oracle=$oline pregate=$pline)"
fi

print -r -- "== GIT-FC (IMP-09): fail-closed git snapshot on the oracle/F-8 paths =="
# Shared git-error parity row: BOTH sides assert its expectReason (Node mirror in
# tests/node/test-done-claim-commit-oracle.test.mjs).
_ge_idx=$(jq -r '.scenarios | map(.gitError == true) | index(true)' "$MATRIX")
_ge_reason=$(jq -r ".scenarios[$_ge_idx].expectReason" "$MATRIX")

# 1. _git_snapshot happy: real repo with a dirty tracked file → prints it, rc 0.
line=$(build_repo gfc-happy true head this-iter tracked)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="'"$R"'"
  o=$(_git_snapshot -C "$ROOT" diff --name-only "$(_git_dirty_base)"); rc=$?
  print "RC=$rc OUT=[$o]"
')
[[ "$out" == *"RC=0"* && "$out" == *"a.txt"* ]] && ok "_git_snapshot happy: prints dirty file, rc 0" \
  || no "_git_snapshot happy wrong ($out)"

# 2. _git_snapshot failure: non-repo dir → rc≠0, EMPTY stdout, [GIT-FC] logged,
#    retried once (2 real git calls — counted via a git shim; sleep stubbed).
: > "$TMP/gfc-err.log"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }
  log_error(){ print -r -- "$*" >> "'"$TMP"'/gfc-err.log"; }
  sleep(){ :; }
  _GC="'"$TMP"'/gcount"; : > "$_GC"
  git(){ print x >> "$_GC"; command git "$@"; }
  o=$(_git_snapshot -C "'"$TMP"'/notrepo" status); rc=$?
  print "RC=$rc OUT=[$o] CALLS=$(grep -c . "$_GC")"
')
if [[ "$out" == *"OUT=[]"* && "$out" != *"RC=0"* && "$out" == *"CALLS=2"* ]] \
   && grep -q '\[GIT-FC\]' "$TMP/gfc-err.log"; then
  ok "_git_snapshot failure: empty stdout, rc≠0, retried once, logged [GIT-FC]"
else
  no "_git_snapshot failure wrong (out=$out err=$(cat "$TMP/gfc-err.log" 2>/dev/null))"
fi

# 3. _commit_oracle_tracked_dirty: git error → rc 2 (NOT rc 0/empty).
line=$(build_repo gfc-td true head this-iter tracked)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  sleep(){ :; }
  git(){ case "$*" in *"diff --name-only"*) return 128;; *) command git "$@";; esac }
  ROOT="'"$R"'"; CAMPAIGN_PREEXISTING_DIRTY=""
  _commit_oracle_tracked_dirty; print "RC=$?"
')
[[ "$out" == *"RC=2"* ]] && ok "_commit_oracle_tracked_dirty: git error → rc 2 (not empty/clean)" \
  || no "_commit_oracle_tracked_dirty infra wrong ($out)"

# 4. _commit_oracle_check: git error → rc 2 + REASON=git_facts_unavailable, with a
#    genuinely DIRTY tree (no false corroboration). THIS IS THE MATRIX PARITY ROW.
line=$(build_repo gfc-check true head this-iter tracked)
R="${line%%$'\t'*}"; rest="${line#*$'\t'}"
ISH="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; DC="${rest%%$'\t'*}"; PRE="${rest#*$'\t'}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  sleep(){ :; }
  git(){ case "$*" in *"diff --name-only"*) return 128;; *) command git "$@";; esac }
  ROOT="'"$R"'"; CAMPAIGN_PREEXISTING_DIRTY="'"$PRE"'"
  _commit_oracle_check "'"$DC"'" "'"$ISH"'"; rc=$?
  print "RC=$rc REASON=$ORACLE_REASON"
')
[[ "$out" == *"RC=2"* && "$out" == *"REASON=$_ge_reason"* ]] \
  && ok "_commit_oracle_check: git error → rc 2 + REASON=$_ge_reason (matrix parity, no false corroboration)" \
  || no "_commit_oracle_check infra wrong (want RC=2 REASON=$_ge_reason; got $out)"

# 5. Gate 3 fail-closed: extract _bug8_check_synth_allowed; Gate 1/2 pass, diff
#    fails → return 1 + infra_failure sentinel, NO auto-commit.
_synth_body=$(sed -n '/^_bug8_check_synth_allowed() {$/,/^}$/p' "$RUN")
line=$(build_repo gfc-gate3 true head this-iter tracked)
R="${line%%$'\t'*}"; rest="${line#*$'\t'}"
ISH="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; DC="${rest%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  '"$_synth_body"'
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  sleep(){ :; }
  SENT="'"$TMP"'/gate3-sentinel.log"; : > "$SENT"
  write_blocked_sentinel(){ print -r -- "REASON=$1 CAT=$3" >> "$SENT"; }
  _emit_a4_fallback_audit(){ :; }
  _COMMITS="'"$TMP"'/gate3-commits.log"; : > "$_COMMITS"
  git(){ case "$*" in
    *"diff --name-only"*) return 128;;
    *" add "*|*" commit -m"*) print x >> "$_COMMITS"; command git "$@";;
    *) command git "$@";;
  esac }
  ROOT="'"$R"'"; DONE_CLAIM_FILE="'"$DC"'"; LOGS_DIR="'"$TMP"'/gate3-logs"; mkdir -p "$LOGS_DIR"
  CAMPAIGN_PREEXISTING_DIRTY=""
  _bug8_check_synth_allowed 1 US-001 clean; print "RC=$?"
  print "SENT=[$(cat "$SENT")]"
  print "COMMITS=$(grep -c . "$_COMMITS")"
')
if [[ "$out" == *"RC=1"* && "$out" == *"CAT=infra_failure"* \
      && "$out" == *"dirty-check failed"* && "$out" == *"COMMITS=0"* ]]; then
  ok "Gate 3 fail-closed: git error → return 1 + infra_failure sentinel, no auto-commit"
else
  no "Gate 3 fail-closed wrong ($out)"
fi

# 6. Site A assignment-form: `if ! VAR=$(_git_snapshot ...)` propagates rc (guards
#    the `local x=$(...)` rc-eating regression).
line=$(build_repo gfc-siteA true head this-iter tracked)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  sleep(){ :; }
  git(){ case "$*" in *"diff --name-only"*) return 128;; *) command git "$@";; esac }
  ROOT="'"$R"'"
  if ! CAMPAIGN_PREEXISTING_DIRTY=$(_git_snapshot -C "$ROOT" diff --name-only "$(_git_dirty_base)"); then
    print "BLOCKED"
  else
    print "PROCEEDED var=[$CAMPAIGN_PREEXISTING_DIRTY]"
  fi
')
[[ "$out" == *"BLOCKED"* ]] && ok "Site A assignment-form: git error propagates through VAR=\$(...) → BLOCKED" \
  || no "Site A rc-eating regression ($out)"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
