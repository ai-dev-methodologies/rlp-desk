#!/usr/bin/env bash
# Test suite: environment/flaky escalation guard (luna-first spec §2.5)
#
# Governance ("Verifier: reasoning in verify-verdict.json") classifies failures
# PER ISSUE, so `failure_category` legitimately lands at three placements
# depending on the producer: top-level, inside `issues[]`, or inside `checks[]`.
# The original guard read only top-level and `checks[]`, so an issue-level
# `environment` verdict silently escalated the model ladder on a verifier
# safety-classifier refusal — the exact outcome the doctrine forbids.
#
# T1-T10 run the REAL `_verdict_failure_category` extracted from the lib against
# real verdict files. T11-T12 drive the REAL `check_model_upgrade` through the
# guard predicate and assert the worker model does / does not move. T13-T15 pin
# the leader wiring, including the literal predicate text that T11/T12 mirror.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="${LIB:-$REPO_ROOT/src/scripts/lib_ralph_desk.zsh}"
RUN="${RUN:-$REPO_ROOT/src/scripts/run_ralph_desk.zsh}"
PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

command -v jq >/dev/null 2>&1 || { echo "FATAL: jq is required"; exit 1; }

FIX=$(mktemp -d -t rlp-env-guard.XXXXXX)
trap 'rm -rf "$FIX"' EXIT

# --- verdict fixtures: all three documented placements, plus the negatives ---
cat > "$FIX/top.json" <<'JSON'
{"verdict":"fail","failure_category":"environment","summary":"verifier safety-classifier refusal"}
JSON
cat > "$FIX/issues.json" <<'JSON'
{"verdict":"fail","issues":[{"id":"AC1","severity":"critical","failure_category":"environment","description":"model-capacity stall"}]}
JSON
cat > "$FIX/checks.json" <<'JSON'
{"verdict":"fail","checks":[{"name":"IL-1 Evidence Gate","decision":"fail","failure_category":"environment"}]}
JSON
cat > "$FIX/issues-flaky.json" <<'JSON'
{"verdict":"fail","issues":[{"id":"AC2","failure_category":"flaky","description":"timing-dependent assertion"}]}
JSON
cat > "$FIX/checks-flaky.json" <<'JSON'
{"verdict":"fail","checks":[{"name":"Test Sufficiency","decision":"fail","failure_category":"flaky"}]}
JSON
cat > "$FIX/absent.json" <<'JSON'
{"verdict":"fail","issues":[{"id":"AC1","description":"off-by-one in the loop bound"}],"checks":[{"name":"IL-1","decision":"fail"}]}
JSON
cat > "$FIX/implementation.json" <<'JSON'
{"verdict":"fail","issues":[{"id":"AC1","failure_category":"implementation","description":"wrong algorithm"}]}
JSON
# Precedence: an explicit top-level classification wins over per-issue entries.
cat > "$FIX/precedence.json" <<'JSON'
{"verdict":"fail","failure_category":"implementation","issues":[{"id":"AC1","failure_category":"environment"}]}
JSON
printf '{"verdict":"fail",\n' > "$FIX/malformed.json"

# Run the REAL extracted helper (same awk function-extraction technique as
# tests/sv-large-campaign/test-model-upgrade-ladder.zsh — name-anchored, so it
# is drift-proof against the function moving inside the lib).
_cat_of() {
  zsh -fc '
    source <(awk "/^_verdict_failure_category\(\)/{f=1} f{print} f&&/^\}/{f=0}" '"$LIB"')
    (( $+functions[_verdict_failure_category] )) || { print -r -- "__NOT_EXTRACTED__"; exit 0; }
    _verdict_failure_category "$1"
  ' zsh "$1" 2>/dev/null
}

_assert_cat() { # <label> <fixture-file> <expected>
  local got
  got=$(_cat_of "$2")
  if [[ "$got" == "$3" ]]; then
    pass "$1"
  else
    fail "$1 (got '$got', want '$3')"
  fi
}

_assert_cat "T1: environment at top level"            "$FIX/top.json"           "environment"
_assert_cat "T2: environment inside issues[]"         "$FIX/issues.json"        "environment"
_assert_cat "T3: environment inside checks[]"         "$FIX/checks.json"        "environment"
_assert_cat "T4: flaky inside issues[]"               "$FIX/issues-flaky.json"  "flaky"
_assert_cat "T5: flaky inside checks[]"               "$FIX/checks-flaky.json"  "flaky"
_assert_cat "T6: absent category -> empty"            "$FIX/absent.json"        ""
_assert_cat "T7: implementation is passed through"    "$FIX/implementation.json" "implementation"
_assert_cat "T8: top level wins over issues[]"        "$FIX/precedence.json"    "implementation"
_assert_cat "T9: malformed JSON -> empty (no crash)"  "$FIX/malformed.json"     ""
_assert_cat "T10: missing file -> empty (no crash)"   "$FIX/does-not-exist.json" ""

# --- functional: the guard predicate over the REAL check_model_upgrade -------
# The predicate below mirrors run_ralph_desk.zsh's fail-verdict guard; T13 pins
# that mirror to the leader's literal source text so the two cannot drift.
_guard_sim() { # <fixture-file> -> "<model>:<effort>" after two same-US failures
  zsh -fc '
    log() { : }; log_debug() { : }; log_error() { : }
    ITERATION=1
    LOCK_WORKER_MODEL=0
    _SAME_US_FAIL_COUNT=0
    _LAST_FAILED_US=""
    _MODEL_UPGRADED=0
    _ORIGINAL_WORKER_MODEL=""
    _ORIGINAL_WORKER_CODEX_REASONING=""
    typeset -gA US_FAIL_HISTORY
    LIB_DIR='"$REPO_ROOT"'/src/scripts
    # Hermeticity: a real ~/.claude/rlp-desk-models.json must not win over the
    # shipped ladder this test asserts on (same guard as the ladder test).
    RLP_DESK_MODELS_FILE=/nonexistent-hermetic-test-guard/rlp-desk-models.json
    _SRC=$(mktemp -t env-guard-fns.XXXXXX.zsh)
    for _fn in get_model_string get_next_model check_model_upgrade record_us_failure _verdict_failure_category; do
      awk "/^${_fn}\(\)/{f=1} f{print} f&&/^\}/{f=0}" '"$LIB"' >> "$_SRC"
    done
    source "$_SRC"; rm -f "$_SRC"
    WORKER_ENGINE=codex
    WORKER_CODEX_MODEL=gpt-5.6-luna
    WORKER_CODEX_REASONING=high
    WORKER_MODEL=gpt-5.6-luna
    # Two consecutive failures on the SAME US — the ladder trigger.
    for _i in 1 2; do
      _fail_cat=$(_verdict_failure_category "$1")
      if [[ "$_fail_cat" != "environment" && "$_fail_cat" != "flaky" ]]; then
        check_model_upgrade "US-001"
      fi
    done
    print -r -- "${WORKER_CODEX_MODEL}:${WORKER_CODEX_REASONING}"
  ' zsh "$1" 2>/dev/null
}

# T11 (control) proves the harness can observe an upgrade, so T12's "unchanged"
# is a real assertion and not a silently inert probe.
_impl_out=$(_guard_sim "$FIX/implementation.json")
[[ "$_impl_out" == "gpt-5.6-luna:max" ]] \
  && pass "T11: control — implementation failure DOES climb (luna:high -> luna:max)" \
  || fail "T11: control did not climb (got '$_impl_out', want gpt-5.6-luna:max)"

_env_out=$(_guard_sim "$FIX/issues.json")
[[ "$_env_out" == "gpt-5.6-luna:high" ]] \
  && pass "T12: issues[]-level environment failure leaves the worker model UNCHANGED" \
  || fail "T12: model moved to '$_env_out' on an environment failure (want gpt-5.6-luna:high)"

_flaky_out=$(_guard_sim "$FIX/checks-flaky.json")
[[ "$_flaky_out" == "gpt-5.6-luna:high" ]] \
  && pass "T12b: checks[]-level flaky failure leaves the worker model UNCHANGED" \
  || fail "T12b: model moved to '$_flaky_out' on a flaky failure (want gpt-5.6-luna:high)"

# --- leader wiring ----------------------------------------------------------
grep -qF '_fail_cat=$(_verdict_failure_category "$VERDICT_FILE")' "$RUN" \
  && pass "T13: leader reads the category via _verdict_failure_category" \
  || fail "T13: leader does not call _verdict_failure_category (inline jq would miss issues[])"

grep -qF '[[ "$_fail_cat" != "environment" && "$_fail_cat" != "flaky" ]]' "$RUN" \
  && pass "T14: leader branches on environment|flaky (predicate mirrored by T11/T12)" \
  || fail "T14: guard predicate text changed — re-sync the T11/T12 simulation"

grep -qF '_verdict_failure_category()' "$LIB" \
  && pass "T15: _verdict_failure_category() is defined in the lib" \
  || fail "T15: _verdict_failure_category() missing from the lib"

echo "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
