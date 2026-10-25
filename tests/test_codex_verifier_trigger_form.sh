#!/bin/zsh
# Backlog item 8 — the codex verifier/worker TRIGGER SCRIPT must launch codex
# non-interactively (`codex exec`).
#
# Evidence (codex-cli 0.163.0, isolated tmux server, 2026-10-25): the generated
# verifier trigger runs `codex -m M ... "<prompt>" > >(tee LOG) 2>&1`. A bare
# positional prompt selects the interactive TUI, and the TUI refuses a
# non-terminal stdout: it printed "Error: stdout is not a terminal" and exited in
# ~1 s with no verdict (the trigger itself still exited 0, masking it). The
# worker form (no tee) starts the TUI but never exits. `codex exec` runs to
# completion, exits, and works under the same `> >(tee LOG) 2>&1`.
#
# This test uses NO real codex: a stub records argv and mimics the one observed
# behaviour that matters (non-`exec` invocation with stdout not a tty -> refuse).
#
#   (a) generated verifier trigger invokes `<codex> exec ...`
#   (b) running it under bash with the stub: the stub was NOT refused, and the
#       tee'd output log holds the stub's success line, not the refusal
#   (c) MCP parity: `-c mcp_servers='{}'` present (every TUI launch site has it)
#   (d) existing flags survive: model, reasoning effort, plugins off, bypass flag,
#       tee to the verifier output log
#   (e) worker trigger codex branch (source structure): `exec` + MCP parity
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$LIB" && -f "$RUN" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# --- stub codex: records argv; mimics "TUI (no subcommand) needs a tty stdout" ---
STUB="$TMP/codex-stub"
cat > "$STUB" <<'STUB_EOF'
#!/bin/bash
printf '%s\n' "$@" > "$STUB_ARGV_FILE"
sub=""
prev=""
for a in "$@"; do
  # first token that is not an option and not the value of -m / -c / --disable
  case "$prev" in -m|-c|--disable|-p|-s|-C) prev=""; continue;; esac
  case "$a" in -*) prev="$a"; continue;; esac
  sub="$a"; break
done
if [[ "$sub" != "exec" && ! -t 1 ]]; then
  echo "Error: stdout is not a terminal"
  exit 1
fi
echo "stub-codex-ok sub=${sub}"
exit 0
STUB_EOF
chmod +x "$STUB"

# --- generate the REAL verifier trigger (same extraction pattern as
#     test_confirmation_preexisting_dirty.sh) ---
EX="$TMP/wvt.zsh"
awk '/^write_verifier_trigger\(\)/,/^}$/' "$RUN" > "$EX"
grep -q 'write_verifier_trigger' "$EX" || { no "could not extract write_verifier_trigger"; print "PASS=$PASS FAIL=$FAIL"; exit 1; }
base="$TMP/base.md"; print -r -- "reply with the single word OK" > "$base"
sig="$TMP/signal.json"; print -r -- '{"us_id":"US-001"}' > "$sig"
LOGS="$TMP/logs"; mkdir -p "$LOGS"
zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  derive_verification_mode(){ print -r -- "build|stub"; }
  build_claude_cmd(){ print -r -- "claude --print"; }
  _emit_evidence_lock_contract(){ :; }
  VERIFIER_ENGINE=codex; VERIFIER_MODEL=sonnet; VERIFIER_EFFORT=""
  VERIFIER_CODEX_MODEL=gpt-6-luna; VERIFIER_CODEX_REASONING=low; CODEX_BIN="'"$STUB"'"
  _CODEX_NO_UPDATE_FLAG=" -c check_for_update_on_startup=false"
  VERIFY_MODE=per-us; AUTONOMOUS_MODE=0
  VERIFIED_LEDGER="'"$TMP"'/ledger.jsonl"; PRD_FILE="'"$TMP"'/prd.md"; ROOT="'"$TMP"'"
  VERIFIER_PROMPT_BASE="'"$base"'"; SIGNAL_FILE="'"$sig"'"
  DONE_CLAIM_FILE="'"$TMP"'/done.json"; VERIFIER_HEARTBEAT="'"$TMP"'/hb.json"
  ITER_WINDOW_START=x; OMX_STATE_DIR="'"$TMP"'/omx"; LOGS_DIR="'"$LOGS"'"
  source "'"$EX"'"
  write_verifier_trigger 1 codex gpt-6-luna -codex
' >/dev/null 2>&1
TRIG="$LOGS/iter-001.verifier-codex-trigger.sh"
OUTLOG="$LOGS/iter-001.verifier-codex-output.log"
[[ -f "$TRIG" ]] || { no "trigger script was not generated"; print "PASS=$PASS FAIL=$FAIL"; exit 1; }

# (a) command form: the codex invocation is the `exec` subcommand
if grep -Eq "^OMX_STATE_ROOT=.* ${STUB:gs/./\\.} exec( |$)" "$TRIG"; then
  ok "(a) verifier trigger invokes 'codex exec' (non-interactive)"
else
  no "(a) verifier trigger does not use 'codex exec' — a bare positional prompt starts the TUI: $(grep -E 'codex-stub' "$TRIG" | head -1)"
fi

# (b) behaviour under bash (manual replay: the leader never executes the trigger; governance.md s7)
: > "$TMP/argv.txt"
STUB_ARGV_FILE="$TMP/argv.txt" bash "$TRIG" >/dev/null 2>&1
sleep 0.3   # > >(tee) is asynchronous; let it flush the log
if grep -q '^stub-codex-ok sub=exec$' "$OUTLOG" 2>/dev/null; then
  ok "(b) trigger run: codex stub accepted the launch and the output log holds its result"
else
  no "(b) trigger run: output log is [$(tr '\n' '|' < "$OUTLOG" 2>/dev/null)] — expected 'stub-codex-ok sub=exec' (stub refuses a non-exec launch with piped stdout, as real codex 0.163.0 does)"
fi

# (c) MCP parity with the TUI launch sites
tui_sites=$(grep -c "\-c mcp_servers='{}'" "$RUN")
(( tui_sites >= 5 )) || no "(c) precondition: expected >=5 TUI launch sites with mcp_servers override in $RUN, found $tui_sites"
if grep -qF -- "-c mcp_servers='{}'" "$TRIG"; then
  ok "(c) verifier trigger carries -c mcp_servers='{}' (parity with $tui_sites TUI sites)"
else
  no "(c) verifier trigger lacks -c mcp_servers='{}' — a user MCP server in ~/.codex/config.toml would load in the verifier"
fi

# (d) existing flags survive the form change
for needle in "-m gpt-6-luna" 'model_reasoning_effort="low"' "--disable plugins" "--dangerously-bypass-approvals-and-sandbox" "check_for_update_on_startup=false" "tee $OUTLOG"; do
  grep -qF -- "$needle" "$TRIG" && ok "(d) trigger keeps: $needle" || no "(d) trigger lost: $needle"
done

# (e) worker trigger codex branch (structural; write_worker_trigger has too many deps to run here)
WEX="$TMP/wwt.zsh"
awk '/^write_worker_trigger\(\)/,/^}$/' "$RUN" > "$WEX"
wcmd=$(grep -A4 'CODEX_BIN:-codex}' "$WEX" | head -6)
if print -r -- "$wcmd" | head -1 | grep -Eq '\$\{CODEX_BIN:-codex\} exec( |\\)'; then
  ok "(e1) worker trigger invokes 'codex exec' (a bare-prompt TUI never exits, so the heartbeat cleanup never runs)"
else
  no "(e1) worker trigger does not use 'codex exec': $(print -r -- "$wcmd" | head -1)"
fi
if print -r -- "$wcmd" | grep -qF -- "-c mcp_servers='{}'"; then
  ok "(e2) worker trigger carries -c mcp_servers='{}'"
else
  no "(e2) worker trigger lacks -c mcp_servers='{}'"
fi

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
