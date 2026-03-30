#!/usr/bin/env bash
# Test Suite: US-001 (v05-remaining) — init --mode improve
# Focus: preserve test-spec on improve + sentinel cleanup + fresh-mode regeneration
# IL-4: 3 ACs x 3 minimum tests = 9 tests

set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT/src/scripts/init_ralph_desk.zsh"

PASS=0
FAIL=0
TMPDIRS=()

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

assert_eq() {
  local got="$1" expected="$2" label="$3"
  if [[ "$got" -eq "$expected" ]]; then
    pass "$label"
  else
    fail "$label (got $got, expected $expected)"
  fi
}

assert_file_missing() {
  local f="$1" label="$2"
  if [[ ! -f "$f" ]]; then
    pass "$label"
  else
    fail "$label (still present: $f)"
  fi
}

assert_file_contains_text() {
  local f="$1" needle="$2" label="$3"
  if grep -qF "$needle" "$f" 2>/dev/null; then
    pass "$label"
  else
    fail "$label (missing text: $needle)"
  fi
}

assert_file_not_contains_text() {
  local f="$1" needle="$2" label="$3"
  if grep -qF "$needle" "$f" 2>/dev/null; then
    fail "$label (unexpected text: $needle)"
  else
    pass "$label"
  fi
}

assert_files_equal() {
  local a="$1" b="$2" label="$3"
  if cmp -s "$a" "$b"; then
    pass "$label"
  else
    fail "$label (files differ)"
  fi
}

cleanup() {
  if [[ ${#TMPDIRS[@]} -gt 0 ]]; then
    for d in "${TMPDIRS[@]}"; do
      rm -rf "$d"
    done
  fi
}
trap cleanup EXIT

run_init() {
  local dir="$1" slug="$2" objective="$3" mode="$4"
  if [[ -z "$mode" ]]; then
    ROOT="$dir" zsh "$INIT" "$slug" "$objective" >/dev/null 2>&1 || true
  else
    ROOT="$dir" zsh "$INIT" "$slug" "$objective" --mode "$mode" >/dev/null 2>&1 || true
  fi
}

new_tmp() {
  local d
  d="$(mktemp -d)"
  TMPDIRS+=("$d")
  printf '%s' "$d"
}

echo "=== US-001: init --mode improve + sentinel cleanup ==="
echo ""

echo "--- AC1: test-spec preserved on improve ---"

# AC1-happy
test_ac1_happy_preserves_customized_test_spec_on_improve() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15 "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15.md"
  cat > "$ts" <<'TS_END'
# Test Spec: ac14a15
## Verification Commands
zsh -n src/scripts/init_ralph_desk.zsh

## US-001: Customize
- custom line
TS_END

  local before="$ts.before"
  cp "$ts" "$before"
  run_init "$dir" ac14a15 "test" "improve"

  assert_files_equal "$ts" "$before" "AC1-happy: custom test-spec content is unchanged after improve"
}

# AC1-negative
test_ac1_negative_fresh_mode_is_not_a_noop_for_test_spec() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15b "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15b.md"
  printf '%s\n' "CUSTOMIZED test-spec marker" > "$ts"
  run_init "$dir" ac14a15b "test" "fresh"

  assert_file_not_contains_text "$ts" "CUSTOMIZED test-spec marker" \
    "AC1-negative: fresh mode does not preserve custom test-spec"
}

# AC1-boundary
test_ac1_boundary_markerless_spec_stays_unchanged_on_improve() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15c "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15c.md"
  cat > "$ts" <<'TS_END'
# Test Spec: markerless
No US sections here.
TS_END

  local before="$ts.before"
  cp "$ts" "$before"
  run_init "$dir" ac14a15c "test" "improve"

  assert_files_equal "$ts" "$before" "AC1-boundary: markerless custom test-spec unchanged on improve"
}


echo ""
echo "--- AC2: sentinels deleted on improve without PRD ---"

# AC2-happy
test_ac2_happy_deletes_complete_sentinel_with_prd_missing() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15s2 "test" ""

  printf '%s\n' "completed" > "$dir/.claude/ralph-desk/memos/ac14a15s2-complete.md"
  rm -f "$dir/.claude/ralph-desk/plans/prd-ac14a15s2.md"
  run_init "$dir" ac14a15s2 "test" "improve"

  assert_file_missing "$dir/.claude/ralph-desk/memos/ac14a15s2-complete.md" \
    "AC2-happy: complete sentinel deleted when PRD is absent"
}

# AC2-negative
test_ac2_negative_no_complete_file_is_idempotent() {
  local dir
  dir="$(new_tmp)"
  local memodir="$dir/.claude/ralph-desk/memos"
  mkdir -p "$memodir"

  local keep_file="$memodir/ac14a15s3-keep.md"
  printf '%s\n' "keep" > "$keep_file"

  rm -f "$dir/.claude/ralph-desk/plans/prd-ac14a15s3.md"

  local status=0
  ROOT="$dir" zsh "$INIT" ac14a15s3 "test" --mode "improve" >/dev/null 2>&1 || status=$?

  assert_eq "$status" 0 "AC2-negative: improve without complete sentinel returns success"
  assert_file_contains_text "$keep_file" "keep" \
    "AC2-negative: non-sentinel memo files remain untouched"
}

# AC2-boundary
test_ac2_boundary_deletes_blocked_too_when_prd_missing() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15s4 "test" ""

  printf '%s\n' "completed" > "$dir/.claude/ralph-desk/memos/ac14a15s4-complete.md"
  printf '%s\n' "blocked" > "$dir/.claude/ralph-desk/memos/ac14a15s4-blocked.md"
  rm -f "$dir/.claude/ralph-desk/plans/prd-ac14a15s4.md"
  run_init "$dir" ac14a15s4 "test" "improve"

  assert_file_missing "$dir/.claude/ralph-desk/memos/ac14a15s4-complete.md" \
    "AC2-boundary: complete sentinel deleted on improve without PRD"
  assert_file_missing "$dir/.claude/ralph-desk/memos/ac14a15s4-blocked.md" \
    "AC2-boundary: blocked sentinel deleted on improve without PRD"
}


echo ""
echo "--- AC3: fresh mode regenerates test-spec ---"

# AC3-happy
test_ac3_happy_fresh_regenerates_customized_test_spec() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15f "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15f.md"
  printf '%s\n' "CUSTOMIZED test-spec marker" > "$ts"
  run_init "$dir" ac14a15f "test" "fresh"

  assert_file_not_contains_text "$ts" "CUSTOMIZED test-spec marker" \
    "AC3-happy: fresh mode replaces customized test-spec"
}

# AC3-negative
test_ac3_negative_improve_does_not_replace_test_spec() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15f2 "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15f2.md"
  printf '%s\n' "DO-NOT-REPLACE" > "$ts"
  run_init "$dir" ac14a15f2 "test" "improve"

  assert_file_contains_text "$ts" "DO-NOT-REPLACE" \
    "AC3-negative: improve preserves custom test-spec"
}

# AC3-boundary
test_ac3_boundary_fresh_mode_clears_stale_per_us_test_spec_splits() {
  local dir
  dir="$(new_tmp)"
  run_init "$dir" ac14a15f3 "test" ""

  local ts="$dir/.claude/ralph-desk/plans/test-spec-ac14a15f3.md"
  cat > "$ts" <<'TS_END'
# Test Spec: ac14a15f3
## Verification Commands
### Test
bash tests/test_us001_prd_splitting.sh

## US-001:
### L1
x
## US-002:
### L1
y
TS_END

  run_init "$dir" ac14a15f3 "test" "improve"
  local split_before
  split_before=$(ls "$dir/.claude/ralph-desk/plans/test-spec-ac14a15f3-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$split_before" 2 "AC3-boundary: improve generates per-US test-spec splits"

  printf '# Test Spec: ac14a15f3\n## Verification Commands\n### Test\nzsh -n src/scripts/init_ralph_desk.zsh\n' > "$ts"
  run_init "$dir" ac14a15f3 "test" "fresh"

  local split_after
  split_after=$(ls "$dir/.claude/ralph-desk/plans/test-spec-ac14a15f3-US-"*.md 2>/dev/null | wc -l | tr -d ' ')
  assert_eq "$split_after" 0 "AC3-boundary: fresh mode clears stale per-US split files when markers disappear"
}


test_ac1_happy_preserves_customized_test_spec_on_improve
test_ac1_negative_fresh_mode_is_not_a_noop_for_test_spec
test_ac1_boundary_markerless_spec_stays_unchanged_on_improve

test_ac2_happy_deletes_complete_sentinel_with_prd_missing
test_ac2_negative_no_complete_file_is_idempotent
test_ac2_boundary_deletes_blocked_too_when_prd_missing

test_ac3_happy_fresh_regenerates_customized_test_spec
test_ac3_negative_improve_does_not_replace_test_spec
test_ac3_boundary_fresh_mode_clears_stale_per_us_test_spec_splits

echo ""
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
if [[ $FAIL -eq 0 ]]; then
  exit 0
else
  exit 1
fi
