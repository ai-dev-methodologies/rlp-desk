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
CONSENSUS_SCOPE="${CONSENSUS_SCOPE:-all}"   # all|final-only

# --- Derived Paths ---
DESK="$ROOT/.claude/ralph-desk"
PROMPTS_DIR="$DESK/prompts"
CONTEXT_DIR="$DESK/context"
MEMOS_DIR="$DESK/memos"
LOGS_DIR="$DESK/logs/$SLUG"
WORKER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.worker.prompt.md"
VERIFIER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.verifier.prompt.md"
CONTEXT_FILE="$CONTEXT_DIR/${SLUG}-latest.md"
MEMORY_FILE="$MEMOS_DIR/${SLUG}-memory.md"
SIGNAL_FILE="$MEMOS_DIR/${SLUG}-iter-signal.json"
DONE_CLAIM_FILE="$MEMOS_DIR/${SLUG}-done-claim.json"
VERDICT_FILE="$MEMOS_DIR/${SLUG}-verify-verdict.json"
COMPLETE_SENTINEL="$MEMOS_DIR/${SLUG}-complete.md"
BLOCKED_SENTINEL="$MEMOS_DIR/${SLUG}-blocked.md"
STATUS_FILE="$LOGS_DIR/status.json"
SESSION_CONFIG="$LOGS_DIR/session-config.json"
WORKER_HEARTBEAT="$LOGS_DIR/worker-heartbeat.json"
VERIFIER_HEARTBEAT="$LOGS_DIR/verifier-heartbeat.json"

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
ITERATION=0
START_TIME=$(date +%s)
VERIFIED_US=""           # comma-separated list of verified US IDs (per-us mode)
CONSENSUS_ROUND=0        # current consensus round for current US
US_LIST=""               # comma-separated US IDs from PRD (per-us mode)

# =============================================================================
# Utility Functions
# =============================================================================

DEBUG="${DEBUG:-0}"
DEBUG_LOG="$ROOT/.claude/ralph-desk/logs/${LOOP_NAME:-unknown}/debug.log"

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

  # Create fresh pane via split-window off leader (omc-teams kill-and-replace pattern)
  local new_pane
  new_pane=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")

  log "  New $role pane: $new_pane (replaced $old_pane)"
  log_debug "[EXEC] iter=$ITERATION pane_replaced=${role} old=$old_pane new=$new_pane"

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

  if ! command -v claude >/dev/null 2>&1; then
    log_error "claude CLI is required but not found. See: https://docs.anthropic.com/en/docs/claude-cli"
    missing=1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log_error "jq is required but not found. Install with: brew install jq"
    missing=1
  fi

  # Codex binary required only when engine=codex or consensus verification is enabled
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$VERIFY_CONSENSUS" = "1" ]]; then
    if ! command -v codex >/dev/null 2>&1; then
      if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
        log_error "codex CLI is required for consensus verification (VERIFY_CONSENSUS=1)."
      else
        log_error "codex CLI is required when WORKER_ENGINE or VERIFIER_ENGINE is 'codex'."
      fi
      log_error "Install with: npm install -g @openai/codex"
      missing=1
    fi
  fi

  if (( missing )); then
    exit 1
  fi

  # Resolve full path to claude binary for reliable launches
  CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "claude")
  log "  Claude binary: $CLAUDE_BIN"

  # Resolve codex binary if needed
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$VERIFY_CONSENSUS" = "1" ]]; then
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

  log "  Leader pane:   $LEADER_PANE"
  log "  Worker pane:   $WORKER_PANE"
  log "  Verifier pane: $VERIFIER_PANE"

  # Write session config (atomic write)
  echo '{
  "session_name": "'"$SESSION_NAME"'",
  "slug": "'"$SLUG"'",
  "created_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",
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
    "max_nudges": '"$MAX_NUDGES"'
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

# =============================================================================
# Verification-Based Send Retry (tmux pattern)
# =============================================================================

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
  # Send text in literal mode with -- separator
  log_debug " Sending text to pane $pane_id (${#text} chars)"
  tmux send-keys -t "$pane_id" -l -- "$text"

  # Allow input buffer to settle (tmux: 150ms)
  sleep 0.15

  # Submit: up to 6 rounds of C-m double-press
  local round=0
  while (( round < 6 )); do
    sleep 0.1
    if (( round == 0 && pane_busy )); then
      # Busy pane: Tab+C-m queue semantics (tmux pattern)
      tmux send-keys -t "$pane_id" Tab
      sleep 0.08
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
  tmux send-keys -t "$pane_id" -l -- "$text"
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
      local count=${(P)nudge_count_var}
      if (( count < MAX_NUDGES )); then
        log "  Nudging idle pane $pane_id (nudge $((count + 1))/$MAX_NUDGES)"
        safe_send_keys "$pane_id" ""
        (( count++ ))
        eval "$nudge_count_var=$count"
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

  {
    cat "$WORKER_PROMPT_BASE"
    echo ""
    echo "---"
    echo "## Iteration Context"
    echo "- **Iteration**: $iter"
    echo "- **Memory Stop Status**: $(sed -n '/^## Stop Status$/,/^$/{ /^## /d; /^$/d; p; }' "$MEMORY_FILE" 2>/dev/null | head -1)"
    echo "- **Next Iteration Contract**: ${contract:-Start from the beginning}"

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
      # Find next unverified US
      local next_us=""
      for us in $(echo "$US_LIST" | tr ',' ' '); do
        if ! echo ",$VERIFIED_US," | grep -q ",$us,"; then
          next_us="$us"
          break
        fi
      done

      if [[ -n "$next_us" ]]; then
        echo ""
        echo "---"
        echo "## PER-US SCOPE LOCK (this iteration)"
        echo "You MUST implement ONLY **${next_us}** in this iteration."
        echo "Do NOT implement any other user stories."
        echo "When done, signal verify with us_id=\"${next_us}\" (not \"ALL\")."
        echo "Signal format: {\"iteration\": N, \"status\": \"verify\", \"us_id\": \"${next_us}\", ...}"
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
    local engine_cmd="${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL \\
  -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" \\
  --dangerously-bypass-approvals-and-sandbox \\
  \"\$(cat $prompt_file)\" \\
  2>&1 | tee $output_log"
    local engine_comment="# Run codex with fresh context (governance.md s7 step 5)"
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
  git_diff=$(git diff --stat HEAD~1 HEAD 2>/dev/null || echo "(no git diff available)")

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
  rm -f "$DESK/logs/.rlp-desk-$SLUG.lock" 2>/dev/null

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

  if (( DEBUG )); then
    local end_ts=$(date +%s)
    local elapsed=$((end_ts - START_TIME))

    log_debug "[EXEC] final status=$final_status iterations=$ITERATION elapsed=${elapsed}s"

    # --- Validation ---
    log_debug "[VALIDATE] === Execution Validation ==="

    # 1. Did the correct verify mode run?
    log_debug "[VALIDATE] verify_mode=$VERIFY_MODE configured=true"

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
          log_debug "[VALIDATE] per_us_coverage=PASS verified=$verified_count/$expected_count us=$VERIFIED_US"
        else
          log_debug "[VALIDATE] per_us_coverage=FAIL verified=$verified_count/$expected_count expected=$expected_us got=$VERIFIED_US"
        fi
      else
        log_debug "[VALIDATE] per_us_coverage=INCOMPLETE verified=$verified_count/$expected_count status=$final_status"
      fi
    fi

    # 3. Consensus: were both engines used?
    if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
      if [[ -n "${CLAUDE_VERDICT:-}" && -n "${CODEX_VERDICT:-}" ]]; then
        log_debug "[VALIDATE] consensus=USED claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT rounds=$CONSENSUS_ROUND"
      else
        log_debug "[VALIDATE] consensus=NOT_TRIGGERED claude=${CLAUDE_VERDICT:-none} codex=${CODEX_VERDICT:-none}"
      fi
    fi

    # 4. Engine match: did the configured engines actually run?
    local worker_dispatches=$(grep -c '\[EXEC\].*phase=worker.*dispatched=true' "$DEBUG_LOG" 2>/dev/null || echo 0)
    local verifier_dispatches=$(grep -c '\[EXEC\].*phase=verifier.*dispatched=true' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[VALIDATE] dispatches worker=$worker_dispatches verifier=$verifier_dispatches"

    # 5. Fix loops: how many fix contracts were generated?
    local fix_count=$(grep -c '\[EXEC\].*phase=fix_loop' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[VALIDATE] fix_loops=$fix_count consecutive_failures=$CONSECUTIVE_FAILURES"

    # 6. Circuit breakers: any triggered?
    local cb_count=$(grep -c '\[EXEC\].*circuit_breaker=' "$DEBUG_LOG" 2>/dev/null || echo 0)
    log_debug "[VALIDATE] circuit_breakers_triggered=$cb_count"

    # 7. Overall result
    log_debug "[VALIDATE] result=$final_status iterations=$ITERATION elapsed=${elapsed}s verified_us=$VERIFIED_US"
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

    # Check heartbeat freshness (tmux pattern)
    if [[ -f "$heartbeat_file" ]]; then
      if check_heartbeat_exited "$heartbeat_file"; then
        # Process exited but no signal file -- give a brief grace period
        sleep 3
        if [[ -f "$signal_file" ]]; then
          log "  Signal file detected after process exit: $signal_file"
          return 0
        fi
        log_error "$role exited without writing signal file"
        # Attempt restart with exponential backoff
        if restart_worker "$pane_id" "$ITERATION" "$trigger_file"; then
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
          log_debug "[EXEC] iter=$ITERATION circuit_breaker=heartbeat_stale detail=\"3 consecutive heartbeat stale events\""
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

    # Auto-approve permission prompts during poll
    local poll_capture
    poll_capture=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$poll_capture" | grep -q "Do you want to" 2>/dev/null; then
      log "  Permission prompt detected during poll, auto-approving..."
      log_debug "[EXEC] iter=$ITERATION permission_prompt_auto_approved=true"
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

# --- governance.md s7 step 8: Stale context detection ---
compute_context_hash() {
  if [[ -f "$CONTEXT_FILE" ]]; then
    md5 -q "$CONTEXT_FILE" 2>/dev/null || md5sum "$CONTEXT_FILE" 2>/dev/null | cut -d' ' -f1
  else
    echo "no-context"
  fi
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

  # Clean previous Verifier session
  local verifier_cmd
  verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
  if [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
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

  # Launch verifier
  if [[ "$engine" = "codex" ]]; then
    # Codex: use non-interactive exec mode in pane (more reliable than TUI for sequential runs)
    local codex_cmd="${CODEX_BIN:-codex} exec \"\$(cat $prompt_file)\" -m $VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
    log "  Running $suffix verifier (codex exec) in pane $VERIFIER_PANE..."
    tmux send-keys -t "$VERIFIER_PANE" -l -- "$codex_cmd"
    tmux send-keys -t "$VERIFIER_PANE" Enter
    log_debug "Verifier$suffix codex exec sent directly"
  else
    # Claude: use interactive TUI
    local verifier_launch="$CLAUDE_BIN --model $model --dangerously-skip-permissions"
    log "  Launching $suffix verifier (claude) in pane $VERIFIER_PANE..."
    tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_launch"
    tmux send-keys -t "$VERIFIER_PANE" Enter

    if ! wait_for_pane_ready "$VERIFIER_PANE" 30; then
      log_error "Verifier$suffix failed to start"
      return 1
    fi

    sleep 3
    local verifier_instruction="Read and execute the instructions in $prompt_file"
    tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_instruction"
    tmux send-keys -t "$VERIFIER_PANE" Enter
    log_debug "Verifier$suffix instruction sent directly"

    # Verify claude actually started working
    local v_submit=0
    while (( v_submit < 15 )); do
      sleep 2
      local v_check
      v_check=$(tmux capture-pane -t "$VERIFIER_PANE" -p 2>/dev/null)
      if echo "$v_check" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut" 2>/dev/null; then
        log_debug "Verifier$suffix started working after $((v_submit + 1)) checks"
        break
      fi
      # After 8 failed attempts, try C-u clear + re-type (omc-teams adaptive retry)
      if (( v_submit == 8 )); then
        log_debug "Adaptive instruction retry: clearing line and re-typing"
        tmux send-keys -t "$VERIFIER_PANE" C-u 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_instruction"
        tmux send-keys -t "$VERIFIER_PANE" Enter
      fi
      tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null
      sleep 0.3
      tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null
      (( v_submit++ ))
    done
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
      log_error "Verifier$suffix poll failed"
      return 1
    fi
  fi

  # Copy verdict to destination
  cp "$VERDICT_FILE" "$verdict_dest"
  log "  Verifier$suffix verdict saved to $verdict_dest"
  return 0
}

# --- US-004: Run consensus verification (claude + codex sequentially) ---
run_consensus_verification() {
  local iter="$1"
  local claude_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-claude.json"
  local codex_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-codex.json"

  CONSENSUS_ROUND=0
  CLAUDE_VERDICT=""
  CODEX_VERDICT=""

  while (( CONSENSUS_ROUND < 3 )); do
    (( CONSENSUS_ROUND++ ))
    log "  Consensus round $CONSENSUS_ROUND/3..."

    # Run claude verifier first
    if ! run_single_verifier "$iter" "claude" "$VERIFIER_MODEL" "-claude" "$claude_verdict_file"; then
      log_error "Claude verifier failed in consensus round $CONSENSUS_ROUND"
      return 1
    fi
    CLAUDE_VERDICT=$(jq -r '.verdict' "$claude_verdict_file" 2>/dev/null)
    log_debug "[EXEC] iter=$iter phase=consensus_claude verdict=$CLAUDE_VERDICT model=$VERIFIER_MODEL"

    # Run codex verifier second
    if ! run_single_verifier "$iter" "codex" "$VERIFIER_CODEX_MODEL" "-codex" "$codex_verdict_file"; then
      log_error "Codex verifier failed in consensus round $CONSENSUS_ROUND"
      return 1
    fi
    CODEX_VERDICT=$(jq -r '.verdict' "$codex_verdict_file" 2>/dev/null)
    log_debug "[EXEC] iter=$iter phase=consensus_codex verdict=$CODEX_VERDICT model=$VERIFIER_CODEX_MODEL reasoning=$VERIFIER_CODEX_REASONING"

    log "  Consensus: claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT"
    local _combined_action="retry"
    if [[ "$CLAUDE_VERDICT" = "pass" && "$CODEX_VERDICT" = "pass" ]]; then _combined_action="pass"
    elif (( CONSENSUS_ROUND >= 3 )); then _combined_action="blocked"
    fi
    log_debug "[EXEC] iter=$iter phase=consensus round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT combined_action=$_combined_action"

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
    log_debug "[EXEC] iter=$iter phase=consensus_disagreement round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT action=fix_contract"

    # Either fails → build combined fix contract
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
    if (( CONSENSUS_ROUND < 3 )); then
      # Create a merged fail verdict for the main loop
      {
        echo '{'
        echo '  "verdict": "fail",'
        echo '  "verified_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
        echo '  "summary": "Consensus disagreement (round '"$CONSENSUS_ROUND"'/3): claude='"$CLAUDE_VERDICT"' codex='"$CODEX_VERDICT"'",'
        echo '  "issues": [],'
        echo '  "recommended_state_transition": "continue",'
        echo '  "consensus": { "claude": "'"$CLAUDE_VERDICT"'", "codex": "'"$CODEX_VERDICT"'", "round": '"$CONSENSUS_ROUND"' }'
        echo '}'
      } | atomic_write "$VERDICT_FILE"
      return 2  # special return: consensus disagreement, needs retry
    fi
  done

  # Max consensus rounds exceeded
  log_error "Consensus failed after 3 rounds"
  {
    echo '{'
    echo '  "verdict": "fail",'
    echo '  "verified_at_utc": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'",'
    echo '  "summary": "Consensus failed after 3 rounds: claude='"$CLAUDE_VERDICT"' codex='"$CODEX_VERDICT"'",'
    echo '  "issues": [],'
    echo '  "recommended_state_transition": "blocked",'
    echo '  "consensus": { "claude": "'"$CLAUDE_VERDICT"'", "codex": "'"$CODEX_VERDICT"'", "round": 3 }'
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
  local lockfile="$DESK/logs/.rlp-desk-$SLUG.lock"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null
  if ! (set -C; echo $$ > "$lockfile") 2>/dev/null; then
    local lock_pid
    lock_pid=$(cat "$lockfile" 2>/dev/null)
    if kill -0 "$lock_pid" 2>/dev/null; then
      log_error "Another instance is already running (PID $lock_pid)"
      exit 1
    fi
    # Stale lock — overwrite
    echo $$ > "$lockfile"
  fi
  mkdir -p "$LOGS_DIR" 2>/dev/null

  # --- Startup ---
  log "Ralph Desk Tmux Runner starting..."
  log "  Slug:            $SLUG"
  log "  Root:            $ROOT"
  log "  Max iterations:  $MAX_ITER"
  log "  Worker model:    $WORKER_MODEL"
  log "  Verifier model:  $VERIFIER_MODEL"
  log "  Verify mode:     $VERIFY_MODE"
  log "  Verify consensus:$VERIFY_CONSENSUS"
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

    log_debug "[PLAN] slug=$SLUG us_count=$us_count us_list=$us_list"
    log_debug "[PLAN] worker_engine=$WORKER_ENGINE worker_model=$WORKER_MODEL"
    log_debug "[PLAN] verifier_engine=$VERIFIER_ENGINE verifier_model=$VERIFIER_MODEL"
    log_debug "[PLAN] verify_mode=$VERIFY_MODE consensus=$VERIFY_CONSENSUS consensus_scope=$CONSENSUS_SCOPE max_iter=$MAX_ITER"

    if [[ "$VERIFY_MODE" = "per-us" ]]; then
      # Build expected flow
      local expected_flow=""
      for us in $(echo "$us_list" | tr ',' ' '); do
        expected_flow="${expected_flow}worker->verify($us)->"
      done
      expected_flow="${expected_flow}verify(ALL)->COMPLETE"
      log_debug "[PLAN] expected_flow=$expected_flow"
    else
      log_debug "[PLAN] expected_flow=worker(all)->verify(ALL)->COMPLETE"
    fi

    if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
      log_debug "[PLAN] consensus_flow=each_verify_runs_claude+codex_both_must_pass"
    fi
  fi

  # Extract US list for per-US sequencing
  if [[ "$VERIFY_MODE" = "per-us" ]]; then
    local prd_file="$DESK/plans/prd-$SLUG.md"
    if [[ -f "$prd_file" ]]; then
      US_LIST=$(grep -oE 'US-[0-9]+' "$prd_file" | sort -u | tr '\n' ',' | sed 's/,$//')
    fi
  fi

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
  for (( ITERATION = 1; ITERATION <= MAX_ITER; ITERATION++ )); do
    log ""
    log "========== Iteration $ITERATION / $MAX_ITER =========="
    local _iter_contract=""
    _iter_contract=$(sed -n '/^## Next Iteration Contract$/,/^## /{ /^## Next/d; /^## [^N]/d; p; }' "$MEMORY_FILE" 2>/dev/null | head -1 | tr '\n' ' ')
    log_debug "[EXEC] iter=$ITERATION start contract=\"${_iter_contract:-none}\""

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

    # --- governance.md s7 step 4: Build worker prompt + trigger ---
    write_worker_trigger "$ITERATION"
    local worker_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).worker-prompt.md"

    update_status "worker" "running"

    # --- governance.md s7 step 5: Execute Worker (interactive TUI, tmux pattern) ---
    # Step 5a: Launch interactive worker engine in Worker pane
    local worker_launch
    if [[ "$WORKER_ENGINE" = "codex" ]]; then
      worker_launch="${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
      log "  Launching Worker codex in pane $WORKER_PANE..."
    else
      worker_launch="$CLAUDE_BIN --model $WORKER_MODEL --dangerously-skip-permissions"
      log "  Launching Worker claude in pane $WORKER_PANE..."
    fi
    tmux send-keys -t "$WORKER_PANE" -l -- "$worker_launch"
    tmux send-keys -t "$WORKER_PANE" Enter
    log_debug "[EXEC] iter=$ITERATION phase=worker engine=$WORKER_ENGINE model=$WORKER_MODEL dispatched=true"

    # Step 5b: Wait for claude TUI to be ready (tmux pattern)
    if ! wait_for_pane_ready "$WORKER_PANE" 30; then
      log_error "Worker claude failed to start"
      write_blocked_sentinel "Worker claude failed to start in pane"
      update_status "blocked" "worker_start_failed"
      return 1
    fi

    # Step 5c: Wait for claude to fully initialize, then send instruction directly
    sleep 3
    local worker_instruction="Read and execute the instructions in $worker_prompt"
    tmux send-keys -t "$WORKER_PANE" -l -- "$worker_instruction"
    tmux send-keys -t "$WORKER_PANE" Enter
    log_debug "Worker instruction sent directly (${#worker_instruction} chars)"

    # Verify claude actually started working — keep sending C-m until activity detected
    local submit_attempts=0
    while (( submit_attempts < 15 )); do
      sleep 2
      local pane_check
      pane_check=$(tmux capture-pane -t "$WORKER_PANE" -p 2>/dev/null)
      if echo "$pane_check" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut\|Exploring\|Running\|exec\|Explored" 2>/dev/null; then
        log_debug "Worker started working after $((submit_attempts + 1)) submit checks"
        log_debug "[EXEC] iter=$ITERATION worker_submit_check=OK attempts=$((submit_attempts + 1))"
        break
      fi
      # After 8 failed attempts, try C-u clear + re-type (omc-teams adaptive retry)
      if (( submit_attempts == 8 )); then
        log_debug "Adaptive instruction retry: clearing line and re-typing"
        tmux send-keys -t "$WORKER_PANE" C-u 2>/dev/null
        sleep 0.1
        tmux send-keys -t "$WORKER_PANE" -l -- "$worker_instruction"
        tmux send-keys -t "$WORKER_PANE" Enter
      fi
      tmux send-keys -t "$WORKER_PANE" C-m 2>/dev/null
      sleep 0.3
      tmux send-keys -t "$WORKER_PANE" C-m 2>/dev/null
      (( submit_attempts++ ))
    done
    if (( submit_attempts >= 15 )); then
      log "  WARNING: Could not confirm Worker started working after 15 attempts"
      log_debug "[EXEC] iter=$ITERATION worker_submit_check=FAILED attempts=15"
    fi

    # --- governance.md s7 step 5+6: Poll for Worker completion ---
    log "  Polling for iter-signal.json..."
    local worker_poll_done=0
    while (( ! worker_poll_done )); do
      if poll_for_signal "$SIGNAL_FILE" "$WORKER_HEARTBEAT" "$WORKER_PANE" "$worker_launch" "Worker"; then
        worker_poll_done=1
        log_debug "[EXEC] iter=$ITERATION poll_signal_received=true"
      else
        # Check if Worker is still actively running (not stuck)
        local worker_cmd
        worker_cmd=$(tmux display-message -p -t "$WORKER_PANE" '#{pane_current_command}' 2>/dev/null)
        if [[ "$worker_cmd" == "node" || "$worker_cmd" == "claude" || "$worker_cmd" == "codex" ]]; then
          log "  Worker timed out but still active ($worker_cmd). Extending poll..."
          log_debug "[EXEC] iter=$ITERATION timeout_active=true process=$worker_cmd"
          log_debug "[EXEC] iter=$ITERATION poll_extended=true worker_cmd=$worker_cmd"
          update_status "worker" "slow"
          # Loop continues — re-poll same iteration
        else
          # Worker is truly dead/stuck
          (( MONITOR_FAILURE_COUNT++ ))
          log_debug "[EXEC] iter=$ITERATION monitor_failure=$MONITOR_FAILURE_COUNT/3"
          if (( MONITOR_FAILURE_COUNT >= 3 )); then
            log_debug "[EXEC] iter=$ITERATION circuit_breaker=monitor_failures detail=\"3 consecutive monitor failures\""
            write_blocked_sentinel "3 consecutive monitor failures (worker not active)"
            update_status "blocked" "monitor_failures"
            return 1
          fi
          log "  WARNING: Worker poll failed (monitor failure $MONITOR_FAILURE_COUNT/3)"
          update_status "worker" "poll_failed"
          worker_poll_done=1  # exit poll loop, continue to next iteration
          log_debug "[EXEC] iter=$ITERATION poll_worker_dead=true worker_cmd=$worker_cmd"
          # Worker is truly dead/stuck — kill and replace pane (omc-teams pattern)
          WORKER_PANE=$(replace_worker_pane "$WORKER_PANE" "worker")
        fi
      fi
    done

    if [[ ! -f "$SIGNAL_FILE" ]]; then
      log_debug "[EXEC] iter=$ITERATION no_signal_after_poll=true continuing"
      # No signal — monitor failure, go to next iteration
      continue
    fi

    # Reset monitor failure count on success
    MONITOR_FAILURE_COUNT=0

    # --- governance.md s7 step 6: Read iter-signal.json via jq (JSON only, no markdown) ---
    local signal_status
    signal_status=$(jq -r '.status' "$SIGNAL_FILE" 2>/dev/null)
    local signal_summary
    signal_summary=$(jq -r '.summary // "no summary"' "$SIGNAL_FILE" 2>/dev/null)

    log "  Worker signal: status=$signal_status summary=\"$signal_summary\""

    # Read us_id early for EXEC logging (also used later in verify branch)
    local signal_us_id_early=""
    signal_us_id_early=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
    log_debug "[EXEC] iter=$ITERATION phase=worker_signal status=$signal_status us_id=${signal_us_id_early:-none} summary=\"$signal_summary\""

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

        update_status "verifier" "running"

        # --- Consensus scope check ---
        local use_consensus=0
        if [[ "$VERIFY_CONSENSUS" = "1" ]]; then
          case "$CONSENSUS_SCOPE" in
            all) use_consensus=1 ;;
            final-only) [[ "$signal_us_id" == "ALL" ]] && use_consensus=1 ;;
          esac
        fi

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

          # Step 7a: Clean previous Verifier session if running
          local verifier_cmd
          verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
          if [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
            tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
            sleep 0.5
            tmux send-keys -t "$VERIFIER_PANE" "/exit" Enter 2>/dev/null
            sleep 2
            wait_for_pane_ready "$VERIFIER_PANE" 5 2>/dev/null || true
          fi

          local verifier_launch
          if [[ "$VERIFIER_ENGINE" = "codex" ]]; then
            verifier_launch="${CODEX_BIN:-codex} -m $VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" --dangerously-bypass-approvals-and-sandbox"
            log "  Launching Verifier codex in pane $VERIFIER_PANE..."
          else
            verifier_launch="$CLAUDE_BIN --model $VERIFIER_MODEL --dangerously-skip-permissions"
            log "  Launching Verifier claude in pane $VERIFIER_PANE..."
          fi
          tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_launch"
          tmux send-keys -t "$VERIFIER_PANE" Enter
          log_debug "[EXEC] iter=$ITERATION phase=verifier engine=$VERIFIER_ENGINE model=$VERIFIER_MODEL scope=${signal_us_id:-all} dispatched=true"

          # Step 7b: Wait for TUI to be ready
          if ! wait_for_pane_ready "$VERIFIER_PANE" 30; then
            log_error "Verifier failed to start"
            update_status "verifier" "start_failed"
            continue
          fi

          # Step 7c: Send instruction
          sleep 3
          local verifier_instruction="Read and execute the instructions in $verifier_prompt"
          tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_instruction"
          tmux send-keys -t "$VERIFIER_PANE" Enter
          log_debug "Verifier instruction sent directly"

          # Verify verifier actually started working
          local vs_submit=0
          while (( vs_submit < 15 )); do
            sleep 2
            local vs_check
            vs_check=$(tmux capture-pane -t "$VERIFIER_PANE" -p 2>/dev/null)
            if echo "$vs_check" | grep -qi "esc to interrupt\|thinking\|working\|kneading\|crunching\|clauding\|billowing\|brewing\|tinkering\|burrowing\|saut\|Exploring\|Running\|exec\|Explored" 2>/dev/null; then
              log_debug "Verifier started working after $((vs_submit + 1)) checks"
              break
            fi
            # After 8 failed attempts, try C-u clear + re-type (omc-teams adaptive retry)
            if (( vs_submit == 8 )); then
              log_debug "Adaptive instruction retry: clearing line and re-typing"
              tmux send-keys -t "$VERIFIER_PANE" C-u 2>/dev/null
              sleep 0.1
              tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_instruction"
              tmux send-keys -t "$VERIFIER_PANE" Enter
            fi
            tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null
            sleep 0.3
            tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null
            (( vs_submit++ ))
          done

          # Poll for verify-verdict.json
          log "  Polling for verify-verdict.json..."
          if ! poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier"; then
            log_error "Verifier poll failed"
            update_status "verifier" "poll_failed"
            # Verifier is dead/stuck — kill and replace pane (omc-teams pattern)
            VERIFIER_PANE=$(replace_worker_pane "$VERIFIER_PANE" "verifier")
            continue
          fi
        fi

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
        log_debug "[EXEC] iter=$ITERATION phase=verdict engine=$VERIFIER_ENGINE verdict=$verdict recommended=$recommended us_id=${signal_us_id:-all} issues=$_issues_count"

        case "$verdict" in
          pass)
            CONSECUTIVE_FAILURES=0
            CONSENSUS_ROUND=0

            # --- Per-US tracking ---
            if [[ "$VERIFY_MODE" = "per-us" && -n "$signal_us_id" && "$signal_us_id" != "ALL" ]]; then
              # Add this US to verified list
              if [[ -n "$VERIFIED_US" ]]; then
                VERIFIED_US="${VERIFIED_US},${signal_us_id}"
              else
                VERIFIED_US="$signal_us_id"
              fi
              log "  US $signal_us_id verified. Verified so far: $VERIFIED_US"
              log_debug "[EXEC] iter=$ITERATION verified_us_update=$signal_us_id verified_us_total=$VERIFIED_US"
              update_status "verifier" "pass_us"
              # Worker will do next US on next iteration
            elif [[ "$recommended" == "complete" || "$signal_us_id" == "ALL" ]]; then
              # Final full verify passed or complete recommended
              write_complete_sentinel "$verdict_summary"
              update_status "complete" "pass"
              return 0
            else
              log "  Verifier passed but did not recommend complete. Continuing."
              update_status "verifier" "pass_continue"
            fi
            ;;
          fail)
            # --- governance.md s7½: Fix Loop (adapted for tmux lean mode) ---
            (( CONSECUTIVE_FAILURES++ ))
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
            log_debug "[EXEC] iter=$ITERATION phase=fix_loop trigger=$verdict consecutive_failures=$CONSECUTIVE_FAILURES fix_contract=$fix_contract"

            # Circuit breaker: consecutive failures
            if (( CONSECUTIVE_FAILURES >= 3 )); then
              log_debug "[EXEC] iter=$ITERATION circuit_breaker=consecutive_failures detail=\"3 consecutive verification failures\""
              log_error "Circuit breaker: 3 consecutive verification failures"
              write_blocked_sentinel "3 consecutive verification failures"
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

    # --- governance.md s7 step 8: Write result log ---
    write_result_log "$ITERATION" "$signal_status"

    # --- governance.md s7 step 8: Circuit breaker - stale context check ---
    if ! check_stale_context; then
      log_debug "[EXEC] iter=$ITERATION circuit_breaker=stale_context detail=\"context unchanged for 3 consecutive iterations\""
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
