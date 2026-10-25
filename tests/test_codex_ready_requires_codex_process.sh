#!/bin/zsh
# ============================================================================
# codex TUI readiness must require the codex PROCESS (SV S6 g55luna-a1 incident).
#
# launch_worker_codex / launch_verifier_codex declared "ready after 0s" on
# `grep -qE '[›❯]'`, which the user's zsh prompt (`❯`, echoed with the launch command)
# satisfies before codex renders anything. The instruction was then sent into the
# shell, codex died, "worker not active" x3. Readiness now also needs
# pane_current_command to be a non-shell process; the F-1 update-dialog dismiss and
# the F-16 trust-prompt accept still run before the ready check.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true
zmodload zsh/datetime
SCRIPT_DIR="${0:A:h}"; ROOT_DIR="${SCRIPT_DIR:h}"
RUN="${RLP_TEST_RUN_SCRIPT:-$ROOT_DIR/src/scripts/run_ralph_desk.zsh}"   # override only for mutation checks
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

_extract_fn() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "$RUN"; }
TMP_LIB=$(mktemp -t codex-ready.XXXXXX); trap 'rm -f "$TMP_LIB" "$CNT" "$CNT.seen" "$CAP"' EXIT
{ grep -E "^_RLP_CODEX_UPDATE_RE=" "$RUN"
  for f in launch_worker_codex launch_verifier_codex _dismiss_codex_update_prompt _codex_dialog_kind _codex_ready_surface _codex_presubmit_guard; do _extract_fn $f; done; } > "$TMP_LIB"
for f in launch_worker_codex launch_verifier_codex _dismiss_codex_update_prompt; do
  grep -q "^${f}()" "$TMP_LIB" || { print -u2 "FAIL: $f not extracted"; exit 1; }
done

typeset -ga EV ERRS
CNT=$(mktemp -t codex-ready-cnt.XXXXXX)
CAP=$(mktemp -t codex-ready-cap.XXXXXX)   # capture-pane call counter (file: captures run in subshells)
typeset -g STATE=codex_ready DELAY_TARGET="" DELAY_AT=0 DELAY_CAPS=0 NARROW=0
sleep() { command sleep 0.01; }
log() { :; }; log_debug() { :; }; log_error() { ERRS+=("$*"); }
ITERATION=1
_paste_cmd_echo_verified() { EV+=("LAUNCH_PASTE"); return 0; }
_due() { [[ -n "$DELAY_TARGET" ]] || return 1; if (( DELAY_CAPS > 0 )); then (( $(<"$CAP") >= DELAY_CAPS )); else (( EPOCHREALTIME >= DELAY_AT )); fi; }   # DELAY_CAPS>0: flip after that many capture-pane calls (load-independent); else wall clock
_eff() { if _due; then print -r -- "$DELAY_TARGET"; else print -r -- "$STATE"; fi; }
_settle() { if _due; then STATE="$DELAY_TARGET"; DELAY_TARGET=""; fi; }
_pcmd() { case "$(_eff)" in shell_echo) print zsh ;; *) print codex ;; esac; }
paste_to_pane() { _settle; if [[ "$2" == codex-launch-cmd ]]; then EV+=("LAUNCH_PASTE"); else EV+=("PASTE@$STATE"); fi; }
# NARROW=1: 14-column pane — plain capture-pane soft-wraps (fold), -J returns the joined lines.
_emit() { if (( NARROW )) && [[ "$*" != *" -J"* ]]; then LC_ALL=en_US.UTF-8 fold -w 14; else cat; fi; }
# Deterministic under load: captures are counted only AFTER display-message has reported the codex
# process once (so a cmd-read / capture straddling the state switch cannot shift the count).
_late_ui() { # after readiness (capture 3+) the pane shows: $1
  local n=0
  if [[ -e "$CNT.seen" ]]; then n=$(cat "$CNT" 2>/dev/null || print 0); n=$((n + 1)); print -r -- "$n" > "$CNT"; fi
  if (( n <= 2 )); then print -r -- "❯ codex-launch-cmd"; print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "› Ask Codex to do anything"; return; fi
  case "$1" in
    chat)     print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "• You asked earlier: Do you trust the contents of this directory? It is 1. Yes, continue — a quoted menu."; print -r -- "› Ask Codex to do anything"; print -r -- "  ? for shortcuts" ;;
    stucktrust) print -r -- "  Folder access"; print -r -- "  Trust this folder? Codex can read, edit, and run files here."; print -r -- "› 1. Trust and continue"; print -r -- "  2. Quit"; print -r -- "  enter continue · esc quit" ;;
    update)   print -r -- "✨ Update available! 0.150 -> 0.151"; print -r -- "› 1. Update now"; print -r -- "  2. Skip" ;;
    promo)    # EXACT live capture (codex 0.162.1): non-modal promo with codex's own input surface BELOW it
              print -r -- "  Set up security for Daybreak mode"; print -r -- "  Set up Advanced Account Security with a hardware security key. You can keep using Codex while you finish setup."; print -r -- "› 1. Set up security"; print -r -- "  Press a number to choose · esc to dismiss · type to continue"; print -r -- "› Ask Codex to do anything"; print -r -- "  GPT-6-Luna high · main · Context 100% left · 0 in · 0 out · weekly 66% left"; print -r -- "  ? for shortcuts                                       ⚠ 2 warnings · f2 to view" ;;
    quoted)   # codex review r2: a chat-quoted trust menu followed by codex's input surface
              print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "• Earlier the CLI showed:"; print -r -- "  › 1. Trust and continue"; print -r -- "    2. Quit"; print -r -- "    enter continue · esc quit"; print -r -- "• (that was only a quote)"; print -r -- "› Ask Codex to do anything"; print -r -- "  ? for shortcuts" ;;
    modelerr) print -r -- "■ The model `gpt-6-luna` does not exist or you do not have access to it."; print -r -- "› Ask Codex to do anything"; print -r -- "  ? for shortcuts" ;;
  esac
}
tmux() {
  case "$1" in
    capture-pane)
      print -r -- $(( $(<"$CAP") + 1 )) > "$CAP"
      { case "$(_eff)" in
        late_chat)       _late_ui chat ;;
        late_stucktrust) _late_ui stucktrust ;;
        late_update)     _late_ui update ;;
        late_promo)      _late_ui promo ;;
        late_quoted)     _late_ui quoted ;;
        loop_quoted)     print -r -- "❯ codex-launch-cmd"; print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "  › 1. Trust and continue"; print -r -- "    2. Quit"; print -r -- "    enter continue · esc quit"; print -r -- "› Ask Codex to do anything"; print -r -- "  ? for shortcuts" ;;
        late_modelerr)   _late_ui modelerr ;;
        wrapecho)        print -r -- "❯ codex-lau"; print -r -- "nch-cmd" ;;
        wrapecho_ready)  print -r -- "❯ codex-lau"; print -r -- "nch-cmd"; print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "› Ask Codex to do anything" ;;
        shell_echo)  print -r -- "❯ codex-launch-cmd" ;;
        booting)     print -r -- "❯ codex-launch-cmd" ;;   # codex process started (cmd=codex) but rendered nothing yet
        trust)       print -r -- "❯ codex-launch-cmd"; print -r -- "Do you trust the contents of this directory?"; print -r -- "› 1. Yes, continue"; print -r -- "  2. No, quit" ;;
        trust162)    print -r -- "❯ codex-launch-cmd"; print -r -- "  Folder access"; print -r -- "  Trust this folder? Codex can read, edit, and run files here."; print -r -- "› 1. Trust and continue"; print -r -- "  2. Quit"; print -r -- "  enter continue · esc quit" ;;
        late_trust)  _late_ui stucktrust ;;   # codex >= 0.162: main UI first, trust dialog AFTER readiness (Enter accepts)
        update)      print -r -- "✨ Update available! 0.150 -> 0.151"; print -r -- "› 1. Update now"; print -r -- "  2. Skip" ;;
        *)           print -r -- "❯ codex-launch-cmd"; print -r -- "OpenAI Codex (v0.150.0)"; print -r -- "› Ask Codex to do anything" ;;
      esac; } | _emit "$@" ;;
    display-message) if [[ "$*" == *pane_current_command* ]]; then case "$(_eff)" in late_*) : > "$CNT.seen" ;; esac; _pcmd; else print -- 0; fi ;;
    send-keys)
      _settle
      local key="${@: -1}"; [[ "$key" == "C-m" ]] && key=Enter
      EV+=("KEY:$key")
      case "$STATE:$key" in
        trust:Enter|trust162:Enter|late_trust:Enter) STATE=codex_ready ;;
        update:Enter) STATE=codex_ready ;;
      esac ;;
  esac
  return 0
}
source "$TMP_LIB"; _DBG=${RLP_DBG:-0}
_reset() { EV=(); ERRS=(); DELAY_TARGET=""; DELAY_AT=0; DELAY_CAPS=0; NARROW=0; STATE="$1"; print -r -- 0 > "$CAP"; }
_enters_before_paste() { local e n=0; for e in "${EV[@]}"; do [[ "$e" == PASTE@* ]] && break; [[ "$e" == KEY:Enter ]] && n=$((n+1)); done; print -r -- $n; }
_first_instr() { local e; for e in "${EV[@]}"; do [[ "$e" == PASTE@* ]] && { print -r -- "$e"; return; }; done; print -r -- none; }

for LF in launch_worker_codex launch_verifier_codex; do
  print "== $LF =="
  _reset shell_echo
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc != 0 && "$(_first_instr)" == none ]] && ok "R1[$LF] shell echo '❯ ...' with cmd=zsh is NOT ready: rc=$rc, no instruction sent" || no "R1[$LF] rc=$rc first-instr=$(_first_instr)"
  [[ "${(j:|:)ERRS}" == *"not ready"* ]] && ok "R1[$LF] loud failure logged" || no "R1[$LF] no loud failure (${(j:|:)ERRS})"

  _reset booting
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc != 0 && "$(_first_instr)" == none ]] && ok "R1b[$LF] codex process running (cmd=codex) but only the shell echo on screen: NOT ready, no instruction sent" || no "R1b[$LF] rc=$rc first-instr=$(_first_instr)"

  _reset booting; DELAY_TARGET=codex_ready; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc == 0 && "$(_first_instr)" == PASTE@codex_ready ]] && ok "R2b[$LF] booting codex renders late: instruction sent only after codex's own prompt appears below the echo" || no "R2b[$LF] rc=$rc first-instr=$(_first_instr)"

  _reset shell_echo; DELAY_TARGET=codex_ready; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc == 0 && "$(_first_instr)" == PASTE@codex_ready ]] && ok "R2[$LF] delayed codex render: instruction sent only once codex owns the pane and shows its prompt" || no "R2[$LF] rc=$rc first-instr=$(_first_instr)"

  _reset codex_ready
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc == 0 && "$(_first_instr)" == PASTE@codex_ready ]] && ok "R3[$LF] codex cmd + › prompt -> ready, instruction sent" || no "R3[$LF] rc=$rc first-instr=$(_first_instr)"

  _reset shell_echo; DELAY_TARGET=trust; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))   # dialog appears after the launch Enter
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ "${EV[1]}" == *KEY:Enter* || "${(j:,:)EV}" == *KEY:Enter* ]] && [[ "$(_first_instr)" == PASTE@codex_ready && $rc == 0 ]] \
    && ok "R4[$LF] F-16 trust prompt (1. Yes, continue) still accepted first, then instruction sent" || no "R4[$LF] rc=$rc ev=${(j:,:)EV[1,6]}"

  _reset shell_echo; DELAY_TARGET=trust162; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))   # codex >= 0.162 wording (live smoke finding)
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ "${(j:,:)EV}" == *KEY:Enter* && "$(_first_instr)" == PASTE@codex_ready && $rc == 0 ]] \
    && ok "R4b[$LF] codex 0.162 trust prompt (› 1. Trust and continue) accepted before any instruction" || no "R4b[$LF] rc=$rc ev=${(j:,:)EV[1,6]}"

  _reset shell_echo; DELAY_TARGET=late_trust; DELAY_CAPS=3; print -r -- 0 > "$CNT"; rm -f "$CNT.seen"
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  (( _DBG )) && print -u2 "DBG R6 ev=${(j:,:)EV}"
  [[ "$(_first_instr)" == PASTE@codex_ready && "${(j:,:)EV}" == *KEY:Enter*PASTE* && $rc == 0 ]] \
    && ok "R6[$LF] trust dialog appearing AFTER the ready check is accepted before the instruction is pasted" || no "R6[$LF] rc=$rc ev=${(j:,:)EV[1,8]}"

  _reset shell_echo; DELAY_TARGET=update; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ "${(j:,:)EV}" == *KEY:Down* && "$(_first_instr)" == PASTE@codex_ready && $rc == 0 ]] \
    && ok "R5[$LF] F-1 update dialog still dismissed (Down,Enter) before readiness" || no "R5[$LF] rc=$rc ev=${(j:,:)EV[1,8]}"

  # ---- round 7 (codex review): R-A wrapped echo, R-B active-dialog signature + submit re-validation ----
  _reset wrapecho
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc != 0 && "$(_first_instr)" == none ]] && ok "RA1[$LF] wrapped launch echo (anchor split) + node: NOT ready without codex's own surface; no paste" || no "RA1[$LF] rc=$rc first-instr=$(_first_instr)"
  _reset wrapecho; DELAY_TARGET=wrapecho_ready; DELAY_AT=$(( EPOCHREALTIME + 0.6 ))
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ $rc == 0 && "$(_first_instr)" == PASTE@wrapecho_ready ]] && ok "RA2[$LF] wrapped echo, codex banner+prompt appears: ready, pasted after" || no "RA2[$LF] rc=$rc first-instr=$(_first_instr)"

  _reset shell_echo; DELAY_TARGET=late_chat; DELAY_CAPS=3; print -r -- 0 > "$CNT"; rm -f "$CNT.seen"
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  _enters=$(_enters_before_paste)
  [[ $rc == 0 && "$(_first_instr)" == PASTE@late_chat && $_enters -le 1 ]] && ok "RB1[$LF] 'Do you trust' quoted in chat is NOT a trust dialog: no Enter sent, instruction pasted (launch Enters: $_enters)" || no "RB1[$LF] rc=$rc enters=$_enters ev=${(j:,:)EV[1,10]}"
  for K in stucktrust update modelerr; do
    _reset shell_echo; DELAY_TARGET=late_$K; DELAY_CAPS=3; print -r -- 0 > "$CNT"; rm -f "$CNT.seen"
    $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
    [[ $rc != 0 && "$(_first_instr)" == none && ${#ERRS[@]} -ge 1 ]] && ok "RB2[$LF][$K] dialog at the bottom at submit time: NO paste, loud failure (rc=$rc)" || no "RB2[$LF][$K] rc=$rc first-instr=$(_first_instr) errs=${#ERRS[@]} ev=${(j:,:)EV[1,8]}"
  done
  _reset shell_echo; DELAY_TARGET=trust162; DELAY_AT=$(( EPOCHREALTIME + 0.6 )); NARROW=1
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  [[ "${(j:,:)EV}" == *KEY:Enter* && "$(_first_instr)" == PASTE@codex_ready && $rc == 0 ]] && ok "RB3[$LF] wrapped (14-col) trust option still recognised (-J) and accepted before the paste" || no "RB3[$LF] rc=$rc first-instr=$(_first_instr) ev=${(j:,:)EV[1,8]}"

  # ---- round 8: a numbered menu is an ACTIVE dialog only when no codex input surface is below it ----
  for K in promo quoted; do
    _reset shell_echo; DELAY_TARGET=late_$K; DELAY_CAPS=3; print -r -- 0 > "$CNT"; rm -f "$CNT.seen"
    $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
    _enters=$(_enters_before_paste)
    [[ $rc == 0 && "$(_first_instr)" == PASTE@late_$K && $_enters -le 1 ]] && ok "R8a[$LF][$K] menu with codex's input surface BELOW it is non-blocking: no key sent, instruction pasted (rc=$rc, launch Enters=$_enters)" || no "R8a[$LF][$K] rc=$rc enters=$_enters first-instr=$(_first_instr) errs=${(j:|:)ERRS}"
  done
  _reset shell_echo; DELAY_TARGET=loop_quoted; DELAY_AT=$(( EPOCHREALTIME + 0.4 ))
  $LF "%t" "/tmp/p.md" 1 "codex-launch-cmd"; rc=$?
  _enters=$(_enters_before_paste)
  [[ $rc == 0 && "$(_first_instr)" == PASTE@loop_quoted && $_enters -le 1 ]] && ok "R8b[$LF] readiness loop: quoted trust menu above codex's input surface does NOT trigger the F-16 accept (Enters=$_enters)" || no "R8b[$LF] rc=$rc enters=$_enters first-instr=$(_first_instr)"
done

print ""; print "codex_ready_requires_codex_process: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
