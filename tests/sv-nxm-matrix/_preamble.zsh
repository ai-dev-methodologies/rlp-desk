# ============================================================================
# _preamble.zsh — HARNESS-ENFORCED isolation contract (INV-1..INV-6, INV-8).
#
# Sourced by every cell body AFTER the main()-stripped base is loaded and
# BEFORE create_session is ever called. Implements the isolation invariants so
# the caller's (operator's) tmux session can NEVER be touched, regardless of an
# author mistake.
#
# Provides:
#   sv_capture_caller     — INV-1: record CALLER_SESSION/CALLER_PANE, then unset TMUX
#   sv_assert_isolated    — INV-2: post-create loud-abort isolation assert (exit 99)
#   safe_kill_session     — INV-4: refuse caller / glob / kill-server
#   safe_kill_pane        — INV-4: refuse caller pane
#   sv_teardown           — INV-3: teardown handler (kills ONLY the local throwaway);
#                           the cell body installs it at TOP-LEVEL via trap (zsh: an
#                           EXIT trap set inside a function fires on function return)
#   svok / svno           — pass/fail counters
#
# Requires the cell to have set INTENDED_THROWAWAY (the session name it will ask
# create_session to build) BEFORE calling sv_capture_caller.
# ============================================================================

SV_PASS=0; SV_FAIL=0
svok(){ SV_PASS=$((SV_PASS+1)); print -P "    %F{green}PASS%f $1"; }
svno(){ SV_FAIL=$((SV_FAIL+1)); print -P "    %F{red}FAIL%f $1"; }
svinfo(){ print -P "    %F{cyan}··%f $1"; }

# INV-1: capture caller identity FIRST, then force the isolated new-session branch.
# create_session() (run_ralph_desk.zsh:861) rebinds the global SESSION_NAME to the
# CALLER's session when $TMUX is set — unsetting TMUX forces the `tmux new-session
# -d` branch (878) so SESSION_NAME stays our throwaway.
sv_capture_caller() {
  CALLER_TMUX="${TMUX:-}"
  if [[ -n "$CALLER_TMUX" ]]; then
    CALLER_SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "__none__")
    CALLER_PANE=$(tmux display-message -p '#{pane_id}' 2>/dev/null || echo "__none__")
  else
    CALLER_SESSION="__none__"
    CALLER_PANE="__none__"
  fi
  svinfo "caller session=$CALLER_SESSION pane=$CALLER_PANE (will be protected)"
  # INV-5 analogue for standalone bodies: strip TMUX so create_session can't rebind.
  unset TMUX
  unset TMUX_PANE 2>/dev/null || true
}

# INV-2: the single control that defeats the whole main-session-destruction bug
# class. Run IMMEDIATELY after create_session, BEFORE any kill/split/teardown.
sv_assert_isolated() {
  local ok=1
  if [[ -z "${SESSION_NAME:-}" ]]; then
    print -P "  %F{red}ISOLATION ASSERT FAILED%f: SESSION_NAME empty"; ok=0
  fi
  if [[ "${SESSION_NAME:-}" == "$CALLER_SESSION" ]]; then
    print -P "  %F{red}ISOLATION ASSERT FAILED%f: SESSION_NAME==CALLER_SESSION ($SESSION_NAME) — create_session rebound to caller"; ok=0
  fi
  if [[ -n "${INTENDED_THROWAWAY:-}" && "${SESSION_NAME:-}" != "$INTENDED_THROWAWAY" ]]; then
    print -P "  %F{red}ISOLATION ASSERT FAILED%f: SESSION_NAME ($SESSION_NAME) != INTENDED_THROWAWAY ($INTENDED_THROWAWAY)"; ok=0
  fi
  if [[ -n "${WORKER_PANE:-}" && "$WORKER_PANE" == "$CALLER_PANE" ]]; then
    print -P "  %F{red}ISOLATION ASSERT FAILED%f: WORKER_PANE==CALLER_PANE"; ok=0
  fi
  if [[ -n "${VERIFIER_PANE:-}" && "$VERIFIER_PANE" == "$CALLER_PANE" ]]; then
    print -P "  %F{red}ISOLATION ASSERT FAILED%f: VERIFIER_PANE==CALLER_PANE"; ok=0
  fi
  if (( ! ok )); then
    print -P "  %F{red}→ aborting cell as BLOCKED(isolation); caller session untouched%f"
    # Do NOT kill anything here — we don't trust SESSION_NAME's binding.
    exit 99
  fi
  svok "isolation OK — throwaway session '$SESSION_NAME' distinct from caller"
}

# INV-4: safe kill wrappers — refuse caller targets, globs, kill-server.
safe_kill_session() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  [[ "$target" == "$CALLER_SESSION" ]] && { print -u2 "safe_kill_session: REFUSED caller session $target"; return 1; }
  [[ "$target" == *'*'* || "$target" == *'?'* ]] && { print -u2 "safe_kill_session: REFUSED glob $target"; return 1; }
  tmux kill-session -t "$target" 2>/dev/null || true
}
safe_kill_pane() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  [[ "$target" == "$CALLER_PANE" ]] && { print -u2 "safe_kill_pane: REFUSED caller pane $target"; return 1; }
  tmux kill-pane -t "$target" 2>/dev/null || true
}

# INV-3: mandatory teardown covering EXIT INT TERM. Kills ONLY the throwaway in
# $MYSESS — never the mutable global SESSION_NAME, never a glob, never kill-server.
# Idempotent + refuses the caller session.
#
# IMPORTANT zsh gotcha: a `trap ... EXIT` installed INSIDE a function fires when
# that FUNCTION returns (function-scoped, unlike bash's shell-scoped EXIT). So we
# do NOT install the trap from a helper function — sv_teardown() is the handler,
# and the cell body installs the trap at TOP-LEVEL scope via:
#     MYSESS="$SESSION_NAME"; trap sv_teardown EXIT INT TERM
sv_teardown() {
  if [[ -n "${MYSESS:-}" && "$MYSESS" != "${CALLER_SESSION:-__none__}" ]]; then
    tmux kill-session -t "$MYSESS" 2>/dev/null || true
  fi
}
