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

# _git_dirty_base() — the diff base for "uncommitted tracked files" detection,
# shared by the Bug #8 gate, the campaign-preexisting-dirty snapshot, and the
# US-001 commit-integrity oracle (moved here from run_ralph_desk.zsh so all three
# reuse ONE definition rather than reimplementing). Globals read: ROOT.
#
# NEW-4 (audit round 2): `git diff --name-only HEAD` FAILS (fatal, empty output)
# in a repo with NO commits (a brand-new `git init` project run before any
# commit) — so a Worker that STAGES but does not COMMIT its deliverables goes
# undetected. Echo HEAD when it exists, else git's empty-tree object so
# `git diff --name-only <base>` lists staged-but-never-committed files.
_git_dirty_base() {
  if git -C "$ROOT" rev-parse --verify HEAD >/dev/null 2>&1; then
    echo HEAD
  else
    git -C "$ROOT" hash-object -t tree /dev/null 2>/dev/null || echo 4b825dc642cb6eb9a060e54bf8d69288fbee4904
  fi
}

# GIT-FC (backlog IMP-09): fail-closed git snapshot. Prints git's stdout and
# returns git's exit code, retrying ONCE after 2s (transient index.lock /
# concurrent worker git op). On failure it logs the git stderr ITSELF —
# callers usually invoke this inside $(...) subshells, where a typeset -g
# error variable would not propagate — prints NOTHING, and returns non-zero.
# Callers MUST branch on rc and must NEVER treat failure as an empty (clean)
# list. That silent empty was the bug class this helper exists to kill.
_git_snapshot() {
  local -a _args=("$@")
  local _out _rc _err
  _err=$(mktemp "${TMPDIR:-/tmp}/rlp-git-snap.XXXXXX") || _err="/dev/null"
  _out=$(git "${_args[@]}" 2>"$_err"); _rc=$?
  if (( _rc != 0 )); then
    sleep 2
    _out=$(git "${_args[@]}" 2>"$_err"); _rc=$?
  fi
  if (( _rc != 0 )); then
    log_error "  [GIT-FC] git ${_args[*]} failed rc=$_rc: $(head -c 200 "$_err" 2>/dev/null | tr '\n' ' ')"
    log_debug "[GIT-FC] snapshot_failed rc=$_rc args='${_args[*]}'"
  else
    print -rn -- "$_out"
  fi
  [[ "$_err" != "/dev/null" ]] && rm -f "$_err"
  return $_rc
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
      haiku|sonnet|opus|claude|claude-*)
        # Short aliases (haiku/sonnet/opus), bare `claude`, AND full versioned
        # claude ids (claude-opus-4-8, claude-fable-5, claude-opus-4-8[1m], ...)
        # route to the claude engine. The `claude-*` glob also covers the
        # bracket+effort combo like claude-opus-4-8[1m]:high.
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
        # Catch-all: any colon-bearing name that is not a claude name or a known
        # codex alias is passed to codex verbatim. Warn (stderr, so the stdout
        # result stays parseable) when it is not even a gpt-* slug — a likely
        # typo being silently routed to codex.
        [[ "$model" != gpt-* ]] && print -u2 "[rlp-desk] note: model '$model' is not a claude id or known codex model — routing to codex engine. Verify this is intended."
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

# G1.d (RC-5/RC-6): sol/terra/luna cost-factor resolver. Duplicates the
# shipped-file search from get_next_model() above INLINE rather than sharing
# a helper — Driver 3: tests/test_us004_progressive_upgrade.sh and
# tests/test_option_cleanup.sh extract get_next_model's single function body
# with `sed -n "/^${fn}() {$/,/^}$/p"` under `zsh -f`; a shared helper
# extraction would break both harnesses.
#
# Precedence is the INVERSE of get_next_model's (RC-6): the shipped
# models.json wins; the user override file is consulted ONLY when the
# shipped file's `cost_factors` table is absent/malformed. A user may
# reasonably redefine which model to escalate to; a user may not redefine
# what a luna token costs relative to sol — that is a vendor pricing fact,
# not a preference.
#
# Sets two global side-channel outputs (does NOT echo a captured value —
# callers must invoke this directly, never via `$(...)`. Command substitution
# forks a subshell in zsh, which would silently discard both globals before
# the caller could read them):
#   _COST_FACTOR_X100    — INTEGER x100 value (e.g. 4 for luna's 0.04), so
#                           callers can accumulate-then-divide-once in zsh
#                           integer arithmetic without truncating small
#                           per-row products to zero (RC-12/F11 — this is for
#                           deterministic, exact fixture assertions; zsh has
#                           typeset -F and awk is already a hard dependency,
#                           so this is not a floating-point workaround).
#   _COST_FACTOR_LAST_UNKNOWN — 1 when the family was absent from the
#                           resolved table (factor 1.0 assumed; mirrors the
#                           existing _MODEL_LADDER_WARNED pattern), else 0.
#                           Callers use this to surface an explicit "(unknown
#                           model — factor 1.0 assumed)" note instead of
#                           silently dropping tokens.
_cost_factor_x100() {
  local model="$1"
  local family="${model%%:*}"
  _COST_FACTOR_X100=100
  _COST_FACTOR_LAST_UNKNOWN=0

  local shipped_candidate factors_file=""
  for shipped_candidate in "$LIB_DIR/node/models.json" "$LIB_DIR/../node/models.json"; do
    if [[ -f "$shipped_candidate" ]] && jq -e '(.cost_factors | type) == "object"' "$shipped_candidate" >/dev/null 2>&1; then
      factors_file="$shipped_candidate"
      break
    fi
  done
  if [[ -z "$factors_file" ]]; then
    local override_file="${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json}"
    if [[ -f "$override_file" ]] && jq -e '(.cost_factors | type) == "object"' "$override_file" >/dev/null 2>&1; then
      factors_file="$override_file"
    fi
  fi
  if [[ -z "$factors_file" ]]; then
    _COST_FACTOR_LAST_UNKNOWN=1
    return 0
  fi

  local result x100 flag
  result=$(jq -r --arg f "$family" \
    'if (.cost_factors | has($f)) then (((.cost_factors[$f] * 100) | floor | tostring) + " known") else "100 unknown" end' \
    "$factors_file" 2>/dev/null)
  x100="${result%% *}"
  flag="${result##* }"
  if [[ -z "$x100" || ! "$x100" =~ ^-?[0-9]+$ ]]; then
    _COST_FACTOR_LAST_UNKNOWN=1
    return 0
  fi
  _COST_FACTOR_X100="$x100"
  [[ "$flag" == "unknown" ]] && _COST_FACTOR_LAST_UNKNOWN=1
}

# _a4_pane_still_needs_reap() — fail-SAFE liveness recheck for the A4
# already-reaped guard (codex round 4). The already-reaped flag only proves a
# reap was ATTEMPTED (_kill_pane_process is fail-open), so the second reap may
# be skipped ONLY on a successful probe that positively shows a bare idle
# shell. Probe failure or an unknown/producer foreground command => reap.
# Returns 0 = still needs reap, 1 = safe to skip.
_a4_pane_still_needs_reap() {
  local pane="$1" cmd
  cmd=$(tmux display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null) || return 0
  case "$cmd" in
    zsh|bash|sh|-zsh|-bash) return 1 ;;
    *) return 0 ;;
  esac
}

# request-j ③: assembly-time sanity guard for codex `-c model_reasoning_effort=`.
# A codex launch command with an EMPTY reasoning effort is fatal — the CLI aborts
# at startup ("Error loading config.toml: reasoning_effort must not be empty"), the
# trigger instruction then leaks to the shell, and the leader BLOCKs on "worker not
# active". This is never transient (it is a mapping/restore bug, not an outage), so
# the correct response is a hard fail-fast rather than shipping the broken flag and
# looping. Call this immediately before EVERY `-c model_reasoning_effort=` assembly
# site with the effort value that will be interpolated and a short context label.
#   $1 effort value about to be interpolated (empty = fatal)
#   $2 context label (e.g. worker-relaunch / verifier / consensus-codex)
# On empty: writes an infra_failure BLOCKED sentinel and exits 1 (definitive — an
# empty effort means EVERY dispatch would fail identically). On non-empty: return 0.
_require_codex_effort() {
  local eff="$1"
  local ctx="${2:-codex-launch}"
  if [[ -z "$eff" ]]; then
    log_error "[effort-guard] empty model_reasoning_effort for codex launch (ctx=$ctx) — refusing to assemble '-c model_reasoning_effort=\"\"' (codex would abort: 'reasoning_effort must not be empty')"
    log_debug "[GOV] iter=${ITERATION:-0} effort_guard_empty=1 ctx=$ctx"
    write_blocked_sentinel "empty codex model_reasoning_effort at $ctx (model:effort mapping/restore bug — cannot launch codex)" "${CURRENT_US:-ALL}" "infra_failure"
    exit 1
  fi
  return 0
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

# Effort-aware task budget (2026-08-03 luna-first spec §6). Slow reasoning
# efforts (:xhigh, :max) get a longer per-iteration budget so cheap-but-slow
# models don't convert their savings into timeout-retry costs. Worker role
# only — verifier/consensus keep the base ITER_TIMEOUT. Applies on top of a
# user-supplied ITER_TIMEOUT too (documented in rlp-desk.md flag reference).
# Recomputed per poll from the CURRENT (possibly ladder-escalated) model.
_effective_iter_timeout() {
  local role="$1"
  # Role strings reach here capitalized from production callsites
  # (run_ralph_desk.zsh passes "Worker" / "Verifier<suffix>" / "Verifier-final",
  # which double as log labels), so the compare MUST be case-insensitive —
  # `${role:l}`. A case-sensitive `!= "worker"` made this whole helper inert:
  # every worker poll fell through to the base ITER_TIMEOUT.
  if [[ "${role:l}" != "worker" ]]; then
    echo "$ITER_TIMEOUT"
    return 0
  fi
  # Read the effort from the engine's OWN variable rather than composing a model
  # string. Composing was engine-broken in two independent ways, so a claude
  # worker could never scale: (a) run_ralph_desk.zsh sets WORKER_CODEX_MODEL
  # unconditionally after engine detection, so the `:-$WORKER_MODEL` fallback is
  # dead and a claude campaign inspected the literal "gpt-5.5"; (b)
  # get_model_string only appends the level for codex, so a claude effort in
  # WORKER_EFFORT never reached the case at all. The multiplier table is
  # engine-agnostic (spec §6) — `--worker-model opus:max` must scale like
  # `--worker-model gpt-5.6-luna:max`.
  local effort
  if [[ "${WORKER_ENGINE:-}" = "codex" ]]; then
    effort="${WORKER_CODEX_REASONING:-}"
  else
    effort="${WORKER_EFFORT:-}"
  fi
  case "${effort:l}" in
    max)   echo $(( ITER_TIMEOUT * 2 )) ;;
    xhigh) echo $(( ITER_TIMEOUT * 3 / 2 )) ;;
    *)     echo "$ITER_TIMEOUT" ;;
  esac
}

# _verdict_failure_category() — extract the effective failure_category from a
# verify-verdict JSON (luna-first spec §2.5 / governance §"Verifier: reasoning
# in verify-verdict.json"). Governance classifies failures PER ISSUE, so the
# field legitimately appears at three placements depending on the producer:
# top-level, inside `issues[]`, or inside `checks[]`. Reading only the first
# two of those silently bypassed the environment/flaky escalation guard on
# issue-level verdicts.
# Precedence: top-level .failure_category, else the first category found in
# .issues[], else .reasoning[], else .checks[]. Echoes "" when absent/unparseable
# (callers treat "" as "not an environment/flaky failure").
#
# .reasoning[] is the per-check array the verifier contract actually emits
# (see the Verdict JSON block in init_ralph_desk.zsh); .checks[] is kept for
# forward/backward compatibility with other producers.
#
# Every arm filters on `type=="string"`, matching the Node extractor's
# `typeof x === 'string'` check (src/node/runner/campaign-main-loop.mjs
# verdictFailureCategory). Without it a non-string top-level value (e.g. a
# numeric 123) is truthy to jq's `//` and SHADOWS a real category sitting in
# issues[] — the two leaders would then disagree on the same verdict file. The
# `?` operators keep a malformed shape (issues[] not an array, non-object
# entries, a top-level array/scalar) returning "" instead of a jq error.
# Usage: _verdict_failure_category <verdict_file>
_verdict_failure_category() {
  local vf="$1"
  [[ -f "$vf" ]] || { echo ""; return 0; }
  jq -r 'first((.failure_category? | select(type=="string")), (.issues? | .[]? | .failure_category? | select(type=="string")), (.reasoning? | .[]? | .failure_category? | select(type=="string")), (.checks? | .[]? | .failure_category? | select(type=="string")), "")' "$vf" 2>/dev/null || echo ""
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
# Both helpers are fail-open on a MISSING sentinel (pane may already be dead,
# file may not exist yet) and tolerate a FS that silently ignores chmod (chmod
# still exits 0 in that case). codex P2 sweep F3: a chmod that genuinely
# FAILS on an existing file now returns non-zero — see _lock_sentinel below.
_kill_pane_process() {
  local pane_id="$1"
  local role="${2:-producer}"
  # v0.15.4 full-wire: optional 3rd arg. When set, this reap was triggered by
  # observing a producer's sentinel file (iter-signal / verify-verdict) — the
  # caller passes the clean tag so pane_reap_latency_ms carries sentinel_type
  # context. Mirrors Node's reapProducer(paneId, sentinelFile, sentinelType)
  # (campaign-main-loop.mjs:1455-1482): pane_eof_to_cleanup_ms ALWAYS fires;
  # pane_reap_latency_ms fires ONLY when sentinel_type is non-empty. Both
  # metrics measure the SAME kill-start-to-shell-idle window ($_b4_delta
  # below) BY DESIGN — Node's reapProducer computes one reapMs and records()
  # it under both names too (v0.15.4 P2 sweep F1: this is not a bug; an
  # earlier doc description implying pane_reap_latency_ms measured a
  # different "sentinel-observed to shell-idle" window was corrected instead,
  # see README.md's metrics table and lifecycle-metrics.mjs's header comment).
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
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    local _b4_t0_str="${${EPOCHREALTIME//./}//,/}"   # strip BOTH '.' and ',' — comma-decimal LC_NUMERIC renders EPOCHREALTIME with ','
    _b4_t0_ms=${_b4_t0_str:0:13}
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
    # codex round 3 R3-3: pass iter (was omitted — unlike every other
    # lifecycle metric, which already carries its own .iter via F5's work)
    # so this record is self-describing about its TRUE iteration even if
    # it's retained across a failed campaign.jsonl flush and later gets
    # rebuilt into a later, different iteration's row.
    log_lifecycle_metric "pane_eof_to_cleanup_ms" $_b4_delta \
      "pane=$pane_id role=$role" "${ITERATION:-}"
    if [[ -n "$sentinel_type" ]]; then
      log_lifecycle_metric "pane_reap_latency_ms" $_b4_delta \
        "pane=$pane_id role=$role sentinel_type=$sentinel_type" "${ITERATION:-}" "" "$sentinel_type"
    fi
  fi
  return 0
}

# codex P2 sweep F3: return the REAL outcome (file exists AND chmod
# succeeded) instead of always 0. A missing file is still a fail-open no-op
# (return 0, unchanged — test_b2fix_sentinel_lock.sh AC-B3 and
# test-bug7-post-sentinel-race.sh Scenario B pin this idempotence
# explicitly); a chmod that genuinely fails on an EXISTING file (permission
# denied, FS error, ENOENT race between the -f check and the chmod call) now
# propagates as a real failure. This matters for callers that pair a
# lifecycle lock-start mark with the lock attempt (run_ralph_desk.zsh) — see
# the guarded call sites there — so a lock that never actually happened
# cannot get paired with a later unlock into a bogus
# sentinel_lock_to_unlock_ms duration. Checked: no production caller relies
# on the old always-0 contract for control flow (grep of every call site;
# the file does not set -e, and callers that genuinely don't care about the
# outcome — the 3 DONE_CLAIM_FILE-only lock sites — are explicit `|| true`).
_lock_sentinel() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  chmod 0444 "$file" 2>/dev/null
}

_unlock_sentinel() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  chmod 0644 "$file" 2>/dev/null
}

# =============================================================================
# v0.15.4 PR-B4: Lifecycle observability — log_lifecycle_metric
# =============================================================================
# Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4 (P2.1 critic-round-2 fix).
# v0.22.4: always-on (the lifecycle-metrics opt-out flag was removed after
# two default-ON dogfood release cycles with no opt-out use)
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
# markUnlock). IMP-10: the former H2 exclusion (done-claim never keyed here
# because it was never unlocked in the happy path) is closed — done-claim is
# now marked at lock time (see the DONE_CLAIM_FILE _lock_sentinel call sites)
# and unlocked at its per-iteration archival site (archive_iter_artifacts),
# tagged ctx=archival since that is a close-out, not a true unlock.
typeset -gA LIFECYCLE_LOCK_TIMES=()

# codex P2 sweep F5: parallel map storing the CURRENT iter at mark-time,
# keyed the same as LIFECYCLE_LOCK_TIMES. Without this, a lock that starts in
# iteration N and is unlocked at iteration N+1's loop-top (normal flow —
# $ITERATION has already incremented by then) gets its emitted record
# attributed to N+1 instead of N. _lifecycle_mark_unlock reads the STORED
# iter here in preference to whatever ambient iter the caller passes.
typeset -gA LIFECYCLE_LOCK_ITERS=()

log_lifecycle_metric() {
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
  # codex P2 sweep F7: a negative or non-numeric value_ms (EPOCHREALTIME
  # mis-scale near a second rollover, comma-decimal LC_NUMERIC corruption,
  # clock skew) is DROPPED entirely instead of clamped to 0. A clamp-and-keep
  # let a corrupted measurement silently satisfy the B3-S2 `<= band` check as
  # a false PASS — an unmeasured metric already SKIPs (not fails) B3-S2, so
  # dropping is safe: no record beats a wrong one. `<->` matches a plain
  # non-negative digit sequence, so a genuine "0" (real sub-ms measurement)
  # is kept and "-50"/"abc"/"" are not.
  if [[ "$value_ms" != <-> ]]; then
    if (( DEBUG )) && typeset -f log_debug >/dev/null 2>&1; then
      ( log_debug "[LIFECYCLE-WARN] dropped record: metric=$metric non-numeric/negative value_ms='$value_ms'" ) &!
    fi
    return 0
  fi
  # codex P2 sweep F2: fork-free record assembly (previously shelled out to
  # the date and jq binaries, 2 forks/call minimum) on the post-sentinel reap hot path — see the
  # capture/emit split in _lifecycle_emit_write_to_read). Safe by construction:
  # value_ms is already digit-only-validated above; metric is a hardcoded
  # call-site literal; iter/us_id/sentinel_type are leader-generated
  # identifiers (an integer, "US-###", or a fixed sentinel-tag vocabulary like
  # "iter-signal"/"verify-verdict") — never raw user/LLM text. Gate each
  # optional field to its safe charset before hand-building JSON; anything
  # outside it drops the record (same fail-open contract as the prior
  # jq-based path) rather than emit malformed JSON. sentinel_type carries
  # both bare tags ("iter-signal") AND sentinel file basenames
  # ("verdict.json") depending on caller (_kill_pane_process vs
  # _lifecycle_mark_unlock), so its charset includes '.'.
  # (`=~` POSIX-ERE match — works without `setopt extendedglob`, which this
  # file does not enable and should not enable file-wide just for this gate.)
  [[ "$metric" =~ ^[a-zA-Z0-9_]+$ ]] || return 0
  [[ -z "$_iter" || "$_iter" == <-> ]] || return 0
  [[ -z "$_us_id" || "$_us_id" =~ ^[a-zA-Z0-9_-]+$ ]] || return 0
  [[ -z "$_sentinel_type" || "$_sentinel_type" =~ ^[a-zA-Z0-9_.-]+$ ]] || return 0
  local -i _vm=$(( 10#$value_ms ))   # force base-10 (avoids leading-zero-as-octal); builtin, no fork
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  local _ts _rec
  # zsh/datetime builtin, -s writes directly into $_ts (no $(...) fork either).
  # This build's strftime has no -u flag; TZ=UTC as a one-command prefix forces
  # UTC without forking (builtins get a scoped env override, not an exec) and
  # without touching $TZ for the rest of the script (verified: does not leak).
  TZ=UTC strftime -s _ts '%Y-%m-%dT%H:%M:%SZ' $EPOCHSECONDS   # replaces the old date-binary call, no fork
  _rec="{\"metric\":\"$metric\",\"value_ms\":$_vm,\"ts\":\"$_ts\""
  [[ -n "$_iter" ]] && _rec+=",\"iter\":$_iter"
  [[ -n "$_us_id" ]] && _rec+=",\"us_id\":\"$_us_id\""
  [[ -n "$_sentinel_type" ]] && _rec+=",\"sentinel_type\":\"$_sentinel_type\""
  _rec+="}"
  LIFECYCLE_RECORDS+=("$_rec")
  # Audit aid: backgrounded debug-log line, now gated on (( DEBUG )) itself
  # (not just log_debug's own internal check) — forking a subshell per metric
  # even when DEBUG=0 was pure waste on the hot path this infra instruments.
  if (( DEBUG )) && typeset -f log_debug >/dev/null 2>&1; then
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

# _lifecycle_capture_write_to_read() / _lifecycle_emit_write_to_read() —
# v0.15.4 full-wire, split in two by codex P2 sweep F2. Mirrors
# campaign-main-loop.mjs:2006-2016 / 2110-2117 (now_ms - sentinel mtime).
#
# F2: the 4 call sites (worker + 3 verdict paths) call CAPTURE immediately on
# poll-resolve, BEFORE the pane reap (_kill_pane_process), so it does not
# meaningfully delay the reap that actually stops the claude/codex TUI from
# self-reviewing. EMIT — the fork-bearing part (log_lifecycle_metric's
# record build) — is called AFTER the reap, once the race window it's
# protecting is already closed.
#
# codex round 2 (R2-1): CAPTURE is now genuinely fork-free, not just
# "cheap". The original F2 cut was 3 nested forks per call: the outer
# call-site `x=$(_lifecycle_capture_write_to_read ...)`, an inner
# `now_ms=$(_epoch_ms)` (a fork just to invoke an already-fork-free
# function), and `mt_s=$(_file_mtime "$file")` (a fork to invoke a function
# that itself forks the external `stat` binary). now_ms is now computed
# INLINE from $EPOCHREALTIME (no function-call fork); mtime is read via the
# zsh/stat module's `zstat` builtin (no external `stat` fork), falling back
# to the fork-based _file_mtime() only if `zmodload zsh/stat` genuinely
# fails (should not happen on any zsh build this project supports — kept
# fail-open to match the rest of this file). The result is written to the
# global $_LC_CAPTURED_DELTA instead of printed to stdout, so callers assign
# it with a plain (non-forking) `x="$_LC_CAPTURED_DELTA"` instead of
# `x=$(...)`.
#
# Deliberately NOT deferred to post-reap (the other option R2-1 offered):
# the mtime stat's whole purpose is to catch the race where the reap arrives
# late and the producer keeps running long enough to REWRITE the file — if
# the stat ran after the reap, it would read whatever the SECOND write left
# behind, making iter_signal_write_to_read_ms/verdict_write_to_read_ms look
# artificially LOW exactly in the case it exists to catch. All 4 call sites
# have identical risk here (worker rewriting iter-signal.json, verifier
# rewriting verify-verdict.json), so none of them defer.
#
# CAVEAT (documented, not fixed): mtime is WHOLE-SECOND precision (both the
# zstat path and the _file_mtime fallback), unlike Node's
# fsSync.statSync().mtimeMs (sub-ms). The emitted value_ms is therefore
# accurate to within ~1000ms on the file-write anchor, not true
# milliseconds — coarser than the Node leader's reading of the same metric
# name, but still useful for the B3-S2 regression band (3000ms).
#
# _lifecycle_capture_write_to_read: Args: $1=sentinel_file. Sets
# $_LC_CAPTURED_DELTA (empty when disabled/unmeasurable — fail-open,
# matches the prior contract).
typeset -g _LC_CAPTURED_DELTA=""
_lifecycle_capture_write_to_read() {
  _LC_CAPTURED_DELTA=""
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  [[ -n "${EPOCHREALTIME:-}" ]] || return 0
  local _now_s="${${EPOCHREALTIME//./}//,/}"   # strip BOTH '.' and ',' (locale-robust, matches _epoch_ms)
  local now_ms="${_now_s:0:13}"
  [[ "$now_ms" == <-> ]] || return 0
  # codex round 3 R3-1: mt_s starts EMPTY (not "0") so the fallback check
  # below can actually tell "zstat never populated anything" apart from "a
  # genuine mtime". A pre-init of "0" would itself pass the `<->` numeric
  # glob, permanently skipping the fork-based fallback whenever zstat
  # failed — the fallback comment claimed a contract the code never honored.
  local mt_s=""
  # codex round 3 R3-1 (found while writing the fallback test): `zmodload
  # zsh/stat` (no -F) binds the SAME builtin under BOTH `zstat` and `stat` —
  # zshmodules(1) documents this explicitly and recommends against it,
  # because it shadows the external `stat` binary for the REST OF THE
  # PROCESS. That silently broke this function's own fork-based fallback
  # (_file_mtime calls `stat -c %Y`/`stat -f %m`, which would hit zsh's
  # `stat` builtin instead — a different calling convention — once this
  # module had been loaded once). `zmodload -F zsh/stat b:zstat` loads ONLY
  # the `zstat` binding, leaving the external `stat` command untouched.
  if zmodload -e zsh/stat 2>/dev/null || zmodload -F zsh/stat b:zstat 2>/dev/null; then
    local -A _lc_statarr
    zstat -H _lc_statarr +mtime -- "$file" 2>/dev/null
    mt_s="${_lc_statarr[mtime]:-}"
  fi
  # Fall back when zstat didn't run, returned nothing, returned something
  # non-numeric, or returned a non-positive mtime (0/negative — either a
  # capture failure or a pathological epoch-0 file; either way, worth a
  # second opinion from the fork-based path before giving up).
  [[ -n "$mt_s" && "$mt_s" == <-> ]] && (( mt_s > 0 )) || mt_s=$(_file_mtime "$file")
  (( mt_s > 0 )) || return 0   # zstat AND the fallback both failed/invalid — drop (F7-consistent: no capture beats a wrong one)
  _LC_CAPTURED_DELTA=$(( now_ms - mt_s * 1000 ))
}

# _lifecycle_emit_write_to_read: Args: $1=metric_name  $2=sentinel_file
# $3=delta_ms (from _lifecycle_capture_write_to_read)  $4=iter (optional)
# $5=us_id (optional). No-ops when $3 is empty (nothing was captured).
_lifecycle_emit_write_to_read() {
  local metric="$1" file="$2" delta="${3:-}" iter="${4:-}" us_id="${5:-}"
  [[ -n "$delta" ]] || return 0
  log_lifecycle_metric "$metric" "$delta" \
    "file=$file iter=$iter us_id=$us_id" "$iter" "$us_id"
}

# _lifecycle_mark_lock_start() / _lifecycle_mark_unlock() — v0.15.4 full-wire:
# sentinel_lock_to_unlock_ms pair bookkeeping. Mirrors LifecycleMetricsCollector
# .markLockStart/.markUnlock (src/node/util/lifecycle-metrics.mjs:70-84),
# including the H3 ordering contract: callers MUST invoke
# _lifecycle_mark_lock_start BEFORE _lock_sentinel's chmod, not after, so the
# metric covers the full lock duration. _lifecycle_mark_unlock silently no-ops
# when there is no matching lock-start (unmatched unlock) — same as Node.
#
# Args: $1=sentinel_key  $2=iter (optional — codex P2 sweep F5, see below).
_lifecycle_mark_lock_start() {
  local sentinel_key="$1" iter="${2:-}"
  [[ -n "$sentinel_key" ]] || return 0
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  LIFECYCLE_LOCK_TIMES[$sentinel_key]=$(_epoch_ms)
  # codex P2 sweep F5: stamp the CURRENT iter at mark-time so a lock that
  # spans an iteration boundary (starts in N, unlocked at N+1's loop-top,
  # where $ITERATION has already incremented) is attributed to N — not the
  # ambient iter at unlock time, which _lifecycle_mark_unlock below would
  # otherwise fall back to.
  LIFECYCLE_LOCK_ITERS[$sentinel_key]="$iter"
}

# Args: $1=sentinel_key  $2=iter (fallback only — used when no iter was
# stamped at mark-time, e.g. an older/direct caller that didn't pass one).
# $3=ctx_tag (optional, IMP-10) — free-text tag appended to the detail string
# as "ctx=$ctx_tag" when non-empty (e.g. "archival" for the done-claim
# lock->close-out series). Absent/empty $3 leaves 2-arg/1-arg callers'
# output byte-identical to before this arg existed.
_lifecycle_mark_unlock() {
  local sentinel_key="$1" fallback_iter="${2:-}" ctx_tag="${3:-}"
  [[ -n "$sentinel_key" ]] || return 0
  local start="${LIFECYCLE_LOCK_TIMES[$sentinel_key]:-}"
  [[ -n "$start" ]] || return 0
  # codex P2 sweep F5: prefer the iter STORED at mark-time over the ambient
  # one the caller passes — see _lifecycle_mark_lock_start above.
  local marked_iter="${LIFECYCLE_LOCK_ITERS[$sentinel_key]:-}"
  local iter="${marked_iter:-$fallback_iter}"
  zmodload -e zsh/datetime || zmodload zsh/datetime 2>/dev/null
  local now_ms
  now_ms=$(_epoch_ms)
  local detail="sentinel=$sentinel_key iter=$iter"
  [[ -n "$ctx_tag" ]] && detail="$detail ctx=$ctx_tag"
  log_lifecycle_metric "sentinel_lock_to_unlock_ms" $(( now_ms - start )) \
    "$detail" "$iter" "" "$sentinel_key"
  unset "LIFECYCLE_LOCK_TIMES[$sentinel_key]"
  unset "LIFECYCLE_LOCK_ITERS[$sentinel_key]"
}

# _lifecycle_flush_pending_locks() — codex P2 sweep F5: a COMPLETE exit
# (leader-finalize sequential-verify pass, full/ALL verify pass) `return`s
# straight out of the campaign loop and skips the loop-top unlock block that
# normally closes out the LAST iteration's lock (there is no "next
# iteration" for it to run in) — silently dropping that sample from
# campaign.jsonl. Call once, immediately before the terminal
# write_campaign_jsonl, to emit every still-pending lock/unlock pair (using
# each one's OWN stored iter, per the fix above) before the process exits.
# A no-op when nothing is pending (the common, non-terminal-exit case).
_lifecycle_flush_pending_locks() {
  local sentinel_key
  for sentinel_key in "${(k)LIFECYCLE_LOCK_TIMES[@]}"; do
    _lifecycle_mark_unlock "$sentinel_key"
  done
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
  local sentinel_key="$1"
  [[ -n "$sentinel_key" ]] || return 0
  unset "LIFECYCLE_LOCK_TIMES[$sentinel_key]"
  unset "LIFECYCLE_LOCK_ITERS[$sentinel_key]"   # codex P2 sweep F5: keep the two maps in sync
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
  # US-002 AC2.2a: on BLOCK, fold any waiver-rejection summary into the block
  # reason so the operator sees WHY a waiver was not honored (symmetric with the
  # honored-waiver id citation — a silent rejection would reincarnate the
  # original deadlock).
  local _eff_block_reason="${LAST_BLOCK_REASON:-}"
  if [[ "$phase" == "blocked" && -n "${WAIVER_REJECTION_SUMMARY:-}" ]]; then
    if [[ -n "$_eff_block_reason" ]]; then
      _eff_block_reason="${_eff_block_reason} | waiver rejections: ${WAIVER_REJECTION_SUMMARY}"
    else
      _eff_block_reason="waiver rejections: ${WAIVER_REJECTION_SUMMARY}"
    fi
  fi
  local _lbr_json _owm_json _owcr_json
  _lbr_json=$(printf '%s' "$_eff_block_reason" | jq -Rs . 2>/dev/null); [[ -z "$_lbr_json" ]] && _lbr_json='""'
  _owm_json=$(printf '%s' "${_ORIGINAL_WORKER_MODEL:-}" | jq -Rs . 2>/dev/null); [[ -z "$_owm_json" ]] && _owm_json='""'
  # request-j ③: persist the ORIGINAL worker codex reasoning effort alongside
  # original_worker_model. Without it, a leader-relaunch restore (D-5b) rehydrates
  # every upgrade field EXCEPT the reasoning, so restore-on-pass later assigns an
  # empty string into WORKER_CODEX_REASONING → the next dispatch assembles
  # `-c model_reasoning_effort=""` → codex refuses to start ("reasoning_effort must
  # not be empty") → BLOCKED. jq-encoded like the other free-text restore fields.
  _owcr_json=$(printf '%s' "${_ORIGINAL_WORKER_CODEX_REASONING:-}" | jq -Rs . 2>/dev/null); [[ -z "$_owcr_json" ]] && _owcr_json='""'

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
  "original_worker_codex_reasoning": '"$_owcr_json"',
  "verified_us": '"$verified_us_json"''"$consensus_json"',
  "iter_start_head": "'"${ITER_START_HEAD:-}"'",
  "gate_receipt": "'"${GATE_RECEIPT_STATUS:-none}"'",
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
    # IMP-10 (closes F3.3/H2): done-claim is locked at production time
    # (_lock_sentinel "$DONE_CLAIM_FILE" call sites) but the happy path never
    # calls _unlock_sentinel on it — this archival copy IS the per-iteration
    # close-out event, so emit sentinel_lock_to_unlock_ms here instead. Key
    # MUST match the mark-time key exactly: ${DONE_CLAIM_FILE:t}, same
    # basename expression used at every done-claim _lock_sentinel call site.
    # ctx=archival distinguishes this lock->close-out series from the true
    # lock->unlock series (signal/verdict). No-ops when no lock is pending
    # (e.g. this iteration never reached a done-claim lock site).
    _lifecycle_mark_unlock "${DONE_CLAIM_FILE:t}" "$iter" "archival"
  fi
  if [[ -f "$VERDICT_FILE" ]]; then
    cp "$VERDICT_FILE" "$LOGS_DIR/iter-${iter_padded}-verify-verdict.json" 2>/dev/null
  fi
  # request-m ②: also archive the iter-signal — it is the third per-iteration
  # evidence artifact (the verdict's companion; a re-seed sometimes needs the
  # signal that produced a verdict, not only the verdict). ${SIGNAL_FILE:-} so an
  # unset global (unit tests that only wire DONE_CLAIM_FILE/VERDICT_FILE) is a
  # clean no-op under nounset.
  if [[ -n "${SIGNAL_FILE:-}" && -f "${SIGNAL_FILE:-}" ]]; then
    cp "$SIGNAL_FILE" "$LOGS_DIR/iter-${iter_padded}-iter-signal.json" 2>/dev/null
  fi
}

# request-m ②: run-scoped artifact archive (evidence preservation). A bare leader
# restart resets ITERATION to 1 (no cross-run counter), so a new run's iter-1,2,3…
# would silently CLOBBER the same-numbered iter-* files from a PRIOR run — the
# field failure: pass-verdict receipts for US-001/002/003 were overwritten and a
# later PRD-revision re-seed (`ledger-seed --evidence`) became impossible. This
# moves any iter-* left in $logs_dir into $logs_dir/runs/superseded-<label>/
# BEFORE the new run can write. Evidence is RELOCATED, never deleted. <label> is
# the superseding run's startup timestamp so the batch is self-describing. Loud
# one-line log. Best-effort: any failure returns 0 (never blocks the campaign).
archive_superseded_run_artifacts() {
  local logs_dir="$1" label="$2"
  [[ -n "$logs_dir" && -d "$logs_dir" ]] || return 0
  local -a stale
  stale=("$logs_dir"/iter-*(N))
  (( ${#stale} )) || return 0
  local dest
  dest=$(_collision_free_archive_dir "$logs_dir/runs" "$label")
  mkdir -p "$dest" 2>/dev/null || return 0
  local f moved=0
  for f in "${stale[@]}"; do
    [[ -e "$f" ]] || continue
    mv "$f" "$dest/" 2>/dev/null && (( moved++ ))
  done
  (( moved > 0 )) && log "[archive] moved $moved superseded iter-* artifact(s) from a prior run → $dest (evidence preserved, never deleted)"
  return 0
}

# request-m ② (collision-proof): pick a `runs/superseded-<label>` dir that does not
# clobber an existing archive. The label is a wall-clock second
# (date +%Y%m%d-%H%M%S), so two leader/init starts in the SAME second would share
# it — silently overwriting the first archive is the exact evidence-loss class ②
# prevents. If the base dir already holds a prior archive (exists AND non-empty),
# disambiguate deterministically (-2, -3, …, detect_next_version-style) instead of
# reusing it. Echoes the chosen absolute dir path (never merges/overwrites).
_collision_free_archive_dir() {
  local runs_dir="$1" label="$2"
  local base="$runs_dir/superseded-$label"
  if [[ -d "$base" && -n "$(ls -A "$base" 2>/dev/null)" ]]; then
    local n=2
    while [[ -e "$runs_dir/superseded-$label-$n" ]]; do (( n++ )); done
    printf '%s' "$runs_dir/superseded-$label-$n"
  else
    printf '%s' "$base"
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

# --- IMP-01: canonical verdict/transition normalizer -------------------------
# Parity contract: src/node/shared/verdict-schema.mjs normalizeVerdictString /
# normalizeTransitionString — synonym tables MUST stay identical (pinned by
# tests/test_verdict_normalize.sh + test-verdict-schema-contract.test.mjs
# driving tests/fixtures/verdict-schema/verdict-string-cases.json through BOTH).
# Rules: strip CR, trim, lowercase, collapse space/hyphen runs to "_", closed
# synonym map. Unknown values pass through canonicalized-but-unmapped so the
# unknown-verdict CB branch (run_ralph_desk.zsh "unrecognized verifier verdicts")
# still fires. "" and "null" pass through untouched — the consensus null-retry
# guards (A12/D-14) depend on those exact values.
_normalize_verdict() {
  local raw="$1" field="${2:-verdict}"
  local v
  v=$(print -rn -- "$raw" | tr -d '\r' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/([[:space:]]|-)+/_/g')
  if [[ "$field" == "transition" ]]; then
    case "$v" in
      completed|done) v="complete" ;;
    esac
  else
    case "$v" in
      passed)         v="pass" ;;
      failed|failure) v="fail" ;;
      block)          v="blocked" ;;
    esac
  fi
  print -r -- "$v"
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

# --- vision-adopt §1b: 3-doc consistency lint (PRD ↔ test-spec ↔ per-US split) ---
# Deterministic structural cross-check, precedent _lint_test_density. Three
# checks:
#   (i)   every US in the per-US PRD split (prd-<slug>-US-*.md) exists as a
#         `### US-NNN` heading in the main PRD (no orphan split after a US was
#         dropped from the PRD).
#   (ii)  every AC id referenced by the test-spec (an `ACN` token under a
#         `## US-NNN` section) exists as a `- ACN` line in that US's PRD block.
#   (iii) per-US AC count is consistent between the main PRD block and the
#         per-US split file (a stale split file drifts the worker's per-US view).
# Mode: 'warn' (default) emits to stderr, returns 0. 'strict' returns 1 on any
# violation so init can REJECT (campaign not started). Reference: governance §1b.
#
# Args: <prd_file> <test_spec_file> <plans_dir> <slug> [warn|strict]
_prd_us_ac_ids() {
  # <prd_file> <us_id> → sorted-unique ACN ids declared in that US's PRD block.
  [[ -f "$1" ]] || return 0
  awk -v us="$2" '
    $0 ~ "^#{2,3}[[:space:]]+"us"([[:space:]]|:|-|$)" { in_us=1; next }
    in_us && /^#{2,3}[[:space:]]+US-[0-9]+/ { in_us=0 }
    in_us && /^[[:space:]]*-[[:space:]]+AC[0-9]+/ {
      if (match($0, /AC[0-9]+/)) print substr($0, RSTART, RLENGTH)
    }
  ' "$1" | sort -u
}
_prd_us_ac_count() {
  # <prd_file> <us_id> → count of `- ACN` lines in that US's block.
  [[ -f "$1" ]] || { printf 0; return 0; }
  awk -v us="$2" '
    $0 ~ "^#{2,3}[[:space:]]+"us"([[:space:]]|:|-|$)" { in_us=1; next }
    in_us && /^#{2,3}[[:space:]]+US-[0-9]+/ { in_us=0 }
    in_us && /^[[:space:]]*-[[:space:]]+AC[0-9]+/ { c++ }
    END { print c+0 }
  ' "$1"
}
_lint_3doc_consistency() {
  local prd_file="$1" spec_file="$2" plans_dir="$3" slug="$4" mode="${5:-warn}"
  local fail=0
  # NOTE: all loop-body locals are declared ONCE here, not inside the loops.
  # zsh re-`local` of an already-set scoped var inside a loop echoes its value
  # (`n_prd=2`) to stdout — a nasty gotcha that would corrupt the WARN capture.
  local u f base sus split_file n_prd n_split pairs pair ts_us ts_ac
  typeset -A prd_us_seen

  [[ -f "$prd_file" ]] || { echo "[lint-3doc] PRD missing: $prd_file" >&2; return 0; }

  local -a prd_us
  prd_us=(${(f)"$(_extract_prd_us_list "$prd_file")"})
  # No US structure → nothing structural to cross-check.
  (( ${#prd_us} )) || return 0
  for u in $prd_us; do prd_us_seen[$u]=1; done

  # (i) orphan per-US split PRD files.
  for f in "$plans_dir"/prd-"$slug"-US-*.md(N); do
    base="${f:t}"
    sus="${${base#prd-${slug}-}%.md}"   # e.g. US-003
    if [[ -z "${prd_us_seen[$sus]:-}" ]]; then
      fail=1
      echo "[lint-3doc] orphan split: $base has no matching '### $sus' in $prd_file:t" >&2
    fi
  done

  # (iii) per-US AC count consistency PRD monolithic vs per-US split file.
  for u in $prd_us; do
    split_file="$plans_dir/prd-$slug-$u.md"
    [[ -f "$split_file" ]] || continue
    n_prd=$(_prd_us_ac_count "$prd_file" "$u")
    n_split=$(_prd_us_ac_count "$split_file" "$u")
    if [[ "$n_prd" != "$n_split" ]]; then
      fail=1
      echo "[lint-3doc] AC-count drift for $u: PRD=$n_prd split=$n_split (re-split the PRD)" >&2
    fi
  done

  # (ii) AC ids referenced by the test-spec should exist in the PRD's US block.
  # ADVISORY ONLY (never sets `fail`) — unlike (i)/(iii), which diff tool-generated
  # split files deterministically, this parses human-authored test-spec text, and
  # no pattern is provably false-positive-free across the open test-spec formats
  # the project allows. A false hard-REJECT at init would block a legitimate
  # campaign, so (ii) only WARNs (at init AND run). To keep the WARN low-noise we
  # scope extraction to STRUCTURED AC-reference lines — list items (`- `, `* `,
  # `N. `) and table rows (`| … |`) — so an AC id mentioned in free prose (e.g.
  # "unlike US-2's AC5 approach") never triggers it.
  if [[ -f "$spec_file" ]]; then
    pairs=$(awk '
      /^##[[:space:]]+US-[0-9]+/ { if (match($0,/US-[0-9]+/)) cur=substr($0,RSTART,RLENGTH); next }
      cur != "" && $0 ~ /^[[:space:]]*([-*|]|[0-9]+\.)/ {
        line=$0
        while (match(line,/AC[0-9]+/)) {
          print cur" "substr(line,RSTART,RLENGTH)
          line=substr(line,RSTART+RLENGTH)
        }
      }
    ' "$spec_file" | sort -u)
    for pair in ${(f)pairs}; do
      [[ -n "$pair" ]] || continue
      ts_us="${pair%% *}"; ts_ac="${pair##* }"
      # Test-spec references a US the PRD does not declare.
      if [[ -z "${prd_us_seen[$ts_us]:-}" ]]; then
        echo "[lint-3doc] ADVISORY: test-spec references $ts_us/$ts_ac but PRD has no $ts_us" >&2
        continue
      fi
      if ! _prd_us_ac_ids "$prd_file" "$ts_us" | grep -qx "$ts_ac"; then
        echo "[lint-3doc] ADVISORY: test-spec references $ts_us/$ts_ac but PRD $ts_us has no '- $ts_ac'" >&2
      fi
    done
  fi

  if (( fail == 1 )); then
    if [[ "$mode" == "strict" ]]; then
      echo "[lint-3doc] STRICT — PRD/test-spec/split inconsistency (fix before init completes)" >&2
      return 1
    fi
    echo "[lint-3doc] WARN — PRD/test-spec/split inconsistency (re-gate via revise)" >&2
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

  # G1.b: per-row model attribution so the Cost & Performance summary can
  # convert to a sol-equivalent WITHOUT re-deriving it from campaign.jsonl
  # (which tolerates row loss — Option C, dogfood-gaps-g1-g4.md §G1). us_id
  # is the same value the iteration passes to write_campaign_jsonl below
  # (both read the same global). worker_effort is separate from worker_model
  # for codex legs (see get_next_model / check_model_upgrade) — ladder moves
  # can be effort-only.
  local cost_us_id="${signal_us_id:-unknown}"
  local cost_worker_model="$WORKER_MODEL"
  local cost_worker_engine="$WORKER_ENGINE"
  local cost_worker_effort="${WORKER_CODEX_REASONING:-}"
  local cost_verifier_engine="$VERIFIER_ENGINE"

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

  echo '{"iteration":'"$iter"',"estimated_tokens":'"$estimated_tokens"',"token_source":"estimated","us_id":"'"$cost_us_id"'","worker_model":"'"$cost_worker_model"'","worker_engine":"'"$cost_worker_engine"'","worker_effort":"'"$cost_worker_effort"'","verifier_engine":"'"$cost_verifier_engine"'","prompt_bytes":'"$prompt_bytes"',"claim_bytes":'"$claim_bytes"',"verdict_bytes":'"$verdict_bytes"',"worker_start_time":"'"$worker_start_time"'","worker_end_time":"'"$worker_end_time"'","worker_duration_s":'"$worker_duration_s"',"verifier_start_time":"'"$verifier_start_time"'","verifier_end_time":"'"$verifier_end_time"'","verifier_duration_s":'"$verifier_duration_s"''"$consensus_fields"',"note":"'"$cost_note"'","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' >> "$COST_LOG"
}

# codex round 2 R2-3: set on EVERY write_campaign_jsonl call (success or
# failure) as the single source of truth the loop-top reset (run_ralph_desk.zsh)
# uses to distinguish "this iteration attempted a flush and it failed — keep
# LIFECYCLE_RECORDS for retry" from "this iteration never attempted a flush
# at all (a row-less `continue`) — discard, they belong to no row". Reset to
# 0 by the loop-top logic at the start of every iteration.
typeset -g _LC_FLUSH_ATTEMPTED=0

# --- Analytics: write per-iteration structured data to campaign.jsonl (always-on) ---
write_campaign_jsonl() {
  _LC_FLUSH_ATTEMPTED=1
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
  if (( ${#LIFECYCLE_RECORDS[@]} > 0 )); then
    lifecycle_json=$(printf '%s\n' "${LIFECYCLE_RECORDS[@]}" \
      | jq -s 'group_by(.metric) | map({key: .[0].metric, value: map(del(.metric))}) | from_entries' 2>/dev/null) \
      || lifecycle_json="null"
    [[ -n "$lifecycle_json" ]] || lifecycle_json="null"
  else
    lifecycle_json="{}"
  fi

  # codex P2 sweep F6: build the complete line in a variable FIRST (a single
  # jq invocation, unchanged), THEN append it in one write with an explicit
  # rc check — instead of piping jq straight into `>> "$CAMPAIGN_JSONL"`,
  # where neither jq's own exit code nor the redirect's were ever checked.
  # This also avoids a partial-line write: capturing first means either the
  # whole line exists in $_campaign_line or nothing gets appended at all,
  # rather than jq's output potentially interleaving a truncated line with a
  # concurrent/subsequent write if it were streamed straight to the file.
  local _campaign_line
  _campaign_line=$(jq -nc \
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
    '{iter: $iter, us_id: $us_id, worker_model: $worker_model, worker_engine: $worker_engine, verifier_engine: $verifier_engine, claude_verdict: $claude_verdict, codex_verdict: $codex_verdict, consensus_mode: $consensus_mode, consecutive_failures: $consecutive_failures, model_upgraded: $model_upgraded, us_fail_history: $us_fail_history, duration_worker_s: $duration_worker_s, duration_verifier_s: $duration_verifier_s, project_root: $project_root, slug: $slug, timestamp: $timestamp, lifecycle_metrics: $lifecycle_metrics}')
  if [[ $? -ne 0 || -z "$_campaign_line" ]]; then
    log_error "write_campaign_jsonl: jq record build failed for iter=$iter us_id=$us_id — campaign.jsonl NOT written this call, lifecycle accumulator retained for retry"
    return 1
  fi
  if print -r -- "$_campaign_line" >> "$CAMPAIGN_JSONL"; then
    # Reset the accumulator ONLY after a confirmed successful flush
    # (snapshot+reset, mirrors Node flush()) — a failed append below leaves
    # it intact so the next iteration's flush retries these same records.
    LIFECYCLE_RECORDS=()
  else
    log_error "write_campaign_jsonl: append to $CAMPAIGN_JSONL failed for iter=$iter us_id=$us_id — lifecycle accumulator retained for retry"
    return 1
  fi
}

# _write_campaign_jsonl_terminal() — codex round 2 R2-3: wraps
# write_campaign_jsonl for the 2 COMPLETE-path call sites (leader-finalize
# sequential-verify pass, full/ALL verify pass in run_ralph_desk.zsh). Both
# `return 0` (campaign SUCCESS) immediately after this call — if the row
# write silently failed there, the terminal row (arguably the most
# important one in the whole file) would be lost with zero chance to retry
# on a "next iteration" that will never come. Retries once, then logs LOUDLY
# (a distinct, hard-to-miss marker, not just write_campaign_jsonl's own
# routine log_error) if the retry also fails. Never blocks completion: the
# campaign must still report COMPLETE even if this terminal metrics row is
# lost — the caller ignores this function's own return value by design.
_write_campaign_jsonl_terminal() {
  local iter="$1" us_id="$2" verdict="$3"
  write_campaign_jsonl "$iter" "$us_id" "$verdict" && return 0
  log_error "write_campaign_jsonl (terminal row) failed for iter=$iter us_id=$us_id — retrying once"
  write_campaign_jsonl "$iter" "$us_id" "$verdict" && return 0
  log_error "*** CRITICAL: write_campaign_jsonl (terminal row) failed TWICE for iter=$iter us_id=$us_id — the campaign COMPLETE row is LOST from campaign.jsonl. Campaign will still report COMPLETE (metrics loss must not block a successful completion), but this run's terminal analytics row is missing. ***"
  return 1
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
    local us_id
    while (( ri <= ITERATION )); do
      local iter_dc="$LOGS_DIR/iter-$(printf '%03d' $ri)-done-claim.json"
      if [[ -f "$iter_dc" ]]; then
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
    echo "## Cost & Performance (ESTIMATED — tmux/zsh bytes÷4 basis)"
    if [[ -f "$COST_LOG" ]]; then
      # G1-3: sol-equivalent cost summary. Every number below is derived
      # SOLELY from cost-log.jsonl (Option C — lossless raw total; per-row
      # model attribution enriched by G1.b). campaign.jsonl is never joined
      # here: it tolerates row loss (lib:1885-1897) and would silently
      # under-count exactly the iterations that failed to flush.
      local total_tokens=0 raw_rows=0 attributed_rows=0
      local codex_sol_x100_sum=0 claude_legs=0
      local escalation_count=0
      local prev_model="" prev_effort="" have_prev=0
      local unknown_family_seen=0
      typeset -A final_model_by_us
      local -a final_model_us_order
      local line t row_worker_model row_worker_engine row_worker_effort row_us_id
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        (( raw_rows++ ))
        t=$(echo "$line" | jq -r '.estimated_tokens // 0' 2>/dev/null || echo 0)
        [[ "$t" =~ ^-?[0-9]+$ ]] || t=0
        total_tokens=$(( total_tokens + t ))

        row_worker_model=$(echo "$line" | jq -r '.worker_model // ""' 2>/dev/null)
        # No model attribution -> pre-enrichment row (legacy log) or a row
        # written before G1.b shipped. Still counted into the raw total
        # above; surfaced via the unattributed reconciliation line below —
        # never silently dropped (Principle 3).
        if [[ -z "$row_worker_model" ]]; then
          continue
        fi
        (( attributed_rows++ ))
        row_worker_engine=$(echo "$line" | jq -r '.worker_engine // ""' 2>/dev/null)
        row_worker_effort=$(echo "$line" | jq -r '.worker_effort // ""' 2>/dev/null)
        row_us_id=$(echo "$line" | jq -r '.us_id // "unknown"' 2>/dev/null)

        if [[ "$row_worker_engine" == "codex" ]]; then
          # C1 rounding contract: accumulate estimated_tokens × factor_x100
          # (integer) across ALL codex rows and divide by 100 exactly ONCE,
          # after the loop — never per-row. Per-row division would truncate
          # small rows (e.g. 10 luna tokens × 0.04) to zero (RC-12/F11).
          _cost_factor_x100 "$row_worker_model"
          codex_sol_x100_sum=$(( codex_sol_x100_sum + t * _COST_FACTOR_X100 ))
          (( _COST_FACTOR_LAST_UNKNOWN )) && unknown_family_seen=1
        elif [[ "$row_worker_engine" == "claude" ]]; then
          (( claude_legs++ ))
        fi

        # Escalation count: adjacent ATTRIBUTED row pairs (file order ==
        # iteration order — cost-log.jsonl is append-only) where worker_model
        # OR worker_effort changed. Ladder moves can be effort-only.
        if (( have_prev )); then
          if [[ "$row_worker_model" != "$prev_model" || "$row_worker_effort" != "$prev_effort" ]]; then
            (( escalation_count++ ))
          fi
        fi
        prev_model="$row_worker_model"
        prev_effort="$row_worker_effort"
        have_prev=1

        # Final model per US: last attributed row per us_id wins (map
        # overwrite), rendered "model:effort" (or bare model for claude
        # legs, which have no effort field).
        if [[ -z "${final_model_by_us[$row_us_id]:-}" ]]; then
          final_model_us_order+=("$row_us_id")
        fi
        if [[ -n "$row_worker_effort" ]]; then
          final_model_by_us[$row_us_id]="${row_worker_model}:${row_worker_effort}"
        else
          final_model_by_us[$row_us_id]="$row_worker_model"
        fi
      done < "$COST_LOG"

      local codex_sol_equivalent=$(( codex_sol_x100_sum / 100 ))
      echo "- Codex legs sol-equivalent: ${codex_sol_equivalent} tokens  (factors sol 1.0 / terra 0.4 / luna 0.04)"
      if (( unknown_family_seen )); then
        echo "- Note: one or more codex rows used an unrecognized model family — factor 1.0 assumed"
      fi
      echo "- Claude legs: ${claude_legs} iteration(s) (subscription pool — no factor conversion)"

      # Cross-check against status.json's model_upgraded flag — a soft
      # signal (it reflects only the LAST status write, not a cumulative
      # count), so a disagreement prints BOTH numbers rather than picking
      # one (G1-3 "Escalation count" derivation).
      local status_model_upgraded=""
      if [[ -n "${STATUS_FILE:-}" && -f "${STATUS_FILE:-/nonexistent}" ]]; then
        status_model_upgraded=$(jq -r '.model_upgraded // empty' "$STATUS_FILE" 2>/dev/null)
      fi
      if [[ -n "$status_model_upgraded" ]]; then
        local status_saw_upgrade=0 cost_log_saw_upgrade=0
        [[ "$status_model_upgraded" == "1" ]] && status_saw_upgrade=1
        (( escalation_count > 0 )) && cost_log_saw_upgrade=1
        if (( status_saw_upgrade != cost_log_saw_upgrade )); then
          echo "- Escalation count: ${escalation_count} ladder move(s) (status.json model_upgraded=${status_model_upgraded} — disagreement, printing both)"
        else
          echo "- Escalation count: ${escalation_count} ladder move(s)"
        fi
      else
        echo "- Escalation count: ${escalation_count} ladder move(s)"
      fi

      if (( ${#final_model_us_order[@]} > 0 )); then
        local fm_line="" fm_us
        for fm_us in "${final_model_us_order[@]}"; do
          if [[ -n "$fm_line" ]]; then
            fm_line="${fm_line}, ${fm_us} = ${final_model_by_us[$fm_us]}"
          else
            fm_line="${fm_us} = ${final_model_by_us[$fm_us]}"
          fi
        done
        echo "- Final model per US: ${fm_line}"
      else
        echo "- Final model per US: (none — no attributed rows)"
      fi

      echo "- Total estimated tokens (raw): ${total_tokens} (source: estimated, tmux mode)"
      local unattributed=$(( raw_rows - attributed_rows ))
      if (( unattributed > 0 )); then
        echo "- (${unattributed} iteration(s) unattributed)"
      fi
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
# Leader-side mechanical pre-gate (Feature 1)
# =============================================================================
# Runs campaign-defined deterministic checks BEFORE any LLM verifier is
# dispatched. Convention: $DESK/plans/pregate-<slug>.sh — a plain shell script
# executed with `zsh <file>` from the campaign ROOT. Absent → true no-op
# (PREGATE_RAN=0, no logging, byte-identical behavior). Present → exit 0 = pass
# (proceed to normal LLM verification), non-zero = fail (leader short-circuits
# and redispatches the worker with the mechanical output as the fix contract).
#
# Iron Law compatibility: the pre-gate can ONLY early-FAIL. A pass simply
# proceeds to the unchanged full LLM verification — it never produces a pass
# verdict of its own.
#
# Soft timeout (default 300s, RLP_PREGATE_TIMEOUT) via the same in-process
# background-pid + watchdog pattern used by generate_sv_report; a timed-out gate
# is treated as a FAIL with "pregate timeout after Ns" in the fix contract.
#
# Sets globals for the caller: PREGATE_RAN (0|1), PREGATE_EXIT, PREGATE_DUR,
# PREGATE_OUTPUT (tail -40 of stdout+stderr), PREGATE_FILE (gate path).
run_pregate() {
  local iter="$1"
  local slug="${2:-$SLUG}"
  PREGATE_RAN=0; PREGATE_EXIT=0; PREGATE_DUR=0; PREGATE_OUTPUT=""; PREGATE_FILE=""

  local gate_file="$DESK/plans/pregate-${slug}.sh"
  [[ -f "$gate_file" ]] || return 0   # absent → no-op, no side effects, no logging

  PREGATE_RAN=1
  PREGATE_FILE="$gate_file"
  local timeout_secs="${RLP_PREGATE_TIMEOUT:-300}"
  [[ "$timeout_secs" == <-> ]] || timeout_secs=300

  local out_file="$LOGS_DIR/iter-$(printf '%03d' $iter).pregate-output.log"
  local timeout_flag_file="$LOGS_DIR/.pregate_timeout_${$}.tmp"
  rm -f "$timeout_flag_file" 2>/dev/null
  local t0
  t0=$(date +%s)

  # Run the gate from the campaign root. `exec zsh` makes the backgrounded pid
  # be the gate process itself (not a wrapper subshell), so the watchdog kill
  # actually reaches it. </dev/null so an inherited pane stdin can't block it.
  ( cd "$ROOT" && exec zsh "$gate_file" ) </dev/null > "$out_file" 2>&1 &
  local gate_pid=$!

  # Watchdog: after timeout_secs, flag + kill the gate if still alive. Its fds
  # are detached to /dev/null so the backgrounded sleep never holds the leader's
  # (or a test's captured) stdout pipe open past this function's return.
  local wd_pid
  (
    sleep "$timeout_secs"
    if kill -0 "$gate_pid" 2>/dev/null; then
      touch "$timeout_flag_file"
      kill "$gate_pid" 2>/dev/null
    fi
  ) </dev/null >/dev/null 2>&1 &
  wd_pid=$!

  wait "$gate_pid"; PREGATE_EXIT=$?
  kill "$wd_pid" 2>/dev/null
  wait "$wd_pid" 2>/dev/null
  PREGATE_DUR=$(( $(date +%s) - t0 ))

  local tail_out
  tail_out=$(tail -40 "$out_file" 2>/dev/null)

  if [[ -f "$timeout_flag_file" ]]; then
    rm -f "$timeout_flag_file" 2>/dev/null
    PREGATE_EXIT=124
    PREGATE_OUTPUT="pregate timeout after ${timeout_secs}s"$'\n'"$tail_out"
    return 1
  fi

  PREGATE_OUTPUT="$tail_out"
  (( PREGATE_EXIT == 0 )) && return 0
  return 1
}

# Shared counter/cap decision for BOTH pre-gate layers (layer 1 = static gate
# script, layer 2 = execution_steps replay). Updates the same-US pre-gate counter
# (NEVER touches the consecutive-failure circuit breaker) and returns:
#   - 0 (short-circuit): still under PREGATE_FAIL_CAP — caller writes the fix
#     contract, skips LLM verification, and redispatches the Worker.
#   - 1 (force): the same US has now failed the pre-gate PREGATE_FAIL_CAP times —
#     the counter is reset and the caller must run one full LLM verifier round
#     (whose verdict drives the CB as normal) instead of another short-circuit.
# Both layers feed the SAME counter, so a mix of layer-1 and layer-2 fails on one
# US still trips the cap at 3 combined.
_pregate_bump() {
  local us_id="${1:-ALL}"
  # Reset the streak when the in-flight US changes (per-US counter).
  if [[ "$us_id" != "$_PREGATE_FAIL_US" ]]; then
    PREGATE_FAILURES=0
    _PREGATE_FAIL_US="$us_id"
  fi
  (( PREGATE_FAILURES++ ))
  if (( PREGATE_FAILURES >= PREGATE_FAIL_CAP )); then
    PREGATE_FAILURES=0
    _PREGATE_FAIL_US=""
    return 1
  fi
  return 0
}

# Layer 1 fail: register + build the PRE-GATE FAILURE (mechanical) fix contract at
# iter-<N>.fix-contract.md. Returns 0 (short-circuit) or 1 (force verifier round).
# Reads PREGATE_FILE / PREGATE_EXIT / PREGATE_OUTPUT (set by run_pregate).
_pregate_register_fail() {
  local iter="$1" us_id="${2:-ALL}"
  _pregate_bump "$us_id" || return 1
  local pregate_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
  {
    echo "# Fix Contract (PRE-GATE FAILURE, iteration $iter)"
    echo ""
    echo "## PRE-GATE FAILURE (mechanical)"
    echo "The leader-side mechanical pre-gate rejected your work BEFORE LLM verification."
    echo "These are deterministic checks (compile / lint / file existence / test count)."
    echo "Fix them first — the pre-gate must exit 0 before any verifier runs."
    echo ""
    echo "- **Gate script**: ${PREGATE_FILE}"
    echo "- **Exit code**: ${PREGATE_EXIT}"
    echo ""
    echo "## Output (tail)"
    echo '```'
    echo "$PREGATE_OUTPUT"
    echo '```'
    echo ""
    echo "## Next Iteration Contract"
    echo "Make the pre-gate pass (exit 0), then continue the contracted work. Scope Lock: only changes that fix the failing checks above are in scope."
  } | atomic_write "$pregate_contract"
  return 0
}

# Layer 2 fail (execution_steps replay mismatch): register + build the PRE-GATE
# FAILURE (replay mismatch) fix contract. Returns 0 (short-circuit) or 1 (force).
# Reads PREGATE_REPLAY_STEP / _AC / _CMD / _CLAIMED / _ACTUAL / _OUTPUT (set by
# run_pregate_replay).
_pregate_register_fail_replay() {
  local iter="$1" us_id="${2:-ALL}"
  _pregate_bump "$us_id" || return 1
  local pregate_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
  {
    echo "# Fix Contract (PRE-GATE FAILURE, iteration $iter)"
    echo ""
    echo "## PRE-GATE FAILURE (replay mismatch)"
    echo "The leader RE-RAN a verification command you recorded in done-claim.json"
    echo "execution_steps and got a DIFFERENT exit code than you claimed. The claim"
    echo "does not reproduce. Fix the underlying work (or stop recording a command"
    echo "whose result you did not actually observe) — a claimed result that does not"
    echo "replay is a FAIL."
    echo ""
    echo "- **Step**: ${PREGATE_REPLAY_STEP}"
    echo "- **AC**: ${PREGATE_REPLAY_AC}"
    echo "- **Command**: \`${PREGATE_REPLAY_CMD}\`"
    echo "- **Claimed exit_code**: ${PREGATE_REPLAY_CLAIMED}"
    echo "- **Actual exit_code (leader replay)**: ${PREGATE_REPLAY_ACTUAL}"
    echo ""
    echo "## Output (tail)"
    echo '```'
    echo "$PREGATE_REPLAY_OUTPUT"
    echo '```'
    echo ""
    echo "## Next Iteration Contract"
    echo "Make the command above actually produce the claimed exit code, then continue. Scope Lock: only changes that fix this mismatch are in scope."
  } | atomic_write "$pregate_contract"
  return 0
}

# --- Layer 2: execution_steps replay ---
# Safe-command gate for replay. A command is eligible ONLY if it BEGINS with an
# allowlisted tool AND contains none of the dangerous denylist patterns. Both are
# documented single regex constants (zsh ERE via [[ =~ ]]).
_PREGATE_CMD_ALLOWLIST='^[[:space:]]*(npm|npx|pnpm|yarn|node|python3?|pytest|go|cargo|make|tsc|eslint|vitest|jest|playwright|zsh|bash|sh|jq|diff|grep|test)([[:space:]]|$)'
_PREGATE_CMD_DENYLIST='rm |git push|git commit|curl |wget |sudo |> /|>> /'
_pregate_cmd_is_safe() {
  local cmd="$1"
  [[ "$cmd" =~ $_PREGATE_CMD_ALLOWLIST ]] || return 1
  [[ "$cmd" =~ $_PREGATE_CMD_DENYLIST ]] && return 1
  return 0
}

# Run one replay command from the campaign root with a soft per-command timeout.
# Sets _PREGATE_CMD_TIMED_OUT (0|1) and returns the command's exit code (or the
# watchdog-kill code on timeout). Same background-pid + watchdog pattern as run_pregate.
_pregate_run_cmd_timed() {
  local cmd="$1" secs="$2" out_file="$3"
  _PREGATE_CMD_TIMED_OUT=0
  [[ "$secs" == <-> ]] || secs=120
  (( secs < 1 )) && secs=1
  local flag="$LOGS_DIR/.pregate_cmd_timeout_${$}.tmp"
  rm -f "$flag" 2>/dev/null
  ( cd "$ROOT" && exec zsh -c "$cmd" ) </dev/null > "$out_file" 2>&1 &
  local pid=$!
  (
    sleep "$secs"
    if kill -0 "$pid" 2>/dev/null; then touch "$flag"; kill "$pid" 2>/dev/null; fi
  ) </dev/null >/dev/null 2>&1 &
  local wd=$!
  wait "$pid"; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  if [[ -f "$flag" ]]; then rm -f "$flag" 2>/dev/null; _PREGATE_CMD_TIMED_OUT=1; fi
  return $rc
}

# Layer 2: replay verify-* commands recorded in done-claim.json execution_steps
# and compare each replayed exit code to the worker's CLAIMED exit_code (EQUALITY
# — a verify_red claiming exit 1 that replays to exit 1 is a MATCH, not a fail).
# NO new schema — uses the existing §1f step/ac_id/command/exit_code fields.
#
# Division of labor (governance §3a): replay only catches "the claimed command is
# false". Command OMISSION, insufficient tests, and tautological checks remain the
# LLM verifier's sufficiency/anti-gaming responsibility. The pre-gate never creates
# a pass; full LLM verification always runs after it passes.
#
# Absent done-claim, no execution_steps, or none eligible → silent no-op (one [GOV]
# line), NOT a fail — schema enforcement is the verifier's job. A dangerous or
# non-allowlisted command is SKIPPED (never executed), logged, and does not fail.
#
# Args: $1=iter  $2=overall_deadline_epoch (optional; whole-pregate RLP_PREGATE_TIMEOUT
# bound — 0/empty = per-command timeout only). Sets PREGATE_REPLAY_RAN (0|1),
# PREGATE_REPLAY_FAIL (0|1), and on fail PREGATE_REPLAY_STEP/_AC/_CMD/_CLAIMED/
# _ACTUAL/_OUTPUT. Returns 0 (pass or no-op) / 1 (mismatch → caller short-circuits).
run_pregate_replay() {
  local iter="$1" deadline="${2:-0}"
  PREGATE_REPLAY_RAN=0; PREGATE_REPLAY_FAIL=0; PREGATE_REPLAY_OUTPUT=""
  PREGATE_REPLAY_STEP=""; PREGATE_REPLAY_CMD=""; PREGATE_REPLAY_CLAIMED=""
  PREGATE_REPLAY_ACTUAL=""; PREGATE_REPLAY_AC=""
  [[ -f "$DONE_CLAIM_FILE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local count
  count=$(jq '(.execution_steps // []) | length' "$DONE_CLAIM_FILE" 2>/dev/null || echo 0)
  [[ "$count" == <-> ]] || count=0
  (( count == 0 )) && return 0

  local cmd_timeout="${RLP_PREGATE_CMD_TIMEOUT:-120}"
  [[ "$cmd_timeout" == <-> ]] || cmd_timeout=120

  local any_eligible=0 i
  for (( i = 0; i < count; i++ )); do
    local step cmd claimed ac
    step=$(jq -r ".execution_steps[$i].step // \"\"" "$DONE_CLAIM_FILE" 2>/dev/null)
    cmd=$(jq -r ".execution_steps[$i].command // \"\"" "$DONE_CLAIM_FILE" 2>/dev/null)
    claimed=$(jq -r ".execution_steps[$i].exit_code // \"\"" "$DONE_CLAIM_FILE" 2>/dev/null)
    ac=$(jq -r ".execution_steps[$i].ac_id // \"\"" "$DONE_CLAIM_FILE" 2>/dev/null)

    # Schema eligibility: verify* step with a non-null command.
    [[ "$step" == verify* ]] || continue
    [[ -n "$cmd" && "$cmd" != "null" ]] || continue
    # Claimed exit must be an integer to compare against (verify_red keeps its
    # own non-zero claim — equality handles it).
    [[ "$claimed" == <-> || "$claimed" == -<-> ]] || {
      log_debug "[GOV] iter=$iter phase=pregate_replay step=$step ac=$ac action=skip reason=no_claimed_exit"
      continue
    }
    # Safety eligibility: allowlist begin + denylist none. Skipped ≠ fail.
    if ! _pregate_cmd_is_safe "$cmd"; then
      log_debug "[GOV] iter=$iter phase=pregate_replay step=$step ac=$ac action=skip reason=unsafe_or_not_allowlisted"
      continue
    fi
    # Whole-pregate deadline (layer1+layer2 ≤ RLP_PREGATE_TIMEOUT).
    local eff_timeout=$cmd_timeout now remaining
    if (( deadline > 0 )); then
      now=$(date +%s); remaining=$(( deadline - now ))
      if (( remaining <= 0 )); then
        PREGATE_REPLAY_RAN=1; PREGATE_REPLAY_FAIL=1
        PREGATE_REPLAY_STEP="$step"; PREGATE_REPLAY_AC="$ac"; PREGATE_REPLAY_CMD="$cmd"
        PREGATE_REPLAY_CLAIMED="$claimed"; PREGATE_REPLAY_ACTUAL="timeout"
        PREGATE_REPLAY_OUTPUT="pre-gate overall timeout reached before replaying this step"
        log_debug "[GOV] iter=$iter phase=pregate_replay step=$step ac=$ac action=fail reason=overall_timeout"
        return 1
      fi
      (( remaining < eff_timeout )) && eff_timeout=$remaining
    fi

    any_eligible=1
    PREGATE_REPLAY_RAN=1
    local out_file="$LOGS_DIR/iter-$(printf '%03d' $iter).pregate-replay-${i}.log"
    local actual
    _pregate_run_cmd_timed "$cmd" "$eff_timeout" "$out_file"; actual=$?
    if (( _PREGATE_CMD_TIMED_OUT )); then
      PREGATE_REPLAY_FAIL=1
      PREGATE_REPLAY_STEP="$step"; PREGATE_REPLAY_AC="$ac"; PREGATE_REPLAY_CMD="$cmd"
      PREGATE_REPLAY_CLAIMED="$claimed"; PREGATE_REPLAY_ACTUAL="timeout (${eff_timeout}s)"
      PREGATE_REPLAY_OUTPUT="pregate replay command timeout after ${eff_timeout}s"$'\n'"$(tail -40 "$out_file" 2>/dev/null)"
      log_debug "[GOV] iter=$iter phase=pregate_replay step=$step ac=$ac claimed=$claimed actual=timeout action=fail"
      return 1
    fi
    log_debug "[GOV] iter=$iter phase=pregate_replay step=$step ac=$ac claimed=$claimed actual=$actual"
    if [[ "$actual" != "$claimed" ]]; then
      PREGATE_REPLAY_FAIL=1
      PREGATE_REPLAY_STEP="$step"; PREGATE_REPLAY_AC="$ac"; PREGATE_REPLAY_CMD="$cmd"
      PREGATE_REPLAY_CLAIMED="$claimed"; PREGATE_REPLAY_ACTUAL="$actual"
      PREGATE_REPLAY_OUTPUT="$(tail -40 "$out_file" 2>/dev/null)"
      return 1
    fi
  done

  if (( ! any_eligible )); then
    log_debug "[GOV] iter=$iter phase=pregate_replay eligible=0 action=noop"
    PREGATE_REPLAY_RAN=0
  fi
  return 0
}

# --- Layer 1.5: done-claim TDD-sequence lint (deterministic) ---
# Runs BETWEEN Layer 1 (static gate) and Layer 2 (replay). For a BUILD-mode
# done-claim (execution_steps contains a write_test step) it asserts that EACH
# acceptance criterion that appears — in any step's ac_id OR a `claims[]` entry
# ("AC3: ...") — has write_test → verify_red → implement → verify_green steps
# labeled with that AC id, IN THAT ORDER. A comma list ("AC1,AC2") counts for
# both; the bundle label "all" satisfies NONE of the four phases. This is the
# SINGLE SOURCE OF TRUTH shared with the verifier's Worker Process Audit and the
# worker-prompt format spec — a claim that passes here must not be re-failed by
# the LLM on step-sequence/label format grounds (governance §3a Layer 1.5).
#
# The jq predicate is byte-identical in intent to src/node/runner/done-claim-
# lint.mjs (shared-fixture parity: tests/test_doneclaim_lint.sh + the Node
# test-done-claim-lint drive the SAME fixtures). The claims-derived AC union is
# a DELIBERATE strengthening over the reference jq — it catches the degenerate
# claim that labels every step `all`.
#
# SKIP (proceed, return 0) cases set PREGATE_LINT_REASON: env RLP_DONECLAIM_LINT==0
# (disabled), jq absent (no-jq, fail-open like the sibling pre-gates), done-claim
# missing/unparseable (unparseable), execution_steps missing/not-array/empty
# (no-steps), no write_test step (not-build — confirmation/replay claims exempt).
#
# Sets: PREGATE_LINT_STATUS (skip|pass|fail), PREGATE_LINT_REASON (skip only),
# PREGATE_LINT_VIOLATIONS (compact JSON array of {ac,idx}; "[]" unless fail).
# Returns 0 (skip or pass → proceed) / 1 (fail → caller short-circuits).
run_pregate_doneclaim_lint() {
  PREGATE_LINT_STATUS="skip"; PREGATE_LINT_REASON=""; PREGATE_LINT_VIOLATIONS="[]"
  if [[ "${RLP_DONECLAIM_LINT:-}" == "0" ]]; then
    PREGATE_LINT_REASON="disabled"; return 0
  fi
  command -v jq >/dev/null 2>&1 || { PREGATE_LINT_REASON="no-jq"; return 0; }
  [[ -f "$DONE_CLAIM_FILE" ]] || { PREGATE_LINT_REASON="unparseable"; return 0; }
  # Unparseable JSON OR a top-level non-object (array/string/number) → skip
  # unparseable (parity with the Node predicate, which requires a plain object).
  jq -e 'type == "object"' "$DONE_CLAIM_FILE" >/dev/null 2>&1 || { PREGATE_LINT_REASON="unparseable"; return 0; }

  local steps_len
  steps_len=$(jq -r 'if (.execution_steps|type)=="array" then (.execution_steps|length) else -1 end' "$DONE_CLAIM_FILE" 2>/dev/null)
  [[ "$steps_len" == <-> ]] || steps_len=-1
  (( steps_len > 0 )) || { PREGATE_LINT_REASON="no-steps"; return 0; }

  local has_wt
  has_wt=$(jq -r 'any(.execution_steps[]; .step == "write_test")' "$DONE_CLAIM_FILE" 2>/dev/null)
  [[ "$has_wt" == "true" ]] || { PREGATE_LINT_REASON="not-build"; return 0; }

  local violations
  violations=$(jq -c '
    # Type-coercion guards (parity with the Node predicate): a non-string ac_id
    # contributes NO ACs; claims is honored ONLY when an array, and only its
    # string elements count. Keeping these INSIDE the program means a malformed
    # sibling field can never error jq and silently mask real step violations.
    def acs: ((.ac_id // "") | (if type == "string" then . else "" end) | split(",") | map(gsub("\\s+";"")) | map(select(. != "" and . != "all")));
    [.execution_steps | to_entries[] | {i: .key, step: .value.step, a: (.value | acs)}] as $S
    | (([$S[].a[]]
        + [(.claims | if type == "array" then map(select(type == "string")) else [] end)[]
            | select(test("^\\s*AC[0-9]+\\s*:"))
            | (capture("^\\s*(?<ac>AC[0-9]+)\\s*:") | .ac)])
       | unique) as $ACS
    | [ $ACS[] as $ac
        | (["write_test","verify_red","implement","verify_green"]
           | map(. as $p | ([$S[] | select(.step == $p and (.a | index($ac)))] | (.[0].i // -1)))) as $idx
        | select(($idx | min) < 0 or ($idx != ($idx | sort)))
        | {ac: $ac, idx: $idx} ]
  ' "$DONE_CLAIM_FILE" 2>/dev/null)
  [[ -n "$violations" ]] || violations="[]"
  PREGATE_LINT_VIOLATIONS="$violations"

  if [[ "$violations" == "[]" ]]; then
    PREGATE_LINT_STATUS="pass"; return 0
  fi
  PREGATE_LINT_STATUS="fail"; return 1
}

# Layer 1.5 fail: register + build the PRE-GATE FAILURE (done-claim format lint)
# fix contract at iter-<N>.fix-contract.md. Mirrors _pregate_register_fail_replay's
# shape and shares the SAME PREGATE_FAIL_CAP counter (never consecutive_failures).
# Returns 0 (short-circuit) or 1 (force verifier round at cap). Reads
# PREGATE_LINT_VIOLATIONS (set by run_pregate_doneclaim_lint).
_pregate_register_fail_doneclaim_lint() {
  local iter="$1" us_id="${2:-ALL}"
  _pregate_bump "$us_id" || return 1
  local pregate_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
  {
    echo "# Fix Contract (PRE-GATE FAILURE, iteration $iter)"
    echo ""
    echo "## PRE-GATE FAILURE (done-claim format lint)"
    echo "- rule: build-mode done-claim must contain write_test → verify_red → implement → verify_green for EACH acceptance criterion, each step labeled with that AC id (comma lists OK; the bundle label \"all\" does NOT satisfy these 4 phases)"
    echo "- idx column order: [write_test, verify_red, implement, verify_green]; -1 = step missing for that AC; non-increasing = steps out of order"
    echo "- violations:"
    echo "$PREGATE_LINT_VIOLATIONS" | jq -r '.[] | "  - \(.ac): idx=\(.idx | tojson)"' 2>/dev/null \
      || echo "  $PREGATE_LINT_VIOLATIONS"
    echo ""
    echo "## Next Iteration Contract"
    echo "Fix ONLY the done-claim execution_steps format for the ACs listed above (add the missing per-AC labeled steps / correct the order), then resubmit the done-claim. Do not re-implement the deliverable."
  } | atomic_write "$pregate_contract"
  return 0
}

# =============================================================================
# US-001: leader-side done-claim commit-integrity oracle
# =============================================================================
# The leader accepts a Worker done-claim that asserts a `commit` step with
# exit_code 0. Before dispatching the (probabilistic) verifier, the leader
# adjudicates that ground truth with git (Principle 1). This is the zsh
# production predicate; src/node/shared/commit-oracle.mjs is the pure-function
# mirror (oracle) — a shared-fixture parity matrix drives both (AC1.6).

# _commit_oracle_tracked_dirty(): worker-attributable tracked-dirty files.
# Mirrors Bug #8 Gate 3 semantics EXACTLY (run_ralph_desk.zsh): `git diff
# --name-only <_git_dirty_base>` of TRACKED files, MINUS the
# CAMPAIGN_PREEXISTING_DIRTY set and MINUS untracked cruft. NOT `git status
# --porcelain` (which counts untracked and would false-fail). Echoes one
# worker-dirty file per line (empty when the tracked tree is clean).
# Globals read: ROOT, CAMPAIGN_PREEXISTING_DIRTY.
# Returns: 0 (ok — clean tree or worker-dirty list on stdout) / 2 (GIT-FC infra:
# the git snapshot itself failed — a git error must NEVER be read as a clean
# tree, which would let the oracle corroborate a claim whose tree is dirty).
_commit_oracle_tracked_dirty() {
  local dirty
  dirty=$(_git_snapshot -C "$ROOT" diff --name-only "$(_git_dirty_base)") || return 2
  [[ -n "$dirty" ]] || return 0
  comm -23 \
    <(printf '%s\n' "$dirty" | sort -u) \
    <(printf '%s\n' "${CAMPAIGN_PREEXISTING_DIRTY:-}" | sort -u) \
    | grep -v '^[[:space:]]*$'
  # GIT-FC (IMP-09): pin rc 0 on the success path. The trailing `grep -v` exits 1
  # when the worker-file list is empty after the preexisting exclusion (a NORMAL
  # clean outcome); the old caller captured stdout and ignored rc, but the rc-2
  # infra contract now inspects rc, so grep's empty-match must not masquerade as a
  # git failure. Only the `_git_snapshot` failure above returns non-zero (2).
  return 0
}

# _commit_oracle_check(): the commit-integrity predicate (sourceable + invokable
# with fixtures). Fires ONLY when the done-claim asserts a successful commit (an
# execution_steps entry step=="commit" exit_code 0). See commit-oracle.mjs for
# the full contract incl. the commit_sha transition rule.
#
# Args: $1=done_claim_file  $2=iter_start_head (HEAD sha at iteration start, ''
#       when the repo had no commits then). Globals read: ROOT,
#       CAMPAIGN_PREEXISTING_DIRTY. Sets ORACLE_ASSERTED (0|1), ORACLE_REASON,
#       ORACLE_DETAIL, ORACLE_CLAIMED_SHA.
# Returns: 0 (pass OR no-op → proceed) / 1 (mismatch → caller routes to fix
#   loop) / 2 (GIT-FC infra — git facts unavailable; caller forces a full
#   verifier round WITHOUT bumping the oracle fail counter: an error can never
#   corroborate a commit claim). Sets ORACLE_REASON=git_facts_unavailable on rc 2.
_commit_oracle_check() {
  local dc_file="$1" iter_start_head="${2:-}"
  ORACLE_ASSERTED=0; ORACLE_REASON=""; ORACLE_DETAIL=""; ORACLE_CLAIMED_SHA=""

  [[ -f "$dc_file" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  # Locate the commit assertion: FIRST execution_steps entry step=="commit" with
  # exit_code 0 (numeric 0 or "0" tolerated via tostring). Empty index → no-op.
  local commit_idx
  commit_idx=$(jq -r '
    ((.execution_steps // []) | to_entries
      | map(select(.value.step == "commit" and ((.value.exit_code|tostring) == "0")))
      | .[0].key) // ""' "$dc_file" 2>/dev/null)
  [[ -n "$commit_idx" ]] || return 0

  ORACLE_ASSERTED=1
  local claimed_sha
  claimed_sha=$(jq -r ".execution_steps[$commit_idx].commit_sha // \"\"" "$dc_file" 2>/dev/null)
  [[ "$claimed_sha" == "null" ]] && claimed_sha=""
  ORACLE_CLAIMED_SHA="$claimed_sha"

  local current_head
  current_head=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
  # HEAD advanced beyond the per-ITERATION start snapshot (not the campaign
  # baseline — that false-accepts "clean tree + HEAD advanced by an earlier
  # iteration + lie THIS iteration"). Non-empty current HEAD that differs from the
  # snapshot proves this iteration committed, incl. the first-commit case.
  local head_advanced=0
  [[ -n "$current_head" && "$current_head" != "$iter_start_head" ]] && head_advanced=1

  # GIT-FC (IMP-09): gather the tracked-dirty set rc-aware. A git ERROR must not
  # collapse to an empty (clean) list — both branches below would then read a
  # corrupt "clean" tree. Route git failure to rc 2 (infra) BEFORE adjudicating.
  local _dirty_out
  if ! _dirty_out=$(_commit_oracle_tracked_dirty); then
    ORACLE_REASON="git_facts_unavailable"
    ORACLE_DETAIL="commit-oracle git snapshot failed (git error) — oracle cannot adjudicate; forcing full verifier round."
    return 2
  fi
  local -a dirty_files
  dirty_files=("${(@f)_dirty_out}")
  dirty_files=(${dirty_files:#})   # prune the lone empty element from empty output
  local tracked_dirty=0
  (( ${#dirty_files} > 0 )) && tracked_dirty=1

  local _s_start="${iter_start_head[1,10]:-none}" _s_head="${current_head[1,10]:-none}"
  local _s_sha="${claimed_sha[1,10]}"

  if [[ -z "$claimed_sha" ]]; then
    # Transition rule (AC1.1): commit-claim WITHOUT commit_sha is unverifiable →
    # mismatch ONLY if HEAD did not advance (tracked-dirty deliberately NOT
    # asserted with no SHA to anchor the claim — mirrors commit-oracle.mjs).
    (( head_advanced )) && return 0
    ORACLE_REASON="commit_claim_no_sha_no_advance"
    ORACLE_DETAIL="done-claim asserts a successful commit but carries no commit_sha, and HEAD did not advance beyond the iteration-start snapshot (${_s_start:-none}). The claimed commit did not land."
    return 1
  fi

  # Full predicate: A (advance + resolves + reachable) AND B (tracked clean),
  # asserted INDEPENDENTLY so the fix contract names the exact violation.
  local -a reasons details
  if (( ! head_advanced )); then
    reasons+=("head_not_advanced")
    details+=("HEAD did not advance beyond the iteration-start snapshot (${_s_start:-none}); current HEAD ${_s_head:-none}.")
  fi
  if ! git -C "$ROOT" cat-file -e "${claimed_sha}^{commit}" 2>/dev/null; then
    reasons+=("claimed_sha_absent")
    details+=("claimed commit ${_s_sha} does not resolve (git cat-file -e failed).")
  elif ! git -C "$ROOT" merge-base --is-ancestor "$claimed_sha" HEAD 2>/dev/null; then
    reasons+=("claimed_sha_unreachable")
    details+=("claimed commit ${_s_sha} is not reachable from HEAD.")
  fi
  if (( tracked_dirty )); then
    local _first5
    _first5=$(printf '%s\n' "${dirty_files[@]}" | head -n 5 | tr '\n' ',' | sed 's/,$//')
    reasons+=("tracked_tree_dirty")
    details+=("tracked files remain uncommitted after the claimed commit: ${_first5}.")
  fi

  (( ${#reasons} == 0 )) && return 0
  ORACLE_REASON="${(j:+:)reasons}"
  ORACLE_DETAIL="${(j: :)details}"
  return 1
}

# _oracle_bump(): same-US commit-oracle fail counter (SEPARATE from the
# consecutive-failure circuit breaker AND from PREGATE_FAILURES). Returns 0
# (short-circuit + redispatch) while under ORACLE_FAIL_CAP; 1 (force one full LLM
# verifier round) at the cap — the safety valve for a false-positive oracle,
# whose verdict then drives the CB as normal.
_oracle_bump() {
  local us_id="${1:-ALL}"
  if [[ "$us_id" != "$_ORACLE_FAIL_US" ]]; then
    ORACLE_FAILURES=0
    _ORACLE_FAIL_US="$us_id"
  fi
  (( ORACLE_FAILURES++ ))
  if (( ORACLE_FAILURES >= ORACLE_FAIL_CAP )); then
    ORACLE_FAILURES=0
    _ORACLE_FAIL_US=""
    return 1
  fi
  return 0
}

# _oracle_register_fail(): commit-oracle fail → machine-generated COMMIT-INTEGRITY
# fix contract (AC1.4). Rendered through the SAME US-003 jq fallback chain the
# verify-fail fix contract uses (.id // .criterion // .criterion_id // "?" +
# .description // .summary // "no description"), fed a synthetic verdict naming
# the specific mismatch — never a free-text verifier finding. Returns 0
# (short-circuit) / 1 (force verifier round). Reads ORACLE_REASON / ORACLE_DETAIL
# (set by _commit_oracle_check).
_oracle_register_fail() {
  local iter="$1" us_id="${2:-ALL}"
  _oracle_bump "$us_id" || return 1
  local oracle_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
  local _verdict
  _verdict=$(jq -n \
    --arg detail "$ORACLE_DETAIL" \
    --arg reason "$ORACLE_REASON" \
    '{verdict:"fail",
      summary:("Leader commit-integrity oracle: " + $reason),
      issues:[{severity:"critical", id:"COMMIT-INTEGRITY", description:$detail}]}' 2>/dev/null)
  {
    echo "# Fix Contract (COMMIT-INTEGRITY FAILURE, iteration $iter)"
    echo ""
    echo "## COMMIT-INTEGRITY FAILURE (leader-adjudicated git ground truth)"
    echo "Your done-claim asserted a successful \`commit\` step, but the leader"
    echo "verified against git and the claim does not hold. A commit that did not"
    echo "actually land (or that left tracked files uncommitted) is an IL-1"
    echo "evidence breach — fix it before any verifier runs."
    echo ""
    echo "## Issues (leader commit-integrity oracle)"
    printf '%s\n' "$_verdict" | jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.id // .criterion // .criterion_id // "?"): \(.description // .summary // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' 2>/dev/null || echo "- (no structured issues)"
    echo ""
    echo "## Next Iteration Contract"
    echo "Actually create the commit (git add + git commit) so HEAD advances and the tracked tree is clean, and record the resulting commit SHA in your done-claim's commit step (commit_sha). Scope Lock: only changes that make the commit real are in scope."
  } | atomic_write "$oracle_contract"
  return 0
}

# =============================================================================
# Parallel consensus evidence isolation (Feature 2)
# =============================================================================
# When two verifiers run concurrently, a DB-mutating or E2E rerun on one side
# can false-FAIL the other (it sees in-flight fixture rows during a "no residue"
# check). The lock below serializes those reruns. Static/unit/file checks stay
# parallel. mkdir is atomic across processes, so it is a portable mutex with no
# flock dependency. Used by the injected prompt contract AND directly unit-tested.
#
# Usage:  _evidence_lock acquire <lockdir> [wait_secs]   → 0 acquired, 1 timed out
#         _evidence_lock release <lockdir>               → always 0
_evidence_lock() {
  local op="$1" lockdir="$2" wait_secs="${3:-120}"
  [[ "$wait_secs" == <-> ]] || wait_secs=120
  case "$op" in
    acquire)
      local waited=0
      mkdir -p "${lockdir:h}" 2>/dev/null
      while ! mkdir "$lockdir" 2>/dev/null; do
        (( waited >= wait_secs )) && return 1
        sleep 1
        (( waited++ ))
      done
      return 0
      ;;
    release)
      rmdir "$lockdir" 2>/dev/null
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

# Single source of truth for the evidence-isolation contract injected into BOTH
# parallel verifier prompts. Emits to stdout (the caller pipes it into the prompt).
_emit_evidence_lock_contract() {
  local lockdir="$1"
  echo ""
  echo "---"
  echo "## EVIDENCE ISOLATION (parallel consensus — mandatory)"
  echo "Another verifier is checking the SAME work at the SAME time. Concurrent"
  echo "DB-mutating or E2E reruns can make each other falsely FAIL (one side sees"
  echo "the other's in-flight fixture rows during a 'no residue' check)."
  echo ""
  echo "BEFORE any DB-mutating or end-to-end rerun, acquire this lock; release it"
  echo "the moment that step finishes:"
  echo '```sh'
  echo "LOCK=\"$lockdir\""
  echo "# acquire (waits up to 120s for the other verifier to finish its mutation window)"
  echo "waited=0; until mkdir \"\$LOCK\" 2>/dev/null; do [ \$waited -ge 120 ] && break; sleep 1; waited=\$((waited+1)); done"
  echo "#   ... run your DB-mutating / E2E step here ..."
  echo "rmdir \"\$LOCK\" 2>/dev/null   # release"
  echo '```'
  echo "Static analysis, unit tests, file-existence and read-only checks do NOT"
  echo "need the lock — run those freely in parallel. Do not hold the lock longer"
  echo "than a single mutating step."
}

# =============================================================================
# Campaign-scope waivers (US-002) — fail-closed pre-existing-baseline waiver
# =============================================================================
#
# CAPTURE RECIPES (operator, out-of-band — a worker cannot forge either):
#   1. Baseline artifact — PROVE a finding predates the campaign. Run the gate,
#      save its output as the artifact, hash it, paste the hash into the waiver:
#        <gate> --json > .rlp-desk/plans/baseline/<gate>.json
#        # minimal schema: { "gate": "<gate>", "captured_at": "<iso8601>",
#        #   "findings": [ { "finding_id": "<id>", "severity": "<sev>", ... } ] }
#        shasum -a 256 .rlp-desk/plans/baseline/<gate>.json   # → baseline_artifact_sha256
#   2. Authorization — bind waivers.json to THIS (re)start out-of-band:
#        shasum -a 256 .rlp-desk/plans/waivers.json           # → --waivers-sha256 <hash>
#
# load_campaign_waivers(): parse + validate .rlp-desk/plans/waivers.json. FAIL
# CLOSED — a waiver is honored ONLY with (a) a well-formed schema (all 7 fields
# non-empty strings), (b) campaign_slug == the running slug, (c) an existing
# baseline artifact whose recomputed sha256 equals baseline_artifact_sha256,
# and (d) finding_id present in that artifact's findings[] for the gate. There
# is NO assertion fallback and NO commit-ancestry check. Authorization is
# out-of-band: RLP_WAIVERS_SHA256 must equal the file's actual sha256 or EVERY
# waiver is rejected unauthorized_hash_change. Byte-for-byte the same decision
# as src/node/shared/waivers.mjs (validateWaivers); a shared fixture set drives
# both. Called at EXACTLY two points (AC2.5): fresh campaign entry and the Bug
# #10 operator-recovery resume.
#
# Args: $1=waivers_path $2=running_slug $3=expected_sha ($RLP_WAIVERS_SHA256)
#       $4=root_dir (baseline_artifact_path resolves against it when relative).
# Sets: WAIVERS_HONORED_LINES (array "id|gate|finding_id|reason"),
#       WAIVER_REJECTION_SUMMARY (string; folded into status.json block reason),
#       WAIVERS_AUTHORIZED_SHA (rotated to actual on authorized match — AC2.4b).
# Enum: artifact_missing sha256_mismatch finding_not_in_artifact slug_mismatch
#       malformed_schema unauthorized_hash_change.
load_campaign_waivers() {
  local waivers_path="$1" running_slug="$2" expected_sha="${3:-}" root_dir="${4:-$ROOT}"
  WAIVERS_HONORED_LINES=(); WAIVER_REJECTION_SUMMARY=""

  # AC2.4a: absent file → zero waivers, --waivers-sha256 unnecessary.
  [[ -f "$waivers_path" ]] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    log "  [waiver] jq unavailable — cannot validate waivers.json; proceeding fail-closed (zero waivers)."
    return 0
  fi

  local actual_sha
  actual_sha=$(shasum -a 256 "$waivers_path" 2>/dev/null | awk '{print $1}')

  # Parse the array. Malformed JSON / non-array → one file-level rejection,
  # zero honored (AC2.1 fail-closed). Mirrors validateWaivers' parse gate.
  local count
  count=$(jq 'if type=="array" then length else -1 end' "$waivers_path" 2>/dev/null)
  if [[ -z "$count" || "$count" == "-1" ]]; then
    _waiver_reject "(file)" "malformed_schema" "waivers.json is not a JSON array or is invalid JSON"
    return 0
  fi

  # AC2.4 authorization gate (out-of-band hash). Present + (flag absent OR
  # mismatch) → EVERY waiver rejected unauthorized_hash_change, per-id (loud).
  if [[ -z "$expected_sha" || "$expected_sha" != "$actual_sha" ]]; then
    local _detail
    if [[ -z "$expected_sha" ]]; then
      _detail="waivers.json present but no --waivers-sha256 authorization supplied (file sha256 ${actual_sha[1,12]})"
    else
      _detail="--waivers-sha256 ${expected_sha[1,12]} does not match waivers.json actual sha256 ${actual_sha[1,12]}"
    fi
    local i wid
    for (( i=0; i<count; i++ )); do
      wid=$(jq -r ".[$i].id // \"\"" "$waivers_path" 2>/dev/null)
      [[ -n "$wid" && "$wid" != "null" ]] || wid="#$i"
      _waiver_reject "$wid" "unauthorized_hash_change" "$_detail"
    done
    return 0
  fi

  # Authorized — rotate the authorized snapshot (AC2.4b).
  WAIVERS_AUTHORIZED_SHA="$actual_sha"
  log_debug "[GOV] phase=waivers action=authorized sha=${actual_sha[1,12]} count=$count"

  local i wid slug gate fid apath asha reason _ok resolved art_sha _present rest
  for (( i=0; i<count; i++ )); do
    wid=$(jq -r ".[$i].id // \"\"" "$waivers_path" 2>/dev/null)
    [[ -n "$wid" && "$wid" != "null" ]] || wid="#$i"

    # Schema: all 7 required fields present as non-empty strings.
    _ok=$(jq -r "
      .[$i] as \$w
      | ([\"id\",\"campaign_slug\",\"gate\",\"finding_id\",\"baseline_artifact_path\",\"baseline_artifact_sha256\",\"reason\"]
         | map((\$w[.]? | type) == \"string\" and ((\$w[.]? | length) > 0)) | all)" "$waivers_path" 2>/dev/null)
    if [[ "$_ok" != "true" ]]; then
      _waiver_reject "$wid" "malformed_schema" "missing or non-string required field(s)"
      continue
    fi

    slug=$(jq -r ".[$i].campaign_slug" "$waivers_path" 2>/dev/null)
    gate=$(jq -r ".[$i].gate" "$waivers_path" 2>/dev/null)
    fid=$(jq -r ".[$i].finding_id" "$waivers_path" 2>/dev/null)
    apath=$(jq -r ".[$i].baseline_artifact_path" "$waivers_path" 2>/dev/null)
    asha=$(jq -r ".[$i].baseline_artifact_sha256" "$waivers_path" 2>/dev/null)
    reason=$(jq -r ".[$i].reason" "$waivers_path" 2>/dev/null)

    # Slug binding (AC2.1).
    if [[ "$slug" != "$running_slug" ]]; then
      _waiver_reject "$wid" "slug_mismatch" "campaign_slug \"$slug\" does not match running slug \"$running_slug\""
      continue
    fi

    # Artifact existence — resolve relative paths against root_dir.
    resolved="$apath"
    [[ "$apath" = /* ]] || resolved="$root_dir/$apath"
    if [[ ! -f "$resolved" ]]; then
      _waiver_reject "$wid" "artifact_missing" "baseline artifact not found: $apath"
      continue
    fi

    # Immutability — recomputed sha256 must equal the recorded hash.
    art_sha=$(shasum -a 256 "$resolved" 2>/dev/null | awk '{print $1}')
    if [[ "$art_sha" != "$asha" ]]; then
      _waiver_reject "$wid" "sha256_mismatch" "baseline artifact sha256 ${art_sha[1,12]} != recorded ${asha[1,12]} (tampered or wrong file)"
      continue
    fi

    # Finding identity on gate + finding_id (AC2.2c). Artifact's own gate (when
    # it records one) must match, AND finding_id must be in findings[].
    _present=$(jq -r --arg g "$gate" --arg fid "$fid" '
      ((.gate == null) or (.gate == $g)) and ((.findings // []) | any(.finding_id == $fid))' "$resolved" 2>/dev/null)
    if [[ "$_present" != "true" ]]; then
      _waiver_reject "$wid" "finding_not_in_artifact" "finding_id \"$fid\" not present in baseline artifact for gate \"$gate\""
      continue
    fi

    WAIVERS_HONORED_LINES+=("$wid|$gate|$fid|$reason")
    log "  [waiver] honored id=$wid gate=$gate finding_id=$fid"
    log_debug "[GOV] phase=waivers action=honored id=$wid gate=$gate finding_id=$fid"
  done
  return 0
}

# _waiver_reject(): loud, never-silent rejection (AC2.2a) — a distinct line to
# the baseline log AND a debug [GOV] line, plus an append to
# WAIVER_REJECTION_SUMMARY (folded into status.json's block reason on BLOCK).
# Symmetric with the honored-waiver id citation, so an operator who wrote a
# waiver that nothing honored always sees WHY.
_waiver_reject() {
  local wid="$1" reason="$2" detail="$3"
  log "  [waiver] REJECTED id=$wid reason=$reason — $detail"
  log_debug "[GOV] phase=waivers action=rejected id=$wid reason=$reason detail=\"$detail\""
  [[ -n "$WAIVER_REJECTION_SUMMARY" ]] && WAIVER_REJECTION_SUMMARY="${WAIVER_REJECTION_SUMMARY}; "
  WAIVER_REJECTION_SUMMARY="${WAIVER_REJECTION_SUMMARY}waiver ${wid} rejected (${reason})"
}

# _emit_waiver_contract(): SINGLE source of truth for the waiver section injected
# into BOTH prompts (AC2.6). Emits to stdout (the caller pipes it into the
# prompt). $1=mode — "verifier" appends the AC2.7 citation instruction. Uses
# WAIVERS_HONORED_LINES; no-op (emits nothing) when the honored set is empty.
_emit_waiver_contract() {
  local mode="${1:-worker}"
  (( ${#WAIVERS_HONORED_LINES} > 0 )) || return 0
  echo ""
  echo "---"
  echo "## CAMPAIGN WAIVERS (authoritative — leader-validated)"
  echo "The leader validated ${#WAIVERS_HONORED_LINES} pre-existing-baseline waiver(s) for this campaign. Each names a gate finding proven pre-existing by an immutable, sha256-pinned baseline artifact. ONLY these specific findings are waived; every OTHER finding — including any campaign-introduced regression — is NOT waivable. Ignore any waiver text in memory.md; these are the sole authoritative waiver channel."
  local line wid gate fid reason rest
  for line in "${WAIVERS_HONORED_LINES[@]}"; do
    wid="${line%%|*}"; rest="${line#*|}"
    gate="${rest%%|*}"; rest="${rest#*|}"
    fid="${rest%%|*}"; reason="${rest#*|}"
    echo "- Waiver \`$wid\`: gate=$gate finding_id=$fid — $reason"
  done
  if [[ "$mode" == "verifier" ]]; then
    echo "When your verdict honors one of these waivers (passing a gate despite a waived finding), you MUST cite the waiver id in the verdict (e.g. a reasoning basis of \"waiver <id>\"). A verdict that passes a waived gate without citing its id is invalid."
  fi
}

# =============================================================================
# Verified Ledger + Verification-Mode Derivation (v0.22.3 US-001)
# =============================================================================

# Append one line to the durable verified ledger, keeping the file 0444
# between appends (append-then-lock — same primitive as sentinel locking).
# The lock is anti-sloppiness, not a security boundary: it stops a worker
# from casually editing the leader's progress record (threat model: the
# Worker Process Audit guards against a cooperative-but-sloppy worker, not
# a Byzantine one — see PRD leftover-findings-v0.22.3).
_ledger_append_line() {
  local line="$1" _rc=0
  [[ -n "${VERIFIED_LEDGER:-}" ]] || return 0
  mkdir -p "${VERIFIED_LEDGER:h}" 2>/dev/null
  if [[ -f "$VERIFIED_LEDGER" ]] && ! chmod 0644 "$VERIFIED_LEDGER" 2>/dev/null; then
    log_error "verified ledger unlock failed ($VERIFIED_LEDGER) — append aborted"
    return 1
  fi
  # early-review P2-6: relock ALWAYS runs (even when the append itself
  # fails), so an interruption cannot leave the ledger writable; append
  # failure is loud and propagated.
  {
    print -r -- "$line" >> "$VERIFIED_LEDGER" || _rc=1
  } always {
    chmod 0444 "$VERIFIED_LEDGER" 2>/dev/null       || log_warn "verified ledger relock failed ($VERIFIED_LEDGER)"
  }
  if (( _rc )); then
    log_error "verified ledger append FAILED ($VERIFIED_LEDGER) — progress record lost for: $line"
  fi
  return $_rc
}

# F-14 (moved from run_ralph_desk.zsh, extended): append a verified-pass US
# to the durable ledger. Records the current HEAD SHA so a later restart can
# prove "nothing changed since this was verified" (the confirmation-mode
# anchor). Skips ALL/empty; append-only, readers dedup.
# _ledger_prd_hash: content hash of the PRD the credit was earned against.
# The PRD lives under the gitignored runtime dir, so the tree-clean check
# cannot see PRD edits — binding each ledger entry to the PRD content closes
# the "same US ids, different plan" hole (early-review P1-2). git hash-object
# needs no object database, so this works in any toy repo.
_ledger_prd_hash() {
  [[ -n "${PRD_FILE:-}" && -f "${PRD_FILE:-}" ]] || { echo ""; return 0; }
  git hash-object "$PRD_FILE" 2>/dev/null || echo ""
}

_append_verified_ledger() {
  local us="$1"
  [[ -z "$us" || "$us" == "ALL" ]] && return 0
  local sha
  sha=$(git -C "${ROOT:-$PWD}" rev-parse HEAD 2>/dev/null || echo "")
  _ledger_append_line "$(printf '{"us_id":"%s","iter":%s,"verified_at":"%s","commit":"%s","prd":"%s"}' \
    "$us" "${ITERATION:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "$(_ledger_prd_hash)")"
}

# ALL completion record: written ONLY on the leader-gated COMPLETE path
# (batch and final-ALL campaigns never take the per-US append, so without
# this the ledger stays empty and a resume could never prove completion).
# coverage_csv: comma-separated US ids that this completion covers.
_append_verified_ledger_all() {
  local coverage_csv="$1"
  local sha cov_json
  sha=$(git -C "${ROOT:-$PWD}" rev-parse HEAD 2>/dev/null || echo "")
  cov_json=$(jq -nc --arg c "$coverage_csv" '$c | split(",") | map(select(test("^US-[0-9]+$")))' 2>/dev/null)
  [[ -n "$cov_json" && "$cov_json" != "[]" ]] || return 0
  _ledger_append_line "$(printf '{"us_id":"ALL","iter":%s,"verified_at":"%s","commit":"%s","prd":"%s","coverage":%s}' \
    "${ITERATION:-0}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$sha" "$(_ledger_prd_hash)" "$cov_json")"
}

# Full PRD US set via the anchored extractor (### US-NNN:), sorted unique.
_prd_us_set() {
  grep -oE '^### US-[0-9]+' "$1" 2>/dev/null | sed 's/^### //' | sort -u
}

# derive_verification_mode <ledger> <prd> <root>
# Prints "<mode>|<basis>" where mode is confirmation|build. FAIL-CLOSED:
# every missing/malformed anchor yields build (the strict TDD contract).
#
# confirmation iff ALL of:
#   (a) the ledger's newest valid entry — a per-US line whose sibling lines
#       cover every PRD US, or an ALL record whose coverage EQUALS the PRD
#       US set — carries a commit SHA;
#   (b) that SHA resolves in this repo AND `git diff --quiet <sha> HEAD`
#       (no tracked content changed since the verified state — F-8/D-16
#       auto-commits demote to build);
#   (c) the tracked working tree is clean (--untracked-files=no).
# The derivation reads ONLY leader-durable state (ledger + git) — strings in
# done-claim/iter-signal never participate (anti-gaming single channel).
derive_verification_mode() {
  local ledger="$1" prd="$2" root="$3"
  [[ -f "$ledger" && -f "$prd" ]] || { print -r -- "build|missing ledger or PRD"; return 0; }
  local prd_us
  prd_us=$(_prd_us_set "$prd")
  [[ -n "$prd_us" ]] || { print -r -- "build|no US markers in PRD"; return 0; }
  # early-review P2-5: judge the newest RAW nonempty line — a malformed
  # trailing entry must fail closed, not silently yield to an older valid one.
  # final-review P2-1: STRICT parse — jq must exit 0 AND yield exactly one
  # object (valid-JSON-plus-garbage or concatenated docs are malformed).
  local newest_raw newest
  newest_raw=$(grep -v '^[[:space:]]*$' "$ledger" 2>/dev/null | tail -1)
  [[ -n "$newest_raw" ]] || { print -r -- "build|empty ledger"; return 0; }
  if ! print -r -- "$newest_raw" | jq -e 'type=="object"' >/dev/null 2>&1; then
    print -r -- "build|newest ledger line is malformed"; return 0
  fi
  newest=$(print -r -- "$newest_raw" | jq -c '.' 2>/dev/null)
  if [[ -z "$newest" || $(print -r -- "$newest_raw" | jq -c '.' 2>/dev/null | grep -c '') -ne 1 ]]; then
    print -r -- "build|newest ledger line is malformed"; return 0
  fi
  local sha us covered
  sha=$(print -r -- "$newest" | jq -r '.commit // empty' 2>/dev/null)
  us=$(print -r -- "$newest" | jq -r '.us_id // empty' 2>/dev/null)
  [[ -n "$sha" ]] || { print -r -- "build|newest ledger entry has no commit anchor"; return 0; }
  # early-review P1-2: the credit must bind to THIS PRD's content — the PRD is
  # gitignored, so the tree-clean check below cannot see plan edits.
  local rec_prd cur_prd
  rec_prd=$(print -r -- "$newest" | jq -r '.prd // empty' 2>/dev/null)
  cur_prd=$(git hash-object "$prd" 2>/dev/null || echo "")
  if [[ -z "$rec_prd" || -z "$cur_prd" || "$rec_prd" != "$cur_prd" ]]; then
    print -r -- "build|ledger entry does not bind to the current PRD content"; return 0
  fi
  # request-e ② (story-scoped confirmation): with an optional 4th arg <us_id>,
  # confirmation is judged for THAT story alone — a multi-US campaign no longer
  # pins every re-verification of an already-verified story to build just
  # because later stories are incomplete (field: a fully-green first story
  # could NEVER pass codex build-doctrine consensus → CB → BLOCKED).
  # Fail-closed checks retained verbatim: malformed newest line (above), the
  # story entry must bind to the CURRENT PRD hash, its commit must resolve AND
  # be an ancestor of HEAD, and the ①b tree gate below still runs. The
  # campaign-scope `diff --quiet <sha> HEAD` unchanged-since check is replaced
  # by the ancestor check HERE ONLY — mid-campaign, later stories legitimately
  # advance HEAD; the verifier's own fresh evidence re-run remains the safety
  # net for cross-story regressions. Full-coverage (no 4th arg) semantics are
  # byte-identical to before — resume-finalize and final-ALL use that path.
  local scope_us="${4:-}"
  if [[ -n "$scope_us" ]]; then
    local story
    story=$(jq -cR 'fromjson? // empty' "$ledger" 2>/dev/null \
      | jq -c --arg u "$scope_us" --arg p "$cur_prd" \
          'select((.us_id == $u and .prd == $p) or (.us_id == "ALL" and .prd == $p and ((.coverage // []) | index($u))))' 2>/dev/null \
      | tail -1)
    if [[ -z "$story" ]]; then
      print -r -- "build|no PRD-bound verified ledger entry for $scope_us"; return 0
    fi
    local story_sha
    story_sha=$(print -r -- "$story" | jq -r '.commit // empty' 2>/dev/null)
    [[ -n "$story_sha" ]] || { print -r -- "build|$scope_us ledger entry has no commit anchor"; return 0; }
    if ! git -C "$root" rev-parse --verify --quiet "${story_sha}^{commit}" >/dev/null 2>&1; then
      print -r -- "build|$scope_us ledger commit SHA does not resolve"; return 0
    fi
    if ! git -C "$root" merge-base --is-ancestor "$story_sha" HEAD 2>/dev/null; then
      print -r -- "build|$scope_us verified commit is not an ancestor of HEAD"; return 0
    fi
    sha="$story_sha"   # basis reporting below
  else
  if [[ "$us" == "ALL" ]]; then
    covered=$(print -r -- "$newest" | jq -r '.coverage[]? // empty' 2>/dev/null | grep -E '^US-[0-9]+$' | sort -u)
  else
    # final-review P1-2: coverage counts ONLY entries bound to the CURRENT
    # PRD hash — sibling lines earned against an older plan must not supply
    # coverage for this one.
    covered=$(jq -cR 'fromjson? // empty' "$ledger" 2>/dev/null | jq -r --arg p "$cur_prd" 'select(.us_id != "ALL" and .prd == $p) | .us_id // empty' 2>/dev/null | grep -E '^US-[0-9]+$' | sort -u)
  fi
  if [[ "$covered" != "$prd_us" ]]; then
    print -r -- "build|ledger coverage does not equal the PRD US set"; return 0
  fi
  if ! git -C "$root" rev-parse --verify --quiet "${sha}^{commit}" >/dev/null 2>&1; then
    print -r -- "build|ledger commit SHA does not resolve"; return 0
  fi
  if ! git -C "$root" diff --quiet "$sha" HEAD 2>/dev/null; then
    print -r -- "build|tracked content changed since the verified commit"; return 0
  fi
  fi
  # request-b ①b: unrelated RESIDENT user dirt must not pin build mode. Reuse the
  # PROVEN Bug#8 F-8 exclusion semantics: the working-tree-dirty gate fails only
  # when (tracked-dirty set MINUS CAMPAIGN_PREEXISTING_DIRTY) is non-empty — the
  # exact same `comm -23` subtraction against the sorted preexisting snapshot that
  # F-8 uses. Tracked dirt captured at process start (a user's resident uncommitted
  # files, which the campaign never touches) no longer forces build; any NEW
  # campaign-era tracked dirt still does. The SHA anchor `git diff --quiet <sha>
  # HEAD` above stays byte-identical — THAT is the anti-gaming guarantee for
  # committed deliverables. Field case: a resumed campaign in a repo with resident
  # user files was pinned to build forever, so codex strict-failed every
  # re-verification while claude passed — the asymmetry was mode MISCLASSIFICATION,
  # not prompt divergence (the confirmation clause is already shared by both
  # engines via VERIFIER_PROMPT_BASE + write_verifier_trigger).
  # Known caveat (accepted, mirrors Bug#8 D-25): CAMPAIGN_PREEXISTING_DIRTY
  # re-captures at each process start, so on a RELAUNCH a prior segment's
  # uncommitted file counts as preexisting and is excluded here. This is safe
  # because confirmation mode's real safety net is the VERIFIER's OWN fresh
  # full-suite re-run plus the committed-deliverable SHA anchor — not this
  # working-tree check. (HEAD resolves here: the SHA-anchor checks above already
  # proved a committed verified state.)
  local _tracked_dirty
  _tracked_dirty=$(git -C "$root" diff --name-only HEAD 2>/dev/null)
  if (( $? != 0 )); then
    print -r -- "build|git status failed (not a repo?)"; return 0
  fi
  local _campaign_dirty
  _campaign_dirty=$(comm -23 \
    <(printf '%s\n' "$_tracked_dirty" | grep -v '^[[:space:]]*$' | sort -u) \
    <(printf '%s\n' "${CAMPAIGN_PREEXISTING_DIRTY:-}" | grep -v '^[[:space:]]*$' | sort -u))
  if [[ -n "$_campaign_dirty" ]]; then
    print -r -- "build|tracked working tree has campaign-era changes since the verified commit"; return 0
  fi
  if [[ -n "$scope_us" ]]; then
    print -r -- "confirmation|story-scoped: $scope_us verified at ${sha[1,10]} (ancestor of HEAD), PRD-bound, tree clean (resident preexisting dirt excluded)"
  else
    print -r -- "confirmation|all PRD US verified at ${sha[1,10]} == HEAD, tree clean (resident preexisting dirt excluded)"
  fi
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
  # v0.22.3 US-001 AC0: leader-gated ALL completion record. Batch/final-ALL
  # campaigns never take the per-US ledger append, so without this line the
  # ledger stays empty and a restart could never derive confirmation mode.
  # Riding the COMPLETE path keeps the record leader-only by construction
  # (governance s7: only the leader writes sentinels).
  if [[ -n "${VERIFIED_LEDGER:-}" && -n "${PRD_FILE:-}" && -f "${PRD_FILE:-}" ]]; then
    local _cov
    _cov=$(_prd_us_set "$PRD_FILE" | paste -sd, -)
    if [[ -n "$_cov" ]] && ! _append_verified_ledger_all "$_cov"; then
      log_error "COMPLETE recorded but the ALL ledger record failed — a future resume will fail closed to build mode (re-runs verification instead of confirming)"
    fi
  fi
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
# reason_category. governance.md §1f defines the reason_category values
# (metric_failure, cross_us_dep, contract_violation, context_limit,
# infra_failure, repeat_axis, mission_abort, external_fact). wrapper MUST branch
# on reason_category; failure_category is diagnostic only.
#
# vision-adopt §2 (recoverable reconciliation — fail-fast wins): infra_failure is
# NOT blanket-recoverable. Node's _classifyBlock classifies EVERY infra_failure
# SOURCE recoverable=false (pane exit / timeout / prompt-block / git-unverifiable
# → a human must investigate, not a blind auto-retry). This category default now
# matches that conservative taxonomy. The genuinely-transient infra callsites
# (API backoff exhaustion, model-capacity stall, lifecycle restart) opt back in
# to recoverable=true + restart via write_blocked_sentinel's per-callsite
# override args — see the parity fixture tests/fixtures/recoverable-parity/.
# vision-adopt §3: external_fact (owner-supplied out-of-repo fact needed) is
# recoverable=false with action retry_after_fix (update the contract, relaunch).
_blocked_recoverable_for_category() {
  case "$1" in
    metric_failure|cross_us_dep|contract_violation) echo "true" ;;
    infra_failure|context_limit|repeat_axis|mission_abort|external_fact) echo "false" ;;
    *)                                          echo "false" ;;
  esac
}
_blocked_action_for_category() {
  case "$1" in
    metric_failure|cross_us_dep|contract_violation) echo "retry_after_fix" ;;
    external_fact)               echo "retry_after_fix" ;;
    infra_failure)               echo "investigate" ;;
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
  # request-d ③: optional 4th arg `cause` (infra|contract_gap|defect). Distinct
  # from reason_category — cause is a 3-value OPERATOR-ROUTING field:
  #   infra        = transient/environment (git error, dispatch, timeout, dead pane)
  #   contract_gap = the PRD must change (a planning miss — a decision the loop met
  #                  that should have been delegated at plan time; request-d ①
  #                  prevents these upstream, so callsites rarely emit it)
  #   defect       = a malformed/incorrect artifact was produced
  # Default `infra` (most common + safest to auto-retry). Closed set enforced;
  # an unrecognized value degrades to infra. Operators may refine callsite
  # classifications over time.
  local cause="${4:-infra}"
  case "$cause" in infra|contract_gap|defect) ;; *) cause="infra" ;; esac
  # vision-adopt §2: optional per-callsite overrides. 5th arg = recoverable
  # override ("true"|"false"), 6th = suggested_action override. Used only where a
  # callsite must diverge from the reason_category default — specifically the
  # genuinely-transient infra_failure callsites (API backoff, capacity stall,
  # lifecycle restart) that stay recoverable=true + restart while the category
  # default is the conservative fail-fast (recoverable=false + investigate). Empty
  # (default) → category-derived value. An out-of-set recoverable override is
  # ignored (falls back to the category default).
  local recoverable_override="${5:-}"
  local action_override="${6:-}"
  local recoverable suggested_action json_path
  recoverable=$(_blocked_recoverable_for_category "$category")
  suggested_action=$(_blocked_action_for_category "$category")
  case "$recoverable_override" in true|false) recoverable="$recoverable_override" ;; esac
  [[ -n "$action_override" ]] && suggested_action="$action_override"
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
    --arg cause "$cause" \
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
      cause: $cause,
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

# =============================================================================
# request-d ①-b: gate-receipt binding (zsh side)
# =============================================================================
# sha256 of a file's bytes (hex). shasum is mac-default; sha256sum on Linux.
_rlp_sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  else
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  fi
}
_rlp_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  else
    sha256sum 2>/dev/null | awk '{print $1}'
  fi
}

# Enumerate the full sealed contract set for a slug in the deterministic byte
# order the content hash is computed over: main PRD, per-US PRD (C-sorted), main
# test-spec, per-US test-spec (C-sorted). Echoes one basename per line. No main
# PRD → empty (the PRD is the anchor; a test-spec with no PRD is not sealable).
# vision-adopt §1a: the sealed set now covers test-spec files too.
_list_contract_files() {
  local plans_dir="$1" slug="$2"
  [[ -f "$plans_dir/prd-$slug.md" ]] || return 0
  print -r -- "prd-$slug.md"
  local b
  for b in ${(f)"$(cd "$plans_dir" 2>/dev/null && ls -1 2>/dev/null | grep -E "^prd-${slug}-US-.*\.md$" | LC_ALL=C sort)"}; do
    [[ -n "$b" ]] && print -r -- "$b"
  done
  [[ -f "$plans_dir/test-spec-$slug.md" ]] && print -r -- "test-spec-$slug.md"
  for b in ${(f)"$(cd "$plans_dir" 2>/dev/null && ls -1 2>/dev/null | grep -E "^test-spec-${slug}-US-.*\.md$" | LC_ALL=C sort)"}; do
    [[ -n "$b" ]] && print -r -- "$b"
  done
}

# Content hash over the whole sealed contract set (PRD + test-spec) for a slug,
# byte-for-byte reproducible by src/node/util/gate-receipt.mjs
# computePrdContentHash(). Each file contributes a line "<basename>:<sha256(file)>\n";
# the digest is sha256 of those lines concatenated (trailing newline included).
# No main PRD → empty.
compute_prd_content_hash() {
  local plans_dir="$1" slug="$2"
  [[ -f "$plans_dir/prd-$slug.md" ]] || { printf ''; return 0; }
  local manifest="" name h
  for name in ${(f)"$(_list_contract_files "$plans_dir" "$slug")"}; do
    [[ -n "$name" ]] || continue
    h=$(_rlp_sha256_file "$plans_dir/$name")
    manifest+="${name}:${h}
"
  done
  printf '%s' "$manifest" | _rlp_sha256_stdin
}

# vision-adopt §1a backward-compat: PRD-ONLY hash (the pre-vision-adopt sealed
# set). Schema-1.0 receipts hold a PRD-only prd_sha256, so their live comparison
# must use this — otherwise every released campaign false-mismatches once a
# test-spec exists. Mirror of gate-receipt.mjs computeLegacyPrdHash().
_compute_prd_only_hash() {
  local plans_dir="$1" slug="$2"
  [[ -f "$plans_dir/prd-$slug.md" ]] || { printf ''; return 0; }
  local manifest="" name h
  local -a ordered
  ordered=("prd-$slug.md")
  for name in ${(f)"$(cd "$plans_dir" 2>/dev/null && ls -1 2>/dev/null | grep -E "^prd-${slug}-US-.*\.md$" | LC_ALL=C sort)"}; do
    [[ -n "$name" ]] && ordered+=("$name")
  done
  for name in "${ordered[@]}"; do
    h=$(_rlp_sha256_file "$plans_dir/$name")
    manifest+="${name}:${h}
"
  done
  printf '%s' "$manifest" | _rlp_sha256_stdin
}

# A receipt predates the vision-adopt sealed set (schema 1.0) when it has no
# per-file file_hashes map. Echoes the live hash to compare it against: PRD-only
# for a legacy receipt, full sealed set for a 1.1+ receipt.
_live_hash_for_receipt() {
  local plans_dir="$1" slug="$2" receipt="$3"
  if jq -e '(.file_hashes | type) == "object"' "$receipt" >/dev/null 2>&1; then
    compute_prd_content_hash "$plans_dir" "$slug"
  else
    _compute_prd_only_hash "$plans_dir" "$slug"
  fi
}

# Compare the live hash to plans/gate-receipt-<slug>.json. Echoes exactly one of:
# ok | missing | mismatch (mirror of gate-receipt.mjs verifyGateReceipt). The
# comparison basis matches how the receipt was sealed (§1a backward-compat).
verify_gate_receipt() {
  local plans_dir="$1" slug="$2"
  local receipt="$plans_dir/gate-receipt-$slug.json"
  local live rec
  [[ -f "$receipt" ]] || { printf 'missing'; return 0; }
  rec=$(jq -r '.prd_sha256 // ""' "$receipt" 2>/dev/null)
  [[ -n "$rec" ]] || { printf 'missing'; return 0; }
  live=$(_live_hash_for_receipt "$plans_dir" "$slug" "$receipt")
  [[ "$rec" == "$live" ]] && printf 'ok' || printf 'mismatch'
}

# vision-adopt §1c: contract-revision audit chain (zsh mirror of
# gate-receipt.mjs appendContractRevisions). When a sealed contract file's hash
# differs from the receipt at run start, append `{ts, file, old_hash, new_hash,
# receipt_version}` per changed file to an append-only JSONL log. Records the
# change, NOT the author (git-blame actor identification was rejected). Follows
# the story-ledger append-then-lock convention: the log stays 0444 between
# appends. Idempotent — the same file→(old→new) transition is recorded once even
# though the run path re-checks every start. Best-effort: never fails the run.
append_contract_revisions() {
  local plans_dir="$1" slug="$2" log_path="$3"
  local receipt="$plans_dir/gate-receipt-$slug.json"
  [[ -f "$receipt" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  local rec_hash live
  rec_hash=$(jq -r '.prd_sha256 // ""' "$receipt" 2>/dev/null)
  [[ -n "$rec_hash" ]] || return 0
  # vision-adopt §1a backward-compat: compare against the receipt's own hash
  # basis (PRD-only for schema 1.0). A zero-edit legacy campaign must NOT record
  # a bundle-composition "difference" from the test-spec sealed-set expansion.
  live=$(_live_hash_for_receipt "$plans_dir" "$slug" "$receipt")
  [[ "$rec_hash" == "$live" ]] && return 0   # no drift

  local receipt_version ts
  receipt_version=$(jq -r '.schema_version // "1.0"' "$receipt" 2>/dev/null)
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Candidate revisions as three parallel arrays (file / old / new).
  local -a c_file c_old c_new
  c_file=(); c_old=(); c_new=()
  if jq -e '(.file_hashes | type) == "object"' "$receipt" >/dev/null 2>&1; then
    typeset -A live_hashes
    local name
    for name in ${(f)"$(_list_contract_files "$plans_dir" "$slug")"}; do
      [[ -n "$name" ]] || continue
      live_hashes[$name]=$(_rlp_sha256_file "$plans_dir/$name")
    done
    local -a names
    names=(${(f)"$(jq -r '.file_hashes | keys[]' "$receipt" 2>/dev/null)"})
    for name in ${(k)live_hashes}; do names+=("$name"); done
    local uniq_name oldh newh
    for uniq_name in ${(ou)names}; do
      [[ -n "$uniq_name" ]] || continue
      oldh=$(jq -r --arg n "$uniq_name" '.file_hashes[$n] // ""' "$receipt" 2>/dev/null)
      newh="${live_hashes[$uniq_name]:-}"
      if [[ "$oldh" != "$newh" ]]; then
        c_file+=("$uniq_name"); c_old+=("$oldh"); c_new+=("$newh")
      fi
    done
  else
    # Legacy (schema 1.0) receipt: no per-file hashes. Record the PRD-only bundle
    # drift ($live is already the PRD-only basis), so this fires only on a real
    # PRD edit, not on the test-spec sealed-set expansion.
    c_file+=("<contract-bundle>"); c_old+=("$rec_hash"); c_new+=("$live")
  fi
  (( ${#c_file} )) || return 0

  # Idempotency: skip transitions already recorded.
  typeset -A seen
  if [[ -f "$log_path" ]]; then
    local line key
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      key=$(printf '%s' "$line" | jq -r '"\(.file) \(.old_hash) \(.new_hash)"' 2>/dev/null) || continue
      [[ -n "$key" ]] && seen[$key]=1
    done < "$log_path"
  fi

  local -a a_file a_old a_new
  a_file=(); a_old=(); a_new=()
  local i k
  for (( i = 1; i <= ${#c_file}; i++ )); do
    k="${c_file[$i]} ${c_old[$i]} ${c_new[$i]}"
    [[ -n "${seen[$k]:-}" ]] && continue
    a_file+=("${c_file[$i]}"); a_old+=("${c_old[$i]}"); a_new+=("${c_new[$i]}")
  done
  (( ${#a_file} )) || return 0

  mkdir -p "${log_path:h}" 2>/dev/null
  [[ -f "$log_path" ]] && chmod 0644 "$log_path" 2>/dev/null
  {
    for (( i = 1; i <= ${#a_file}; i++ )); do
      jq -nc --arg ts "$ts" --arg file "${a_file[$i]}" --arg old "${a_old[$i]}" \
        --arg new "${a_new[$i]}" --arg rv "$receipt_version" \
        '{ts:$ts, file:$file, old_hash:$old, new_hash:$new, receipt_version:$rv}' >> "$log_path"
    done
  } always {
    chmod 0444 "$log_path" 2>/dev/null
  }
  return 0
}

# =============================================================================
# request-d ②: campaign worktree isolation (zsh side)
# =============================================================================
# Create (or reuse) a dedicated git worktree for the campaign and copy the
# .rlp-desk scaffold into it. Echoes the worktree path on success (stdout);
# echoes nothing and returns 1 on any failure so the caller falls back to the
# in-place path. All human-readable logs go to stderr (stdout is the path only,
# so the caller can `ROOT=$(setup_campaign_worktree ...)`).
setup_campaign_worktree() {
  local origin_root="$1" slug="$2" desk_rel="${3:-.rlp-desk}"
  local wt_parent="$origin_root/$desk_rel/worktrees"
  local wt_dir="$wt_parent/$slug"
  local branch="campaign/$slug"

  if ! git -C "$origin_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    print -u2 "[worktree] WARNING: --worktree requested but $origin_root is not a git work tree — running in-place."
    return 1
  fi

  if [[ -e "$wt_dir/.git" ]]; then
    print -u2 "[worktree] reusing existing campaign worktree: $wt_dir"
  else
    mkdir -p "$wt_parent"
    if git -C "$origin_root" show-ref --verify --quiet "refs/heads/$branch"; then
      if ! git -C "$origin_root" worktree add "$wt_dir" "$branch" >/dev/null 2>&1; then
        print -u2 "[worktree] WARNING: 'git worktree add $wt_dir $branch' failed — running in-place."
        return 1
      fi
    else
      if ! git -C "$origin_root" worktree add "$wt_dir" -b "$branch" >/dev/null 2>&1; then
        print -u2 "[worktree] WARNING: 'git worktree add -b $branch $wt_dir' failed — running in-place."
        return 1
      fi
    fi
    print -u2 "[worktree] created $wt_dir on branch $branch (HEAD-based)"
  fi

  # Copy the campaign scaffold from the origin .rlp-desk into the worktree's own
  # .rlp-desk. The worktree checks out HEAD's tracked tree, but .rlp-desk is
  # gitignored, so it is absent there — copy only the durable plan/prompt/context/
  # memo inputs. Explicitly NOT copied: logs/ (fresh runtime per worktree) and
  # worktrees/ (would recurse).
  local sub
  for sub in plans prompts context memos; do
    if [[ -d "$origin_root/$desk_rel/$sub" ]]; then
      mkdir -p "$wt_dir/$desk_rel/$sub"
      cp -R "$origin_root/$desk_rel/$sub/." "$wt_dir/$desk_rel/$sub/" 2>/dev/null
    fi
  done
  print -u2 "[worktree] copied .rlp-desk scaffold (plans/prompts/context/memos) into $wt_dir/$desk_rel"
  print -u2 "[worktree] NOTE: campaign runs in the worktree — if your project needs installed deps (node_modules/.venv/etc.), run your install step (npm/pnpm/yarn/pip install) inside $wt_dir. rlp-desk does not assume a package manager."

  printf '%s' "$wt_dir"
  return 0
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

# --- Provider quota exhaustion over PRE-CAPTURED pane text ---
# rc 0 = the account is out of usage/credits for now (caller must ABORT);
# rc 1 = not quota exhaustion.
#
# Deliberately distinct from detect_api_error(). A transient outage clears on its
# own, so that path backs off and retries. Quota exhaustion does not: the CLI
# prints its error, parks at the prompt, and nothing arrives until the reset
# time. Retrying is futile, so the leader aborts immediately rather than burning
# the whole ITER_TIMEOUT waiting for a verdict that cannot come.
#
# Anchor on "hit your usage limit" / "usage limit reached", never a bare
# /usage limit/: the D-17a transient banner contains the substring
# "(not your usage limit)", and matching that would strand a recoverable
# rate-limit on the terminal path. A remedy/reset hint is required as a second
# token so prose that merely discusses usage limits cannot trip the abort.
detect_quota_exhausted() {
  local text="$1"
  [[ -n "$text" ]] || return 1
  local tail
  tail=$(print -r -- "$text" | tail -n 20)
  print -r -- "$tail" | grep -qiE 'hit your usage limit|usage limit reached' || return 1
  print -r -- "$tail" | grep -qiE 'try again at|will reset at|resets at|purchase more credits|settings/usage' || return 1
  return 0
}

# ③/④ request-b: multi-signal execution-start predicate. A trigger prompt is
# "submitted and running" when the pane shows ANY of: the active-task footer
# ("esc to interrupt" / "background terminal running"), a spinner/verb the CLIs
# render while working, or a NONZERO input-token counter ("N in", never "0 in").
# NEVER trust a single glyph (repo gotcha: a banner can echo the prompt without
# executing it) — this ORs several independent signals. An echoed-but-idle prompt
# (prompt text present, none of these signals) is therefore treated as UNSUBMITTED.
# The token set is deliberately restricted to signals that ONLY appear while the
# model is actually running: the active-task footer, the CLIs' spinner verbs, and
# a nonzero input-token counter. Generic tool names (exec/Bash/Edit/Read/…) are
# intentionally EXCLUDED — the dispatched instruction is "Read and execute the
# instructions in <path>", so matching `exec`/`Read` would false-fire on the mere
# echo of the prompt and defeat the submit-anchored timeout (the very case this
# guards). Returns 0 = progress seen, 1 = no start signal.
_RLP_PROGRESS_RE='esc to interrupt|background terminal running|thinking|working|kneading|crunching|clauding|billowing|brewing|tinkering|burrowing|saut|Exploring|Prestidigitating|Undulating|razzle|bunning|zesting|fermenting|actualizing|composing|evaporating|churning|Osmosing'
_pane_shows_progress() {
  local snap="$1"
  [[ -n "$snap" ]] || return 1
  # request-e P1 fix (2026-07-21): the leader's polling call sites pass a tmux
  # PANE ID (e.g. %2065), not snapshot text — grepping the literal id string
  # meant NO pane ever showed progress, so the submit-anchored guard killed
  # healthy running verifiers at SUBMISSION_TIMEOUT (4x field-reproduced).
  # Accept BOTH: a %-prefixed pane id is captured here; anything else is
  # treated as snapshot text (test harnesses pass text directly).
  if [[ "$snap" == %<-> ]]; then
    snap=$(tmux capture-pane -t "$snap" -p 2>/dev/null) || return 1
    [[ -n "$snap" ]] || return 1
  fi
  print -r -- "$snap" | grep -qiE "$_RLP_PROGRESS_RE" && return 0
  # nonzero input-token counter (codex/claude "N in · M out" footer). "0 in" is
  # idle; any nonzero count is proof the model consumed the prompt.
  print -r -- "$snap" | grep -qE '[1-9][0-9]* in\b' && return 0
  return 1
}

# request-g (v0.22.16): a known NON-exhaustion usage banner can steal the submit
# keystroke, leaving the trigger prompt echoed-but-unsubmitted in the input box
# while the model never starts. Field-observed twice on the codex verifier leg
# ("• You have 1 usage limit reset available. Run /usage…", plus "increased plan
# usage") — case 1 a manual Enter, case 2 a 20s watchdog Enter, each resolving
# in 6-9s. This is a pure submit-delay, NOT quota exhaustion (detect_quota_exhausted
# deliberately does not match these "resets available" / weekly banners), so the
# remedy is one early Enter re-inject instead of burning the 90s submit window.
# Config knob: env-overridable because the codex CLI banner wording changes per
# version. Declared at source time (no knob section in lib) so it survives set -u.
RLP_SUBMIT_BANNER_RE="${RLP_SUBMIT_BANNER_RE:-usage limit reset(s)? available|increased plan usage|weekly limit}"
# _pane_submit_blocked_by_banner <pane_text> [trigger_needle]
# Returns 0 iff ALL THREE hold: (1) the trigger instruction is echoed in the
# input box (the needle — default the literal dispatched instruction), so the
# prompt is sitting there unsubmitted; (2) NO execution-start signal
# (_pane_shows_progress is false); (3) a known submit-blocking banner matches
# RLP_SUBMIT_BANNER_RE. Text-only input — callers capture the pane. An INVALID
# user-supplied ERE fails SAFE to "no match" (grep exit 2 → return 1), never a
# crash or a false positive.
_pane_submit_blocked_by_banner() {
  local snap="$1"
  local needle="${2:-Read and execute the instructions in}"
  [[ -n "$snap" ]] || return 1
  # (1) trigger echoed → prompt unsubmitted in the input box.
  [[ "$snap" == *"$needle"* ]] || return 1
  # (2) already running → not blocked (normal case gets zero re-injects).
  _pane_shows_progress "$snap" && return 1
  # (3) known banner visible. grep exit 1 (no match) OR 2 (invalid ERE) → not
  # blocked; only a clean match (exit 0) confirms the block. 2>/dev/null hides
  # the invalid-regex diagnostic so a bad env knob degrades quietly to "safe".
  print -r -- "$snap" | grep -qE "$RLP_SUBMIT_BANNER_RE" 2>/dev/null || return 1
  return 0
}

# ① request-j (v0.22.18): codex "Selected model is at capacity" is a POST-submission
# MID-EXECUTION stall — the model was selected and the prompt submitted, then the
# pane freezes with the capacity banner and NO progress signal, waiting indefinitely
# until ITER_TIMEOUT. This is DISTINCT from:
#   - request-g's RLP_SUBMIT_BANNER_RE (a PRE-submission banner stealing the submit
#     keystroke — there the trigger is still echoed unsubmitted), and
#   - detect_api_error's transient outage phrases (overloaded / rate-limit).
# Field-observed as pure transient: a manual "Continue." resumed it instantly. So the
# remedy is to inject a resume line, bounded by a cooldown + strike cap (the caller
# owns that bookkeeping), and to fail fast if the capacity wall persists. The banner
# wording changes per codex version, so the pattern is env-overridable; kept
# CONSERVATIVE (anchored on "model … at capacity") to avoid false positives on
# ordinary output. Declared at source time so it survives set -u.
RLP_CAPACITY_BANNER_RE="${RLP_CAPACITY_BANNER_RE:-Selected model is at capacity|model is at capacity}"
RLP_CAPACITY_RESUME_TEXT="${RLP_CAPACITY_RESUME_TEXT:-Continue.}"
RLP_CAPACITY_REINJECT_COOLDOWN_S="${RLP_CAPACITY_REINJECT_COOLDOWN_S:-120}"
RLP_CAPACITY_MAX_STRIKES="${RLP_CAPACITY_MAX_STRIKES:-3}"
# _validate_int_knob is defined by run_ralph_desk.zsh (sourced BEFORE this lib in
# production); guard the call so standalone lib sourcing (test harnesses) does not
# error on the missing function — the inline ${:-default} at the call sites keeps
# the poll arithmetic safe regardless.
if (( $+functions[_validate_int_knob] )); then
  _validate_int_knob RLP_CAPACITY_REINJECT_COOLDOWN_S 120 0
  _validate_int_knob RLP_CAPACITY_MAX_STRIKES 3 1
fi
# _pane_capacity_stalled <pane_text>
# Returns 0 iff BOTH hold on the SAME captured text: (1) NO execution-start signal
# (_pane_shows_progress false — never inject while a spinner/progress is live, so a
# healthy run is never disturbed) AND (2) a known capacity banner matches
# RLP_CAPACITY_BANNER_RE. Text-only input — the caller captures the pane ONCE and
# passes it (single-capture contract). An INVALID user-supplied ERE fails SAFE to
# "no match" (grep exit 2 → return 1). The caller must additionally let
# detect_quota_exhausted WIN (a usage wall is terminal, never resume-injected).
_pane_capacity_stalled() {
  local snap="$1"
  [[ -n "$snap" ]] || return 1
  # (1) already running → not a stall (zero false injections on a live spinner).
  _pane_shows_progress "$snap" && return 1
  # (2) known capacity banner visible. grep exit 1 (no match) OR 2 (invalid ERE) →
  # not stalled; only a clean match (exit 0) confirms. 2>/dev/null so a bad env
  # knob degrades quietly to "safe" instead of emitting a regex diagnostic.
  print -r -- "$snap" | grep -qiE "$RLP_CAPACITY_BANNER_RE" 2>/dev/null || return 1
  return 0
}

# ③/④ request-b: submit-anchored deadline classifier (the root fix). The task
# timeout (ITER_TIMEOUT) MUST count from the FIRST progress signal, not from
# dispatch — a banner that delays submission must never burn the task budget and
# be mis-read as a task/infra timeout. Args (all epoch seconds / seconds):
#   $1 first_progress_ts  epoch when progress was first seen; 0 = never seen
#   $2 dispatch_ts        epoch when the trigger was sent
#   $3 now                epoch now
#   $4 iter_timeout       task budget, counted FROM first_progress_ts
#   $5 submit_timeout     max wait for first progress before it's a submission failure
# Prints exactly one state:
#   running            progress seen, still within the task deadline
#   task_timeout       progress seen, first_progress_ts+iter_timeout has passed
#   pending            no progress yet, still within the submit window
#   submission_failure no progress AND submit window exceeded → RE-DISPATCH (never a hard BLOCK)
_submission_deadline_state() {
  local fp="${1:-0}" disp="${2:-0}" now="${3:-0}" iter_to="${4:-0}" submit_to="${5:-0}"
  if (( fp > 0 )); then
    if (( now - fp >= iter_to )); then print -r -- "task_timeout"; else print -r -- "running"; fi
    return 0
  fi
  if (( now - disp >= submit_to )); then print -r -- "submission_failure"; else print -r -- "pending"; fi
  return 0
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
