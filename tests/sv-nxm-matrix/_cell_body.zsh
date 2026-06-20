# ============================================================================
# _cell_body.zsh — ONE (WORKER_ENGINE, VERIFIER_ENGINE) matrix cell.
#
# This file is APPENDED to a freshly-regenerated main()-stripped copy of
# run_ralph_desk.zsh (see assemble-base.zsh) and run at toplevel, so every
# function under test (launch_worker_*, launch_verifier_*, create_session,
# build_claude_cmd, wait_for_pane_ready) is the REAL function in its REAL load
# context — NOT a reimplementation.
#
# Inputs (env, set by run-cell.zsh before assembly):
#   CELL_ID                e.g. C1
#   WORKER_ENGINE          codex|claude   (also consumed by the base at source time)
#   VERIFIER_ENGINE        codex|claude
#   WORKER_MODEL           claude model (haiku/sonnet/...) — ignored for codex worker
#   VERIFIER_MODEL         claude model — ignored for codex verifier
#   WORKER_CODEX_MODEL/_REASONING, VERIFIER_CODEX_MODEL/_REASONING (codex tuning)
#   EVID_DIR               fresh unique evidence dir (mktemp -d)
#   NONCE                  per-run random hex nonce
#   INTENDED_THROWAWAY     the session name we will demand
#   ROOT                   /tmp sandbox (git-init'd by run-cell.zsh)
#   READY_BUDGET, ANSWER_BUDGET, TIMING_FLOOR_S  (per-engine timing knobs)
#
# Emits to $EVID_DIR:
#   worker_capture.txt, verifier_capture.txt, ANSWER.txt (the worker artifact),
#   verdict.json, cell-result.json (the per-cell ledger entry).
# Exit: 0 if cell PASS, 1 if FAIL, 99 if BLOCKED(isolation) (from preamble).
# ============================================================================

# Quiet the leader's logging so cell output stays readable. The base defines
# log/log_error/log_debug from lib_ralph_desk.zsh; we override to stderr-lite.
log()       { print -u2 -- "    [leader] $*"; }
log_error() { print -u2 -- "    [leader:err] $*"; }
log_debug() { :; }

# ---- nonce transform: human-replayable string reverse (openQuestion resolved
# toward replayability so a reviewer can re-confirm WITHOUT recomputing a hash).
# NONCE is hex so reverse is unambiguous and never appears verbatim in the prompt.
sv_nonce_transform() { print -rn -- "${1}_SVOK"; }
EXPECT_TRANSFORM="$(sv_nonce_transform "$NONCE")"

print -P "%F{magenta}══ CELL $CELL_ID  W=$WORKER_ENGINE  V=$VERIFIER_ENGINE  nonce=$NONCE%f"

# Initialize a fail-closed cell ledger entry up front so any early exit still
# leaves a scoreable record on disk.
RESULT_JSON="$EVID_DIR/cell-result.json"
write_result() {
  # $1 outcome  $2 failing_rung  $3 elapsed_s
  jq -n \
    --arg cell "$CELL_ID" --arg w "$WORKER_ENGINE" --arg v "$VERIFIER_ENGINE" \
    --arg out "$1" --arg rung "${2:-}" --arg el "${3:-0}" \
    --arg ed "$EVID_DIR" --arg wa "$EVID_DIR/ANSWER.txt" --arg vv "$EVID_DIR/verdict.json" \
    --arg nonce "$NONCE" --arg xform "$EXPECT_TRANSFORM" \
    --arg cbv "${CODEX_VERSION:-}" --arg clv "${CLAUDE_VERSION:-}" \
    '{cell_id:$cell, worker_engine:$w, verifier_engine:$v, ran:true,
      outcome:$out, failing_rung:$rung, elapsed_s:($el|tonumber? // 0),
      evidence_dir:$ed, worker_artifact_path:$wa, verifier_verdict_path:$vv,
      nonce:$nonce, expected_transform:$xform,
      binary_versions:{codex:$cbv, claude:$clv}}' > "$RESULT_JSON"
}
write_result "INCOMPLETE" "startup" 0

# ---------------------------------------------------------------------------
# Binary presence + version capture (anti-gaming: missing required bin ⇒ BLOCKED,
# never PASS — build_claude_cmd emits an EMPTY-binary cmd if CLAUDE_BIN unset).
need_codex=0; need_claude=0
[[ "$WORKER_ENGINE" == codex || "$VERIFIER_ENGINE" == codex ]] && need_codex=1
[[ "$WORKER_ENGINE" == claude || "$VERIFIER_ENGINE" == claude ]] && need_claude=1

CODEX_VERSION=""; CLAUDE_VERSION=""
if (( need_codex )); then
  CODEX_BIN=$(command -v codex 2>/dev/null || true)
  if [[ -z "$CODEX_BIN" || ! -x "$CODEX_BIN" ]]; then
    svno "binary: codex required but absent → BLOCKED"; write_result "BLOCKED" "binary:codex" 0; exit 1
  fi
  CODEX_VERSION="$("$CODEX_BIN" --version 2>/dev/null | head -1)"
  svinfo "codex: $CODEX_BIN ($CODEX_VERSION)"
fi
if (( need_claude )); then
  CLAUDE_BIN=$(command -v claude 2>/dev/null || true)
  if [[ -z "$CLAUDE_BIN" || ! -x "$CLAUDE_BIN" ]]; then
    svno "binary: claude required but absent → BLOCKED"; write_result "BLOCKED" "binary:claude" 0; exit 1
  fi
  CLAUDE_VERSION="$("$CLAUDE_BIN" --version 2>/dev/null | head -1)"
  svinfo "claude: $CLAUDE_BIN ($CLAUDE_VERSION)"
fi

# ---------------------------------------------------------------------------
# ISOLATION (INV-1): capture caller, unset TMUX.
sv_capture_caller
# The base UNCONDITIONALLY sets SESSION_NAME=rlp-desk-<slug>-<ts> at line 294,
# so our run-cell pre-seed was clobbered. Re-pin it to INTENDED_THROWAWAY NOW,
# after the base loaded and BEFORE create_session, so the isolated new-session
# branch (TMUX unset) builds OUR throwaway name (and sv_assert_isolated passes).
# INTENDED_THROWAWAY shares the rlp-desk-<slug>- prefix so check_existing_sessions
# and the INV-8 sweep still scope it correctly.
SESSION_NAME="$INTENDED_THROWAWAY"
mkdir -p "$MEMOS_DIR" "$LOGS_DIR" "$RUNTIME_DIR" 2>/dev/null

print "  ▶ create_session (isolated new-session branch)…"
create_session >/dev/null 2>&1

# ISOLATION (INV-2): loud abort if create_session rebound to caller. exit 99.
sv_assert_isolated
# ISOLATION (INV-3): now that SESSION_NAME is verified-ours, arm the teardown trap
# at TOP-LEVEL scope (NOT inside a function — a zsh `trap ... EXIT` set in a
# function fires on FUNCTION return and would kill the session immediately).
MYSESS="$SESSION_NAME"
trap sv_teardown EXIT INT TERM

[[ -n "$WORKER_PANE" && -n "$VERIFIER_PANE" ]] \
  && svok "panes created (worker=$WORKER_PANE verifier=$VERIFIER_PANE)" \
  || { svno "panes missing"; write_result "FAIL" "L1:panes" 0; exit 1; }

# ---------------------------------------------------------------------------
# Build the WORKER prompt: a TRIVIAL DETERMINISTIC task that is echo-PROOF AND
# reliable for weak models. The worker must (a) append the fixed suffix _SVOK to
# the NONCE and (b) write the combined string to ANSWER.txt, then (c) print the
# token SELFVERIFY_OK. The combined "<nonce>_SVOK" is NOT present verbatim in the
# prompt (only NONCE + the instruction are), so a TUI echo / whole-prompt copy
# cannot satisfy the EXACT-match artifact check. F-15: replaced character-reversal
# (which weak models like haiku flub by one char → spurious L4 FAILs, not real
# defects) with copy+append, which any LLM does reliably.
WPROMPT="$ROOT/worker_prompt.md"
cat > "$WPROMPT" <<EOF
You are running a self-verification probe. Do EXACTLY this and nothing else:

1. Take this nonce string: $NONCE
2. Append the exact 5-character suffix _SVOK to it (so it becomes the nonce
   immediately followed by _SVOK, with no space between them).
3. Write ONLY that combined string (no newline, no extra text) to the file
   ANSWER.txt in the current working directory ($ROOT).
4. After the file is written, print the single token SELFVERIFY_OK and stop.

Do not modify any other files. Do not run unrelated commands.
EOF

# Build launch commands using the REAL builders / the exact production cmd shapes.
if [[ "$WORKER_ENGINE" == codex ]]; then
  worker_launch="${CODEX_BIN} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" --disable plugins --dangerously-bypass-approvals-and-sandbox"
else
  # build_claude_cmd is the REAL production builder (mode=tui). Emits an EMPTY
  # command if CLAUDE_BIN unset — we already hard-asserted it is present.
  worker_launch="$(build_claude_cmd tui "$WORKER_MODEL" "" "" "${WORKER_EFFORT:-}")"
fi
svinfo "worker launch: $worker_launch"

# ---------------------------------------------------------------------------
# L1: drive the REAL launch_worker_<engine>.
print "  ▶ launch_worker_$WORKER_ENGINE (ready+submit)…"
typeset -i wt0=$SECONDS
if [[ "$WORKER_ENGINE" == codex ]]; then
  launch_worker_codex "$WORKER_PANE" "$WPROMPT" 1 "$worker_launch"; wrc=$?
else
  launch_worker_claude "$WORKER_PANE" "$WPROMPT" 1 "$worker_launch"; wrc=$?
fi
typeset -i w_launch_s=$(( SECONDS - wt0 ))
[[ $wrc -eq 0 ]] && svok "L1 launch_worker_$WORKER_ENGINE rc=0 (${w_launch_s}s)" \
                 || { svno "L1 launch_worker_$WORKER_ENGINE FATAL rc=$wrc"; write_result "FAIL" "L1:launch_worker" "$w_launch_s"; exit 1; }

# L2: engine ready glyph in a REAL capture.
sleep 2
wcap=$(tmux capture-pane -t "$WORKER_PANE" -p -S -400 2>/dev/null)
print -r -- "$wcap" > "$EVID_DIR/worker_capture.txt"
if [[ "$WORKER_ENGINE" == codex ]]; then
  ready_re='›'
else
  ready_re='❯|>|›|»'
fi
if print -r -- "$wcap" | grep -qE "$ready_re" 2>/dev/null; then
  svok "L2 worker ready glyph present"
else
  svno "L2 worker ready glyph ABSENT (engine=$WORKER_ENGINE)"; write_result "FAIL" "L2:worker_ready" "$w_launch_s"; exit 1
fi

# L3: engine TELEMETRY activity marker (model-produced, not generic prompt words).
if [[ "$WORKER_ENGINE" == codex ]]; then
  act_re='tokens used|Worked for|esc to interrupt|Esc to interrupt|•|Exploring|Running'
else
  act_re='esc to interrupt|tokens|Thinking|Working|Bash|Edit|Write|Read|Grep'
fi
if print -r -- "$wcap" | grep -qiE "$act_re" 2>/dev/null; then
  svok "L3 worker telemetry activity marker present"
else
  svinfo "L3 no activity marker yet in first capture (will re-check during answer poll)"
fi

# L4: worker nonce round-trip — poll for SELFVERIFY_OK AND the real artifact.
print "  ▶ waiting ≤${ANSWER_BUDGET}s for worker artifact (nonce round-trip)…"
typeset -i at0=$SECONDS
ans=0; artifact_ok=0; l3_late=0
ANSWER_FILE="$ROOT/ANSWER.txt"
for i in $(seq 1 $(( ANSWER_BUDGET / 2 ))); do
  c=$(tmux capture-pane -t "$WORKER_PANE" -p -S -500 2>/dev/null)
  # late L3 re-check
  if (( ! l3_late )) && print -r -- "$c" | grep -qiE "$act_re" 2>/dev/null; then l3_late=1; fi
  if [[ -f "$ANSWER_FILE" ]]; then
    got="$(tr -d '\n' < "$ANSWER_FILE" 2>/dev/null)"
    if [[ "$got" == "$EXPECT_TRANSFORM" ]]; then artifact_ok=1; fi
  fi
  if print -r -- "$c" | grep -q 'SELFVERIFY_OK' 2>/dev/null; then ans=1; fi
  if (( artifact_ok )); then
    print -r -- "$c" > "$EVID_DIR/worker_final.txt"; break
  fi
  sleep 2
done
typeset -i answer_s=$(( SECONDS - at0 ))
[[ -f "$ANSWER_FILE" ]] && cp "$ANSWER_FILE" "$EVID_DIR/ANSWER.txt" 2>/dev/null

(( l3_late )) && svok "L3 (late) worker activity telemetry observed during round-trip"

# Timing plausibility floor — sub-floor "answers" are stub-suspect.
typeset -i total_worker_s=$(( w_launch_s + answer_s ))
if (( artifact_ok )); then
  if (( total_worker_s < TIMING_FLOOR_S )); then
    svno "L4 artifact matched but TOO FAST (${total_worker_s}s < floor ${TIMING_FLOOR_S}s) — stub-suspect"
    write_result "FAIL" "L4:timing_floor" "$total_worker_s"; exit 1
  fi
  svok "L4 worker nonce round-trip OK: ANSWER.txt == reverse(nonce) (${total_worker_s}s, token=$ans)"
else
  svno "L4 worker artifact missing or != reverse(nonce) (got='${got:-<none>}' expect='$EXPECT_TRANSFORM')"
  write_result "FAIL" "L4:nonce_roundtrip" "$total_worker_s"; exit 1
fi

# Echo-proof: assert the expected transform is NOT verbatim in the prompt.
if grep -qF "$EXPECT_TRANSFORM" "$WPROMPT" 2>/dev/null; then
  svno "anti-gaming: reversed nonce leaked into prompt — invalid probe"; write_result "FAIL" "anti_gaming:leak" "$total_worker_s"; exit 1
fi

# git author of the artifact == worker (best-effort; sandbox is git-init'd).
( cd "$ROOT" && git add ANSWER.txt 2>/dev/null && git -c user.email=worker@sv -c user.name=worker commit -q -m "worker artifact" 2>/dev/null ) || true

# ---------------------------------------------------------------------------
# VERIFIER half — build prompt that REQUIRES reading the worker's real artifact.
VPROMPT="$ROOT/verifier_prompt.md"
VERDICT_OUT="$ROOT/verdict.json"
rm -f "$VERDICT_OUT"
cat > "$VPROMPT" <<EOF
You are a verifier. Do EXACTLY this:

1. Read the file ANSWER.txt in the current working directory ($ROOT).
2. Write a JSON verdict to the file verdict.json in $ROOT with this exact shape:
   {
     "status": "pass" or "fail",
     "criteria_results": [
       { "id": "C1", "status": "pass" or "fail",
         "evidence": "<paste the EXACT content you read from ANSWER.txt here>" }
     ],
     "summary": "<one short sentence>"
   }
3. Set status/C1.status to "pass" only if ANSWER.txt exists and is non-empty.
4. After writing verdict.json, print the single token VERIFY_DONE and stop.

Do not modify ANSWER.txt. Do not run unrelated commands.
EOF

if [[ "$VERIFIER_ENGINE" == codex ]]; then
  verifier_launch="${CODEX_BIN} -m $VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" --disable plugins --dangerously-bypass-approvals-and-sandbox"
else
  verifier_launch="$(build_claude_cmd tui "$VERIFIER_MODEL" "" "" "${VERIFIER_EFFORT:-}")"
fi
svinfo "verifier launch: $verifier_launch"

print "  ▶ launch_verifier_$VERIFIER_ENGINE…"
typeset -i vt0=$SECONDS
if [[ "$VERIFIER_ENGINE" == codex ]]; then
  launch_verifier_codex "$VERIFIER_PANE" "$VPROMPT" 1 "$verifier_launch"; vrc=$?
else
  launch_verifier_claude "$VERIFIER_PANE" "$VPROMPT" 1 "$verifier_launch"; vrc=$?
fi
typeset -i v_launch_s=$(( SECONDS - vt0 ))
[[ $vrc -eq 0 ]] && svok "L1(verifier) launch_verifier_$VERIFIER_ENGINE rc=0 (${v_launch_s}s)" \
                 || { svno "L1(verifier) FATAL rc=$vrc"; write_result "FAIL" "L1:launch_verifier" "$total_worker_s"; exit 1; }

sleep 2
vcap=$(tmux capture-pane -t "$VERIFIER_PANE" -p -S -400 2>/dev/null)
print -r -- "$vcap" > "$EVID_DIR/verifier_capture.txt"

# L5: schema-valid verdict.json that cites the worker's real nonce transform.
print "  ▶ waiting ≤${ANSWER_BUDGET}s for verifier verdict.json…"
verdict_ok=0
for i in $(seq 1 $(( ANSWER_BUDGET / 2 ))); do
  if [[ -f "$VERDICT_OUT" ]] && jq -e . "$VERDICT_OUT" >/dev/null 2>&1; then
    cp "$VERDICT_OUT" "$EVID_DIR/verdict.json"
    # schema: status in {pass,fail}, criteria_results len>=1, summary present
    if jq -e '
        (.status|type=="string") and (.status=="pass" or .status=="fail")
        and (.criteria_results|type=="array") and (.criteria_results|length>=1)
        and (.summary|type=="string")
      ' "$VERDICT_OUT" >/dev/null 2>&1; then
      # echo-proof: at least one criterion evidence must contain the reversed nonce.
      if jq -e --arg x "$EXPECT_TRANSFORM" \
           '[.criteria_results[].evidence] | any(. != null and (tostring|contains($x)))' \
           "$VERDICT_OUT" >/dev/null 2>&1; then
        verdict_ok=1; break
      fi
    fi
  fi
  sleep 2
done
typeset -i verifier_s=$(( SECONDS - vt0 ))

if (( verdict_ok )); then
  if (( verifier_s < TIMING_FLOOR_S )); then
    svno "L5 verdict valid but TOO FAST (${verifier_s}s) — stub-suspect"; write_result "FAIL" "L5:timing_floor" "$verifier_s"; exit 1
  fi
  svok "L5 verifier verdict.json schema-valid AND cites worker's reversed-nonce (${verifier_s}s)"
else
  svno "L5 verifier verdict missing/invalid or did not cite the worker artifact"
  write_result "FAIL" "L5:verdict" "$verifier_s"; exit 1
fi

# ---------------------------------------------------------------------------
typeset -i cell_total=$(( total_worker_s + verifier_s ))
print -P "  %F{magenta}── cell $CELL_ID ladder complete in ${cell_total}s%f"
if (( SV_FAIL == 0 )); then
  write_result "PASS" "" "$cell_total"
  print -P "  %F{green}▶ CELL $CELL_ID PASS ($SV_PASS rungs)%f"
  exit 0
else
  write_result "FAIL" "ladder" "$cell_total"
  print -P "  %F{red}▶ CELL $CELL_ID FAIL ($SV_FAIL failing)%f"
  exit 1
fi
