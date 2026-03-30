#!/bin/zsh
set -uo pipefail
# NOTE: We use set -u (undefined var check) and pipefail, but NOT set -e
# because the main loop uses explicit error checks throughout.

# =============================================================================
# Ralph Desk Tmux Runner
#
# Implements the Leader loop from governance.md section 7 as a shell script.
# Uses tmux proven patterns: write-then-notify, pane IDs (%N),
# copy-mode guards, verification-based retry, heartbeat monitoring,
# idle pane nudging, exponential backoff restarts, atomic file writes.
#
# Usage:
#   LOOP_NAME=<slug> ./run_ralph_desk.zsh
#
# Required env:
#   LOOP_NAME     - slug identifier for the campaign
#
# Optional env:
#   ROOT                      - project root (default: $PWD)
#   MAX_ITER                  - max iterations (default: 20)
#   WORKER_MODEL              - claude model for Worker (default: sonnet)
#   VERIFIER_MODEL            - claude model for Verifier (default: opus)
#   POLL_INTERVAL             - seconds between signal checks (default: 5)
#   ITER_TIMEOUT              - per-iteration timeout in seconds (default: 600)
#   HEARTBEAT_STALE_THRESHOLD - seconds before heartbeat is stale (default: 120)
#   MAX_RESTARTS              - max restart attempts per worker (default: 3)
#   IDLE_NUDGE_THRESHOLD      - seconds of idle before nudge (default: 30)
#   MAX_NUDGES                - max nudges per pane per iteration (default: 3)
#
# Per-role codex config:
#   WORKER_CODEX_MODEL            - codex model for Worker (default: gpt-5.4)
#   WORKER_CODEX_REASONING        - codex reasoning for Worker (default: high)
#   VERIFIER_CODEX_MODEL          - codex model for Verifier (default: gpt-5.4)
#   VERIFIER_CODEX_REASONING      - codex reasoning for Verifier (default: high)
#
# Consensus scope:
#   CONSENSUS_SCOPE               - when consensus applies (default: all)
#                                   all=every verify, final-only=final ALL only
#
# Dependencies: tmux, claude CLI, jq
# Optional: codex CLI (required when WORKER_ENGINE=codex, VERIFIER_ENGINE=codex, or VERIFY_CONSENSUS=1)
# =============================================================================

# --- Environment Variables ---
SLUG="${LOOP_NAME:?ERROR: LOOP_NAME is required. Set it to the campaign slug.}"
ROOT="${ROOT:-$PWD}"
MAX_ITER="${MAX_ITER:-20}"
WORKER_MODEL="${WORKER_MODEL:-sonnet}"
VERIFIER_MODEL="${VERIFIER_MODEL:-opus}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ITER_TIMEOUT="${ITER_TIMEOUT:-600}"
HEARTBEAT_STALE_THRESHOLD="${HEARTBEAT_STALE_THRESHOLD:-120}"
MAX_RESTARTS="${MAX_RESTARTS:-3}"
IDLE_NUDGE_THRESHOLD="${IDLE_NUDGE_THRESHOLD:-30}"
MAX_NUDGES="${MAX_NUDGES:-3}"
WITH_SELF_VERIFICATION="${WITH_SELF_VERIFICATION:-0}"

# --- Engine Selection ---
WORKER_ENGINE="${WORKER_ENGINE:-claude}"    # claude|codex
VERIFIER_ENGINE="${VERIFIER_ENGINE:-claude}"  # claude|codex
WORKER_CODEX_MODEL="${WORKER_CODEX_MODEL:-gpt-5.4}"
WORKER_CODEX_REASONING="${WORKER_CODEX_REASONING:-high}"   # low|medium|high
VERIFIER_CODEX_MODEL="${VERIFIER_CODEX_MODEL:-gpt-5.4}"
VERIFIER_CODEX_REASONING="${VERIFIER_CODEX_REASONING:-high}"   # low|medium|high
CODEX_BIN=""  # resolved by check_dependencies when engine=codex

# --- Verify Mode ---
VERIFY_MODE="${VERIFY_MODE:-per-us}"        # per-us|batch
VERIFY_CONSENSUS="${VERIFY_CONSENSUS:-0}"   # 0|1
FINAL_CONSENSUS="${FINAL_CONSENSUS:-0}"     # 0|1 — consensus for final ALL verify only (independent of VERIFY_CONSENSUS)
CONSENSUS_SCOPE="${CONSENSUS_SCOPE:-all}"   # all|final-only
CB_THRESHOLD="${CB_THRESHOLD:-3}"           # consecutive failures before BLOCKED (default: 3)
# Effective CB threshold: doubled when consensus mode active (AC2 auto-double)
if [[ "${VERIFY_CONSENSUS:-0}" = "1" ]]; then
  EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD * 2 ))
else
  EFFECTIVE_CB_THRESHOLD=$CB_THRESHOLD
fi
_API_MAX_RETRIES="${_API_MAX_RETRIES:-5}"
_API_RETRY_INTERVAL_S="${_API_RETRY_INTERVAL_S:-30}"

# --- Derived Paths ---
DESK="$ROOT/.claude/ralph-desk"
PROMPTS_DIR="$DESK/prompts"
CONTEXT_DIR="$DESK/context"
MEMOS_DIR="$DESK/memos"
LOGS_DIR="$DESK/logs/$SLUG"
PRD_FILE="$DESK/plans/prd-$SLUG.md"
TEST_SPEC_FILE="$DESK/plans/test-spec-$SLUG.md"
# --- Analytics Directory (user-level, cross-project) ---
ANALYTICS_SLUG_HASH=$(echo -n "$ROOT" | md5 -q 2>/dev/null || md5sum <<< "$ROOT" | cut -d' ' -f1)
ANALYTICS_DIR="$HOME/.claude/ralph-desk/analytics/${SLUG}--${ANALYTICS_SLUG_HASH:0:8}"
CAMPAIGN_JSONL="$ANALYTICS_DIR/campaign.jsonl"
METADATA_FILE="$ANALYTICS_DIR/metadata.json"
WORKER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.worker.prompt.md"
VERIFIER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.verifier.prompt.md"
CONTEXT_FILE="$CONTEXT_DIR/${SLUG}-latest.md"
MEMORY_FILE="$MEMOS_DIR/${SLUG}-memory.md"
SIGNAL_FILE="$MEMOS_DIR/${SLUG}-iter-signal.json"
DONE_CLAIM_FILE="$MEMOS_DIR/${SLUG}-done-claim.json"
VERDICT_FILE="$MEMOS_DIR/${SLUG}-verify-verdict.json"
COMPLETE_SENTINEL="$MEMOS_DIR/${SLUG}-complete.md"
BLOCKED_SENTINEL="$MEMOS_DIR/${SLUG}-blocked.md"
LOCKFILE_PATH="$DESK/logs/.rlp-desk-${SLUG}.lock"
STATUS_FILE="$LOGS_DIR/status.json"
SESSION_CONFIG="$LOGS_DIR/session-config.json"
WORKER_HEARTBEAT="$LOGS_DIR/worker-heartbeat.json"
VERIFIER_HEARTBEAT="$LOGS_DIR/verifier-heartbeat.json"
COST_LOG="$LOGS_DIR/cost-log.jsonl"

# --- Session Naming ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SESSION_NAME="rlp-desk-${SLUG}-${TIMESTAMP}"

# --- State Tracking ---
typeset -A LAST_PANE_CONTENT
typeset -A PANE_IDLE_SINCE
typeset -A WORKER_RESTARTS
STALE_CONTEXT_COUNT=0
HEARTBEAT_STALE_COUNT=0
MONITOR_FAILURE_COUNT=0
CONSECUTIVE_FAILURES=0
PREV_CONTEXT_HASH=""
PREV_PRD_HASH=""
PREV_PRD_US_LIST=""
_PRD_CHANGED=0
ITERATION=0
START_TIME=$(date +%s)
BASELINE_COMMIT=""       # git HEAD at campaign start (captured before loop)
CAMPAIGN_REPORT_GENERATED=0  # guard against double-generation in cleanup trap
SV_REPORT_GENERATED=0       # guard against double-generation in generate_sv_report
VERIFIED_US=""           # comma-separated list of verified US IDs (per-us mode)
CONSENSUS_ROUND=0        # current consensus round for current US
US_LIST=""               # comma-separated US IDs from PRD (per-us mode)
LOCKFILE_ACQUIRED=0
LOCK_WORKER_MODEL="${LOCK_WORKER_MODEL:-0}"  # 0|1 — set by --lock-worker-model; disables progressive upgrade
_SAME_US_FAIL_COUNT=0         # consecutive same-US fail counter (upgrade trigger at >= 2)
_LAST_FAILED_US=""            # last failed US ID (same-US tracking for upgrade logic)
_MODEL_UPGRADED=0             # 1 if Worker model was auto-upgraded during campaign
_ORIGINAL_WORKER_MODEL=""     # WORKER_MODEL saved before first upgrade (for restore on pass)
_ORIGINAL_WORKER_CODEX_REASONING=""  # WORKER_CODEX_REASONING saved before first upgrade

# =============================================================================
# Utility Functions
# =============================================================================

DEBUG="${DEBUG:-0}"
DEBUG_LOG="$ANALYTICS_DIR/debug.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_debug() {
  if (( DEBUG )); then
    mkdir -p "$(dirname "$DEBUG_LOG")" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEBUG: $*" >> "$DEBUG_LOG"
  fi
}

log_error() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# parse_model_flag() — parse unified --worker-model / --verifier-model value
# Colon format (model:reasoning) → codex engine; plain name → claude engine.
# Spark alias: any model name containing "spark" is normalized to "spark".
# Usage:  parse_model_flag <value> <role>
# Output (stdout): "engine model [reasoning]"  e.g. "codex gpt-5.4 medium" | "claude sonnet"
# Returns: 0 on success, 1 on invalid format (error written to stderr)
parse_model_flag() {
  local value="$1"
  local role="${2:-worker}"
  local colon_count
  colon_count=$(printf '%s' "$value" | tr -cd ':' | wc -c | tr -d ' ')
  if (( colon_count > 1 )); then
    echo "ERROR: Invalid --${role}-model format '${value}'. Use 'model:reasoning' (codex) or 'model-name' (claude)." >&2
    return 1
  fi
  if (( colon_count == 1 )); then
    local model="${value%%:*}"
    local reasoning="${value##*:}"
    if [[ "$model" == *"spark"* ]]; then
      model="spark"
    fi
    echo "codex $model $reasoning"
  else
    echo "claude $value"
  fi
}

# check_dead_pane() — determine if pane command indicates a dead/exited process
# Engine-aware: bash is normal for codex workers (trigger runs in bash),
# but indicates dead pane for claude workers.
# Args: $1=pane_current_command  $2=engine (claude|codex)  $3=role (worker|verifier)
# Returns: 0 if dead, 1 if alive
check_dead_pane() {
  local poll_cmd="$1"
  local engine="${2:-claude}"
  local role="${3:-worker}"

  if [[ -z "$poll_cmd" ]]; then
    return 0  # empty = dead
  elif [[ "$poll_cmd" == "zsh" ]]; then
    return 0  # bare zsh = dead
  elif [[ "$poll_cmd" == "bash" && "$engine" != "codex" ]]; then
    return 0  # bash = dead for claude (codex uses bash trigger)
  fi
  return 1  # alive
}

# get_model_string() — return engine-appropriate model identifier string
# Claude: returns model name (e.g., "sonnet")
# Codex: returns model:reasoning (e.g., "gpt-5.4:high")
# Args: $1=engine (claude|codex)  $2=model  $3=codex_reasoning (optional)
# Output: model string on stdout
get_model_string() {
  local engine="$1"
  local model="$2"
  local reasoning="${3:-}"

  if [[ "$engine" = "codex" && -n "$reasoning" ]]; then
    echo "${model}:${reasoning}"
  else
    echo "$model"
  fi
}

# launch_worker_codex() — launch codex Worker via trigger script (non-interactive exec)
# Args: $1=pane_id  $2=trigger_file  $3=iteration
# Returns: 0 always (codex failures detected by poll_for_signal)
launch_worker_codex() {
  local pane_id="$1"
  local trigger_file="$2"
  local iter="$3"

  log "  Launching Worker codex via trigger script in pane $pane_id..."
  paste_to_pane "$pane_id" "bash $trigger_file"
  tmux send-keys -t "$pane_id" Enter
  log_debug "Worker codex trigger sent: $trigger_file"
  sleep 3  # brief wait for codex to start
  return 0
}

# launch_worker_claude() — launch claude Worker TUI, send instruction, verify submission
# Handles: TUI startup, wait_for_pane_ready, instruction send, 15-iteration submit loop,
#          restart recovery on submit failure.
# Args: $1=pane_id  $2=prompt_file  $3=iteration  $4=worker_launch_cmd
# Returns: 0 on success, 1 on fatal failure (caller writes BLOCKED)
launch_worker_claude() {
  local pane_id="$1"
  local prompt_file="$2"
  local iter="$3"
  local worker_launch="$4"

  log "  Launching Worker claude in pane $pane_id..."
  paste_to_pane "$pane_id" "$worker_launch"
  tmux send-keys -t "$pane_id" Enter

  # Wait for claude TUI to be ready
  if ! wait_for_pane_ready "$pane_id" 30; then
    log_error "Worker claude failed to start"
    return 1
  fi

  # Send instruction to claude TUI
  sleep 3
  local worker_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$worker_instruction"
  tmux send-keys -t "$pane_id" Enter
  log_debug "Worker instruction sent directly (${#worker_instruction} chars)"

  # 15-iteration submit loop — verify claude started working
  local submit_attempts=0
  while (( submit_attempts < 15 )); do
    sleep 2
    local pane_check
    pane_check=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$pane_check" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut\|Exploring\|Running\|exec\|Explored\|Prestidigitating\|Undulating\|Reading\|Bash\|Edit\|Write\|Grep\|Glob" 2>/dev/null; then
      log_debug "Worker started working after $((submit_attempts + 1)) submit checks"
      log_debug "[FLOW] iter=$iter worker_submit_check=OK attempts=$((submit_attempts + 1))"
      break
    fi
    # Every 3 failed attempts, re-send full instruction
    if (( submit_attempts > 0 && submit_attempts % 3 == 0 )); then
      log_debug "Re-sending full worker instruction (attempt $submit_attempts)"
      tmux send-keys -t "$pane_id" C-u 2>/dev/null
      sleep 0.2
      paste_to_pane "$pane_id" "$worker_instruction"
      sleep 0.15
      tmux send-keys -t "$pane_id" Enter
      sleep 1
    fi
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    (( submit_attempts++ ))
  done

  # If 15 attempts failed, restart claude and retry
  if (( submit_attempts >= 15 )); then
    log "  WARNING: Worker instruction not consumed after 15 attempts — restarting claude"
    log_debug "[GOV] iter=$iter worker_instruction_failed=true attempts=15 action=restart_claude"
    tmux send-keys -t "$pane_id" C-c 2>/dev/null
    sleep 0.5
    tmux send-keys -t "$pane_id" "/exit" Enter 2>/dev/null
    sleep 2
    wait_for_pane_ready "$pane_id" 10 2>/dev/null || true
    paste_to_pane "$pane_id" "$worker_launch"
    tmux send-keys -t "$pane_id" Enter
    if wait_for_pane_ready "$pane_id" 30; then
      sleep 3
      paste_to_pane "$pane_id" "$worker_instruction"
      tmux send-keys -t "$pane_id" Enter
      log "  Worker restarted and instruction re-sent"
      log_debug "[FLOW] iter=$iter worker_restart_recovery=success"
    else
      log_error "Worker restart failed — pane not ready"
      log_debug "[FLOW] iter=$iter worker_restart_recovery=failed"
    fi
  fi

  return 0
}

# launch_verifier_codex() — launch codex Verifier in pane (non-interactive)
# Args: $1=pane_id  $2=prompt_file  $3=iteration  $4=launch_cmd
# Returns: 0 always
launch_verifier_codex() {
  local pane_id="$1"
  local prompt_file="$2"
  local iter="$3"
  local verifier_launch="$4"

  log "  Launching Verifier codex in pane $pane_id..."
  paste_to_pane "$pane_id" "$verifier_launch"
  tmux send-keys -t "$pane_id" Enter
  sleep 3
  return 0
}

# launch_verifier_claude() — launch claude Verifier TUI, send instruction, verify submission
# Args: $1=pane_id  $2=prompt_file  $3=iteration  $4=launch_cmd
# Returns: 0 on success
launch_verifier_claude() {
  local pane_id="$1"
  local prompt_file="$2"
  local iter="$3"
  local verifier_launch="$4"

  log "  Launching Verifier claude in pane $pane_id..."
  paste_to_pane "$pane_id" "$verifier_launch"
  tmux send-keys -t "$pane_id" Enter

  if ! wait_for_pane_ready "$pane_id" 30; then
    log_error "Verifier failed to start"
    return 1
  fi

  sleep 3
  local verifier_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$verifier_instruction"
  tmux send-keys -t "$pane_id" Enter
  log_debug "Verifier instruction sent directly"

  # Submit loop — verify verifier started working
  local submit_attempts=0
  while (( submit_attempts < 15 )); do
    sleep 2
    local vs_check
    vs_check=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$vs_check" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut\|Exploring\|Running\|exec\|Explored" 2>/dev/null; then
      log_debug "Verifier started working after $((submit_attempts + 1)) checks"
      break
    fi
    if (( submit_attempts == 8 )); then
      log_debug "Adaptive instruction retry: clearing line and re-typing"
      tmux send-keys -t "$pane_id" C-u 2>/dev/null
      sleep 0.1
      paste_to_pane "$pane_id" "$verifier_instruction"
      tmux send-keys -t "$pane_id" Enter
    fi
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    (( submit_attempts++ ))
  done
  return 0
}

# handle_worker_exit_codex() — handle codex worker process exit (1-shot exec)
# On exit: check done-claim, auto-generate iter-signal.
# Args: $1=iteration  $2=signal_file
# Returns: 0 (signal generated), 1 (error)
handle_worker_exit_codex() {
  local iter="$1"
  local signal_file="$2"

  log "  Codex worker process exited. Checking for done-claim..."
  if [[ -f "$DONE_CLAIM_FILE" ]]; then
    local dc_us_id
    dc_us_id=$(jq -r '.us_id // "unknown"' "$DONE_CLAIM_FILE" 2>/dev/null)
    log "  Codex worker completed with done-claim (us_id=$dc_us_id). Auto-generating signal."
    echo '{"iteration":'"$iter"',"status":"verify","us_id":"'"$dc_us_id"'","summary":"auto-generated after codex exec exit","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$signal_file"
  else
    log "  WARNING: Codex worker exited without done-claim. Generating verify signal for current US."
    local current_us
    current_us=$(jq -r '.us_id // "US-001"' "$DESK/memos/${SLUG}-iter-signal.json" 2>/dev/null || echo "US-001")
    local mem_us
    mem_us=$(sed -n 's/.*Next.*US-\([0-9]*\).*/US-\1/p' "$DESK/memos/${SLUG}-memory.md" 2>/dev/null | head -1)
    [[ -n "$mem_us" ]] && current_us="$mem_us"
    echo '{"iteration":'"$iter"',"status":"verify","us_id":"'"$current_us"'","summary":"auto-generated after codex exec exit (no done-claim)","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$signal_file"
  fi
  return 0
}

# handle_worker_exit_claude() — handle claude worker process exit (restart with backoff)
# Args: $1=pane_id  $2=iteration  $3=trigger_file
# Returns: 0 (restarted), 1 (max restarts exceeded)
handle_worker_exit_claude() {
  local pane_id="$1"
  local iter="$2"
  local trigger_file="$3"

  log_error "Worker exited without writing signal file"
  if restart_worker "$pane_id" "$iter" "$trigger_file"; then
    return 0
  else
    return 1
  fi
}

# get_next_model() — return next model in Worker upgrade path, or empty at ceiling
# Usage: get_next_model <model_str>
#   claude: "haiku"|"sonnet"|"opus"
#   codex:  "gpt-5.4:medium"|"gpt-5.4:high"|"gpt-5.4:xhigh"|"spark:medium"|...
# Output: next model string, or empty string if at ceiling
get_next_model() {
  local current="$1"
  case "$current" in
    # Claude upgrade path (Worker only — Verifier fixed)
    haiku)          echo "sonnet"         ;;
    sonnet)         echo "opus"           ;;
    opus)           echo ""               ;;
    # Codex GPT Pro upgrade path (short aliases)
    spark:low)      echo "spark:medium"   ;;
    spark:medium)   echo "spark:high"     ;;
    spark:high)     echo "spark:xhigh"    ;;
    spark:xhigh)    echo ""               ;;  # spark ceiling
    # Codex GPT Pro upgrade path (full model names)
    gpt-5.3-codex-spark:low)    echo "gpt-5.3-codex-spark:medium" ;;
    gpt-5.3-codex-spark:medium) echo "gpt-5.3-codex-spark:high"   ;;
    gpt-5.3-codex-spark:high)   echo "gpt-5.3-codex-spark:xhigh"  ;;
    gpt-5.3-codex-spark:xhigh)  echo ""                           ;;  # spark ceiling (full name)
    # Codex standard (gpt-5.3-codex) upgrade path
    gpt-5.3-codex:low)    echo "gpt-5.3-codex:medium" ;;
    gpt-5.3-codex:medium) echo "gpt-5.3-codex:high"   ;;
    gpt-5.3-codex:high)   echo "gpt-5.3-codex:xhigh"  ;;
    gpt-5.3-codex:xhigh)  echo ""                     ;;  # codex ceiling
    # Codex Non-Pro / upper path
    gpt-5.4:low)    echo "gpt-5.4:medium" ;;
    gpt-5.4:medium) echo "gpt-5.4:high"   ;;
    gpt-5.4:high)   echo "gpt-5.4:xhigh"  ;;
    gpt-5.4:xhigh)  echo ""               ;;
    *)              echo ""               ;;  # unknown → treat as ceiling
  esac
}

# check_model_upgrade() — evaluate and apply Worker model upgrade on repeated same-US failure
# Called in the fail verdict path. Upgrades Worker model when same US fails >= 2 consecutive times.
# Respects LOCK_WORKER_MODEL flag. Never modifies VERIFIER_MODEL.
# Usage: check_model_upgrade <us_id>
check_model_upgrade() {
  local current_us="$1"

  # Track consecutive failures on same US
  if [[ "$current_us" = "$_LAST_FAILED_US" ]]; then
    (( _SAME_US_FAIL_COUNT++ ))
  else
    _SAME_US_FAIL_COUNT=1
    _LAST_FAILED_US="$current_us"
  fi

  # Respect --lock-worker-model: no upgrade; CB threshold handles BLOCKED
  if (( LOCK_WORKER_MODEL )); then
    log_debug "[DECIDE] iter=${ITERATION:-0} phase=model_select model_upgrade=false reason=locked"
    return 0
  fi

  # Upgrade when same US fails >= 2 consecutive times
  if (( _SAME_US_FAIL_COUNT >= 2 )); then
    local current_model_str
    current_model_str=$(get_model_string "$WORKER_ENGINE" "${WORKER_CODEX_MODEL:-$WORKER_MODEL}" "${WORKER_CODEX_REASONING:-}")

    local next_model
    next_model=$(get_next_model "$current_model_str")

    if [[ -z "$next_model" ]]; then
      # Already at ceiling — CB threshold will trigger BLOCKED with escalation message
      log_debug "[DECIDE] iter=${ITERATION:-0} phase=model_select model_upgrade=false reason=already_max current=$current_model_str"
      return 0
    fi

    # Save original model on first upgrade only
    if (( _MODEL_UPGRADED == 0 )); then
      _ORIGINAL_WORKER_MODEL="$WORKER_MODEL"
      _ORIGINAL_WORKER_CODEX_REASONING="$WORKER_CODEX_REASONING"
    fi
    _MODEL_UPGRADED=1

    if [[ "$WORKER_ENGINE" = "codex" ]]; then
      WORKER_CODEX_MODEL="${next_model%%:*}"
      WORKER_CODEX_REASONING="${next_model##*:}"
      WORKER_MODEL="$WORKER_CODEX_MODEL"
    else
      WORKER_MODEL="$next_model"
    fi

    log "  Worker model upgraded: ${_ORIGINAL_WORKER_MODEL} → ${WORKER_MODEL} (same-US consecutive fail threshold)"
    log_debug "[DECIDE] iter=${ITERATION:-0} phase=model_select model_upgrade=true reason=consecutive_same_ac_fail from=${_ORIGINAL_WORKER_MODEL} to=${WORKER_MODEL}"
    _SAME_US_FAIL_COUNT=0  # Reset counter after upgrade
  fi

  return 0
}

# --- governance.md s7: Atomic file writes (tmux pattern) ---
# All file writes by the Leader use tmp+mv to prevent corruption.
atomic_write() {
  local target="$1"
  local tmp="${target}.tmp.$$"
  cat > "$tmp"
  mv "$tmp" "$target"
}

# --- omc-teams pattern: Kill-and-replace dead/stuck worker panes ---
replace_worker_pane() {
  local old_pane="$1"
  local role="$2"  # "worker" or "verifier"

  log "  Replacing dead $role pane $old_pane..."
  tmux kill-pane -t "$old_pane" 2>/dev/null

  # Create fresh pane maintaining original layout: worker(top-right) / verifier(bottom-right)
  local new_pane
  if [[ "$role" == "verifier" ]]; then
    # Verifier goes below worker: split vertically from worker pane
    if tmux display-message -t "$WORKER_PANE" -p '#{pane_id}' &>/dev/null; then
      new_pane=$(tmux split-window -v -d -t "$WORKER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    else
      # Fallback: worker pane also dead, split horizontally from leader
      new_pane=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    fi
  else
    # Worker goes above verifier: split vertically before verifier pane
    if tmux display-message -t "$VERIFIER_PANE" -p '#{pane_id}' &>/dev/null; then
      new_pane=$(tmux split-window -v -b -d -t "$VERIFIER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    else
      # Fallback: verifier pane also dead, split horizontally from leader
      new_pane=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    fi
  fi

  log "  New $role pane: $new_pane (replaced $old_pane)"
  log_debug "[FLOW] iter=$ITERATION pane_replaced=${role} old=$old_pane new=$new_pane"

  # Update session-config.json with new pane ID
  if [[ -f "$SESSION_CONFIG" ]]; then
    jq --arg role "$role" --arg pane "$new_pane" \
      '.panes[$role] = $pane' "$SESSION_CONFIG" | atomic_write "$SESSION_CONFIG"
    log_debug "Updated session-config.json: $role pane → $new_pane"
  fi

  echo "$new_pane"
}

# =============================================================================
# Dependency Checks
# =============================================================================

# --- governance.md s7 step 1: Validate prerequisites before starting ---
check_dependencies() {
  local missing=0

  if ! command -v tmux >/dev/null 2>&1; then
    log_error "tmux is required but not found. Install with: brew install tmux"
    missing=1
  fi

  # claude required only when claude engine is used for Worker or Verifier execution;
  # codex-only campaigns can run without claude — generate_sv_report degrades gracefully
  if [[ "$WORKER_ENGINE" != "codex" || "$VERIFIER_ENGINE" != "codex" ]]; then
    if ! command -v claude >/dev/null 2>&1; then
      log_error "claude CLI is required but not found. See: https://docs.anthropic.com/en/docs/claude-cli"
      missing=1
    fi
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found. Install with: brew install jq"
    missing=1
  fi

  # Codex binary required only when engine=codex or consensus verification is enabled
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$VERIFY_CONSENSUS" = "1" || "$FINAL_CONSENSUS" = "1" ]]; then
    if ! command -v codex >/dev/null 2>&1; then
      log_error "codex CLI not found. Install: npm install -g @openai/codex"
      missing=1
    fi
  fi

  if (( missing )); then
    exit 1
  fi

  # Resolve full path to claude binary when claude engine is in use
  if [[ "$WORKER_ENGINE" != "codex" || "$VERIFIER_ENGINE" != "codex" ]]; then
    CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "claude")
    log "  Claude binary: $CLAUDE_BIN"
  fi

  # Resolve codex binary if needed
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$VERIFY_CONSENSUS" = "1" || "$FINAL_CONSENSUS" = "1" ]]; then
    CODEX_BIN=$(command -v codex 2>/dev/null || echo "codex")
    log "  Codex binary:  $CODEX_BIN"
  fi
}

# =============================================================================
# Scaffold Validation
# =============================================================================

validate_scaffold() {
  local errors=0

  if [[ ! -f "$WORKER_PROMPT_BASE" ]]; then
    log_error "Worker prompt not found: $WORKER_PROMPT_BASE"
    errors=1
  fi

  if [[ ! -f "$VERIFIER_PROMPT_BASE" ]]; then
    log_error "Verifier prompt not found: $VERIFIER_PROMPT_BASE"
    errors=1
  fi

  if [[ ! -f "$CONTEXT_FILE" ]]; then
    log_error "Context file not found: $CONTEXT_FILE"
    errors=1
  fi

  if [[ ! -f "$MEMORY_FILE" ]]; then
    log_error "Memory file not found: $MEMORY_FILE"
    errors=1
  fi

  if (( errors )); then
    log_error "Scaffold validation failed. Run init_ralph_desk.zsh first."
    exit 1
  fi

  mkdir -p "$LOGS_DIR"
}

# =============================================================================
# Session Management (tmux pattern: pane IDs)
# =============================================================================

# --- governance.md s7 step 1: Check for existing sessions ---
check_existing_sessions() {
  local current_session
  current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null || echo "")
  local existing
  existing=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^rlp-desk-${SLUG}-" | grep -v "^${current_session}$" || true)
  if [[ -n "$existing" ]]; then
    log_error "Existing tmux session(s) found for slug '$SLUG':"
    echo "$existing" | while read -r s; do
      echo "  - $s"
    done
    echo ""
    echo "Kill existing session first:"
    echo "  tmux kill-session -t <session-name>"
    exit 1
  fi
}

# --- governance.md s7 step 1: Create tmux session with pane IDs (%N) ---
create_session() {
  log "Creating tmux session: $SESSION_NAME"

  # tmux split-pane pattern
  if [[ -n "${TMUX:-}" ]]; then
    # Inside tmux: split CURRENT pane in place
    # Current pane stays as-is (leader/user stays here)
    # Worker/Verifier appear on the RIGHT, user sees them immediately
    LEADER_PANE=$(tmux display-message -p '#{pane_id}')
    SESSION_NAME=$(tmux display-message -p '#{session_name}')
    log "  Splitting current pane in session: $SESSION_NAME"

    # -h off current pane → right column (worker)
    WORKER_PANE=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    # -v off worker → stacked below on right (verifier)
    VERIFIER_PANE=$(tmux split-window -v -d -t "$WORKER_PANE" -P -F '#{pane_id}' -c "$ROOT")
  else
    # Outside tmux: wrap current terminal into a new tmux session and attach
    # tmux pattern: user sees panes immediately, no separate attach needed
    tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$ROOT"
    LEADER_PANE=$(tmux display-message -p -t "$SESSION_NAME" '#{pane_id}')
    WORKER_PANE=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    VERIFIER_PANE=$(tmux split-window -v -d -t "$WORKER_PANE" -P -F '#{pane_id}' -c "$ROOT")

  fi

  # Set pane titles and enable border labels for visual distinction
  local worker_label="Worker ($WORKER_ENGINE:$WORKER_MODEL)"
  local verifier_label="Verifier ($VERIFIER_ENGINE:$VERIFIER_MODEL)"
  [[ "$VERIFY_CONSENSUS" = "1" ]] && verifier_label="Verifier ($VERIFIER_ENGINE:$VERIFIER_MODEL + codex:$VERIFIER_CODEX_MODEL)"
  tmux select-pane -t "$LEADER_PANE" -T "Leader" 2>/dev/null
  tmux select-pane -t "$WORKER_PANE" -T "$worker_label" 2>/dev/null
  tmux select-pane -t "$VERIFIER_PANE" -T "$verifier_label" 2>/dev/null
  # Color-coded pane borders: green=leader, blue=worker, yellow=verifier
  tmux set-option -p -t "$LEADER_PANE" pane-border-style "fg=green" 2>/dev/null
  tmux set-option -p -t "$WORKER_PANE" pane-border-style "fg=blue" 2>/dev/null
  tmux set-option -p -t "$VERIFIER_PANE" pane-border-style "fg=yellow" 2>/dev/null
  # Show pane titles in border
  tmux set-option pane-border-status top 2>/dev/null
  tmux set-option pane-border-format "#{?pane_active,#[fg=white bold],#[fg=grey]} #{pane_title} " 2>/dev/null

  log "  Leader pane:   $LEADER_PANE"
  log "  Worker pane:   $WORKER_PANE"
  log "  Verifier pane: $VERIFIER_PANE"

  # AC12: Capture baseline commit before writing session config
  BASELINE_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "none")

  # Truncate cost-log for fresh run (previous data in versioned campaign reports)
  > "$COST_LOG"

  # SV flag warning for tmux mode
  if (( WITH_SELF_VERIFICATION )); then
    log "  NOTE: --with-self-verification recorded but SV report generation is Agent-mode only"
  fi

  # Write session config (atomic write)
  echo '{
  "session_name": "'"$SESSION_NAME"'",
  "slug": "'"$SLUG"'",
  "created_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
  "baseline_commit": "'"$BASELINE_COMMIT"'",
  "panes": {
    "leader": "'"$LEADER_PANE"'",
    "worker": "'"$WORKER_PANE"'",
    "verifier": "'"$VERIFIER_PANE"'"
  },
  "pid": '$$',
  "root": "'"$ROOT"'",
  "models": {
    "worker": "'"$WORKER_MODEL"'",
    "verifier": "'"$VERIFIER_MODEL"'"
  },
  "engines": {
    "worker": "'"$WORKER_ENGINE"'",
    "verifier": "'"$VERIFIER_ENGINE"'",
    "worker_codex_model": "'"$WORKER_CODEX_MODEL"'",
    "worker_codex_reasoning": "'"$WORKER_CODEX_REASONING"'",
    "verifier_codex_model": "'"$VERIFIER_CODEX_MODEL"'",
    "verifier_codex_reasoning": "'"$VERIFIER_CODEX_REASONING"'"
  },
  "verification": {
    "verify_mode": "'"$VERIFY_MODE"'",
    "verify_consensus": '"$VERIFY_CONSENSUS"',
    "consensus_scope": "'"$CONSENSUS_SCOPE"'"
  },
  "config": {
    "max_iter": '"$MAX_ITER"',
    "poll_interval": '"$POLL_INTERVAL"',
    "iter_timeout": '"$ITER_TIMEOUT"',
    "heartbeat_stale_threshold": '"$HEARTBEAT_STALE_THRESHOLD"',
    "max_restarts": '"$MAX_RESTARTS"',
    "idle_nudge_threshold": '"$IDLE_NUDGE_THRESHOLD"',
    "max_nudges": '"$MAX_NUDGES"',
    "cb_threshold": '"$CB_THRESHOLD"',
    "effective_cb_threshold": '"$EFFECTIVE_CB_THRESHOLD"',
    "with_self_verification": '"$WITH_SELF_VERIFICATION"'
  }
}' | atomic_write "$SESSION_CONFIG"

  log "  Session config: $SESSION_CONFIG"
}

# =============================================================================
# Copy-Mode Guard (tmux pattern)
# =============================================================================

# --- governance.md s7 step 5: Check pane_in_mode before every send-keys ---
check_copy_mode() {
  local pane_id="$1"
  local in_mode
  in_mode=$(tmux display-message -p -t "$pane_id" '#{pane_in_mode}' 2>/dev/null) || return 1
  if [[ "$in_mode" -eq 1 ]]; then
    return 1  # pane is in copy mode, cannot send keys
  fi
  return 0
}

# --- US-003: API error detector using tmux pane buffer ---
is_api_error() {
  local pane_id="$1"
  local pane_output
  pane_output=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
  if [[ -z "$pane_output" ]]; then
    return 1
  fi

  if echo "$pane_output" | grep -qiE '(^|[^[:digit:]])500([^[:digit:]]|$)' \
    || echo "$pane_output" | grep -qiE '(^|[^[:digit:]])529([^[:digit:]]|$)' \
    || echo "$pane_output" | grep -qi 'overloaded' \
    || echo "$pane_output" | grep -qi 'too many requests' \
    || echo "$pane_output" | grep -qi 'service unavailable'; then
    return 0
  fi
  return 1
}

# =============================================================================
# Verification-Based Send Retry (tmux pattern)
# =============================================================================

# --- Reliable text paste via tmux buffer (avoids send-keys -l char-by-char issues) ---
paste_to_pane() {
  local pane_id="$1"
  local text="$2"
  local tmpbuf="/tmp/.rlp-desk-paste-$$.tmp"
  echo -n "$text" > "$tmpbuf"
  tmux load-buffer -b rlp-paste "$tmpbuf" 2>/dev/null
  tmux paste-buffer -b rlp-paste -d -t "$pane_id" 2>/dev/null
  rm -f "$tmpbuf"
}

# --- governance.md s7 step 5: Send with copy-mode guard and retry ---
safe_send_keys() {
  local pane_id="$1"
  local text="$2"

  # --- Exact tmux sendToWorker pattern (tmux-session.js:527-626) ---

  # Guard: copy-mode captures keys; skip entirely
  if ! check_copy_mode "$pane_id"; then
    log_debug " Pane $pane_id in copy mode, skipping send"
    return 1
  fi

  # Check for trust prompt and auto-dismiss
  local initial_capture
  initial_capture=$(tmux capture-pane -t "$pane_id" -p -S -20 2>/dev/null)
  local pane_busy=0
  if echo "$initial_capture" | grep -q "esc to interrupt" 2>/dev/null; then
    pane_busy=1
  fi
  if echo "$initial_capture" | grep -q "Do you trust" 2>/dev/null; then
    log_debug " Trust prompt detected, dismissing"
    tmux send-keys -t "$pane_id" C-m
    sleep 0.12
  fi
  # Auto-approve permission prompts ("Do you want to create/overwrite X?")
  if echo "$initial_capture" | grep -q "Do you want to" 2>/dev/null; then
    log_debug " Permission prompt detected, auto-approving"
    tmux send-keys -t "$pane_id" Enter
    sleep 0.3
  fi
  # Auto-dismiss codex update prompt (select Skip)
  if echo "$initial_capture" | grep -qi "new version\|update.*codex\|codex.*update" 2>/dev/null; then
    log_debug " Codex update prompt detected, selecting Skip"
    tmux send-keys -t "$pane_id" "2" Enter
    sleep 0.2
  fi
  # Send text via buffer paste (reliable for long strings)
  log_debug " Pasting text to pane $pane_id (${#text} chars)"
  paste_to_pane "$pane_id" "$text"

  # Allow input buffer to settle (tmux: 150ms)
  sleep 0.15

  # Submit: up to 6 rounds of C-m double-press
  local round=0
  while (( round < 6 )); do
    sleep 0.1
    if (( round == 0 && pane_busy )); then
      # Busy pane: just C-m (DO NOT send Tab — it toggles Claude Code permission mode)
      tmux send-keys -t "$pane_id" C-m
    else
      tmux send-keys -t "$pane_id" C-m
      sleep 0.2
      tmux send-keys -t "$pane_id" C-m
    fi
    sleep 0.14

    # Check if text was consumed
    local check_capture
    check_capture=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -5)
    if ! echo "$check_capture" | grep -qF "$text" 2>/dev/null; then
      log_debug " Text consumed after round $((round + 1))"
      return 0
    fi
    sleep 0.14
    (( round++ ))
  done

  # Safety gate: copy-mode check
  if ! check_copy_mode "$pane_id"; then
    log_debug " Copy mode activated during send, aborting"
    return 1
  fi

  # Adaptive fallback: C-u clear line, resend (tmux pattern)
  log_debug " Adaptive retry — clearing line and resending"
  tmux send-keys -t "$pane_id" C-u
  sleep 0.08
  if ! check_copy_mode "$pane_id"; then
    return 1
  fi
  paste_to_pane "$pane_id" "$text"
  sleep 0.12
  local retry_round=0
  while (( retry_round < 4 )); do
    tmux send-keys -t "$pane_id" C-m
    sleep 0.18
    tmux send-keys -t "$pane_id" C-m
    sleep 0.14
    local retry_capture
    retry_capture=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -5)
    if ! echo "$retry_capture" | grep -qF "$text" 2>/dev/null; then
      log_debug " Text consumed after adaptive retry round $((retry_round + 1))"
      return 0
    fi
    (( retry_round++ ))
  done

  # Fail-open: one last nudge
  if ! check_copy_mode "$pane_id"; then
    return 1
  fi
  tmux send-keys -t "$pane_id" C-m
  sleep 0.12
  tmux send-keys -t "$pane_id" C-m
  log_debug " Fail-open — text may or may not have been submitted"
  return 0
}

# =============================================================================
# Wait for Pane Ready (tmux pattern: paneLooksReady)
# =============================================================================

wait_for_pane_ready() {
  local pane_id="$1"
  local timeout="${2:-10}"  # tmux default: 10s
  local start=$(date +%s)
  log "  Waiting for pane $pane_id ready..."
  while (( $(date +%s) - start < timeout )); do
    local captured
    captured=$(tmux capture-pane -t "$pane_id" -p -S -20 2>/dev/null)

    # Auto-dismiss trust prompt (tmux pattern: paneHasTrustPrompt)
    if echo "$captured" | grep -q "Do you trust" 2>/dev/null; then
      log "  Trust prompt detected, auto-dismissing..."
      tmux send-keys -t "$pane_id" Enter
      sleep 0.12
      tmux send-keys -t "$pane_id" Enter
      sleep 2
      continue
    fi

    # Auto-approve permission prompts ("Do you want to create/overwrite X?")
    if echo "$captured" | grep -q "Do you want to" 2>/dev/null; then
      log "  Permission prompt detected, auto-approving..."
      tmux send-keys -t "$pane_id" Enter
      sleep 0.5
      continue
    fi

    # Auto-dismiss codex update prompt (select Skip = option 2)
    if echo "$captured" | grep -qi "new version\|update.*codex\|codex.*update" 2>/dev/null; then
      log "  Codex update prompt detected, selecting Skip..."
      tmux send-keys -t "$pane_id" "2" Enter
      sleep 0.5
      continue
    fi

    # tmux paneLooksReady: check each line for prompt char at line start
    local ready=0
    echo "$captured" | while IFS= read -r line; do
      local trimmed="${line## }"
      if [[ "$trimmed" == ❯* || "$trimmed" == \>* || "$trimmed" == ›* || "$trimmed" == »* ]]; then
        ready=1
        break
      fi
    done 2>/dev/null

    # Also check via grep as fallback
    if echo "$captured" | tail -5 | grep -qE '^\s*[❯›]' 2>/dev/null; then
      ready=1
    fi

    if (( ready )) || echo "$captured" | tail -3 | grep -qE '^\s*[❯›>]' 2>/dev/null; then
      # Check no active task running
      if ! echo "$captured" | grep -q "esc to interrupt" 2>/dev/null; then
        log "  Pane $pane_id is ready."
        return 0
      fi
    fi
    sleep 0.25
  done
  # Timeout — return success anyway (fail-open, let safe_send_keys handle it)
  log "  Pane $pane_id ready timeout after ${timeout}s (proceeding anyway)"
  return 0
}

# =============================================================================
# Heartbeat Monitoring (tmux pattern)
# =============================================================================

# --- governance.md s7 step 5+6: Check heartbeat freshness ---
check_heartbeat() {
  local hb_file="$1"
  local threshold="$HEARTBEAT_STALE_THRESHOLD"

  if [[ ! -f "$hb_file" ]]; then
    return 1
  fi

  local hb_epoch now_epoch
  # Read epoch seconds directly (avoids timezone parsing bugs)
  hb_epoch=$(jq -r '.epoch // empty' "$hb_file" 2>/dev/null) || return 1

  if [[ -z "$hb_epoch" ]]; then
    return 1
  fi

  now_epoch=$(date +%s)
  (( now_epoch - hb_epoch < threshold ))
}

# Check if heartbeat indicates process has exited
check_heartbeat_exited() {
  local hb_file="$1"
  if [[ ! -f "$hb_file" ]]; then
    return 1
  fi
  local hb_status
  hb_status=$(jq -r '.status // empty' "$hb_file" 2>/dev/null)
  [[ "$hb_status" == "exited" ]]
}

# =============================================================================
# Idle Pane Nudging (tmux pattern)
# =============================================================================

# --- governance.md s7 step 5+6: Nudge idle panes ---
check_and_nudge_idle_pane() {
  local pane_id="$1"
  local nudge_count_var="$2"
  local current_content
  current_content=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | tail -3)

  if [[ "$current_content" == "${LAST_PANE_CONTENT[$pane_id]:-}" ]]; then
    local idle_since="${PANE_IDLE_SINCE[$pane_id]:-$(date +%s)}"
    local now
    now=$(date +%s)
    if (( now - idle_since > IDLE_NUDGE_THRESHOLD )); then
      # A12 fix: NEVER nudge if pane is busy (thinking/working) — nudge interrupts claude
      local _nudge_capture
      _nudge_capture=$(tmux capture-pane -t "$pane_id" -p -S -5 2>/dev/null)
      if echo "$_nudge_capture" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut\|razzle\|bunning\|zesting\|fermenting\|actualizing\|composing\|evaporating\|churning" 2>/dev/null; then
        log_debug "  Pane $pane_id appears busy (thinking/working), skipping nudge"
      else
        local count=${(P)nudge_count_var}
        if (( count < MAX_NUDGES )); then
          log "  Nudging idle pane $pane_id (nudge $((count + 1))/$MAX_NUDGES)"
          safe_send_keys "$pane_id" ""
          (( count++ ))
          eval "$nudge_count_var=$count"
        fi
      fi
    fi
  else
    LAST_PANE_CONTENT[$pane_id]="$current_content"
    PANE_IDLE_SINCE[$pane_id]=$(date +%s)
  fi
}

# =============================================================================
# Exponential Backoff Restart (tmux pattern)
# =============================================================================

# --- governance.md s7 step 5: Restart dead workers with backoff ---
restart_worker() {
  local pane_id="$1"
  local iter="$2"
  local trigger_file="$3"

  # Codex workers are 1-shot exec; restart is not applicable
  if [[ "$WORKER_ENGINE" = "codex" ]]; then
    log_debug "restart_worker called for codex engine — no-op (1-shot exec)"
    return 1
  fi

  local restart_count="${WORKER_RESTARTS[$iter]:-0}"

  if (( restart_count >= MAX_RESTARTS )); then
    log_error "Worker exceeded max restarts ($MAX_RESTARTS) for iteration $iter"
    return 1  # caller writes BLOCKED
  fi

  # Exponential backoff: 5s, 10s, 20s, 60s (cap)
  local -a delays=(5 10 20 60)
  local delay=${delays[$((restart_count + 1))]:-60}
  log "  Restarting worker (attempt $((restart_count + 1))/$MAX_RESTARTS) after ${delay}s backoff..."
  sleep "$delay"

  # Kill existing claude, wait for shell prompt
  tmux send-keys -t "$pane_id" C-c 2>/dev/null
  tmux send-keys -t "$pane_id" "/exit" Enter 2>/dev/null
  sleep 2

  # Re-launch worker (tmux interactive pattern)
  if [[ "$WORKER_ENGINE" = "codex" ]]; then
    safe_send_keys "$pane_id" "${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
  else
    safe_send_keys "$pane_id" "$CLAUDE_BIN --model $WORKER_MODEL --dangerously-skip-permissions"
  fi
  WORKER_RESTARTS[$iter]=$((restart_count + 1))
  return 0
}

# =============================================================================
# Write-Then-Notify: Trigger Script Generation (tmux CRITICAL pattern)
# =============================================================================

# Per-US PRD injection helper
# Substitutes the full PRD path with a per-US split path in the Worker prompt base.
# Falls back to the full PRD with a stderr warning if the split file is missing.
# Args: $1=prompt_base_file $2=full_prd_path $3=per_us_prd_path (empty = no substitution)
inject_per_us_prd() {
  local prompt_base="$1"
  local full_prd="$2"
  local per_us_prd="${3:-}"

  if [[ -n "$per_us_prd" && -f "$per_us_prd" ]]; then
    sed "s|$full_prd|$per_us_prd|g" "$prompt_base"
  else
    if [[ -n "$per_us_prd" ]]; then
      echo "WARNING: per-US split file not found: $per_us_prd — falling back to full PRD injection" >&2
    fi
    cat "$prompt_base"
  fi
}

# --- governance.md s7 step 4+5: Write prompt and trigger to files ---
# NEVER send prompt content through tmux send-keys.
# Write payloads to files, send only short trigger commands (<200 chars).
write_worker_trigger() {
  local iter="$1"
  local prompt_file="$LOGS_DIR/iter-$(printf '%03d' $iter).worker-prompt.md"
  local trigger_file="$LOGS_DIR/iter-$(printf '%03d' $iter).worker-trigger.sh"
  local output_log="$LOGS_DIR/iter-$(printf '%03d' $iter).worker-output.log"

  # Build the worker prompt: base prompt + iteration context
  local contract
  contract=$(sed -n '/^## Next Iteration Contract$/,/^## /{ /^## Next/d; /^## [^N]/d; p; }' "$MEMORY_FILE" 2>/dev/null | head -5)

  # Check for fix contract from previous verifier failure
  local prev_iter=$((iter - 1))
  local fix_contract_file="$LOGS_DIR/iter-$(printf '%03d' $prev_iter).fix-contract.md"

  # Compute next unverified US before prompt assembly (required for per-US PRD injection)
  local next_us=""
  if [[ "$VERIFY_MODE" = "per-us" && -n "$US_LIST" ]]; then
    for us in $(echo "$US_LIST" | tr ',' ' '); do
      if ! echo ",$VERIFIED_US," | grep -q ",$us,"; then
        next_us="$us"
        break
      fi
    done
  fi

  {
    # Per-US PRD injection: substitute full PRD path with per-US split path when available
    local per_us_prd=""
    [[ -n "$next_us" ]] && per_us_prd="$DESK/plans/prd-${SLUG}-${next_us}.md"
    inject_per_us_prd "$WORKER_PROMPT_BASE" "$DESK/plans/prd-${SLUG}.md" "$per_us_prd"
    echo ""
    echo "---"
    echo "## Iteration Context"
    echo "- **Iteration**: $iter"
    echo "- **Memory Stop Status**: $(sed -n '/^## Stop Status$/,/^$/{ /^## /d; /^$/d; p; }' "$MEMORY_FILE" 2>/dev/null | head -1)"
    echo "- **Next Iteration Contract**: ${contract:-Start from the beginning}"
    if (( _PRD_CHANGED )); then
      echo "NOTE: PRD was updated since last iteration. New/changed US may exist."
    fi

    # Include fix contract if previous verifier failed
    if [[ -f "$fix_contract_file" ]]; then
      echo ""
      echo "---"
      echo "## IMPORTANT: Fix Contract from Verifier (iteration $prev_iter)"
      echo "The Verifier REJECTED your previous work. You MUST fix the issues below."
      echo "Do NOT just resubmit — actually change the code to address each issue."
      echo ""
      cat "$fix_contract_file"
    fi

    # Per-US mode: tell Worker exactly which US to work on
    if [[ "$VERIFY_MODE" = "per-us" && -n "$US_LIST" ]]; then
      if [[ -n "$next_us" ]]; then
        echo ""
        echo "---"
        echo "## PER-US SCOPE LOCK (this iteration) — OVERRIDES memory contract"
        echo "**IGNORE the 'Next Iteration Contract' from memory if it references a different story.**"
        echo "The Leader has determined that **${next_us}** is the next unverified story."
        echo "You MUST implement ONLY **${next_us}** in this iteration."
        echo "Do NOT implement any other user stories."
        echo "When done, signal verify with us_id=\"${next_us}\" (not \"ALL\")."
        echo "Signal format: {\"iteration\": N, \"status\": \"verify\", \"us_id\": \"${next_us}\", ...}"
        echo ""
        echo "**Update the campaign memory's 'Next Iteration Contract' to reflect ${next_us}.**"
      elif [[ -n "$VERIFIED_US" ]]; then
        # All individual US verified — this is the final full verify iteration
        echo ""
        echo "---"
        echo "## FINAL VERIFICATION ITERATION"
        echo "All individual US have been verified: $VERIFIED_US"
        echo "Run all tests and verification commands to confirm everything works together."
        echo "Signal verify with us_id=\"ALL\" for the final full verification."
      fi
    elif [[ "$VERIFY_MODE" = "batch" ]]; then
      echo ""
      echo "---"
      echo "## BATCH MODE OVERRIDE"
      echo "Ignore any per-US signal instructions above. In batch mode:"
      echo "- Implement ALL user stories in this iteration"
      echo '- Signal verify with us_id="ALL" only when ALL stories are complete'
      echo "- Do NOT signal verify after individual stories"
    fi
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
  # Engine-specific launch command (expanded at write time)
  if [[ "$WORKER_ENGINE" = "codex" ]]; then
    local engine_cmd="${CODEX_BIN:-codex} exec \\
  -m $WORKER_CODEX_MODEL \\
  -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" \\
  --dangerously-bypass-approvals-and-sandbox \\
  \"\$(cat $prompt_file)\""
    local engine_comment="# Run codex exec with fresh context (no pipe — codex requires terminal)"
  else
    local engine_cmd="$CLAUDE_BIN -p \"\$(cat $prompt_file)\" \\
  --model $WORKER_MODEL \\
  --dangerously-skip-permissions \\
  --output-format text \\
  2>&1 | tee $output_log"
    local engine_comment="# Run claude with fresh context (governance.md s7 step 5)"
  fi

  {
    cat <<TRIGGER_EOF
#!/bin/zsh
# Trigger for iteration $iter worker - generated by run_ralph_desk.zsh
# DO NOT use exec here -- it breaks heartbeat cleanup

HEARTBEAT_FILE="$WORKER_HEARTBEAT"

# Background heartbeat writer (tmux pattern)
(
  while true; do
    echo '{"epoch":'\$(date +%s)',"pid":'"\$\$"'}' > "\${HEARTBEAT_FILE}.tmp.\$\$"
    mv "\${HEARTBEAT_FILE}.tmp.\$\$" "\$HEARTBEAT_FILE"
    sleep 15
  done
) &
HEARTBEAT_PID=\$!

$engine_comment
$engine_cmd

# Cleanup heartbeat writer
kill \$HEARTBEAT_PID 2>/dev/null
wait \$HEARTBEAT_PID 2>/dev/null
echo '{"epoch":'\$(date +%s)',"status":"exited"}' > "\${HEARTBEAT_FILE}.tmp.\$\$"
mv "\${HEARTBEAT_FILE}.tmp.\$\$" "\$HEARTBEAT_FILE"
TRIGGER_EOF
  } | atomic_write "$trigger_file"
  chmod +x "$trigger_file"

  log "  Worker prompt:  $prompt_file"
  log "  Worker trigger: $trigger_file"
}

write_verifier_trigger() {
  local iter="$1"
  local verifier_engine="${2:-$VERIFIER_ENGINE}"  # allow override for consensus
  local verifier_model="${3:-$VERIFIER_MODEL}"
  local suffix="${4:-}"  # optional suffix for consensus (e.g., "-claude", "-codex")
  local prompt_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-prompt.md"
  local trigger_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-trigger.sh"
  local output_log="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-output.log"

  # Read us_id from iter-signal.json for per-US scoping
  local us_id=""
  if [[ -f "$SIGNAL_FILE" ]]; then
    us_id=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
  fi

  # Build verifier prompt from base with US scope
  {
    cat "$VERIFIER_PROMPT_BASE"
    echo ""
    echo "---"
    echo "## Verification Context"
    echo "- **Iteration**: $iter"
    echo "- **Done Claim**: $DONE_CLAIM_FILE"
    echo "- **Verify Mode**: $VERIFY_MODE"
    if [[ "$VERIFY_MODE" = "per-us" && -n "$us_id" ]]; then
      if [[ "$us_id" = "ALL" ]]; then
        echo "- **Scope**: FINAL FULL VERIFY — check ALL acceptance criteria from the PRD"
        echo "- **Previously verified US**: $VERIFIED_US"
      else
        echo "- **Scope**: Verify ONLY the acceptance criteria for **${us_id}**"
        echo "- **Previously verified US**: $VERIFIED_US"
      fi
    fi
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
  # Engine-specific launch command (expanded at write time)
  if [[ "$verifier_engine" = "codex" ]]; then
    local engine_cmd="${CODEX_BIN:-codex} -m $VERIFIER_CODEX_MODEL \\
  -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" \\
  --dangerously-bypass-approvals-and-sandbox \\
  \"\$(cat $prompt_file)\" \\
  2>&1 | tee $output_log"
    local engine_comment="# Run codex with fresh context (governance.md s7 step 7)"
  else
    local engine_cmd="$CLAUDE_BIN -p \"\$(cat $prompt_file)\" \\
  --model $verifier_model \\
  --dangerously-skip-permissions \\
  --output-format text \\
  2>&1 | tee $output_log"
    local engine_comment="# Run claude with fresh context (governance.md s7 step 7)"
  fi

  {
    cat <<TRIGGER_EOF
#!/bin/zsh
# Trigger for iteration $iter verifier${suffix} - generated by run_ralph_desk.zsh
# DO NOT use exec here -- it breaks heartbeat cleanup

HEARTBEAT_FILE="$VERIFIER_HEARTBEAT"

# Background heartbeat writer (tmux pattern)
(
  while true; do
    echo '{"epoch":'\$(date +%s)',"pid":'"\$\$"'}' > "\${HEARTBEAT_FILE}.tmp.\$\$"
    mv "\${HEARTBEAT_FILE}.tmp.\$\$" "\$HEARTBEAT_FILE"
    sleep 15
  done
) &
HEARTBEAT_PID=\$!

$engine_comment
$engine_cmd

# Cleanup heartbeat writer
kill \$HEARTBEAT_PID 2>/dev/null
wait \$HEARTBEAT_PID 2>/dev/null
echo '{"epoch":'\$(date +%s)',"status":"exited"}' > "\${HEARTBEAT_FILE}.tmp.\$\$"
mv "\${HEARTBEAT_FILE}.tmp.\$\$" "\$HEARTBEAT_FILE"
TRIGGER_EOF
  } | atomic_write "$trigger_file"
  chmod +x "$trigger_file"

  log "  Verifier prompt:  $prompt_file"
  log "  Verifier trigger: $trigger_file"
}

# =============================================================================
# Status Updates
# =============================================================================

# --- governance.md s7 step 8: Update status.json ---
update_status() {
  local phase="$1"
  local last_result="$2"

  # Build verified_us as JSON array
  local verified_us_json="[]"
  if [[ -n "$VERIFIED_US" ]]; then
    verified_us_json=$(echo "$VERIFIED_US" | tr ',' '\n' | jq -R . | jq -s .)
  fi

  # Build consensus fields
  local consensus_json=""
  if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
    consensus_json=',
  "consensus_scope": "'"$CONSENSUS_SCOPE"'",
  "consensus_round": '"$CONSENSUS_ROUND"',
  "claude_verdict": "'"${CLAUDE_VERDICT:-}"'",
  "codex_verdict": "'"${CODEX_VERDICT:-}"'"'
  fi

  echo '{
  "slug": "'"$SLUG"'",
  "baseline_commit": "'"${BASELINE_COMMIT:-none}"'",
  "iteration": '"$ITERATION"',
  "max_iter": '"$MAX_ITER"',
  "phase": "'"$phase"'",
  "worker_model": "'"$WORKER_MODEL"'",
  "verifier_model": "'"$VERIFIER_MODEL"'",
  "worker_engine": "'"$WORKER_ENGINE"'",
  "verifier_engine": "'"$VERIFIER_ENGINE"'",
  "worker_codex_model": "'"$WORKER_CODEX_MODEL"'",
  "worker_codex_reasoning": "'"$WORKER_CODEX_REASONING"'",
  "verifier_codex_model": "'"$VERIFIER_CODEX_MODEL"'",
  "verifier_codex_reasoning": "'"$VERIFIER_CODEX_REASONING"'",
  "verify_mode": "'"$VERIFY_MODE"'",
  "verify_consensus": '"$VERIFY_CONSENSUS"',
  "last_result": "'"$last_result"'",
  "consecutive_failures": '"$CONSECUTIVE_FAILURES"',
  "verified_us": '"$verified_us_json"''"$consensus_json"',
  "updated_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"
}' | atomic_write "$STATUS_FILE"
}

# --- governance.md s7 step 8: Write result log ---
write_result_log() {
  local iter="$1"
  local result="$2"
  local result_file="$LOGS_DIR/iter-$(printf '%03d' $iter).result.md"

  local git_diff=""
  if git -C "$ROOT" rev-parse HEAD &>/dev/null; then
    git_diff=$(git -C "$ROOT" diff --stat HEAD 2>/dev/null || echo "(no git diff available)")
  else
    git_diff="(no commits in repo — cannot diff)"
  fi
  # Include untracked new files in result log
  local result_untracked
  result_untracked=$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null | head -20)
  if [[ -n "$result_untracked" ]]; then
    git_diff="${git_diff}

Untracked new files:
${result_untracked}"
  fi

  {
    echo "# Iteration $iter Result"
    echo ""
    echo "## Status"
    echo "$result [leader-measured]"
    echo ""
    echo "## Files Changed"
    echo '```'
    echo "$git_diff"
    echo '```'
    echo "[git-measured]"
    echo ""
    echo "## Timestamp"
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } | atomic_write "$result_file"
}

# --- step 7d: Archive iteration artifacts (done-claim + verdict) to logs/ ---
archive_iter_artifacts() {
  local iter="$1"
  local iter_padded
  iter_padded=$(printf '%03d' "$iter")
  if [[ -f "$DONE_CLAIM_FILE" ]]; then
    cp "$DONE_CLAIM_FILE" "$LOGS_DIR/iter-${iter_padded}-done-claim.json" 2>/dev/null
  fi
  if [[ -f "$VERDICT_FILE" ]]; then
    cp "$VERDICT_FILE" "$LOGS_DIR/iter-${iter_padded}-verify-verdict.json" 2>/dev/null
  fi
}

# --- AC5: Write per-iteration cost estimate to cost-log.jsonl ---
write_cost_log() {
  local iter="$1"
  local iter_padded
  iter_padded=$(printf '%03d' "$iter")

  local prompt_bytes=0 claim_bytes=0 verdict_bytes=0
  local worker_prompt_file="$LOGS_DIR/iter-${iter_padded}.worker-prompt.md"
  [[ -f "$worker_prompt_file" ]] && prompt_bytes=$(wc -c < "$worker_prompt_file" 2>/dev/null || echo 0)
  [[ -f "$DONE_CLAIM_FILE" ]]   && claim_bytes=$(wc -c < "$DONE_CLAIM_FILE" 2>/dev/null || echo 0)
  [[ -f "$VERDICT_FILE" ]]      && verdict_bytes=$(wc -c < "$VERDICT_FILE" 2>/dev/null || echo 0)

  local estimated_tokens=$(( (prompt_bytes + claim_bytes + verdict_bytes) / 4 ))

  # AC1: per-phase timing fields
  local worker_start_time="" worker_end_time="" worker_duration_s=0
  local verifier_start_time="" verifier_end_time="" verifier_duration_s=0
  if [[ -n "${ITER_WORKER_START:-}" ]]; then
    worker_start_time=$(date -u -r "$ITER_WORKER_START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    worker_end_time=$(date -u -r "${ITER_WORKER_END:-$ITER_WORKER_START}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    worker_duration_s=$(( ${ITER_WORKER_END:-$ITER_WORKER_START} - ITER_WORKER_START ))
  fi
  if [[ -n "${ITER_VERIFIER_START:-}" ]]; then
    verifier_start_time=$(date -u -r "$ITER_VERIFIER_START" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    verifier_end_time=$(date -u -r "${ITER_VERIFIER_END:-$ITER_VERIFIER_START}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    verifier_duration_s=$(( ${ITER_VERIFIER_END:-$ITER_VERIFIER_START} - ITER_VERIFIER_START ))
  fi

  # AC2: consensus mode per-engine timing
  local consensus_fields=""
  if [[ -n "${ITER_VERIFIER_CLAUDE_DURATION_S:-}" ]]; then
    consensus_fields="${consensus_fields}"',"verifier_claude_duration_s":'"${ITER_VERIFIER_CLAUDE_DURATION_S}"
  fi
  if [[ -n "${ITER_VERIFIER_CODEX_DURATION_S:-}" ]]; then
    consensus_fields="${consensus_fields}"',"verifier_codex_duration_s":'"${ITER_VERIFIER_CODEX_DURATION_S}"
  fi

  echo '{"iteration":'"$iter"',"estimated_tokens":'"$estimated_tokens"',"token_source":"estimated","prompt_bytes":'"$prompt_bytes"',"claim_bytes":'"$claim_bytes"',"verdict_bytes":'"$verdict_bytes"',"worker_start_time":"'"$worker_start_time"'","worker_end_time":"'"$worker_end_time"'","worker_duration_s":'"$worker_duration_s"',"verifier_start_time":"'"$verifier_start_time"'","verifier_end_time":"'"$verifier_end_time"'","verifier_duration_s":'"$verifier_duration_s"''"$consensus_fields"',"timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$COST_LOG"
}

# --- Analytics: write per-iteration structured data to campaign.jsonl ---
write_campaign_jsonl() {
  if (( ! DEBUG )) && (( ! WITH_SELF_VERIFICATION )); then return 0; fi
  local iter="$1"
  local us_id="${2:-unknown}"
  local verdict="${3:-unknown}"

  local worker_duration_s=0
  local verifier_duration_s=0
  if [[ -n "${ITER_WORKER_START:-}" ]]; then
    worker_duration_s=$(( ${ITER_WORKER_END:-$(date +%s)} - ITER_WORKER_START ))
  fi
  if [[ -n "${ITER_VERIFIER_START:-}" ]]; then
    verifier_duration_s=$(( ${ITER_VERIFIER_END:-$(date +%s)} - ITER_VERIFIER_START ))
  fi

  jq -nc \
    --argjson iter "$iter" \
    --arg us_id "$us_id" \
    --arg worker_model "$WORKER_MODEL" \
    --arg worker_engine "$WORKER_ENGINE" \
    --arg verifier_engine "$VERIFIER_ENGINE" \
    --arg claude_verdict "${CLAUDE_VERDICT:-$verdict}" \
    --arg codex_verdict "${CODEX_VERDICT:-N/A}" \
    --argjson consensus "$VERIFY_CONSENSUS" \
    --argjson duration_worker_s "$worker_duration_s" \
    --argjson duration_verifier_s "$verifier_duration_s" \
    --arg project_root "$ROOT" \
    --arg slug "$SLUG" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{iter: $iter, us_id: $us_id, worker_model: $worker_model, worker_engine: $worker_engine, verifier_engine: $verifier_engine, claude_verdict: $claude_verdict, codex_verdict: $codex_verdict, consensus: $consensus, duration_worker_s: $duration_worker_s, duration_verifier_s: $duration_verifier_s, project_root: $project_root, slug: $slug, timestamp: $timestamp}' \
    >> "$CAMPAIGN_JSONL"
}

# --- AC4: Generate campaign-report.md on all terminal states ---
generate_campaign_report() {
  # Guard: idempotent — only generate once per campaign run
  if (( CAMPAIGN_REPORT_GENERATED )); then return 0; fi
  CAMPAIGN_REPORT_GENERATED=1

  local final_status="UNKNOWN"
  if [[ -f "$COMPLETE_SENTINEL" ]]; then final_status="COMPLETE"
  elif [[ -f "$BLOCKED_SENTINEL" ]]; then final_status="BLOCKED"
  else final_status="TIMEOUT"; fi

  local report_file="$LOGS_DIR/campaign-report.md"

  # AC9: Version existing report before writing new one
  if [[ -f "$report_file" ]]; then
    local v=1
    while [[ -f "${report_file%.md}-v${v}.md" ]]; do (( v++ )); done
    mv "$report_file" "${report_file%.md}-v${v}.md"
  fi

  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - START_TIME ))

  local baseline_commit_val="${BASELINE_COMMIT:-none}"
  local files_changed=""
  if [[ "$baseline_commit_val" != "none" ]]; then
    files_changed=$(git -C "$ROOT" diff --stat "${baseline_commit_val}" 2>/dev/null || echo "(git diff unavailable)")
  elif git -C "$ROOT" rev-parse HEAD &>/dev/null; then
    files_changed=$(git -C "$ROOT" diff --stat HEAD 2>/dev/null || echo "(git diff unavailable)")
  else
    files_changed="(no commits in repo — cannot diff)"
  fi
  # Include untracked new files
  local untracked
  untracked=$(git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null | head -20)
  if [[ -n "$untracked" ]]; then
    files_changed="${files_changed}

Untracked new files:
${untracked}"
  fi

  local sv_summary=""
  if (( WITH_SELF_VERIFICATION )); then
    local sv_report
    sv_report=$(ls -t "$ANALYTICS_DIR"/self-verification-report-*.md 2>/dev/null | head -1)
    if [[ -n "$sv_report" ]]; then
      sv_summary="See: $sv_report"
    else
      sv_summary="SV report generation pending — will be appended after this report."
    fi
  else
    sv_summary="N/A — --with-self-verification not enabled"
  fi

  {
    echo "# Campaign Report: $SLUG"
    echo ""
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ) | Status: $final_status | Iterations: $ITERATION"
    echo ""
    echo "## Objective"
    local prd_file="$DESK/plans/prd-$SLUG.md"
    if [[ -f "$prd_file" ]]; then
      grep '^## Objective' -A3 "$prd_file" 2>/dev/null | tail -n +2 | head -3
    else
      echo "(PRD not found)"
    fi
    echo ""
    echo "## Execution Summary"
    echo "- Terminal state: $final_status"
    echo "- Iterations run: $ITERATION / $MAX_ITER"
    echo "- Elapsed: ${elapsed}s"
    echo "- Worker model: $WORKER_MODEL ($WORKER_ENGINE)"
    echo "- Verifier model: $VERIFIER_MODEL ($VERIFIER_ENGINE)"
    echo "- Consensus: verify_consensus=$VERIFY_CONSENSUS consensus_scope=$CONSENSUS_SCOPE final_consensus=$FINAL_CONSENSUS"
    echo ""
    echo "## US Status"
    echo "- Verified: ${VERIFIED_US:-none}"
    echo "- Consecutive failures at end: $CONSECUTIVE_FAILURES"
    echo ""
    echo "## Verification Results"
    local ri=1
    while (( ri <= ITERATION )); do
      local iter_dc="$LOGS_DIR/iter-$(printf '%03d' $ri)-done-claim.json"
      if [[ -f "$iter_dc" ]]; then
        local us_id
        us_id=$(jq -r '.us_id // "unknown"' "$iter_dc" 2>/dev/null)
        echo "- $(basename "$iter_dc"): us_id=$us_id"
      fi
      (( ri++ ))
    done
    echo ""
    echo "## Issues Encountered"
    local fi_found=0
    local fi_i=1
    while (( fi_i <= ITERATION )); do
      local fix_f="$LOGS_DIR/iter-$(printf '%03d' $fi_i).fix-contract.md"
      if [[ -f "$fix_f" ]]; then
        echo "- $(basename "$fix_f")"
        fi_found=1
      fi
      (( fi_i++ ))
    done
    (( fi_found == 0 )) && echo "- None"
    echo ""
    echo "## Cost & Performance"
    if [[ -f "$COST_LOG" ]]; then
      local total_tokens=0
      while IFS= read -r line; do
        local t
        t=$(echo "$line" | jq -r '.estimated_tokens // 0' 2>/dev/null || echo 0)
        total_tokens=$(( total_tokens + t ))
      done < "$COST_LOG"
      echo "- Total estimated tokens: $total_tokens (source: estimated, tmux mode)"
      echo "- See: cost-log.jsonl for per-iteration breakdown"
    else
      echo "- No cost data available"
    fi
    echo ""
    echo "## SV Summary"
    echo "$sv_summary"
    echo ""
    echo "## Files Changed"
    echo '```'
    echo "$files_changed"
    echo '```'
    echo "Note: Files Changed may include pre-existing uncommitted changes if the campaign started in a dirty worktree."
    echo ""
    echo "## Suggested Next Actions"
    if [[ "$final_status" == "COMPLETE" ]]; then
      echo "- Review verified US list and plan next feature campaign or next cycle"
      echo "- Consider re-run with --mode improve for quality refinement"
      echo "- Archive campaign artifacts and update project documentation"
    elif [[ "$final_status" == "BLOCKED" ]]; then
      echo "- Review PRD acceptance criteria for the failing US"
      echo "- Check circuit breaker history (consecutive failures: $CONSECUTIVE_FAILURES)"
      echo "- Consider relaxing verifier criteria if false-negative pattern detected"
    elif [[ "$final_status" == "TIMEOUT" ]]; then
      echo "- Increase --max-iter to allow more iterations for completion"
      echo "- Reduce scope by splitting remaining US into a follow-up campaign"
      echo "- Review last iteration done-claim for partial progress"
    fi
  } | atomic_write "$report_file"

  log "Campaign report written: $report_file"
}

generate_sv_report() {
  # AC1-boundary: SV_REPORT_GENERATED guard (init + check + set = 3 occurrences)
  if (( SV_REPORT_GENERATED )); then return 0; fi

  # AC3-negative: early return if ! WITH_SELF_VERIFICATION flag not set
  if (( ! WITH_SELF_VERIFICATION )); then return 0; fi

  SV_REPORT_GENERATED=1

  # AC4: check claude CLI availability — graceful degradation, not exit 1
  if ! command -v claude &>/dev/null; then
    echo "SV report generation failed: claude CLI not found" >> "$LOGS_DIR/campaign-report.md"
    return 0
  fi

  # AC2: versioning — find next available sv_version slot (in logs dir)
  local sv_version=1
  while [[ -f "$LOGS_DIR/self-verification-report-$(printf '%03d' $sv_version).md" ]]; do
    (( sv_version++ ))
  done
  local sv_report_file="$LOGS_DIR/self-verification-report-$(printf '%03d' $sv_version).md"

  log "Generating SV report: $(basename "$sv_report_file")"

  # AC5: configurable timeout with in-process watchdog
  local _sv_timeout_secs="${_SV_TIMEOUT_SECS:-300}"
  local _sv_timeout_flag=0
  local _sv_timeout_file="$LOGS_DIR/.sv_timeout_${$}.tmp"
  rm -f "$_sv_timeout_file"

  # Spawn claude CLI in background — write to sv_report_file
  claude --print "Analyze campaign artifacts in $LOGS_DIR and generate a self-verification report with sections: 1. Automated Validation Summary, 2. Failure Deep Dive, 3. Worker Process Quality, 4. Verifier Judgment Quality, 5. AC Lifecycle, 6. Test-Spec Adherence, 7. Patterns: Strengths & Weaknesses, 8. Recommendations for Next Cycle, 9. Cost & Performance, 10. Blind Spots." \
    > "$sv_report_file" 2>/dev/null &
  local _sv_pid=$!

  # AC5: watchdog — signals timeout file THEN kills _sv_pid after _sv_timeout_secs
  local _sv_watchdog
  (
    sleep "$_sv_timeout_secs"
    if kill -0 "$_sv_pid" 2>/dev/null; then
      touch "$_sv_timeout_file"
      kill "$_sv_pid" 2>/dev/null
    fi
  ) &
  _sv_watchdog=$!

  wait "$_sv_pid"
  local _sv_exit=$?
  kill "$_sv_watchdog" 2>/dev/null
  wait "$_sv_watchdog" 2>/dev/null

  # AC5: detect timeout — exit code 124 or watchdog file present
  if [[ "$_sv_exit" == 124 ]] || [[ -f "$_sv_timeout_file" ]]; then
    _sv_timeout_flag=1
    rm -f "$_sv_timeout_file"
    local _timeout_msg="SV report generation TIMEOUT: exceeded ${_sv_timeout_secs}s"
    echo "$_timeout_msg" >> "$sv_report_file"
    echo "$_timeout_msg" >> "$LOGS_DIR/campaign-report.md"
    log "$_timeout_msg"
    return 0
  fi

  # On success: append reference to campaign-report (full path, cross-directory)
  echo "See: $sv_report_file" >> "$LOGS_DIR/campaign-report.md"
  log "SV report written: $sv_report_file"
  return 0
}

# =============================================================================
# Sentinel Writers
# =============================================================================

# --- governance.md s7: Only the Leader writes sentinels ---
write_complete_sentinel() {
  local summary="$1"
  echo "# Campaign Complete

Completed at iteration $ITERATION.
$summary

Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | atomic_write "$COMPLETE_SENTINEL"
  log "COMPLETE sentinel written: $COMPLETE_SENTINEL"
}

write_blocked_sentinel() {
  local reason="$1"
  echo "# Campaign Blocked

Blocked at iteration $ITERATION.
Reason: $reason

Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | atomic_write "$BLOCKED_SENTINEL"
  log "BLOCKED sentinel written: $BLOCKED_SENTINEL"
}

# =============================================================================
# Cleanup (trap handler)
# =============================================================================

cleanup() {
  log "Cleaning up..."

  # Remove lockfile
  if (( LOCKFILE_ACQUIRED )); then
    rm -f "$LOCKFILE_PATH" 2>/dev/null
  else
    log_debug "cleanup: lockfile not owned by this process, skipping removal"
  fi

  # Kill claude processes then kill panes
  log_debug "cleanup: WORKER_PANE=${WORKER_PANE:-unset} VERIFIER_PANE=${VERIFIER_PANE:-unset}"
  if [[ -n "${WORKER_PANE:-}" ]]; then
    tmux send-keys -t "$WORKER_PANE" C-c 2>/dev/null
    tmux send-keys -t "$WORKER_PANE" "/exit" Enter 2>/dev/null
  fi
  if [[ -n "${VERIFIER_PANE:-}" ]]; then
    tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
    tmux send-keys -t "$VERIFIER_PANE" "/exit" Enter 2>/dev/null
  fi
  sleep 2
  # Kill panes on completion
  if [[ -n "${WORKER_PANE:-}" ]]; then
    tmux kill-pane -t "$WORKER_PANE" 2>/dev/null
  fi
  if [[ -n "${VERIFIER_PANE:-}" ]]; then
    tmux kill-pane -t "$VERIFIER_PANE" 2>/dev/null
  fi
  log "  Panes cleaned up."

  # Remove any leftover tmp files (setopt nonomatch to avoid zsh glob errors)
  setopt local_options nonomatch 2>/dev/null
  rm -f "$LOGS_DIR"/*.tmp.* "$MEMOS_DIR"/*.tmp.* 2>/dev/null

  # AC4: Generate campaign report on all terminal states (always-on)
  generate_campaign_report

  # US-001: Generate SV report after campaign report (tmux mode)
  generate_sv_report

  # Print summary
  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - START_TIME ))
  local minutes=$(( elapsed / 60 ))
  local seconds=$(( elapsed % 60 ))

  local final_status="UNKNOWN"
  if [[ -f "$COMPLETE_SENTINEL" ]]; then final_status="COMPLETE"
  elif [[ -f "$BLOCKED_SENTINEL" ]]; then final_status="BLOCKED"
  else final_status="TIMEOUT"; fi

  # --- Update metadata.json with final status ---
  if [[ -f "$METADATA_FILE" ]]; then
    jq --arg status "$final_status" --arg end_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '.campaign_status = $status | .end_time = $end_time' \
      "$METADATA_FILE" > "${METADATA_FILE}.tmp" && mv "${METADATA_FILE}.tmp" "$METADATA_FILE"
  fi

  if (( DEBUG )); then
    local end_ts=$(date +%s)
    local elapsed=$((end_ts - START_TIME))

    log_debug "[FLOW] final status=$final_status iterations=$ITERATION elapsed=${elapsed}s"

    # --- Validation ---
    log_debug "[FLOW] === Execution Validation ==="

    # 1. Did the correct verify mode run?
    log_debug "[FLOW] verify_mode=$VERIFY_MODE configured=true"

    # 2. Per-US: were all US individually verified?
    if [[ "$VERIFY_MODE" = "per-us" ]]; then
      local prd_file="$DESK/plans/prd-$SLUG.md"
      local expected_us=""
      if [[ -f "$prd_file" ]]; then
        expected_us=$(grep -oE 'US-[0-9]+' "$prd_file" | sort -u | tr '\n' ',' | sed 's/,$//')
      fi
      local verified_count=$(echo "$VERIFIED_US" | tr ',' '\n' | grep -c 'US-' 2>/dev/null || echo 0)
      local expected_count=$(echo "$expected_us" | tr ',' '\n' | grep -c 'US-' 2>/dev/null || echo 0)

      if [[ "$final_status" = "COMPLETE" ]]; then
        if (( verified_count >= expected_count )); then
          log_debug "[FLOW] per_us_coverage=PASS verified=$verified_count/$expected_count us=$VERIFIED_US"
        else
          log_debug "[FLOW] per_us_coverage=FAIL verified=$verified_count/$expected_count expected=$expected_us got=$VERIFIED_US"
        fi
      else
        log_debug "[FLOW] per_us_coverage=INCOMPLETE verified=$verified_count/$expected_count status=$final_status"
      fi
    fi

    # 3. Consensus: were both engines used?
    if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
      if [[ -n "${CLAUDE_VERDICT:-}" && -n "${CODEX_VERDICT:-}" ]]; then
        log_debug "[FLOW] consensus=USED claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT rounds=$CONSENSUS_ROUND"
      else
        log_debug "[FLOW] consensus=NOT_TRIGGERED claude=${CLAUDE_VERDICT:-none} codex=${CODEX_VERDICT:-none}"
      fi
    fi

    # 4. Engine match: did the configured engines actually run?
    local worker_dispatches=$(grep -c '\[FLOW\].*phase=worker.*dispatched=true' "$DEBUG_LOG" 2>/dev/null || echo 0)
    local verifier_dispatches=$(grep -c '\[FLOW\].*phase=verifier.*dispatched=true' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[FLOW] dispatches worker=$worker_dispatches verifier=$verifier_dispatches"

    # 5. Fix loops: how many fix contracts were generated?
    local fix_count=$(grep -c '\[DECIDE\].*phase=fix_loop' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[FLOW] fix_loops=$fix_count consecutive_failures=$CONSECUTIVE_FAILURES"

    # 6. Circuit breakers: any triggered?
    local cb_count=$(grep -c '\[GOV\].*circuit_breaker=' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[FLOW] circuit_breakers_triggered=$cb_count"

    # 7. Overall result
    log_debug "[FLOW] result=$final_status iterations=$ITERATION elapsed=${elapsed}s verified_us=$VERIFIED_US"
  fi

  echo ""
  echo "============================================================"
  echo "  Ralph Desk Tmux Runner - Session Complete"
  echo "============================================================"
  echo "  Session:    $SESSION_NAME"
  echo "  Slug:       $SLUG"
  echo "  Iterations: $ITERATION / $MAX_ITER"
  echo "  Elapsed:    ${minutes}m ${seconds}s"
  echo ""

  if [[ -f "$COMPLETE_SENTINEL" ]]; then
    echo "  Final State: COMPLETE"
  elif [[ -f "$BLOCKED_SENTINEL" ]]; then
    echo "  Final State: BLOCKED"
  else
    echo "  Final State: STOPPED (interrupted or timeout)"
  fi

  echo ""
  echo "  Tmux session left alive for inspection:"
  echo "    tmux attach -t $SESSION_NAME"
  echo "    tmux kill-session -t $SESSION_NAME"
  echo "============================================================"
}

# =============================================================================
# Poll Loop (used for both Worker and Verifier)
# =============================================================================

# --- governance.md s7 step 5+6: Poll for signal file with heartbeat monitoring ---
poll_for_signal() {
  local signal_file="$1"
  local heartbeat_file="$2"
  local pane_id="$3"
  local trigger_file="$4"
  local role="$5"  # "worker" or "verifier"
  local nudge_count=0
  local api_retry_count=0
  local poll_start
  poll_start=$(date +%s)

  # Initialize idle tracking for this pane
  LAST_PANE_CONTENT[$pane_id]=""
  PANE_IDLE_SINCE[$pane_id]=$(date +%s)

  while true; do
    local now
    now=$(date +%s)
    local elapsed=$(( now - poll_start ))

    # Per-iteration timeout check
    if (( elapsed >= ITER_TIMEOUT )); then
      log_error "$role timed out after ${ITER_TIMEOUT}s for iteration $ITERATION"
      return 1  # timeout
    fi

    # Check if signal file appeared
    if [[ -f "$signal_file" ]]; then
      log "  Signal file detected: $signal_file"
      return 0  # success
    fi

    # A4 fallback: done-claim exists but no signal → Worker forgot iter-signal
    # ONLY for Worker polling — Verifier waits for verdict file, not done-claim
    if [[ "$role" != *erifier* && -f "$DONE_CLAIM_FILE" && ! -f "$signal_file" ]]; then
      local dc_us_id
      dc_us_id=$(jq -r '.us_id // "unknown"' "$DONE_CLAIM_FILE" 2>/dev/null)
      if [[ -n "$dc_us_id" && "$dc_us_id" != "null" ]]; then
        log "  WARNING: done-claim exists for $dc_us_id but no iter-signal. Auto-generating signal (A4 fallback)."
        log_debug "[GOV] iter=$ITERATION done_claim_without_signal=true us_id=$dc_us_id action=auto_generate_signal"
        echo '{"iteration":'"$ITERATION"',"status":"verify","us_id":"'"$dc_us_id"'","summary":"auto-generated by A4 fallback (done-claim without signal)","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "$signal_file"
        return 0
      fi
    fi

    # API transient-error recovery with bounded backoff
    local pane_output_for_retry
    pane_output_for_retry=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
    local is_api_text_retry=0
    if [[ -n "$pane_output_for_retry" ]] &&
       ( echo "$pane_output_for_retry" | grep -qiE '(^|[^[:digit:]])500([^[:digit:]]|$)' \
      || echo "$pane_output_for_retry" | grep -qiE '(^|[^[:digit:]])529([^[:digit:]]|$)' \
      || echo "$pane_output_for_retry" | grep -qi 'overloaded' \
      || echo "$pane_output_for_retry" | grep -qi 'too many requests' \
      || echo "$pane_output_for_retry" | grep -qi 'service unavailable' ); then
      is_api_text_retry=1
    fi

    if (( is_api_text_retry )) || is_api_error "$pane_id"; then
      (( api_retry_count++ ))
      log_debug "[FLOW] iter=$ITERATION api_retry=${api_retry_count}/${_API_MAX_RETRIES} role=${role} reason=tmux_pane_api_error"
      if (( api_retry_count >= _API_MAX_RETRIES )); then
        log_error "API unavailable after ${_API_MAX_RETRIES} retries"
        write_blocked_sentinel "API unavailable after ${_API_MAX_RETRIES} retries"
        return 2
      fi
      sleep "$_API_RETRY_INTERVAL_S"
      continue
    else
      api_retry_count=0
    fi

    # Check heartbeat freshness (tmux pattern)
    if [[ -f "$heartbeat_file" ]]; then
      if check_heartbeat_exited "$heartbeat_file"; then
        # Process exited but no signal file -- give a brief grace period
        sleep 3
        if [[ -f "$signal_file" ]]; then
          log "  Signal file detected after process exit: $signal_file"
          return 0
        fi
        # Dispatch to engine-specific exit handler
        if [[ "$WORKER_ENGINE" = "codex" && "$role" != *erifier* ]]; then
          handle_worker_exit_codex "$ITERATION" "$signal_file"
          return 0
        fi
        # Claude path (or verifier of any engine)
        if handle_worker_exit_claude "$pane_id" "$ITERATION" "$trigger_file"; then
          # Reset poll timer for the restart
          poll_start=$(date +%s)
          nudge_count=0
          LAST_PANE_CONTENT[$pane_id]=""
          PANE_IDLE_SINCE[$pane_id]=$(date +%s)
          sleep "$POLL_INTERVAL"
          continue
        else
          return 1  # max restarts exceeded
        fi
      fi

      if ! check_heartbeat "$heartbeat_file"; then
        log "  WARNING: $role heartbeat stale (>${HEARTBEAT_STALE_THRESHOLD}s)"
        (( HEARTBEAT_STALE_COUNT++ ))
        # Circuit breaker: 3 consecutive heartbeat stale events
        if (( HEARTBEAT_STALE_COUNT >= 3 )); then
          log_debug "[GOV] iter=$ITERATION circuit_breaker=heartbeat_stale detail=\"3 consecutive heartbeat stale events\""
          log_error "Circuit breaker: 3 consecutive heartbeat stale events"
          return 1
        fi
        # Attempt restart
        if restart_worker "$pane_id" "$ITERATION" "$trigger_file"; then
          poll_start=$(date +%s)
          nudge_count=0
          continue
        else
          return 1
        fi
      else
        # Heartbeat is fresh, reset stale counter
        HEARTBEAT_STALE_COUNT=0
      fi
    fi

    # Dead pane detection during poll: check if claude/codex process died
    local poll_cmd
    poll_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null)
    # Dead pane detection — delegates to check_dead_pane() for engine-aware logic
    if check_dead_pane "$poll_cmd" "$WORKER_ENGINE" "$role"; then
      log "  WARNING: $role pane $pane_id has bare shell ($poll_cmd) — process died during execution"
      log_debug "[GOV] iter=$ITERATION pane_dead_during_poll=true pane=$pane_id cmd=$poll_cmd role=$role"
      # Return failure so caller can handle recovery
      return 1
    fi

    # Auto-approve permission prompts during poll
    local poll_capture
    poll_capture=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$poll_capture" | grep -q "Do you want to" 2>/dev/null; then
      log "  Permission prompt detected during poll, auto-approving..."
      log_debug "[FLOW] iter=$ITERATION permission_prompt_auto_approved=true"
      tmux send-keys -t "$pane_id" Enter
      sleep 0.5
    fi

    # Idle pane nudging (tmux pattern)
    check_and_nudge_idle_pane "$pane_id" "nudge_count"

    sleep "$POLL_INTERVAL"
  done
}

# =============================================================================
# Circuit Breaker: Stale Context Detection
# =============================================================================

# --- US-004: Live PRD update helpers ---
compute_prd_hash() {
  local prd_file="${PRD_FILE:-}"
  if [[ -z "$prd_file" && -n "${DESK:-}" && -n "${SLUG:-}" ]]; then
    prd_file="$DESK/plans/prd-$SLUG.md"
  fi
  if [[ -f "$prd_file" ]]; then
    md5 -q "$prd_file" 2>/dev/null || md5sum "$prd_file" 2>/dev/null | cut -d' ' -f1
  else
    echo ""
  fi
}

count_prd_us() {
  local prd_file="${PRD_FILE:-}"
  if [[ -z "$prd_file" && -n "${DESK:-}" && -n "${SLUG:-}" ]]; then
    prd_file="$DESK/plans/prd-$SLUG.md"
  fi
  if [[ -f "$prd_file" ]]; then
    grep -oE '^### US-[0-9]+' "$prd_file" 2>/dev/null | sed 's/^### //' | sort -u | tr '\n' ',' | sed 's/,$//'
  else
    echo ""
  fi
}

split_prd_by_us() {
  local prd_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$prd_file")"

  [[ -f "$prd_file" ]] || return 0

  local us_count
  us_count=$(grep -oE '^### US-' "$prd_file" 2>/dev/null | wc -l | tr -d ' ') || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    return 0
  fi

  awk -v dir="$plans_dir" -v slug="$slug" '
    /^### US-[0-9]+:/ {
      if (out != "") close(out)
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = dir "/prd-" slug "-" us_id ".md"
    }
    out != "" { print > out }
  ' "$prd_file"
}

split_test_spec_by_us() {
  local ts_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$ts_file")"

  [[ -f "$ts_file" ]] || return 0

  local us_count
  us_count=$(grep -oE '^## US-' "$ts_file" 2>/dev/null | wc -l | tr -d ' ') || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    return 0
  fi

  local header_tmp="${plans_dir}/test-spec-${slug}-header.tmp.$$"
  awk '/^## US-[0-9]+:/{exit} {print}' "$ts_file" > "$header_tmp"

  awk -v dir="$plans_dir" -v slug="$slug" '
    /^## US-[0-9]+:/ {
      if (out != "") close(out)
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = dir "/test-spec-" slug "-" us_id ".md"
    }
    out != "" { print > out }
  ' "$ts_file"

  for split_file in "$plans_dir"/test-spec-"$slug"-US-*.md; do
    [[ -f "$split_file" ]] || continue
    local tmp="${split_file}.tmp.$$"
    cat "$header_tmp" "$split_file" > "$tmp" && mv "$tmp" "$split_file"
  done
  rm -f "$header_tmp"
}

check_prd_update() {
  local current_hash current_us_list us_count_prev us_count_now new_us
  current_hash=$(compute_prd_hash)
  current_us_list=$(count_prd_us)
  us_count_prev=$(echo "$PREV_PRD_US_LIST" | tr ',' '\n' | grep -c 'US-' 2>/dev/null || echo 0)
  us_count_now=$(echo "$current_us_list" | tr ',' '\n' | grep -c 'US-' 2>/dev/null || echo 0)

  _PRD_CHANGED=0

  if [[ "$current_hash" != "$PREV_PRD_HASH" ]]; then
    _PRD_CHANGED=1
    new_us=$(printf '%s\n' "$current_us_list" | tr ',' '\n' | awk -v prev="$PREV_PRD_US_LIST" '
      BEGIN {
        split(prev, p, ",")
        for (i in p) {
          seen[p[i]] = 1
        }
      }
      {
        if ($0 != "" && !seen[$0]) {
          if (out == "") out = $0
          else out = out "," $0
        }
      }
      END { print out }
    ')
    log_debug "prd_changed=true prd_hash_prev=${PREV_PRD_HASH:-none} prd_hash_now=${current_hash:-none} us_count_prev=${us_count_prev} us_count_now=${us_count_now} new_us=${new_us:-none}"
    split_prd_by_us "$PRD_FILE" "$SLUG"
    split_test_spec_by_us "$TEST_SPEC_FILE" "$SLUG"
    US_LIST="$current_us_list"
  else
    log_debug "prd_changed=false prd_hash_prev=${PREV_PRD_HASH:-none} prd_hash_now=${current_hash:-none} us_count_prev=${us_count_prev} us_count_now=${us_count_now}"
  fi

  PREV_PRD_HASH="$current_hash"
  PREV_PRD_US_LIST="$current_us_list"
}

# --- governance.md s7 step 8: Stale context detection ---
compute_context_hash() {
  # Hash context-latest.md + memory.md + verified_us from status.json
  # This prevents false stale detection when Worker updates memory but not context,
  # or when verified_us changes between iterations
  local hash_input=""
  if [[ -f "$CONTEXT_FILE" ]]; then
    hash_input+=$(md5 -q "$CONTEXT_FILE" 2>/dev/null || md5sum "$CONTEXT_FILE" 2>/dev/null | cut -d' ' -f1)
  fi
  local memory_file="$DESK/memos/${SLUG}-memory.md"
  if [[ -f "$memory_file" ]]; then
    hash_input+=$(md5 -q "$memory_file" 2>/dev/null || md5sum "$memory_file" 2>/dev/null | cut -d' ' -f1)
  fi
  if [[ -f "$STATUS_FILE" ]]; then
    hash_input+=$(jq -r '.verified_us // [] | join(",")' "$STATUS_FILE" 2>/dev/null)
  fi
  echo -n "$hash_input" | md5 -q 2>/dev/null || echo -n "$hash_input" | md5sum 2>/dev/null | cut -d' ' -f1
}

check_stale_context() {
  local current_hash
  current_hash=$(compute_context_hash)

  if [[ "$current_hash" == "$PREV_CONTEXT_HASH" ]]; then
    (( STALE_CONTEXT_COUNT++ ))
    log "  WARNING: Context unchanged ($STALE_CONTEXT_COUNT/3 stale iterations)"
    if (( STALE_CONTEXT_COUNT >= 3 )); then
      log_error "Circuit breaker: context unchanged for 3 consecutive iterations"
      return 1
    fi
  else
    STALE_CONTEXT_COUNT=0
  fi

  PREV_CONTEXT_HASH="$current_hash"
  return 0
}

# =============================================================================
# Consensus Verification (run two verifiers sequentially in same pane)
# =============================================================================

# --- US-004: Run a single verifier in the Verifier pane and poll for verdict ---
run_single_verifier() {
  local iter="$1"
  local engine="$2"       # claude|codex
  local model="$3"        # model for this verifier
  local suffix="$4"       # "-claude" or "-codex"
  local verdict_dest="$5" # where to copy the verdict file

  # Write trigger for this engine
  write_verifier_trigger "$iter" "$engine" "$model" "$suffix"
  local trigger_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-trigger.sh"
  local prompt_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-prompt.md"

  # Clean previous Verifier session (with dead pane detection)
  local verifier_cmd
  verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
  if [[ -z "$verifier_cmd" ]]; then
    log "  Verifier pane $VERIFIER_PANE is gone — replacing..."
    log_debug "[GOV] iter=$iter pane_dead=true pane_id=$VERIFIER_PANE action=replace_pane"
    replace_worker_pane "$VERIFIER_PANE" "verifier"
    VERIFIER_PANE=$(jq -r '.panes.verifier' "$SESSION_CONFIG")
    log "  New verifier pane: $VERIFIER_PANE"
  elif [[ "$verifier_cmd" == "zsh" || "$verifier_cmd" == "bash" ]]; then
    log "  Verifier pane $VERIFIER_PANE has bare shell ($verifier_cmd) — resetting..."
    log_debug "[GOV] iter=$iter pane_dead=true pane_id=$VERIFIER_PANE cmd=$verifier_cmd action=reset_shell"
    tmux send-keys -t "$VERIFIER_PANE" C-c C-u 2>/dev/null
    sleep 0.2
    tmux send-keys -t "$VERIFIER_PANE" "clear" Enter 2>/dev/null
    sleep 0.3
  elif [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
    tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
    sleep 0.5
    tmux send-keys -t "$VERIFIER_PANE" "/exit" Enter 2>/dev/null
    sleep 2
  fi
  # Always ensure clean shell state before launching new verifier
  wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true
  # Clear pane to avoid residual text interference
  tmux send-keys -t "$VERIFIER_PANE" C-l 2>/dev/null
  sleep 0.5

  # Remove previous verdict file
  rm -f "$VERDICT_FILE" 2>/dev/null

  # Launch verifier — dispatch to engine-specific function
  local verifier_launch
  if [[ "$engine" = "codex" ]]; then
    verifier_launch="${CODEX_BIN:-codex} exec \"\$(cat $prompt_file)\" -m $VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
    launch_verifier_codex "$VERIFIER_PANE" "$prompt_file" "$iter" "$verifier_launch"
    log_debug "Verifier$suffix codex exec dispatched"
  else
    verifier_launch="$CLAUDE_BIN --model $model --dangerously-skip-permissions"
    if ! launch_verifier_claude "$VERIFIER_PANE" "$prompt_file" "$iter" "$verifier_launch"; then
      log_error "Verifier$suffix failed to start"
      return 1
    fi
    log_debug "Verifier$suffix claude dispatched"
  fi

  # Poll for verdict
  if [[ "$engine" = "codex" ]]; then
    # Codex exec: simple file poll (non-interactive, no heartbeat/nudge needed)
    log "  Polling for verify-verdict.json ($suffix, codex exec)..."
    local codex_poll_start
    codex_poll_start=$(date +%s)
    while true; do
      if [[ -f "$VERDICT_FILE" ]]; then
        # Validate JSON
        if jq . "$VERDICT_FILE" >/dev/null 2>&1; then
          log "  Verdict file detected: $VERDICT_FILE"
          break
        fi
      fi
      local codex_elapsed=$(( $(date +%s) - codex_poll_start ))
      if (( codex_elapsed >= ITER_TIMEOUT )); then
        log_error "Codex verifier$suffix timed out after ${ITER_TIMEOUT}s"
        return 1
      fi
      sleep "$POLL_INTERVAL"
    done
  else
    # Claude: use full poll_for_signal with heartbeat/nudge
    log "  Polling for verify-verdict.json ($suffix)..."
    if ! poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier$suffix"; then
      local verifier_poll_rc=$?
      if (( verifier_poll_rc == 2 )); then
        return 1
      fi
      log_error "Verifier$suffix poll failed"
      return 1
    fi
  fi

  # Copy verdict to destination
  cp "$VERDICT_FILE" "$verdict_dest"
  log "  Verifier$suffix verdict saved to $verdict_dest"
  return 0
}

# --- US-005: Determine whether consensus verification should run for this signal ---
# Returns 0 (use consensus) or 1 (single engine).
# VERIFY_CONSENSUS + CONSENSUS_SCOPE handles per-US consensus.
# FINAL_CONSENSUS independently enables consensus for the final ALL verify only.
_should_use_consensus() {
  local signal_us_id="${1:-}"
  if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
    case "$CONSENSUS_SCOPE" in
      all) return 0 ;;
      final-only) [[ "$signal_us_id" == "ALL" ]] && return 0 ;;
    esac
  fi
  if [[ "$FINAL_CONSENSUS" = "1" && "$signal_us_id" == "ALL" ]]; then
    return 0
  fi
  return 1
}

# --- US-004: Run consensus verification (claude + codex sequentially) ---
run_consensus_verification() {
  local iter="$1"
  local claude_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-claude.json"
  local codex_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-codex.json"

  CONSENSUS_ROUND=0
  CLAUDE_VERDICT=""
  CODEX_VERDICT=""

  while (( CONSENSUS_ROUND < 6 )); do
    (( CONSENSUS_ROUND++ ))
    log "  Consensus round $CONSENSUS_ROUND/6..."

    # Run claude verifier first
    local _claude_t0=$(date +%s)
    if ! run_single_verifier "$iter" "claude" "$VERIFIER_MODEL" "-claude" "$claude_verdict_file"; then
      log_error "Claude verifier failed in consensus round $CONSENSUS_ROUND"
      return 1
    fi
    ITER_VERIFIER_CLAUDE_DURATION_S=$(( $(date +%s) - _claude_t0 ))
    CLAUDE_VERDICT=$(jq -r '.verdict' "$claude_verdict_file" 2>/dev/null)
    # A12 fix: validate claude verdict is not null/empty — if so, retry once before proceeding
    if [[ -z "$CLAUDE_VERDICT" || "$CLAUDE_VERDICT" == "null" ]]; then
      log "  WARNING: Claude verdict is '$CLAUDE_VERDICT' — likely interrupted. Retrying claude verifier..."
      log_debug "[GOV] iter=$iter phase=consensus_claude_retry reason=null_verdict"
      rm -f "$claude_verdict_file" 2>/dev/null
      if ! run_single_verifier "$iter" "claude" "$VERIFIER_MODEL" "-claude" "$claude_verdict_file"; then
        log_error "Claude verifier retry also failed"
        return 1
      fi
      CLAUDE_VERDICT=$(jq -r '.verdict' "$claude_verdict_file" 2>/dev/null)
      if [[ -z "$CLAUDE_VERDICT" || "$CLAUDE_VERDICT" == "null" ]]; then
        log_error "Claude verdict still null after retry — consensus cannot proceed"
        return 1
      fi
    fi
    log_debug "[GOV] iter=$iter phase=consensus_claude verdict=$CLAUDE_VERDICT model=$VERIFIER_MODEL"

    # Run codex verifier second
    local _codex_t0=$(date +%s)
    if ! run_single_verifier "$iter" "codex" "$VERIFIER_CODEX_MODEL" "-codex" "$codex_verdict_file"; then
      log_error "Codex verifier failed in consensus round $CONSENSUS_ROUND"
      return 1
    fi
    ITER_VERIFIER_CODEX_DURATION_S=$(( $(date +%s) - _codex_t0 ))
    CODEX_VERDICT=$(jq -r '.verdict' "$codex_verdict_file" 2>/dev/null)
    log_debug "[GOV] iter=$iter phase=consensus_codex verdict=$CODEX_VERDICT model=$VERIFIER_CODEX_MODEL reasoning=$VERIFIER_CODEX_REASONING"

    log "  Consensus: claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT"
    local _combined_action="retry"
    if [[ "$CLAUDE_VERDICT" = "pass" && "$CODEX_VERDICT" = "pass" ]]; then _combined_action="pass"
    elif (( CONSENSUS_ROUND >= 6 )); then _combined_action="blocked"
    fi
    log_debug "[GOV] iter=$iter phase=consensus round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT combined_action=$_combined_action"

    # Both pass → success
    if [[ "$CLAUDE_VERDICT" = "pass" && "$CODEX_VERDICT" = "pass" ]]; then
      # Create merged verdict with per-engine details
      {
        echo '{'
        echo '  "verdict": "pass",'
        echo '  "verified_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
        echo '  "summary": "Consensus PASS: both claude and codex verified independently",'
        echo '  "recommended_state_transition": "complete",'
        echo '  "consensus": {'
        echo '    "claude": { "verdict": "pass", "file": "'"$claude_verdict_file"'" },'
        echo '    "codex": { "verdict": "pass", "file": "'"$codex_verdict_file"'" },'
        echo '    "round": '"$CONSENSUS_ROUND"
        echo '  }'
        echo '}'
      } | atomic_write "$VERDICT_FILE"
      return 0
    fi

    # Consensus disagreement
    log_debug "[GOV] iter=$iter phase=consensus_disagreement round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT action=fix_contract"

    # NOTE: pre_existing_failure heuristic was removed (v0.3.5).
    # It used unreliable grep-in-description string matching to classify
    # consensus failures as "pre-existing", bypassing the consensus rule.
    # Consensus disagreement now ALWAYS flows to fix contract.
    # Codex CLI crash (no verdict file) is handled upstream via run_single_verifier return 1 → BLOCKED.

    # --- Consensus disagreement: build fix contract ---
    local fix_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
    {
      echo "# Fix Contract (Consensus Round $CONSENSUS_ROUND, iteration $iter)"
      echo ""
      echo "## Claude Verdict: $CLAUDE_VERDICT"
      if [[ "$CLAUDE_VERDICT" = "fail" ]]; then
        echo "### Claude Issues"
        jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.criterion // "?"): \(.description // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$claude_verdict_file" 2>/dev/null || echo "- (no structured issues)"
      fi
      echo ""
      echo "## Codex Verdict: $CODEX_VERDICT"
      if [[ "$CODEX_VERDICT" = "fail" ]]; then
        echo "### Codex Issues"
        jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.criterion // "?"): \(.description // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$codex_verdict_file" 2>/dev/null || echo "- (no structured issues)"
      fi
      echo ""
      echo "## Traceability"
      echo "Only changes that resolve a listed issue are allowed."
    } | atomic_write "$fix_contract"

    log "  Combined fix contract: $fix_contract"

    # If this is not the last round, the caller will dispatch the Worker with the fix contract
    # For now, write a fail verdict so the main loop can handle the fix loop
    if (( CONSENSUS_ROUND < 6 )); then
      # Create a merged fail verdict for the main loop — include issues from BOTH verdicts
      local merged_issues="[]"
      local claude_issues codex_issues
      claude_issues=$(jq -c '[.issues[]? | . + {"source": "claude"}]' "$claude_verdict_file" 2>/dev/null || echo '[]')
      codex_issues=$(jq -c '[.issues[]? | . + {"source": "codex"}]' "$codex_verdict_file" 2>/dev/null || echo '[]')
      merged_issues=$(echo "$claude_issues $codex_issues" | jq -s 'add // []')
      {
        echo '{'
        echo '  "verdict": "fail",'
        echo '  "verified_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
        echo '  "summary": "Consensus disagreement (round '"$CONSENSUS_ROUND"'/6): claude='"$CLAUDE_VERDICT"' codex='"$CODEX_VERDICT"'",'
        echo '  "issues": '"$merged_issues"','
        echo '  "recommended_state_transition": "continue",'
        echo '  "consensus": { "claude": "'"$CLAUDE_VERDICT"'", "codex": "'"$CODEX_VERDICT"'", "round": '"$CONSENSUS_ROUND"' }'
        echo '}'
      } | atomic_write "$VERDICT_FILE"
      return 2  # special return: consensus disagreement, needs retry
    fi
  done

  # Max consensus rounds exceeded — include issues from both verdicts
  log_error "Consensus failed after 6 rounds"
  local final_claude_issues final_codex_issues final_merged_issues
  final_claude_issues=$(jq -c '[.issues[]? | . + {"source": "claude"}]' "$claude_verdict_file" 2>/dev/null || echo '[]')
  final_codex_issues=$(jq -c '[.issues[]? | . + {"source": "codex"}]' "$codex_verdict_file" 2>/dev/null || echo '[]')
  final_merged_issues=$(echo "$final_claude_issues $final_codex_issues" | jq -s 'add // []')
  {
    echo '{'
    echo '  "verdict": "fail",'
    echo '  "verified_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
    echo '  "summary": "Consensus failed after 6 rounds: claude='"$CLAUDE_VERDICT"' codex='"$CODEX_VERDICT"'",'
    echo '  "issues": '"$final_merged_issues"','
    echo '  "recommended_state_transition": "blocked",'
    echo '  "consensus": { "claude": "'"$CLAUDE_VERDICT"'", "codex": "'"$CODEX_VERDICT"'", "round": 6 }'
    echo '}'
  } | atomic_write "$VERDICT_FILE"
  return 1
}

# =============================================================================
# Security Warning
# =============================================================================

print_security_warning() {
  echo ""
  echo "================================================================"
  echo "  WARNING: Running with --dangerously-skip-permissions"
  echo ""
  echo "  The claude CLI will execute tools (file writes, shell commands)"
  echo "  without asking for confirmation. Only run this on code you"
  echo "  trust in an environment you control."
  echo "================================================================"
  echo ""
}

# =============================================================================
# Main Leader Loop
# =============================================================================

main() {
  # --- Lockfile: prevent duplicate execution ---
  local lockfile="$LOCKFILE_PATH"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null
  if ! (set -C; echo $$ > "$lockfile") 2>/dev/null; then
    local lock_pid
    lock_pid=$(cat "$lockfile" 2>/dev/null)
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_error "Another instance is already running (PID $lock_pid). Kill $lock_pid or rm $lockfile"
      exit 1
    fi
    # Stale lock — overwrite
    log "Stale lock detected (PID ${lock_pid:-unknown} not running), recovering"
    echo $$ > "$lockfile"
    LOCKFILE_ACQUIRED=1
  else
    LOCKFILE_ACQUIRED=1
  fi
  trap cleanup EXIT INT TERM
  mkdir -p "$LOGS_DIR" 2>/dev/null

  # --- Analytics directory: create only when --debug or --with-self-verification ---
  if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
    mkdir -p "$ANALYTICS_DIR" 2>/dev/null
  fi

  # --- debug.log versioning (in analytics dir) ---
  if (( DEBUG )) && [[ -f "$DEBUG_LOG" ]]; then
    local dbg_n=1
    while [[ -f "${DEBUG_LOG%.log}-v${dbg_n}.log" ]]; do
      (( dbg_n++ ))
    done
    mv "$DEBUG_LOG" "${DEBUG_LOG%.log}-v${dbg_n}.log"
  fi

  # --- campaign.jsonl versioning (in analytics dir, after mkdir) ---
  if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
    if [[ -f "$CAMPAIGN_JSONL" ]]; then
      local cj_n=1
      while [[ -f "${CAMPAIGN_JSONL%.jsonl}-v${cj_n}.jsonl" ]]; do
        (( cj_n++ ))
      done
      mv "$CAMPAIGN_JSONL" "${CAMPAIGN_JSONL%.jsonl}-v${cj_n}.jsonl"
    fi
  fi

  # --- metadata.json: write at campaign start ---
  if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
    jq -n \
      --arg slug "$SLUG" \
      --arg project_root "$ROOT" \
      --arg campaign_status "running" \
      --arg start_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg end_time "" \
      --arg worker_model "$WORKER_MODEL" \
      --arg verifier_model "$VERIFIER_MODEL" \
      --argjson debug "$DEBUG" \
      --argjson with_sv "$WITH_SELF_VERIFICATION" \
      --argjson consensus "$VERIFY_CONSENSUS" \
      '{slug: $slug, project_root: $project_root, campaign_status: $campaign_status, start_time: $start_time, end_time: $end_time, worker_model: $worker_model, verifier_model: $verifier_model, debug: $debug, with_self_verification: $with_sv, consensus: $consensus}' \
      > "$METADATA_FILE"
  fi

  # --- Startup ---
  log "Ralph Desk Tmux Runner starting..."
  log "  Slug:            $SLUG"
  log "  Root:            $ROOT"
  log "  Max iterations:  $MAX_ITER"
  log "  Worker model:    $WORKER_MODEL"
  log "  Verifier model:  $VERIFIER_MODEL"
  log "  Verify mode:     $VERIFY_MODE"
  log "  Verify consensus:$VERIFY_CONSENSUS"
  log "  Final consensus: $FINAL_CONSENSUS"
  log "  Consensus scope: $CONSENSUS_SCOPE"
  log "  Poll interval:   ${POLL_INTERVAL}s"
  log "  Iter timeout:    ${ITER_TIMEOUT}s"
  # --- Debug: Log execution plan ---
  if (( DEBUG )); then
    # Extract US IDs from PRD
    local prd_file="$DESK/plans/prd-$SLUG.md"
    local us_list=""
    if [[ -f "$prd_file" ]]; then
      us_list=$(grep -oE 'US-[0-9]+' "$prd_file" | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
    local us_count=$(echo "$us_list" | tr ',' '\n' | grep -c 'US-')

    log_debug "[OPTION] slug=$SLUG us_count=$us_count us_list=$us_list"
    log_debug "[OPTION] worker_engine=$WORKER_ENGINE worker_model=$WORKER_MODEL"
    log_debug "[OPTION] verifier_engine=$VERIFIER_ENGINE verifier_model=$VERIFIER_MODEL"
    log_debug "[OPTION] verify_mode=$VERIFY_MODE consensus=$VERIFY_CONSENSUS consensus_scope=$CONSENSUS_SCOPE max_iter=$MAX_ITER"
    log_debug "[OPTION] cb_threshold=$CB_THRESHOLD effective_cb_threshold=$EFFECTIVE_CB_THRESHOLD iter_timeout=$ITER_TIMEOUT with_self_verification=$WITH_SELF_VERIFICATION debug=$DEBUG"

    if [[ "$VERIFY_MODE" = "per-us" ]]; then
      # Build expected flow
      local expected_flow=""
      for us in $(echo "$us_list" | tr ',' ' '); do
        expected_flow="${expected_flow}worker->verify($us)->"
      done
      expected_flow="${expected_flow}verify(ALL)->COMPLETE"
      log_debug "[OPTION] expected_flow=$expected_flow"
    else
      log_debug "[OPTION] expected_flow=worker(all)->verify(ALL)->COMPLETE"
    fi

    if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
      log_debug "[OPTION] consensus_flow=each_verify_runs_claude+codex_both_must_pass"
    fi
  fi

  # Extract US list for per-US sequencing
  if [[ "$VERIFY_MODE" = "per-us" ]]; then
    local prd_file="$DESK/plans/prd-$SLUG.md"
    if [[ -f "$prd_file" ]]; then
      US_LIST=$(grep -oE 'US-[0-9]+' "$prd_file" | sort -u | tr '\n' ',' | sed 's/,$//')
    fi

  # Initialize VERIFIED_US from memory's Completed Stories (carry over previous runs)
  local memory_file="$DESK/memos/${SLUG}-memory.md"
  if [[ -f "$memory_file" ]]; then
      local completed_us
      completed_us=$(sed -n '/^## Completed Stories$/,/^## /p' "$memory_file" 2>/dev/null | grep '^- US-' | sed 's/^- \(US-[0-9]*\):.*/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
      if [[ -n "$completed_us" ]]; then
        VERIFIED_US="$completed_us"
        log "  Loaded completed stories from memory: $VERIFIED_US"
        log_debug "[FLOW] loaded_verified_us_from_memory=$VERIFIED_US"
      fi
    fi
  fi

  # Initialize PRD snapshot state for live update detection
  PREV_PRD_HASH=$(compute_prd_hash)
  PREV_PRD_US_LIST=$(count_prd_us)

  # Dependency checks
  check_dependencies

  # Print security warning (governance.md s7: --dangerously-skip-permissions)
  print_security_warning

  # Validate scaffold
  validate_scaffold

  # Check for existing sessions
  check_existing_sessions

  # Create tmux session with pane IDs (governance.md s7 step 1)
  create_session

  # Set trap for cleanup on exit/error
  trap cleanup EXIT

  # Initialize context hash for stale detection
  PREV_CONTEXT_HASH=$(compute_context_hash)

  # --- governance.md s7: Leader Loop ---
  local HARD_CEILING=$(( ITER_TIMEOUT * 3 ))  # logged but NOT enforced — Worker extends indefinitely when active

  for (( ITERATION = 1; ITERATION <= MAX_ITER; ITERATION++ )); do
    log ""
    log "========== Iteration $ITERATION / $MAX_ITER =========="
    local ITER_START_TIME
    ITER_START_TIME=$(date +%s)
    local _iter_contract=""
    _iter_contract=$(sed -n '/^## Next Iteration Contract$/,/^## /{ /^## Next/d; /^## [^N]/d; p; }' "$MEMORY_FILE" 2>/dev/null | head -1 | tr '\n' ' ')
    log_debug "[FLOW] iter=$ITERATION start contract=\"${_iter_contract:-none}\""

    # --- governance.md s7 step 1: Check sentinels ---
    if [[ -f "$COMPLETE_SENTINEL" ]]; then
      log "COMPLETE sentinel found. Campaign succeeded."
      update_status "complete" "complete"
      return 0
    fi
    if [[ -f "$BLOCKED_SENTINEL" ]]; then
      log "BLOCKED sentinel found. Campaign blocked."
      update_status "blocked" "blocked"
      return 1
    fi

    # --- governance.md s7 step 8 (cleanup): Clean previous iteration signals ---
    rm -f "$SIGNAL_FILE" "$DONE_CLAIM_FILE" "$VERDICT_FILE" 2>/dev/null
    rm -f "$WORKER_HEARTBEAT" "$VERIFIER_HEARTBEAT" 2>/dev/null

    # --- Clean previous claude session in panes (one-shot lifecycle) ---
    # Only needed from iteration 2 onwards (iteration 1 has fresh panes)
    if (( ITERATION > 1 )); then
      # Send C-c first (in case claude is mid-task), then /exit
      tmux send-keys -t "$WORKER_PANE" C-c 2>/dev/null
      sleep 1
      tmux send-keys -t "$WORKER_PANE" "/exit" Enter 2>/dev/null
      sleep 2
      # Wait for shell prompt before proceeding
      wait_for_pane_ready "$WORKER_PANE" 10 2>/dev/null || true
    fi

    # Reset per-iteration state
    local worker_nudge_count=0
    local verifier_nudge_count=0
    ITER_VERIFIER_START=""
    ITER_VERIFIER_END=""

    # --- US-004: detect PRD changes for live update + re-split ---
    check_prd_update

    # --- governance.md s7 step 4: Build worker prompt + trigger ---
    write_worker_trigger "$ITERATION"
    local worker_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).worker-prompt.md"

    # AC1: capture worker start timestamp
    ITER_WORKER_START=$(date +%s)

    update_status "worker" "running"

    # --- governance.md s7 step 5: Execute Worker (dispatched to engine-specific function) ---
    log_debug "[FLOW] iter=$ITERATION phase=worker engine=$WORKER_ENGINE model=$WORKER_MODEL dispatched=true"

    local worker_launch
    if [[ "$WORKER_ENGINE" = "codex" ]]; then
      local worker_trigger="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).worker-trigger.sh"
      worker_launch="bash $worker_trigger"
      launch_worker_codex "$WORKER_PANE" "$worker_trigger" "$ITERATION"
    else
      worker_launch="$CLAUDE_BIN --model $WORKER_MODEL --dangerously-skip-permissions"
      if ! launch_worker_claude "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
        write_blocked_sentinel "Worker claude failed to start in pane"
        update_status "blocked" "worker_start_failed"
        return 1
      fi
    fi

    # --- governance.md s7 step 5+6: Poll for Worker completion ---
    log "  Polling for iter-signal.json..."
    local worker_poll_done=0
    while (( ! worker_poll_done )); do
      local worker_poll_rc=0
      if poll_for_signal "$SIGNAL_FILE" "$WORKER_HEARTBEAT" "$WORKER_PANE" "$worker_launch" "Worker"; then
        worker_poll_done=1
        log_debug "[FLOW] iter=$ITERATION poll_signal_received=true"
      else
        worker_poll_rc=$?
        if (( worker_poll_rc == 2 )); then
          return 1
        fi
        # Check if Worker is still actively running (not stuck)
        local worker_cmd
        worker_cmd=$(tmux display-message -p -t "$WORKER_PANE" '#{pane_current_command}' 2>/dev/null)
        if [[ "$worker_cmd" == "node" || "$worker_cmd" == "claude" || "$worker_cmd" == "codex" ]]; then
          # Process alive — extend indefinitely (no hard ceiling kill)
          # Stale-context breaker and nudge system handle truly stuck workers
          local iter_elapsed=$(( $(date +%s) - ITER_START_TIME ))
          local ceiling_exceeded=""
          if (( iter_elapsed >= HARD_CEILING )); then
            ceiling_exceeded=" [EXCEEDED hard_ceiling=${HARD_CEILING}s — not enforced, logged only]"
            log "  WARNING: Worker exceeded soft hard-ceiling (${iter_elapsed}s >= ${HARD_CEILING}s) but still active. Continuing..."
            log_debug "[GOV] iter=$ITERATION hard_ceiling_exceeded=true elapsed=${iter_elapsed}s ceiling=${HARD_CEILING}s process=$worker_cmd action=log_only_no_kill"
          fi
          log "  Worker timed out but still active ($worker_cmd). Extending poll... (${iter_elapsed}s, no ceiling)${ceiling_exceeded}"
          log_debug "[GOV] iter=$ITERATION timeout_active=true process=$worker_cmd elapsed=${iter_elapsed}s action=extend_indefinitely"
          log_debug "[FLOW] iter=$ITERATION poll_extended=true worker_cmd=$worker_cmd"
          update_status "worker" "slow"
          # Loop continues — re-poll same iteration
        else
          # Worker is truly dead/stuck
          (( MONITOR_FAILURE_COUNT++ ))
          log_debug "[GOV] iter=$ITERATION monitor_failure=$MONITOR_FAILURE_COUNT/3"
          if (( MONITOR_FAILURE_COUNT >= 3 )); then
            log_debug "[GOV] iter=$ITERATION circuit_breaker=monitor_failures detail=\"3 consecutive monitor failures\""
            write_blocked_sentinel "3 consecutive monitor failures (worker not active)"
            update_status "blocked" "monitor_failures"
            return 1
          fi
          log "  WARNING: Worker poll failed (monitor failure $MONITOR_FAILURE_COUNT/3)"
          update_status "worker" "poll_failed"
          log_debug "[FLOW] iter=$ITERATION poll_worker_dead=true worker_cmd=$worker_cmd"
          # Worker is truly dead/stuck — BLOCK and let user decide
          write_blocked_sentinel "Worker process dead/stuck (poll failed). Pane preserved for inspection."
          update_status "blocked" "worker_dead"
          return 1
        fi
      fi
    done

    if [[ ! -f "$SIGNAL_FILE" ]]; then
      log_debug "[FLOW] iter=$ITERATION no_signal_after_poll=true continuing"
      # No signal — monitor failure, go to next iteration
      continue
    fi

    # Reset monitor failure count on success
    MONITOR_FAILURE_COUNT=0

    # AC1: capture worker end timestamp; reset consensus timing
    ITER_WORKER_END=$(date +%s)
    ITER_VERIFIER_CLAUDE_DURATION_S=""
    ITER_VERIFIER_CODEX_DURATION_S=""

    # --- governance.md s7 step 6: Read iter-signal.json via jq (JSON only, no markdown) ---
    local signal_status
    signal_status=$(jq -r '.status' "$SIGNAL_FILE" 2>/dev/null)
    local signal_summary
    signal_summary=$(jq -r '.summary // "no summary"' "$SIGNAL_FILE" 2>/dev/null)

    log "  Worker signal: status=$signal_status summary=\"$signal_summary\""

    # Read us_id early for EXEC logging (also used later in verify branch)
    local signal_us_id_early=""
    signal_us_id_early=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
    log_debug "[FLOW] iter=$ITERATION phase=worker_signal status=$signal_status us_id=${signal_us_id_early:-none} summary=\"$signal_summary\""

    case "$signal_status" in
      continue)
        # --- governance.md s7 step 6: continue -> go to step 8 ---
        log "  Worker requests continue. Moving to next iteration."
        update_status "worker" "continue"
        ;;
      verify)
        # --- governance.md s7 step 7: Execute Verifier ---
        # Read us_id from signal for per-US scoping
        local signal_us_id=""
        signal_us_id=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
        log "  Worker claims done (us_id=${signal_us_id:-all}). Dispatching Verifier..."

        # AC1: capture verifier start timestamp
        ITER_VERIFIER_START=$(date +%s)

        update_status "verifier" "running"

        # --- Consensus scope check (US-005: _should_use_consensus handles VERIFY_CONSENSUS + FINAL_CONSENSUS) ---
        local use_consensus=0
        _should_use_consensus "$signal_us_id" && use_consensus=1

        # --- Consensus vs single verification ---
        if (( use_consensus )); then
          # US-004: Run consensus verification (claude + codex sequentially)
          local consensus_rc=0
          run_consensus_verification "$ITERATION" || consensus_rc=$?

          if (( consensus_rc == 2 )); then
            # Consensus disagreement — treat as fail, fix loop will handle
            log "  Consensus disagreement, treating as fail."
          elif (( consensus_rc != 0 )); then
            # Consensus verification failed entirely
            log_error "Consensus verification failed"
            write_blocked_sentinel "Consensus verification failed after max rounds"
            update_status "blocked" "consensus_failed"
            return 1
          fi
        else
          # Standard single-engine verification
          write_verifier_trigger "$ITERATION"
          local verifier_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).verifier-prompt.md"

          # Step 7a: Clean previous Verifier session (with dead pane detection)
          local verifier_cmd
          verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
          if [[ -z "$verifier_cmd" ]]; then
            log "  Verifier pane $VERIFIER_PANE is gone — replacing..."
            log_debug "[GOV] iter=$ITERATION pane_dead=true pane_id=$VERIFIER_PANE action=replace_pane"
            replace_worker_pane "$VERIFIER_PANE" "verifier"
            VERIFIER_PANE=$(jq -r '.panes.verifier' "$SESSION_CONFIG")
            log "  New verifier pane: $VERIFIER_PANE"
          elif [[ "$verifier_cmd" == "zsh" || "$verifier_cmd" == "bash" ]]; then
            log "  Verifier pane $VERIFIER_PANE has bare shell ($verifier_cmd) — resetting..."
            log_debug "[GOV] iter=$ITERATION pane_dead=true pane_id=$VERIFIER_PANE cmd=$verifier_cmd action=reset_shell"
            tmux send-keys -t "$VERIFIER_PANE" C-c C-u 2>/dev/null
            sleep 0.2
            tmux send-keys -t "$VERIFIER_PANE" "clear" Enter 2>/dev/null
            sleep 0.3
          elif [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
            tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
            sleep 0.5
            tmux send-keys -t "$VERIFIER_PANE" "/exit" Enter 2>/dev/null
            sleep 2
          fi
          wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true

          local verifier_launch
          if [[ "$VERIFIER_ENGINE" = "codex" ]]; then
            verifier_launch="${CODEX_BIN:-codex} -m $VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
          else
            verifier_launch="$CLAUDE_BIN --model $VERIFIER_MODEL --dangerously-skip-permissions"
          fi
          log_debug "[FLOW] iter=$ITERATION phase=verifier engine=$VERIFIER_ENGINE model=$VERIFIER_MODEL scope=${signal_us_id:-all} dispatched=true"

          if [[ "$VERIFIER_ENGINE" = "codex" ]]; then
            launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"
          else
            if ! launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"; then
              update_status "verifier" "start_failed"
              continue
            fi
          fi

          # Poll for verify-verdict.json
          log "  Polling for verify-verdict.json..."
          if ! poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier"; then
            local verifier_poll_rc=$?
            if (( verifier_poll_rc == 2 )); then
              return 1
            fi
            log_error "Verifier poll failed"
            # Verifier is dead/stuck — BLOCK and let user decide
            write_blocked_sentinel "Verifier process dead/stuck (poll failed). Pane preserved for inspection."
            update_status "blocked" "verifier_dead"
            return 1
          fi
        fi

        # AC1: capture verifier end timestamp
        ITER_VERIFIER_END=$(date +%s)

        # --- governance.md s7 step 7: Read verdict via jq ---
        local verdict
        verdict=$(jq -r '.verdict' "$VERDICT_FILE" 2>/dev/null)
        local recommended
        recommended=$(jq -r '.recommended_state_transition' "$VERDICT_FILE" 2>/dev/null)
        local verdict_summary
        verdict_summary=$(jq -r '.summary // "no summary"' "$VERDICT_FILE" 2>/dev/null)

        log "  Verifier: verdict=$verdict recommended=$recommended"
        log "  Verifier summary: \"$verdict_summary\""
        local _issues_count=$(jq '.issues | length' "$VERDICT_FILE" 2>/dev/null || echo 0)
        log_debug "[GOV] iter=$ITERATION phase=verdict engine=$VERIFIER_ENGINE verdict=$verdict recommended=$recommended us_id=${signal_us_id:-all} issues=$_issues_count"

        case "$verdict" in
          pass)
            CONSECUTIVE_FAILURES=0
            CONSENSUS_ROUND=0
            _SAME_US_FAIL_COUNT=0
            _LAST_FAILED_US=""
            if (( _MODEL_UPGRADED )); then
              log "  Worker model restored: ${WORKER_MODEL} → ${_ORIGINAL_WORKER_MODEL} (pass verdict)"
              log_debug "[DECIDE] iter=$ITERATION phase=model_select model_restore=true from=${WORKER_MODEL} to=${_ORIGINAL_WORKER_MODEL}"
              WORKER_MODEL="$_ORIGINAL_WORKER_MODEL"
              if [[ "$WORKER_ENGINE" = "codex" ]]; then
                WORKER_CODEX_MODEL="$WORKER_MODEL"
                WORKER_CODEX_REASONING="$_ORIGINAL_WORKER_CODEX_REASONING"
              fi
              _MODEL_UPGRADED=0
            fi

            # --- Per-US tracking ---
            if [[ "$VERIFY_MODE" = "per-us" && -n "$signal_us_id" && "$signal_us_id" != "ALL" ]]; then
              # Add this US to verified list
              if [[ -n "$VERIFIED_US" ]]; then
                VERIFIED_US="${VERIFIED_US},${signal_us_id}"
              else
                VERIFIED_US="$signal_us_id"
              fi
              log "  US $signal_us_id verified. Verified so far: $VERIFIED_US"
              log_debug "[FLOW] iter=$ITERATION verified_us_update=$signal_us_id verified_us_total=$VERIFIED_US"
              update_status "verifier" "pass_us"
              # Worker will do next US on next iteration
            elif [[ "$recommended" == "complete" || "$signal_us_id" == "ALL" ]]; then
              # Final full verify passed or complete recommended
              write_complete_sentinel "$verdict_summary"
              update_status "complete" "pass"
              write_campaign_jsonl "$ITERATION" "${signal_us_id:-ALL}" "pass"
              return 0
            else
              log "  Verifier passed but did not recommend complete. Continuing."
              update_status "verifier" "pass_continue"
            fi
            ;;
          fail)
            # --- governance.md s7½: Fix Loop (adapted for tmux lean mode) ---
            (( CONSECUTIVE_FAILURES++ ))
            check_model_upgrade "${signal_us_id:-unknown}"
            local verdict_summary_fail
            verdict_summary_fail=$(jq -r '.summary // "no summary"' "$VERDICT_FILE" 2>/dev/null)
            log "  Verifier FAILED (consecutive: $CONSECUTIVE_FAILURES). Building fix contract..."

            # Extract issues from verdict for next Worker's fix contract
            local fix_contract="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).fix-contract.md"
            {
              echo "# Fix Contract (from Verifier iteration $ITERATION)"
              echo ""
              echo "## Summary"
              echo "$verdict_summary_fail"
              echo ""
              echo "## Issues (from verify-verdict.json)"
              jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.criterion // "?"): \(.description // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$VERDICT_FILE" 2>/dev/null || echo "- (no structured issues available)"
              echo ""
              echo "## Next Iteration Contract"
              jq -r '.next_iteration_contract // "Fix the issues listed above."' "$VERDICT_FILE" 2>/dev/null
            } | atomic_write "$fix_contract"
            log "  Fix contract: $fix_contract"
            log_debug "[DECIDE] iter=$ITERATION phase=fix_loop trigger=$verdict consecutive_failures=$CONSECUTIVE_FAILURES fix_contract=$fix_contract"

            # Circuit breaker: consecutive failures (with architecture escalation when at model ceiling)
            if (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )); then
              # For codex: use full model:reasoning string (WORKER_MODEL loses reasoning suffix after upgrade)
              _ceiling_model_str="$([[ "$WORKER_ENGINE" = "codex" ]] && echo "${WORKER_CODEX_MODEL}:${WORKER_CODEX_REASONING}" || echo "$WORKER_MODEL")"
              if (( _MODEL_UPGRADED )) && [[ -z "$(get_next_model "$_ceiling_model_str")" ]]; then
                log_debug "[GOV] iter=$ITERATION circuit_breaker=consecutive_failures detail=\"architecture escalation: Worker at ceiling (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive failures\""
                log_error "Circuit breaker: architecture escalation — Worker upgraded to ceiling (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive failures"
                write_blocked_sentinel "architecture escalation: Worker upgraded to ceiling model (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures"
              else
                log_debug "[GOV] iter=$ITERATION circuit_breaker=consecutive_failures detail=\"${EFFECTIVE_CB_THRESHOLD} consecutive verification failures\""
                log_error "Circuit breaker: ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures"
                write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive verification failures"
              fi
              update_status "blocked" "consecutive_failures"
              return 1
            fi

            update_status "verifier" "fail"
            ;;
          request_info)
            # --- governance.md s7 step 7: request_info (degraded in tmux mode) ---
            local verdict_summary_ri
            verdict_summary_ri=$(jq -r '.summary // "no summary"' "$VERDICT_FILE" 2>/dev/null)
            log "  Verifier requests info (degraded in tmux lean mode)."
            log "  Questions: \"$verdict_summary_ri\""
            log "  Treating as soft fail — Worker will see verdict in next iteration."
            update_status "verifier" "request_info"
            ;;
          blocked)
            write_blocked_sentinel "Verifier verdict: blocked - $verdict_summary"
            update_status "blocked" "verifier_blocked"
            return 1
            ;;
          *)
            log_error "Unknown verdict: $verdict"
            update_status "verifier" "unknown_verdict"
            ;;
        esac
        ;;
      blocked)
        # --- governance.md s7 step 6: blocked -> write sentinel ---
        write_blocked_sentinel "Worker reported blocked: $signal_summary"
        update_status "blocked" "worker_blocked"
        return 1
        ;;
      *)
        log_error "Unknown signal status: $signal_status"
        update_status "worker" "unknown_status"
        ;;
    esac

    # --- step 7d: Archive iteration artifacts before cleanup ---
    archive_iter_artifacts "$ITERATION"

    # --- AC5: Write per-iteration cost estimate ---
    write_cost_log "$ITERATION"
    write_campaign_jsonl "$ITERATION" "${signal_us_id:-unknown}" "${signal_status:-unknown}"

    # --- governance.md s7 step 8: Write result log ---
    write_result_log "$ITERATION" "$signal_status"

    # --- governance.md s7 step 8: Circuit breaker - stale context check ---
    if ! check_stale_context; then
      log_debug "[GOV] iter=$ITERATION circuit_breaker=stale_context detail=\"context unchanged for 3 consecutive iterations\""
      write_blocked_sentinel "Context unchanged for 3 consecutive iterations (stale)"
      update_status "blocked" "stale_context"
      return 1
    fi

    # --- governance.md s7 step 8: Update status ---
    update_status "idle" "${signal_status:-unknown}"
  done

  # Max iterations reached
  log "Max iterations ($MAX_ITER) reached."
  update_status "timeout" "max_iter"
  return 1
}

# =============================================================================
# Entry Point
# =============================================================================

# --- CLI: parse --worker-model / --verifier-model flags ---
# These flags override env-var defaults (WORKER_ENGINE, WORKER_MODEL, etc.)
# Format: "model:reasoning" → codex engine; "model-name" → claude engine
_cli_i=1
while (( _cli_i <= $# )); do
  case "${@[$_cli_i]}" in
    --worker-model)
      (( _cli_i++ ))
      _cli_parsed=$(parse_model_flag "${@[$_cli_i]:-}" "worker") || exit 1
      WORKER_ENGINE="${_cli_parsed%% *}"
      _cli_rest="${_cli_parsed#* }"
      WORKER_MODEL="${_cli_rest%% *}"
      if [[ "$WORKER_ENGINE" = "codex" ]]; then
        WORKER_CODEX_MODEL="$WORKER_MODEL"
        WORKER_CODEX_REASONING="${_cli_rest##* }"
      fi
      ;;
    --verifier-model)
      (( _cli_i++ ))
      _cli_parsed=$(parse_model_flag "${@[$_cli_i]:-}" "verifier") || exit 1
      VERIFIER_ENGINE="${_cli_parsed%% *}"
      _cli_rest="${_cli_parsed#* }"
      VERIFIER_MODEL="${_cli_rest%% *}"
      if [[ "$VERIFIER_ENGINE" = "codex" ]]; then
        VERIFIER_CODEX_MODEL="$VERIFIER_MODEL"
        VERIFIER_CODEX_REASONING="${_cli_rest##* }"
      fi
      ;;
    --lock-worker-model)
      LOCK_WORKER_MODEL=1
      ;;
    --final-consensus)
      FINAL_CONSENSUS=1
      ;;
  esac
  (( _cli_i++ ))
done
unset _cli_i _cli_parsed _cli_rest

# Require tmux — tmux mode only works inside an active tmux session
if [[ -z "${TMUX:-}" ]]; then
  echo "ERROR: tmux mode requires running inside a tmux session."
  echo ""
  echo "  Start tmux first, then retry:"
  echo "    tmux"
  echo "    LOOP_NAME=$SLUG $0"
  echo ""
  echo "  Or use Agent() mode instead (no tmux needed):"
  echo "    /rlp-desk run $SLUG"
  exit 1
fi

main "$@"
