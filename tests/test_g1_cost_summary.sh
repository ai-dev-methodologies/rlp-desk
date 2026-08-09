#!/usr/bin/env zsh
# G1-0 — campaign report: stray key=value line regression tests.
#
# Root cause (dogfood-gaps-g1-g4.md §G1-0): `local <name>` with NO assignment,
# applied to an already-existing variable inside a loop, is a zsh `typeset`
# DISPLAY command — it prints `name=<current value>` to stdout on every
# iteration after the first. Two sites in generate_campaign_report()
# (lib_ralph_desk.zsh) had this defect: `local us_id` (Verification Results
# loop) and `local t` (Cost & Performance loop). Fix: hoist the bare
# declaration above its loop so it is declared once, assigned (not
# re-declared) inside.
#
# Sources the REAL generate_campaign_report() (test_commit_oracle.sh style —
# `source "$LIB"` in a clean zsh, stub log/log_debug/log_error, drive it
# against a real temp git repo + real done-claim/cost-log fixtures).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a minimal real campaign dir: git repo ROOT + LOGS_DIR with N
# iter-NNN-done-claim.json (real us_id values) and a 5-row cost-log.jsonl
# (the exact token values from the plan's arithmetic check: 5892, 5888,
# 5613, 5660, 1588 — sum 24641).
setup_campaign() {
  local root="$1" logs="$2" n_iters="$3"
  mkdir -p "$root" "$logs"
  git -C "$root" init -q
  git -C "$root" config user.email t@e.com
  git -C "$root" config user.name t
  git -C "$root" config commit.gpgsign false
  echo v1 > "$root/a.txt"
  git -C "$root" add a.txt
  git -C "$root" commit -q -m baseline
  local i us
  for (( i=1; i<=n_iters; i++ )); do
    us="US-$(printf '%03d' $i)"
    jq -n --arg u "$us" '{us_id:$u}' > "$logs/iter-$(printf '%03d' $i)-done-claim.json"
  done
  : > "$logs/cost-log.jsonl"
  local tok
  for tok in 5892 5888 5613 5660 1588; do
    jq -nc --argjson t "$tok" '{estimated_tokens:$t}' >> "$logs/cost-log.jsonl"
  done
}

# Invoke the REAL generate_campaign_report in a clean sourced-lib zsh.
run_report() { # $1=root $2=logs $3=n_iters
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$1"'"; LOGS_DIR="'"$2"'"; DESK="'"$1"'"; SLUG="g1-test"
    ITERATION='"$3"'; MAX_ITER='"$3"'
    START_TIME=$(date +%s)
    COST_LOG="'"$2"'/cost-log.jsonl"
    CAMPAIGN_REPORT_GENERATED=0
    COMPLETE_SENTINEL="'"$1"'/.complete"; BLOCKED_SENTINEL="'"$1"'/.blocked"
    touch "$COMPLETE_SENTINEL"
    WITH_SELF_VERIFICATION=0; WITH_SELF_VERIFICATION_REQUESTED=0
    WORKER_MODEL=w; WORKER_ENGINE=we; VERIFIER_MODEL=v; VERIFIER_ENGINE=ve
    CONSENSUS_MODE=cm; CONSENSUS_MODEL=cmm; FINAL_CONSENSUS_MODEL=fcm
    VERIFIED_US="US-001"; CONSECUTIVE_FAILURES=0
    generate_campaign_report
    cat "$LOGS_DIR/campaign-report.md"
  '
}

print -r -- "== g1: no stray t= line in a 5-row cost-log report =="
R1="$TMP/repo1"; L1="$TMP/logs1"
setup_campaign "$R1" "$L1" 2
out1=$(run_report "$R1" "$L1" 2)
if print -r -- "$out1" | grep -qE '^t='; then
  no "stray 't=' line present in report body"
else
  ok "no stray 't=' line"
fi
# Corroborate the fix is real, not a no-op: total must reflect all 5 rows
# (24641), not the 4-row undercount (23053) the display-command bug caused
# when the 5th 't=' line got swallowed into the loop's last echo.
if print -r -- "$out1" | grep -q 'Total estimated tokens: 24641'; then
  ok "total_tokens reflects all 5 cost rows (24641)"
else
  no "total_tokens wrong or stray-line corrupted (want 24641): $(print -r -- "$out1" | grep 'Total estimated tokens')"
fi

print -r -- "== g1: no stray us_id= line in Verification Results =="
R2="$TMP/repo2"; L2="$TMP/logs2"
setup_campaign "$R2" "$L2" 3
out2=$(run_report "$R2" "$L2" 3)
if print -r -- "$out2" | grep -qE '^us_id='; then
  no "stray 'us_id=' line present in report body"
else
  ok "no stray 'us_id=' line"
fi
# Corroborate real us_id values still render inline (fix must not blank them).
us_lines=$(print -r -- "$out2" | grep -c 'us_id=US-00[1-3]')
if (( us_lines == 3 )); then
  ok "all 3 real us_id values render inline in Verification Results"
else
  no "expected 3 inline us_id values, found $us_lines"
fi

print -r -- "== g1: general stray key=value line check (both reports) =="
stray1=$(print -r -- "$out1" | grep -cE '^[a-z_][a-z0-9_]*=')
stray2=$(print -r -- "$out2" | grep -cE '^[a-z_][a-z0-9_]*=')
if (( stray1 == 0 )); then
  ok "report1: zero bare key=value lines"
else
  no "report1: $stray1 bare key=value line(s) found"
fi
if (( stray2 == 0 )); then
  ok "report2: zero bare key=value lines"
else
  no "report2: $stray2 bare key=value line(s) found"
fi

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
