#!/usr/bin/env zsh
# F6 — a leader relaunch must keep the same-US failure streak (count AND the US it
# belongs to), whether or not the Worker was already promoted, and a fresh
# campaign must never inherit a stale streak.
#
# Root cause: check_model_upgrade() counts a streak with
#   if [[ "$current_us" = "$_LAST_FAILED_US" ]]; then (( _SAME_US_FAIL_COUNT++ ))
#   else _SAME_US_FAIL_COUNT=1; _LAST_FAILED_US="$current_us"; fi
# update_status() persisted same_us_fail_count but NOT the US, and the relaunch
# restore (D-5b) sat entirely inside `if [[ "$_status_mu" == "1" ]]`: after a crash
# BEFORE the first promotion (the common case: one same-US failure, then a crash)
# neither value came back, and after a promotion the count came back without its
# US, so the first failure after the relaunch always reset the count to 1 and every
# promotion slipped one failure.
# Fix: update_status persists `last_failed_us`; the relaunch restores count + US for
# any live campaign (model/effort restore stays gated on model_upgraded==1), except
# from a finished leftover (phase complete|blocked).
#
# Outer conditions (audited in the addendum, pinned here): STATUS_FILE is
# $ROOT/.rlp-desk/logs/<slug>/runtime/status.json (per project and per slug); a
# first run has no file; `init --mode fresh|improve` removes it from the live path (the lifecycle
# deletes it, the no-PRD fallback archives it); a COMPLETE/BLOCKED
# campaign returns at the loop-top sentinel check before any iteration.
#
# Drives the REAL update_status() / check_model_upgrade() from lib_ralph_desk.zsh,
# the REAL relaunch restore region extracted from run_ralph_desk.zsh by content, and
# the REAL init_ralph_desk.zsh.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
TMP=$(mktemp -d); trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

# Relaunch restore region: from the F6 block (`local _s_phase`; before F6 this marker
# does not exist and the region starts at `local _status_mu`) through the D-5b outer
# if's closing 4-space `fi`.
restore_region() {
  awk '
    /local _s_phase|local _status_mu$/ { if (!capture) capture=1 }
    capture { print; if (started_if && $0 ~ /^    fi$/) { exit } }
    capture && /if \[\[ "\$_status_mu"/ { started_if=1 }
  ' "$RUN"
}
REGION="$(restore_region)"
[[ -n "$REGION" ]] && ok "extraction sanity: relaunch restore region found in run_ralph_desk.zsh" || { no "extraction sanity: relaunch restore region NOT found"; exit 1; }

# Fresh relaunch state: what a new leader process starts with.
relaunch_prelude() { # $1 = status.json path
  print -r -- 'log(){ :; }; log_debug(){ :; }'
  print -r -- "STATUS_FILE='$1'"
  print -r -- 'WORKER_MODEL=haiku; WORKER_ENGINE=claude; WORKER_EFFORT=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=high'
  print -r -- '_ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""'
  print -r -- '_MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; _CEILING_DEFERRAL_COUNT=0; LOCK_WORKER_MODEL=0'
  print -r -- 'CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
}
# restore_state <json> -> "LAST=[..] COUNT=[..] UP=[..] MODEL=[..]"
restore_state() {
  local d="$TMP/rs-$RANDOM"; mkdir -p "$d"; print -r -- "$1" > "$d/status.json"
  { relaunch_prelude "$d/status.json"; print -r -- "$REGION"
    print -r -- 'print -r -- "LAST=[$_LAST_FAILED_US] COUNT=[$_SAME_US_FAIL_COUNT] UP=[$_MODEL_UPGRADED] MODEL=[$WORKER_MODEL$WORKER_EFFORT]"'; } > "$d/h.zsh"
  zsh -f "$d/h.zsh" 2>&1 | tail -1
}

print -r -- "== F6 R1: update_status() persists last_failed_us =="
d="$TMP/r1"; mkdir -p "$d"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  SLUG=t; ITERATION=3; MAX_ITER=10; BASELINE_COMMIT=none; WORKER_MODEL=claude-sonnet-5-5; WORKER_EFFORT=high
  VERIFIER_MODEL=sonnet; WORKER_ENGINE=claude; VERIFIER_ENGINE=claude; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=high
  VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""; VERIFY_MODE=per-us; CONSENSUS_MODE=off; CONSECUTIVE_FAILURES=3
  CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""; _MODEL_UPGRADED=1; _SAME_US_FAIL_COUNT=1; _CEILING_DEFERRAL_COUNT=0
  _ORIGINAL_WORKER_MODEL=haiku; _ORIGINAL_WORKER_CODEX_REASONING=high; _ORIGINAL_WORKER_EFFORT=""; VERIFIED_US=""
  _LAST_FAILED_US=US-001; STATUS_FILE="'"$d"'/status.json"
  update_status verifier fail
' >/dev/null 2>&1
got=$(jq -r '.last_failed_us // "MISSING"' "$d/status.json" 2>/dev/null)
[[ "$got" == "US-001" ]] && ok "R1 status.json last_failed_us=US-001" || no "R1 status.json last_failed_us='$got' (want 'US-001' — update_status must persist the US the same_us_fail_count belongs to)"

print -r -- "== F6 R2: promoted relaunch restores count AND US =="
got=$(restore_state '{"model_upgraded":1,"worker_model":"claude-sonnet-5-5","worker_engine":"claude","worker_effort":"high","original_worker_model":"haiku","same_us_fail_count":1,"last_failed_us":"US-001","phase":"verifier"}')
[[ "$got" == "LAST=[US-001] COUNT=[1] UP=[1] MODEL=[claude-sonnet-5-5high]" ]] && ok "R2 promoted: US-001 / count 1 restored, model/effort restored as before" || no "R2 promoted relaunch: '$got' (want 'LAST=[US-001] COUNT=[1] UP=[1] MODEL=[claude-sonnet-5-5high]' — the US must be restored next to the count)"

print -r -- "== F6 R3: backward compat — a status.json written before the field existed =="
got=$(restore_state '{"model_upgraded":1,"worker_model":"claude-sonnet-5-5","worker_engine":"claude","worker_effort":"high","original_worker_model":"haiku","same_us_fail_count":1}')
[[ "$got" == "LAST=[] COUNT=[1] UP=[1] MODEL=[claude-sonnet-5-5high]" ]] && ok "R3 field absent: _LAST_FAILED_US stays empty (not 'null'), count and model restore unchanged" || no "R3 field absent: '$got' (want 'LAST=[] COUNT=[1] UP=[1] MODEL=[claude-sonnet-5-5high]')"

print -r -- "== F6 R4: NOT yet promoted relaunch (the common case) restores the streak, not the model =="
got=$(restore_state '{"model_upgraded":0,"worker_model":"haiku","worker_engine":"claude","same_us_fail_count":1,"last_failed_us":"US-001","phase":"verifier"}')
[[ "$got" == "LAST=[US-001] COUNT=[1] UP=[0] MODEL=[haiku]" ]] && ok "R4 not promoted: US-001 / count 1 restored; _MODEL_UPGRADED stays 0, model stays the CLI model" || no "R4 not-promoted relaunch: '$got' (want 'LAST=[US-001] COUNT=[1] UP=[0] MODEL=[haiku]' — the restore must not depend on model_upgraded)"

print -r -- "== F6 R5 (end to end): crash at same-US count 1, relaunch, same-US failure MUST promote =="
# seg1 <start model> <start effort> <nfails> -> status.json path. Real lib: N same-US failures, then the status a crash leaves.
seg1() {
  local d="$TMP/seg-$RANDOM"; mkdir -p "$d"
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    LIB_DIR="'"$REPO"'/src/scripts"; RLP_DESK_MODELS_FILE=/nonexistent/x.json
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    SLUG=t; ITERATION=3; MAX_ITER=10; BASELINE_COMMIT=none; WORKER_MODEL="'"$1"'"; WORKER_EFFORT="'"$2"'"; WORKER_ENGINE=claude
    VERIFIER_MODEL=sonnet; VERIFIER_ENGINE=claude; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=high; VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""
    VERIFY_MODE=per-us; CONSENSUS_MODE=off; CONSECUTIVE_FAILURES='"$3"'; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""; LOCK_WORKER_MODEL=0
    _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _CEILING_DEFERRAL_COUNT=0; _LAST_FAILED_US=""; VERIFIED_US=""
    _ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""
    STATUS_FILE="'"$d"'/status.json"
    for i in {1..'"$3"'}; do check_model_upgrade US-001; done
    update_status verifier fail
  ' >/dev/null 2>&1
  print -r -- "$d/status.json"
}
# seg2 <status path> <US of the next failure> -> "MODEL=[..] EFFORT=[..]"
seg2() {
  local d="$TMP/seg2-$RANDOM"; mkdir -p "$d"
  { relaunch_prelude "$1"
    print -r -- 'LIB_DIR="'"$REPO"'/src/scripts"; RLP_DESK_MODELS_FILE=/nonexistent/x.json; ITERATION=4'
    print -r -- 'source "'"$LIB"'" 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }'
    print -r -- "$REGION"
    print -r -- "check_model_upgrade $2"
    print -r -- 'print -r -- "MODEL=[$WORKER_MODEL] EFFORT=[$WORKER_EFFORT]"'; } > "$d/h.zsh"
  zsh -f "$d/h.zsh" 2>&1 | tail -1
}
# (a) promoted: haiku, 3 failures -> promoted at #2, count 1 after #3; crash; the next same-US failure promotes to opus
sp=$(seg1 haiku "" 3)
st=$(jq -c '[.worker_model, .worker_effort, .model_upgraded, .same_us_fail_count, .last_failed_us]' "$sp" 2>/dev/null)
[[ "$st" == '["claude-sonnet-5-5","high",1,1,"US-001"]' ]] && ok "R5a segment 1 left status: promoted claude-sonnet-5-5:high, count 1, US-001" || no "R5a segment 1 status: $st (want [\"claude-sonnet-5-5\",\"high\",1,1,\"US-001\"])"
out=$(seg2 "$sp" US-001)
[[ "$out" == "MODEL=[claude-opus-5-5] EFFORT=[high]" ]] && ok "R5a promoted: relaunch then the 2nd same-US failure promotes claude-sonnet-5-5:high -> claude-opus-5-5:high" || no "R5a promoted relaunch then same-US failure: '$out' (want 'MODEL=[claude-opus-5-5] EFFORT=[high]' — the streak was not restored, so the count restarted at 1)"
out=$(seg2 "$sp" US-002)
[[ "$out" == "MODEL=[claude-sonnet-5-5] EFFORT=[high]" ]] && ok "R5a control: relaunch then a DIFFERENT-US failure does not promote" || no "R5a control: '$out' (want 'MODEL=[claude-sonnet-5-5] EFFORT=[high]')"
# (b) NOT promoted: haiku, 1 failure (count 1), crash, relaunch, the next same-US failure must promote haiku -> sonnet:high
sp=$(seg1 haiku "" 1)
st=$(jq -c '[.worker_model, .model_upgraded, .same_us_fail_count, .last_failed_us]' "$sp" 2>/dev/null)
[[ "$st" == '["haiku",0,1,"US-001"]' ]] && ok "R5b segment 1 left status: haiku, not promoted, count 1, US-001" || no "R5b segment 1 status: $st (want [\"haiku\",0,1,\"US-001\"])"
out=$(seg2 "$sp" US-001)
[[ "$out" == "MODEL=[claude-sonnet-5-5] EFFORT=[high]" ]] && ok "R5b NOT promoted: relaunch at count 1 then a same-US failure promotes haiku -> claude-sonnet-5-5:high" || no "R5b not-promoted relaunch then same-US failure: '$out' (want 'MODEL=[claude-sonnet-5-5] EFFORT=[high]' — the streak was lost, the promotion slipped a failure)"
out=$(seg2 "$sp" US-002)
[[ "$out" == "MODEL=[haiku] EFFORT=[]" ]] && ok "R5b control: relaunch then a DIFFERENT-US failure does not promote" || no "R5b control: '$out' (want 'MODEL=[haiku] EFFORT=[]')"

print -r -- "== F6 R6: a pass clears the persisted US =="
d="$TMP/r6"; mkdir -p "$d"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  SLUG=t; ITERATION=3; MAX_ITER=10; BASELINE_COMMIT=none; WORKER_MODEL=haiku; WORKER_EFFORT=""; WORKER_ENGINE=claude
  VERIFIER_MODEL=sonnet; VERIFIER_ENGINE=claude; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=high; VERIFIER_CODEX_MODEL=""; VERIFIER_CODEX_REASONING=""
  VERIFY_MODE=per-us; CONSENSUS_MODE=off; CONSECUTIVE_FAILURES=0; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""
  _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _CEILING_DEFERRAL_COUNT=0; _LAST_FAILED_US=""; VERIFIED_US="US-001"
  _ORIGINAL_WORKER_MODEL=""; _ORIGINAL_WORKER_CODEX_REASONING=""; _ORIGINAL_WORKER_EFFORT=""
  STATUS_FILE="'"$d"'/status.json"
  update_status verifier pass
' >/dev/null 2>&1
got=$(jq -r 'if has("last_failed_us") then .last_failed_us else "MISSING" end' "$d/status.json" 2>/dev/null)
[[ "$got" == "" ]] && ok "R6 after a pass status.json last_failed_us is the empty string" || no "R6 status.json last_failed_us='$got' (want '' — present and empty after the pass reset)"

print -r -- "== F6 R7: the model-upgrade table documents the persisted field and its guard =="
TBL="$REPO/src/model-upgrade-table.md"
if grep -qF '`last_failed_us`' "$TBL" && grep -qF 'Same-US streak across a relaunch (F6)' "$TBL" && grep -qF '_validate_blocked_recovery' "$TBL" && grep -qF 'restored as persisted' "$TBL"; then ok "R7 src/model-upgrade-table.md documents last_failed_us, the phase guard (PR-E predicate) and the per-US carry-over across an operator --worker-model change"; else no "R7 src/model-upgrade-table.md lacks the 'Same-US streak across a relaunch (F6)' paragraph (last_failed_us, the _validate_blocked_recovery predicate of the phase guard, 'restored as persisted' carry-over)"; fi

print -r -- "== F6 R8-R10: a fresh campaign / a finished leftover never inherits a stale streak =="
got=$(restore_state '{"phase":"complete","model_upgraded":0,"worker_model":"haiku","worker_engine":"claude","same_us_fail_count":3,"last_failed_us":"US-009"}')
[[ "$got" == "LAST=[] COUNT=[0] UP=[0] MODEL=[haiku]" ]] && ok "R8 leftover of a COMPLETED run (phase=complete, stale count 3 / US-009): not inherited" || no "R8 completed leftover: '$got' (want 'LAST=[] COUNT=[0] UP=[0] MODEL=[haiku]')"
got=$(restore_state '{"phase":"blocked","model_upgraded":0,"worker_model":"haiku","worker_engine":"claude","same_us_fail_count":2,"last_failed_us":"US-004"}')
[[ "$got" == "LAST=[] COUNT=[0] UP=[0] MODEL=[haiku]" ]] && ok "R9 leftover of a BLOCKED run (phase=blocked, i.e. an operator-cleared BLOCKED = clean restart): not inherited" || no "R9 blocked leftover: '$got' (want 'LAST=[] COUNT=[0] UP=[0] MODEL=[haiku]')"
# first run: no status.json at all (the region is only reached inside the caller's `if [[ -f "$STATUS_FILE" ]]`)
n=$(grep -n '^    local _status_cf$' "$RUN" | head -1 | cut -d: -f1)
OUTER="$(sed -n "$((n-1)),\$p" "$RUN" | awk '{print} /^  fi$/ {exit}')"
if print -r -- "$OUTER" | head -1 | grep -qxF '  if [[ -f "$STATUS_FILE" ]]; then' && print -r -- "$OUTER" | grep -qF "$(print -r -- "$REGION" | head -1)"; then
  d="$TMP/r10"; mkdir -p "$d"
  { print -r -- 'log(){ :; }; log_debug(){ :; }'; print -r -- "STATUS_FILE='$d/no-such-status.json'"
    print -r -- 'CONSECUTIVE_FAILURES=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""'
    print -r -- "$OUTER"; print -r -- 'print -r -- "LAST=[$_LAST_FAILED_US] COUNT=[$_SAME_US_FAIL_COUNT] CF=[$CONSECUTIVE_FAILURES]"'; } > "$d/h.zsh"
  got=$(zsh -f "$d/h.zsh" 2>&1 | tail -1)
  [[ "$got" == "LAST=[] COUNT=[0] CF=[0]" ]] && ok "R10 first run / no status.json: the restore region lives inside the caller's 'if [[ -f \$STATUS_FILE ]]' guard; nothing is restored" || no "R10 no status.json: '$got' (want 'LAST=[] COUNT=[0] CF=[0]')"
else no "R10 the relaunch restore region is no longer inside the 'if [[ -f \$STATUS_FILE ]]' outer block"; fi
# a fresh campaign through the REAL init deletes status.json; init without --mode keeps it (reported, same trust as the CB counter restore)
P="$TMP/proj"; mkdir -p "$P"
( cd "$P" && git init -q && git config user.email t@e.com && git config user.name t && git config commit.gpgsign false && echo x > a && git add a && git commit -qm b \
  && zsh "$INIT" slugx "objective" >/dev/null 2>&1 )
SF="$P/.rlp-desk/logs/slugx/runtime/status.json"; mkdir -p "${SF:h}"
print -r -- '{"phase":"verifier","same_us_fail_count":3,"last_failed_us":"US-009","model_upgraded":1}' > "$SF"
( cd "$P" && zsh "$INIT" slugx "objective" --mode fresh >/dev/null 2>&1 )
[[ ! -f "$SF" ]] && ok "R11 init --mode fresh deletes the previous status.json (a fresh campaign has nothing to inherit)" || no "R11 init --mode fresh left status.json behind: $(cat "$SF")"
print -r -- '{"phase":"verifier","same_us_fail_count":3,"last_failed_us":"US-009","model_upgraded":1}' > "$SF"
( cd "$P" && zsh "$INIT" slugx "objective" --mode improve >/dev/null 2>&1 )
[[ ! -f "$SF" ]] && ok "R12 init --mode improve deletes the previous status.json too" || no "R12 init --mode improve left status.json behind"
# --- codex E2: an explicit --mode fresh|improve with a MISSING PRD must still clear the previous run's runtime state ---
mkproj() { local p; p="$(mktemp -d "$TMP/np-XXXXXX")"; ( cd "$p" && git init -q && git config user.email t@e.com && git config user.name t && git config commit.gpgsign false && echo x > a && git add a && git commit -qm b ) >/dev/null 2>&1; print -r -- "$p"; }
outer_state() { # <status path> -> LAST/COUNT after the real outer restore block ran against it
  local d="$TMP/os-$RANDOM"; mkdir -p "$d"
  { print -r -- 'log(){ :; }; log_debug(){ :; }'; print -r -- "STATUS_FILE='$1'"
    print -r -- 'CONSECUTIVE_FAILURES=0; _MODEL_UPGRADED=0; _SAME_US_FAIL_COUNT=0; _LAST_FAILED_US=""; CONSECUTIVE_BLOCKS=0; LAST_BLOCK_REASON=""; WORKER_MODEL=haiku; WORKER_ENGINE=claude'
    print -r -- "$OUTER"; print -r -- 'print -r -- "LAST=[$_LAST_FAILED_US] COUNT=[$_SAME_US_FAIL_COUNT]"'; } > "$d/h.zsh"
  zsh -f "$d/h.zsh" 2>&1 | tail -1
}
CRASH='{"phase":"verifier","model_upgraded":0,"worker_model":"haiku","worker_engine":"claude","same_us_fail_count":1,"last_failed_us":"US-001","consecutive_failures":1}'
p=$(mkproj); SF="$p/.rlp-desk/logs/slugx/runtime/status.json"; mkdir -p "${SF:h}"; print -r -- "$CRASH" > "$SF"; cp "$SF" "$p/orig-runtime-status.json"
out=$( cd "$p" && zsh "$INIT" slugx "objective" --mode fresh 2>&1 )
a14=( "$p"/.rlp-desk/logs/slugx/runs/superseded-*(N/) )
if [[ ! -f "$SF" && "$(print -r -- "$out" | grep -cF 'Archived:  1 evidence artifact(s)')" == 1 && "$out" != *"Removed stale"* ]] && (( ${#a14} == 1 )) && cmp -s "$p/orig-runtime-status.json" "${a14[1]}/runtime-status.json"; then
  got=$(outer_state "$SF")
  [[ "$got" == "LAST=[] COUNT=[0]" ]] && ok "R14 --mode fresh with a MISSING PRD archives the crashed run's status.json (runtime-status.json, byte-identical, never deleted); a relaunch inherits no streak" || no "R14 status archived but a relaunch still sees '$got'"
else no "R14 --mode fresh with a missing PRD did not archive the crashed run's status.json: live=$([[ -f $SF ]] && echo yes || echo no) archive-dirs=${#a14} archived-line=$(print -r -- "$out" | grep -cF 'Archived:  1 evidence artifact(s)') removed-line=$([[ "$out" == *"Removed stale"* ]] && echo yes || echo no)"; fi
p=$(mkproj); SF="$p/.rlp-desk/logs/slugx/runtime/status.json"; mkdir -p "${SF:h}"; print -r -- "$CRASH" > "$SF"
( cd "$p" && zsh "$INIT" slugx "objective" >/dev/null 2>&1 )
got=$(outer_state "$SF")
[[ -f "$SF" ]] && ok "R15a control: init WITHOUT --mode keeps the previous status.json (documented existing behavior)" || no "R15a control: init without --mode REMOVED the status.json (it must only delete under --mode fresh|improve)"
[[ "$got" == "LAST=[US-001] COUNT=[1]" ]] && ok "R15b control: the kept status.json's streak is restored like every other field (LAST=[US-001] COUNT=[1])" || no "R15b the kept crash status.json is not restored: '$got' (want 'LAST=[US-001] COUNT=[1]' — the un-gated same-US restore is missing)"
p=$(mkproj); LG="$p/.rlp-desk/logs/slugx"; mkdir -p "$LG/runtime" "$p.orig16"; print -r -- "$CRASH" > "$LG/runtime/status.json"; print -r -- "{\"other\":\"status-$RANDOM$RANDOM\"}" > "$LG/status.json"; print -r -- "baseline-$RANDOM$RANDOM" > "$LG/baseline.log"; print -r -- "{\"cost\":$RANDOM$RANDOM}" > "$LG/cost-log.jsonl"; print -r -- "keep" > "$LG/iter-001.worker-prompt.md"
cp "$LG/runtime/status.json" "$p.orig16/runtime-status.json"; for f in status.json baseline.log cost-log.jsonl; do cp "$LG/$f" "$p.orig16/$f"; done
out=$( cd "$p" && zsh "$INIT" slugx "objective" --mode improve 2>&1 )
gone=0; for f in runtime/status.json status.json baseline.log cost-log.jsonl; do [[ ! -f "$LG/$f" ]] && gone=$((gone+1)); done
a16=( "$LG"/runs/superseded-*(N/) ); same16=0
(( ${#a16} == 1 )) && for f in runtime-status.json status.json baseline.log cost-log.jsonl; do cmp -s "$p.orig16/$f" "${a16[1]}/$f" && same16=$((same16+1)); done
nmsg=$(print -r -- "$out" | grep -cF 'Archived:  4 evidence artifact(s)')
if (( gone == 4 && same16 == 4 && nmsg == 1 )) && [[ "$out" != *"Removed stale"* && -f "$LG/iter-001.worker-prompt.md" ]]; then ok "R16 --mode improve with a missing PRD archives the 4 runtime-state files (two distinct status.json names), prints 'Archived:  4', keeps unrelated logs (iter-*)"
else no "R16 expected the 4 state files archived byte-identical in one dir with one 'Archived:  4' line and iter-001.worker-prompt.md kept: live-gone=$gone archive-dirs=${#a16} identical=$same16 archived-lines=$nmsg removed-line=$([[ "$out" == *"Removed stale"* ]] && echo yes || echo no) kept=$([[ -f $LG/iter-001.worker-prompt.md ]] && echo yes || echo no)"; fi
if [[ -f "$p/.rlp-desk/plans/prd-slugx.md" && "$out" == *"treating as first-run"* ]]; then ok "R17 the first-run fallback is unchanged: note printed, PRD scaffolded"
else no "R17 first-run fallback changed (note or PRD scaffold missing)"; fi
# --- review-1 N2: an INVALID --mode must delete nothing (init does not validate MODE) ---
p=$(mkproj); LG="$p/.rlp-desk/logs/slugx"; mkdir -p "$LG/runtime"; print -r -- "$CRASH" > "$LG/runtime/status.json"; print -r -- "x" > "$LG/baseline.log"; print -r -- "{}" > "$LG/cost-log.jsonl"
out=$( cd "$p" && zsh "$INIT" slugx "objective" --mode bogus 2>&1 )
a18=( "$LG"/runs/superseded-*(N/) )
if [[ -f "$LG/runtime/status.json" && -f "$LG/baseline.log" && -f "$LG/cost-log.jsonl" && "$out" != *"Removed stale"* && "$out" != *"Archived:"* ]] && (( ${#a18} == 0 )); then ok "R18 an INVALID --mode with a missing PRD changes nothing: no delete, no archive (guard: --mode fresh|improve only)"
else no "R18 --mode bogus with a missing PRD touched runtime state (status=$([[ -f $LG/runtime/status.json ]] && echo kept || echo gone) baseline=$([[ -f $LG/baseline.log ]] && echo kept || echo gone) cost=$([[ -f $LG/cost-log.jsonl ]] && echo kept || echo gone) archive-dirs=${#a18} archived-line=$([[ "$out" == *"Archived:"* ]] && echo yes || echo no))"; fi
# --- addendum-5: the missing-PRD fallback ARCHIVES the leader's full restore inputs (16 files) ---
# The leader restores VERIFIED_US from (1) the ledger, (2) runtime/status.json, (3) the prose
# "## Completed Stories" of memos/<slug>-memory.md; the scaffold keeps an existing memory file. So
# all three sources, the cost log and the rest of the contract must leave the live paths, and
# nothing may be deleted (.rlp-desk/ is gitignored: a deleted file is gone).
# seed16 <project>: the full inventory with DISTINCT contents (ledger 0444); the originals are
# copied to <project>.orig/<archive name>. Archive names equal the basenames except
# runtime/status.json -> runtime-status.json (two status.json would overwrite each other).
seed16() {
  local p="$1" n
  LG="$p/.rlp-desk/logs/slugx"; M="$p/.rlp-desk/memos"; C="$p/.rlp-desk/context"; ORIG="$p.orig"
  mkdir -p "$LG/runtime" "$M" "$C" "$ORIG"
  ANAMES=(); LIVEALL=(); LIVE14=()
  put() { # <live path> <archive name> <content>
    printf '%s\n' "$3" > "$1"; cp "$1" "$ORIG/$2"; ANAMES+=("$2"); LIVEALL+=("$1")
    [[ "$2" == slugx-memory.md || "$2" == slugx-latest.md ]] || LIVE14+=("$1")
  }
  put "$M/slugx-verified.jsonl" slugx-verified.jsonl "{\"us_id\":\"US-001\",\"tag\":\"$RANDOM$RANDOM\"}"; chmod 0444 "$M/slugx-verified.jsonl"
  for n in done-claim.json iter-signal.json verify-verdict.json complete.md blocked.md blocked.json flywheel-signal.json flywheel-review.md flywheel-guard-verdict.json; do
    put "$M/slugx-$n" "slugx-$n" "$n-$RANDOM$RANDOM"
  done
  put "$M/slugx-memory.md" slugx-memory.md "$(printf '# slugx - Campaign Memory\n\n## Objective\nold-objective-%s\n\n## Completed Stories\n- US-001: done\n\n## Next Iteration Contract\nx' "$RANDOM$RANDOM")"
  put "$C/slugx-latest.md" slugx-latest.md "$(printf '# slugx - Latest Context\n\nold-%s' "$RANDOM$RANDOM")"
  put "$LG/runtime/status.json" runtime-status.json "{\"verified_us\":[\"US-001\"],\"phase\":\"verifier\",\"n\":\"$RANDOM$RANDOM\"}"
  put "$LG/status.json" status.json "{\"other\":\"status-$RANDOM$RANDOM\"}"
  put "$LG/baseline.log" baseline.log "baseline-$RANDOM$RANDOM"
  put "$LG/cost-log.jsonl" cost-log.jsonl "{\"cost\":$RANDOM$RANDOM}"
}
# dir_holds <dir> <archive name>...: the dir holds exactly these files, each byte-identical to $ORIG/<name>
dir_holds() {
  local d="$1"; shift; local n; local -a have; have=( "$d"/*(N) )
  (( ${#have} == $# )) || { ARCH_WHY="${d:t} holds ${#have} files (want $#)"; return 1; }
  for n in "$@"; do cmp -s "$ORIG/$n" "$d/$n" || { ARCH_WHY="$n missing or differs in ${d:t}"; return 1; }; done
  return 0
}
# arch_ok <logs dir> <archive name>...: exactly one runs/superseded-*/ dir, holding exactly these files
arch_ok() {
  local lg="$1"; shift; local -a dirs; dirs=( "$lg"/runs/superseded-*(N/) )
  (( ${#dirs} == 1 )) || { ARCH_WHY="${#dirs} archive dirs (want 1)"; return 1; }
  dir_holds "${dirs[1]}" "$@"
}
live_intact() { local i; for i in {1..${#LIVEALL}}; do cmp -s "$ORIG/${ANAMES[$i]}" "${LIVEALL[$i]}" || { ARCH_WHY="${ANAMES[$i]} missing or changed live"; return 1; }; done; return 0; }
# regenerated memory/latest are CLEAN: not the old bytes, no credited story, new objective, template header
regen_clean() {
  local m="$M/slugx-memory.md" l="$C/slugx-latest.md"
  [[ -f "$m" && -f "$l" ]] || { ARCH_WHY="memory/latest not regenerated"; return 1; }
  cmp -s "$m" "$ORIG/slugx-memory.md" && { ARCH_WHY="old memory still live"; return 1; }
  cmp -s "$l" "$ORIG/slugx-latest.md" && { ARCH_WHY="old latest still live"; return 1; }
  sed -n '/^## Completed Stories$/,/^## /p' "$m" | grep -q '^- US-' && { ARCH_WHY="regenerated memory carries a completed story"; return 1; }
  grep -qF "$1" "$m" || { ARCH_WHY="regenerated memory lacks the new objective"; return 1; }
  [[ "$(head -1 "$l")" == "# slugx - Latest Context" ]] || { ARCH_WHY="latest header wrong"; return 1; }
  return 0
}
fallback16() { # <mode> <label> <id>: fallback init on the 16-file inventory; sets OUT16
  local md="$1" label="$2" id="$3" p live=0 f rc
  p=$(mkproj); seed16 "$p"
  OUT16=$( cd "$p" && zsh "$INIT" slugx "new-objective" --mode "$md" 2>&1 ); rc=$?
  for f in "${LIVE14[@]}"; do [[ ! -e "$f" ]] && live=$((live+1)); done
  ARCH_WHY=""; (( rc == 0 )) || ARCH_WHY="init exited $rc"; [[ -z "$ARCH_WHY" && "$OUT16" != *"Next:"* ]] && ARCH_WHY="init printed no Next: line"
  if [[ -z "$ARCH_WHY" ]] && (( live == 14 )) && regen_clean new-objective && arch_ok "$LG" "${ANAMES[@]}"; then ok "$id $label fallback archives the 16 restore inputs byte-identical in one archive dir; the 14 non-regenerated paths are gone; memory/latest regenerate clean"
  else no "$id $label fallback: absent-live=$live/14 ${ARCH_WHY}"; fi
}
print -r -- "== addendum-5 R19-R27: no-PRD fallback archives the full restore contract =="
fallback16 fresh "--mode fresh" R19; OUT19="$OUT16"
fallback16 improve "--mode improve" R20
if [[ "$(print -r -- "$OUT19" | grep -cF 'Archived:  16 evidence artifact(s) → runs/superseded-')" == 1 && "$OUT19" != *"Removed stale"* ]]; then ok "R21 the fresh fallback prints exactly one 'Archived:  16 evidence artifact(s) → runs/superseded-' line and no 'Removed stale' line"
else no "R21 summary line wrong: archived-lines=$(print -r -- "$OUT19" | grep -cF 'Archived:  16 evidence artifact(s) → runs/superseded-') removed-line=$([[ "$OUT19" == *"Removed stale"* ]] && echo yes || echo no)"; fi
p=$(mkproj); seed16 "$p"; out=$( cd "$p" && zsh "$INIT" slugx "objective" --mode bogus 2>&1 ); ARCH_WHY=""
if live_intact && [[ ! -d "$LG/runs" || -z "$(ls -A "$LG/runs" 2>/dev/null)" ]] && [[ "$out" != *"Archived:"* ]]; then ok "R22 guard: an INVALID --mode with a missing PRD leaves all 16 files live, creates no archive and prints no 'Archived:' line"
else no "R22 invalid --mode touched the inventory: ${ARCH_WHY}"; fi
p=$(mkproj); seed16 "$p"; out=$( cd "$p" && zsh "$INIT" slugx "objective" 2>&1 ); ARCH_WHY=""
if live_intact && [[ ! -d "$LG/runs" || -z "$(ls -A "$LG/runs" 2>/dev/null)" ]]; then ok "R23 guard: NO --mode leaves all 16 files live (documented existing behavior)"
else no "R23 init without --mode touched the inventory: ${ARCH_WHY}"; fi
# R24: the fallback block holds no `rm` command word (comment lines stripped)
RM_HIT=$(awk '/^if \[\[ -n "\$MODE" \]\] && \[\[ ! -f "\$PRD_FILE" \]\]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$INIT" | grep -v '^[[:space:]]*#' | grep -cE -e '(^|[^A-Za-z_-])rm( |$)' || true)
[[ "${RM_HIT:-0}" == 0 ]] && ok "R24 the no-PRD fallback block contains no rm command (campaign state is archived, never bare-deleted)" || no "R24 the no-PRD fallback block still has ${RM_HIT} rm command line(s)"
# R25: the REAL restore region of the leader (run_ralph_desk.zsh: ledger -> status.json -> memory prose)
RESTORE_REGION="$(awk '/^  if \[\[ -f "\$VERIFIED_LEDGER" \]\]; then$/ {c=1} c {print} c && /local memory_file=/ {m=1} m && /^    fi$/ {exit}' "$RUN")"
[[ "$RESTORE_REGION" == *'last-resort prose'* && "$RESTORE_REGION" == *'durable ledger'* && "$RESTORE_REGION" == *'from status.json'* ]] || { no "R25 extraction sanity: the VERIFIED_US restore region was NOT found in run_ralph_desk.zsh"; exit 1; }
restore_harness() { # <project> -> "VERIFIED=[..]" after the real restore region ran against it
  local d="$TMP/rh-$RANDOM"; mkdir -p "$d"
  { print -r -- 'log(){ :; }; log_debug(){ :; }'; print -r -- 'h(){'; print -r -- 'VERIFIED_US=""'
    print -r -- "VERIFIED_LEDGER='$1/.rlp-desk/memos/slugx-verified.jsonl'; STATUS_FILE='$1/.rlp-desk/logs/slugx/runtime/status.json'; DESK='$1/.rlp-desk'; SLUG=slugx"
    print -r -- "$RESTORE_REGION"; print -r -- 'print -r -- "VERIFIED=[$VERIFIED_US]"'; print -r -- '}; h'; } > "$d/h.zsh"
  zsh -f "$d/h.zsh" 2>&1 | tail -1
}
p=$(mkproj); seed16 "$p"; got=$(restore_harness "$p")
[[ "$got" == "VERIFIED=[US-001]" ]] && ok "R25a guard: the extracted restore region credits US-001 from the stale inventory (the harness is sensitive)" || no "R25a harness not sensitive: '$got' (want 'VERIFIED=[US-001]')"
p=$(mkproj); seed16 "$p"; ( cd "$p" && zsh "$INIT" slugx "new-objective" --mode fresh >/dev/null 2>&1 ); got=$(restore_harness "$p")
[[ "$got" == "VERIFIED=[]" ]] && ok "R25b after the fallback the leader's full restore chain credits nothing (ledger, status.json and memory prose all emptied)" || no "R25b stale credit survives the fallback: '$got' (want 'VERIFIED=[]')"
p=$(mkproj); LG="$p/.rlp-desk/logs/slugx"; M="$p/.rlp-desk/memos"; mkdir -p "$M" "$p.orig"; ORIG="$p.orig"
printf '# slugx - Campaign Memory\n\n## Objective\nold-objective\n\n## Completed Stories\n- US-001: done\n\n## Next Iteration Contract\nx\n' > "$M/slugx-memory.md"; cp "$M/slugx-memory.md" "$ORIG/slugx-memory.md"
( cd "$p" && zsh "$INIT" slugx "new-objective" --mode fresh >/dev/null 2>&1 ); got=$(restore_harness "$p"); a25=( "$LG"/runs/superseded-*(N/) )
if [[ "$got" == "VERIFIED=[]" ]] && (( ${#a25} == 1 )) && cmp -s "$ORIG/slugx-memory.md" "${a25[1]}/slugx-memory.md" && grep -qF new-objective "$M/slugx-memory.md" && ! sed -n '/^## Completed Stories$/,/^## /p' "$M/slugx-memory.md" | grep -q '^- US-'; then ok "R25c a memory file ALONE (prose source) is archived byte-identical and regenerated clean with the new objective: nothing credited"
else no "R25c memory-only fixture: '$got' archive-dirs=${#a25} (want 'VERIFIED=[]', old memory archived, regenerated memory with new-objective and no '- US-' line)"; fi
p=$(mkproj); mkdir -p "$p/.rlp-desk/logs/slugx/runtime"; print -r -- '{"verified_us":["US-001"]}' > "$p/.rlp-desk/logs/slugx/runtime/status.json"; got=$(restore_harness "$p")
[[ "$got" == "VERIFIED=[US-001]" ]] && ok "R25d guard: a runtime/status.json ALONE credits US-001 through the extracted region (source 2 is wired; R25a's live ledger cannot mask it)" || no "R25d status-only harness: '$got' (want 'VERIFIED=[US-001]')"
# R26: a FAILED move stops init (exit 4) before scaffolding; the re-run after repair completes
if [[ $EUID -eq 0 ]]; then
  no "R26a needs a non-root user: root ignores chmod 555 on context/, so the failure cannot be injected (FAIL, not skipped)"
  no "R26b needs a non-root user (see R26a)"
else
  p=$(mkproj); seed16 "$p"; chmod 555 "$C"
  out=$( cd "$p" && zsh "$INIT" slugx "objective" --mode fresh 2>&1 ); rc=$?
  chmod 755 "$C"; ARCH_WHY=""; others=( "${(@)ANAMES:#slugx-latest.md}" )
  if (( rc == 4 )) && [[ "$out" == *"slugx-latest.md"* && "$out" == *"ERROR"* && "$out" != *"Next:"* && ! -e "$p/.rlp-desk/plans/prd-slugx.md" ]] && arch_ok "$LG" "${others[@]}" && cmp -s "$ORIG/slugx-latest.md" "$C/slugx-latest.md"; then ok "R26a a failed move (latest.md; context/ read-only) exits 4, names the file, prints no 'Next:' and does not scaffold; the 15 archived and the 1 live file keep their bytes"
  else no "R26a failed move: rc=$rc (want 4) ERROR=$([[ "$out" == *ERROR* ]] && echo yes || echo no) names-file=$([[ "$out" == *slugx-latest.md* ]] && echo yes || echo no) Next=$([[ "$out" == *"Next:"* ]] && echo yes || echo no) prd-scaffolded=$([[ -e $p/.rlp-desk/plans/prd-slugx.md ]] && echo yes || echo no) ${ARCH_WHY}"; fi
  d1=( "$LG"/runs/superseded-*(N/) )
  out2=$( cd "$p" && zsh "$INIT" slugx "objective" --mode fresh 2>&1 ); rc2=$?
  d2=( "$LG"/runs/superseded-*(N/) ); d2new=( "${(@)d2:#${d1[1]:-NONE}}" ); ARCH_WHY=""
  if (( rc2 == 0 && ${#d1} == 1 && ${#d2} == 2 && ${#d2new} == 1 )) && dir_holds "${d1[1]}" "${others[@]}" && dir_holds "${d2new[1]}" slugx-latest.md \
     && [[ -f "$p/.rlp-desk/plans/prd-slugx.md" && "$out2" == *"Next:"* && "$(print -r -- "$out2" | grep -cF 'Archived:  1 evidence artifact(s)')" == 1 ]]; then ok "R26b after the repair the re-run exits 0: latest.md goes to a second archive dir, the first dir is unchanged, scaffold and 'Next:' are present, 'Archived:  1'"
  else no "R26b re-run after repair: rc=$rc2 dirs-before=${#d1} dirs-after=${#d2} prd=$([[ -f $p/.rlp-desk/plans/prd-slugx.md ]] && echo yes || echo no) Next=$([[ "$out2" == *"Next:"* ]] && echo yes || echo no) ${ARCH_WHY}"; fi
fi
# R27: the governance contract documents the fallback exception
grep -q 'also when no PRD exists yet' "$REPO/src/governance.md" && ok "R27 governance.md documents that the re-execution relocation also applies when no PRD exists yet" || no "R27 governance.md does not document the no-PRD fallback relocation ('also when no PRD exists yet')"
# per-project, per-slug scoping of the file the restore reads
if grep -qF 'DESK="$ROOT/${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"' "$RUN" && grep -qF 'LOGS_DIR="$DESK/logs/$SLUG"' "$RUN" && grep -qF 'RUNTIME_DIR="$LOGS_DIR/runtime"' "$RUN" && grep -qF 'STATUS_FILE="$RUNTIME_DIR/status.json"' "$RUN"; then
  ok "R13 STATUS_FILE = \$ROOT/.rlp-desk/logs/<slug>/runtime/status.json: another slug or project never shares it"
else no "R13 the STATUS_FILE path is no longer scoped by project root and slug"; fi

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
