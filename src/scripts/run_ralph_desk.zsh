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
# Dependencies: tmux, claude CLI, jq
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

  if (( missing )); then
    exit 1
  fi

  # Resolve full path to claude binary for reliable launches
  CLAUDE_BIN=$(command -v claude 2>/dev/null || echo "claude")
  log "  Claude binary: $CLAUDE_BIN"
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
    tmux send-keys -t "$pane_id" C-m
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

  # Re-launch claude (tmux interactive pattern)
  safe_send_keys "$pane_id" "$CLAUDE_BIN --model $WORKER_MODEL --dangerously-skip-permissions"
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
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
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

# Run claude with fresh context (governance.md s7 step 5)
claude -p "\$(cat $prompt_file)" \\
  --model $WORKER_MODEL \\
  --dangerously-skip-permissions \\
  --output-format text \\
  2>&1 | tee $output_log

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
  local prompt_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-prompt.md"
  local trigger_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-trigger.sh"
  local output_log="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-output.log"

  # Build verifier prompt from base
  {
    cat "$VERIFIER_PROMPT_BASE"
    echo ""
    echo "---"
    echo "## Verification Context"
    echo "- **Iteration**: $iter"
    echo "- **Done Claim**: $DONE_CLAIM_FILE"
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
  {
    cat <<TRIGGER_EOF
#!/bin/zsh
# Trigger for iteration $iter verifier - generated by run_ralph_desk.zsh
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

# Run claude with fresh context (governance.md s7 step 7)
claude -p "\$(cat $prompt_file)" \\
  --model $VERIFIER_MODEL \\
  --dangerously-skip-permissions \\
  --output-format text \\
  2>&1 | tee $output_log

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

  echo '{
  "slug": "'"$SLUG"'",
  "iteration": '"$ITERATION"',
  "max_iter": '"$MAX_ITER"',
  "phase": "'"$phase"'",
  "worker_model": "'"$WORKER_MODEL"'",
  "verifier_model": "'"$VERIFIER_MODEL"'",
  "last_result": "'"$last_result"'",
  "consecutive_failures": '"$CONSECUTIVE_FAILURES"',
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
  # Kill the panes themselves
  log_debug "cleanup: killing panes $WORKER_PANE $VERIFIER_PANE"
  tmux kill-pane -t "$WORKER_PANE" 2>&1 | while read -r line; do log_debug "kill worker: $line"; done
  tmux kill-pane -t "$VERIFIER_PANE" 2>&1 | while read -r line; do log_debug "kill verifier: $line"; done

  # Remove any leftover tmp files (setopt nonomatch to avoid zsh glob errors)
  setopt local_options nonomatch 2>/dev/null
  rm -f "$LOGS_DIR"/*.tmp.* "$MEMOS_DIR"/*.tmp.* 2>/dev/null

  # Print summary
  local end_time
  end_time=$(date +%s)
  local elapsed=$(( end_time - START_TIME ))
  local minutes=$(( elapsed / 60 ))
  local seconds=$(( elapsed % 60 ))

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
  # --- Startup ---
  log "Ralph Desk Tmux Runner starting..."
  log "  Slug:            $SLUG"
  log "  Root:            $ROOT"
  log "  Max iterations:  $MAX_ITER"
  log "  Worker model:    $WORKER_MODEL"
  log "  Verifier model:  $VERIFIER_MODEL"
  log "  Poll interval:   ${POLL_INTERVAL}s"
  log "  Iter timeout:    ${ITER_TIMEOUT}s"

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

    # --- governance.md s7 step 5: Execute Worker (interactive claude, tmux pattern) ---
    # Step 5a: Launch interactive claude in Worker pane
    local worker_launch="$CLAUDE_BIN --model $WORKER_MODEL --dangerously-skip-permissions"
    log "  Launching Worker claude in pane $WORKER_PANE..."
    tmux send-keys -t "$WORKER_PANE" -l -- "$worker_launch"
    tmux send-keys -t "$WORKER_PANE" Enter

    # Step 5b: Wait for claude TUI to be ready (tmux pattern)
    if ! wait_for_pane_ready "$WORKER_PANE" 30; then
      log_error "Worker claude failed to start"
      write_blocked_sentinel "Worker claude failed to start in pane"
      update_status "blocked" "worker_start_failed"
      return 1
    fi

    # Step 5c: Wait for claude to fully initialize, then send instruction
    sleep 3
    local worker_instruction="Read and execute the instructions in $worker_prompt"
    if ! safe_send_keys "$WORKER_PANE" "$worker_instruction"; then
      log_error "Failed to send instruction to Worker"
    fi
    # Extra C-m to ensure submission (long text may false-positive the consumed check)
    sleep 0.5
    tmux send-keys -t "$WORKER_PANE" C-m 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$WORKER_PANE" C-m 2>/dev/null

    # --- governance.md s7 step 5+6: Poll for Worker completion ---
    log "  Polling for iter-signal.json..."
    if ! poll_for_signal "$SIGNAL_FILE" "$WORKER_HEARTBEAT" "$WORKER_PANE" "$worker_launch" "Worker"; then
      # Check if Worker is still actively running (not stuck)
      local worker_cmd
      worker_cmd=$(tmux display-message -p -t "$WORKER_PANE" '#{pane_current_command}' 2>/dev/null)
      if [[ "$worker_cmd" == "node" || "$worker_cmd" == "claude" ]]; then
        # Worker is still active — timeout but not a failure, just slow
        log "  Worker timed out but still active ($worker_cmd). Extending..."
        update_status "worker" "slow"
        continue
      fi
      # Worker is truly dead/stuck
      (( MONITOR_FAILURE_COUNT++ ))
      if (( MONITOR_FAILURE_COUNT >= 3 )); then
        write_blocked_sentinel "3 consecutive monitor failures (worker not active)"
        update_status "blocked" "monitor_failures"
        return 1
      fi
      log "  WARNING: Worker poll failed (monitor failure $MONITOR_FAILURE_COUNT/3)"
      update_status "worker" "poll_failed"
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

    case "$signal_status" in
      continue)
        # --- governance.md s7 step 6: continue -> go to step 8 ---
        log "  Worker requests continue. Moving to next iteration."
        update_status "worker" "continue"
        ;;
      verify)
        # --- governance.md s7 step 7: Execute Verifier ---
        log "  Worker claims done. Dispatching Verifier..."

        write_verifier_trigger "$ITERATION"
        local verifier_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).verifier-prompt.md"

        update_status "verifier" "running"

        # Step 7a: Clean previous Verifier session if claude is running
        local verifier_cmd
        verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
        if [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" ]]; then
          tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
          sleep 0.5
          tmux send-keys -t "$VERIFIER_PANE" "/exit" Enter 2>/dev/null
          sleep 2
          wait_for_pane_ready "$VERIFIER_PANE" 5 2>/dev/null || true
        fi

        local verifier_launch="$CLAUDE_BIN --model $VERIFIER_MODEL --dangerously-skip-permissions"
        log "  Launching Verifier claude in pane $VERIFIER_PANE..."
        tmux send-keys -t "$VERIFIER_PANE" -l -- "$verifier_launch"
        tmux send-keys -t "$VERIFIER_PANE" Enter

        # Step 7b: Wait for claude TUI to be ready
        if ! wait_for_pane_ready "$VERIFIER_PANE" 30; then
          log_error "Verifier claude failed to start"
          update_status "verifier" "start_failed"
          continue
        fi

        # Step 7c: Wait for claude to fully initialize, then send instruction
        sleep 3
        local verifier_instruction="Read and execute the instructions in $verifier_prompt"
        safe_send_keys "$VERIFIER_PANE" "$verifier_instruction"
        # Extra C-m to ensure submission
        sleep 0.5
        tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null
        sleep 0.3
        tmux send-keys -t "$VERIFIER_PANE" C-m 2>/dev/null

        # Poll for verify-verdict.json
        log "  Polling for verify-verdict.json..."
        if ! poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier"; then
          log_error "Verifier poll failed"
          update_status "verifier" "poll_failed"
          continue
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

        case "$verdict" in
          pass)
            CONSECUTIVE_FAILURES=0
            if [[ "$recommended" == "complete" ]]; then
              # Write COMPLETE sentinel (only Leader writes sentinels)
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

            # Circuit breaker: consecutive failures
            if (( CONSECUTIVE_FAILURES >= 3 )); then
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
