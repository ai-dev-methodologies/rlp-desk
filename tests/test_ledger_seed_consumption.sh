#!/usr/bin/env zsh
# request-f §3: end-to-end — the operator `ledger-seed` CLI writes a verified-
# ledger entry that the story-scoped consumer (derive_verification_mode's
# request-e ② 4th-arg path) actually honors. This is the recovery path for a
# story that could never earn a consensus pass (an old-version defect): the
# seed routes verification MODE, it does NOT grant a pass.
#
# Fixture drives the REAL CLI (node run.mjs ledger-seed) from the fixture cwd,
# then sources lib_ralph_desk.zsh and asserts derive_verification_mode.
set -uo pipefail
unset TMUX 2>/dev/null   # copy-mode/pane guards must never engage in a test
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN_MJS="$REPO/src/node/run.mjs"
SLUG="demo"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Fixture git repo with a committed anchor and an untracked .rlp-desk runtime
# tree (mirrors production: .rlp-desk is gitignored, so PRD/ledger are invisible
# to the tracked-tree gate).
FIX="$TMP/fix"; mkdir -p "$FIX/.rlp-desk/plans" "$FIX/.rlp-desk/memos"; cd "$FIX"
git init -q; git config user.email t@t; git config user.name t
echo one > a.txt; git add a.txt; git commit -qm c1
HEAD_SHA=$(git rev-parse HEAD)

PRD="$FIX/.rlp-desk/plans/prd-$SLUG.md"
printf '### US-000: Zero\n- AC1: a\n### US-001: One\n- AC1: b\n' > "$PRD"
LEDGER="$FIX/.rlp-desk/memos/$SLUG-verified.jsonl"

# Claude-leg pass verdict for US-000 (the evidence the operator captured).
EV="$FIX/verdict-us000.json"
printf '{"us_id":"US-000","verdict":"pass"}' > "$EV"

# --- run the REAL operator CLI from the fixture cwd ---
seed_out=$(node "$RUN_MJS" ledger-seed "$SLUG" US-000 \
  --evidence "$EV" --note "claude fresh x2 pass; codex old-doctrine fail" 2>&1)
seed_rc=$?
[[ $seed_rc -eq 0 && -f "$LEDGER" ]] \
  && ok "CLI ledger-seed exits 0 and creates the ledger" \
  || no "CLI ledger-seed failed (rc=$seed_rc): $seed_out"
grep -q '"seeded":true' "$LEDGER" && grep -q '"operator_note"' "$LEDGER" \
  && ok "seed entry is audit-visible (seeded:true + operator_note)" \
  || no "seed entry missing audit fields: $(cat "$LEDGER")"

# Driver: source lib in a clean zsh, stub loggers, call derive with optional 4th arg.
derive() { # $1=ledger $2=prd $3=root [$4=us_id]
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }; log_warn(){ :; }
    derive_verification_mode "$1" "$2" "$3" "${4:-}"
  ' _ "$1" "$2" "$3" "${4:-}"
}
mode_of(){ derive "$@" | head -1 | cut -d'|' -f1; }

print -r -- "-- consumer honors the seeded story (story-scoped path)"
out=$(derive "$LEDGER" "$PRD" "$FIX" US-000)
[[ "$out" == confirmation\|story-scoped:\ US-000* ]] \
  && ok "seeded US-000 -> confirmation|story-scoped (v0.22.14 4th-arg path consumes the seed)" \
  || no "seeded story should confirm, got: $out"

print -r -- "-- seed is PRD-bound: editing the PRD demotes to build"
cp "$PRD" "$TMP/prd.bak"
printf '### US-000: Zero\n- AC1: a EDITED\n### US-001: One\n- AC1: b\n' > "$PRD"
[[ $(mode_of "$LEDGER" "$PRD" "$FIX" US-000) == build ]] \
  && ok "PRD drift -> build (seed does not survive a plan change)" \
  || no "PRD drift must demote to build"
cp "$TMP/prd.bak" "$PRD"   # restore

print -r -- "-- a single seed must not over-grant campaign-wide confirmation"
[[ $(mode_of "$LEDGER" "$PRD" "$FIX") == build ]] \
  && ok "full-coverage path (no 4th arg) with only US-000 seeded -> build (US-001 unverified)" \
  || no "one seeded story must not confirm the whole campaign"

print -r -- "-- an unseeded story stays build"
[[ $(mode_of "$LEDGER" "$PRD" "$FIX" US-001) == build ]] \
  && ok "unseeded US-001 -> build (no PRD-bound entry for it)" \
  || no "unseeded story must be build"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
