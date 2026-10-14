#!/usr/bin/env zsh
# F-COSTLOG — write_cost_log must record the engine's OWN effort field.
#
# Root cause: write_cost_log() set cost_worker_effort from WORKER_CODEX_REASONING
# for every engine. run_ralph_desk.zsh defaults that variable to `high`
# regardless of engine, so every claude row carried worker_effort:"high"
# (haiku, claude-sonnet-5-5:medium, ...), hiding effort-only claude ladder
# hops (claude-sonnet-5-5:medium -> :high) from the report's escalation count
# and mislabeling "Final model per US". Fix: claude -> WORKER_EFFORT, codex ->
# WORKER_CODEX_REASONING (unchanged).
#
# Drives the REAL write_cost_log() and the REAL generate_campaign_report() from
# lib_ralph_desk.zsh (test_g1_cost_summary.sh style).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# write_row <dir> <engine> <model> <effort> <codex_reasoning> [us_id] [iter]
# Appends ONE real write_cost_log row to <dir>/cost-log.jsonl.
write_row() {
  local dir="$1" eng="$2" model="$3" eff="$4" cdx="$5" us="${6:-US-001}" iter="${7:-1}"
  mkdir -p "$dir/logs"
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    LOGS_DIR="'"$dir"'/logs"; COST_LOG="'"$dir"'/cost-log.jsonl"
    DONE_CLAIM_FILE=""; VERDICT_FILE=""
    WORKER_ENGINE="'"$eng"'"; WORKER_MODEL="'"$model"'"; WORKER_EFFORT="'"$eff"'"
    WORKER_CODEX_REASONING="'"$cdx"'"; VERIFIER_ENGINE=claude; signal_us_id="'"$us"'"
    write_cost_log '"$iter"'
  ' >/dev/null 2>&1
}
last_field() { jq -r ".$2 // \"MISSING\"" <(tail -1 "$1/cost-log.jsonl") 2>/dev/null; }

print -r -- "== costlog W1: claude haiku (no effort) records worker_effort '' even though WORKER_CODEX_REASONING defaults to high =="
d="$TMP/w1"; write_row "$d" claude haiku "" high
got=$(last_field "$d" worker_effort); gotm=$(last_field "$d" worker_model)
[[ "$gotm" == "haiku" && "$got" == "" ]] && ok "W1 haiku row worker_effort is empty" || no "W1 claude haiku row: worker_model='$gotm' worker_effort='$got' (want 'haiku' and '' — haiku has no effort; the codex default 'high' must not leak)"

print -r -- "== costlog W2: claude MEDIUM start records 'medium' =="
d="$TMP/w2"; write_row "$d" claude claude-sonnet-5-5 medium high
got=$(last_field "$d" worker_effort)
[[ "$got" == "medium" ]] && ok "W2 claude-sonnet-5-5 row worker_effort=medium" || no "W2 claude-sonnet-5-5:medium row: worker_effort='$got' (want 'medium')"

print -r -- "== costlog W3: claude effort is independent of a DIFFERENT codex reasoning value =="
d="$TMP/w3"; write_row "$d" claude claude-opus-5-5 max low
got=$(last_field "$d" worker_effort)
[[ "$got" == "max" ]] && ok "W3 claude-opus-5-5 row worker_effort=max (codex var 'low' ignored)" || no "W3 claude-opus-5-5:max row with WORKER_CODEX_REASONING=low: worker_effort='$got' (want 'max')"

print -r -- "== costlog W4 (guard): codex row unchanged — WORKER_CODEX_REASONING wins, stale WORKER_EFFORT ignored =="
d="$TMP/w4"; write_row "$d" codex gpt-5.6-luna medium xhigh
got=$(last_field "$d" worker_effort)
[[ "$got" == "xhigh" ]] && ok "W4 codex row worker_effort=xhigh" || no "W4 codex row: worker_effort='$got' (want 'xhigh')"

print -r -- "== costlog W5: other row fields unchanged (model/engine/us_id still recorded) =="
d="$TMP/w5"; write_row "$d" claude claude-sonnet-5-5 medium high US-007 4
if [[ "$(last_field "$d" worker_model)" == "claude-sonnet-5-5" && "$(last_field "$d" worker_engine)" == "claude" && "$(last_field "$d" us_id)" == "US-007" && "$(last_field "$d" iteration)" == "4" ]]; then
  ok "W5 model/engine/us_id/iteration intact"
else
  no "W5 row fields changed: $(tail -1 "$d/cost-log.jsonl")"
fi

# --- end to end: real rows -> real campaign report --------------------------
report_section() { # $1=cost-log dir (holds cost-log.jsonl)  $2=optional status.json content
  local dir="$1" root="$TMP/rr-$RANDOM" status_file=""
  mkdir -p "$root"
  if [[ -n "${2:-}" ]]; then status_file="$dir/status.json"; print -r -- "$2" > "$status_file"; fi
  git -C "$root" init -q; git -C "$root" config user.email t@e.com; git -C "$root" config user.name t
  git -C "$root" config commit.gpgsign false; echo v > "$root/a"; git -C "$root" add a; git -C "$root" commit -q -m b
  touch "$root/.complete"
  zsh --no-rcs -c '
    LIB_DIR="'"$REPO"'/src/scripts"; source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$root"'"; LOGS_DIR="'"$dir"'/logs"; DESK="'"$root"'"; SLUG=costlog-e2e; ITERATION=0; MAX_ITER=0
    START_TIME=$(date +%s); COST_LOG="'"$dir"'/cost-log.jsonl"; STATUS_FILE="'"$status_file"'"; CAMPAIGN_REPORT_GENERATED=0
    COMPLETE_SENTINEL="'"$root"'/.complete"; BLOCKED_SENTINEL="'"$root"'/.blocked"
    WITH_SELF_VERIFICATION=0; WITH_SELF_VERIFICATION_REQUESTED=0
    WORKER_MODEL=w; WORKER_ENGINE=we; VERIFIER_MODEL=v; VERIFIER_ENGINE=ve
    CONSENSUS_MODE=cm; CONSENSUS_MODEL=cmm; FINAL_CONSENSUS_MODEL=fcm; VERIFIED_US=""; CONSECUTIVE_FAILURES=0
    generate_campaign_report >/dev/null 2>&1
    sed -n "/^## Cost/,/^## SV/p" "$LOGS_DIR/campaign-report.md"
  '
}

print -r -- "== costlog W6: claude effort-only hop (medium -> high on the SAME model) is an escalation; final model per US is exact =="
d="$TMP/w6"
write_row "$d" claude haiku "" high US-001 1
write_row "$d" claude claude-sonnet-5-5 medium high US-002 2
write_row "$d" claude claude-sonnet-5-5 high high US-002 3
out=$(report_section "$d")
esc=$(print -r -- "$out" | grep '^- Escalation count:')
fm=$(print -r -- "$out" | grep '^- Final model per US:')
if print -r -- "$esc" | grep -qE '^- Escalation count: 2 ladder move'; then
  ok "W6 escalation count 2 (haiku->S:medium model change + S:medium->S:high effort-only)"
else
  no "W6 escalation: '$esc' (want '- Escalation count: 2 ladder move(s)' — the effort-only claude hop must count)"
fi
if [[ "$fm" == "- Final model per US: US-001 = haiku, US-002 = claude-sonnet-5-5:high" ]]; then
  ok "W6 final model per US: bare haiku, claude-sonnet-5-5:high"
else
  no "W6 final model per US: '$fm' (want '- Final model per US: US-001 = haiku, US-002 = claude-sonnet-5-5:high')"
fi

print -r -- "== costlog W7: a MEDIUM start that never escalates renders claude-sonnet-5-5:medium =="
d="$TMP/w7"
write_row "$d" claude claude-sonnet-5-5 medium high US-001 1
out=$(report_section "$d")
fm=$(print -r -- "$out" | grep '^- Final model per US:')
[[ "$fm" == "- Final model per US: US-001 = claude-sonnet-5-5:medium" ]] && ok "W7 MEDIUM start rendered claude-sonnet-5-5:medium" || no "W7 final model per US: '$fm' (want '- Final model per US: US-001 = claude-sonnet-5-5:medium')"

print -r -- "== costlog W8: status.json model_upgraded=1 agrees with a claude effort-only hop (no false disagreement note) =="
d="$TMP/w8"
write_row "$d" claude claude-sonnet-5-5 medium high US-001 1
write_row "$d" claude claude-sonnet-5-5 high high US-001 2
esc=$(report_section "$d" '{"model_upgraded":1}' | grep '^- Escalation count:')
if [[ "$esc" == "- Escalation count: 1 ladder move(s)" ]]; then
  ok "W8 escalation count 1, no disagreement note"
else
  no "W8 escalation line: '$esc' (want '- Escalation count: 1 ladder move(s)' with no disagreement note)"
fi

print -r -- "== costlog W9: non-codex engine (empty / unexpected) records WORKER_EFFORT, not WORKER_CODEX_REASONING =="
d="$TMP/w9a"; write_row "$d" "" claude-sonnet-5-5 medium high
got=$(last_field "$d" worker_effort)
d="$TMP/w9b"; write_row "$d" other claude-sonnet-5-5 medium high
got2=$(last_field "$d" worker_effort)
[[ "$got" == "medium" && "$got2" == "medium" ]] && ok "W9 empty/unknown engine rows worker_effort=medium (codex var 'high' ignored)" || no "W9 empty engine worker_effort='$got', engine=other worker_effort='$got2' (want 'medium' for both — only engine=codex uses WORKER_CODEX_REASONING)"

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
