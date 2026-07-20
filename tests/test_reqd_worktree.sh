#!/usr/bin/env zsh
# Test Suite: request-d ② campaign worktree isolation + ①-b zsh gate-receipt.
# Exercises the setup helpers directly against a scratch git repo (no tmux) —
# the worktree setup is gated BEFORE session creation, so the helper is testable
# in isolation.

ROOT_REPO="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_REPO/src/scripts/lib_ralph_desk.zsh"

PASS=0
FAIL=0
pass() { PASS=$((PASS+1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

source "$LIB" 2>/dev/null
# neutralize logging helpers if lib defines them (they don't matter here)
log() { :; }
log_error() { :; }

echo "=== request-d ②/①-b: worktree + gate-receipt (zsh) ==="
echo

# ---------------------------------------------------------------------------
# Fixture: scratch git repo with a .rlp-desk scaffold
# ---------------------------------------------------------------------------
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/rlp-reqd-wt-XXXX")
trap "rm -rf '$SCRATCH'" EXIT
(
  cd "$SCRATCH"
  git init -q
  git config user.email t@example.com
  git config user.name test
  echo "seed" > seed.txt
  git add seed.txt
  git commit -qm "init"
)
mkdir -p "$SCRATCH/.rlp-desk/plans" "$SCRATCH/.rlp-desk/prompts" \
         "$SCRATCH/.rlp-desk/context" "$SCRATCH/.rlp-desk/memos"
echo "prd body" > "$SCRATCH/.rlp-desk/plans/prd-wt.md"
echo "us1"      > "$SCRATCH/.rlp-desk/plans/prd-wt-US-001.md"
echo "worker"   > "$SCRATCH/.rlp-desk/prompts/wt.worker.prompt.md"

# ---------------------------------------------------------------------------
# AC1: setup_campaign_worktree creates a worktree on branch campaign/<slug>
# ---------------------------------------------------------------------------
WT=$(setup_campaign_worktree "$SCRATCH" "wt" ".rlp-desk" 2>/dev/null)
if [[ -n "$WT" && -d "$WT" ]]; then
  pass "AC1-a: worktree path returned and directory exists ($WT)"
else
  fail "AC1-a: no worktree created (got '$WT')"
fi
if [[ "$WT" == "$SCRATCH/.rlp-desk/worktrees/wt" ]]; then
  pass "AC1-b: worktree lives under <root>/.rlp-desk/worktrees/<slug>"
else
  fail "AC1-b: unexpected worktree path '$WT'"
fi
wt_branch=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
if [[ "$wt_branch" == "campaign/wt" ]]; then
  pass "AC1-c: worktree is on branch campaign/wt"
else
  fail "AC1-c: worktree branch is '$wt_branch'"
fi

# ---------------------------------------------------------------------------
# AC2: the .rlp-desk scaffold is copied into the worktree
# ---------------------------------------------------------------------------
if [[ -f "$WT/.rlp-desk/plans/prd-wt.md" && -f "$WT/.rlp-desk/plans/prd-wt-US-001.md" \
      && -f "$WT/.rlp-desk/prompts/wt.worker.prompt.md" ]]; then
  pass "AC2-a: plans + prompts scaffold copied into the worktree"
else
  fail "AC2-a: scaffold not fully copied"
fi
# worktrees/ must NOT be recursively copied into itself
if [[ ! -e "$WT/.rlp-desk/worktrees" ]]; then
  pass "AC2-b: worktrees/ dir not recursively copied"
else
  fail "AC2-b: worktrees/ was copied (recursion risk)"
fi

# ---------------------------------------------------------------------------
# AC3: idempotent reuse — a second call returns the same path, no error
# ---------------------------------------------------------------------------
WT2=$(setup_campaign_worktree "$SCRATCH" "wt" ".rlp-desk" 2>/dev/null)
if [[ "$WT2" == "$WT" && -d "$WT2" ]]; then
  pass "AC3: second call reuses the existing worktree (idempotent)"
else
  fail "AC3: reuse returned '$WT2' (expected '$WT')"
fi

# ---------------------------------------------------------------------------
# AC4: non-git origin → fallback (empty return, non-zero) so caller runs in-place
# ---------------------------------------------------------------------------
NONGIT=$(mktemp -d "${TMPDIR:-/tmp}/rlp-reqd-nongit-XXXX")
WT_NONE=$(setup_campaign_worktree "$NONGIT" "x" ".rlp-desk" 2>/dev/null)
rc=$?
if [[ -z "$WT_NONE" && "$rc" -ne 0 ]]; then
  pass "AC4: non-git origin falls back (empty path, non-zero return)"
else
  fail "AC4: expected fallback, got path='$WT_NONE' rc=$rc"
fi
rm -rf "$NONGIT"

# ---------------------------------------------------------------------------
# AC5: gate-receipt zsh helpers — ok / mismatch / missing
# ---------------------------------------------------------------------------
PLANS="$SCRATCH/.rlp-desk/plans"
# Seal a receipt matching the current PRD hash.
LIVE=$(compute_prd_content_hash "$PLANS" "wt")
cat > "$PLANS/gate-receipt-wt.json" <<JSON
{ "schema_version": "1.0", "slug": "wt", "prd_sha256": "$LIVE",
  "scorecard": "PASS:1", "passed_at": "2026-07-20T00:00:00Z" }
JSON
[[ "$(verify_gate_receipt "$PLANS" "wt")" == "ok" ]] \
  && pass "AC5-a: verify=ok when receipt matches" \
  || fail "AC5-a: expected ok"
echo "edit" >> "$PLANS/prd-wt-US-001.md"
[[ "$(verify_gate_receipt "$PLANS" "wt")" == "mismatch" ]] \
  && pass "AC5-b: verify=mismatch after a PRD edit" \
  || fail "AC5-b: expected mismatch"
rm -f "$PLANS/gate-receipt-wt.json"
[[ "$(verify_gate_receipt "$PLANS" "wt")" == "missing" ]] \
  && pass "AC5-c: verify=missing without a receipt" \
  || fail "AC5-c: expected missing"

# ---------------------------------------------------------------------------
# AC6: empty PRD set → empty hash (no main PRD)
# ---------------------------------------------------------------------------
EMPTY=$(mktemp -d "${TMPDIR:-/tmp}/rlp-reqd-empty-XXXX")
mkdir -p "$EMPTY/plans"
[[ -z "$(compute_prd_content_hash "$EMPTY/plans" "none")" ]] \
  && pass "AC6: no main PRD → empty content hash" \
  || fail "AC6: expected empty hash"
rm -rf "$EMPTY"

echo
echo "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
