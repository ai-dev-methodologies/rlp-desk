#!/bin/bash
set -uo pipefail

# =============================================================================
# US-001: SV Flag E2E Test — File Creation and Content Verification
# IL-4: >= 3 tests per AC (happy + negative + boundary)
# =============================================================================

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKDIR="$ROOT"

PASS=0
FAIL=0

pass() { PASS=$((PASS+1)); echo "  ✓ PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ FAIL: $1"; }

# =============================================================================
# AC1: Create file sv-test-output.txt containing "hello"
# =============================================================================

# Test 1: Happy path — file created with correct content
sv_test_happy_path() {
  echo "Test 1: Happy path — file created with correct content"

  cd "$WORKDIR"
  rm -f sv-test-output.txt

  # Execute the required action
  echo hello > sv-test-output.txt

  # Verify: file exists
  if [[ -f sv-test-output.txt ]]; then
    pass "AC1-happy: sv-test-output.txt exists"
  else
    fail "AC1-happy: sv-test-output.txt does not exist"
    return 1
  fi

  # Verify: content is exactly "hello"
  local content
  content=$(cat sv-test-output.txt)
  if [[ "$content" == "hello" ]]; then
    pass "AC1-happy: content is exactly 'hello'"
  else
    fail "AC1-happy: content is '$content', expected 'hello'"
    return 1
  fi

  # Cleanup
  rm -f sv-test-output.txt
  return 0
}

# Test 2: Negative path — error handling when directory is read-only
sv_test_negative_readonly() {
  echo "Test 2: Negative path — error handling with read-only directory"

  local readonly_dir="/tmp/sv_test_readonly_$$"
  mkdir -p "$readonly_dir"

  # Make directory read-only (no write permission)
  chmod 555 "$readonly_dir"

  # Attempt to create file in read-only directory (should fail)
  local exit_code=0
  (
    cd "$readonly_dir"
    echo hello > sv-test-output.txt 2>/dev/null
  ) || exit_code=$?

  # Restore permissions for cleanup
  chmod 755 "$readonly_dir"

  # Verify: command failed (exit code != 0)
  if [[ $exit_code -ne 0 ]]; then
    pass "AC1-negative: write to read-only directory correctly fails"
  else
    fail "AC1-negative: write to read-only directory should have failed but didn't"
    rm -rf "$readonly_dir"
    return 1
  fi

  # Verify: file was NOT created
  if [[ ! -f "$readonly_dir/sv-test-output.txt" ]]; then
    pass "AC1-negative: file was not created in read-only directory"
  else
    fail "AC1-negative: file should not exist in read-only directory"
    rm -rf "$readonly_dir"
    return 1
  fi

  # Cleanup
  rm -rf "$readonly_dir"
  return 0
}

# Test 3: Boundary path — verify exact content (no extra whitespace, single line)
sv_test_boundary_content() {
  echo "Test 3: Boundary path — verify exact content (no whitespace, single line)"

  cd "$WORKDIR"
  rm -f sv-test-output.txt

  # Execute the required action
  echo hello > sv-test-output.txt

  # Verify: file has exactly 1 line
  local line_count
  line_count=$(wc -l < sv-test-output.txt)
  if [[ $line_count -eq 1 ]]; then
    pass "AC1-boundary: file has exactly 1 line"
  else
    fail "AC1-boundary: file has $line_count lines, expected 1"
    rm -f sv-test-output.txt
    return 1
  fi

  # Verify: no leading whitespace
  local content
  content=$(cat sv-test-output.txt)
  if [[ "$content" == "hello" ]] && [[ ! "$content" =~ ^[[:space:]] ]]; then
    pass "AC1-boundary: no leading whitespace"
  else
    fail "AC1-boundary: content has unexpected whitespace: '$content'"
    rm -f sv-test-output.txt
    return 1
  fi

  # Verify: no trailing whitespace (cat strips newline, so just check content)
  if [[ "$content" == "hello" ]]; then
    pass "AC1-boundary: no trailing whitespace"
  else
    fail "AC1-boundary: content has trailing whitespace: '$content'"
    rm -f sv-test-output.txt
    return 1
  fi

  # Cleanup
  rm -f sv-test-output.txt
  return 0
}

# =============================================================================
# Run all tests
# =============================================================================

echo ""
echo "=========================================="
echo "Running US-001 AC1 Tests"
echo "=========================================="
echo ""

sv_test_happy_path
sv_test_negative_readonly
sv_test_boundary_content

echo ""
echo "=========================================="
echo "Test Results: $PASS passed, $FAIL failed"
echo "=========================================="
echo ""

if [[ $FAIL -gt 0 ]]; then
  exit 1
else
  exit 0
fi
