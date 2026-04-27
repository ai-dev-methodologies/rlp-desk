#!/bin/zsh
# v5.7 §4.13.a unit test — auto_dismiss_prompts() line-adjacency contract.
# G12 acceptance: prompt phrase must have affordance marker on SAME, PREV, or
# NEXT line; otherwise NO auto-Enter (false-positive guard, R-V5-9).
#
# Mocks tmux capture-pane and tmux send-keys to avoid needing a live tmux server.
set -uo pipefail

# Sandbox the helpers — extract just the function definitions from run_ralph_desk.zsh.
SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Inline the auto_dismiss_prompts block by sourcing only the relevant region.
# We do this by extracting between the v5.7 §4.13.a banner and check_and_nudge_idle_pane().
TMP_LIB=$(mktemp -t auto-dismiss-test.XXXXXX)
sed -n '/^# --- v5.7 §4.13.a:/,/^check_and_nudge_idle_pane()/p' "$RUN_SCRIPT" \
  | sed '$d' > "$TMP_LIB"

# Mocks
log() { :; }
log_debug() { :; }
log_error() { :; }
write_blocked_sentinel() { :; }
declare -g _LAST_SENDKEYS=""
declare -g _CAPTURE_FIXTURE=""
tmux() {
  if [[ "$1" == "capture-pane" ]]; then
    print -- "$_CAPTURE_FIXTURE"
  elif [[ "$1" == "send-keys" ]]; then
    # Args: send-keys -t <pane_id> <key>  ->  $1 send-keys, $2 -t, $3 pane, $4 key
    _LAST_SENDKEYS="$4"
  fi
}

source "$TMP_LIB"

PASS=0
FAIL=0

assert_dismissed() {
  local label="$1"
  local fixture="$2"
  _LAST_SENDKEYS=""
  _CAPTURE_FIXTURE="$fixture"
  LAST_AUTO_APPROVE_TS=()  # reset debounce
  auto_dismiss_prompts "%test"
  if [[ "$_LAST_SENDKEYS" == "Enter" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (expected Enter, got '$_LAST_SENDKEYS')"
    (( FAIL++ ))
  fi
}

assert_not_dismissed() {
  local label="$1"
  local fixture="$2"
  _LAST_SENDKEYS=""
  _CAPTURE_FIXTURE="$fixture"
  LAST_AUTO_APPROVE_TS=()
  auto_dismiss_prompts "%test"
  if [[ -z "$_LAST_SENDKEYS" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (expected no send, got '$_LAST_SENDKEYS')"
    (( FAIL++ ))
  fi
}

# --- POSITIVE cases (Bug 4 repro) ---
assert_dismissed "prompt + affordance on same line" \
"some output
Do you want to create test.json? (y/n)
"

assert_dismissed "prompt with affordance on next line" \
"some output
Do you want to create test.json?
(y/n)
"

assert_dismissed "prompt with affordance on prev line (rare TUI layout)" \
"(y/n)
Do you want to create test.json?
"

assert_dismissed "Do you trust + numeric picker" \
"Do you trust this directory?
1) Yes
"

# --- NEGATIVE cases (R-V5-9 false-positive guard) ---
assert_not_dismissed "non-prompt text containing 'Do you want to'" \
"User: Do you want to learn more about Rust?
Tutor: Sure, here's the basics...
"

assert_not_dismissed "prompt without affordance marker (no (y/n) anywhere)" \
"Do you want to create test.json?
Just plain output text.
"

# v5.7 §4.23: line-adjacency strict design replaced with tail-15 normalized
# matching for real claude wrapped multi-line prompts. Closeness via tail-15
# is the new contract.
assert_dismissed "tail-15: prompt + affordance with gap → auto-dismiss" \
"Do you want to create test.json?
some unrelated output line
another unrelated line
(y/n)
"

assert_not_dismissed "empty capture" ""

# --- CODEX engine prompts (tmux mode + codex CLI) ---
# v5.7 _PROMPT_RE / _AFFORDANCE_RE must catch codex CLI variants too.
assert_dismissed "codex: 'Proceed?' with (y/n)" \
"Send this command to the model?
Proceed? (y/n)
"

assert_dismissed "codex: 'Approve this command?' with [Y/n] (default-Yes)" \
"Approve this command? [Y/n]
"

assert_dismissed "codex: numeric picker '1) Yes / 2) No'" \
"Choose an option:
1) Yes
2) No
"

assert_dismissed "codex: 'Allow this action?' with [Y/n]" \
"Allow this action? [Y/n]
"

assert_dismissed "codex: 'Press y to' affordance" \
"Continue?
press y to confirm
"

assert_dismissed "codex: 'Select [' picker" \
"Select [an option below]:
1) Yes
2) No
"

# --- v5.7 §4.20: claude v2.x trust prompt (E2E real-CLI finding) ---
assert_dismissed "claude v2.x trust prompt: narrow-pane wrap (❯1.Yes)" \
"Quick safety check: Is this a project you
created or one you trust?
❯1.Yes, I trust this folder
2. No, exit
Enter to confirm"

assert_dismissed "claude v2.x trust prompt: with-space (❯ 1.)" \
"Is this a project you trust?
❯ 1. Yes, I trust this folder
2. No, exit"

assert_dismissed "claude v2.x trust prompt: 'trust this folder' + Enter to confirm" \
"Will trust this folder
Enter to confirm"

# --- v5.7 §4.18: unknown-prompt fast-fail (omc benchmarking) ---
# bare affordance bracket without recognized PROMPT_RE phrasing → BLOCK fast.
# Don't make the operator wait 10min for the freeze timeout.
_BLOCKED_AFTER=""
custom_block_track_call() {
  _BLOCKED_AFTER="$1|$3"
}

assert_blocks_unknown() {
  local label="$1"
  local fixture="$2"
  _LAST_SENDKEYS=""
  _BLOCKED_AFTER=""
  _CAPTURE_FIXTURE="$fixture"
  LAST_AUTO_APPROVE_TS=()
  PANE_PROMPT_STUCK_SINCE=()
  # Override write_blocked_sentinel for this assertion
  function write_blocked_sentinel() { custom_block_track_call "$1" "$2" "$3"; }
  auto_dismiss_prompts "%test"
  function write_blocked_sentinel() { :; }  # restore
  if [[ -z "$_LAST_SENDKEYS" ]] && [[ -n "$_BLOCKED_AFTER" ]] && [[ "${_BLOCKED_AFTER##*|}" == "infra_failure" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (sendkeys='$_LAST_SENDKEYS' blocked='$_BLOCKED_AFTER')"
    (( FAIL++ ))
  fi
}

assert_no_block_active() {
  local label="$1"
  local fixture="$2"
  _LAST_SENDKEYS=""
  _BLOCKED_AFTER=""
  _CAPTURE_FIXTURE="$fixture"
  LAST_AUTO_APPROVE_TS=()
  PANE_PROMPT_STUCK_SINCE=()
  function write_blocked_sentinel() { custom_block_track_call "$1" "$2" "$3"; }
  auto_dismiss_prompts "%test"
  function write_blocked_sentinel() { :; }
  if [[ -z "$_LAST_SENDKEYS" ]] && [[ -z "$_BLOCKED_AFTER" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (sendkeys='$_LAST_SENDKEYS' blocked='$_BLOCKED_AFTER')"
    (( FAIL++ ))
  fi
}

assert_blocks_unknown "unknown-prompt: bare [y/N] no phrasing → BLOCK fast" \
"Some weird CLI banner
[y/N]
"

assert_blocks_unknown "unknown-prompt: bare (y/n) no phrasing → BLOCK fast" \
"Brand new CLI variant message
(y/n)
"

assert_no_block_active "active worker (esc to interrupt) suppresses unknown-prompt BLOCK" \
"Worker output mentioning (y/n) inside body
· Synthesizing...
esc to interrupt
"

# --- v5.7 §4.17.b: scrollback contamination guard ---
# Production scenario the real-tmux E2E uncovered: old [Y/n] in scrollback
# alongside an active [y/N] prompt. Old break-on-first-match would auto-Enter
# on the older one and CANCEL the active default-No prompt. Fix scans all
# matches and BLOCKs if ANY default-No is visible.
assert_not_dismissed "scrollback: mixed [Y/n] then [y/N] → must NOT auto-Enter" \
"Do you want to create file? [Y/n]
done
Do you want to overwrite passwd? [y/N]
"

assert_dismissed "scrollback: two default-Yes prompts → safe to auto-dismiss" \
"Do you want to create A? [Y/n]
done
Do you want to create B? (y/n)
"

# --- DEBOUNCE ---
_CAPTURE_FIXTURE="Do you want to create test.json? (y/n)
"
LAST_AUTO_APPROVE_TS=()
auto_dismiss_prompts "%dbnce"
_LAST_SENDKEYS=""
auto_dismiss_prompts "%dbnce"  # immediate re-call should debounce
if [[ -z "$_LAST_SENDKEYS" ]]; then
  print "PASS: 3s debounce suppresses second call within window"
  (( PASS++ ))
else
  print "FAIL: 3s debounce did not suppress second call"
  (( FAIL++ ))
fi

rm -f "$TMP_LIB"

print ""
print "=== Total: $PASS pass, $FAIL fail ==="
(( FAIL == 0 ))
