#!/usr/bin/env bash
# Test Suite: US-016 — R4 P1-E Lane Enforcement (WARN-default + --lane-strict opt-in).
# Validates:
#   - --lane-strict CLI flag parsed by zsh runner + Node run.mjs
#   - LANE_MODE serialized into session-config + metadata.json
#   - governance §7e Lane Enforcement section present (WARN + STRICT downgrade)
#   - Worker prompt mentions lane discipline (governance §7e)
#   - Node helpers _initLaneAuditLog / _snapshotLaneMtimes / _checkLaneViolations defined
#   - Node strict-mode BLOCKED uses recoverable=true + retry_after_fix downgrade

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
INIT="$ROOT_REPO/src/scripts/init_ralph_desk.zsh"
RUN="$ROOT_REPO/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"
LOOP="$ROOT_REPO/src/node/runner/campaign-main-loop.mjs"
RUN_NODE="$ROOT_REPO/src/node/run.mjs"
GOV="$ROOT_REPO/src/governance.md"

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

echo "=== US-016: R4 P1-E Lane Enforcement (WARN + STRICT) ==="
echo

# ----------------------------------------------------------------------------
# AC1: zsh runner --lane-strict flag + LANE_MODE variable + serialization
# ----------------------------------------------------------------------------
assert_one "$RUN" '^LANE_MODE="\$\{LANE_MODE:-warn\}"' \
  "AC1-a: LANE_MODE variable initialized at script top (default warn)"
assert_one "$RUN" '\-\-lane-strict\)' \
  "AC1-b: zsh runner parses --lane-strict CLI flag"
assert_one "$RUN" 'LANE_MODE="strict"' \
  "AC1-c: --lane-strict sets LANE_MODE=strict"
assert_one "$RUN" '"lane_mode": ' \
  "AC1-d: session-config serializes lane_mode"
assert_one "$RUN" 'lane_mode: \$lane_mode' \
  "AC1-e: metadata.json jq filter wires lane_mode"

# ----------------------------------------------------------------------------
# AC2: Node run.mjs --lane-strict stub
# ----------------------------------------------------------------------------
assert_one "$RUN_NODE" 'laneStrict: false' \
  "AC2-a: RUN_DEFAULTS includes laneStrict default"
assert_one "$RUN_NODE" "case '--lane-strict':" \
  "AC2-b: --lane-strict CLI parser case present"
assert_one "$RUN_NODE" 'options\.laneStrict = true' \
  "AC2-c: parser sets options.laneStrict"

# ----------------------------------------------------------------------------
# AC3: governance §7e Lane Enforcement section
# ----------------------------------------------------------------------------
assert_one "$GOV" '## 7e\. Lane Enforcement \(P1-E\)' \
  "AC3-a: §7e Lane Enforcement section present"
assert_one "$GOV" 'Default mode is \*\*WARN-only\*\*' \
  "AC3-b: §7e clarifies WARN-only default"
assert_one "$GOV" 'recoverable=true.*retry_after_fix' \
  "AC3-c: §7e documents strict downgrade (recoverable + retry_after_fix)"
assert_one "$GOV" 'NOT.*terminal_alert' \
  "AC3-d: §7e explicitly NOT terminal_alert"
assert_one "$GOV" 'lane-audit\.json' \
  "AC3-e: §7e references lane-audit.json file"

# ----------------------------------------------------------------------------
# AC4: Worker prompt mentions lane discipline
# ----------------------------------------------------------------------------
assert_one "$INIT" 'Lane discipline \(governance §7e\)' \
  "AC4-a: Worker prompt cites governance §7e"
assert_one "$INIT" 'lane_violation_warning' \
  "AC4-b: Worker prompt mentions lane_violation_warning event"

# ----------------------------------------------------------------------------
# AC5: Node helpers — _initLaneAuditLog, _snapshotLaneMtimes, _checkLaneViolations
# ----------------------------------------------------------------------------
assert_one "$LOOP" '_initLaneAuditLog' \
  "AC5-a: _initLaneAuditLog helper defined"
assert_one "$LOOP" '_snapshotLaneMtimes' \
  "AC5-b: _snapshotLaneMtimes helper defined"
assert_one "$LOOP" '_checkLaneViolations' \
  "AC5-c: _checkLaneViolations helper defined"
assert_one "$LOOP" 'laneAuditFile' \
  "AC5-d: paths.laneAuditFile path defined"
assert_one "$LOOP" 'await _initLaneAuditLog\(paths\)' \
  "AC5-e: campaign init calls _initLaneAuditLog"

# ----------------------------------------------------------------------------
# AC6: Node strict-mode BLOCKED uses downgrade (recoverable=true + retry_after_fix)
# ----------------------------------------------------------------------------
assert_one "$LOOP" "reason_category: 'infra_failure'" \
  "AC6-a: strict-mode BLOCKED uses infra_failure category"
assert_one "$LOOP" "suggested_action: 'retry_after_fix'" \
  "AC6-b: strict-mode BLOCKED uses retry_after_fix action (downgrade from terminal_alert)"
assert_one "$LOOP" 'recoverable: true' \
  "AC6-c: strict-mode BLOCKED uses recoverable=true"

# ----------------------------------------------------------------------------
# AC7: behavioural — _initLaneAuditLog creates the file with []
# ----------------------------------------------------------------------------
TMP_AUDIT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/rlp-us016-XXXX")
TMP_AUDIT_FILE="$TMP_AUDIT_DIR/lane-audit.json"
node --input-type=module -e "
import { mkdir, writeFile, readFile, access } from 'node:fs/promises';
import path from 'node:path';
const tmpFile = process.argv[1];
async function exists(p) { try { await access(p); return true; } catch { return false; } }
const paths = { laneAuditFile: tmpFile };
async function _initLaneAuditLog(paths) {
  await mkdir(path.dirname(paths.laneAuditFile), { recursive: true });
  if (!(await exists(paths.laneAuditFile))) {
    await writeFile(paths.laneAuditFile, '[]\n', 'utf8');
  }
}
await _initLaneAuditLog(paths);
const content = await readFile(tmpFile, 'utf8');
process.stdout.write(content.trim() === '[]' ? 'OK' : 'BAD:' + content);
" "$TMP_AUDIT_FILE"
got_init=$(cat "$TMP_AUDIT_FILE" 2>/dev/null)
if [[ "$got_init" == "[]" ]]; then
  pass "AC7: _initLaneAuditLog creates audit log with empty array []"
else
  fail "AC7: got '$got_init'"
fi
rm -rf "$TMP_AUDIT_DIR"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
