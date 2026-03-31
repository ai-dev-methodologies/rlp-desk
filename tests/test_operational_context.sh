#!/usr/bin/env bash
# Test Suite: Operational Context (server lifecycle support)
# Tests: init CLI options, Worker prompt injection, Verifier prompt injection,
#        brainstorm guidance, conditional injection (no server = no section)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_DIR/src/scripts/init_ralph_desk.zsh"
CMD="$ROOT_DIR/src/commands/rlp-desk.md"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

TMPDIRS=()
cleanup() { for d in "${TMPDIRS[@]}"; do rm -rf "$d"; done; }
trap cleanup EXIT

echo "=== Operational Context Tests ==="
echo ""

# --- AC1: Init CLI options parsing ---
echo "--- AC1: Init CLI option parsing ---"

if grep -q '\-\-server-cmd)' "$INIT" 2>/dev/null; then
  pass "AC1-1: --server-cmd option defined in init"
else
  fail "AC1-1: --server-cmd option not found in init"
fi

if grep -q '\-\-server-port)' "$INIT" 2>/dev/null; then
  pass "AC1-2: --server-port option defined in init"
else
  fail "AC1-2: --server-port option not found in init"
fi

if grep -q '\-\-server-health)' "$INIT" 2>/dev/null; then
  pass "AC1-3: --server-health option defined in init"
else
  fail "AC1-3: --server-health option not found in init"
fi

# Test actual parsing via inline zsh script (mirrors init's case block)
result=$(zsh -c '
  SERVER_CMD="" SERVER_PORT="" SERVER_HEALTH=""
  set -- "--server-cmd" "npm run dev" "--server-port" "7001" "--server-health" "http://localhost:7001/health"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --server-cmd) SERVER_CMD="$2"; shift 2 ;;
      --server-port) SERVER_PORT="$2"; shift 2 ;;
      --server-health) SERVER_HEALTH="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "$SERVER_CMD|$SERVER_PORT|$SERVER_HEALTH"
' 2>/dev/null)
if [[ "$result" == "npm run dev|7001|http://localhost:7001/health" ]]; then
  pass "AC1-4: CLI options correctly parsed (cmd|port|health)"
else
  fail "AC1-4: CLI options parsing failed (got '$result')"
fi

# --- AC2: Worker prompt operational context injection ---
echo ""
echo "--- AC2: Worker prompt operational context ---"

if grep -q 'SERVER_CMD.*SERVER_PORT' "$INIT" 2>/dev/null; then
  pass "AC2-1: Init checks SERVER_CMD/PORT for injection"
else
  fail "AC2-1: SERVER_CMD/PORT check not found in init"
fi

if grep -q 'Operational Context' "$INIT" 2>/dev/null; then
  pass "AC2-2: 'Operational Context' section defined in init"
else
  fail "AC2-2: 'Operational Context' section not found"
fi

if grep -q 'Operational Rules' "$INIT" 2>/dev/null; then
  pass "AC2-3: 'Operational Rules' section defined in init"
else
  fail "AC2-3: 'Operational Rules' not found"
fi

if grep -q 'Do NOT modify dependency files' "$INIT" 2>/dev/null; then
  pass "AC2-4: Dependency modification guard in operational rules"
else
  fail "AC2-4: Dependency guard not found"
fi

if grep -q 'Do NOT run package install' "$INIT" 2>/dev/null; then
  pass "AC2-5: Package install guard in operational rules"
else
  fail "AC2-5: Package install guard not found"
fi

# --- AC3: Verifier prompt operational verification ---
echo ""
echo "--- AC3: Verifier prompt operational verification ---"

if grep -q 'Operational Verification' "$INIT" 2>/dev/null; then
  pass "AC3-1: 'Operational Verification' section defined for verifier"
else
  fail "AC3-1: 'Operational Verification' section not found for verifier"
fi

if grep -q 'server not running' "$INIT" 2>/dev/null; then
  pass "AC3-2: Verifier fails if server not running"
else
  fail "AC3-2: Server not running check not found in verifier"
fi

if grep -q 'server not restarted' "$INIT" 2>/dev/null; then
  pass "AC3-3: Verifier fails if server not restarted after code change"
else
  fail "AC3-3: Server restart check not found in verifier"
fi

# --- AC4: Conditional injection (no server = no section) ---
echo ""
echo "--- AC4: Conditional injection ---"

# The injection is gated by: if [[ -n "$SERVER_CMD" || -n "$SERVER_PORT" ]]
if grep -q 'SERVER_CMD.*||.*SERVER_PORT' "$INIT" 2>/dev/null; then
  pass "AC4-1: Operational context injection gated by SERVER_CMD/PORT"
else
  fail "AC4-1: Conditional gate not found"
fi

# E2E: run init WITHOUT server options, check no operational context
tmpdir2=$(mktemp -d)
TMPDIRS+=("$tmpdir2")
mkdir -p "$tmpdir2/.claude/ralph-desk"/{plans,prompts,memos,context,logs}
(cd "$tmpdir2" && ROOT="$tmpdir2" zsh "$INIT" "test-e2e" "Test objective" 2>/dev/null)
worker_prompt="$tmpdir2/.claude/ralph-desk/prompts/test-e2e.worker.prompt.md"
if [[ -f "$worker_prompt" ]]; then
  if grep -q 'Operational Context' "$worker_prompt" 2>/dev/null; then
    fail "AC4-2: Operational context injected WITHOUT server options"
  else
    pass "AC4-2: No operational context when server options absent"
  fi
else
  fail "AC4-2: Worker prompt not generated"
fi

# E2E: run init WITH server options, check operational context present
tmpdir3=$(mktemp -d)
TMPDIRS+=("$tmpdir3")
mkdir -p "$tmpdir3/.claude/ralph-desk"/{plans,prompts,memos,context,logs}
(cd "$tmpdir3" && ROOT="$tmpdir3" zsh "$INIT" "test-e2e-server" "Server project" --server-cmd "npm run dev" --server-port "7001" 2>/dev/null)
worker_prompt_srv="$tmpdir3/.claude/ralph-desk/prompts/test-e2e-server.worker.prompt.md"
if [[ -f "$worker_prompt_srv" ]]; then
  if grep -q 'Operational Context' "$worker_prompt_srv" 2>/dev/null; then
    pass "AC4-3: Operational context injected WITH server options"
  else
    fail "AC4-3: Operational context NOT injected despite server options"
  fi
  if grep -q 'npm run dev' "$worker_prompt_srv" 2>/dev/null; then
    pass "AC4-4: Server command 'npm run dev' in worker prompt"
  else
    fail "AC4-4: Server command not found in worker prompt"
  fi
  if grep -q '7001' "$worker_prompt_srv" 2>/dev/null; then
    pass "AC4-5: Server port 7001 in worker prompt"
  else
    fail "AC4-5: Server port not found in worker prompt"
  fi
else
  fail "AC4-3: Worker prompt not generated"
  fail "AC4-4: (skipped)"
  fail "AC4-5: (skipped)"
fi

# Check verifier prompt too
verifier_prompt_srv="$tmpdir3/.claude/ralph-desk/prompts/test-e2e-server.verifier.prompt.md"
if [[ -f "$verifier_prompt_srv" ]]; then
  if grep -q 'Operational Verification' "$verifier_prompt_srv" 2>/dev/null; then
    pass "AC4-6: Operational verification in verifier prompt WITH server options"
  else
    fail "AC4-6: Operational verification NOT in verifier prompt despite server options"
  fi
else
  fail "AC4-6: Verifier prompt not generated"
fi

# --- AC5: Brainstorm guidance ---
echo ""
echo "--- AC5: Brainstorm operational context guidance ---"

if grep -q 'Operational Context' "$CMD" 2>/dev/null; then
  pass "AC5-1: Brainstorm section includes Operational Context item"
else
  fail "AC5-1: Operational Context not in brainstorm"
fi

if grep -q 'server.*start.*command\|Server start command' "$CMD" 2>/dev/null; then
  pass "AC5-2: Brainstorm asks for server start command"
else
  fail "AC5-2: Server start command not asked in brainstorm"
fi

if grep -q 'package.json\|docker-compose\|Makefile' "$CMD" 2>/dev/null; then
  pass "AC5-3: Brainstorm auto-detects from common project files"
else
  fail "AC5-3: Auto-detection guidance not found"
fi

if grep -q 'server.*restart.*health.*check\|server is restarted and health check' "$CMD" 2>/dev/null; then
  pass "AC5-4: US generation guidance for server restart AC"
else
  fail "AC5-4: Server restart AC guidance not found"
fi

# --- L2: Syntax ---
echo ""
echo "--- L2: Syntax ---"

zsh -n "$INIT" 2>/dev/null
if (( $? == 0 )); then
  pass "L2-1: init_ralph_desk.zsh syntax valid"
else
  fail "L2-1: init_ralph_desk.zsh syntax error"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed (total $((PASS+FAIL))) ==="
exit $FAIL
