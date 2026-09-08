#!/bin/zsh
# LIB quoting fix (reaudit wave 1) — regression test for the two
# lib_ralph_desk.zsh consumers of unquoted git dirty-file names:
#   1. _commit_oracle_tracked_dirty()  (~lib:3062, US-001 commit-integrity oracle)
#   2. derive_verification_mode()      (~lib:3684, build-vs-confirmation classifier)
#
# Bug: both called a git-diff path directly (`_git_snapshot ... diff
# --name-only <base>` / a bare `git diff --name-only HEAD`) instead of
# _git_dirty_names (the -z + unquote helper). Plain `--name-only` is
# DISPLAY-formatted: under git's own default `core.quotePath=true`, a path
# with a backslash, a double quote, or a non-ASCII byte comes back C-quoted
# (e.g. `"\303\244.txt"`). Both consumers then `comm -23` that quoted name
# against CAMPAIGN_PREEXISTING_DIRTY, which holds UNQUOTED names (as produced
# by _git_dirty_names elsewhere) — the quoted string never matches, so a
# RESIDENT (preexisting, non-campaign) dirty file with such a name is wrongly
# treated as NEW campaign-era dirt:
#   - _commit_oracle_tracked_dirty wrongly attributes it to the worker
#   - derive_verification_mode wrongly downgrades confirmation -> build
#
# Fix: both now call the shared _git_dirty_names helper (moved from
# run_ralph_desk.zsh into lib_ralph_desk.zsh in this same change), so the
# resident file's name matches CAMPAIGN_PREEXISTING_DIRTY and is correctly
# excluded.
#
# This test builds a repo with core.quotePath=true and a non-ASCII-named
# tracked file, dirties it (simulating resident user dirt captured into
# CAMPAIGN_PREEXISTING_DIRTY under its UNQUOTED name — exactly what
# _git_dirty_names would have produced at process start), and drives BOTH
# consumers end to end against:
#   - the CURRENT (fixed) lib_ralph_desk.zsh  -> must exclude/pass
#   - the pre-fix lib_ralph_desk.zsh, via `git show $ORACLE_COMMIT:...` (see
#     the constant below — NOT HEAD), as a live oracle -> must reproduce the
#     false-positive (mutation control, non-vacuity)
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }
command -v jq  >/dev/null 2>&1 || { print -u2 "FAIL: jq not installed"; exit 1; }
# Oracle commit: a FIXED historical commit that predates this fix (still has
# the pre-fix bare _git_snapshot calls, no _git_dirty_names quoting wrapper),
# NOT "HEAD" — HEAD moves, and once this reaudit-wave-1 branch's own fixes
# were committed, HEAD stopped being a valid unfixed baseline. 6d94518 =
# "chore: bump version to 0.25.0 + changelog", the last commit before ANY fix
# in this wave landed (the commit this branch was cut from). Do not repoint
# this at HEAD.
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

_build_harness() {
  # $1 = source lib file to extract from, $2 = output harness file
  local src="$1" out="$2"
  {
    echo 'log(){ :; }; log_error(){ :; }; log_debug(){ :; }'
    # reaudit wave 1 (queued after A-5): _prd_us_set now references the
    # shared RLP_US_HEADING_ERE_PRD constant instead of an inline literal —
    # source it here too. Harmless (unused) for the HEAD oracle build, which
    # still has the old inline-literal form.
    grep '^RLP_US_HEADING_ERE_PRD=' "$src"
    for fn in _git_snapshot _git_dirty_base _git_dirty_names _commit_oracle_tracked_dirty _prd_us_set derive_verification_mode; do
      _extract_fn "$fn" "$src"
    done
  } > "$out"
}

# CURRENT (fixed) harness
_build_harness "$LIB" "$TMP/current.zsh"
grep -q '^_git_dirty_names() {' "$TMP/current.zsh" \
  || { print -u2 "FAIL: _git_dirty_names not found in current lib_ralph_desk.zsh — LIB move not present"; exit 1; }
grep -q '_git_dirty_names "\$ROOT"' "$TMP/current.zsh" \
  || { print -u2 "FAIL: _commit_oracle_tracked_dirty in current lib does not call _git_dirty_names"; exit 1; }
grep -q '_git_dirty_names "\$root" HEAD' "$TMP/current.zsh" \
  || { print -u2 "FAIL: derive_verification_mode in current lib does not call _git_dirty_names"; exit 1; }

# ORACLE (pre-fix, pinned to $ORACLE_COMMIT) harness
git -C "$ROOT_DIR" show "$ORACLE_COMMIT":src/scripts/lib_ralph_desk.zsh > "$TMP/head_lib.zsh" 2>/dev/null \
  || { print -u2 "FAIL: could not read $ORACLE_COMMIT:src/scripts/lib_ralph_desk.zsh"; exit 1; }
_build_harness "$TMP/head_lib.zsh" "$TMP/oracle.zsh"
grep -q '^_git_dirty_names() {' "$TMP/oracle.zsh" \
  && { print -u2 "FAIL: \$ORACLE_COMMIT's lib_ralph_desk.zsh already has _git_dirty_names — oracle is not a valid pre-fix baseline; re-pin ORACLE_COMMIT to a commit before this fix landed"; exit 1; }
grep -q 'git -C "\$root" diff --name-only HEAD' "$TMP/oracle.zsh" \
  || { print -u2 "FAIL: HEAD's derive_verification_mode is not the bare-git-diff pre-fix form — oracle does not reproduce the bug"; exit 1; }

# =============================================================================
# Repo fixture: core.quotePath=true, a non-ASCII-named TRACKED file, dirtied
# (uncommitted edit) — this is the "resident preexisting dirt" that must be
# excluded by name-matching against CAMPAIGN_PREEXISTING_DIRTY.
# =============================================================================
mkfixture() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  git -C "$r" config core.quotePath true
  local nonascii=$'\xc3\xa4.txt'   # ä.txt
  print -r -- base > "$r/a.txt"
  print -r -- seed > "$r/$nonascii"
  git -C "$r" add -- a.txt "$nonascii"
  git -C "$r" commit -qm base
  print -r -- "resident edit" >> "$r/$nonascii"   # dirty, uncommitted, never staged/committed by "the campaign"
  print -r -- "$nonascii"
}

# =============================================================================
# Scenario 1: _commit_oracle_tracked_dirty — resident dirt exclusion
# =============================================================================
R1="$TMP/repo1"
NONASCII_NAME=$(mkfixture "$R1")

(
  source "$TMP/current.zsh"
  ROOT="$R1"
  CAMPAIGN_PREEXISTING_DIRTY="$NONASCII_NAME"
  dirty=$(_commit_oracle_tracked_dirty); rc=$?
  print "RC=$rc DIRTY=[$dirty]"
) > "$TMP/s1_current.out" 2>&1
if grep -q '^RC=0 DIRTY=\[\]$' "$TMP/s1_current.out"; then
  ok "_commit_oracle_tracked_dirty (current): resident quoted-name dirt correctly excluded (empty worker-dirty set)"
else
  no "_commit_oracle_tracked_dirty (current): expected RC=0 DIRTY=[], got: $(cat "$TMP/s1_current.out")"
fi

(
  source "$TMP/oracle.zsh"
  ROOT="$R1"
  CAMPAIGN_PREEXISTING_DIRTY="$NONASCII_NAME"
  dirty=$(_commit_oracle_tracked_dirty); rc=$?
  print "RC=$rc DIRTY=[$dirty]"
) > "$TMP/s1_oracle.out" 2>&1
if grep -q '^RC=0 DIRTY=\[\]$' "$TMP/s1_oracle.out"; then
  no "mutation control: pre-fix oracle _commit_oracle_tracked_dirty did NOT reproduce the false-positive (got empty dirty set, same as fixed — test would not catch a regression)"
else
  ok "mutation control: pre-fix oracle _commit_oracle_tracked_dirty wrongly attributes the quoted resident file as worker dirt: $(cat "$TMP/s1_oracle.out")"
fi

# =============================================================================
# Scenario 2: derive_verification_mode — resident dirt must not downgrade
# confirmation to build
# =============================================================================
R2="$TMP/repo2"
NONASCII_NAME2=$(mkfixture "$R2")
HEAD_SHA=$(git -C "$R2" rev-parse HEAD)

PRD="$TMP/prd.md"
cat > "$PRD" <<'EOF'
# Test PRD

### US-001: something
EOF
PRD_HASH=$(git hash-object "$PRD")

LEDGER="$TMP/ledger.jsonl"
jq -nc --arg us "US-001" --arg sha "$HEAD_SHA" --arg prd "$PRD_HASH" \
  '{us_id: $us, commit: $sha, prd: $prd}' > "$LEDGER"

(
  source "$TMP/current.zsh"
  CAMPAIGN_PREEXISTING_DIRTY="$NONASCII_NAME2"
  derive_verification_mode "$LEDGER" "$PRD" "$R2" "US-001"
) > "$TMP/s2_current.out" 2>&1
if grep -q '^confirmation|' "$TMP/s2_current.out"; then
  ok "derive_verification_mode (current): resident quoted-name dirt does not block confirmation mode"
else
  no "derive_verification_mode (current): expected confirmation|..., got: $(cat "$TMP/s2_current.out")"
fi

(
  source "$TMP/oracle.zsh"
  CAMPAIGN_PREEXISTING_DIRTY="$NONASCII_NAME2"
  derive_verification_mode "$LEDGER" "$PRD" "$R2" "US-001"
) > "$TMP/s2_oracle.out" 2>&1
if grep -q '^build|tracked working tree has campaign-era changes' "$TMP/s2_oracle.out"; then
  ok "mutation control: pre-fix oracle derive_verification_mode wrongly downgrades to build: $(cat "$TMP/s2_oracle.out")"
else
  no "mutation control: pre-fix oracle derive_verification_mode did NOT reproduce the false downgrade (got: $(cat "$TMP/s2_oracle.out")) — test would not catch a regression"
fi

echo ""
echo "=== test_git_dirty_names_lib.sh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
