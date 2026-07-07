#!/usr/bin/env bash
# NOW-tier IMP-01..09 self-verification gate (CLAUDE.md mandate).
# Triggered because src/scripts/init_ralph_desk.zsh changed (IMP-08 slug guard).
# Mirrors tests/sv-self-verify-0.13.sh: derives scenarios from the IMP-01..09
# diff and runs them as Worker(execution_steps) -> Verifier(5 categories) -> PASS.
# Every scenario is a REAL code-path execution (node --test, real run.mjs init
# E2E, real zsh function execution) — never grep/echo simulation.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure function / contract,        L1 unit + L3 contract.
#   MEDIUM   = feature with file I/O,           L1 + L2 integration + L3.
#   CRITICAL = security / hot-path,             L1 + L2 + L3 + security + L3 error-path E2E.

set -u
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PASS=0
FAIL=0
TOTAL=0

emit() { printf "%s\n" "$*"; }

run_scenario() {
  local name="$1" risk="$2"
  shift 2
  local cmd="$*"
  TOTAL=$((TOTAL+1))
  emit ""
  emit "-- [${risk}] ${name}"
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-imp-out.log 2>&1; then
    emit "   -> PASS"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-imp-out.log)"
    tail -15 /tmp/sv-imp-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== NOW-tier IMP-01..09 Self-Verification Gate ==="
emit "Trigger: src/scripts/init_ralph_desk.zsh changed (IMP-08)"

# ---------------- LOW risk (L1 unit + L3 contract) ----------------

run_scenario "IMP-01 _file_mtime GNU-first stat + numeric guard (recovery freshness gate)" \
  "LOW" \
  "zsh tests/test_imp01_stat_mtime_gnu.sh"

run_scenario "IMP-02 --mode value validation throws for unknown mode (no silent Node fallthrough)" \
  "LOW" \
  "node --test tests/node/imp02-mode-validation.test.mjs"

run_scenario "IMP-04 CLI status schema parity (max_iter fallback + optional final segment)" \
  "LOW" \
  "node --test tests/node/imp04-status-schema-parity.test.mjs"

run_scenario "IMP-07 detect_api_error context anchoring (unconditional phrases vs co-located bare codes)" \
  "LOW" \
  "zsh tests/test_imp07_api_sniff_context.sh"

run_scenario "IMP-07 poll-loop API retry contract (500/529 + false-positive rejection)" \
  "LOW" \
  "bash tests/test_us009_api_retry_guard.sh"

# ---------------- MEDIUM risk (L1 + L2 integration + L3) ----------------

run_scenario "IMP-03 analytics pointer cross-leader resolve (zsh writes .current, node reads w/ legacy fallback)" \
  "MEDIUM" \
  "node --test tests/node/imp03-sv-pointer.test.mjs"

run_scenario "IMP-06 postinstall 0o444-locked tree upgrade path (chmod + symlink + dir branches)" \
  "MEDIUM" \
  "node --test tests/node/imp06-postinstall-locked-upgrade.test.mjs"

run_scenario "IMP-08 zsh syntax validity across all three changed scripts (init + run + lib)" \
  "MEDIUM" \
  "zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

run_scenario "IMP-08 init E2E: valid slug still scaffolds via SOURCE init script (guard is a no-op on the happy path)" \
  "MEDIUM" \
  '
TMP=$(mktemp -d) && cd "$TMP" && git init -q >/dev/null
zsh "$REPO_ROOT/src/scripts/init_ralph_desk.zsh" valid-imp-slug "sv gate objective" >/tmp/sv-init-good.log 2>&1
EC=$?
test "$EC" -eq 0 && test -d .rlp-desk
'

# ---------------- CRITICAL risk (L1 + L2 + L3 + security + error-path E2E) ----------------

run_scenario "IMP-08 SECURITY: node clean/run/status reject non-canonical slug (../../x -> throw, no retarget)" \
  "CRITICAL" \
  "node --test tests/node/imp08-slug-traversal.test.mjs"

run_scenario "IMP-08 SECURITY: zsh leaders reject traversal/invalid slug before any scaffolding (exit 2)" \
  "CRITICAL" \
  "zsh tests/test_imp08_slug_guard.sh"

run_scenario "IMP-08 ERROR-PATH E2E: SOURCE init script with traversal slug refuses (exit 2) before touching fs" \
  "CRITICAL" \
  '
TMP=$(mktemp -d) && cd "$TMP" && git init -q >/dev/null
zsh "$REPO_ROOT/src/scripts/init_ralph_desk.zsh" "../../../etc/evil" 2>/tmp/sv-init-bad.log
EC=$?
# must refuse (exit 2) AND must not have created any traversal artifact or local scaffold
test "$EC" -eq 2 && test ! -e ../../../etc/evil && test ! -d .rlp-desk
'

run_scenario "IMP-09 SECURITY: paste_to_pane no predictable /tmp file, 0600 fallback, no EXIT-trap clobber" \
  "CRITICAL" \
  "zsh tests/test_imp09_paste_no_tmpfile.sh"

# ---------------- summary ----------------
emit ""
emit "─────────────────────────────────────────────────"
if [ "$FAIL" -eq 0 ]; then
  emit "▶ IMP-01..09 SELF-VERIFY: ${PASS}/${TOTAL} scenarios PASS — OK"
else
  emit "▶ IMP-01..09 SELF-VERIFY: ${PASS}/${TOTAL} pass, ${FAIL} FAIL"
fi
emit "─────────────────────────────────────────────────"
exit "$FAIL"
