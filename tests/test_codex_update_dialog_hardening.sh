#!/usr/bin/env zsh
# ============================================================================
# v0.22.21 — codex update-dialog hardening (incident 2026-07-22, F-1 recurrence).
#
# codex-cli 0.145.0 shipped a TWO-option "✨ Update available!" startup dialog
# whose changed key handling defeated the old Skip handler; the stuck dialog fell
# through the (unchecked) verifier codex dispatch to verdict polling, burned the
# 90s submit window + 2 re-dispatches, then died with a MISLEADING
# "[infra_failure] Codex verifier never started". Three defenses landed:
#   ROOT  — inject `-c check_for_update_on_startup=false` at every codex launch
#           (removes the dialog surface); env escape hatch RLP_CODEX_UPDATE_CHECK=1.
#   MASK  — guard the verifier codex dispatch return (like the claude branch) and
#           make the durable abort reason name the update dialog + remedy.
#   CONS  — one shared dismisser (_dismiss_codex_update_prompt) + one canonical
#           regex (_RLP_CODEX_UPDATE_RE) replacing 4 inconsistent inline handlers.
#
# This pins the wiring against the source so a future refactor cannot silently
# drop a defense. Behavioral key-strategy is covered by
# tests/sv-large-campaign/test-f1-codex-update-dismiss.zsh.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

# ---------------------------------------------------------------------------
# (a) ROOT: every codex launch assembly site carries the update-check-off flag.
# ---------------------------------------------------------------------------
# The flag is expanded via ${_CODEX_NO_UPDATE_FLAG} (one helper var, uniform across
# sites) rather than 8 literal copies, so we count the variable expansion at the
# assembly sites AND assert the single definition carries the literal config key.
_assembly_sites=$(grep -c 'dangerously-bypass-approvals-and-sandbox' "$RUN")
_flag_sites=$(grep -c '_CODEX_NO_UPDATE_FLAG}' "$RUN")
{ [[ "$_assembly_sites" == 8 && "$_flag_sites" == 8 ]] } \
  && ok "(a) all 8 codex launch assembly sites expand \${_CODEX_NO_UPDATE_FLAG} (sites=$_assembly_sites flag=$_flag_sites)" \
  || no "(a) launch-site/flag count mismatch (assembly=$_assembly_sites flag=$_flag_sites, expected 8/8)"

grep -qE '_CODEX_NO_UPDATE_FLAG=" -c check_for_update_on_startup=false"' "$RUN" \
  && ok "(a) flag definition injects '-c check_for_update_on_startup=false'" \
  || no "(a) flag definition missing the check_for_update_on_startup=false config key"

# ---------------------------------------------------------------------------
# (b) ESCAPE HATCH: RLP_CODEX_UPDATE_CHECK=1 omits the flag; default injects it.
#     Drive the REAL flag-computation block extracted from source.
# ---------------------------------------------------------------------------
_flag_block=$(awk '/RLP_CODEX_UPDATE_CHECK:-0/,/^fi$/' "$RUN")
{ [[ -n "$_flag_block" ]] && grep -q '_CODEX_NO_UPDATE_FLAG' <<< "$_flag_block" ; } \
  || no "(b) flag-computation block not extracted (drift?)"

_eval_flag() {  # $1 = value for RLP_CODEX_UPDATE_CHECK ("" = unset)
  local _CODEX_NO_UPDATE_FLAG=""
  if [[ -n "$1" ]]; then local RLP_CODEX_UPDATE_CHECK="$1"; fi
  eval "$_flag_block"
  print -r -- "$_CODEX_NO_UPDATE_FLAG"
}
_default_flag=$(RLP_CODEX_UPDATE_CHECK= _eval_flag "")
[[ "$_default_flag" == " -c check_for_update_on_startup=false" ]] \
  && ok "(b) default (unset) → flag injected ('$_default_flag')" \
  || no "(b) default did not inject the flag (got '$_default_flag')"

_optout_flag=$(_eval_flag "1")
[[ -z "$_optout_flag" ]] \
  && ok "(b) RLP_CODEX_UPDATE_CHECK=1 → flag omitted (codex default restored)" \
  || no "(b) opt-out did not omit the flag (got '$_optout_flag')"

# ---------------------------------------------------------------------------
# (c) MASK: the stuck-dialog abort reason names the update dialog + remedy,
#     NOT the misleading generic "never started ... submission failure".
# ---------------------------------------------------------------------------
# The submission-failure else-branch must branch on _RLP_CODEX_UPDATE_RE and, when
# it matches, set an abort reason naming the dialog + the 'codex update' remedy.
grep -qE "VERIFIER_ABORT_REASON=.*update dialog could not be dismissed" "$RUN" \
  && ok "(c) abort path can name the codex update dialog as the true cause" \
  || no "(c) abort path never names the update dialog"

grep -qE "update dialog could not be dismissed.*run 'codex update'" "$RUN" \
  && ok "(c) abort reason includes the operator remedy (run 'codex update')" \
  || no "(c) abort reason missing the 'codex update' remedy"

# The launch functions persist the durable reason on 30s ready-exhaustion.
_geo_style=$(grep -c '_CODEX_LAUNCH_FAIL_REASON="Worker codex update dialog\|_CODEX_LAUNCH_FAIL_REASON="Verifier codex update dialog' "$RUN")
{ [[ "$_geo_style" -ge 2 ]] } \
  && ok "(c) both launch functions set the durable _CODEX_LAUNCH_FAIL_REASON on dialog-stuck exhaustion ($_geo_style)" \
  || no "(c) durable launch-fail reason not set in both launch functions ($_geo_style)"

# ---------------------------------------------------------------------------
# (d) MASK: the verifier codex dispatch checks launch_verifier_codex's return
#     (guarded like the claude branch) and threads the durable reason.
# ---------------------------------------------------------------------------
# Every codex verifier-dispatch that mirrors a PROPAGATING claude branch
# (return/continue) must itself propagate. Five such sites: run_single_verifier
# initial, _final_verify_one_us initial + D-4 retry, consensus-parallel initial,
# inline verifier-relaunch initial. The 3 remaining launch_verifier_codex calls
# are submit-anchored RE-dispatches inside poll loops (codex-only, or a claude
# sibling of `|| true`) — legitimately best-effort. Count-pinned so a NEW
# unguarded dispatch fails loud.
# (d.1) run_single_verifier initial — gated + durable reason + return 1.
_disp=$(awk '/"verifier-dispatch"/,/Verifier.suffix codex TUI dispatched/' "$RUN")
{ grep -qE 'if ! launch_verifier_codex "\$VERIFIER_PANE" "\$prompt_file" "\$iter" "\$verifier_launch"; then' <<< "$_disp" \
  && grep -qE 'VERIFIER_ABORT_REASON="\$\{_CODEX_LAUNCH_FAIL_REASON' <<< "$_disp" \
  && grep -qE '^[[:space:]]*return 1' <<< "$_disp" ; } \
  && ok "(d.1) run_single_verifier codex dispatch guarded (if ! → durable reason + return 1)" \
  || no "(d.1) run_single_verifier codex dispatch NOT guarded"

# (d.2) _final_verify_one_us — BOTH the initial dispatch and the D-4 retry relaunch
#       use `|| { … return 2 }` (mirrors the claude `|| { return 2 }` / `|| return 2`).
_fv_guards=$(grep -cE 'launch_verifier_codex "\$VERIFIER_PANE" "\$verifier_prompt" "\$iter" "\$verifier_launch" \|\| \{' "$RUN")
{ [[ "$_fv_guards" == 2 ]] } \
  && ok "(d.2) _final_verify_one_us codex dispatch + D-4 retry both guarded (|| { return 2 }) ($_fv_guards)" \
  || no "(d.2) expected 2 guarded final-verify codex dispatches, got $_fv_guards"

# (d.3) consensus-parallel initial — gated (mirrors claude `return 1`).
grep -qE 'if ! launch_verifier_codex "\$CONSENSUS_PANE" "\$codex_prompt" "\$iter" "\$codex_launch"; then' "$RUN" \
  && ok "(d.3) consensus-parallel codex dispatch guarded (if ! → return 1)" \
  || no "(d.3) consensus-parallel codex dispatch NOT guarded"

# (d.4) inline verifier-relaunch initial — gated (mirrors claude update_status+continue).
grep -qE 'if ! launch_verifier_codex "\$VERIFIER_PANE" "\$verifier_prompt" "\$ITERATION" "\$verifier_launch"; then' "$RUN" \
  && ok "(d.4) inline verifier-relaunch codex dispatch guarded (if ! → update_status + continue)" \
  || no "(d.4) inline verifier-relaunch codex dispatch NOT guarded"

# (d.5) count guard — total=8, propagating-guarded=5 (3×`if !` + 2×`|| {`),
#       best-effort re-dispatches=3. A new unguarded dispatch bumps the delta and fails.
_lvc_total=$(grep -c 'launch_verifier_codex "' "$RUN")
_lvc_ifguard=$(grep -c 'if ! launch_verifier_codex' "$RUN")
_lvc_orguard=$(grep -cE 'launch_verifier_codex .*\|\| \{' "$RUN")
_lvc_guarded=$(( _lvc_ifguard + _lvc_orguard ))
_lvc_unguarded=$(( _lvc_total - _lvc_guarded ))
{ [[ "$_lvc_total" == 8 && "$_lvc_guarded" == 5 && "$_lvc_unguarded" == 3 ]] } \
  && ok "(d.5) 8 codex dispatches: 5 propagating-guarded, 3 best-effort re-dispatch (fails loud on a new site)" \
  || no "(d.5) dispatch guard census drifted (total=$_lvc_total guarded=$_lvc_guarded unguarded=$_lvc_unguarded, expected 8/5/3)"

# ---------------------------------------------------------------------------
# (e) CONSOLIDATION: 4 former inline handlers now call ONE shared dismisser with
#     ONE canonical regex; the dead "new version|update.*codex" regex is gone.
# ---------------------------------------------------------------------------
_callsites=$(grep -c '_dismiss_codex_update_prompt "' "$RUN")
{ [[ "$_callsites" == 4 ]] } \
  && ok "(e) exactly 4 _dismiss_codex_update_prompt callsites (A launch_worker, B launch_verifier, C safe_send_keys, D wait_for_pane_ready)" \
  || no "(e) expected 4 dismisser callsites, got $_callsites"

_regex_defs=$(grep -c "^_RLP_CODEX_UPDATE_RE=" "$RUN")
{ [[ "$_regex_defs" == 1 ]] } \
  && ok "(e) exactly ONE canonical _RLP_CODEX_UPDATE_RE definition" \
  || no "(e) expected 1 canonical regex definition, got $_regex_defs"

_dead=$(grep -c 'new version\|update\.\*codex\|codex\.\*update' "$RUN")
{ [[ "$_dead" == 0 ]] } \
  && ok "(e) no stray dead update regex remains (negative grep clean)" \
  || no "(e) dead 'new version|update.*codex' regex still present ($_dead)"

# The dismisser exists and returns 0/1 (present + dismissed vs no dialog).
_dsrc=$(awk '/^_dismiss_codex_update_prompt\(\)/,/^\}/' "$RUN")
{ grep -q 'return 1' <<< "$_dsrc" && grep -q 'return 0' <<< "$_dsrc" \
  && grep -q '_RLP_CODEX_UPDATE_RE' <<< "$_dsrc"; } \
  && ok "(e) shared dismisser uses the canonical regex + returns 0 (dismissed) / 1 (no dialog)" \
  || no "(e) shared dismisser body malformed (regex/return contract missing)"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
