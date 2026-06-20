#!/bin/zsh
# ============================================================================
# run-cell.zsh — assemble + run ONE matrix cell with full isolation + timeout.
#
# Usage:
#   RLP_REAL_LLM_GATE=1 ./run-cell.zsh <CELL_ID> <worker_engine> <verifier_engine> [results_dir]
#
# CELL_ID ∈ {C1,C2,C3,C4}; engines ∈ {codex,claude}.
# Every live cell is gated behind RLP_REAL_LLM_GATE=1 (real paid agents).
#
# INV-7: regenerates the main()-stripped base at gate time (no checked-in snapshot).
# INV-6/INV-8: fresh mktemp -d sandbox + distinct slug/session per cell.
# Hard timeout → BLOCKED(timeout) (never a silent hang, never PASS).
# ============================================================================
set -uo pipefail

SCRIPT_DIR="${0:A:h}"

CELL_ID="${1:?usage: run-cell.zsh <CELL_ID> <worker_engine> <verifier_engine>}"
W_ENGINE="${2:?worker engine}"
V_ENGINE="${3:?verifier engine}"
RESULTS_DIR="${4:-$SCRIPT_DIR/results}"

if [[ "${RLP_REAL_LLM_GATE:-0}" != "1" ]]; then
  print -u2 "run-cell: RLP_REAL_LLM_GATE!=1 — refusing to spend real LLM credits. (set RLP_REAL_LLM_GATE=1)"
  exit 2
fi

# --- per-engine timing / budget knobs (calibrate before freezing — openQuestion) ---
READY_BUDGET="${READY_BUDGET:-30}"
ANSWER_BUDGET="${ANSWER_BUDGET:-120}"
TIMING_FLOOR_S="${TIMING_FLOOR_S:-3}"
CELL_TIMEOUT_S="${CELL_TIMEOUT_S:-360}"
COST_BUDGET_USD="${COST_BUDGET_USD:-0.50}"   # advisory header; recorded, not enforced live

# --- fresh unique evidence dir (anti-gaming: prior-artifact rm via mktemp) ---
TS="$(date +%Y%m%d-%H%M%S)"
NONCE="$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
mkdir -p "$RESULTS_DIR"
EVID_DIR="$RESULTS_DIR/${TS}-${CELL_ID}-${NONCE}"
mkdir -p "$EVID_DIR"

# --- /tmp sandbox ROOT (INV-6): NEVER the repo; git-init'd ---
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/sv-nxm-${CELL_ID}-XXXXXX")"
( cd "$SANDBOX" && git init -q 2>/dev/null
  git config user.email sv@nxm 2>/dev/null; git config user.name sv-nxm 2>/dev/null ) || true

# --- distinct session name (INV-8), set BEFORE base load ---
INTENDED_THROWAWAY="rlp-desk-svnxm-${CELL_ID}-$$-${RANDOM}"

# --- assemble (INV-7): regenerate stripped base, append preamble + body ---
BASE="$EVID_DIR/_base.zsh"
"$SCRIPT_DIR/assemble-base.zsh" "$BASE" >/dev/null || {
  print -u2 "run-cell: base assembly (INV-7) failed for $CELL_ID"; exit 3
}
ASSEMBLED="$EVID_DIR/_assembled.zsh"
{
  cat "$BASE"
  print "\n# ===== injected isolation preamble ====="
  cat "$SCRIPT_DIR/_preamble.zsh"
  print "\n# ===== injected cell body ====="
  cat "$SCRIPT_DIR/_cell_body.zsh"
} > "$ASSEMBLED"

# --- engine-specific model defaults ---
W_MODEL="${WORKER_MODEL:-haiku}"
V_MODEL="${VERIFIER_MODEL:-haiku}"
W_CX_MODEL="${WORKER_CODEX_MODEL:-gpt-5.5}";   W_CX_R="${WORKER_CODEX_REASONING:-low}"
V_CX_MODEL="${VERIFIER_CODEX_MODEL:-gpt-5.5}"; V_CX_R="${VERIFIER_CODEX_REASONING:-low}"

print "──────────────────────────────────────────────────────────"
print "RUN CELL $CELL_ID  W=$W_ENGINE V=$V_ENGINE  sandbox=$SANDBOX"
print "  evidence=$EVID_DIR  session=$INTENDED_THROWAWAY  timeout=${CELL_TIMEOUT_S}s budget=\$$COST_BUDGET_USD"
print "──────────────────────────────────────────────────────────"

TIMEOUT_BIN="$(command -v timeout || command -v gtimeout || true)"

# Canonical env-prefixed invocation. We pre-seed SESSION_NAME so create_session's
# new-session branch uses our throwaway name (base only assigns it if unset).
CMD_ENV=(
  LOOP_NAME="svnxm-${CELL_ID}"
  ROOT="$SANDBOX"
  SESSION_NAME="$INTENDED_THROWAWAY"
  WORKER_ENGINE="$W_ENGINE" VERIFIER_ENGINE="$V_ENGINE"
  WORKER_MODEL="$W_MODEL" VERIFIER_MODEL="$V_MODEL"
  WORKER_CODEX_MODEL="$W_CX_MODEL" WORKER_CODEX_REASONING="$W_CX_R"
  VERIFIER_CODEX_MODEL="$V_CX_MODEL" VERIFIER_CODEX_REASONING="$V_CX_R"
  CELL_ID="$CELL_ID" EVID_DIR="$EVID_DIR" NONCE="$NONCE"
  INTENDED_THROWAWAY="$INTENDED_THROWAWAY"
  READY_BUDGET="$READY_BUDGET" ANSWER_BUDGET="$ANSWER_BUDGET" TIMING_FLOOR_S="$TIMING_FLOOR_S"
  CODEX_VERSION="" CLAUDE_VERSION=""
  RLP_ISOLATED=1
  # RLP_BACKGROUND=1 is MANDATORY for isolated cells: create_session's isolated
  # new-session branch only sets `destroy-unattached off` under it (run_ralph_desk
  # .zsh:901). Without it the unattached throwaway session is reaped the instant
  # split-window's transient client detaches, so WORKER_PANE points at an already
  # -destroyed pane ("can't find pane") and launch_worker_* fails L1.
  RLP_BACKGROUND=1
)

rc=0
if [[ -n "$TIMEOUT_BIN" ]]; then
  env "${CMD_ENV[@]}" "$TIMEOUT_BIN" -k 10 "$CELL_TIMEOUT_S" zsh "$ASSEMBLED" 2>&1 | tee "$EVID_DIR/cell.log"
  rc=${pipestatus[1]}
else
  env "${CMD_ENV[@]}" zsh "$ASSEMBLED" 2>&1 | tee "$EVID_DIR/cell.log"
  rc=${pipestatus[1]}
fi

# --- timeout → BLOCKED(timeout) (124=GNU timeout, 137=SIGKILL) ---
if (( rc == 124 || rc == 137 )); then
  print -u2 "run-cell: $CELL_ID TIMED OUT after ${CELL_TIMEOUT_S}s → BLOCKED(timeout)"
  jq -n --arg cell "$CELL_ID" --arg w "$W_ENGINE" --arg v "$V_ENGINE" --arg ed "$EVID_DIR" \
     '{cell_id:$cell, worker_engine:$w, verifier_engine:$v, ran:true,
       outcome:"BLOCKED", failing_rung:"timeout", evidence_dir:$ed}' \
     > "$EVID_DIR/cell-result.json"
fi

# --- defense-in-depth sweep: kill ONLY our exact throwaway session (INV-8) ---
tmux kill-session -t "$INTENDED_THROWAWAY" 2>/dev/null || true

print "run-cell: $CELL_ID rc=$rc  result=$(jq -r '.outcome // "?"' "$EVID_DIR/cell-result.json" 2>/dev/null)"
print "  evidence: $EVID_DIR"
exit $rc
