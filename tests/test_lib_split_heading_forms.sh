#!/bin/zsh
# reaudit wave 1 (queued after A-5) — lib_ralph_desk.zsh split_prd_by_us() /
# split_test_spec_by_us() heading-form + path-escaping regression test.
#
# init_ralph_desk.zsh's OWN split_prd_by_us was fixed to accept the same
# heading vocabulary as _extract_prd_us_list (lib ~1762): 2-or-3 leading #,
# US-NNN, then whitespace/colon/dash/end-of-line — e.g. "### US-001 - Title"
# (dash form), not just "### US-001: Title" (colon-only, the old form).
# lib_ralph_desk.zsh's own split_prd_by_us and split_test_spec_by_us
# (called mid-campaign, e.g. on a PRD update — NOT the same code as init's
# one-time init-time split) still had the OLD colon-only regex, so a
# dash-form PRD that init now accepts at init time would re-split to ZERO
# files mid-campaign, silently starving the Worker of per-US context.
#
# Second defect (same class as A-4's --literal-pathspecs / lib's own
# _git_dirty_names quoting fix): both functions passed the plans directory to
# awk via `-v dir=...`. POSIX awk's `-v` applies C-style backslash-escape
# processing to its value, so a directory path containing a literal
# backslash is silently corrupted (verified below: `awk -v
# dir='a\with\backslash'` prints `awithackslash`). `ENVIRON["PLANS_DIR"]`
# performs no such processing.
#
# Follow-up review round: the heading ERE is now a SHARED CONSTANT
# (RLP_US_HEADING_ERE_PRD / RLP_US_HEADING_ERE_TESTSPEC, defined once next to
# _extract_prd_us_list) used by every gate/count/split site in lib AND by
# run_ralph_desk.zsh's US_LIST derivation — so a loose pre-check gate can
# never again silently disagree with its own splitter. Plus two more fixes:
# (a) append-mode instead of close()-then-reopen-with-`>`, which used to
# TRUNCATE a US's split file if the same heading recurred later (a duplicate
# or "rationale appendix" section) — first write to a target truncates
# (`>`), every later write to the SAME target appends (`>>`); (b) the header
# for split_test_spec_by_us is captured into a variable (NUL-terminated
# read, matching init's own fix) instead of a tmp file on disk, removing an
# orphan-file leak risk, and the per-file prepend loop globs with the zsh
# `(N)` qualifier so a zero-file result is a graceful no-op, not a NOMATCH
# abort.
#
# This test extracts the REAL current implementation (never a mirror) via
# the same brace-depth-aware extractor used elsewhere in this suite, and
# the REAL pre-fix implementation via `git show HEAD:...` (HEAD still has
# the colon-only/-v-dir/close-reopen/tmp-file form) as a live oracle proving
# the mutations are real regressions, not vacuous.
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
INIT="$ROOT_DIR/src/scripts/init_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: lib script not found: $LIB"; exit 1; }
[[ -f "$RUN" ]] || { print -u2 "FAIL: run script not found: $RUN"; exit 1; }
[[ -f "$INIT" ]] || { print -u2 "FAIL: init script not found: $INIT"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }

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

# =============================================================================
# Structural: the shared ERE constants exist, are widened, and are what the
# functions/gates actually reference (not a re-inlined literal each).
# =============================================================================
ERE_PRD_LINE=$(grep -n "^RLP_US_HEADING_ERE_PRD=" "$LIB" | head -1 | cut -d: -f2-)
ERE_PRD_LIST_LINE=$(grep -n "^RLP_US_HEADING_ERE_PRD_LIST=" "$LIB" | head -1 | cut -d: -f2-)
ERE_TS_LINE=$(grep -n "^RLP_US_HEADING_ERE_TESTSPEC=" "$LIB" | head -1 | cut -d: -f2-)
[[ -n "$ERE_PRD_LINE" ]] || { print -u2 "FAIL: RLP_US_HEADING_ERE_PRD constant not found in $LIB"; exit 1; }
[[ -n "$ERE_PRD_LIST_LINE" ]] || { print -u2 "FAIL: RLP_US_HEADING_ERE_PRD_LIST constant not found in $LIB"; exit 1; }
[[ -n "$ERE_TS_LINE" ]]  || { print -u2 "FAIL: RLP_US_HEADING_ERE_TESTSPEC constant not found in $LIB"; exit 1; }
# RLP_US_HEADING_ERE_PRD is the STRICT split-level constant — 3-hash ONLY.
# ### US-NNN is a PRD story; ## US-NNN is the test-spec section level. A
# prior "unify everything" pass widened this to 2-or-3 hash and broke the
# pinned tests/test_us001_prd_splitting.sh AC1-L3-neg contract (a 2-hash
# line in a PRD must NOT be treated as a story heading — zero split files).
print -r -- "$ERE_PRD_LINE" | grep -qE "^RLP_US_HEADING_ERE_PRD='\\^###\\[\\[:space:\\]\\]\\+US-\\[0-9\\]\\+" \
  || { print -u2 "FAIL: RLP_US_HEADING_ERE_PRD is not the STRICT 3-hash-only form (got: $ERE_PRD_LINE)"; exit 1; }
print -r -- "$ERE_PRD_LINE" | grep -q '#{2,3}' \
  && { print -u2 "FAIL: RLP_US_HEADING_ERE_PRD still accepts 2-hash — must be 3-hash only"; exit 1; }
# RLP_US_HEADING_ERE_PRD_LIST stays PERMISSIVE (2-or-3 hash) — feeds the
# US-022 quarantine scope check, pre-existing behavior, deliberately NOT
# narrowed by this wave.
print -r -- "$ERE_PRD_LIST_LINE" | grep -q '#{2,3}\[\[:space:\]\]+US-\[0-9\]+(\[\[:space:\]:-\]|\$)' \
  || { print -u2 "FAIL: RLP_US_HEADING_ERE_PRD_LIST is not the broadened (2-or-3-hash, colon/dash/space/EOL) form"; exit 1; }
print -r -- "$ERE_TS_LINE" | grep -q '##\[\[:space:\]\]+US-\[0-9\]+(\[\[:space:\]:-\]|\$)' \
  || { print -u2 "FAIL: RLP_US_HEADING_ERE_TESTSPEC is not the broadened (2-hash, colon/dash/space/EOL) form"; exit 1; }

CURRENT_PRD_FN=$(_extract_fn "split_prd_by_us" "$LIB")
CURRENT_TS_FN=$(_extract_fn "split_test_spec_by_us" "$LIB")
[[ -n "$CURRENT_PRD_FN" ]] || { print -u2 "FAIL: split_prd_by_us not found in $LIB"; exit 1; }
[[ -n "$CURRENT_TS_FN" ]]  || { print -u2 "FAIL: split_test_spec_by_us not found in $LIB"; exit 1; }
print -r -- "$CURRENT_PRD_FN" | grep -q 'ENVIRON\["PLANS_DIR"\]' \
  || { print -u2 "FAIL: current split_prd_by_us does not use ENVIRON — fix not present"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -q 'ENVIRON\["PLANS_DIR"\]' \
  || { print -u2 "FAIL: current split_test_spec_by_us does not use ENVIRON — fix not present"; exit 1; }
print -r -- "$CURRENT_PRD_FN" | grep -q 'RLP_US_HEADING_ERE_PRD' \
  || { print -u2 "FAIL: current split_prd_by_us does not reference the shared ERE constant"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -q 'RLP_US_HEADING_ERE_TESTSPEC' \
  || { print -u2 "FAIL: current split_test_spec_by_us does not reference the shared ERE constant"; exit 1; }
print -r -- "$CURRENT_PRD_FN" | grep -q 'if (out in seen) { print >> out } else { print > out; seen\[out\] = 1 }' \
  || { print -u2 "FAIL: current split_prd_by_us does not use the seen[]/append-mode fix"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -q 'if (out in seen) { print >> out } else { print > out; seen\[out\] = 1 }' \
  || { print -u2 "FAIL: current split_test_spec_by_us does not use the seen[]/append-mode fix"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -qE '^\s*(local\s+)?header_tmp=' \
  && { print -u2 "FAIL: current split_test_spec_by_us still assigns a header_tmp file variable — tmp-file elimination not present"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -q 'header_content' \
  || { print -u2 "FAIL: current split_test_spec_by_us does not capture the header into a variable"; exit 1; }
print -r -- "$CURRENT_TS_FN" | grep -q '(N)' \
  || { print -u2 "FAIL: current split_test_spec_by_us does not glob split_files with (N) — NOMATCH-abort fix not present"; exit 1; }

# Unified loose gates: count_prd_us, _prd_us_set, and run.zsh's US_LIST
# derivation must all reference the SAME shared constant, not a re-inlined
# (and driftable) literal.
print -r -- "$(_extract_fn "count_prd_us" "$LIB")" | grep -q 'RLP_US_HEADING_ERE_PRD' \
  || { print -u2 "FAIL: count_prd_us does not reference RLP_US_HEADING_ERE_PRD"; exit 1; }
print -r -- "$(_extract_fn "_prd_us_set" "$LIB")" | grep -q 'RLP_US_HEADING_ERE_PRD' \
  || { print -u2 "FAIL: _prd_us_set does not reference RLP_US_HEADING_ERE_PRD"; exit 1; }
grep -q 'US_LIST=\$(grep -oE "\$RLP_US_HEADING_ERE_PRD"' "$RUN" \
  || { print -u2 "FAIL: run_ralph_desk.zsh's US_LIST derivation does not reference RLP_US_HEADING_ERE_PRD"; exit 1; }
grep -q 'expected_us=\$(grep -oE "\$RLP_US_HEADING_ERE_PRD"' "$RUN" \
  || { print -u2 "FAIL: run_ralph_desk.zsh's expected_us (per-US coverage diagnostic) does not reference RLP_US_HEADING_ERE_PRD"; exit 1; }
print -r -- "$(_extract_fn "_extract_prd_us_list" "$LIB")" | grep -q 'RLP_US_HEADING_ERE_PRD_LIST' \
  || { print -u2 "FAIL: _extract_prd_us_list does not reference the PERMISSIVE RLP_US_HEADING_ERE_PRD_LIST constant"; exit 1; }
ok "structural: shared ERE constants defined (PRD strict 3-hash, PRD_LIST permissive 2-or-3-hash, TESTSPEC 2-hash) and referenced by every gate/count/split site (lib + run.zsh)"

# --- Harness builder: source the two shared constants FIRST (the extracted
# function bodies reference them as external variables, not inline
# literals), then the extracted function itself. ---
_write_current_harness() {
  local fn_body="$1" out="$2"
  {
    print -r -- "$ERE_PRD_LINE"
    print -r -- "$ERE_TS_LINE"
    print -r -- "$fn_body"
  } > "$out"
}
_write_current_harness "$CURRENT_PRD_FN" "$TMP/current_prd_fn.zsh"
_write_current_harness "$CURRENT_TS_FN"  "$TMP/current_ts_fn.zsh"

git -C "$ROOT_DIR" show HEAD:src/scripts/lib_ralph_desk.zsh > "$TMP/head_lib.zsh" 2>/dev/null \
  || { print -u2 "FAIL: could not read HEAD:src/scripts/lib_ralph_desk.zsh"; exit 1; }
ORACLE_PRD_FN=$(_extract_fn "split_prd_by_us" "$TMP/head_lib.zsh")
ORACLE_TS_FN=$(_extract_fn "split_test_spec_by_us" "$TMP/head_lib.zsh")
[[ -n "$ORACLE_PRD_FN" && -n "$ORACLE_TS_FN" ]] || { print -u2 "FAIL: could not extract oracle functions from HEAD"; exit 1; }
print -r -- "$ORACLE_PRD_FN" | grep -q 'ENVIRON\["PLANS_DIR"\]' \
  && { print -u2 "FAIL: HEAD's split_prd_by_us already uses ENVIRON — oracle no longer reproduces the pre-fix bug"; exit 1; }
print -r -- "$ORACLE_PRD_FN" | grep -q 'if (out != "") close(out)' \
  || { print -u2 "FAIL: HEAD's split_prd_by_us no longer uses close()-then-reopen — oracle no longer reproduces the truncation bug"; exit 1; }

print -r -- "$ORACLE_PRD_FN" > "$TMP/oracle_prd_fn.zsh"
print -r -- "$ORACLE_TS_FN"  > "$TMP/oracle_ts_fn.zsh"

# =============================================================================
# Fixtures
# =============================================================================
DASH_PRD="$TMP/prd-dashtest.md"
cat > "$DASH_PRD" <<'EOF'
# Test PRD

### US-001 - Dash form title
Content for US-001.

### US-002: Colon form title
Content for US-002.
EOF

DASH_TS="$TMP/test-spec-dashtest.md"
cat > "$DASH_TS" <<'EOF'
# Test Spec

## Verification Commands
npm test

## US-001 - Dash form title
Test case for US-001.

## US-002: Colon form title
Test case for US-002.
EOF

# Simple colon-form-only PRD/test-spec (no duplicates) — used for the HEAD
# byte-identity checks below.
COLON_PRD="$TMP/prd-colontest.md"
cat > "$COLON_PRD" <<'EOF'
# Test PRD

### US-001: First heading
Body content for US-001.
More content.

### US-002: Second heading
Body content for US-002.
EOF

COLON_TS="$TMP/test-spec-colontest.md"
cat > "$COLON_TS" <<'EOF'
# Test Spec

## Verification Commands
npm test

## US-001: First
Test for US-001.

## US-002: Second
Test for US-002.
EOF

# =============================================================================
# 1: dash-form PRD -> current split_prd_by_us produces both per-US files
# =============================================================================
D1="$TMP/d1"; mkdir -p "$D1"; cp "$DASH_PRD" "$D1/prd-dashtest.md"
(
  source "$TMP/current_prd_fn.zsh"
  split_prd_by_us "$D1/prd-dashtest.md" "dashtest"
)
[[ -f "$D1/prd-dashtest-US-001.md" ]] \
  && ok "dash-form PRD: US-001 (dash heading) split file created" \
  || no "dash-form PRD: US-001 split file missing"
[[ -f "$D1/prd-dashtest-US-002.md" ]] \
  && ok "dash-form PRD: US-002 (colon heading, regression check) split file created" \
  || no "dash-form PRD: US-002 split file missing"
grep -q 'Content for US-001' "$D1/prd-dashtest-US-001.md" 2>/dev/null \
  && ok "dash-form PRD: US-001 file contains its own content" \
  || no "dash-form PRD: US-001 file content wrong or missing"

# =============================================================================
# 2: dash-form test-spec -> current split_test_spec_by_us produces both
#    per-US files WITH the global header prepended
# =============================================================================
D2="$TMP/d2"; mkdir -p "$D2"; cp "$DASH_TS" "$D2/test-spec-dashtest.md"
(
  source "$TMP/current_ts_fn.zsh"
  split_test_spec_by_us "$D2/test-spec-dashtest.md" "dashtest"
)
[[ -f "$D2/test-spec-dashtest-US-001.md" ]] \
  && ok "dash-form test-spec: US-001 (dash heading) split file created" \
  || no "dash-form test-spec: US-001 split file missing"
[[ -f "$D2/test-spec-dashtest-US-002.md" ]] \
  && ok "dash-form test-spec: US-002 (colon heading, regression check) split file created" \
  || no "dash-form test-spec: US-002 split file missing"
grep -q 'Verification Commands' "$D2/test-spec-dashtest-US-001.md" 2>/dev/null \
  && ok "dash-form test-spec: global header prepended to US-001 file" \
  || no "dash-form test-spec: global header missing from US-001 file"
grep -q 'Test case for US-001' "$D2/test-spec-dashtest-US-001.md" 2>/dev/null \
  && ok "dash-form test-spec: US-001 file contains its own content" \
  || no "dash-form test-spec: US-001 file content wrong or missing"
[[ -f "$D2/test-spec-dashtest-header.tmp."* ]] 2>/dev/null \
  && no "dash-form test-spec: leftover header.tmp file not cleaned up" \
  || ok "dash-form test-spec: no leftover header.tmp file"

# =============================================================================
# 3: backslash-containing plans dir -> files land at the CORRECT (unmangled)
#    path for both PRD and test-spec splits
# =============================================================================
D3='a\with\backslash'
mkdir -p "$TMP/$D3"
cp "$DASH_PRD" "$TMP/$D3/prd-bs.md"
cp "$DASH_TS" "$TMP/$D3/test-spec-bs.md"
(
  source "$TMP/current_prd_fn.zsh"
  source "$TMP/current_ts_fn.zsh"
  split_prd_by_us "$TMP/$D3/prd-bs.md" "bs"
  split_test_spec_by_us "$TMP/$D3/test-spec-bs.md" "bs"
)
[[ -f "$TMP/$D3/prd-bs-US-001.md" ]] \
  && ok "backslash dir: PRD split file lands at the correct (unmangled) path" \
  || no "backslash dir: PRD split file NOT at expected path (mangled by -v dir=)"
[[ -f "$TMP/$D3/test-spec-bs-US-001.md" ]] \
  && ok "backslash dir: test-spec split file lands at the correct (unmangled) path" \
  || no "backslash dir: test-spec split file NOT at expected path (mangled by -v dir=)"

# =============================================================================
# 4: duplicate-heading appendix — a US id re-mentioned as a heading LATER in
#    the same file (e.g. "### US-001 rationale" in an appendix section) must
#    APPEND to that US's split file, not truncate away the original body.
# =============================================================================
DUP_PRD="$TMP/prd-dup.md"
cat > "$DUP_PRD" <<'EOF'
# Test PRD

### US-001: First heading
Original body content for US-001.

### US-002: Second heading
Body content for US-002.

## Appendix

### US-001: Rationale appendix
Appendix content that must be APPENDED, not overwrite the original body.
EOF
D4="$TMP/d4"; mkdir -p "$D4"; cp "$DUP_PRD" "$D4/prd-dup.md"
(
  source "$TMP/current_prd_fn.zsh"
  split_prd_by_us "$D4/prd-dup.md" "dup"
)
dup_content=$(cat "$D4/prd-dup-US-001.md" 2>/dev/null)
[[ "$dup_content" == *"Original body content for US-001"* ]] \
  && ok "duplicate-heading appendix: the ORIGINAL body is preserved (not truncated away)" \
  || no "duplicate-heading appendix: original body missing — appendix truncated it: $dup_content"
[[ "$dup_content" == *"Appendix content that must be APPENDED"* ]] \
  && ok "duplicate-heading appendix: the appendix content is present (appended)" \
  || no "duplicate-heading appendix: appendix content missing: $dup_content"

# Mutation control: the pre-fix oracle (close()-then-reopen-with->) DOES
# truncate the original body when the same heading recurs.
DM4="$TMP/dm4"; mkdir -p "$DM4"; cp "$DUP_PRD" "$DM4/prd-dup.md"
(
  source "$TMP/oracle_prd_fn.zsh"
  split_prd_by_us "$DM4/prd-dup.md" "dup"
)
dm4_content=$(cat "$DM4/prd-dup-US-001.md" 2>/dev/null)
if [[ "$dm4_content" != *"Original body content for US-001"* && "$dm4_content" == *"Appendix content"* ]]; then
  ok "mutation control: pre-fix oracle TRUNCATES the original US-001 body when the heading recurs (reproduces the reported bug): got '$dm4_content'"
else
  no "mutation control: pre-fix oracle did not reproduce the truncation-on-duplicate-heading bug: got '$dm4_content'"
fi

# =============================================================================
# 5: colon-form (no duplicates) output is BYTE-IDENTICAL to the pre-fix
#    oracle's output — these split files are in the gate-receipt hash set.
# =============================================================================
D5="$TMP/d5"; mkdir -p "$D5/new" "$D5/old"
cp "$COLON_PRD" "$D5/new/prd-colontest.md"; cp "$COLON_PRD" "$D5/old/prd-colontest.md"
(
  source "$TMP/current_prd_fn.zsh"
  split_prd_by_us "$D5/new/prd-colontest.md" "colontest"
)
(
  source "$TMP/oracle_prd_fn.zsh"
  split_prd_by_us "$D5/old/prd-colontest.md" "colontest"
)
if diff -q "$D5/new/prd-colontest-US-001.md" "$D5/old/prd-colontest-US-001.md" >/dev/null 2>&1 \
  && diff -q "$D5/new/prd-colontest-US-002.md" "$D5/old/prd-colontest-US-002.md" >/dev/null 2>&1; then
  ok "colon-form PRD (no duplicates): current output is byte-identical to the pre-fix HEAD oracle"
else
  no "colon-form PRD (no duplicates): output DIVERGED from the pre-fix HEAD oracle — byte-identity broken"
fi

D6="$TMP/d6"; mkdir -p "$D6/new" "$D6/old"
cp "$COLON_TS" "$D6/new/test-spec-colontest.md"; cp "$COLON_TS" "$D6/old/test-spec-colontest.md"
(
  source "$TMP/current_ts_fn.zsh"
  split_test_spec_by_us "$D6/new/test-spec-colontest.md" "colontest"
)
(
  source "$TMP/oracle_ts_fn.zsh"
  split_test_spec_by_us "$D6/old/test-spec-colontest.md" "colontest"
)
if diff -q "$D6/new/test-spec-colontest-US-001.md" "$D6/old/test-spec-colontest-US-001.md" >/dev/null 2>&1 \
  && diff -q "$D6/new/test-spec-colontest-US-002.md" "$D6/old/test-spec-colontest-US-002.md" >/dev/null 2>&1; then
  ok "colon-form test-spec (no duplicates): current output is byte-identical to the pre-fix HEAD oracle (header + body)"
else
  no "colon-form test-spec (no duplicates): output DIVERGED from the pre-fix HEAD oracle — byte-identity broken"
fi

# =============================================================================
# 6: 2-hash PRD -> NEGATIVE control. ### US-NNN is the PRD story level; ##
#    US-NNN is the test-spec section level, so a 2-hash line in a PRD is NOT
#    a story heading. Both lib's split_prd_by_us and init's split_prd_by_us
#    must produce ZERO split files (pinned contract: this is the SAME
#    fixture tests/test_us001_prd_splitting.sh AC1-L3-neg exercises against
#    the real init CLI end to end; this checks lib's own function agrees).
# =============================================================================
TWOHASH_PRD="$TMP/prd-twohash.md"
cat > "$TWOHASH_PRD" <<'EOF'
# Test PRD

## US-001: Two-hash heading
Content for the two-hash US-001.
EOF
D7="$TMP/d7"; mkdir -p "$D7/lib" "$D7/init"
cp "$TWOHASH_PRD" "$D7/lib/prd-twohash.md"; cp "$TWOHASH_PRD" "$D7/init/prd-twohash.md"
(
  source "$TMP/current_prd_fn.zsh"
  split_prd_by_us "$D7/lib/prd-twohash.md" "twohash"
)
INIT_PRD_FN=$(_extract_fn "split_prd_by_us" "$INIT")
[[ -n "$INIT_PRD_FN" ]] || { print -u2 "FAIL: split_prd_by_us not found in $INIT"; exit 1; }
print -r -- "$INIT_PRD_FN" > "$TMP/init_prd_fn.zsh"
(
  source "$TMP/init_prd_fn.zsh"
  split_prd_by_us "$D7/init/prd-twohash.md" "twohash" >/dev/null 2>&1
)
if [[ ! -f "$D7/lib/prd-twohash-US-001.md" && ! -f "$D7/init/prd-twohash-US-001.md" ]]; then
  ok "2-hash PRD: neither lib's nor init's split_prd_by_us produces a split file (## is test-spec level, not a PRD story heading)"
else
  no "2-hash PRD: expected ZERO split files from both lib and init, got lib=$([[ -f "$D7/lib/prd-twohash-US-001.md" ]] && echo yes || echo no) init=$([[ -f "$D7/init/prd-twohash-US-001.md" ]] && echo yes || echo no)"
fi

# =============================================================================
# 7: malformed / zero-marker test-spec -> graceful no-op, no tmp leak, no
#    NOMATCH abort (the (N) glob fix).
# =============================================================================
MALFORMED_TS="$TMP/test-spec-malformed.md"
cat > "$MALFORMED_TS" <<'EOF'
# Test Spec with no US markers at all
Just prose.
EOF
D8="$TMP/d8"; mkdir -p "$D8"; cp "$MALFORMED_TS" "$D8/test-spec-malformed.md"
(
  source "$TMP/current_ts_fn.zsh"
  split_test_spec_by_us "$D8/test-spec-malformed.md" "malformed"
)
malformed_rc=$?
(( malformed_rc == 0 )) \
  && ok "malformed test-spec: graceful no-op (rc 0, no NOMATCH abort)" \
  || no "malformed test-spec: unexpected rc $malformed_rc"
ls "$D8" | grep -qi 'US-\|header.tmp' \
  && no "malformed test-spec: unexpected split/tmp file created" \
  || ok "malformed test-spec: no split file and no tmp leak"

# =============================================================================
# 8: tab-whitespace heading ("##\tUS-001:") is accepted by the gate/splitter
# =============================================================================
TAB_TS="$TMP/test-spec-tabtest.md"
printf '# Test Spec\n\n##\tUS-001: Tab-separated heading\nTab test content.\n' > "$TAB_TS"
D9="$TMP/d9"; mkdir -p "$D9"; cp "$TAB_TS" "$D9/test-spec-tabtest.md"
(
  source "$TMP/current_ts_fn.zsh"
  split_test_spec_by_us "$D9/test-spec-tabtest.md" "tabtest"
)
[[ -f "$D9/test-spec-tabtest-US-001.md" ]] \
  && ok "tab-whitespace heading: gate/splitter accept a tab between ## and US-NNN" \
  || no "tab-whitespace heading: split file missing — tab form rejected"

# =============================================================================
# Mutation control: the pre-fix oracle (HEAD) reproduces the dash-form and
# backslash-path defects
# =============================================================================
DM1="$TMP/dm1"; mkdir -p "$DM1"; cp "$DASH_PRD" "$DM1/prd-dashtest.md"
(
  source "$TMP/oracle_prd_fn.zsh"
  split_prd_by_us "$DM1/prd-dashtest.md" "dashtest"
)
if [[ ! -f "$DM1/prd-dashtest-US-001.md" && -f "$DM1/prd-dashtest-US-002.md" ]]; then
  ok "mutation control: pre-fix oracle split_prd_by_us drops the dash-form US-001 heading entirely (colon-only regex) while still splitting the colon-form US-002 — reproduces the reported bug"
else
  no "mutation control: pre-fix oracle did not reproduce the dash-form drop (US-001 present=$([[ -f "$DM1/prd-dashtest-US-001.md" ]] && echo yes || echo no), US-002 present=$([[ -f "$DM1/prd-dashtest-US-002.md" ]] && echo yes || echo no))"
fi

DM3="$TMP/dm3"; mkdir -p "$DM3/$D3"
cp "$DASH_PRD" "$DM3/$D3/prd-bs.md"
(
  source "$TMP/oracle_prd_fn.zsh"
  split_prd_by_us "$DM3/$D3/prd-bs.md" "bs"
) 2>/dev/null   # expected: the mangled path awk writes to doesn't exist
if [[ ! -f "$DM3/$D3/prd-bs-US-002.md" ]]; then
  ok "mutation control: pre-fix oracle split_prd_by_us mangles the backslash-containing dir path (-v dir=) — split file not found at the correct path (reproduces the reported bug)"
else
  no "mutation control: pre-fix oracle split correctly with a backslash dir — mutation does not reproduce the bug"
fi

# Direct, isolated proof of the awk -v mechanism itself (independent of the
# gate above, in case both the current and oracle functions happen to agree
# for unrelated reasons on this particular fixture).
mangled=$(awk -v dir='a\with\backslash' 'BEGIN{print dir}')
[[ "$mangled" != 'a\with\backslash' ]] \
  && ok "mutation control: awk -v itself corrupts a backslash-containing value on this awk (mangled to '$mangled') — confirms the mechanism, not just this fixture" \
  || no "mutation control: awk -v did NOT corrupt the backslash value on this awk ('$mangled') — the -v/ENVIRON distinction would not matter here"
unmangled=$(PLANS_DIR='a\with\backslash' awk 'BEGIN{print ENVIRON["PLANS_DIR"]}')
[[ "$unmangled" == 'a\with\backslash' ]] \
  && ok "sanity: ENVIRON preserves the backslash-containing value unmangled" \
  || no "sanity: ENVIRON also mangled the value ('$unmangled') — the fix would not help"

echo ""
echo "=== test_lib_split_heading_forms.sh: $PASS passed, $FAIL failed ==="
(( FAIL == 0 ))
