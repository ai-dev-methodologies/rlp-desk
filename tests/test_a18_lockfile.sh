#!/usr/bin/env bash
# Test suite: US-002 — Zombie Runner Lockfile Hardening
# AC1 (3) + AC2 (3) + AC3 (3) = 9 total

RUN="${RUN:-src/scripts/run_ralph_desk.zsh}"
PASS=0
FAIL=0
SLUG="a18test"

pass() { echo "  PASS: $1"; (( PASS++ )); }
fail() { echo "  FAIL: $1"; (( FAIL++ )); }

extract_fn() {
  local fn_name="$1"
  awk -v fn="$fn_name" '
    $0 ~ fn"\\(\\) \{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$RUN"
}

setup_scaffold() {
  local root="$1"
  mkdir -p "$root/.claude/ralph-desk"/{prompts,context,memos,logs,plans}
  printf '# Worker\n' > "$root/.claude/ralph-desk/prompts/${SLUG}.worker.prompt.md"
  printf '# Verifier\n' > "$root/.claude/ralph-desk/prompts/${SLUG}.verifier.prompt.md"
  printf '# Context\n' > "$root/.claude/ralph-desk/context/${SLUG}-latest.md"
  printf '# Memory\n' > "$root/.claude/ralph-desk/memos/${SLUG}-memory.md"
}

build_tmux_stub() {
  local root="$1"
  local stub_bin="$root/.a18-stub-bin"
  mkdir -p "$stub_bin"

  cat > "$stub_bin/tmux" << 'TMUX_STUB'
#!/usr/bin/env bash
cmd="$1"
shift

case "$cmd" in
  display-message)
    if [[ "${1-}" == "-p" ]]; then
      local arg="${2-}"
      if [[ "$arg" == "#{session_name}" ]]; then
        echo "rlp-desk-${LOOP_NAME}-stub"
      else
        echo "%0"
      fi
      exit 0
    fi
    echo "%0"
    exit 0
    ;;

  list-sessions|new-session|select-pane|set-option|send-keys|kill-pane|kill-session|attach-session)
    exit 0
    ;;

  split-window)
    if [[ "$*" == *"-v"* ]]; then
      echo "%2"
    else
      echo "%1"
    fi
    exit 0
    ;;
esac

exit 0
TMUX_STUB

  chmod +x "$stub_bin/tmux"
}

run_runner() {
  local root="$1"
  local out="$2"

  build_tmux_stub "$root"
  local stub_bin="$root/.a18-stub-bin"

  PATH="$stub_bin:$PATH" \
  TMUX=tmux-active \
  LOOP_NAME="$SLUG" \
  ROOT="$root" \
  MAX_ITER=1 \
  ITER_TIMEOUT=2 \
  zsh "$RUN" >"$out" 2>&1
  return $?
}

run_runner_with_complete() {
  local root="$1"
  local out="$2"
  touch "$root/.claude/ralph-desk/memos/${SLUG}-complete.md"
  run_runner "$root" "$out"
}

run_runner_with_blocked() {
  local root="$1"
  local out="$2"
  touch "$root/.claude/ralph-desk/memos/${SLUG}-blocked.md"
  run_runner "$root" "$out"
}

echo "=== US-002: Zombie Runner Lockfile Hardening ==="
echo "Target: $RUN"
echo ""

# --- AC1: running instance detection ---
echo "--- AC1: running lock detection ---"

test_ac1_happy() {
  local root out pid rc
  root="$(mktemp -d)"
  setup_scaffold "$root"

  sleep 120 &
  pid=$!
  printf '%d' "$pid" > "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac1-happy.out"
  run_runner "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 1 ]] &&
     grep -F "Another instance is already running" "$out" >/dev/null 2>&1 &&
     grep -F "Kill $pid or rm $root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock" "$out" >/dev/null 2>&1; then
    pass "AC1-happy: active runner prints pid + remediation"
  else
    fail "AC1-happy: active runner did not reject with expected message"
  fi

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$root"
}

test_ac1_negative() {
  local root out pid rc
  root="$(mktemp -d)"
  setup_scaffold "$root"

  sleep 120 &
  pid=$!
  printf '%d' "$pid" > "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac1-negative.out"
  run_runner "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 1 ]] && [[ -f "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    local lock_pid
    lock_pid="$(cat "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock")"
    if [[ "$lock_pid" == "$pid" ]]; then
      pass "AC1-negative: active lockfile is retained when denied"
    else
      fail "AC1-negative: active lockfile overwritten (was $pid, got ${lock_pid:-empty})"
    fi
  else
    fail "AC1-negative: active lockpath not retained"
  fi

  kill "$pid" >/dev/null 2>&1 || true
  wait "$pid" 2>/dev/null || true
  rm -rf "$root"
}

test_ac1_boundary() {
  local body
  body=$(extract_fn "main")
  if echo "$body" | grep -F 'if kill -0 "$lock_pid"' >/dev/null 2>&1 &&
     echo "$body" | grep -F 'Another instance is already running' >/dev/null 2>&1; then
    pass "AC1-boundary: active lockpath checks PID with kill -0"
  else
    fail "AC1-boundary: active lockpath missing kill -0 branch or message"
  fi
}

# --- AC2: stale lockfile recovery ---
echo ""
echo "--- AC2: stale lock recovery ---"

test_ac2_happy() {
  local root out rc
  root="$(mktemp -d)"
  setup_scaffold "$root"
  printf '99999' > "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac2-happy.out"
  run_runner_with_complete "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 0 ]] && grep -F 'Stale lock detected (PID 99999 not running), recovering' "$out" >/dev/null 2>&1; then
    pass "AC2-happy: stale lock logs recovery warning and proceeds"
  else
    fail "AC2-happy: stale lock recovery warning/proceed behavior missing"
  fi

  if [[ ! -f "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    pass "AC2-negative: stale lock cleanup removes stale lockfile"
  else
    fail "AC2-negative: stale lockfile remains after recovery"
  fi
}

test_ac2_negative() {
  local body
  body=$(extract_fn "main")
  if echo "$body" | grep -F 'echo $$ > "$lockfile"' >/dev/null 2>&1; then
    pass "AC2-negative: stale branch rewrites lockfile"
  else
    fail "AC2-negative: stale branch does not rewrite lockfile"
  fi
}

test_ac2_boundary() {
  local body
  body=$(extract_fn "main")
  if echo "$body" | grep -F 'Stale lock detected (PID ${lock_pid:-unknown} not running), recovering' >/dev/null 2>&1; then
    pass "AC2-boundary: stale warning message includes pid + recovering"
  else
    fail "AC2-boundary: stale warning message format changed"
  fi
}

# --- AC3: lockfile cleanup across terminal paths ---
echo ""
echo "--- AC3: lockfile cleanup ---"

test_ac3_happy() {
  local root out rc
  root="$(mktemp -d)"
  setup_scaffold "$root"

  out="$root/ac3-complete.out"
  run_runner_with_complete "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 0 ]] && [[ ! -f "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    pass "AC3-happy: COMPLETE terminal path removes lockfile"
  else
    fail "AC3-happy: COMPLETE terminal path did not remove lockfile"
  fi

  rm -rf "$root"
}

test_ac3_negative() {
  local body
  body=$(extract_fn "main")
  if echo "$body" | grep -F 'trap cleanup EXIT INT TERM' >/dev/null 2>&1; then
    pass "AC3-negative: cleanup trap includes EXIT, INT, TERM"
  else
    fail "AC3-negative: cleanup trap missing EXIT/INT/TERM"
  fi
}

test_ac3_boundary() {
  local root out rc
  root="$(mktemp -d)"
  setup_scaffold "$root"

  out="$root/ac3-blocked.out"
  run_runner_with_blocked "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 1 ]] && [[ ! -f "$root/.claude/ralph-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    pass "AC3-boundary: BLOCKED terminal path removes lockfile"
  else
    fail "AC3-boundary: BLOCKED terminal path did not remove lockfile"
  fi

  rm -rf "$root"
}

test_ac1_happy
test_ac1_negative
test_ac1_boundary
test_ac2_happy
test_ac2_negative
test_ac2_boundary
test_ac3_happy
test_ac3_negative
test_ac3_boundary

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
