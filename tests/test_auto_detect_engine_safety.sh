#!/bin/zsh
# F-1 (reaudit wave 1) — _auto_detect_engine() eval-injection fix regression test.
#
# Bug: `_auto_detect_engine` (run_ralph_desk.zsh, env-var path for WORKER_MODEL /
# VERIFIER_MODEL / FINAL_VERIFIER_MODEL) assigned via `eval "$var=$val"` with an
# UNQUOTED, unvalidated `$val` taken straight from the model env var. A value
# like `opus:high;touch $TMP/pwned` executes arbitrary shell commands in the
# leader process. More subtly, `opus:high max` silently set WORKER_EFFORT to
# EMPTY (the RHS `high max` becomes an env-var-prefixed command invocation
# `WORKER_EFFORT=high max`, which runs a nonexistent "max" command and never
# actually assigns the shell variable) — already root-caused in this repo at
# ~5321-5325 (pre-fix line numbers).
#
# Fix: every eval-assignment replaced with `typeset -g "$var=$val"` (a single
# literal-string assignment, never re-parsed/re-executed), plus explicit
# vocabulary validation of the effort/reasoning level with a loud
# error+non-zero-exit on an invalid value instead of a silent empty.
#
# This test extracts the REAL current implementation (never a mirror) from the
# working tree, and the REAL pre-fix implementation via `git show
# $ORACLE_COMMIT:...` (see the constant below — NOT HEAD) as a live oracle
# for "what the bug actually did". It asserts:
#   1. Injection payload does not execute + fails loudly (current impl)
#   2. Injection payload DOES execute against the oracle (proves the oracle
#      reproduces the vulnerability — mutation control, non-vacuity)
#   3. 'opus:high max' fails loudly, not silently empty (current impl)
#   4. 'opus:high max' silently empties the effort var (oracle — reproduces
#      the previously-reported bug)
#   5. Valid inputs (opus:high, haiku, gpt-5.5:medium) resolve IDENTICALLY
#      between current impl and oracle (no behavior regression)
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }
# Oracle commit: a FIXED historical commit that predates this fix (still has
# the pre-fix eval() form), NOT "HEAD" — HEAD moves. Pinning to HEAD once
# already broke this test: once this reaudit-wave-1 branch's own fixes were
# committed, HEAD started containing the FIX too, so "HEAD still has the bug"
# stopped being true and every oracle-dependent assertion here would either
# fail loudly (as designed) or, worse, silently stop discriminating anything.
# 6d94518 = "chore: bump version to 0.25.0 + changelog", the last commit
# before ANY fix in this wave landed (the commit this branch was cut from).
# Do not repoint this at HEAD; if a later wave needs a newer pre-fix floor,
# pin a new fixed SHA here with the same reasoning, not a moving ref.
ORACLE_COMMIT="6d94518"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Brace-depth-aware function extractor (same style as
# tests/test_us011_worker_model_upgrade.sh's _extract_fn_from). ---
_extract_fn() {
  local fn_name="$1" src="$2"
  awk -v fn="$fn_name" '
    $0 ~ "^"fn"\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") { depth--; if (depth == 0) { print; in_fn=0; next } }
      }
      print
    }
  ' "$src"
}

CURRENT_BODY=$(_extract_fn "_auto_detect_engine" "$RUN")
[[ -n "$CURRENT_BODY" ]] || { print -u2 "FAIL: _auto_detect_engine not found in $RUN"; exit 1; }
print -r -- "$CURRENT_BODY" | grep -q 'eval "' && { print -u2 "FAIL: current _auto_detect_engine still uses eval — fix not present"; exit 1; }

git -C "$ROOT_DIR" show "$ORACLE_COMMIT":src/scripts/run_ralph_desk.zsh > "$TMP/head.zsh" 2>/dev/null \
  || { print -u2 "FAIL: could not read $ORACLE_COMMIT:src/scripts/run_ralph_desk.zsh"; exit 1; }
ORACLE_BODY=$(_extract_fn "_auto_detect_engine" "$TMP/head.zsh")
[[ -n "$ORACLE_BODY" ]] || { print -u2 "FAIL: _auto_detect_engine not found at $ORACLE_COMMIT"; exit 1; }
print -r -- "$ORACLE_BODY" | grep -q 'eval "' \
  || { print -u2 "FAIL: \$ORACLE_COMMIT's _auto_detect_engine no longer uses eval — oracle no longer reproduces the pre-fix bug; re-pin ORACLE_COMMIT to a commit before this fix landed"; exit 1; }

print -r -- "$CURRENT_BODY" > "$TMP/current_fn.zsh"
print -r -- "$ORACLE_BODY"  > "$TMP/oracle_fn.zsh"

# =============================================================================
# 1+2: injection payload
# =============================================================================
PWNED_CUR="$TMP/pwned_current"
PWNED_ORACLE="$TMP/pwned_oracle"
INJECT_MODEL_CUR="opus:high;touch $PWNED_CUR"
INJECT_MODEL_ORACLE="opus:high;touch $PWNED_ORACLE"

# --- current (fixed) impl ---
(
  source "$TMP/current_fn.zsh"
  WORKER_MODEL="$INJECT_MODEL_CUR"
  WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""
  _auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
  print "RC=$?"
) > "$TMP/inject_current.out" 2> "$TMP/inject_current.err"
if [[ -f "$PWNED_CUR" ]]; then
  no "injection: current impl EXECUTED the payload (touch created $PWNED_CUR)"
else
  ok "injection: current impl does not execute the payload"
fi
grep -q '^RC=0$' "$TMP/inject_current.out" \
  && no "injection: current impl returned 0 (should reject loudly)" \
  || ok "injection: current impl returns non-zero on the malformed effort"
[[ -s "$TMP/inject_current.err" ]] \
  && ok "injection: current impl wrote an error to stderr" \
  || no "injection: current impl produced no stderr diagnostic"

# --- oracle (pre-fix) impl: must actually execute, proving this is a real
# reproduction of the vulnerability and not a vacuous mutation control ---
(
  source "$TMP/oracle_fn.zsh"
  WORKER_MODEL="$INJECT_MODEL_ORACLE"
  WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""
  _auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
) > "$TMP/inject_oracle.out" 2> "$TMP/inject_oracle.err"
if [[ -f "$PWNED_ORACLE" ]]; then
  ok "mutation control: pre-fix oracle DOES execute the injection payload (confirms this reproduces the real bug)"
else
  no "mutation control: pre-fix oracle did NOT execute the payload — oracle extraction is not reproducing the vulnerability"
fi

# =============================================================================
# 3+4: 'opus:high max' (whitespace in the effort segment)
# =============================================================================
(
  source "$TMP/current_fn.zsh"
  WORKER_MODEL="opus:high max"
  WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""
  _auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
  print "RC=$? EFFORT=[$WORKER_EFFORT]"
) > "$TMP/maxspace_current.out" 2> "$TMP/maxspace_current.err"
grep -q '^RC=0 ' "$TMP/maxspace_current.out" \
  && no "'opus:high max': current impl returned 0 (should reject loudly)" \
  || ok "'opus:high max': current impl fails loudly (non-zero rc)"
[[ -s "$TMP/maxspace_current.err" ]] \
  && ok "'opus:high max': current impl wrote an error to stderr" \
  || no "'opus:high max': current impl produced no stderr diagnostic"

# Oracle: the reported bug is that WORKER_EFFORT silently ends up empty
# instead of "high" or any valid level — 'high max' is unpacked by the eval
# as an env-var-prefixed command invocation (WORKER_EFFORT=high max), which
# runs a nonexistent "max" command and never actually assigns the shell
# variable, discarding "high" entirely. The pre-fix CALL SITE (before this
# fix added `|| exit 1`) never checked _auto_detect_engine's return value
# either, so this corruption reached the campaign regardless of what rc came
# back — the defect under test is the empty WORKER_EFFORT, not the rc.
(
  source "$TMP/oracle_fn.zsh"
  WORKER_MODEL="opus:high max"
  WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""
  _auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
  print "RC=$? EFFORT=[$WORKER_EFFORT]"
) > "$TMP/maxspace_oracle.out" 2>"$TMP/maxspace_oracle.err"
if grep -q 'EFFORT=\[\]$' "$TMP/maxspace_oracle.out"; then
  ok "mutation control: pre-fix oracle silently empties WORKER_EFFORT on 'opus:high max' ($(cat "$TMP/maxspace_oracle.out"))"
else
  no "mutation control: pre-fix oracle did not reproduce the silent-empty-effort bug ($(cat "$TMP/maxspace_oracle.out"))"
fi

# =============================================================================
# 5: valid inputs resolve identically between current impl and oracle
# =============================================================================
_resolve() {
  local fn_file="$1" model_val="$2"
  (
    source "$fn_file"
    WORKER_MODEL="$model_val"
    WORKER_ENGINE=""; WORKER_CODEX_MODEL=""; WORKER_CODEX_REASONING=""; WORKER_EFFORT=""
    _auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT >/dev/null 2>&1
    print "engine=$WORKER_ENGINE model=$WORKER_MODEL codex_model=$WORKER_CODEX_MODEL codex_reasoning=$WORKER_CODEX_REASONING effort=$WORKER_EFFORT"
  )
}

for case_model in "opus:high" "haiku" "gpt-5.5:medium"; do
  cur=$(_resolve "$TMP/current_fn.zsh" "$case_model")
  ora=$(_resolve "$TMP/oracle_fn.zsh" "$case_model")
  if [[ "$cur" == "$ora" ]]; then
    ok "valid input '$case_model' resolves identically (current: $cur)"
  else
    no "valid input '$case_model' DIVERGED — current='$cur' oracle='$ora'"
  fi
done

echo ""
echo "=== test_auto_detect_engine_safety.sh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
