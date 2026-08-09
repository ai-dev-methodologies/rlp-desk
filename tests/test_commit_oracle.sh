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
  # G3: claimKind (build|confirmation) picks the non-commit step that decides the
  # not-build predicate; treeDelta (empty|nonempty|root) decides whether the
  # worker commit is a REAL commit, `git commit --allow-empty`, or a parentless
  # root commit. Defaults keep every pre-G3 caller unchanged.
  local claimKind="${6:-build}" treeDelta="${7:-nonempty}"
  local R="$TMP/$name"; mkdir -p "$R"
  _g "$R" init
  _g "$R" config user.email t@e.com; _g "$R" config user.name t; _g "$R" config commit.gpgsign false
  local ISH="" PRE=""
  [[ "$advance" != "first-commit" ]] && { echo v1 > "$R/a.txt"; _g "$R" add a.txt; _g "$R" commit -m baseline; }
  # The commit this iteration's claim points at: empty tree delta vs real work.
  _worker_commit(){
    if [[ "$treeDelta" == "empty" || "$treeDelta" == "root" ]]; then
      _g "$R" commit --allow-empty -m worker
    else
      echo v1 > "$R/b.txt"; _g "$R" add b.txt; _g "$R" commit -m worker
    fi
  }
  case "$advance" in
    prior-only-lie)
      echo v1 > "$R/b.txt"; _g "$R" add b.txt; _g "$R" commit -m prior
      ISH=$(_grev "$R")            # snapshot == current HEAD; NO new commit this iter
      ;;
    none)
      ISH=$(_grev "$R") ;;         # snapshot == current HEAD; NO new commit this iter
    this-iter)
      ISH=$(_grev "$R")
      _worker_commit ;;
    first-commit)
      ISH=""                       # repo had no commits at iteration start
      _worker_commit ;;
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
  # claimKind → the step the not-build predicate keys on: a build claim carries
  # write_test, a confirmation/verification claim carries verify_existing.
  local LEAD='{"step":"write_test","exit_code":0}'
  [[ "$claimKind" == "build" ]] || LEAD='{"step":"verify_existing","exit_code":0}'
  if [[ "$commitStep" == "true" ]]; then
    if [[ "$commitSha" == "absent" ]]; then
      jq -n --argjson lead "$LEAD" '{execution_steps:[$lead,{step:"commit",exit_code:0}]}' > "$DC"
    else
      jq -n --argjson lead "$LEAD" --arg s "$SHA" '{execution_steps:[$lead,{step:"commit",exit_code:0,commit_sha:$s}]}' > "$DC"
    fi
  else
    jq -n --argjson lead "$LEAD" '{execution_steps:[$lead,{step:"test",exit_code:0}]}' > "$DC"
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
  cKind=$(jq -r ".scenarios[$i].claimKind // \"build\"" "$MATRIX")
  cDelta=$(jq -r ".scenarios[$i].commitTreeDelta // \"nonempty\"" "$MATRIX")
  eReason=$(jq -r ".scenarios[$i].expectReason // \"\"" "$MATRIX")
  line=$(build_repo "$name" "$cS" "$cSha" "$adv" "$dty" "$cKind" "$cDelta")
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
  # expectReason rows pin the cross-leader reason STRING (the Node mirror asserts
  # the same field against evaluateCommitOracle).
  if [[ -n "$eReason" ]]; then
    [[ "$out" == *"REASON=$eReason"* ]] \
      && ok "$name reason=$eReason (cross-leader parity)" \
      || no "$name — want REASON=$eReason; got: $out"
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

print -r -- "== G3: empty-commit anti-fabrication (_commit_oracle_empty_tree) =="
# 1. Healthy repo: empty commit → rc 0 (empty), real commit → rc 1 (nonempty),
#    root commit → rc 3 (unknown, no parent to diff against).
line=$(build_repo g3-empty true head this-iter clean confirmation empty)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="'"$R"'"
  _commit_oracle_empty_tree "$(git -C "$ROOT" rev-parse HEAD)"; print "EMPTY=[$?]"
  _commit_oracle_empty_tree "$(git -C "$ROOT" rev-parse HEAD^)"; print "ROOT=[$?]"
')
[[ "$out" == *"EMPTY=[0]"* ]] && ok "empty commit → rc 0 (tree equals parent)" \
  || no "empty commit probe wrong ($out)"
[[ "$out" == *"ROOT=[3]"* ]] && ok "root commit → rc 3 (unknown, parent unavailable)" \
  || no "root commit probe wrong ($out)"
line=$(build_repo g3-real true head this-iter clean confirmation nonempty)
R="${line%%$'\t'*}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="'"$R"'"
  _commit_oracle_empty_tree "$(git -C "$ROOT" rev-parse HEAD)"; print "REAL=[$?]"
')
[[ "$out" == *"REAL=[1]"* ]] && ok "real commit → rc 1 (non-empty tree delta)" \
  || no "real commit probe wrong ($out)"

# 2. C3 EXPECTED class — shallow clone: the tip's parent is grafted away, so the
#    probe must report unknown (rc 3) and the oracle must ACCEPT, never rc 2.
ORIGIN="$TMP/g3-origin"; mkdir -p "$ORIGIN"
_g "$ORIGIN" init
_g "$ORIGIN" config user.email t@e.com; _g "$ORIGIN" config user.name t; _g "$ORIGIN" config commit.gpgsign false
echo v1 > "$ORIGIN/a.txt"; _g "$ORIGIN" add a.txt; _g "$ORIGIN" commit -m baseline
echo v1 > "$ORIGIN/b.txt"; _g "$ORIGIN" add b.txt; _g "$ORIGIN" commit -m second
SHALLOW="$TMP/g3-shallow"
git clone -q --depth 1 "file://$ORIGIN" "$SHALLOW" >/dev/null 2>&1
TIP=$(_grev "$SHALLOW")
jq -n --arg s "$TIP" '{execution_steps:[{step:"verify_existing",exit_code:0},{step:"commit",exit_code:0,commit_sha:$s}]}' > "$TMP/g3-shallow-dc.json"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  ROOT="'"$SHALLOW"'"; CAMPAIGN_PREEXISTING_DIRTY=""
  _commit_oracle_empty_tree "'"$TIP"'"; print "PROBE=[$?]"
  _commit_oracle_check "'"$TMP"'/g3-shallow-dc.json" ""; print "RC=$? REASON=$ORACLE_REASON"
')
[[ "$out" == *"PROBE=[3]"* && "$out" == *"RC=0"* ]] \
  && ok "C3 expected class: shallow-clone tip → unknown → accept (never rc 2)" \
  || no "C3 shallow-clone handling wrong ($out)"

# 3. C3 GENUINE-FAILURE class — a git error inside the probe keeps the GIT-FC
#    rc-2 path (it must NOT be swallowed into unknown/accept).
line=$(build_repo g3-giterr true head this-iter clean confirmation empty)
R="${line%%$'\t'*}"; rest="${line#*$'\t'}"
ISH="${rest%%$'\t'*}"; rest="${rest#*$'\t'}"; DC="${rest%%$'\t'*}"; PRE="${rest#*$'\t'}"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  sleep(){ :; }
  git(){ case "$*" in *"diff --quiet"*) return 128;; *) command git "$@";; esac }
  ROOT="'"$R"'"; CAMPAIGN_PREEXISTING_DIRTY="'"$PRE"'"
  _commit_oracle_empty_tree "$(command git -C "$ROOT" rev-parse HEAD)"; print "PROBE=[$?]"
  _commit_oracle_check "'"$DC"'" "'"$ISH"'"; print "RC=$? REASON=$ORACLE_REASON"
')
[[ "$out" == *"PROBE=[2]"* && "$out" == *"RC=2"* && "$out" == *"REASON=git_facts_unavailable"* ]] \
  && ok "C3 genuine class: git error in the probe → rc 2 + git_facts_unavailable (GIT-FC preserved)" \
  || no "C3 genuine git failure must stay infra ($out)"

# 4. Fix contract branches on the empty-commit reason: DROP the commit, never
#    "create the commit" (which would re-fabricate it).
LOGS2="$TMP/logs-g3"; mkdir -p "$LOGS2"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  LOGS_DIR="'"$LOGS2"'"; ORACLE_FAILURES=0; _ORACLE_FAIL_US=""; ORACLE_FAIL_CAP=3
  ORACLE_REASON="empty_commit_on_confirmation_claim"
  ORACLE_DETAIL="claimed commit abc1234567 has the same tree as its parent (empty commit)."
  _oracle_register_fail 9 US-001; print "RC=$?"
')
C2="$LOGS2/iter-009.fix-contract.md"
if [[ -f "$C2" ]] && grep -qi 'drop the empty commit' "$C2" && ! grep -q 'Actually create the commit' "$C2"; then
  ok "empty-commit fix contract instructs DROPPING the commit (no re-fabrication)"
else
  no "empty-commit fix contract wrong ($(cat "$C2" 2>/dev/null | tail -3))"
fi
# LOW-4 (SV gate): the preamble above the Next Iteration Contract must not
# contradict it. A commit DID land on this reason (its tree just equals its
# parent's) — the generic "did not actually land / left tracked files
# uncommitted" framing is false here and was mutation-verified to be
# present before this fix.
if grep -qi 'evidence of nothing' "$C2" \
  && ! grep -q 'did not actually land' "$C2" \
  && ! grep -q 'left tracked files uncommitted' "$C2"; then
  ok "empty-commit fix contract preamble accurately describes the breach (no longer claims the commit did not land)"
else
  no "empty-commit fix contract preamble still contradicts its own DROP instruction ($(cat "$C2" 2>/dev/null | head -6))"
fi
# The generic commit-integrity reason keeps the original create-the-commit wording.
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  LOGS_DIR="'"$LOGS2"'"; ORACLE_FAILURES=0; _ORACLE_FAIL_US=""; ORACLE_FAIL_CAP=3
  ORACLE_REASON="head_not_advanced"; ORACLE_DETAIL="HEAD did not advance."
  _oracle_register_fail 10 US-001; print "RC=$?"
')
grep -q 'Actually create the commit' "$LOGS2/iter-010.fix-contract.md" 2>/dev/null \
  && ok "non-empty-commit reasons keep the create-the-commit contract" \
  || no "generic commit-integrity contract regressed"
# Note: "did not actually land" is word-wrapped across two `echo` lines in
# the source (single-line grep can't match it) — assert both fragments
# separately instead.
if grep -q 'A commit that did not' "$LOGS2/iter-010.fix-contract.md" 2>/dev/null \
  && grep -q 'actually land' "$LOGS2/iter-010.fix-contract.md" 2>/dev/null; then
  ok "non-empty-commit reasons keep the original preamble wording (LOW-4 branch did not disturb the else arm)"
else
  no "generic commit-integrity preamble regressed"
fi

print -r -- "== G3.a: generated worker prompt forbids the fabricated empty commit =="
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
grep -q 'Commit all changes when the iteration is complete' "$INIT" \
  && no "init still carries the UNCONDITIONAL commit bullet" \
  || ok "init no longer carries the unconditional 'commit when the iteration is complete' bullet"
grep -qi 'empty commit' "$INIT" \
  && ok "init carries the empty-commit prohibition" \
  || no "init is missing the empty-commit prohibition"
grep -q 'verify_existing' "$INIT" \
  && ok "init names the verification/confirmation pass exemption" \
  || no "init does not name verify_existing in the commit rule"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
