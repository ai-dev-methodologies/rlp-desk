#!/bin/zsh
# C-01 parity: the signal path of generate_campaign_report / write_cost_log / log no longer forks, so its grep|sed|jq|printf|ls
# pipelines were rewritten (clean children, in-process parsing). This test pins the OLD observable behaviour of every rewritten
# construct on inputs where the rewrite could drift. Expected values were taken from running the pre-fix lib on the same fixtures;
# C01_PARITY_LIB points the harness at another lib to repeat that (e.g. a `git show HEAD:...` copy).
#   L-03 newline in LOGS_DIR            L-04 newest SV report by mtime        L-05 odd cost-log rows keep their tokens
#   L-06 iteration >= 1000 padding      L-07 unterminated last line + first-match  L-08 failed stat must not reuse a size
#   L-09 no temp-file litter            L-10 missing module fails loudly     L-11 offset follows TZ outside the handler
#   M-01 no libc time call anywhere     M-03 NUL inside a value               M-07 fatal error in the report body
#   M-08 every temp name matches cleanup's *.tmp.* sweep
set -uo pipefail
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="${C01_PARITY_LIB:-$ROOT_DIR/src/scripts/lib_ralph_desk.zsh}"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib not found: $LIB"; exit 1; }
for _t in jq git; do command -v $_t >/dev/null 2>&1 || { print -u2 "FAIL: $_t not installed"; exit 1; }; done
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export C01_PARITY_LIB="$LIB"

# _gcr <name> <setup snippet run before the call> [<call>]: fresh git repo + logs dir, production flags (set -u), real lib.
# Prints the logs dir; the report is "<logs>/campaign-report.md".
_gcr() {
  local d="$TMP/$1" logs
  logs="${GCR_LOGS:-$d/logs}"
  mkdir -p "$d/plans" "$logs"; git -C "$d" init -q 2>/dev/null
  cat > "$d/h.zsh" <<HARNESS
set -uo pipefail
zmodload zsh/datetime
source "\${C01_PARITY_LIB:?}"
CAMPAIGN_REPORT_GENERATED=0; LOGS_DIR="$logs"; SLUG=s; START_TIME=\$(( EPOCHSECONDS - 60 )); DESK="$d"; ROOT="$d"
COMPLETE_SENTINEL="$d/nc"; BLOCKED_SENTINEL="$d/nb"; COST_LOG="$logs/cost-log.jsonl"; STATUS_FILE="$logs/status.json"
ITERATION=3; MAX_ITER=9; VERIFIED_US=""; CONSECUTIVE_FAILURES=0; BASELINE_COMMIT=none
WORKER_MODEL=m; WORKER_ENGINE=codex; VERIFIER_MODEL=v; VERIFIER_ENGINE=claude; WORKER_EFFORT=""; WORKER_CODEX_REASONING=high
WITH_SELF_VERIFICATION=0; DEBUG=0; SIGNAL_RECEIVED=""; CURRENT_US=US-1; VERIFY_MODE=per-us
CONSENSUS_MODE=off; CONSENSUS_MODEL=x; FINAL_CONSENSUS_MODEL=y; CAMPAIGN_UNTRACKED_SNAPSHOT_OK=0
LIB_DIR="$ROOT_DIR/src/scripts"
$2
${3:-generate_campaign_report}
HARNESS
  zsh -f "$d/h.zsh" >"$d/out" 2>"$d/err"; print -r -- $? > "$d/rc"   # exit status kept: an aborted harness must not pass (M-04)
  print -r -- "$logs"
}
_rep() { cat "$1/campaign-report.md" 2>/dev/null; }

# --- L-03: a newline in LOGS_DIR must not abort report generation (set -u) ---------------------------------------
GCR_LOGS="$TMP/l03/lo"$'\n'"gs"
L=$(GCR_LOGS="$GCR_LOGS" _gcr l03 "print -r -- '{\"us_id\":\"US-7\"}' > \"\$LOGS_DIR/iter-001-done-claim.json\"")
R=$(_rep "$GCR_LOGS"); err=$(<"$TMP/l03/err")
[[ "$R" == *"iter-001-done-claim.json: us_id=US-7"* && "$err" != *"parameter not set"* ]] \
  && ok "L-03 LOGS_DIR with a newline: report written, done-claim us_id listed, no set -u abort" \
  || no "L-03 newline in LOGS_DIR broke the report (err: ${err[1,160]})"
unset GCR_LOGS

# --- L-04: the NEWEST self-verification report (mtime), not the oldest, and not the highest name -----------------
L=$(_gcr l04 'print r1 > "$LOGS_DIR/self-verification-report-001.md"; print r2 > "$LOGS_DIR/self-verification-report-002.md"; touch -t 202001010000 "$LOGS_DIR/self-verification-report-002.md"; WITH_SELF_VERIFICATION=1')
R=$(_rep "$L")
[[ "$R" == *"See: $L/self-verification-report-001.md"* ]] \
  && ok "L-04 two SV reports: the newest by mtime (001, older name order reversed) is linked" \
  || no "L-04 wrong SV report linked: $(print -r -- "$R" | grep -m1 'self-verification-report')"

# --- L-05: cost rows with a non-scalar field keep their tokens; newline in a string field is one row ----------------
# (The pre-fix `echo "$line" | jq` expanded the "\n" escape inside zsh's echo and dropped that row: 150, not 175. The new
# reader counts it; the other two rows and the garbage rows behave exactly as before.)
L=$(_gcr l05 'printf "%s\n" "{\"estimated_tokens\":100,\"worker_model\":{},\"worker_engine\":\"codex\",\"worker_effort\":\"high\",\"us_id\":\"US-1\"}" "{\"estimated_tokens\":50,\"worker_model\":\"gpt-6-luna\",\"worker_engine\":\"codex\",\"worker_effort\":\"high\",\"us_id\":\"US-2\"}" "{\"estimated_tokens\":25,\"worker_model\":\"a\\nb\",\"worker_engine\":\"claude\",\"worker_effort\":\"\",\"us_id\":\"US-3\"}" "not json at all" "[1]" > "$COST_LOG"')
R=$(_rep "$L")
[[ "$R" == *"Total estimated tokens (raw): 175 "* ]] \
  && ok "L-05 odd cost rows: raw total 175 (100 with an object model + 50 + 25 with a newline in the model; 2 garbage rows count 0)" \
  || no "L-05 raw token total wrong: $(print -r -- "$R" | grep -m1 'Total estimated')"
[[ "$R" == *"US-1 = {}:high"* && "$R" == *"US-2 = gpt-6-luna:high"* && "$R" == *"Claude legs: 1 "* ]] \
  && ok "L-05 per-row fields intact (object model rendered, luna row, one claude leg despite the embedded newline)" \
  || no "L-05 per-row fields wrong: $(print -r -- "$R" | grep -m3 -E 'Final model|Claude legs')"

# --- L-06: iteration >= 1000 keeps all its digits (printf %03d semantics) -----------------------------------------
L=$(_gcr l06 'ITERATION=1001; print -r -- "{\"us_id\":\"US-9\"}" > "$LOGS_DIR/iter-1000-done-claim.json"; print x > "$LOGS_DIR/iter-1001.fix-contract.md"; print -rn -- 1234567 > "$LOGS_DIR/iter-1000.worker-prompt.md"; DONE_CLAIM_FILE=/nonexistent; VERDICT_FILE=/nonexistent; rm -f "$COST_LOG"; write_cost_log 1000' )
R=$(_rep "$L")
[[ "$R" == *"iter-1000-done-claim.json: us_id=US-9"* && "$R" == *"iter-1001.fix-contract.md"* ]] \
  && ok "L-06 report lists iter-1000 done-claim and iter-1001 fix-contract (no 3-digit truncation)" \
  || no "L-06 iteration >= 1000 files missed in the report"
grep -qE '"prompt_bytes": *7,' "$L/cost-log.jsonl" 2>/dev/null \
  && ok "L-06 write_cost_log 1000 reads iter-1000.worker-prompt.md (prompt_bytes 7)" \
  || no "L-06 write_cost_log 1000 read the wrong prompt file: $(grep -o '"prompt_bytes":[0-9 ]*' "$L/cost-log.jsonl" 2>/dev/null)"

# --- L-07: unterminated last line, first-match semantics ---------------------------------------------------------
L=$(_gcr l07a 'printf "Reason: only-reason" > "$BLOCKED_SENTINEL"')
R=$(_rep "$L")
[[ "$R" == *"Terminal state: BLOCKED"* && "$R" == *"Blocked reason: only-reason"* ]] \
  && ok "L-07 BLOCKED sentinel whose last line has no newline: Reason parsed" || no "L-07 unterminated Reason line lost"
L=$(_gcr l07b 'printf "Reason:\nReason: second\nCategory:\nCategory: late\n" > "$BLOCKED_SENTINEL"')
R=$(_rep "$L")
[[ "$R" == *"Terminal state: BLOCKED"* && "$R" != *"Blocked reason: second"* && "$R" != *"late"* ]] \
  && ok "L-07 first Reason:/Category: line wins even when empty (grep -m1): a later one is not substituted" \
  || no "L-07 a later Reason/Category replaced the empty first match"
L=$(_gcr l07c 'printf "## Objective\nline one\nline two\nlast without newline" > "$DESK/plans/prd-s.md"')
R=$(_rep "$L")
[[ "$R" == *"last without newline"* ]] && ok "L-07 PRD objective: unterminated last line kept" || no "L-07 unterminated objective line lost"

# --- L-08: a failed stat must not reuse the previous file's size --------------------------------------------------
L=$(_gcr l08 'print -rn -- 12345 > "$LOGS_DIR/iter-001.worker-prompt.md"; print -rn -- 12345678 > "$LOGS_DIR/done.json"; DONE_CLAIM_FILE="$LOGS_DIR/done.json"; VERDICT_FILE=/nonexistent; rm -f "$COST_LOG"; zstat() { [[ "${@[-1]}" == *done.json ]] && return 1; builtin zstat "$@"; }; write_cost_log 1' )
row=$(<"$L/cost-log.jsonl")
[[ "$row" =~ '"prompt_bytes": *5,' && ! "$row" =~ '"claim_bytes": *5,' ]] \
  && ok "L-08 stat failure on the done-claim does not inherit the prompt's 5 bytes (claim_bytes != 5)" \
  || no "L-08 failed stat reused the previous size: $(print -r -- "$row" | grep -o '"claim_bytes":[0-9]*')"

# --- L-09: no temp litter, also on a failed publish; temps never listed as untracked -------------------------------
L=$(_gcr l09a 'print u > "$DESK/untracked-file.txt"; print -r -- "{\"us_id\":\"US-1\"}" > "$LOGS_DIR/iter-001-done-claim.json"; print -r -- "{\"estimated_tokens\":1,\"worker_model\":\"m\",\"worker_engine\":\"claude\"}" > "$COST_LOG"')
R=$(_rep "$L"); litter=("$L"/*tmp*(N) "$L"/.*tmp*(N) "$L"/.report*(N) "$L"/.untracked*(N))
[[ ${#litter} == 0 && "$R" != *report.*tmp* && "$R" != *".report"* && "$R" == *"untracked-file.txt"* ]] \
  && ok "L-09 success path: no temp files left, none listed among the untracked files (untracked-file.txt is)" \
  || no "L-09 temp litter or temp name in the untracked listing: ${litter[*]} / $(print -r -- "$R" | grep -m2 -E 'tmp|\.report')"
L=$(_gcr l09b 'mv() { return 1; }; zf_mv() { [[ -e "$1" ]] && print -r -- "tmp-existed:$1" >> "$DESK/mvcalls.txt"; return 1; }')
litter=("$L"/*tmp*(N) "$L"/.*tmp*(N) "$L"/.report*(N))
# positive evidence: the publish step really ran against an existing temp file and failed, and the report body was written
[[ -s "$TMP/l09b/mvcalls.txt" && "$(<$TMP/l09b/rc)" == 0 && ! -e "$L/campaign-report.md" ]] \
  && ok "L-09 failed publish: the publish rename ran on an existing temp file and failed (harness rc 0, no report)" \
  || no "L-09 failed-publish scenario did not exercise the rename (mvcalls: $(cat $TMP/l09b/mvcalls.txt 2>/dev/null) rc=$(<$TMP/l09b/rc))"
[[ ${#litter} == 0 ]] && ok "L-09 failed publish (mv fails): the report temp file is removed" || no "L-09 failed publish left temp files: ${litter[*]}"

# --- M-03: an escaped \u0000 inside a value must not shift the NUL framing of the following rows -----------------------
L=$(_gcr m03 'printf "%s\n" "{\"estimated_tokens\":100,\"worker_model\":\"a\\u0000b\",\"worker_engine\":\"claude\",\"us_id\":\"US-1\"}" "{\"estimated_tokens\":50,\"worker_model\":\"gpt-6-luna\",\"worker_engine\":\"codex\",\"worker_effort\":\"high\",\"us_id\":\"US-2\"}" > "$COST_LOG"; print -r -- "{\"us_id\":\"A\\u0000B\"}" > "$LOGS_DIR/iter-001-done-claim.json"; print -r -- "{\"us_id\":\"US-2\"}" > "$LOGS_DIR/iter-002-done-claim.json"')
R=$(_rep "$L")
[[ "$R" == *"Total estimated tokens (raw): 150 "* && "$R" == *"US-2 = gpt-6-luna:high"* ]] \
  && ok "M-03 cost row with a NUL inside a string: the next row is still read (raw total 150, luna row intact)" \
  || no "M-03 NUL shifted the cost-row framing: $(print -r -- "$R" | grep -m2 -E 'Total estimated|Final model')"
[[ "$R" == *"iter-001-done-claim.json: us_id=AB"* && "$R" == *"iter-002-done-claim.json: us_id=US-2"* ]] \
  && ok "M-03 done-claim us_id with a NUL: each file keeps its own us_id" \
  || no "M-03 NUL shifted the us_id pairing: $(print -r -- "$R" | grep -m2 'done-claim')"

# --- M-07: a fatal set -u error inside the report body must not take the leader down (HEAD lost only a pipeline subshell) ---
L=$(_gcr m07 'print -r -- "{\"us_id\":\"US-1\"}" > "$LOGS_DIR/iter-001-done-claim.json"; unset CONSECUTIVE_FAILURES' 'generate_campaign_report; print -r -- AFTER-GCR')
litter=("$L"/*tmp*(N) "$L"/.*tmp*(N))
# N-04 (HEAD parity): HEAD's pipeline subshell died but atomic_write still published what it had received, so the PARTIAL report is
# published; the error is logged; there is no false "Campaign report written" line.
[[ "$(<$TMP/m07/rc)" == 0 && "$(<$TMP/m07/out)" == *AFTER-GCR* && "$(<$TMP/m07/err)" == *"parameter not set"* && ${#litter} == 0 && -s "$L/campaign-report.md" \
  && "$(<$TMP/m07/out)" != *"Campaign report written"* && "$(<$TMP/m07/err)" == *"report generation aborted"* ]] \
  && ok "M-07/N-04 error inside the report body: partial report published, error logged, no false success line, no temp litter, the caller carries on (rc 0, AFTER-GCR)" \
  || no "M-07 leader did not survive a fatal error in the report body (rc=$(<$TMP/m07/rc) err=${$(<$TMP/m07/err)[1,100]} litter=${litter[*]})"

# --- N-02: the UTC offset is read in-process on the normal path (`$(command date +%z)`, as HEAD did per line), at most once per 60 s, never from
#     the handler; no TMPDIR temp file at all; a failing/missing date keeps the last known offset ------------------------------------------
[[ -z "$(grep -n 'rlp-tzoff' "$LIB" "$ROOT_DIR/src/scripts/run_ralph_desk.zsh")" ]] && ok "N-02 no rlp-tzoff temp file anywhere in the lib or the run script" || no "N-02 the TMPDIR offset temp file is still referenced"
out=$(TZ=Asia/Seoul TMPDIR=/nonexistent-c01/x/y zsh -fc 'source "$1"; _RLP_TZ_REFRESH_S=0; log a; log b' zsh "$LIB" 2>&1)
want_s=$(TZ=Asia/Seoul date '+%Y-%m-%d %H')
[[ "${#${(f)out}}" == 2 && "${out[2,14]}" == "$want_s" ]] \
  && ok "N-02 TMPDIR missing/unwritable: no stderr noise, the offset is still the real local one (not a silent UTC fallback)" \
  || no "N-02 with an unwritable TMPDIR: $(print -r -- "$out" | head -3)"
mkdir -p "$TMP/failshim"; printf '#!/bin/sh\nexit 1\n' > "$TMP/failshim/date"; chmod +x "$TMP/failshim/date"
out=$(TZ=Asia/Seoul zsh -fc 'source "$1"; PATH="$2:$PATH"; _RLP_TZ_REFRESH_S=0; log a' zsh "$LIB" "$TMP/failshim" 2>&1)
[[ "${out[2,14]}" == "$want_s" ]] && ok "N-02 date failing: the last known offset is kept (never reset to UTC)" || no "N-02 a failing date reset the offset: $out"
mkdir -p "$TMP/markshim"; printf '#!/bin/sh\ntouch "%s/date-was-forked"\nexec /bin/date "$@"\n' "$TMP" > "$TMP/markshim/date"; chmod +x "$TMP/markshim/date"; rm -f "$TMP/date-was-forked"
out=$(TZ=Asia/Seoul zsh -fc 'source "$1"; SIGNAL_RECEIVED=INT; PATH="$2:$PATH"; _RLP_TZ_REFRESH_S=0; _RLP_TZOFF_AT=0; log a; log b' zsh "$LIB" "$TMP/markshim" 2>&1)
[[ ! -e "$TMP/date-was-forked" && "${out[2,14]}" == "$want_s" ]] && ok "N-02 inside the handler (SIGNAL_RECEIVED set) date is never forked, even with the refresh forced due, and the cached offset is used" || no "N-02 handler path forked date or lost the offset: $out"
out=$(TZ=Asia/Seoul zsh -fc 'source "$1"; PATH="$2:$PATH"; _RLP_TZ_REFRESH_S=0; log a' zsh "$LIB" "$TMP/markshim" 2>&1)
[[ -e "$TMP/date-was-forked" ]] && ok "N-02 control: on the normal path the forced refresh does fork date (the shim sees it)" || no "N-02 control failed: the forced normal-path refresh never forked date"
_sig_ref=$(awk '/^_rlp_tz_refresh\(\) \{/,/^}/' "$LIB"; sed -n '/^_rlp_local_ts() {/,/^}/p' "$LIB")
[[ "$_sig_ref" == *'command date +%z'* && "$_sig_ref" == *'-z "${SIGNAL_RECEIVED:-}"'* ]] && ok "N-02 form check: command date +%z in-process, guarded by SIGNAL_RECEIVED" || no "N-02 refresh form changed: ${_sig_ref[1,160]}"

# --- N-03: `local -a _dbg_v` is a real statement, not text inside a comment ------------------------------------------------
[[ -n "$(grep -E '^[^#]*local -a _dbg_v' "$ROOT_DIR/src/scripts/run_ralph_desk.zsh")" ]] && ok "N-03 _dbg_v is declared local on a code line" || no "N-03 _dbg_v declaration sits in a comment (global leak)"

# --- P-01: the error branch reports the partial report as published ONLY when the rename succeeded ------------------------
L=$(_gcr p01 'unset CONSECUTIVE_FAILURES; zf_mv() { return 1; }' 'generate_campaign_report; print -r -- AFTER-GCR')
[[ "$(<$TMP/p01/rc)" == 0 && "$(<$TMP/p01/out)" == *AFTER-GCR* && "$(<$TMP/p01/err)" == *"partial report NOT published"* && "$(<$TMP/p01/err)" != *"partial report published"* && ! -e "$L/campaign-report.md" ]] \
  && ok "P-01 failed rename after a report-body error: logged as NOT published (no false claim), leader carries on" \
  || no "P-01 wrong claim after a failed rename: $(grep -m1 aborted $TMP/p01/err)"
[[ "$(<$TMP/m07/err)" == *"partial report published"* ]] && ok "P-01 control: with a working rename the same branch logs \"partial report published\"" || no "P-01 control: $(grep -m1 aborted $TMP/m07/err)"

# --- M-08: every temp name the signal path creates matches cleanup's *.tmp.* sweep ---------------------------------------
for _src in "$LIB" "$ROOT_DIR/src/scripts/run_ralph_desk.zsh"; do
  # N-05: every `$$` temp must live under a swept directory ($LOGS_DIR / $MEMOS_DIR, covered by cleanup's *.tmp.* sweep) or be removed by
  # name in the same file (zf_rm "$VAR"); a temp in TMPDIR that nothing removes would pass the name check below and still leak.
  for _nm in ${(f)"$(grep -hoE '[A-Za-z_][A-Za-z0-9_]*="[^"]*[$][$][^"]*"' "$_src" | grep -E '^_[A-Za-z0-9_]*=.*[.]tmp')"}; do
    _var=${_nm%%=*}; _val=${_nm#*=}
    if [[ "$_val" == \"\$LOGS_DIR/* || "$_val" == \"\$MEMOS_DIR/* ]] || grep -qE "zf_rm .*\"[$]$_var\"" "$_src"; then ok "N-05 temp $_var is swept (under LOGS_DIR/MEMOS_DIR) or removed by name"; else no "N-05 temp $_var=$_val is neither under a swept dir nor removed by name"; fi
  done
  for _nm in ${(f)"$(grep -hoE '(_rt|_t|_dbg_t|_f)="[^"]*[$][$][^"]*"' "$_src")"}; do
    _v=${_nm#*=}; _v=${${_v//\$\{TMPDIR:-\/tmp\}/\/x}//\$LOGS_DIR/\/x}; _v="${_v//\$\$/123}"; _v="${_v//\$_d/\/x}"; _v="${_v//\"/}"; [[ "$_nm" == _rt=* ]] && _v+=".diff"   # only _rt is a prefix (the children append .diff/.cost/...)
    [[ "$_v" == *.tmp.* ]] && ok "M-08 temp name $_nm matches *.tmp.* (as $_v)" || no "M-08 temp name $_nm (as $_v) is NOT matched by the *.tmp.* sweep"
  done
done

# --- M-01: the leader process makes NO libc time call on any path ------------------------------------------------------
_hits=$(grep -vE '^\s*#' "$LIB" "$ROOT_DIR/src/scripts/run_ralph_desk.zsh" "$ROOT_DIR/src/scripts/init_ralph_desk.zsh" | grep -nE 'strftime|localtime|mktime|print +-[a-zA-Z]*P|zstat +-[a-zA-Z]*F|%D\{|\(%\)|%[Tt*@]|%W' | head -3)
[[ -z "$_hits" ]] && ok "M-01 no strftime/localtime/mktime/print -P in the lib, the run script or the init script (non-comment lines)" || no "M-01 libc time call left in the leader: $_hits"
out=$(zsh -fc 'source "$1"; _RLP_TZ_REFRESH_S=0; export TZ=America/New_York; log a; log b; print -r -- "${#functions[_rlp_tz_refresh]}"' zsh "$LIB" 2>&1)
[[ "${out[2,14]}" == "$(TZ=America/New_York date +%Y-%m-%d\ %H)" ]] && ok "M-01 a due refresh (forced on every call) re-reads the offset (in-process date) and follows TZ" || no "M-01 forced refresh did not follow TZ: ${out[1,60]}"

# --- L-10: a missing builtin module fails LOUDLY at source time ----------------------------------------------------
for _mod in zsh/files zsh/stat zsh/zselect zsh/datetime zsh/parameter; do
  out=$(zsh -fc 'zmodload() { [[ "$*" == *"'$_mod'"* ]] && return 1; builtin zmodload "$@"; }; source "$1"; print SOURCED' zsh "$LIB" 2>&1); rc=$?
  [[ $rc != 0 && "$out" == *"$_mod"* && "$out" != *SOURCED* ]] \
    && ok "L-10 without $_mod the lib refuses to load (rc=$rc) and names the module" \
    || no "L-10 without $_mod the lib still loaded or stayed silent (rc=$rc): ${out[1,120]}"
done

# --- L-11: the UTC offset follows TZ changes outside the handler (throttled: a per-call libc strftime made 0.75% of stresslog trials
#     die with SIGKILL/SIGSEGV, see _rlp_local_ts); the handler path only uses the cached offset; no global leak -----------------
out=$(TZ=Asia/Seoul zsh -fc 'zmodload zsh/datetime; source "$1"; export TZ=America/New_York; _RLP_TZ_REFRESH_S=0; log x' zsh "$LIB" 2>&1)
want=$(TZ=America/New_York date '+%Y-%m-%d %H')
[[ "${out[2,14]}" == "$want" ]] && ok "L-11 normal path follows the CURRENT TZ (New York after a TZ change) when the refresh is due, like the old \`date\` prefix" \
  || no "L-11 normal-path log prefix did not follow TZ: got '${out[1,24]}' want '[$want'"
out=$(TZ=Asia/Seoul zsh -fc 'zmodload zsh/datetime; source "$1"; export TZ=America/New_York; _RLP_TZOFF_AT=$(( EPOCHSECONDS - 120 )); log x' zsh "$LIB" 2>&1)
[[ "${out[2,14]}" == "$want" ]] && ok "L-11 default throttle: a TZ change is picked up once the cached offset is older than 60 s" \
  || no "L-11 stale offset (120 s old) was not refreshed: got '${out[1,24]}' want '[$want'"
out=$(TZ=Asia/Seoul zsh -fc 'zmodload zsh/datetime; source "$1"; export TZ=America/New_York; log x' zsh "$LIB" 2>&1)
want_s=$(TZ=Asia/Seoul date '+%Y-%m-%d %H')
[[ "${out[2,14]}" == "$want_s" ]] && ok "L-11 inside the 60 s throttle window the cached offset is kept (no libc time call per log line)" \
  || no "L-11 offset refreshed inside the throttle window: got '${out[1,24]}' want '[$want_s'"
out=$(TZ=Asia/Seoul zsh -fc 'zmodload zsh/datetime; source "$1"; export TZ=America/New_York; _RLP_TZOFF_AT=$(( EPOCHSECONDS - 120 )); SIGNAL_RECEIVED=INT; log x' zsh "$LIB" 2>&1)
[[ "${out[2,14]}" == "$want_s" ]] && ok "L-11 handler path (SIGNAL_RECEIVED set) keeps the cached offset even when it is stale: no libc time call" \
  || no "L-11 handler-path prefix not the cached Seoul time: '${out[1,24]}' want '[$want_s'"
leak=$(zsh -fc 'zmodload zsh/datetime; source "$1"; print -r -- "z=${+_z} s=${+_s} f=${+f}"' zsh "$LIB" 2>&1)
[[ "$leak" == "z=0 s=0 f=0" ]] && ok "L-11 sourcing the lib leaks no temporary globals (_z/_s/f)" || no "L-11 global leak after source: $leak"

# M-04: no scenario harness above may have aborted
_badrc=(); for _rcf in "$TMP"/*/rc(N); do [[ "$(<$_rcf)" == 0 ]] || _badrc+=("${_rcf:h:t}=$(<$_rcf)"); done
(( ${#_badrc} == 0 )) && ok "M-04 every scenario harness exited 0 (no aborted run behind a passing assertion)" || no "M-04 aborted scenario harness(es): ${_badrc[*]}"

print ""
print "=== test_signal_path_report_parity.zsh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
