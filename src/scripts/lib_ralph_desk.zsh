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

# _file_mtime() — GNU-first mtime lookup with a numeric guard (IMP-01).
# On GNU coreutils, `stat -f %m` (BSD-first order) *succeeds* printing
# filesystem info instead of failing, so a BSD-first `||` chain never falls
# through to `-c %Y` and callers get a non-numeric mtime. GNU-first avoids
# that; the numeric guard protects against any other non-numeric result.
_file_mtime() {
  local mt
  mt=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0)
  [[ $mt == <-> ]] || mt=0
  print -r -- "$mt"
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

  # Bug 1 (v5.7 §4.12): zsh ${(qq)var} wraps in single quotes with proper internal escape.
  # Defends against bracketed model ids like 'claude-opus-4-7[1m]' (zsh char-class glob),
  # spaces, embedded quotes, etc. Plain "$model" would let zsh expand brackets as glob.
  #
  # v0.14.6: ANTHROPIC_BETA injected only when the model id ends with the
  # explicit '[1m]' suffix. opus / sonnet / claude-opus-4-7 (no suffix) all
  # run at the standard 200K context. Mirror of src/node/constants.mjs
  # ONE_MILLION_BETA + wantsOneMillionContext(). Update both on rotation.
  local _onem_beta=""
  case "$model" in
    *\[1m\]) _onem_beta="ANTHROPIC_BETA='context-1m-2025-08-07' " ;;
  esac
  # v5.7 §4.11.a: --add-dir whitelist for autonomous mode. ROOT (campaign cwd)
  # plus home rlp-desk tree authorized for read/write without TUI prompts.
  local _home_desk="$HOME/.claude/ralph-desk"
  local _add_dirs="--add-dir ${(qq)_home_desk} --add-dir ${(qq)ROOT}"
  local base="DISABLE_OMC=1 ${_onem_beta}$CLAUDE_BIN --model ${(qq)model} --mcp-config '{\"mcpServers\":{}}' --strict-mcp-config --dangerously-skip-permissions ${_add_dirs}"
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
      # GPT-5.6 family aliases (codex 0.144): sol=frontier, terra=balanced,
      # luna=fast/affordable. Same convention as the spark alias above.
      sol)
        echo "codex gpt-5.6-sol $level"
        ;;
      terra)
        echo "codex gpt-5.6-terra $level"
        ;;
      luna)
        echo "codex gpt-5.6-luna $level"
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
#   codex:  "gpt-5.5:medium"|"gpt-5.6-sol:max"|"gpt-5.6-terra:ultra"|"gpt-5.3-codex-spark:medium"|...
# Output: next model string, or empty string if at ceiling
#
# US-001: single-sourced from src/node/models.json (shipped default ladder),
# with an optional user override at
# ${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json} (never touched
# by postinstall). Precedence: override -> shipped -> a 3-entry emergency
# inline ladder (identical to the Node emergency ladder in
# src/node/model-ladder.mjs, cross-checked by an equivalence test).
# Malformed/unreadable JSON at any layer falls through to the next layer with
# exactly one logged warning per call (every call site invokes this via
# command substitution, i.e. a subshell, so a cross-call "already warned"
# flag can't survive anyway — each resolution warns at most once); this
# never crashes the campaign.
# Shipped-file resolution tries the installed flat layout first
# ($LIB_DIR/node/models.json), then the source-checkout layout
# ($LIB_DIR/../node/models.json — this script lives in src/scripts/).
#
# Resolved fresh on every call (no array caching): call volume is at most a
# handful per campaign (only on repeated same-US failure), so a jq
# subprocess per call is not a meaningful cost, and it keeps this function
# runnable in isolation via the single-function extraction harnesses in
# tests/test_us004_progressive_upgrade.sh and tests/test_option_cleanup.sh.
get_next_model() {
  local current="$1"
  local override_file="${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json}"
  local ladder_file="" shipped_candidate
  # Every upgrades value must be a string (empty string = ceiling) — a
  # syntactically-valid file like {"upgrades":{"haiku":123}} must still be
  # treated as malformed (fall through), not resolved into junk output.
  local ladder_filter='(.upgrades | type) == "object" and (.upgrades | to_entries | all(.value | type == "string"))'

  if [[ -f "$override_file" ]] && jq -e "$ladder_filter" "$override_file" >/dev/null 2>&1; then
    ladder_file="$override_file"
  else
    if [[ -f "$override_file" && "${_MODEL_LADDER_WARNED:-0}" != 1 ]]; then
      _MODEL_LADDER_WARNED=1
      log_error "model ladder: override file '$override_file' unreadable or malformed; falling through"
    fi
    for shipped_candidate in "$LIB_DIR/node/models.json" "$LIB_DIR/../node/models.json"; do
      if [[ -f "$shipped_candidate" ]] && jq -e "$ladder_filter" "$shipped_candidate" >/dev/null 2>&1; then
        ladder_file="$shipped_candidate"
        break
      fi
    done
    if [[ -z "$ladder_file" ]]; then
      if [[ "${_MODEL_LADDER_WARNED:-0}" != 1 ]]; then
        _MODEL_LADDER_WARNED=1
        log_error "model ladder: shipped defaults not found under '$LIB_DIR'; using emergency inline ladder (haiku, sonnet, opus only)"
      fi
      case "$current" in
        haiku)  echo "sonnet" ;;
        sonnet) echo "opus"   ;;
        *)      echo ""       ;;  # opus / unknown → ceiling
      esac
      return 0
    fi
  fi

  jq -r --arg m "$current" '.upgrades[$m] // ""' "$ladder_file" 2>/dev/null
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
  # F-26: check BOTH stages. A truncated tmp (ENOSPC / SIGPIPE / full disk) must
  # never be atomically renamed into the canonical path — a half-written
  # complete/blocked/status sentinel would otherwise pass existence checks and
  # mis-drive (or falsely terminate) the campaign. On failure: drop the tmp,
  # leave the existing target untouched, and signal the error to callers that
  # check. Behaviour on success is unchanged.
  if ! cat > "$tmp"; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  if ! mv "$tmp" "$target" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  # codex round 3 (closes the P2-2 class structurally): every SUCCESSFUL
  # atomic_write replaces $target's inode via mv, which does not preserve the
  # replaced file's chmod bits — so if a sentinel_lock_to_unlock_ms lock-start
  # mark is pending for this basename, it belongs to the instance that was
  # JUST replaced, not whatever comes next. Clear it here, once, for every
  # caller — rather than requiring each of the (now-proven-numerous) call
  # sites that replace SIGNAL_FILE/VERDICT_FILE to remember on their own.
  # Placed AFTER the successful mv (not before the write): on FAILURE above,
  # the target is untouched and any pending mark is still valid for it — only
  # a real replacement invalidates the mark. _lifecycle_clear_lock_mark is a
  # no-op when no mark is pending (the common case for the many non-monitored
  # files atomic_write also writes — fix_contract, SESSION_CONFIG, prompts,
  # triggers) and gated the same way as every other lifecycle helper, so the
  # off-path cost is one already-gated function call.
  _lifecycle_clear_lock_mark "${target:t}"
  return 0
}

# =============================================================================
# ZSH-4: race-safe per-slug lock acquisition (redesign, v0.17.1)
# =============================================================================
# Acquire an exclusive lock at $1 (a file holding the owner PID). Race-safe vs:
#   (a) two concurrent stale-lock recoverers,
#   (b) a normal starter slipping into the rm/create gap,
#   (c) a recovery mutex leaked by a crashed recoverer.
# Algorithm: fast path is `set -C` (noclobber) atomic create. On contention with
# a STALE (dead-owner) lock, recovery is serialized by an atomic `mkdir` mutex
# whose own staleness is PID-based (never age-based, so a slow-but-alive recoverer
# is never falsely reaped). Inside the mutex we re-read the lock (don't clobber a
# live holder that recovered first) and re-acquire with `set -C` (so a starter
# that grabbed the lock in the gap wins instead of us). Echoes nothing; returns:
#   0 = acquired (caller should set LOCKFILE_ACQUIRED=1 and trap cleanup)
#   1 = busy (a live instance holds the lock) OR lost a recovery race — caller exits
acquire_slug_lock() {
  local lockfile="$1"
  mkdir -p "$(dirname "$lockfile")" 2>/dev/null
  # Fast path: atomic noclobber create.
  if (set -C; echo $$ > "$lockfile") 2>/dev/null; then
    return 0
  fi
  local lock_pid
  lock_pid=$(cat "$lockfile" 2>/dev/null)
  if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
    return 1   # a live instance holds it
  fi
  # Stale lock (dead/unknown owner) — recover under an atomic mkdir mutex.
  local rmutex="${lockfile}.recovery.d"
  # Reap a leaked mutex ONLY when we can prove its owner is dead. An EMPTY owner
  # is NOT proof of death: it usually means another recoverer just won the `mkdir`
  # and has not yet written its PID (the window between `mkdir` and the owner
  # write below). Reaping an empty-owner mutex here is a TOCTOU that deletes a
  # LIVE mid-creation holder, letting two recoverers both proceed. So: a
  # present-but-dead owner is reaped immediately; for an empty owner we give a
  # brief settle window and re-read — if a PID appears it is a live holder and we
  # do NOT reap (we lose the mkdir below and back off), and only if it stays
  # empty do we treat it as a genuinely leaked mutex (creator died in the gap).
  if [[ -d "$rmutex" ]]; then
    local mowner
    mowner=$(cat "$rmutex/owner" 2>/dev/null)
    if [[ -z "$mowner" ]]; then
      sleep 0.3
      mowner=$(cat "$rmutex/owner" 2>/dev/null)
    fi
    if [[ -z "$mowner" ]] || ! kill -0 "$mowner" 2>/dev/null; then
      rm -rf "$rmutex" 2>/dev/null
    fi
  fi
  if ! mkdir "$rmutex" 2>/dev/null; then
    return 1   # another recoverer owns the critical section
  fi
  echo $$ > "$rmutex/owner" 2>/dev/null
  # Critical section: re-read the lock. If a prior recoverer installed a LIVE pid,
  # do not clobber it.
  local cur_pid
  cur_pid=$(cat "$lockfile" 2>/dev/null)
  if [[ -n "$cur_pid" && "$cur_pid" != "$$" ]] && kill -0 "$cur_pid" 2>/dev/null; then
    rm -rf "$rmutex" 2>/dev/null
    return 1
  fi
  # Replace the stale lock, re-acquiring with noclobber so a starter that slipped
  # into the gap (and created the lock) wins — we lose cleanly instead of clobbering.
  rm -f "$lockfile" 2>/dev/null
  if ! (set -C; echo $$ > "$lockfile") 2>/dev/null; then
    rm -rf "$rmutex" 2>/dev/null
    return 1
  fi
  rm -rf "$rmutex" 2>/dev/null
  return 0
}

# =============================================================================
# Bug #7 Fix-Q/R: Post-sentinel pane reaper + sentinel write-lock
# =============================================================================
# Without explicit teardown the claude/codex TUI returns to its idle prompt and
# self-reviews for ~2min after writing iter-signal.json or verify-verdict.json.
# Observed: verdict mtime drift 1m43s post-detect; iter-N verifier overlapped
# iter-N+1 worker for 2min. _kill_pane_process closes the race; _lock_sentinel
# is defense-in-depth that freezes the file mtime. Mirror of run_ralph_desk.zsh
# verifier-cleanup pattern at L2384-2397 (Ctrl+C + /exit + wait_for_pane_ready).
# Both helpers are fail-open: pane may already be dead, FS may ignore chmod.
_kill_pane_process() {
  local pane_id="$1"
  local role="${2:-producer}"
  # v0.15.4 full-wire: optional 3rd arg. When set, this reap was triggered by
  # observing a producer's sentinel file (iter-signal / verify-verdict) — the
  # caller passes the clean tag so pane_reap_latency_ms carries sentinel_type
  # context. Mirrors Node's reapProducer(paneId, sentinelFile, sentinelType)
  # (campaign-main-loop.mjs:1455-1482): pane_eof_to_cleanup_ms ALWAYS fires;
  # pane_reap_latency_ms fires ONLY when sentinel_type is non-empty.
  local sentinel_type="${3:-}"
  [[ -n "$pane_id" ]] || return 0
  if typeset -f log_debug >/dev/null 2>&1; then
    log_debug "[bug7] kill_pane_process pane=$pane_id role=$role"
  fi
  # v0.15.4 PR-B4: pane_eof_to_cleanup_ms instrumentation (flag-gated).
  # Records the wallclock from kill-start to wait_for_pane_ready return so
  # B3 can value-assert the substrate fix actually closes the race window.
  # Uses zsh native $EPOCHREALTIME (microsec) — portable to macOS BSD where
  # `date +%N` is not supported.
  local _b4_t0_ms=0
  if [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]]; then
    zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
    if [[ -n "${EPOCHREALTIME:-}" ]]; then
      local _b4_t0_str="${${EPOCHREALTIME//./}//,/}"   # strip BOTH '.' and ',' — comma-decimal LC_NUMERIC renders EPOCHREALTIME with ','
      _b4_t0_ms=${_b4_t0_str:0:13}
    fi
  fi
  tmux send-keys -t "$pane_id" C-c 2>/dev/null
  sleep 0.5
  tmux send-keys -t "$pane_id" C-c 2>/dev/null
  sleep 1
  if typeset -f wait_for_pane_ready >/dev/null 2>&1; then
    wait_for_pane_ready "$pane_id" 5 2>/dev/null || true
  fi
  if (( _b4_t0_ms > 0 )); then
    local _b4_t1_str="${${EPOCHREALTIME//./}//,/}"   # strip BOTH '.' and ',' (locale-robust, matches t0)
    local _b4_t1_ms=${_b4_t1_str:0:13}
    local _b4_delta=$(( _b4_t1_ms - _b4_t0_ms ))
    log_lifecycle_metric "pane_eof_to_cleanup_ms" $_b4_delta \
      "pane=$pane_id role=$role"
    if [[ -n "$sentinel_type" ]]; then
      log_lifecycle_metric "pane_reap_latency_ms" $_b4_delta \
        "pane=$pane_id role=$role sentinel_type=$sentinel_type" "${ITERATION:-}" "" "$sentinel_type"
    fi
  fi
  return 0
}

_lock_sentinel() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  chmod 0444 "$file" 2>/dev/null || true
  return 0
}

_unlock_sentinel() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  chmod 0644 "$file" 2>/dev/null || true
  return 0
}

# =============================================================================
# v0.15.4 PR-B4: Lifecycle observability — log_lifecycle_metric
# =============================================================================
# Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4 (P2.1 critic-round-2 fix).
# Helper defaults ON; gated OFF only by explicit $RLP_LIFECYCLE_METRICS=0
# (codex round 1 P2-1: unified on Node's `!== '0'` contract so a value like
# "true" enables on both leaders instead of silently disabling zsh-only).
# Emits to debug.log via log_debug, in a backgrounded subshell so the caller
# does not block on the FS write. The Node-side mirror is src/node/util/
# lifecycle-metrics.mjs LifecycleMetricsCollector.
#
# v0.15.4 audit M2: concurrent-appender semantics — `( ... ) &!` spawns a
# disowned subshell per metric. Multiple metrics can fire in rapid succession
# (e.g., during iter teardown) and race on debug.log. POSIX guarantees atomic
# append for writes <= PIPE_BUF (4096 bytes). A single LIFECYCLE line is
# ~150 bytes, well under the limit, so on local filesystems (APFS, ext4, xfs)
# concurrent appends produce intact non-interleaved lines. On NFS / FUSE /
# some Docker overlay setups PIPE_BUF guarantees may not hold; in those
# environments, expect possible interleaving. This is best-effort logging
# by design — the metric values land in campaign.jsonl via the Node leader's
# batched flush as the canonical authoritative record. debug.log is an
# audit aid, not the source of truth.
#
# Args:
#   $1  metric_name       e.g. iter_signal_write_to_read_ms
#   $2  value_ms          integer milliseconds (will be coerced via printf %d)
#   $3  context (optional, free-form key=val pairs joined with spaces)
#
# Side effects:
#   - When flag unset: returns 0 immediately (no fork, no FS call).
#   - When flag set:   forks `( log_debug "..." ) &!` to debug.log.
#
# Examples:
#   log_lifecycle_metric "iter_signal_write_to_read_ms" "$delta" \
#     "iter=$ITERATION us=$us_id pane=$WORKER_PANE"
#   log_lifecycle_metric "pane_reap_latency_ms" "$delta" \
#     "iter=$ITERATION sentinel=done-claim"
# B3 (zsh-leader port): accumulator the iteration flush drains into campaign.jsonl's
# `lifecycle_metrics` field. MUST be a parent-shell global appended SYNCHRONOUSLY here
# (NOT inside the backgrounded `( ) &!` debug write) so write_campaign_jsonl — called
# later in the same shell — can see it. All current callers run in directly-invoked
# parent-shell functions; a caller inside `$(...)` or `( )&` would not propagate.
typeset -ga LIFECYCLE_RECORDS=()

# v0.15.4 full-wire: lock->unlock pair bookkeeping for sentinel_lock_to_unlock_ms,
# keyed by sentinel basename (e.g. "myslug-iter-signal.json") — mirrors Node's
# _sentinelLockTimes Map (src/node/util/lifecycle-metrics.mjs markLockStart/
# markUnlock), including the H2 exclusion: done-claim is never unlocked in the
# happy path (only SIGNAL_FILE/VERDICT_FILE are), so it is never keyed here.
typeset -gA LIFECYCLE_LOCK_TIMES=()

log_lifecycle_metric() {
  [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]] || return 0   # off-path: zero work, no fork
  local metric="$1"
  local value_ms="$2"
  local ctx="${3:-}"
  # v0.15.4 full-wire: optional audit fields, embedded as JSON fields on the
  # record (not just the debug.log text line) — mirrors the Node ctx object
  # for the fields cheap enough to carry without generic key=value plumbing.
  # Omitted args stay empty and are NOT added to the record, so existing 3-arg
  # callers (e.g. pane_eof_to_cleanup_ms) are byte-for-byte unaffected.
  local _iter="${4:-}"
  local _us_id="${5:-}"
  local _sentinel_type="${6:-}"
  [[ -n "$metric" && -n "$value_ms" ]] || return 0
  # Synchronous parent-shell accumulation (drained + reset by write_campaign_jsonl).
  # jq builds the record so value_ms is a real number and strings are escaped.
  # Fail-open: a malformed record is skipped, never aborts the caller.
  local _vm _ts _rec
  _vm=$(printf '%d' "$value_ms" 2>/dev/null) || _vm=0
  (( _vm < 0 )) && _vm=0   # clamp non-negative (mirror Node collector): a negative ms
                           # (EPOCHREALTIME mis-scale / locale corruption / clock skew)
                           # would silently pass the B3-S2 `<= band` check → false PASS.
  _ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  _rec=$(jq -nc --arg m "$metric" --argjson v "$_vm" --arg ts "$_ts" \
    --arg iter "$_iter" --arg us_id "$_us_id" --arg stype "$_sentinel_type" \
    '{metric:$m, value_ms:$v, ts:$ts}
      + (if $iter != "" then {iter: (try ($iter|tonumber) catch $iter)} else {} end)
      + (if $us_id != "" then {us_id: $us_id} else {} end)
      + (if $stype != "" then {sentinel_type: $stype} else {} end)' 2>/dev/null) \
    && [[ -n "$_rec" ]] && LIFECYCLE_RECORDS+=("$_rec")
  # Audit aid (unchanged): backgrounded debug-log line.
  if typeset -f log_debug >/dev/null 2>&1; then
    ( log_debug "[LIFECYCLE] metric=$metric value_ms=$value_ms $ctx" ) &!
  fi
  return 0
}

# _epoch_ms() — locale-robust EPOCHREALTIME->integer-ms. A separate helper from
# (not a refactor of) _kill_pane_process's own inline t0/t1 pair, which is
# pinned by the "EPOCHREALTIME strip" structural test — this is the shared
# helper for the 4 newly-wired write_to_read/reap/lock emit sites. Caller must
# zmodload zsh/datetime first (same contract _kill_pane_process follows).
_epoch_ms() {
  [[ -n "${EPOCHREALTIME:-}" ]] || { print -r -- 0; return 0; }
  local _s="${${EPOCHREALTIME//./}//,/}"   # strip BOTH '.' and ',' (locale-robust)
  print -r -- "${_s:0:13}"
}

# _lifecycle_emit_write_to_read() — v0.15.4 full-wire: emits
# iter_signal_write_to_read_ms / verdict_write_to_read_ms. Mirrors
# campaign-main-loop.mjs:2006-2016 / 2110-2117 (now_ms - sentinel mtime).
#
# CAVEAT (documented, not fixed — _file_mtime is out of scope to rewrite):
# _file_mtime() is WHOLE-SECOND precision (GNU `stat -c %Y` / BSD `stat -f %m`),
# unlike Node's fsSync.statSync().mtimeMs (sub-ms). The emitted value_ms is
# therefore accurate to within ~1000ms on the file-write anchor, not true
# milliseconds — coarser than the Node leader's reading of the same metric
# name, but still useful for the B3-S2 regression band (3000ms).
#
# Args: $1=metric_name  $2=sentinel_file  $3=iter (optional)  $4=us_id (optional)
_lifecycle_emit_write_to_read() {
  [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]] || return 0
  local metric="$1" file="$2" iter="${3:-}" us_id="${4:-}"
  [[ -n "$file" && -f "$file" ]] || return 0
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  local now_ms
  now_ms=$(_epoch_ms)
  (( now_ms > 0 )) || return 0
  local mt_s
  mt_s=$(_file_mtime "$file")
  (( mt_s > 0 )) || return 0
  log_lifecycle_metric "$metric" $(( now_ms - mt_s * 1000 )) \
    "file=$file iter=$iter us_id=$us_id" "$iter" "$us_id"
}

# _lifecycle_mark_lock_start() / _lifecycle_mark_unlock() — v0.15.4 full-wire:
# sentinel_lock_to_unlock_ms pair bookkeeping. Mirrors LifecycleMetricsCollector
# .markLockStart/.markUnlock (src/node/util/lifecycle-metrics.mjs:70-84),
# including the H3 ordering contract: callers MUST invoke
# _lifecycle_mark_lock_start BEFORE _lock_sentinel's chmod, not after, so the
# metric covers the full lock duration. _lifecycle_mark_unlock silently no-ops
# when there is no matching lock-start (unmatched unlock) — same as Node.
_lifecycle_mark_lock_start() {
  [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]] || return 0
  local sentinel_key="$1"
  [[ -n "$sentinel_key" ]] || return 0
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  LIFECYCLE_LOCK_TIMES[$sentinel_key]=$(_epoch_ms)
}

_lifecycle_mark_unlock() {
  [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]] || return 0
  local sentinel_key="$1" iter="${2:-}"
  [[ -n "$sentinel_key" ]] || return 0
  local start="${LIFECYCLE_LOCK_TIMES[$sentinel_key]:-}"
  [[ -n "$start" ]] || return 0
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  local now_ms
  now_ms=$(_epoch_ms)
  log_lifecycle_metric "sentinel_lock_to_unlock_ms" $(( now_ms - start )) \
    "sentinel=$sentinel_key iter=$iter" "$iter" "" "$sentinel_key"
  unset "LIFECYCLE_LOCK_TIMES[$sentinel_key]"
}

# _lifecycle_clear_lock_mark() — codex round 1 (P2-2): drops a pending
# sentinel_lock_to_unlock_ms lock-start mark WITHOUT emitting a metric.
#
# Why this exists: a lock-mark set by _lifecycle_mark_lock_start is only
# retired by a matching _lifecycle_mark_unlock call OR overwritten by a fresh
# _lifecycle_mark_lock_start on the SAME key (both safe — Node's collector
# behaves identically, a bare Map.set()). The unsafe gap is a sentinel file
# that gets rm'd/replaced (e.g. "clear stale verdict before relaunch") by a
# code path that never reaches its OWN _lock_sentinel call for THIS attempt
# (a poll hard-fail, an early return) — the mark from the PRIOR successful
# lock is left dangling in LIFECYCLE_LOCK_TIMES, keyed by basename. If a
# LATER, unrelated _lifecycle_mark_unlock call for that same basename fires
# (e.g. the next loop-top iteration's defensive unlock), it would pair with
# the stale mark and emit a bogus duration spanning an unrelated delete+
# recreate cycle. Call this immediately alongside any such rm/replace so the
# next real lock (if any) starts clean, and an unlock with no intervening
# relock is a correct no-op instead of a false pairing.
_lifecycle_clear_lock_mark() {
  [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]] || return 0
  local sentinel_key="$1"
  [[ -n "$sentinel_key" ]] || return 0
  unset "LIFECYCLE_LOCK_TIMES[$sentinel_key]"
}

# PR-A (Bug #10) — validate operator-written manual recovery artifacts.
# Returns 0 when all 5 checks pass; 1 otherwise. Sets RECOVERY_FAIL_REASON
# (global) on failure for caller logging. Mirrors the Node-side helper
# `_validateOperatorRecoveryArtifacts` in `src/node/runner/campaign-main-loop.mjs`.
#
# Args:
#   $1  iter-signal.json path
#   $2  done-claim.json path
#   $3  status.json path
#   $4  iter-NNN.worker-prompt.md path (may not exist for iter-1 fresh start)
_validate_operator_recovery_artifacts() {
  local sig_file="$1" done_file="$2" status_file="$3" prompt_file="$4"
  RECOVERY_FAIL_REASON=""

  # Check 1: both artifacts exist + parse as JSON
  if [[ ! -f "$sig_file" ]]; then
    RECOVERY_FAIL_REASON="iter-signal.json missing"; return 1
  fi
  if [[ ! -f "$done_file" ]]; then
    RECOVERY_FAIL_REASON="done-claim.json missing"; return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    RECOVERY_FAIL_REASON="jq unavailable; cannot validate"; return 1
  fi
  if ! jq -e . "$sig_file" >/dev/null 2>&1; then
    RECOVERY_FAIL_REASON="iter-signal.json parse error"; return 1
  fi
  if ! jq -e . "$done_file" >/dev/null 2>&1; then
    RECOVERY_FAIL_REASON="done-claim.json parse error"; return 1
  fi
  if [[ ! -f "$status_file" ]] || ! jq -e . "$status_file" >/dev/null 2>&1; then
    RECOVERY_FAIL_REASON="status.json missing or invalid"; return 1
  fi

  # Check 2: us_id match in both artifacts
  local current_us sig_us done_us
  current_us=$(jq -r '.current_us // ""' "$status_file" 2>/dev/null)
  sig_us=$(jq -r '.us_id // ""' "$sig_file" 2>/dev/null)
  done_us=$(jq -r '.us_id // ""' "$done_file" 2>/dev/null)
  if [[ "$sig_us" != "$current_us" ]]; then
    RECOVERY_FAIL_REASON="iter-signal.us_id ($sig_us) != status.current_us ($current_us)"; return 1
  fi
  if [[ "$done_us" != "$current_us" ]]; then
    RECOVERY_FAIL_REASON="done-claim.us_id ($done_us) != status.current_us ($current_us)"; return 1
  fi

  # Check 3: iteration match in both artifacts
  local current_iter sig_iter done_iter
  current_iter=$(jq -r '.iteration // 0' "$status_file" 2>/dev/null)
  sig_iter=$(jq -r '.iteration // 0' "$sig_file" 2>/dev/null)
  done_iter=$(jq -r '.iteration // 0' "$done_file" 2>/dev/null)
  if [[ "$sig_iter" != "$current_iter" ]]; then
    RECOVERY_FAIL_REASON="iter-signal.iteration ($sig_iter) != status.iteration ($current_iter)"; return 1
  fi
  if [[ "$done_iter" != "$current_iter" ]]; then
    RECOVERY_FAIL_REASON="done-claim.iteration ($done_iter) != status.iteration ($current_iter)"; return 1
  fi

  # Check 4: iter_signal_quality must equal 'specific'
  local sig_quality
  sig_quality=$(jq -r '.iter_signal_quality // ""' "$sig_file" 2>/dev/null)
  if [[ "$sig_quality" != "specific" ]]; then
    RECOVERY_FAIL_REASON="iter-signal.iter_signal_quality ($sig_quality) != 'specific'"; return 1
  fi

  # Check 5: artifact mtimes must be strictly newer than worker-prompt mtime.
  # Vacuously passes when the prompt file does not exist (fresh iter-1 start
  # before any leader-written prompt).
  if [[ -f "$prompt_file" ]]; then
    local prompt_mtime sig_mtime done_mtime
    prompt_mtime=$(_file_mtime "$prompt_file")
    sig_mtime=$(_file_mtime "$sig_file")
    done_mtime=$(_file_mtime "$done_file")
    if (( sig_mtime <= prompt_mtime )); then
      RECOVERY_FAIL_REASON="iter-signal.json mtime ($sig_mtime) not strictly newer than worker-prompt mtime ($prompt_mtime)"; return 1
    fi
    if (( done_mtime <= prompt_mtime )); then
      RECOVERY_FAIL_REASON="done-claim.json mtime ($done_mtime) not strictly newer than worker-prompt mtime ($prompt_mtime)"; return 1
    fi
  fi

  return 0
}

# PR-E (Phase C1, stabilization) — operator-cleared BLOCKED recovery validator.
# Pair to PR-A (_validate_operator_recovery_artifacts above). Together they
# close two recovery surfaces: phase=verify (PR-A) and phase=blocked
# sentinel-cleared (PR-E this helper).
#
# Returns 0 when all 4 checks pass; 1 otherwise. Sets BLOCKED_RECOVERY_FAIL_REASON
# (global) on failure for caller logging. Mirrors Node `_validateBlockedRecovery`
# in src/node/runner/campaign-main-loop.mjs.
#
# Args:
#   $1  blocked sentinel path (.md)
#   $2  blocked sidecar path (.json)
#   $3  status.json path
_validate_blocked_recovery() {
  local sentinel_md="$1" sidecar_json="$2" status_file="$3"
  BLOCKED_RECOVERY_FAIL_REASON=""

  # Check 1: precondition — caller verified phase=blocked already
  # (passed in via status read; no need to re-read here)

  # Check 2: sentinel cleared by operator
  if [[ -f "$sentinel_md" ]]; then
    BLOCKED_RECOVERY_FAIL_REASON="blocked sentinel still present (operator did not clear)"
    return 1
  fi

  # Check 3: status.json must exist + counters non-zero
  if [[ ! -f "$status_file" ]]; then
    BLOCKED_RECOVERY_FAIL_REASON="status.json missing"
    return 1
  fi
  if ! command -v jq >/dev/null 2>&1; then
    BLOCKED_RECOVERY_FAIL_REASON="jq unavailable; cannot validate"
    return 1
  fi
  local fails blocks
  fails=$(jq -r '.consecutive_failures // 0' "$status_file" 2>/dev/null)
  blocks=$(jq -r '.consecutive_blocks // 0' "$status_file" 2>/dev/null)
  if [[ "$fails" == "0" && "$blocks" == "0" ]]; then
    BLOCKED_RECOVERY_FAIL_REASON="counters already zero, nothing to recover"
    return 1
  fi

  # Check 4: sidecar safety — if sidecar exists and recoverable=false, fall through
  if [[ -f "$sidecar_json" ]]; then
    if ! jq -e . "$sidecar_json" >/dev/null 2>&1; then
      BLOCKED_RECOVERY_FAIL_REASON="blocked.json sidecar parse error"
      return 1
    fi
    local recoverable category
    recoverable=$(jq -r '.recoverable' "$sidecar_json" 2>/dev/null)
    category=$(jq -r '.reason_category // "unknown"' "$sidecar_json" 2>/dev/null)
    if [[ "$recoverable" == "false" ]]; then
      BLOCKED_RECOVERY_FAIL_REASON="non-recoverable category $category from sidecar (use clean to reset)"
      return 1
    fi
  fi

  return 0
}

# PR-E helper: rename the recovered sidecar so operator can audit what was
# recovered from. Best-effort — failure is non-fatal.
#
# Args:
#   $1  blocked sidecar path (.json)
_archive_recovered_sidecar() {
  local sidecar_json="$1"
  [[ -f "$sidecar_json" ]] || return 0
  local iso
  iso=$(date -u +%Y-%m-%dT%H-%M-%SZ)
  mv "$sidecar_json" "${sidecar_json}.recovered-${iso}" 2>/dev/null || true
  return 0
}

# PR-0b-narrow (Plan v6) — stamp leader handshake ack onto the sentinel.
# Mirror of src/node/shared/fs.mjs::stampAckField. Best-effort, audit-only:
# any failure is silently swallowed. Sequence:
#   1. chmod 0644 (so jq + mv can write)
#   2. jq merge .leader_ack
#   3. atomic rename via tmp file
#   4. chmod 0444 (re-lock)
# Tolerant of jq absence (graceful degrade — no stamp, no error).
#
# codex round 3 P2-2 audit (checked, does NOT go through atomic_write, NOT
# converted, NO fix needed): this has its own inline tmp+mv (a different tmp
# naming convention than atomic_write's), so it does not get the
# _lifecycle_clear_lock_mark hook. It doesn't need it: every call site
# (grep "_stamp_ack_field \"\$" in run_ralph_desk.zsh) invokes this
# IMMEDIATELY after that SAME code path's own _lifecycle_mark_lock_start +
# _lock_sentinel on the SAME file — it annotates the instance that was just
# locked, it never replaces a DIFFERENT (older) locked instance. The mark set
# moments earlier survives this call untouched (it doesn't read or write
# LIFECYCLE_LOCK_TIMES), so the eventual unlock still pairs with the correct,
# freshly-set mark. Not the same shape as the atomic_write replacement bug.
_stamp_ack_field() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  local tmp="${file}.ack.tmp"
  chmod 0644 "$file" 2>/dev/null || true
  if jq --arg ts "$now_iso" \
        '. + {leader_ack: {acked_by: "leader", acked_at: $ts, ack_pane_state: "shell"}}' \
        "$file" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi
  chmod 0444 "$file" 2>/dev/null || true
  return 0
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

  # D-5: jq-encode the free-text restore fields so a reason/model with special
  # chars can't corrupt the status JSON (the rest of this builder is echo-based).
  local _lbr_json _owm_json
  _lbr_json=$(printf '%s' "${LAST_BLOCK_REASON:-}" | jq -Rs . 2>/dev/null); [[ -z "$_lbr_json" ]] && _lbr_json='""'
  _owm_json=$(printf '%s' "${_ORIGINAL_WORKER_MODEL:-}" | jq -Rs . 2>/dev/null); [[ -z "$_owm_json" ]] && _owm_json='""'

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
  "consecutive_blocks": '"${CONSECUTIVE_BLOCKS:-0}"',
  "last_block_reason": '"$_lbr_json"',
  "model_upgraded": '"${_MODEL_UPGRADED:-0}"',
  "same_us_fail_count": '"${_SAME_US_FAIL_COUNT:-0}"',
  "original_worker_model": '"$_owm_json"',
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

# --- US-024 (R12 P0): tmux pane / session lifecycle verification ---
# Returns 0 if pane is alive (#{pane_dead} == 0), non-zero otherwise.
# Empty pane id is treated as dead so callers don't have to pre-check.
_verify_pane_alive() {
  local pane_id="$1"
  [[ -z "$pane_id" ]] && return 1
  local dead
  dead=$(tmux display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null)
  [[ "$dead" == "0" ]]
}
# Returns 0 if the named tmux session is alive, non-zero otherwise.
_verify_session_alive() {
  local session="$1"
  [[ -z "$session" ]] && return 1
  tmux has-session -t "$session" 2>/dev/null
}

# --- US-022 (R10 P2-J): Normalized PRD US-list extractor ---
# Recognises `### US-005:`, `## US-005:`, `## US-005 -`, and bare headings.
# Returns one US-NNN per line, sorted unique.
# D-24: the canonical PRD US heading is `### US-NNN:` (3 hashes — see init
# `### US-` + count_prd_us + split_prd_by_us). The prior `^##[[:space:]]` (exactly
# 2 hashes) did NOT match a 3-hash heading, so on a real PRD this returned EMPTY.
# That silently broke `_quarantine_stale_signal` (the "us_id is in the current PRD
# → keep it" preservation guard never matched → every leftover signal, including a
# legitimate same-mission one, was quarantined/mv'd at init) and the PRD/test-spec
# lint (skipped). Accept 2 OR 3 leading hashes so it matches canonical PRDs.
_extract_prd_us_list() {
  local prd_file="$1"
  [[ -f "$prd_file" ]] || return 0
  grep -oE '^#{2,3}[[:space:]]+US-[0-9]+([[:space:]:-]|$)' "$prd_file" 2>/dev/null \
    | grep -oE 'US-[0-9]+' \
    | sort -u
}

# --- US-022 (R10 P2-J): Quarantine stale iter-signal.json from prior mission ---
# Worker autonomy is preserved: the signal is moved (not deleted) to
# .sisyphus/quarantine/iter-signal.<epoch>.json so the operator can recover.
# Argument 4 (force) skips the PRD scope check and quarantines unconditionally
# (used for tests / invasive cleanups).
_quarantine_stale_signal() {
  local signal_file="$1"
  local prd_file="$2"
  local desk="${3:-${DESK:-}}"
  [[ -f "$signal_file" ]] || return 0
  [[ -n "$desk" ]] || return 0
  local stale_us
  stale_us=$(jq -r '.us_id // empty' "$signal_file" 2>/dev/null)
  [[ -z "$stale_us" || "$stale_us" == "ALL" || "$stale_us" == "null" ]] && return 0
  if [[ -f "$prd_file" ]]; then
    local prd_us_list
    prd_us_list=$(_extract_prd_us_list "$prd_file")
    if echo "$prd_us_list" | grep -qx "$stale_us"; then
      return 0
    fi
  fi
  local qdir="$desk/.sisyphus/quarantine"
  mkdir -p "$qdir" 2>/dev/null
  local qfile="$qdir/iter-signal.$(date +%s).json"
  if mv "$signal_file" "$qfile" 2>/dev/null; then
    # Lifecycle stale-mark class closure (codex round 4): this mv is the one
    # monitored-file mutation outside the atomic_write hook and the rm sites.
    # Its current caller is init-only (empty mark map), but clear after a
    # successful mv anyway so the class invariant holds for future callers.
    _lifecycle_clear_lock_mark "${signal_file:t}"
    echo "[lane] cross-mission stale us_id ($stale_us) — quarantined to $qfile" >&2
  fi
  return 0
}

# --- US-021 (R9 P2-I): Canonical block reason for consecutive_blocks counter ---
# Strips wrapper prefixes (hygiene_violated:, wrapped:) so the counter compares
# semantic reasons rather than surface labels. Truncates to 80 chars so noisy
# tail content doesn't fragment the same logical reason into different keys.
_canonical_block_reason() {
  local raw="$1"
  echo "$raw" | sed -E 's/^(hygiene_violated:[[:space:]]*|wrapped:[[:space:]]*)//' | cut -c1-80
}

# --- US-018 (R6 P1-F): Test density enforcement (≥3 tests/AC) ---
# Counts ACs per US in the PRD (lines like `- AC1:`, `- AC2:`) and tests per US
# in the test-spec (lines like `### Test ` or `**T-`). Emits a warning when any
# US has < 3 tests / AC. Mode 'strict' returns non-zero so callers can `exit 1`.
# Reference: governance §7f.
_lint_test_density() {
  local prd_file="$1"
  local spec_file="$2"
  local mode="${3:-warn}"
  local fail=0

  [[ -f "$prd_file" ]] || { echo "[lint] PRD missing: $prd_file" >&2; return 0; }
  [[ -f "$spec_file" ]] || { echo "[lint] test-spec missing: $spec_file" >&2; return 0; }

  local us_list
  # D-24: reuse the shared extractor (now matches the canonical 3-hash `### US-`
  # heading) instead of an inline 2-hash regex that silently returned empty on a
  # real PRD → the lint skipped every canonical PRD.
  us_list=$(_extract_prd_us_list "$prd_file")
  [[ -z "$us_list" ]] && return 0

  # ZSH-8: prefer the campaign LOGS_DIR. When it is unavailable, avoid a fixed,
  # predictable /tmp name (insecure-temp: symlink/collision risk) by creating a
  # unique temp file via mktemp; fall back to a PID-scoped name only if mktemp
  # is missing.
  local audit_dir="${LOGS_DIR:-}"
  local audit_file
  if [[ -n "$audit_dir" && -d "$audit_dir" ]]; then
    audit_file="$audit_dir/test-density-audit.jsonl"
  else
    audit_file=$(mktemp "${TMPDIR:-/tmp}/test-density-audit.XXXXXX" 2>/dev/null) \
      || audit_file="${TMPDIR:-/tmp}/test-density-audit.$$.jsonl"
  fi

  local us
  for us in ${(f)us_list}; do
    # ACs in this US block of the PRD
    local ac_count
    ac_count=$(awk -v us="$us" '
      $0 ~ "^#{2,3}[[:space:]]+"us"([[:space:]]|:|-|$)" { in_us=1; next }
      in_us && /^#{2,3}[[:space:]]+US-[0-9]+/ { in_us=0 }
      in_us && /^[[:space:]]*-[[:space:]]+AC[0-9]+/ { c++ }
      END { print c+0 }
    ' "$prd_file")

    local test_count
    test_count=$(awk -v us="$us" '
      $0 ~ "^#{2,3}[[:space:]]+"us"([[:space:]]|:|-|$)" { in_us=1; next }
      in_us && /^#{2,3}[[:space:]]+US-[0-9]+/ { in_us=0 }
      in_us && (/^###[[:space:]]+Test[[:space:]]/ || /^\*\*T-/) { c++ }
      END { print c+0 }
    ' "$spec_file")

    [[ "$ac_count" -eq 0 ]] && continue

    local required=$(( ac_count * 3 ))
    if [[ "$test_count" -lt "$required" ]]; then
      fail=1
      local msg="Test density warning: $us has $test_count tests for $ac_count ACs (ratio=$test_count/$ac_count, required >=3 per AC = $required)"
      echo "$msg" >&2
      printf '{"event":"test_density_warning","us_id":"%s","ac_count":%s,"test_count":%s,"required":%s,"timestamp":"%s"}\n' \
        "$us" "$ac_count" "$test_count" "$required" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$audit_file"
    fi
  done

  if (( fail == 1 )); then
    if [[ "$mode" == "strict" ]]; then
      echo "[lint] Test density STRICT mode — exit 1 (run without --test-density-strict to continue)" >&2
      return 1
    fi
    echo "[lint] Test density WARN — see $audit_file (use --test-density-strict to fail init)" >&2
  fi
  return 0
}

# --- US-017 (R5 P0-D): Append A4 fallback audit entry ---
# Worker forgot to write iter-signal.json after done-claim → A4 fallback auto-generated a verify signal.
# This helper records the event for debugging context loss tracking.
# Per-mission ratio < 10% recommended (governance §1f).
_emit_a4_fallback_audit() {
  local us_id="${1:-UNKNOWN}"
  local iter="${2:-0}"
  local source_path="${3:-inline}"
  local audit_dir="${LOGS_DIR:-/tmp}"
  [[ -d "$audit_dir" ]] || return 0
  local audit_file="$audit_dir/a4-fallback-audit.jsonl"
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
  printf '{"event":"a4_fallback","iter":%s,"us_id":"%s","source":"%s","timestamp":"%s"}\n' \
    "$iter" "$us_id" "$source_path" "$ts" >> "$audit_file"
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

  # US-023 R11 P2-K: emit a `note` field so empty-inputs entries are distinguishable
  # from broken logging. The audit pipeline can branch on `note == 'no_actual_usage_recorded'`
  # to know that the iteration ran but token counts were not captured (tmux/estimated path).
  local cost_note="${COST_LOG_NOTE:-}"
  if [[ -z "$cost_note" ]] && (( prompt_bytes == 0 && claim_bytes == 0 && verdict_bytes == 0 )); then
    cost_note="no_actual_usage_recorded"
  fi

  echo '{"iteration":'"$iter"',"estimated_tokens":'"$estimated_tokens"',"token_source":"estimated","prompt_bytes":'"$prompt_bytes"',"claim_bytes":'"$claim_bytes"',"verdict_bytes":'"$verdict_bytes"',"worker_start_time":"'"$worker_start_time"'","worker_end_time":"'"$worker_end_time"'","worker_duration_s":'"$worker_duration_s"',"verifier_start_time":"'"$verifier_start_time"'","verifier_end_time":"'"$verifier_end_time"'","verifier_duration_s":'"$verifier_duration_s"''"$consensus_fields"',"note":"'"$cost_note"'","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$COST_LOG"
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

  # B3 (zsh-leader port): drain LIFECYCLE_RECORDS into a grouped `lifecycle_metrics`
  # object matching the Node leader's flush() shape ({metric:[{value_ms,ts},...]}).
  # Shape contract (cross-leader, test-campaign-jsonl-shape.test.mjs): null when the
  # flag is off; grouped object when on with records; {} when on but no records.
  # FAIL-OPEN: this is the always-on canonical analytics writer — any jq failure on
  # the (opt-in) lifecycle field degrades to null and the campaign row STILL writes.
  # v0.15.4 full-wire: `del(.metric)` (was a `{value_ms, ts}` whitelist) so the
  # optional iter/us_id/sentinel_type context fields log_lifecycle_metric may now
  # attach survive the grouping — mirrors Node flush()'s `{ metric, ...rest }`
  # destructure exactly. Records with no extra context still reduce to exactly
  # {value_ms, ts} (nothing to drop beyond .metric), so this is not a regression
  # for existing 3-arg callers.
  local lifecycle_json="null"
  if [[ "${RLP_LIFECYCLE_METRICS:-1}" != "0" ]]; then
    if (( ${#LIFECYCLE_RECORDS[@]} > 0 )); then
      lifecycle_json=$(printf '%s\n' "${LIFECYCLE_RECORDS[@]}" \
        | jq -s 'group_by(.metric) | map({key: .[0].metric, value: map(del(.metric))}) | from_entries' 2>/dev/null) \
        || lifecycle_json="null"
      [[ -n "$lifecycle_json" ]] || lifecycle_json="null"
    else
      lifecycle_json="{}"
    fi
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
    --argjson lifecycle_metrics "$lifecycle_json" \
    '{iter: $iter, us_id: $us_id, worker_model: $worker_model, worker_engine: $worker_engine, verifier_engine: $verifier_engine, claude_verdict: $claude_verdict, codex_verdict: $codex_verdict, consensus_mode: $consensus_mode, consecutive_failures: $consecutive_failures, model_upgraded: $model_upgraded, us_fail_history: $us_fail_history, duration_worker_s: $duration_worker_s, duration_verifier_s: $duration_verifier_s, project_root: $project_root, slug: $slug, timestamp: $timestamp, lifecycle_metrics: $lifecycle_metrics}' \
    >> "$CAMPAIGN_JSONL"

  # Reset the accumulator after every flush (snapshot+reset, mirrors Node flush()).
  LIFECYCLE_RECORDS=()
}

# --- AC4: Generate campaign-report.md on all terminal states ---
generate_campaign_report() {
  # Guard: idempotent — only generate once per campaign run
  if (( CAMPAIGN_REPORT_GENERATED )); then return 0; fi
  CAMPAIGN_REPORT_GENERATED=1

  local final_status="UNKNOWN"
  local blocked_reason=""
  local blocked_category=""
  if [[ -f "$COMPLETE_SENTINEL" ]]; then final_status="COMPLETE"
  elif [[ -f "$BLOCKED_SENTINEL" ]]; then
    final_status="BLOCKED"
    # governance §1f BLOCKED Surfacing (4-channel): markdown sentinel +
    # JSON sidecar + status + console + report. Pull both Reason and
    # Category lines for the report. Tolerate legacy sentinels missing
    # either field (back-compat).
    blocked_reason=$(grep -m1 -E '^[Rr]eason:[[:space:]]*' "$BLOCKED_SENTINEL" 2>/dev/null \
      | sed -E 's/^[Rr]eason:[[:space:]]*//' \
      || true)
    blocked_category=$(grep -m1 -E '^[Cc]ategory:[[:space:]]*' "$BLOCKED_SENTINEL" 2>/dev/null \
      | sed -E 's/^[Cc]ategory:[[:space:]]*//' \
      || true)
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
  elif [[ "${WITH_SELF_VERIFICATION_REQUESTED:-0}" == "1" ]]; then
    sv_summary="N/A — --with-self-verification requested but skipped (reason: ${SV_SKIPPED_REASON:-unknown})"
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
    if [[ -n "$blocked_reason" ]]; then
      echo "- Blocked reason: $blocked_reason"
    fi
    if [[ -n "$blocked_category" ]]; then
      echo "- Blocked category: $blocked_category"
    fi
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

  # Defense-in-depth: skip in tmux runner even if WITH_SELF_VERIFICATION leaks through
  # (claude --print hangs without TTY/stdin in tmux pane; SV is Agent-mode only)
  if [[ -n "${TMUX:-}" ]]; then
    log "SV report skipped: tmux runner detected (Agent-mode only feature)"
    return 0
  fi

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
  # </dev/null prevents the spawned process from blocking on inherited stdin (e.g. tmux pane)
  claude --print "Analyze campaign artifacts in $LOGS_DIR and generate a self-verification report with sections: 1. Automated Validation Summary, 2. Failure Deep Dive, 3. Worker Process Quality, 4. Verifier Judgment Quality, 5. AC Lifecycle, 6. Test-Spec Adherence, 7. Patterns: Strengths & Weaknesses, 8. Recommendations for Next Cycle, 9. Cost & Performance, 10. Blind Spots." \
    </dev/null > "$sv_report_file" 2>/dev/null &
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
  # Optional 2nd arg: us_id (defaults to ALL). Same first-line contract
  # as writeSentinel(complete) on the Node side so wrappers can parse
  # `head -1 | awk '{print $2}'` consistently.
  local us_id="${2:-${CURRENT_US:-ALL}}"
  echo "COMPLETE: $us_id
Summary: $summary

# Campaign Complete

Completed at iteration $ITERATION.

Timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)" | atomic_write "$COMPLETE_SENTINEL"
  # F-26: propagate atomic_write failure — never log success on a failed write.
  if (( ${pipestatus[-1]:-0} != 0 )); then
    log_error "FAILED to write COMPLETE sentinel ($COMPLETE_SENTINEL) — IO/disk error; completion NOT durably recorded"
    return 1
  fi
  log "COMPLETE sentinel written: $COMPLETE_SENTINEL"
}

# P1-D Cross-US dependency detection: scan a verdict summary or worker
# signal body for cross-US dependency tokens. Returns "cross_us_dep" when
# any token matches, "metric_failure" otherwise. governance.md §1f locks
# the token list — keep this in sync with that section.
#   English: "depends on US-", "blocking US-", "awaits US-",
#            "post-iter US-", "requires US-", "cross-US"
#   Korean:  "US-NNN 산출물", "신규 US-", "post-iter"
_classify_cross_us_or_metric() {
  local text="$1"
  if echo "$text" | grep -qE 'depends on US-|blocking US-|awaits US-|post-iter US-|requires US-[0-9]+|cross-US|US-[0-9]+ 산출물|신규 US-|post-iter'; then
    echo "cross_us_dep"
  else
    echo "metric_failure"
  fi
}

# P1-D Failure Taxonomy: derive (recoverable, suggested_action) from
# reason_category. governance.md §1f defines the 6 reason_category values
# (metric_failure, cross_us_dep, context_limit, infra_failure, repeat_axis,
# mission_abort). wrapper MUST branch on reason_category; failure_category
# is diagnostic only.
_blocked_recoverable_for_category() {
  case "$1" in
    metric_failure|cross_us_dep|infra_failure) echo "true" ;;
    context_limit|repeat_axis|mission_abort)   echo "false" ;;
    *)                                          echo "false" ;;
  esac
}
_blocked_action_for_category() {
  case "$1" in
    metric_failure|cross_us_dep) echo "retry_after_fix" ;;
    infra_failure)               echo "restart" ;;
    context_limit|repeat_axis)   echo "next_mission_chain" ;;
    mission_abort)               echo "terminal_alert" ;;
    *)                           echo "terminal_alert" ;;
  esac
}

write_blocked_sentinel() {
  local reason="$1"
  # Optional 2nd arg: us_id (defaults to ALL).
  local us_id="${2:-${CURRENT_US:-ALL}}"
  # Optional 3rd arg: reason_category (default metric_failure).
  # See governance.md §1f Failure Taxonomy for the 6-value enum.
  local category="${3:-metric_failure}"
  local recoverable suggested_action json_path
  recoverable=$(_blocked_recoverable_for_category "$category")
  suggested_action=$(_blocked_action_for_category "$category")
  json_path="${BLOCKED_SENTINEL%.md}.json"
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # US-020 R8 P1-H: Blocked exit hygiene auto-check.
  # Worker is required to update memory.md (Blocking History) and latest.md (Known Issues)
  # before signalling blocked. We compare those file mtimes against the sentinel write time;
  # if either is older than 5 minutes the worker skipped the hygiene step and we tag the
  # JSON sidecar so audit pipelines (governance §1f, 5th channel) can see it.
  local hygiene_violated=false
  local hygiene_now hygiene_mem_mt hygiene_lat_mt
  hygiene_now=$(date +%s 2>/dev/null || echo 0)
  if [[ -n "${DESK:-}" && -n "${SLUG:-}" && "$hygiene_now" -gt 0 ]]; then
    local mem_file="$DESK/memos/$SLUG-memory.md"
    local lat_file="$DESK/context/$SLUG-latest.md"
    for hf in "$mem_file" "$lat_file"; do
      if [[ -f "$hf" ]]; then
        local f_mt
        f_mt=$(_file_mtime "$hf")
        if (( hygiene_now - f_mt > 300 )); then
          hygiene_violated=true
          break
        fi
      fi
    done
  fi

  # P1-D Write Order Contract (governance.md §1f):
  # 1. JSON sidecar FIRST (wrapper-friendly, jq parseable).
  # 2. markdown sentinel SECOND (legacy, watched by older wrappers).
  # Invariant: markdown exists ⇒ JSON exists. Wrappers watch markdown,
  # then read JSON; if JSON not yet visible (rare), retry up to 5×50ms.
  # atomic_write provides per-file rename atomicity; cross-file ordering
  # is enforced by the explicit two-call sequence below.
  jq -n \
    --arg sv "2.0" \
    --arg slug "${SLUG:-unknown}" \
    --arg us_id "$us_id" \
    --argjson iter "${ITERATION:-0}" \
    --arg utc "$now_iso" \
    --arg category "$category" \
    --arg detail "$reason" \
    --argjson recoverable "$recoverable" \
    --arg action "$suggested_action" \
    --argjson hygiene "$hygiene_violated" \
    '{
      schema_version: $sv,
      slug: $slug,
      us_id: $us_id,
      blocked_at_iter: $iter,
      blocked_at_utc: $utc,
      reason_category: $category,
      reason_detail: $detail,
      failure_category: null,
      recoverable: $recoverable,
      suggested_action: $action,
      meta: { blocked_hygiene_violated: $hygiene }
    }' | atomic_write "$json_path"
  local _bs_json_rc=${pipestatus[-1]:-0}

  echo "BLOCKED: $us_id
Reason: $reason
Category: $category

# Campaign Blocked

Blocked at iteration $ITERATION.

Timestamp: $now_iso" | atomic_write "$BLOCKED_SENTINEL"
  local _bs_md_rc=${pipestatus[-1]:-0}

  # F-26: propagate atomic_write failure. The "markdown ⇒ JSON" invariant means a
  # half-written sentinel must surface loudly, not log false success. (Best-effort
  # signal: callers already `return 1` after this, so we log+return rather than
  # restructure every caller.)
  if (( _bs_md_rc != 0 || _bs_json_rc != 0 )); then
    log_error "FAILED to durably write BLOCKED sentinel (md_rc=$_bs_md_rc json_rc=$_bs_json_rc) for [$category] $reason — IO/disk error"
    return 1
  fi
  log_error "Campaign BLOCKED: [$category] $reason"
  log "BLOCKED sentinel written: $BLOCKED_SENTINEL"
  log "BLOCKED sidecar written: $json_path"
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
    # D-23 (codex NEW-3 defensive): only overwrite US_LIST when the re-split
    # actually parsed stories. A transient empty result (parse glitch, or a PRD
    # momentarily mid-edit) must NOT blank a non-empty US_LIST — that loses per-US
    # scoping (the worker's next_us computation + the coverage count both iterate
    # US_LIST), silently degrading a per-US campaign mid-flight. Keep the prior
    # US_LIST when the new parse is empty.
    if [[ -n "$current_us_list" ]]; then
      US_LIST="$current_us_list"
    else
      log_debug "prd_changed but current_us_list empty — keeping prior US_LIST='$US_LIST' (no blank-overwrite)"
    fi
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

# --- IMP-07: single API-error detector over PRE-CAPTURED pane text ---
# rc 0 = an API/service/rate-limit outage is on screen (caller should backoff);
# rc 1 = not an API error. Consolidates the old poll-loop inline sniff AND the
# drifted is_api_error() re-grep into one function, capturing the pane ONCE.
#
# codex B1 (false-positive fix): a bare numeric code (500|529|429) counts as an
# API error ONLY when co-located with an API/service/rate-limit-SPECIFIC phrase
# on the last ~10 lines — a generic `error`/`Error:` token is NOT sufficient. So
# ordinary worker output like `Error: expected status 500` or
# `expect(res.status).toBe(429)` no longer terminal-BLOCKs a healthy worker.
# The genuine outage phrases (overloaded / too many requests / service
# unavailable / the D-17a "API Error … temporarily limiting requests" banner)
# stay unconditional — real rate-limits still route to the bounded backoff.
detect_api_error() {
  local text="$1"
  [[ -n "$text" ]] || return 1
  local tail
  tail=$(print -r -- "$text" | tail -n 10)

  # Unconditional outage phrases — the signal on their own (any adjacency).
  if print -r -- "$tail" | grep -qiE 'overloaded|too many requests|service unavailable|api error.*temporarily limiting requests'; then
    return 0
  fi
  # Bare numeric codes require an API/service/rate-limit-specific context token.
  if print -r -- "$tail" | grep -qiE '(^|[^[:digit:]])(500|529|429)([^[:digit:]]|$)' \
     && print -r -- "$tail" | grep -qiE 'api error|overloaded|rate[ -]?limit|service unavailable|temporarily limiting|too many requests|quota'; then
    return 0
  fi
  return 1
}

# --- US-003 (retained shim): pane-id API error detector.
# Legacy signature that captures the pane itself, now delegating to the
# pre-captured detect_api_error so there is a single detection contract.
is_api_error() {
  local pane_id="$1"
  local pane_output
  pane_output=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
  detect_api_error "$pane_output"; return $?
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
