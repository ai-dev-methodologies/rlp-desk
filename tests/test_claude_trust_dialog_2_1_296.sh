#!/bin/zsh
# ============================================================================
# claude CLI 2.1.296 trust dialog — deterministic accept (g55promo-a2/a3 incidents).
#
# claude 2.1.296 opens with
#     Quick safety check: Is this a project you created or one you trust? ...
#     ❯ No, exit
#       Yes, I trust this folder
#     Enter to confirm · Esc to cancel
# with the cursor DEFAULTING TO "No, exit" (unnumbered options). Enter confirms
# whatever the cursor is on, so every site that answers a claude trust dialog must
# read the cursor first. Round 1 (a2): wait_for_pane_ready / safe_send_keys /
# auto_dismiss_prompts only knew the old wording and Enter'd on "No, exit".
# Round 2 (a3 + codex review TRUST-A/B/C):
#   A  only an ACTIVE trust dialog may be navigated: trust heading + its own
#      Yes/No trust options + the footer as the LAST screen content. Trust words in
#      worker prose, a quoted menu in scrollback, or a different dialog (bypass-
#      permissions "Yes, I accept") never authorize a key.
#   B  unknown cursor never becomes Enter (no "legacy" fallback): retry, then fail.
#   C  readiness in claude mode needs claude to OWN the pane (pane_current_command
#      not a shell) AND its own input UI rendered — the shell echo of the launch
#      command (zsh prompt `❯ ...claude...`) is not ready — and a trust re-check
#      sits right before every direct paste+Enter in launch_worker/verifier_claude.
#
# Drives the REAL functions extracted from run_ralph_desk.zsh against a fake tmux
# whose pane is a tiny state machine, so a wrong key sequence is observable as the
# pane state (claude exited), not just as a recorded string.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
zmodload zsh/datetime

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # override only for mutation checks
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
check(){ # $1=label $2=expected $3=actual
  [[ "$2" == "$3" ]] && ok "$1" || no "$1 (expected '$2', got '$3')"
}

# --- extract the real functions under test ---------------------------------
_extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RUN"; }
TMP_LIB=$(mktemp -t claude-trust-dialog.XXXXXX)
trap 'rm -f "$TMP_LIB"' EXIT
{
  _extract_fn wait_for_pane_ready
  _extract_fn safe_send_keys
  _extract_fn launch_worker_claude
  _extract_fn launch_verifier_claude
  # §4.13.a region: prompt regexes + trust helpers + auto_dismiss_prompts
  sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN" | sed '$d'
} > "$TMP_LIB"
for f in wait_for_pane_ready safe_send_keys launch_worker_claude launch_verifier_claude auto_dismiss_prompts; do
  grep -q "^${f}()" "$TMP_LIB" || { print -u2 "FAIL: $f not extracted"; exit 1; }
done

# --- mocks -------------------------------------------------------------------
typeset -ga KEYS LOGS ERRS BLOCKS
typeset -g STATE="ready" STUCK=0 CHAT_TEXT="" DELAY_TARGET="" DELAY_AT=0 NARROW=0
sleep() { command sleep 0.02; }
log() { LOGS+=("$*"); }
log_debug() { LOGS+=("DEBUG $*"); }
log_error() { ERRS+=("$*"); }
write_blocked_sentinel() { BLOCKS+=("$*"); }
_dismiss_codex_update_prompt() { return 1; }
_validate_int_knob() { :; }   # §4.13.a region has top-level knob-validation calls; real one lives earlier in prod
check_copy_mode() { return 0; }
_paste_cmd_echo_verified() { KEYS+=("LAUNCH_PASTE"); return 0; }

# Pane model. DELAY_TARGET/DELAY_AT: after DELAY_AT (EPOCHREALTIME) the pane turns
# into DELAY_TARGET by itself — claude "starting up" and rendering late.
_eff() { if [[ -n "$DELAY_TARGET" ]] && (( EPOCHREALTIME >= DELAY_AT )); then print -r -- "$DELAY_TARGET"; else print -r -- "$STATE"; fi; }
_settle() { if [[ -n "$DELAY_TARGET" ]] && (( EPOCHREALTIME >= DELAY_AT )); then STATE="$DELAY_TARGET"; DELAY_TARGET=""; fi; }
_pcmd() { case "$(_eff)" in starting|exited) print zsh ;; *) print claude.exe ;; esac; }
paste_to_pane() { _settle; if [[ "$2" == claude-launch-cmd ]]; then KEYS+=("LAUNCH_PASTE"); else KEYS+=("PASTE@$STATE"); fi; }

_dialog_new() { # $1 = cursor on: no|yes|none
  print -r -- " Accessing workspace:"
  print -r -- " /path/to/proj"
  print -r -- " Quick safety check: Is this a project you created or one you trust? (Like your own code, a well-known open source project, or work from your team). If not, take a moment to review what's in this"
  print -r -- " folder first."
  print -r -- " Claude Code'll be able to read, edit, and execute files here."
  print -r -- " Security guide"
  case "$1" in
    no)  print -r -- " ❯ No, exit"; print -r -- "   Yes, I trust this folder" ;;
    yes) print -r -- "   No, exit"; print -r -- " ❯ Yes, I trust this folder" ;;
    *)   print -r -- "   No, exit"; print -r -- "   Yes, I trust this folder" ;;
  esac
  print -r -- " Enter to confirm · Esc to cancel"
}
_dialog_old() { # claude <=2.1.1xx numbered, default Yes
  print -r -- " Do you trust the files in this folder?"
  print -r -- " /path/to/proj"
  print -r -- " ❯ 1. Yes, proceed"
  print -r -- "   2. No, exit"
  print -r -- " Enter to confirm · Esc to cancel"
}
_dialog_old_codexstyle() {
  print -r -- " Do you trust the contents of this directory?"
  print -r -- " › 1. Yes, continue"
  print -r -- "   2. No, quit"
  print -r -- " Press enter to continue"
}
_bypass_dialog() { # a DIFFERENT claude dialog (cursor defaults to No) — never ours to answer
  print -r -- " WARNING: Claude Code running in Bypass Permissions mode"
  print -r -- " By proceeding, you accept all responsibility for actions taken while running in Bypass Permissions mode."
  print -r -- " ❯ 1. No, exit"
  print -r -- "   2. Yes, I accept"
  print -r -- " Enter to confirm · Esc to cancel"
}
_claude_box() {
  print -r -- " ▐▛███▛█   Claude Code v2.1.296"
  print -r -- "▝▜██████▀  Haiku 5.5 with low effort · Claude Max"
  print -r -- ""
  print -r -- "────────────────────────────────────────────────────────────────────────────────────"
  print -r -- "❯ Try \"refactor <filepath>\""
  print -r -- "────────────────────────────────────────────────────────────────────────────────────"
  print -r -- "  ⏵⏵ bypass permissions on (shift+tab to cycle)"
}
_quoted_menu() { _dialog_new no; }
_stale_heading_other() { # stale trust-heading prose + an UNRELATED dialog sharing option labels (codex r2 TRUST-A)
  print -r -- "● Earlier: Quick safety check: Is this a project you created or one you trust? — answered."
  print -r -- " Do you want to reset all settings?"
  print -r -- " ❯ No, exit"; print -r -- "   Yes, proceed"
  print -r -- " Enter to confirm · Esc to cancel"
}
_stale_ui_bypass() { _claude_box; _bypass_dialog; }   # input UI in scrollback ABOVE a bypass warning (TRUST-D)

# NARROW=1: a 40-column pane. A plain capture-pane soft-wraps long lines (fold) while
# capture-pane -J returns the joined logical lines, like real tmux (TRUST-E).
_emit() { if (( NARROW )) && [[ "$*" != *" -J"* ]]; then LC_ALL=en_US.UTF-8 fold -w 40; else cat; fi; }
tmux() {
  local sub="$1"
  case "$sub" in
    capture-pane)
      { case "$(_eff)" in
        dialog_no)  _dialog_new no ;;
        dialog_yes) _dialog_new yes ;;
        dialog_unknown) _dialog_new none ;;
        old_yes)    _dialog_old ;;
        codex_yes)  _dialog_old_codexstyle ;;
        stale_heading_other) _stale_heading_other ;;
        stale_ui_bypass) _stale_ui_bypass ;;
        head_foot)  print -r -- " Quick safety check: Is this a project you created or one you trust?"; print -r -- " Enter to confirm · Esc to cancel" ;;
        prose_bypass) print -r -- "● I trust this folder now. The Quick safety check passed earlier."; _bypass_dialog ;;
        bypass)     _bypass_dialog ;;
        quoted_ready) print -r -- "● The CLI shows:"; _dialog_new no; print -r -- "● that is the trust prompt. Anyway, done."; _claude_box ;;
        chat)       print -r -- "$CHAT_TEXT" ;;
        starting)   print -r -- "❯ DISABLE_OMC=1 /opt/homebrew/bin/claude --model 'claude-opus-5-5' --dangerously-skip-permissions --effort low" ;;
        exited)     print -r -- "kyjin@host rlp-desk % " ;;
        *)          _claude_box ;;
      esac; } | _emit "$@" ;;
    display-message)
      if [[ "$*" == *pane_current_command* ]]; then _pcmd; else print -- 0; fi ;;
    send-keys)
      _settle
      local key="${@: -1}"; [[ "$key" == "C-m" ]] && key="Enter"
      KEYS+=("$key")
      case "$STATE:$key" in
        dialog_no:Down)  (( STUCK )) || STATE="dialog_yes" ;;
        dialog_no:Enter) STATE="exited" ;;          # selects "No, exit" -> claude quits
        dialog_yes:Enter|old_yes:Enter|codex_yes:Enter) STATE="ready" ;;
        dialog_yes:Down) STATE="dialog_no" ;;
        bypass:Enter|prose_bypass:Enter|stale_ui_bypass:Enter|stale_heading_other:Enter) STATE="exited" ;;
        stale_heading_other:Down) STATE="stale_heading_other" ;;
      esac ;;
  esac
  return 0
}

typeset -gA LAST_AUTO_APPROVE_TS PANE_PROMPT_STUCK_SINCE PANE_DISMISS_FAILED_COUNT PANE_VERIFIER_TRACE_LOGGED
source "$TMP_LIB"

_reset() { KEYS=(); LOGS=(); ERRS=(); BLOCKS=(); LAST_AUTO_APPROVE_TS=(); STUCK=0; NARROW=0; CHAT_TEXT=""; DELAY_TARGET=""; DELAY_AT=0; STATE="$1"; }
_keys() { print -r -- "${(j:,:)KEYS}"; }
_logged() { [[ "${(j:|:)LOGS}" == *"$1"* ]]; }

# ---------------------------------------------------------------------------
# Round 1: dialog handling, both readiness modes ("" = shell/legacy, claude)
# ---------------------------------------------------------------------------
for MODE in "" claude; do
print "== wait_for_pane_ready ${MODE:-(shell mode)} =="
_reset dialog_no
wait_for_pane_ready "%t" 5 $MODE; rc=$?
check "W1[$MODE] new dialog, cursor on 'No, exit': Down then Enter, never Enter first" "Down,Enter" "$(_keys)"
check "W1[$MODE] pane ended at the ready prompt (claude did NOT exit)" "ready" "$STATE"
check "W1[$MODE] returns ready only after the dialog was dismissed" "0" "$rc"
_logged claude_trust_prompt && ok "W1[$MODE] [GOV] claude_trust_prompt logged" || no "W1[$MODE] no claude_trust_prompt log line"

_reset dialog_yes
wait_for_pane_ready "%t" 5 $MODE; rc=$?
check "W2[$MODE] new dialog, cursor already on Yes: Enter only" "Enter" "$(_keys)"
check "W2[$MODE] pane ended ready" "ready" "$STATE"

_reset old_yes
wait_for_pane_ready "%t" 5 $MODE; rc=$?
check "W3[$MODE] old 'Do you trust' format (positively identified, cursor on Yes) accepted: Enter only" "Enter" "$(_keys)"
check "W3[$MODE] pane ended ready" "ready" "$STATE"

_reset codex_yes
wait_for_pane_ready "%t" 5 $MODE; rc=$?
check "W3b[$MODE] codex-style '› 1. Yes, continue' trust menu: Enter only" "Enter" "$(_keys)"

_reset dialog_no; STUCK=1
wait_for_pane_ready "%t" 3 $MODE; rc=$?
[[ "$(_keys)" != *Enter* ]] && ok "W5[$MODE] cursor stuck on No: Enter never pressed (keys: $(_keys))" || no "W5[$MODE] pressed Enter while cursor on No ($(_keys))"
(( rc != 0 )) && ok "W5[$MODE] non-ready return code ($rc)" || no "W5[$MODE] reported ready with the dialog still visible"
[[ "$STATE" == dialog_no ]] && ok "W5[$MODE] claude still alive on the dialog (not exited)" || no "W5[$MODE] pane state '$STATE'"
(( ${#ERRS[@]} >= 1 )) && [[ "${(j:|:)ERRS}" == *rust* ]] && ok "W5[$MODE] loud log_error naming the trust dialog" || no "W5[$MODE] no loud error (ERRS=${(j:|:)ERRS})"
nd=${#${(M)KEYS:#Down}}
(( nd >= 1 && nd <= 5 )) && ok "W5[$MODE] Down attempts bounded ($nd)" || no "W5[$MODE] Down attempts not bounded/zero ($nd)"
done

print "== wait_for_pane_ready (shell mode): chat text =="
_reset chat
CHAT_TEXT="● I trust this refactor is safe. Do you trust the result? Quick safety check done.
Is this a project you want me to scaffold? Let me know.
╭──────────────╮
│ ❯            │
╰──────────────╯"
wait_for_pane_ready "%t" 5; rc=$?
check "W4 ordinary chat text mentioning trust: no keys sent" "" "$(_keys)"
check "W4 chat pane reported ready" "0" "$rc"

# ---------------------------------------------------------------------------
print "== auto_dismiss_prompts =="
_reset dialog_no
auto_dismiss_prompts "%t"
check "A1 new dialog, cursor on No: Down then Enter" "Down,Enter" "$(_keys)"
check "A1 pane ended ready" "ready" "$STATE"

_reset dialog_yes
auto_dismiss_prompts "%t"
check "A2 new dialog, cursor on Yes: Enter only" "Enter" "$(_keys)"

_reset old_yes
auto_dismiss_prompts "%t"
check "A3 old numbered dialog: Enter only" "Enter" "$(_keys)"

_reset chat
CHAT_TEXT="● I trust this is right. Do you trust the output? Quick safety check passed.
╭──────────────╮
│ ❯            │
╰──────────────╯"
auto_dismiss_prompts "%t"
check "A4 ordinary chat text mentioning trust: no keys" "" "$(_keys)"

_reset dialog_no; STUCK=1
auto_dismiss_prompts "%t"
[[ "$(_keys)" != *Enter* ]] && ok "A5 stuck on No: no Enter (keys: $(_keys))" || no "A5 pressed Enter while cursor on No"
(( ${#ERRS[@]} >= 1 )) && ok "A5 loud log_error" || no "A5 silent failure"
(( ${#BLOCKS[@]} >= 1 )) && ok "A5 BLOCKED sentinel written (infra_failure)" || no "A5 no BLOCKED sentinel"

# ---------------------------------------------------------------------------
print "== safe_send_keys =="
_reset dialog_no
safe_send_keys "%t" "do the thing"
check "S1 cursor on No: Down,Enter happen BEFORE the paste" "Down,Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,3]}}"

_reset dialog_yes
safe_send_keys "%t" "do the thing"
check "S2 cursor on Yes: Enter before the paste" "Enter,PASTE@ready" "${(j:,:)${(@)KEYS[1,2]}}"

_reset dialog_no; STUCK=1
safe_send_keys "%t" "do the thing"; rc=$?
[[ "$(_keys)" != *Enter* && "$(_keys)" != *PASTE* ]] && ok "S3 stuck on No: no Enter, instruction NOT pasted into the dialog" || no "S3 keys: $(_keys)"
(( rc != 0 )) && ok "S3 non-zero return" || no "S3 returned 0 with the dialog unresolved"

# ===========================================================================
# Round 2
# ===========================================================================
print "== TRUST-C: claude-mode readiness =="
_reset starting
wait_for_pane_ready "%t" 2 claude; rc=$?
(( rc != 0 )) && ok "C1 shell echo '❯ ...claude...' with pane_current_command=zsh is NOT ready (rc=$rc)" || no "C1 shell echo was declared ready (a3 incident)"
check "C1 no keys sent into the shell" "" "$(_keys)"

_reset starting; DELAY_TARGET=dialog_no; DELAY_AT=$(( EPOCHREALTIME + 0.8 ))
wait_for_pane_ready "%t" 10 claude; rc=$?
check "C2 dialog appearing after a delay is handled: Down then Enter" "Down,Enter" "$(_keys)"
check "C2 pane ended ready (claude alive)" "ready" "$STATE"
check "C2 returns ready" "0" "$rc"

_reset starting; DELAY_TARGET=ready; DELAY_AT=$(( EPOCHREALTIME + 0.8 ))
t0=$EPOCHREALTIME
wait_for_pane_ready "%t" 10 claude; rc=$?
(( rc == 0 && EPOCHREALTIME >= DELAY_AT )) && ok "C3 trusted folder, delayed render: ready only after claude rendered its input UI" || no "C3 ready before claude rendered (rc=$rc)"
check "C3 no keys needed" "" "$(_keys)"

# zsh prints `name=value` when a loop-body `local name` (no assignment) is re-declared:
# stdout noise that corrupts any `$(wait_for_pane_ready ...)` / piped caller (found live).
_reset starting; DELAY_TARGET=ready; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))
_out=$(wait_for_pane_ready "%t" 10 claude 2>/dev/null)
[[ -z "$_out" ]] && ok "C3b wait_for_pane_ready (claude mode) writes nothing to stdout across polling iterations" || no "C3b stdout noise: ${_out:0:80}"

_reset quoted_ready
wait_for_pane_ready "%t" 5 claude; rc=$?
check "C4 quoted trust menu mid-scrollback + normal claude input box at bottom: no keys" "" "$(_keys)"
check "C4 pane is ready (claude input UI rendered)" "0" "$rc"
_reset quoted_ready
auto_dismiss_prompts "%t"
check "C4b same capture through auto_dismiss_prompts: no keys" "" "$(_keys)"

print "== TRUST-C: launch paths wait for claude and re-check before submit =="
for LF in launch_verifier_claude launch_worker_claude; do
  _reset starting; DELAY_TARGET=dialog_no; DELAY_AT=$(( EPOCHREALTIME + 0.8 ))
  $LF "%t" "/tmp/prompt.md" 1 "claude-launch-cmd"; rc=$?
  ks="$(_keys)"
  [[ "$ks" == *"PASTE@ready"* && "$ks" != *"PASTE@starting"* && "$ks" != *"PASTE@dialog"* ]] \
    && ok "L1[$LF] instruction pasted only after claude rendered its input UI (keys: ${ks:0:80})" \
    || no "L1[$LF] instruction pasted too early: $ks"
  [[ "$STATE" != exited ]] && ok "L1[$LF] claude still alive after the launch sequence" || no "L1[$LF] claude EXITED (Enter landed on 'No, exit')"
  [[ "$ks" == *Down,Enter* ]] && ok "L1[$LF] dialog answered Down,Enter" || no "L1[$LF] dialog not answered deterministically: $ks"
done

# pre-submit guard: dialog appears between ready and the paste
for LF in launch_verifier_claude launch_worker_claude; do
  _reset starting
  # readiness returns OK, then the dialog pops in before the submit
  wait_for_pane_ready() { STATE=dialog_no; return 0; }
  $LF "%t" "/tmp/prompt.md" 1 "claude-launch-cmd"; rc=$?
  ks="$(_keys)"
  [[ "$ks" == "LAUNCH_PASTE,Enter,Down,Enter,PASTE@ready"* ]] && ok "G1[$LF] dialog appearing right before submit: Down,Enter then paste (keys: ${ks:0:70})" || no "G1[$LF] guard missing: $ks"
  unfunction wait_for_pane_ready; source "$TMP_LIB"
  _reset starting
  # claude gone (bare shell) at submit time: never paste the instruction into zsh
  wait_for_pane_ready() { return 0; }
  $LF "%t" "/tmp/prompt.md" 1 "claude-launch-cmd"; rc=$?
  [[ "$(_keys)" != *PASTE@starting* ]] && ok "G2[$LF] pane is a bare shell at submit time: instruction NOT pasted" || no "G2[$LF] pasted the instruction into the shell"
  (( rc != 0 )) && ok "G2[$LF] failure returned" || no "G2[$LF] returned 0"
  unfunction wait_for_pane_ready; source "$TMP_LIB"
done

print "== TRUST-A: only an ACTIVE trust dialog may be navigated =="
_reset prose_bypass
wait_for_pane_ready "%t" 2 claude; rc=$?
check "T1 worker prose 'trust this folder' + bypass-permissions dialog (wait): no keys" "" "$(_keys)"
_reset prose_bypass
auto_dismiss_prompts "%t"
check "T1b same capture (auto_dismiss_prompts): no keys" "" "$(_keys)"
_reset prose_bypass
safe_send_keys "%t" "do the thing"
[[ -z "$(_keys)" ]] && ok "T1c same capture (safe_send_keys): refused, no keys (round 3: unrecognized dialog is never pasted into)" || no "T1c keys: $(_keys)"

_reset bypass
auto_dismiss_prompts "%t"
check "T2 bypass-permissions dialog alone (no trust wording): never touched" "" "$(_keys)"

print "== TRUST-B: unknown selection never becomes Enter =="
_reset head_foot
wait_for_pane_ready "%t" 2 claude; rc=$?
check "B1 heading+footer only (no options): no keys (wait)" "" "$(_keys)"
_reset head_foot
auto_dismiss_prompts "%t"
check "B1b heading+footer only: no keys (auto_dismiss)" "" "$(_keys)"
_reset head_foot
safe_send_keys "%t" "x"
[[ -z "$(_keys)" ]] && ok "B1c heading+footer only: send refused, no keys" || no "B1c keys: $(_keys)"

_reset dialog_unknown
wait_for_pane_ready "%t" 3 claude; rc=$?
[[ "$(_keys)" != *Enter* ]] && ok "B2 options visible but no cursor on any: no Enter (keys: $(_keys))" || no "B2 Enter pressed with unknown cursor"
(( rc != 0 )) && ok "B2 fails loudly (rc=$rc)" || no "B2 reported ready"
(( ${#ERRS[@]} >= 1 )) && ok "B2 log_error written" || no "B2 silent"
_reset dialog_unknown
auto_dismiss_prompts "%t"
[[ "$(_keys)" != *Enter* ]] && ok "B2b unknown cursor (auto_dismiss): no Enter" || no "B2b Enter pressed"
(( ${#BLOCKS[@]} >= 1 )) && ok "B2b BLOCKED sentinel written" || no "B2b no sentinel"

# ===========================================================================
# Round 3 (codex r2): heading binding, send-path refusal, bottom-most input UI, narrow
# ===========================================================================
print "== R3 TRUST-A: heading must belong to the active dialog =="
_reset stale_heading_other
check "RA1 stale trust heading + unrelated 'Do you want to ...?' dialog sharing option labels: state none" "none" "$(_claude_trust_dialog_state "$(tmux capture-pane -p)")"
_reset stale_heading_other
wait_for_pane_ready "%t" 2 claude; rc=$?
check "RA1 (wait, claude mode): no keys, claude not exited" "" "$(_keys)"
_reset stale_heading_other
_claude_presubmit_guard "%t" test; rc=$?
(( rc != 0 )) && [[ "$(_keys)" != *Down* && "$(_keys)" != *Enter* ]] && ok "RA1 (presubmit guard): refused, no keys" || no "RA1 guard rc=$rc keys=$(_keys)"
_reset stale_heading_other
auto_dismiss_prompts "%t"
[[ "$(_keys)" != *Down* ]] && ok "RA1 (auto_dismiss): never navigates it with Down" || no "RA1 auto_dismiss keys=$(_keys)"

print "== R3 TRUST-B: incomplete/unrecognized bottom dialog refuses paste+Enter =="
for ST in head_foot prose_bypass bypass; do
  _reset $ST
  safe_send_keys "%t" "do the thing"; rc=$?
  (( rc != 0 )) && [[ "$(_keys)" != *PASTE* && "$(_keys)" != *Enter* ]] && ok "RB1[$ST] safe_send_keys refuses: rc=$rc, no paste, no Enter" || no "RB1[$ST] rc=$rc keys=$(_keys)"
  (( ${#ERRS[@]} >= 1 )) && ok "RB1[$ST] refusal logged" || no "RB1[$ST] silent refusal"
  [[ "$STATE" != exited ]] && ok "RB1[$ST] claude/pane not exited" || no "RB1[$ST] pane EXITED"
done
_reset starting
safe_send_keys "%t" "echo shell-cmd"; rc=$?
[[ "$(_keys)" == PASTE@starting,Enter* ]] && ok "RB2 plain shell pane: send unchanged (paste, Enter)" || no "RB2 keys=$(_keys)"
_reset ready
safe_send_keys "%t" "hello"; rc=$?
[[ "$(_keys)" == PASTE@ready,Enter* ]] && ok "RB2 plain input-ready claude pane: send unchanged" || no "RB2b keys=$(_keys)"

print "== R3 TRUST-D: input UI must be the bottom-most UI element =="
_reset stale_ui_bypass
wait_for_pane_ready "%t" 2 claude; rc=$?
(( rc != 0 )) && ok "RD1 input UI in scrollback above a bypass warning is NOT ready (rc=$rc)" || no "RD1 declared ready"
check "RD1 no keys sent into the warning" "" "$(_keys)"
_reset stale_ui_bypass
_claude_presubmit_guard "%t" test; rc=$?
(( rc != 0 )) && [[ "$(_keys)" == "" ]] && ok "RD1 presubmit guard refuses (rc=$rc), no keys" || no "RD1 guard rc=$rc keys=$(_keys)"
for LF in launch_verifier_claude launch_worker_claude; do
  _reset starting
  wait_for_pane_ready() { STATE=stale_ui_bypass; return 0; }   # claude "ready", then the warning is what is on screen
  $LF "%t" "/tmp/prompt.md" 1 "claude-launch-cmd"; rc=$?
  [[ "$(_keys)" != *PASTE@stale* && "$STATE" != exited ]] && ok "RD2[$LF] never pastes into the bypass warning, claude alive" || no "RD2[$LF] keys=$(_keys) state=$STATE"
  unfunction wait_for_pane_ready; source "$TMP_LIB"
done
_reset bypass
wait_for_pane_ready "%t" 2 claude; rc=$?
(( rc != 0 )) && [[ "$(_keys)" == "" && ${#ERRS[@]} -ge 1 ]] && ok "RD3 bypass warning alone: not ready, loud error, no keys (pre-existing: no auto-handling)" || no "RD3 rc=$rc keys=$(_keys)"

print "== R3 TRUST-E: soft-wrapped narrow panes (capture-pane -J) =="
_reset dialog_no; NARROW=1
wait_for_pane_ready "%t" 5 claude; rc=$?
check "RE1 40-col pane, wrapped trust dialog: Down then Enter" "Down,Enter" "$(_keys)"
check "RE1 ready afterwards (wrapped rule-delimited input UI recognised)" "0" "$rc"
_reset ready; NARROW=1
wait_for_pane_ready "%t" 3 claude; rc=$?
check "RE2 40-col pane, wrapped rule-delimited input UI is ready" "0" "$rc"
_reset dialog_yes; NARROW=1
auto_dismiss_prompts "%t"
check "RE3 40-col pane, auto_dismiss_prompts: Enter only (cursor on Yes)" "Enter" "$(_keys)"
_reset dialog_no; NARROW=1
_claude_presubmit_guard "%t" test; rc=$?
check "RE4 40-col pane, presubmit guard: Down,Enter" "Down,Enter" "$(_keys)"


print ""
print "claude_trust_dialog_2_1_296: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
