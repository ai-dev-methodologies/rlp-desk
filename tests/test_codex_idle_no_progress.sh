#!/bin/zsh
# v0.14.1 unit test — Bug Report #3 fixes in run_ralph_desk.zsh.
#
# Validates two helpers:
#   1. is_codex_idle_ui()         — recognizes codex post-work idle banner
#   2. _verifier_pane_has_verdict() — short-circuits no-progress when the
#      verdict file is already on disk (the "frozen verifier" false positive
#      that BOS Bug Report #3 reported).
#
# Mocks tmux + the global state so we can exercise the helpers without a live
# tmux server.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN_SCRIPT="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"

# Extract the helpers we need to test. is_codex_idle_ui is small and
# self-contained; _verifier_pane_has_verdict needs jq + the
# VERIFIER_PANE/VERDICT_FILE globals; v0.14.2 also requires
# _migrate_legacy_verdict (legacy → canonical fallback).
TMP_LIB=$(mktemp -t codex-idle-test.XXXXXX)
sed -n '/^is_codex_idle_ui()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_migrate_legacy_verdict()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"
sed -n '/^_verifier_pane_has_verdict()/,/^}/p' "$RUN_SCRIPT" >> "$TMP_LIB"
print "" >> "$TMP_LIB"

# Stub log helpers so _migrate_legacy_verdict's calls do not error.
log() { :; }
log_debug() { :; }

source "$TMP_LIB"

PASS=0
FAIL=0

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    print "PASS: $label"
    (( PASS++ ))
  else
    print "FAIL: $label (expected '$expected', got '$actual')"
    (( FAIL++ ))
  fi
}

# ---------------------------------------------------------------------------
# is_codex_idle_ui
# ---------------------------------------------------------------------------

is_codex_idle_ui '─ Worked for 5m 36s ──────────────────'
assert_eq "idle banner with full BOS Bug #3 capture" 0 $?

is_codex_idle_ui 'gpt-5.5 high · main · Context 87% left · 1.85M in'
assert_eq "context status line alone" 0 $?

is_codex_idle_ui '─ Worked for 0m 30s ─'
assert_eq "short-duration variant" 0 $?

is_codex_idle_ui 'I worked through the spec and now ran tests'
assert_eq "false: 'worked' word elsewhere" 1 $?

is_codex_idle_ui ''
assert_eq "false: empty input" 1 $?

is_codex_idle_ui 'Do you want to create file.json? (y/n)'
assert_eq "false: claude permission prompt" 1 $?

# v0.14.2 Bug Report #4 — pattern relaxations:
is_codex_idle_ui 'Worked for 5m 14s'
assert_eq "v0.14.2: 'Worked for' without horizontal-rule wrapper" 0 $?

is_codex_idle_ui 'gpt-5.5 high · feature/phase-1-bc-implementation · Context 57%left'
assert_eq "v0.14.2: 'Context X%left' (no space) — wrapped pane variant" 0 $?

is_codex_idle_ui 'gpt-5.5 high · feature/foo · Context 99% left'
assert_eq "v0.14.2: model+branch line — alone" 0 $?

# codex 0.144 / GPT-5.6 (models: gpt-5.6-sol|terra|luna; new efforts max|ultra).
# The status line carries SUFFIXED model names ("gpt-5.6-sol max · main"),
# which the pre-5.6 pattern (bare gpt-X.Y + low..xhigh) never matched.
is_codex_idle_ui 'gpt-5.6-sol max · main'
assert_eq "gpt-5.6: suffixed model + max effort — model+branch line alone" 0 $?

is_codex_idle_ui 'gpt-5.6-terra ultra · feature/foo'
assert_eq "gpt-5.6: terra + ultra effort" 0 $?

is_codex_idle_ui 'gpt-5.6-luna low · main'
assert_eq "gpt-5.6: luna + pre-existing effort name" 0 $?

is_codex_idle_ui 'gpt-5.3-codex-spark high · main'
assert_eq "spark: suffixed model name on model+branch line alone" 0 $?

is_codex_idle_ui 'gpt-5.6-sol finished reviewing the maximum retry logic'
assert_eq "false: model name in prose without effort-dot-branch shape" 1 $?

is_codex_idle_ui '› Improve documentation in @bos/db'
assert_eq "v0.14.2: codex default suggestion 'Improve documentation in @'" 0 $?

is_codex_idle_ui '› Summarize recent commits'
assert_eq "v0.14.2: codex default suggestion 'Summarize recent commits'" 0 $?

# ---------------------------------------------------------------------------
# _verifier_pane_has_verdict
# ---------------------------------------------------------------------------

# Setup: temp verdict file + globals that the helper reads.
TMP_VERDICT=$(mktemp -t codex-verdict.XXXXXX)
print '{"verdict":"pass","us_id":"US-003","iteration":3}' > "$TMP_VERDICT"

VERIFIER_PANE="%v"
FINAL_VERIFIER_PANE="%fv"
VERDICT_FILE="$TMP_VERDICT"

_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + valid verdict → return 0" 0 $?

_verifier_pane_has_verdict "%fv"
assert_eq "final-verifier pane + valid verdict → return 0" 0 $?

_verifier_pane_has_verdict "%w"   # worker pane, not verifier
assert_eq "worker pane → return 1 (no short-circuit)" 1 $?

print 'not-json' > "$TMP_VERDICT"
_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + invalid JSON → return 1" 1 $?

rm -f "$TMP_VERDICT"
_verifier_pane_has_verdict "%v"
assert_eq "verifier pane + missing verdict file → return 1" 1 $?

# Empty VERDICT_FILE var → return 1.
VERDICT_FILE=""
_verifier_pane_has_verdict "%v"
assert_eq "empty VERDICT_FILE → return 1" 1 $?

# ---------------------------------------------------------------------------
# v0.14.2: legacy verdict auto-migration (Bug Report #4 Fix-D)
# ---------------------------------------------------------------------------

# Build a temp project layout with a legacy verdict file but no canonical one.
TMP_PROJ=$(mktemp -d -t codex-verdict-proj.XXXXXX)
mkdir -p "$TMP_PROJ/.claude/ralph-desk/memos"
mkdir -p "$TMP_PROJ/.rlp-desk/memos"
LEGACY_PAYLOAD='{"verdict":"pass","us_id":"US-008","iteration":5}'
print -- "$LEGACY_PAYLOAD" > "$TMP_PROJ/.claude/ralph-desk/memos/test-verify-verdict.json"

VERIFIER_PANE="%v"
FINAL_VERIFIER_PANE="%fv"
VERDICT_FILE="$TMP_PROJ/.rlp-desk/memos/test-verify-verdict.json"
LEGACY_VERDICT_FILE="$TMP_PROJ/.claude/ralph-desk/memos/test-verify-verdict.json"

# 1) verifier pane + only legacy file present → short-circuit returns 0
#    AND auto-migrates the file into the canonical location.
_verifier_pane_has_verdict "%v"
assert_eq "v0.14.2: legacy-only verdict + verifier pane → return 0" 0 $?
[[ -f "$VERDICT_FILE" ]]
assert_eq "v0.14.2: canonical file now exists after auto-mv" 0 $?
[[ ! -f "$LEGACY_VERDICT_FILE" ]]
assert_eq "v0.14.2: legacy file removed after auto-mv" 0 $?
test "$(jq -r .us_id < "$VERDICT_FILE")" = "US-008"
assert_eq "v0.14.2: migrated content preserved (us_id=US-008)" 0 $?

# 2) Both legacy + canonical present (canonical wins, no migration needed)
print -- "$LEGACY_PAYLOAD" > "$LEGACY_VERDICT_FILE"
print -- '{"verdict":"fail","us_id":"US-008","iteration":5}' > "$VERDICT_FILE"
_verifier_pane_has_verdict "%v"
assert_eq "v0.14.2: canonical present → return 0 (no migration)" 0 $?
test "$(jq -r .verdict < "$VERDICT_FILE")" = "fail"
assert_eq "v0.14.2: canonical content untouched when present" 0 $?

# 3) Legacy present but invalid JSON → migration refused, return 1
rm -f "$VERDICT_FILE"
print -- 'not-json' > "$LEGACY_VERDICT_FILE"
_verifier_pane_has_verdict "%v"
assert_eq "v0.14.2: legacy with invalid JSON → return 1 (no migration)" 1 $?
[[ -f "$LEGACY_VERDICT_FILE" ]]
assert_eq "v0.14.2: invalid legacy file left in place" 0 $?

rm -rf "$TMP_PROJ"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print ""
print "=== summary: PASS=$PASS FAIL=$FAIL ==="
rm -f "$TMP_LIB"
[[ "$FAIL" -eq 0 ]]
