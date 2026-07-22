#!/usr/bin/env zsh
# request-m ②: run-scoped artifact archive (evidence preservation). Four cases:
#   (a) leader-startup batch move — archive_superseded_run_artifacts relocates a
#       prior run's iter-* into runs/superseded-<ts>/ (originals gone from live,
#       content intact) BEFORE the new run can clobber same-numbered files.
#   (b) init --mode fresh archives instead of deletes (incl. verified.jsonl).
#   (c) archive_iter_artifacts now includes the iter-signal (3rd artifact).
#   (d) an archived verdict is a valid `ledger-seed --evidence` input end-to-end.
set -uo pipefail
unset TMUX 2>/dev/null
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
RUN_MJS="$REPO/src/node/run.mjs"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# (a) leader-startup batch move
# ---------------------------------------------------------------------------
LA="$TMP/a/logs/demo"; mkdir -p "$LA"
printf 'dc\n'  > "$LA/iter-001-done-claim.json"
printf 'vv\n'  > "$LA/iter-001-verify-verdict.json"
printf 'sig\n' > "$LA/iter-001-iter-signal.json"
printf 'prompt\n' > "$LA/iter-001.worker-prompt.md"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_error(){ :; }; log_warn(){ :; }
  archive_superseded_run_artifacts "'"$LA"'" "20260722-140000"'
_live=("$LA"/iter-*(N))
_arch="$LA/runs/superseded-20260722-140000"
if (( ${#_live} == 0 )) && [[ -d "$_arch" ]]; then
  ok "(a) leader-startup: live dir has no iter-* after archive"
  [[ -f "$_arch/iter-001-done-claim.json" && -f "$_arch/iter-001-iter-signal.json" \
     && -f "$_arch/iter-001.worker-prompt.md" ]] \
    && ok "(a) all 4 iter-* artifacts relocated into runs/superseded-<ts>/" \
    || no "(a) some artifacts not relocated: $(ls "$_arch" 2>/dev/null)"
  [[ "$(cat "$_arch/iter-001-verify-verdict.json")" == "vv" ]] \
    && ok "(a) archived content intact" || no "(a) content corrupted"
else
  no "(a) live iter-* not cleared or archive dir missing (live=${#_live} arch=$_arch)"
fi
# idempotent-ish: a second call with no iter-* present is a clean no-op.
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_error(){ :; }; log_warn(){ :; }
  archive_superseded_run_artifacts "'"$LA"'" "20260722-150000"' 2>/dev/null
[[ ! -d "$LA/runs/superseded-20260722-150000" ]] \
  && ok "(a) no-op when no iter-* remain (no empty archive dir created)" \
  || no "(a) created a spurious empty archive dir"

# ---------------------------------------------------------------------------
# (b) init --mode fresh archives evidence (incl. verified.jsonl) instead of rm
# ---------------------------------------------------------------------------
BROOT="$TMP/b"; mkdir -p "$BROOT"
ROOT="$BROOT" zsh "$INIT" demo "obj" >/dev/null 2>&1
BD="$BROOT/.rlp-desk"
printf 'dc\n'  > "$BD/logs/demo/iter-001-done-claim.json"
printf 'vv\n'  > "$BD/logs/demo/iter-001-verify-verdict.json"
printf 'sig\n' > "$BD/logs/demo/iter-001-iter-signal.json"
printf '{"us_id":"US-001","verdict":"pass"}\n' > "$BD/memos/demo-verified.jsonl"
chmod 0444 "$BD/memos/demo-verified.jsonl"   # ledger is 0444 between appends
printf 'dc\n' > "$BD/memos/demo-done-claim.json"
printf 'vv\n' > "$BD/memos/demo-verify-verdict.json"
ROOT="$BROOT" zsh "$INIT" demo --mode fresh >/dev/null 2>&1
# live evidence paths emptied
_bfail=0
[[ -f "$BD/memos/demo-verified.jsonl" ]] && _bfail=1
(( ${#$(echo "$BD/logs/demo"/iter-*(N))} )) 2>/dev/null && _bfail=1
_bliveiters=("$BD/logs/demo"/iter-*(N))
{ (( ${#_bliveiters} == 0 )) && [[ ! -f "$BD/memos/demo-verified.jsonl" ]] } \
  && ok "(b) init fresh emptied the LIVE evidence paths (iter-*, verified.jsonl)" \
  || no "(b) live evidence not emptied (iters=${#_bliveiters}, ledger present=$([[ -f $BD/memos/demo-verified.jsonl ]] && echo yes||echo no))"
# bytes survive under runs/
_barch=("$BD/logs/demo/runs/"superseded-*(N))
if (( ${#_barch} >= 1 )); then
  _bd="${_barch[1]}"
  [[ -f "$_bd/demo-verified.jsonl" && "$(cat "$_bd/demo-verified.jsonl")" == '{"us_id":"US-001","verdict":"pass"}' ]] \
    && ok "(b) verified.jsonl relocated into runs/ with content intact (0444 ledger moved OK)" \
    || no "(b) verified.jsonl not archived intact"
  [[ -f "$_bd/iter-001-verify-verdict.json" && -f "$_bd/iter-001-iter-signal.json" ]] \
    && ok "(b) iter-* evidence relocated into runs/ (incl. iter-signal)" \
    || no "(b) iter-* not archived: $(ls "$_bd" 2>/dev/null)"
else
  no "(b) no runs/superseded-* archive dir created by init fresh"
fi

# ---------------------------------------------------------------------------
# (c) archive_iter_artifacts includes iter-signal (3rd artifact)
# ---------------------------------------------------------------------------
_c=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  D=$(mktemp -d)
  LOGS_DIR="$D/logs"; mkdir -p "$LOGS_DIR"
  DONE_CLAIM_FILE="$D/dc.json"; VERDICT_FILE="$D/vv.json"; SIGNAL_FILE="$D/sig.json"
  echo dc > "$DONE_CLAIM_FILE"; echo vv > "$VERDICT_FILE"; echo sig > "$SIGNAL_FILE"
  archive_iter_artifacts 5
  for suffix in done-claim verify-verdict iter-signal; do
    [[ -f "$LOGS_DIR/iter-005-$suffix.json" ]] && print "HAVE:$suffix"
  done
  rm -rf "$D"')
{ [[ "$_c" == *HAVE:done-claim* && "$_c" == *HAVE:verify-verdict* && "$_c" == *HAVE:iter-signal* ]] } \
  && ok "(c) archive_iter_artifacts writes iter-NNN-{done-claim,verify-verdict,iter-signal}.json" \
  || no "(c) missing an archived artifact: $_c"

# ---------------------------------------------------------------------------
# (d) an archived verdict is a valid ledger-seed --evidence input end-to-end
# ---------------------------------------------------------------------------
FIX="$TMP/d/fix"; mkdir -p "$FIX/.rlp-desk/plans" "$FIX/.rlp-desk/memos"
mkdir -p "$FIX/.rlp-desk/logs/demo/runs/superseded-20260722-160000"
cd "$FIX"
git init -q; git config user.email t@t; git config user.name t
echo one > a.txt; git add a.txt; git commit -qm c1
printf '### US-000: Zero\n- AC1: a\n' > "$FIX/.rlp-desk/plans/prd-demo.md"
# the evidence lives ONLY in the archive (models the recovery scenario)
ARCH_EV="$FIX/.rlp-desk/logs/demo/runs/superseded-20260722-160000/iter-001-verify-verdict.json"
printf '{"us_id":"US-000","verdict":"pass"}' > "$ARCH_EV"
LEDGER="$FIX/.rlp-desk/memos/demo-verified.jsonl"
seed_out=$(node "$RUN_MJS" ledger-seed demo US-000 --evidence "$ARCH_EV" --note "re-seed from archived verdict" 2>&1); seed_rc=$?
{ [[ $seed_rc -eq 0 && -f "$LEDGER" ]] && grep -q '"seeded":true' "$LEDGER" } \
  && ok "(d) ledger-seed --evidence <archived verdict path> succeeds end-to-end" \
  || no "(d) ledger-seed rejected the archived path (rc=$seed_rc): $seed_out"
cd "$REPO"

# ---------------------------------------------------------------------------
# (e) COLLISION — leader-startup: two archive calls with a FORCED identical label
# (two leader starts in the same wall-clock second) must NOT overwrite; both
# survive in distinct dirs (superseded-<ts>/ and superseded-<ts>-2/), byte-intact.
# ---------------------------------------------------------------------------
LC="$TMP/e/logs/demo"; mkdir -p "$LC"
printf 'RUN1\n' > "$LC/iter-001-verify-verdict.json"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_error(){ :; }; log_warn(){ :; }
  archive_superseded_run_artifacts "'"$LC"'" "20260722-170000"'
printf 'RUN2\n' > "$LC/iter-001-verify-verdict.json"   # a second run, SAME label, SAME iter number
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_error(){ :; }; log_warn(){ :; }
  archive_superseded_run_artifacts "'"$LC"'" "20260722-170000"'
_d1="$LC/runs/superseded-20260722-170000"
_d2="$LC/runs/superseded-20260722-170000-2"
if [[ -f "$_d1/iter-001-verify-verdict.json" && -f "$_d2/iter-001-verify-verdict.json" ]]; then
  ok "(e) same-label collision: both archives survive in distinct dirs (-<ts> and -<ts>-2)"
  { [[ "$(cat "$_d1/iter-001-verify-verdict.json")" == "RUN1" ]] \
    && [[ "$(cat "$_d2/iter-001-verify-verdict.json")" == "RUN2" ]] } \
    && ok "(e) both archived copies byte-intact (RUN1 in base, RUN2 in -2 — no overwrite/merge)" \
    || no "(e) content wrong (d1=$(cat "$_d1/iter-001-verify-verdict.json") d2=$(cat "$_d2/iter-001-verify-verdict.json"))"
else
  no "(e) collision not disambiguated (d1=$([[ -f $_d1/iter-001-verify-verdict.json ]] && echo yes||echo no) d2=$([[ -f $_d2/iter-001-verify-verdict.json ]] && echo yes||echo no))"
fi

# ---------------------------------------------------------------------------
# (f) COLLISION — init path: a same-second prior archive is not overwritten.
# Pre-seed superseded-<S..S+4>/PRIOR.txt (covers whichever second init lands in),
# then init --mode fresh must disambiguate into a -N dir and leave every
# pre-seeded sentinel untouched.
# ---------------------------------------------------------------------------
FROOT="$TMP/f"; mkdir -p "$FROOT"
ROOT="$FROOT" zsh "$INIT" demo "obj" >/dev/null 2>&1
FD="$FROOT/.rlp-desk"
printf '{"us_id":"US-001","verdict":"pass"}\n' > "$FD/memos/demo-verified.jsonl"
printf 'vv\n' > "$FD/logs/demo/iter-001-verify-verdict.json"
# pre-seed the archive dir for a window of seconds so init is guaranteed to collide
RUNS="$FD/logs/demo/runs"; mkdir -p "$RUNS"
for _off in 0 1 2 3 4; do
  _s=$(date -v+${_off}S +%Y%m%d-%H%M%S 2>/dev/null)
  [[ -n "$_s" ]] && { mkdir -p "$RUNS/superseded-$_s"; printf 'PRIOR\n' > "$RUNS/superseded-$_s/PRIOR.txt"; }
done
ROOT="$FROOT" zsh "$INIT" demo --mode fresh >/dev/null 2>&1
# init's evidence must be in a disambiguated -N dir (never in a pre-seeded base).
_dis=("$RUNS"/superseded-*-[0-9](N/))
_found_evidence=0
for _dd in "${_dis[@]}"; do
  [[ -f "$_dd/demo-verified.jsonl" ]] && _found_evidence=1 && _evidence_dir="$_dd"
done
if (( _found_evidence )); then
  ok "(f) init same-second collision disambiguates into ${_evidence_dir:t} (not the pre-seeded base)"
  [[ "$(cat "$_evidence_dir/demo-verified.jsonl")" == '{"us_id":"US-001","verdict":"pass"}' ]] \
    && ok "(f) init-archived verified.jsonl byte-intact in the disambiguated dir" \
    || no "(f) init evidence content wrong"
else
  no "(f) init did not disambiguate — evidence not found in any superseded-*-N dir ($(ls "$RUNS" 2>/dev/null))"
fi
# every pre-seeded sentinel dir is UNTOUCHED (only PRIOR.txt, no init evidence merged in).
_clobbered=0
for _pd in "$RUNS"/superseded-[0-9]*(N/); do
  [[ "${_pd:t}" == *-[0-9] ]] && continue   # skip disambiguated dirs
  { [[ -f "$_pd/PRIOR.txt" ]] && [[ ! -f "$_pd/demo-verified.jsonl" ]] } || _clobbered=1
done
(( _clobbered == 0 )) \
  && ok "(f) all pre-seeded same-second dirs left untouched (no overwrite/merge)" \
  || no "(f) a pre-seeded archive dir was overwritten/merged by init"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
