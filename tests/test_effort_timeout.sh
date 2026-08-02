#!/usr/bin/env bash
# Test suite: effort-aware ITER_TIMEOUT multiplier (luna-first spec §6)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# T1: helper exists in lib
grep -qF '_effective_iter_timeout()' "$LIB" \
  && pass "T1: _effective_iter_timeout() exists in lib" \
  || fail "T1: _effective_iter_timeout() missing"

# T2: max multiplier is x2
grep -q 'ITER_TIMEOUT \* 2' "$LIB" \
  && pass "T2: :max multiplier x2 present" || fail "T2: :max multiplier missing"

# T3: xhigh multiplier is x1.5 (integer math 3/2)
grep -q 'ITER_TIMEOUT \* 3 / 2' "$LIB" \
  && pass "T3: :xhigh multiplier x1.5 present" || fail "T3: :xhigh multiplier missing"

# T4: non-worker role passes base through
awk '/_effective_iter_timeout\(\)/,/^}/' "$LIB" | grep -q 'worker' \
  && pass "T4: helper is role-aware (worker-only scaling)" \
  || fail "T4: helper not role-aware"

# T5: the poll loop consumes the helper (not raw ITER_TIMEOUT) for its budget check
grep -q '_effective_iter_timeout' "$RUN" \
  && pass "T5: run_ralph_desk.zsh consumes _effective_iter_timeout" \
  || fail "T5: poll loop still uses raw ITER_TIMEOUT only"

# T6: functional — helper computes 1200/900/600 from a 600 base, driven with the
# PRODUCTION role strings. run_ralph_desk.zsh:5501 passes "Worker" (capitalized —
# the role doubles as a log label) and the verifier polls pass "Verifier-final" /
# "Verifier<suffix>". A lowercase-only probe passes against a case-SENSITIVE
# compare that is dead on every real callsite, so "Worker" is the load-bearing
# case here; the lowercase call stays pinned alongside it.
_fn_out=$(zsh -fc '
  ITER_TIMEOUT=600
  get_model_string() { if [[ "$1" == codex ]]; then echo "$2:$3"; else echo "$2"; fi }
  source <(awk "/_effective_iter_timeout\(\)/,/^}/" '"$LIB"')
  WORKER_ENGINE=codex WORKER_CODEX_MODEL=gpt-5.6-luna WORKER_CODEX_REASONING=max WORKER_MODEL=gpt-5.6-luna
  echo -n "$(_effective_iter_timeout Worker),"
  WORKER_CODEX_REASONING=xhigh
  echo -n "$(_effective_iter_timeout Worker),"
  WORKER_CODEX_REASONING=high
  echo -n "$(_effective_iter_timeout Worker),"
  WORKER_CODEX_REASONING=max
  echo -n "$(_effective_iter_timeout worker),"
  echo -n "$(_effective_iter_timeout Verifier-final)"
' 2>/dev/null)
[[ "$_fn_out" == "1200,900,600,1200,600" ]] \
  && pass "T6: functional 600s -> Worker max=1200 xhigh=900 high=600, worker max=1200, Verifier-final=600" \
  || fail "T6: functional output was '$_fn_out' (want 1200,900,600,1200,600)"

# T7: the role compare must be case-INSENSITIVE. Regression guard for the
# case-sensitive `[[ "$role" != "worker" ]]` that made the whole helper inert
# (production passes "Worker"). Pinned on the zsh `${role:l}` lowercasing;
# swap this grep if an equivalent mechanism replaces it.
# Comment lines are stripped first — the helper's own comment names ${role:l},
# and a grep that matched the comment would keep passing after a code regression.
awk '/_effective_iter_timeout\(\)/,/^}/' "$LIB" | grep -v '^[[:space:]]*#' | grep -qF '${role:l}' \
  && pass "T7: role compare is case-insensitive (\${role:l})" \
  || fail "T7: role compare is case-sensitive — 'Worker' from run_ralph_desk.zsh:5501 will not match"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
