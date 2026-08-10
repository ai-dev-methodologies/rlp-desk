# ============================================================================
# LIVE codex-TUI E2E — exercises the REAL launch_worker_codex against a REAL
# codex 0.140.0 process in a REAL tmux pane. Confirms the two assumptions that
# most plausibly break "codex never finishes": (a) the '›' ready-prompt grep,
# (b) the working-keyword submit detection. Sends one harmless instruction.
# ============================================================================
SV_PASS=0; SV_FAIL=0
svok(){ SV_PASS=$((SV_PASS+1)); print -P "  %F{green}PASS%f $1"; }
svno(){ SV_FAIL=$((SV_FAIL+1)); print -P "  %F{red}FAIL%f $1"; }

CODEX_BIN=$(command -v codex)
mkdir -p "$MEMOS_DIR" "$LOGS_DIR" "$RUNTIME_DIR" 2>/dev/null
# codex runs in ROOT; make it a clean git repo so codex is happy + sandboxed
( cd "$ROOT" && git init -q 2>/dev/null; git config user.email sv@test >/dev/null 2>&1; git config user.name sv >/dev/null 2>&1 )

WORKER_ENGINE=codex
WORKER_CODEX_MODEL=gpt-5.5
WORKER_CODEX_REASONING=low

# A-FIX (main-session safety): force create_session() into its ISOLATED
# new-session path. With $TMUX set, create_session() rebinds SESSION_NAME to the
# CALLER's session and splits into it — the kill-session teardown below would then
# destroy the user's main session (the Claude Code pane included). Unsetting TMUX
# keeps SESSION_NAME our own throwaway session so teardown only ever kills that.
unset TMUX

print "▶ creating ISOLATED tmux session + worker pane (new-session path)…"
create_session >/dev/null 2>&1
print "  session=$SESSION_NAME"
[[ -n "$WORKER_PANE" ]] && svok "session/worker pane created" || { svno "no worker pane — abort"; exit 1; }

PF="$ROOT/sv_prompt.md"
print "Respond in the chat with exactly the single token SELFVERIFY_OK and then stop. Do NOT modify, create, or delete any files, and do NOT run any shell commands." > "$PF"

worker_launch="${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" --disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox"
print "  launch cmd: $worker_launch"

print "▶ calling REAL launch_worker_codex (30s ready budget + 15-round submit)…"
typeset -i t0=$SECONDS
launch_worker_codex "$WORKER_PANE" "$PF" 1 "$worker_launch"
lrc=$?
typeset -i elapsed=$(( SECONDS - t0 ))
print "  launch_worker_codex returned rc=$lrc after ${elapsed}s"
[[ $lrc -eq 0 ]] && svok "L1 launch_worker_codex completed without fatal (rc=0)" || svno "L1 launch_worker_codex FATAL rc=$lrc (ready/submit failed)"

# Snapshot the pane and re-apply rlp-desk's exact detection predicates
sleep 2
cap=$(tmux capture-pane -t "$WORKER_PANE" -p -S -300 2>/dev/null)
print -r -- "$cap" > /tmp/sv_codex_live_capture.txt
print "  (full pane capture → /tmp/sv_codex_live_capture.txt)"

if print -r -- "$cap" | grep -q '›' 2>/dev/null; then
  svok "L2 codex TUI '›' ready-prompt present (launch_worker_codex line 392 holds)"
else
  svno "L2 '›' prompt ABSENT — rlp-desk ready-detect mis-fires on codex 0.140.0"
fi

if print -r -- "$cap" | grep -qiE "working|thinking|Exploring|Running|reading|searching|editing|writing|esc to interrupt|Esc to interrupt|tokens used|Worked for|•" 2>/dev/null; then
  svok "L3 codex working/activity markers present (submit-detect can observe progress)"
else
  svno "L3 no working markers — submit loop would spin 15x then proceed blind"
fi

print "▶ waiting up to 90s for the end-to-end answer token…"
ans=0
for i in {1..45}; do
  c=$(tmux capture-pane -t "$WORKER_PANE" -p -S -400 2>/dev/null)
  if print -r -- "$c" | grep -q 'SELFVERIFY_OK' 2>/dev/null; then
    ans=1; print -r -- "$c" > /tmp/sv_codex_live_final.txt; break
  fi
  sleep 2
done
[[ $ans -eq 1 ]] && svok "L4 codex reached the expected answer (full worker round trip OK)" || svno "L4 no answer token within 90s (codex round trip stalled)"

# graceful teardown — SESSION_NAME is our own isolated session (TMUX unset above),
# so kill-session here can never reach the caller's main session.
tmux send-keys -t "$WORKER_PANE" C-c 2>/dev/null; sleep 0.3
tmux send-keys -t "$WORKER_PANE" "/quit" C-m 2>/dev/null; sleep 0.3
tmux kill-session -t "$SESSION_NAME" 2>/dev/null

print ""
print -P "%F{magenta}─────────────────────────────────────────────%f"
if (( SV_FAIL == 0 )); then
  print -P "%F{green}▶ LIVE codex worker E2E: $SV_PASS/$((SV_PASS+SV_FAIL)) PASS%f"
else
  print -P "%F{red}▶ LIVE codex worker E2E: $SV_PASS pass, $SV_FAIL FAIL%f"
fi
