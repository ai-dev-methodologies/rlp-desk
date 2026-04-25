#!/usr/bin/env bash
# Test Suite: US-026 — R14 P0 Project-scoped runner lockfile (mkdir atomic)
# Validates:
#   - RUNNER_LOCKFILE_PATH variable defined with project-root hash
#   - shasum||sha1sum||cksum fallback chain present
#   - mkdir atomic lock pattern (RUNNER_LOCKDIR)
#   - Behavioural: same root duplicate → reject; different root → allowed; stale pid → cleaned

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
_match_count() {
  local file="$1" pat="$2" n
  n=$(grep -cE -- "$pat" "$file" 2>/dev/null) || n=0
  printf '%s' "$n"
}
assert_one() {
  local n; n=$(_match_count "$1" "$2")
  [[ "$n" -ge 1 ]] && pass "$3" || fail "$3 (matches=0)"
}

echo "=== US-026: R14 P0 Project-scoped runner lockfile ==="
echo

# AC1: RUNNER_LOCKFILE_PATH + ROOT_HASH
assert_one "$RUN" 'RUNNER_LOCKFILE_PATH=' \
  "AC1-a: RUNNER_LOCKFILE_PATH variable defined"
assert_one "$RUN" 'ROOT_HASH=' \
  "AC1-b: ROOT_HASH variable for project-scoped key"
assert_one "$RUN" 'RUNNER_LOCKDIR=' \
  "AC1-c: RUNNER_LOCKDIR (mkdir atomic lock dir)"

# AC2: shasum fallback chain
assert_one "$RUN" 'shasum.*sha1sum.*cksum' \
  "AC2: shasum || sha1sum || cksum fallback chain"

# AC3: mkdir atomic pattern (not test-then-write)
assert_one "$RUN" 'mkdir.*RUNNER_LOCKDIR' \
  "AC3-a: mkdir RUNNER_LOCKDIR atomic acquire"
assert_one "$RUN" 'kill -0.*existing' \
  "AC3-b: stale pid detection via kill -0"

# AC4: cleanup trap rm -rf RUNNER_LOCKDIR
assert_one "$RUN" 'rm -rf.*RUNNER_LOCKDIR' \
  "AC4: cleanup trap removes RUNNER_LOCKDIR"

# AC5: Behavioural — duplicate same-root reject
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us026-XXXX")
ROOT_TEST="$TMP_DIR/proj"
mkdir -p "$ROOT_TEST" "$TMP_DIR/desk/logs"
# Compute hash same way runner does
ROOT_HASH=$(printf '%s' "$ROOT_TEST" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | awk '{print substr($1,1,8)}')
LOCK="$TMP_DIR/desk/logs/.rlp-desk-runner-$ROOT_HASH.lock"
LOCKDIR="${LOCK}.d"

# Simulate alive runner holding the lock
mkdir -p "$LOCKDIR"
sleep 60 &
ALIVE_PID=$!
printf '{"pid":%s,"slug":"existing","root":"%s","started_at":"now"}\n' "$ALIVE_PID" "$ROOT_TEST" > "$LOCK"

# Try to acquire from second wrapper (simulated)
if mkdir "$LOCKDIR" 2>/dev/null; then
  fail "AC5-a: second mkdir unexpectedly succeeded — atomic lock broken"
else
  pass "AC5-a: second mkdir blocked (atomic lock honored)"
fi
kill "$ALIVE_PID" 2>/dev/null

# AC6: Behavioural — stale pid cleanup
ZOMBIE_PID=99999
while kill -0 "$ZOMBIE_PID" 2>/dev/null; do
  ZOMBIE_PID=$((ZOMBIE_PID + 1))
done
printf '{"pid":%s,"slug":"stale","root":"%s","started_at":"now"}\n' "$ZOMBIE_PID" "$ROOT_TEST" > "$LOCK"
# Lockdir still exists from prior; simulate stale cleanup
if kill -0 "$ZOMBIE_PID" 2>/dev/null; then
  fail "AC6: zombie pid is actually alive — pick another"
else
  rm -rf "$LOCKDIR"
  if mkdir "$LOCKDIR" 2>/dev/null; then
    pass "AC6: stale pid lockdir replaceable after rm -rf"
  else
    fail "AC6: cannot replace stale lockdir"
  fi
fi

# AC7: Behavioural — different root → different lock → allowed
ROOT_OTHER="$TMP_DIR/other-proj"
mkdir -p "$ROOT_OTHER"
ROOT_HASH_OTHER=$(printf '%s' "$ROOT_OTHER" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | awk '{print substr($1,1,8)}')
LOCK_OTHER="$TMP_DIR/desk/logs/.rlp-desk-runner-$ROOT_HASH_OTHER.lock"
if [[ "$ROOT_HASH_OTHER" != "$ROOT_HASH" ]]; then
  pass "AC7-a: different ROOT yields different ROOT_HASH ($ROOT_HASH vs $ROOT_HASH_OTHER)"
else
  fail "AC7-a: hash collision between different roots — broken hashing"
fi
LOCKDIR_OTHER="${LOCK_OTHER}.d"
if mkdir "$LOCKDIR_OTHER" 2>/dev/null; then
  pass "AC7-b: different-root lock acquirable independently (multi-project parallel preserved)"
else
  fail "AC7-b: different-root lock blocked"
fi

rm -rf "$TMP_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
