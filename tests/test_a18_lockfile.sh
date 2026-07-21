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
  local file="${2:-$RUN}"
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
  ' "$file"
}

setup_scaffold() {
  local root="$1"
  # GIT-FC (IMP-09): a real campaign root is always a git repo, and the leader's
  # t0 preexisting-dirty snapshot now fail-closes (exit 1) if git is unreadable at
  # $ROOT. Model that invariant so the runner reaches its terminal paths instead
  # of the startup hard-stop. `git init` alone is enough — the scaffold files stay
  # untracked, so `git diff --name-only <empty-tree>` is a clean empty snapshot.
  git init -q "$root" 2>/dev/null
  git -C "$root" config user.email test@example.com 2>/dev/null
  git -C "$root" config user.name test 2>/dev/null
  mkdir -p "$root/.rlp-desk"/{prompts,context,memos,logs,plans}
  printf '# Worker\n' > "$root/.rlp-desk/prompts/${SLUG}.worker.prompt.md"
  printf '# Verifier\n' > "$root/.rlp-desk/prompts/${SLUG}.verifier.prompt.md"
  printf '# Context\n' > "$root/.rlp-desk/context/${SLUG}-latest.md"
  printf '# Memory\n' > "$root/.rlp-desk/memos/${SLUG}-memory.md"
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
    # US-024 R12 P0 _r12_check_lifecycle polls #{pane_dead}/#{session_name} via
    # `tmux display-message -p -t <target> '<format>'` — the format is always the
    # LAST argument, not a fixed position, so match on that instead of $2.
    # request-l: also answer the width + geometry probes so create_session's
    # _ensure_leader_pane_width and _assert_pane_geometry pass. Panes: leader=%0
    # (left col), worker=%1 / verifier=%2 (one right column, stacked top-down).
    last="${@: -1}"
    tgt=""; prev=""
    for a in "$@"; do [[ "$prev" == "-t" ]] && tgt="$a"; prev="$a"; done
    case "$last" in
      '#{session_name}') echo "rlp-desk-${LOOP_NAME}-stub" ;;
      '#{pane_dead}') echo "0" ;;
      '#{window_id}') echo "@0" ;;
      '#{pane_width}') echo "200" ;;
      '#{pane_left}') case "$tgt" in %1|%2) echo "100" ;; *) echo "0" ;; esac ;;
      '#{pane_top}')  case "$tgt" in %2) echo "25" ;; *) echo "0" ;; esac ;;
      *) echo "%0" ;;
    esac
    exit 0
    ;;

  resize-pane)
    exit 0
    ;;

  list-sessions|new-session|select-pane|set-option|send-keys|kill-pane|kill-session|attach-session|has-session)
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
  touch "$root/.rlp-desk/memos/${SLUG}-complete.md"
  run_runner "$root" "$out"
}

run_runner_with_blocked() {
  local root="$1"
  local out="$2"
  touch "$root/.rlp-desk/memos/${SLUG}-blocked.md"
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
  printf '%d' "$pid" > "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac1-happy.out"
  run_runner "$root" "$out"
  rc=$?

  # ZSH-4 lock redesign (commit 88aa034) reworded the message: it no longer
  # echoes the pid in "Kill $pid or rm ..." — it now says "Kill it or rm ...".
  if [[ "$rc" -eq 1 ]] &&
     grep -F "Another instance is already running" "$out" >/dev/null 2>&1 &&
     grep -F "Kill it or rm $root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock" "$out" >/dev/null 2>&1; then
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
  printf '%d' "$pid" > "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac1-negative.out"
  run_runner "$root" "$out"
  rc=$?

  if [[ "$rc" -eq 1 ]] && [[ -f "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    local lock_pid
    lock_pid="$(cat "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock")"
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
  # ZSH-4 lock redesign (commit 88aa034) moved the live-PID check out of main()
  # and into acquire_slug_lock() (lib_ralph_desk.zsh); main() only reports the
  # failure once acquire_slug_lock returns non-zero. Check both halves.
  local main_body lock_body
  main_body=$(extract_fn "main")
  lock_body=$(extract_fn "acquire_slug_lock" "$(dirname "$RUN")/lib_ralph_desk.zsh")
  if echo "$lock_body" | grep -F 'kill -0 "$lock_pid"' >/dev/null 2>&1 &&
     echo "$main_body" | grep -F 'Another instance is already running' >/dev/null 2>&1; then
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
  printf '99999' > "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock"

  out="$root/ac2-happy.out"
  run_runner_with_complete "$root" "$out"
  rc=$?

  # ZSH-4 lock redesign (commit 88aa034) removed the old "Stale lock detected"
  # log line — acquire_slug_lock() (lib_ralph_desk.zsh) now recovers a
  # dead-owner lock silently under a race-safe mkdir mutex. The observable
  # contract is behavioral: a lock held by a non-running PID must NOT block
  # the runner, and the campaign must proceed to completion.
  if [[ "$rc" -eq 0 ]] &&
     ! grep -F "Another instance is already running" "$out" >/dev/null 2>&1; then
    pass "AC2-happy: stale lock (dead PID) does not block and campaign proceeds"
  else
    fail "AC2-happy: stale lock recovery/proceed behavior missing"
  fi

  if [[ ! -f "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    pass "AC2-negative: stale lock cleanup removes stale lockfile"
  else
    fail "AC2-negative: stale lockfile remains after recovery"
  fi
}

test_ac2_negative() {
  # ZSH-4 lock redesign moved the rewrite out of main() and into
  # acquire_slug_lock() (lib_ralph_desk.zsh).
  local body
  body=$(extract_fn "acquire_slug_lock" "$(dirname "$RUN")/lib_ralph_desk.zsh")
  if echo "$body" | grep -F 'echo $$ > "$lockfile"' >/dev/null 2>&1; then
    pass "AC2-negative: stale branch rewrites lockfile"
  else
    fail "AC2-negative: stale branch does not rewrite lockfile"
  fi
}

test_ac2_boundary() {
  # The old exact "Stale lock detected ... recovering" log line is gone. The
  # current boundary is structural: a dead-owner lock is recovered under a
  # dedicated recovery mutex (not blindly clobbered by every contender).
  local body
  body=$(extract_fn "acquire_slug_lock" "$(dirname "$RUN")/lib_ralph_desk.zsh")
  if echo "$body" | grep -F 'rmutex="${lockfile}.recovery.d"' >/dev/null 2>&1 &&
     echo "$body" | grep -F 'mkdir "$rmutex"' >/dev/null 2>&1; then
    pass "AC2-boundary: stale (dead-owner) lock recovery is serialized under a dedicated mutex"
  else
    fail "AC2-boundary: stale-lock recovery mutex boundary missing"
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

  if [[ "$rc" -eq 0 ]] && [[ ! -f "$root/.rlp-desk/logs/.rlp-desk-${SLUG}.lock" ]]; then
    pass "AC3-happy: COMPLETE terminal path removes lockfile"
  else
    fail "AC3-happy: COMPLETE terminal path did not remove lockfile"
  fi

  rm -rf "$root"
}

test_ac3_negative() {
  # US-023 R11 P2-K chained `_emit_final_cost_log` ahead of `cleanup` in the
  # trap body, so the exact old literal 'trap cleanup EXIT INT TERM' is gone;
  # cleanup is still trapped on EXIT/INT/TERM, just via a compound command.
  local body
  body=$(extract_fn "main")
  if echo "$body" | grep -E "trap '.*cleanup' EXIT INT TERM" >/dev/null 2>&1; then
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
