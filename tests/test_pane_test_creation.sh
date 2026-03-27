#!/bin/bash
# Test file for pane-test creation (US-001)
# Tests verify that create_pane_test_file() creates /tmp/pane-test.txt with correct content

set -e

TEST_FILE="/tmp/pane-test.txt"
PASS_COUNT=0
FAIL_COUNT=0

# Source the function to test
source "$(dirname "$0")/../src/lib/create-pane-test-file.sh"

# Helper: cleanup
cleanup() {
  rm -f "$TEST_FILE"
}

# Helper: assert_file_exists
assert_file_exists() {
  if [ ! -f "$1" ]; then
    echo "FAIL: File does not exist: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  return 0
}

# Helper: assert_file_not_exists
assert_file_not_exists() {
  if [ -f "$1" ]; then
    echo "FAIL: File should not exist: $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  return 0
}

# Helper: assert_file_content
assert_file_content() {
  local file=$1
  local expected=$2
  local actual
  actual=$(cat "$file" 2>/dev/null || echo "")
  if [ "$actual" != "$expected" ]; then
    echo "FAIL: Content mismatch. Expected: '$expected', Got: '$actual'"
    FAIL_COUNT=$((FAIL_COUNT + 1))
    return 1
  fi
  return 0
}

echo "=== AC1 Test Suite ==="

# TEST 1: Negative - File should not exist initially
echo "TEST 1: Negative - Pre-condition check"
cleanup
assert_file_not_exists "$TEST_FILE" && {
  echo "PASS: Test 1 - File does not exist before creation"
  PASS_COUNT=$((PASS_COUNT + 1))
} || true

# TEST 2: Happy Path - Function creates file with correct content
echo "TEST 2: Happy Path - Function execution"
cleanup
create_pane_test_file
assert_file_exists "$TEST_FILE" && assert_file_content "$TEST_FILE" "test" && {
  echo "PASS: Test 2 - Function created file with correct content"
  PASS_COUNT=$((PASS_COUNT + 1))
} || true

# TEST 3: Boundary - Exact content (no extra whitespace/newlines in content check)
echo "TEST 3: Boundary - Content exactness"
cleanup
create_pane_test_file
actual_content=$(cat "$TEST_FILE")
actual_length=${#actual_content}
if [ "$actual_length" -eq 4 ] && [ "$actual_content" = "test" ]; then
  echo "PASS: Test 3 - Content is exactly 'test' (4 chars)"
  PASS_COUNT=$((PASS_COUNT + 1))
else
  echo "FAIL: Test 3 - Content length is $actual_length, expected 4"
  FAIL_COUNT=$((FAIL_COUNT + 1))
fi

# Cleanup
cleanup

# Summary
echo ""
echo "=== Test Summary ==="
echo "PASSED: $PASS_COUNT"
echo "FAILED: $FAIL_COUNT"
echo "TOTAL:  $((PASS_COUNT + FAIL_COUNT))"

if [ $FAIL_COUNT -eq 0 ]; then
  exit 0
else
  exit 1
fi
