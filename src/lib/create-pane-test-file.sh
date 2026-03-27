#!/bin/bash
# create-pane-test-file: Create the test file for pane-test verification
# This function creates /tmp/pane-test.txt with content "test"
# Used by US-001 acceptance criteria

create_pane_test_file() {
  echo test > /tmp/pane-test.txt
}

# Allow sourcing or direct execution
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  create_pane_test_file
fi
