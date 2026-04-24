# lib_ralph_desk.zsh — Shared business logic for RLP Desk runner
# SOURCED by run_ralph_desk.zsh. Do NOT execute directly.
#
# IMPORTANT: Must be sourced at file scope, not inside a function.
# typeset -A creates local arrays inside functions, breaking global state.
# Functions in this file read/write globals defined by the sourcing script.

if [[ -n "${funcstack[2]:-}" ]]; then
  echo "FATAL: lib_ralph_desk.zsh must be sourced at file scope" >&2
  exit 1
fi

# =============================================================================
# Utility Functions
# =============================================================================

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

# build_claude_cmd() — centralized claude CLI command builder
# Single source of truth for all claude invocation flags (--mcp-config, DISABLE_OMC, --effort, etc.)
# Inspired by codex-plugin-cc companion pattern: CLI abstraction in one place.
# Args: $1=mode (tui|print)  $2=model  $3=prompt_file (print mode only)  $4=output_log (print mode only)  $5=effort (optional: low|medium|high|max)
# Output: complete command string on stdout
# Globals read: CLAUDE_BIN
build_claude_cmd() {
  local mode="$1"
  local model="$2"
  local prompt_file="${3:-}"
  local output_log="${4:-}"
  local effort="${5:-}"

  local base="DISABLE_OMC=1 $CLAUDE_BIN --model $model --mcp-config '{\"mcpServers\":{}}' --strict-mcp-config --dangerously-skip-permissions"
  if [[ -n "$effort" ]]; then
    base="$base --effort $effort"
  fi
  case "$mode" in
    tui)
      echo "$base"
      ;;
    print)
      echo "$base -p \"\$(cat $prompt_file)\" --output-format text 2>&1 | tee $output_log"
      ;;
    *)
      echo "ERROR: build_claude_cmd unknown mode '$mode'" >&2
      return 1
      ;;
  esac
}

# parse_model_flag() — parse unified --worker-model / --verifier-model value
# Colon format: claude models (haiku/sonnet/opus) with effort → claude engine + effort
#               codex models (gpt-*/spark) with reasoning → codex engine + reasoning
#               plain name → claude engine (no effort override)
# Usage:  parse_model_flag <value> <role>
# Output (stdout): "engine model [reasoning_or_effort]"
#   e.g. "codex gpt-5.5 medium" | "claude opus max" | "claude sonnet"
# Returns: 0 on success, 1 on invalid format (error written to stderr)
parse_model_flag() {
  local value="$1"
  local role="${2:-worker}"
  local colon_count
  colon_count=$(printf '%s' "$value" | tr -cd ':' | wc -c | tr -d ' ')
  if (( colon_count > 1 )); then
    echo "ERROR: Invalid --${role}-model format '${value}'. Use 'model:effort' (claude) or 'model:reasoning' (codex)." >&2
    return 1
  fi
  if (( colon_count == 1 )); then
    local model="${value%%:*}"
    local level="${value##*:}"
    # Detect engine by model name
    case "$model" in
      haiku|sonnet|opus)
        echo "claude $model $level"
        ;;
      spark)
        echo "codex gpt-5.3-codex-spark $level"
        ;;
      *)
        echo "codex $model $level"
        ;;
    esac
  else
    echo "claude $value"
  fi
}

# get_model_string() — return engine-appropriate model identifier string
# Claude: returns model name (e.g., "sonnet")
# Codex: returns model:reasoning (e.g., "gpt-5.5:high")
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

# get_next_model() — return next model in Worker upgrade path, or empty at ceiling
# Usage: get_next_model <model_str>
#   claude: "haiku"|"sonnet"|"opus"
#   codex:  "gpt-5.5:medium"|"gpt-5.5:high"|"gpt-5.5:xhigh"|"gpt-5.3-codex-spark:medium"|...
# Output: next model string, or empty string if at ceiling
get_next_model() {
  local current="$1"
  case "$current" in
    # Claude upgrade path (Worker only — Verifier fixed)
    haiku)          echo "sonnet"         ;;
    sonnet)         echo "opus"           ;;
    opus)           echo ""               ;;
    # Codex GPT Pro (spark) upgrade path
    gpt-5.3-codex-spark:low)    echo "gpt-5.3-codex-spark:medium" ;;
    gpt-5.3-codex-spark:medium) echo "gpt-5.3-codex-spark:high"   ;;
    gpt-5.3-codex-spark:high)   echo "gpt-5.3-codex-spark:xhigh"  ;;
    gpt-5.3-codex-spark:xhigh)  echo ""                           ;;  # spark ceiling
    # Codex Non-Pro upgrade path
    gpt-5.5:low)    echo "gpt-5.5:medium" ;;
    gpt-5.5:medium) echo "gpt-5.5:high"   ;;
    gpt-5.5:high)   echo "gpt-5.5:xhigh"  ;;
    gpt-5.5:xhigh)  echo ""               ;;
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
    log "  [WARN] Same AC failing repeatedly — consider IL-2 re-assessment of AC quality (spec quality check)"
    log_debug "[DECIDE] iter=${ITERATION:-0} phase=model_select model_upgrade=true reason=consecutive_same_ac_fail from=${_ORIGINAL_WORKER_MODEL} to=${WORKER_MODEL}"
    _SAME_US_FAIL_COUNT=0  # Reset counter after upgrade
  fi

  return 0
}

# record_us_failure() — track per-US cumulative failure count (dual counter, Option D)
# Unlike CONSECUTIVE_FAILURES which resets on pass, US_FAIL_HISTORY persists across phases.
# This enables prior-failure warnings when a US that struggled in per-US mode fails again in final verify.
# Usage: record_us_failure <us_id>
record_us_failure() {
  local us_id="$1"
  [[ -z "$us_id" || "$us_id" = "unknown" ]] && return 0

  local prev_count="${US_FAIL_HISTORY[$us_id]:-0}"
  US_FAIL_HISTORY[$us_id]=$(( prev_count + 1 ))

  # Prior-failure warning: if this US has failed before, it's showing fragility
  if (( prev_count > 0 )); then
    log "  [WARN] US $us_id has prior failure history (${US_FAIL_HISTORY[$us_id]} total failures) — consider IL-2 AC quality re-assessment"
    log_debug "[GOV] iter=${ITERATION:-0} us_prior_failures=$us_id count=${US_FAIL_HISTORY[$us_id]}"
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
  if [[ "$CONSENSUS_MODE" != "off" ]]; then
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
  "consensus_mode": "'"$CONSENSUS_MODE"'",
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

# --- Analytics: write per-iteration structured data to campaign.jsonl (always-on) ---
write_campaign_jsonl() {
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

  # Build us_fail_history JSON object from associative array
  local us_fail_history_json="{}"
  if (( ${#US_FAIL_HISTORY[@]} > 0 )); then
    us_fail_history_json="{"
    local first=1
    for key in "${(@k)US_FAIL_HISTORY}"; do
      (( first )) || us_fail_history_json+=","
      us_fail_history_json+="\"$key\":${US_FAIL_HISTORY[$key]}"
      first=0
    done
    us_fail_history_json+="}"
  fi

  jq -nc \
    --argjson iter "$iter" \
    --arg us_id "$us_id" \
    --arg worker_model "$WORKER_MODEL" \
    --arg worker_engine "$WORKER_ENGINE" \
    --arg verifier_engine "$VERIFIER_ENGINE" \
    --arg claude_verdict "${CLAUDE_VERDICT:-$verdict}" \
    --arg codex_verdict "${CODEX_VERDICT:-N/A}" \
    --arg consensus_mode "$CONSENSUS_MODE" \
    --argjson consecutive_failures "$CONSECUTIVE_FAILURES" \
    --argjson model_upgraded "${_MODEL_UPGRADED:-0}" \
    --argjson us_fail_history "$us_fail_history_json" \
    --argjson duration_worker_s "$worker_duration_s" \
    --argjson duration_verifier_s "$verifier_duration_s" \
    --arg project_root "$ROOT" \
    --arg slug "$SLUG" \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{iter: $iter, us_id: $us_id, worker_model: $worker_model, worker_engine: $worker_engine, verifier_engine: $verifier_engine, claude_verdict: $claude_verdict, codex_verdict: $codex_verdict, consensus_mode: $consensus_mode, consecutive_failures: $consecutive_failures, model_upgraded: $model_upgraded, us_fail_history: $us_fail_history, duration_worker_s: $duration_worker_s, duration_verifier_s: $duration_verifier_s, project_root: $project_root, slug: $slug, timestamp: $timestamp}' \
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
    sv_report=$(ls -t "$LOGS_DIR"/self-verification-report-*.md 2>/dev/null | head -1)
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
    echo "- Consensus: mode=$CONSENSUS_MODE model=$CONSENSUS_MODEL final_model=$FINAL_CONSENSUS_MODEL"
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
# PRD Tracking
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

# =============================================================================
# Circuit Breakers: Stale Context Detection
# =============================================================================

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
# Error Detection
# =============================================================================

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
