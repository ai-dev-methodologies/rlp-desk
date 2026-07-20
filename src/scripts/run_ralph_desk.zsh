#!/bin/zsh
set -uo pipefail
# NOTE: We use set -u (undefined var check) and pipefail, but NOT set -e
# because the main loop uses explicit error checks throughout.

# D-19: validate an env-overridable INTEGER knob. A non-integer value (operator
# typo, or a bad CLI arg like `--max-iter abc` threaded into the env) otherwise
# mis-evaluates under `set -u` inside (( )) arithmetic — e.g. a non-integer
# MAX_ITER makes the main-loop bound error so the campaign silently runs ZERO
# iterations; a non-integer CB_THRESHOLD breaks the circuit breaker. The `<->`
# integer glob is checked FIRST (and short-circuits) so the arithmetic never runs
# on a non-integer. A malformed / below-min / above-max value → the default.
_validate_int_knob() {
  local _name="$1" _default="$2" _min="${3:-0}" _max="${4:-0}"
  local _val="${(P)_name}"
  local _bad=0
  if ! [[ "$_val" == <-> ]]; then
    _bad=1
  elif (( _val < _min )); then
    _bad=1
  elif (( _max > 0 && _val > _max )); then
    _bad=1
  fi
  if (( _bad )); then
    local _range="min=$_min"; (( _max > 0 )) && _range="$_range, max=$_max"
    print -r -- "WARNING: $_name='$_val' is not a valid integer ($_range) — using default $_default" >&2
    eval "$_name=$_default"
  fi
}

# _git_dirty_base(): moved to lib_ralph_desk.zsh (v0.22.7 US-001) so the Bug #8
# gate, the campaign-preexisting-dirty snapshot, and the new commit-integrity
# oracle share ONE definition. lib is sourced at L474 (before any call site).

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
#   WORKER_CODEX_MODEL            - codex model for Worker (default: gpt-5.5)
#   WORKER_CODEX_REASONING        - codex reasoning for Worker (default: high)
#   VERIFIER_CODEX_MODEL          - codex model for Verifier (default: gpt-5.5)
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
# IMP-08: fail-fast slug guard (mirrors init_ralph_desk.zsh + Node
# requireCanonicalSlug) — SLUG is interpolated raw into $DESK/logs/$SLUG,
# mkdir, rm, analytics paths, so reject a traversal/separator/uppercase slug
# BEFORE any filesystem op. Superset of normalizeSlug output → no valid slug breaks.
[[ "$SLUG" =~ '^[a-z0-9][a-z0-9-]*$' ]] || { print -u2 "ERROR: invalid slug: $SLUG (must be lowercase [a-z0-9-], no path separators)"; exit 2; }
ROOT="${ROOT:-$PWD}"
MAX_ITER="${MAX_ITER:-20}"
WORKER_MODEL="${WORKER_MODEL:-haiku}"
VERIFIER_MODEL="${VERIFIER_MODEL:-sonnet}"
FINAL_VERIFIER_MODEL="${FINAL_VERIFIER_MODEL:-opus}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"
ITER_TIMEOUT="${ITER_TIMEOUT:-600}"
# ③/④ request-b: submit-anchored timeout. ITER_TIMEOUT is the TASK budget and
# now counts from the first progress signal, not from dispatch. SUBMISSION_TIMEOUT
# bounds how long the leader waits for that first progress signal before
# classifying the dispatch as a SUBMISSION failure (banner-delayed / prompt not
# consumed) and re-dispatching — instead of burning the task budget and hard-
# BLOCKing. SUBMISSION_MAX_REDISPATCH caps the re-dispatch cycles per dispatch.
SUBMISSION_TIMEOUT="${SUBMISSION_TIMEOUT:-90}"
SUBMISSION_MAX_REDISPATCH="${SUBMISSION_MAX_REDISPATCH:-2}"
HEARTBEAT_STALE_THRESHOLD="${HEARTBEAT_STALE_THRESHOLD:-120}"
MAX_RESTARTS="${MAX_RESTARTS:-3}"
IDLE_NUDGE_THRESHOLD="${IDLE_NUDGE_THRESHOLD:-30}"
MAX_NUDGES="${MAX_NUDGES:-3}"
# D-19: validate the numeric knobs above (set -u + (( )) arithmetic safety).
_validate_int_knob MAX_ITER 20 1
_validate_int_knob POLL_INTERVAL 5 1
_validate_int_knob ITER_TIMEOUT 600 1
_validate_int_knob SUBMISSION_TIMEOUT 90 1
_validate_int_knob SUBMISSION_MAX_REDISPATCH 2 0
_validate_int_knob HEARTBEAT_STALE_THRESHOLD 120 1
_validate_int_knob MAX_RESTARTS 3 0
_validate_int_knob IDLE_NUDGE_THRESHOLD 30 1
_validate_int_knob MAX_NUDGES 3 0
WITH_SELF_VERIFICATION="${WITH_SELF_VERIFICATION:-0}"
WITH_SELF_VERIFICATION_REQUESTED="$WITH_SELF_VERIFICATION"  # preserves original user intent for traceability (governance §1f)
SV_SKIPPED_REASON=""                                         # set when SV is disabled despite user request

# v0.14.0 — zsh runner restored as primary tmux mode path.
# v5.7 §4.2's deprecation gate (rejected --flywheel/--flywheel-guard/
# --with-self-verification) is removed: the Node port shipped without
# zsh-equivalent safety nets (heartbeat, copy-mode guard, prompt-stall,
# no-progress, stale-context, claude model upgrade chain, etc.), so the
# Node leader is now reserved for `--mode agent` (LLM-driven) only.
# `--mode tmux` invocations from src/node/run.mjs delegate here as a
# subprocess via env vars. ARCH Wave C / ADR-001: FLYWHEEL and FLYWHEEL_GUARD
# are NOT implemented in the zsh leader (no dispatch site) and are deprecated —
# do NOT claim otherwise. WITH_SELF_VERIFICATION is forwarded for traceability,
# but the SV report is produced by the Node post-pass in run.mjs runTmuxViaZsh
# after this script exits (this script keeps its $TMUX early-return to avoid the
# `claude --print` no-TTY hang).
AUTONOMOUS_MODE="${AUTONOMOUS_MODE:-0}"    # 1=don't stop on ambiguity, PRD is authoritative
# P1-E Lane enforcement: WARN-only by default; --lane-strict opts into BLOCKED
# escalation. governance §7¾. The opt-in defaults to "warn"; "strict" trips
# BLOCKED with reason_category=infra_failure + recoverable=true (downgrade
# from terminal_alert) so an inaccurate mtime audit cannot terminally kill a
# campaign.
LANE_MODE="${LANE_MODE:-warn}"
# US-018 R6 P1-F Test density: WARN by default; --test-density-strict turns
# init exit non-zero when any AC has < 3 tests (governance §7f).
TEST_DENSITY_MODE="${TEST_DENSITY_MODE:-warn}"
# US-021 R9 P2-I consecutive_blocks circuit breaker (governance §8). When the
# same canonical block reason fires N times in a row the runner writes
# .sisyphus/mission-abort.json and exits non-zero so contract defects don't
# silently loop. infra_failure category and the very first iteration are exempt.
BLOCK_CB_THRESHOLD="${BLOCK_CB_THRESHOLD:-3}"
_validate_int_knob BLOCK_CB_THRESHOLD 3 1   # D-19
CONSECUTIVE_BLOCKS=0
LAST_BLOCK_REASON=""

# US-021 R9 P2-I: track repeated same-reason blocks. infra_failure category and
# the very first iteration are exempt (mission setup blocks shouldn't trip
# the abort). Returns 0 if loop should continue, 1 (after writing
# mission-abort.json) if the threshold is reached.
# US-023 R11 P2-K: guarantee at least one cost-log.jsonl entry per campaign.
# An empty cost-log can mean either "no usage recorded" or "logging broken" —
# we make the distinction observable by always emitting a final entry on exit
# (idempotent via COST_LOG_FINAL_WRITTEN). Wired into the existing cleanup trap.
COST_LOG_FINAL_WRITTEN=0
_emit_final_cost_log() {
  if [[ "${COST_LOG_FINAL_WRITTEN:-0}" -ne 0 ]]; then
    return 0
  fi
  COST_LOG_FINAL_WRITTEN=1
  if [[ -n "${ITERATION:-}" && -n "${LOGS_DIR:-}" ]]; then
    write_cost_log "${ITERATION:-0}" 2>/dev/null || true
  fi
}

# US-004 AC4.1/AC4.2 (F3.6 zero-artifact campaign abandonment guardrail,
# failure-modes.md §3): synchronous t0 launch-breadcrumb writer. Called once,
# at top level, immediately after LOGS_DIR/SLUG resolve (near STATUS_FILE
# init — see call site below). `logs/<slug>/launch-record.json` is the same
# file src/node/run.mjs already wrote (provisional-then-enriched, AC4.1) as
# the outermost --mode tmux frame; this is the durable guarantee: called
# BEFORE check_dependencies()/main() can exit early (e.g. missing
# jq/tmux/claude), so a death before iteration 1 still leaves a post-mortem
# trail. No jq dependency on purpose — jq itself is not confirmed present
# until check_dependencies() runs inside main(), which is after this point.
_write_launch_record_t0() {
  LAUNCH_RECORD_FILE="$LOGS_DIR/launch-record.json"
  mkdir -p "$LOGS_DIR" 2>/dev/null
  printf '{"ts":"%s","slug":"%s","leader":"zsh","pid":%s,"phase":"launched"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SLUG" "$$" > "$LAUNCH_RECORD_FILE" 2>/dev/null
}

# US-004 AC4.2: best-effort outcome update to the t0 launch-record.json above
# — THAT synchronous write is the durable guarantee this US provides, not
# this function. Chained first into the EXIT/INT/TERM/HUP trap so `$?` still
# reflects the status that triggered the trap. SIGKILL is untrappable, so a
# campaign killed with -9 gets no outcome update — the t0 record alone still
# proves the campaign launched.
LAUNCH_RECORD_OUTCOME_WRITTEN=0
_emit_launch_record_outcome() {
  local exit_code="$?"
  if [[ "${LAUNCH_RECORD_OUTCOME_WRITTEN:-0}" -ne 0 ]]; then
    return 0
  fi
  LAUNCH_RECORD_OUTCOME_WRITTEN=1
  if [[ -z "${LAUNCH_RECORD_FILE:-}" || ! -f "$LAUNCH_RECORD_FILE" ]]; then
    return 0
  fi
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg ts "$ts" --argjson exit_code "$exit_code" \
    '.phase = "exited" | .exited_at = $ts | .exit_code = $exit_code' \
    "$LAUNCH_RECORD_FILE" > "${LAUNCH_RECORD_FILE}.tmp.$$" 2>/dev/null \
    && mv "${LAUNCH_RECORD_FILE}.tmp.$$" "$LAUNCH_RECORD_FILE" 2>/dev/null
  rm -f "${LAUNCH_RECORD_FILE}.tmp.$$" 2>/dev/null
  return 0
}

# US-024 R12 P0: tmux pane/session lifecycle monitor.
# Single authoritative timeout: 5 attempts × 1s sleep = 5s budget.
# Invoked at 3 sites: create_session post-finish, main loop iter entry, and
# every send-keys/paste post-action before the wait-loop. Writes infra_failure
# BLOCKED sentinel and exits 1 when any pane or the session is dead beyond budget.
_r12_check_lifecycle() {
  local site="${1:-unknown}"
  local _attempts=0
  while ! _verify_session_alive "$SESSION_NAME" || \
         ! _verify_pane_alive "$LEADER_PANE" || \
         ! _verify_pane_alive "$WORKER_PANE" || \
         ! _verify_pane_alive "$VERIFIER_PANE"; do
    (( _attempts++ ))
    if (( _attempts >= 5 )); then
      log_error "[r12:$site] tmux session/pane dead after 5x1s polling (5s authoritative budget). session=$SESSION_NAME panes leader=$LEADER_PANE worker=$WORKER_PANE verifier=$VERIFIER_PANE"
      tmux list-panes -a -F '#{session_name}:#{pane_id} dead=#{pane_dead}' 2>&1 | head -20 >> "${DEBUG_LOG:-/dev/null}"
      write_blocked_sentinel "tmux session/pane dead during $site" "${CURRENT_US:-ALL}" "infra_failure"
      exit 1
    fi
    sleep 1
  done
  return 0
}

_check_consecutive_blocks() {
  local reason="$1"
  local category="${2:-metric_failure}"
  local iter="${3:-${ITERATION:-0}}"
  if [[ "$category" == "infra_failure" ]] || (( iter <= 1 )); then
    LAST_BLOCK_REASON=""
    CONSECUTIVE_BLOCKS=0
    return 0
  fi
  local canonical
  canonical=$(_canonical_block_reason "$reason" 2>/dev/null)
  if [[ "$canonical" == "$LAST_BLOCK_REASON" && -n "$canonical" ]]; then
    CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
  else
    CONSECUTIVE_BLOCKS=1
    LAST_BLOCK_REASON="$canonical"
  fi
  if (( CONSECUTIVE_BLOCKS >= BLOCK_CB_THRESHOLD )); then
    local abort_dir="$DESK/.sisyphus"
    mkdir -p "$abort_dir" 2>/dev/null
    local abort_file="$abort_dir/mission-abort.json"
    printf '{"reason":"consecutive_blocks","count":%s,"last_reason":"%s","threshold":%s,"timestamp":"%s"}\n' \
      "$CONSECUTIVE_BLOCKS" "$canonical" "$BLOCK_CB_THRESHOLD" \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$abort_file"
    log_error "Mission abort: same canonical block reason '$canonical' repeated $CONSECUTIVE_BLOCKS times (>= $BLOCK_CB_THRESHOLD)"
    return 1
  fi
  return 0
}

# F-22: bump the consecutive-failure counter for a soft-fail (request_info,
# unknown verdict/status). Returns 0 if the circuit breaker is now tripped
# (caller writes a sentinel + returns 1), 1 if still under threshold (continue).
# Closes the "silently loop to MAX_ITER without ever firing the CB" gap for
# verdict/status values the case-statement did not previously account for.
_bump_consecutive_failure() {
  (( CONSECUTIVE_FAILURES++ ))
  (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )) && return 0
  return 1
}

# F-22: decide a worker/verifier BLOCK with grace. This is the call site that
# was MISSING — _check_consecutive_blocks was dead code (defined, never invoked),
# so the consecutive-blocks circuit breaker (governance §8) never ran and a
# SINGLE transient "blocked" (a fresh-context LLM mis-emitting the status, a
# formatting slip) terminated the whole campaign. Returns 0 = TERMINATE (caller
# writes the sentinel + returns 1); 1 = ABSORB as a soft-fail (loop continues,
# Worker retries). Forced terminal when: the category is a genuine infra_failure,
# the same canonical reason repeats >= BLOCK_CB_THRESHOLD, or the consecutive-
# failures CB trips. Otherwise a recoverable first/transient block is absorbed.
_block_with_grace() {
  local reason="$1" category="${2:-metric_failure}"
  _check_consecutive_blocks "$reason" "$category" "${ITERATION:-0}" || return 0
  [[ "$category" == "infra_failure" ]] && return 0
  _bump_consecutive_failure && return 0
  return 1
}

# --- Engine Selection (auto-detect from model format) ---
# claude models (haiku/sonnet/opus) with :effort → claude engine + effort
# codex models (gpt-*/spark) with :reasoning → codex engine + reasoning
# plain name → claude engine (no effort/reasoning)
_auto_detect_engine() {
  local model_var="$1" engine_var="$2" codex_model_var="$3" codex_reasoning_var="$4" effort_var="${5:-}"
  local model_val="${(P)model_var}"
  if [[ "$model_val" == *:* ]]; then
    local model_part="${model_val%%:*}"
    local level_part="${model_val##*:}"
    case "$model_part" in
      haiku|sonnet|opus|claude|claude-*)
        # Claude model with effort — keep engine as claude, store effort.
        # Matches short aliases (haiku/sonnet/opus), bare `claude`, AND full
        # versioned ids (claude-opus-4-8, claude-fable-5, claude-opus-4-8[1m]).
        # The `claude-*` glob also covers the bracket+effort combo
        # (claude-opus-4-8[1m]:high → model=claude-opus-4-8[1m], effort=high).
        eval "$engine_var=claude"
        eval "$model_var=$model_part"
        [[ -n "$effort_var" ]] && eval "$effort_var=$level_part"
        ;;
      *)
        # Codex model with reasoning
        [[ "$model_part" == "spark" ]] && model_part="gpt-5.3-codex-spark"
        # GPT-5.6 family aliases (codex 0.144) — mirror of parse_model_flag
        [[ "$model_part" == "sol" ]]   && model_part="gpt-5.6-sol"
        [[ "$model_part" == "terra" ]] && model_part="gpt-5.6-terra"
        [[ "$model_part" == "luna" ]]  && model_part="gpt-5.6-luna"
        # Warn (stderr) when the name — after alias expansion above — is not even
        # a gpt-* slug: a likely typo being silently routed to codex.
        [[ "$model_part" != gpt-* ]] && print -u2 "[rlp-desk] note: model '$model_part' is not a claude id or known codex model — routing to codex engine. Verify this is intended."
        eval "$engine_var=codex"
        eval "$model_var=$model_part"
        [[ -n "$codex_model_var" ]] && eval "$codex_model_var=$model_part"
        [[ -n "$codex_reasoning_var" ]] && eval "$codex_reasoning_var=$level_part"
        ;;
    esac
  fi
}

WORKER_ENGINE="${WORKER_ENGINE:-claude}"
VERIFIER_ENGINE="${VERIFIER_ENGINE:-claude}"
FINAL_VERIFIER_ENGINE="${FINAL_VERIFIER_ENGINE:-claude}"

# Effort levels for Claude models (set by _auto_detect_engine or CLI --worker-model opus:max)
WORKER_EFFORT="${WORKER_EFFORT:-}"
VERIFIER_EFFORT="${VERIFIER_EFFORT:-}"
FINAL_VERIFIER_EFFORT="${FINAL_VERIFIER_EFFORT:-}"
# D-18: max final-verify attempts for a US that ALREADY passed per-US. A verifier
# fail verdict on already-per-US-passed work must REPRODUCE across all attempts
# (first pass wins) before it charges a fix-loop failure — guards against verifier
# non-determinism defeating a complete, correct campaign. A genuinely-regressed US
# (or one never per-US-passed) still fails on the first attempt.
FINAL_VERIFY_MAX_ATTEMPTS="${FINAL_VERIFY_MAX_ATTEMPTS:-3}"
# D-18/D-19: a non-integer value ("abc") would mis-evaluate under set -u in the
# (( )) retry-loop arithmetic — skipping the loop and silently FALSE-FAILING a US
# — and an unbounded value would be ruinously expensive. Validate to an integer
# in 1..10 via the shared _validate_int_knob helper (D-19 generalized this
# per-knob fix into one validator used by every numeric knob).
_validate_int_knob FINAL_VERIFY_MAX_ATTEMPTS 3 1 10

# Auto-detect engine from model format for env var path (CLI path uses parse_model_flag)
_auto_detect_engine WORKER_MODEL WORKER_ENGINE WORKER_CODEX_MODEL WORKER_CODEX_REASONING WORKER_EFFORT
_auto_detect_engine VERIFIER_MODEL VERIFIER_ENGINE VERIFIER_CODEX_MODEL VERIFIER_CODEX_REASONING VERIFIER_EFFORT
_auto_detect_engine FINAL_VERIFIER_MODEL FINAL_VERIFIER_ENGINE FINAL_VERIFIER_CODEX_MODEL FINAL_VERIFIER_CODEX_REASONING FINAL_VERIFIER_EFFORT
WORKER_CODEX_MODEL="${WORKER_CODEX_MODEL:-gpt-5.5}"
WORKER_CODEX_REASONING="${WORKER_CODEX_REASONING:-high}"   # low|medium|high
VERIFIER_CODEX_MODEL="${VERIFIER_CODEX_MODEL:-gpt-5.5}"
VERIFIER_CODEX_REASONING="${VERIFIER_CODEX_REASONING:-high}"   # low|medium|high
# D-1: FINAL verifier codex sub-vars (auto-detected above from FINAL_VERIFIER_MODEL,
# default here when not codex). Wired so the FINAL (ALL) verify can run a stronger
# model than the per-US verifier — the "final 엄격" knob (FINAL_VERIFIER_MODEL
# defaults to opus). Distinct from the removed per-iteration verifier auto-upgrade.
FINAL_VERIFIER_CODEX_MODEL="${FINAL_VERIFIER_CODEX_MODEL:-gpt-5.5}"
FINAL_VERIFIER_CODEX_REASONING="${FINAL_VERIFIER_CODEX_REASONING:-high}"   # low|medium|high
CODEX_BIN=""  # resolved by check_dependencies when engine=codex

# --- Verify Mode ---
VERIFY_MODE="${VERIFY_MODE:-per-us}"        # per-us|batch
# Consensus: off|all|final-only (replaces VERIFY_CONSENSUS + FINAL_CONSENSUS + CONSENSUS_SCOPE)
CONSENSUS_MODE="${CONSENSUS_MODE:-off}"     # off|all|final-only
CONSENSUS_MODEL="${CONSENSUS_MODEL:-gpt-5.6-terra:medium}"       # per-US cross-verifier (lighter)
FINAL_CONSENSUS_MODEL="${FINAL_CONSENSUS_MODEL:-gpt-5.6-sol:high}"  # final cross-verifier (stricter)
# Legacy compat: map old flags to CONSENSUS_MODE
if [[ "${VERIFY_CONSENSUS:-0}" = "1" ]]; then
  CONSENSUS_MODE="${CONSENSUS_SCOPE:-all}"
elif [[ "${FINAL_CONSENSUS:-0}" = "1" ]]; then
  CONSENSUS_MODE="final-only"
fi
CONSENSUS_SCOPE="${CONSENSUS_SCOPE:-${CONSENSUS_MODE}}"
CB_THRESHOLD="${CB_THRESHOLD:-6}"           # consecutive failures before BLOCKED (default: 6)
_validate_int_knob CB_THRESHOLD 6 1   # D-19: must be valid before the (( *2 )) below
# Effective CB threshold (doubled when consensus mode is active) is computed
# after CLI arg parsing below, once CONSENSUS_MODE is fully resolved --
# --consensus/--final-consensus/--verify-consensus reassign it later in this
# file, and computing it here would miss CLI-driven consensus activation.
_API_MAX_RETRIES="${_API_MAX_RETRIES:-5}"
_API_RETRY_INTERVAL_S="${_API_RETRY_INTERVAL_S:-30}"
_validate_int_knob _API_MAX_RETRIES 5 1        # D-19
_validate_int_knob _API_RETRY_INTERVAL_S 30 1  # D-19

# --- Derived Paths ---
DESK="$ROOT/${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"
# v0.13.0: legacy detection — refuse to run when .claude/ralph-desk/ is still
# present. init mode auto-migrates; run mode protects in-flight campaigns.
if [[ -d "$ROOT/.claude/ralph-desk" ]]; then
  print -u2 "ERROR: Legacy .claude/ralph-desk/ detected at $ROOT/.claude/ralph-desk."
  print -u2 "Run mode does not auto-migrate to protect in-flight campaigns."
  print -u2 "Run: mv .claude/ralph-desk ${RLP_DESK_RUNTIME_DIR:-.rlp-desk} then re-run."
  exit 1
fi
# US-026 R14 P0: project-root-hashed runner lockfile prevents duplicate runner spawns
# on the same project root while allowing parallel runs across different projects.
# shasum is mac-default; sha1sum on Linux; cksum is POSIX-final fallback.
ROOT_HASH=$(printf '%s' "$ROOT" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | awk '{print substr($1,1,8)}')
RUNNER_LOCKFILE_PATH="$DESK/logs/.rlp-desk-runner-$ROOT_HASH.lock"
RUNNER_LOCKDIR="${RUNNER_LOCKFILE_PATH}.d"
PROMPTS_DIR="$DESK/prompts"
CONTEXT_DIR="$DESK/context"
MEMOS_DIR="$DESK/memos"
LOGS_DIR="$DESK/logs/$SLUG"
RUNTIME_DIR="$LOGS_DIR/runtime"
PRD_FILE="$DESK/plans/prd-$SLUG.md"
TEST_SPEC_FILE="$DESK/plans/test-spec-$SLUG.md"
# --- Analytics Directory (v5.7 §4.11.b: project-local) ---
# Was previously $HOME/.claude/ralph-desk/analytics/<slug>--<hash> (cross-project
# rollup). With v0.12.0 the canonical location is project-local; cross-project
# rollup is the Leader's responsibility via ~/.claude/ralph-desk/registry.jsonl
# (Worker/Verifier prompts never reference the registry path — see §4.11.c).
# IMP-03: this hash is INTRA-MACHINE-ONLY (a stable per-machine dir suffix);
# cross-platform parity is intentionally NOT required — the <slug>.current
# pointer file (written at analytics mkdir in main) is the cross-leader contract.
ANALYTICS_SLUG_HASH=$(echo -n "$ROOT" | md5 -q 2>/dev/null || md5sum <<< "$ROOT" | cut -d' ' -f1)
ANALYTICS_DIR="$DESK/analytics/${SLUG}--${ANALYTICS_SLUG_HASH:0:8}"
CAMPAIGN_JSONL="$ANALYTICS_DIR/campaign.jsonl"
METADATA_FILE="$ANALYTICS_DIR/metadata.json"
WORKER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.worker.prompt.md"
VERIFIER_PROMPT_BASE="$PROMPTS_DIR/${SLUG}.verifier.prompt.md"
CONTEXT_FILE="$CONTEXT_DIR/${SLUG}-latest.md"
MEMORY_FILE="$MEMOS_DIR/${SLUG}-memory.md"
SIGNAL_FILE="$MEMOS_DIR/${SLUG}-iter-signal.json"
DONE_CLAIM_FILE="$MEMOS_DIR/${SLUG}-done-claim.json"
VERDICT_FILE="$MEMOS_DIR/${SLUG}-verify-verdict.json"
# F-14: durable, structured append-only ledger of verified-pass US — the
# drift-proof source-of-truth for VERIFIED_US restore (vs the Worker's prose
# "## Completed Stories", which is fresh-context LLM output that can drift).
VERIFIED_LEDGER="$MEMOS_DIR/${SLUG}-verified.jsonl"
# v0.14.2 Bug Report #4: codex sometimes writes the verdict file to the
# pre-v0.13.0 legacy path despite the prompt instructing otherwise (CWD
# heuristics inside the codex CLI). Track the legacy path so the no-progress
# watcher and the harvest step can both fall back to it before BLOCKing the
# campaign. Auto-migration logic lives in _migrate_legacy_verdict().
LEGACY_VERDICT_FILE="$ROOT/.claude/ralph-desk/memos/${SLUG}-verify-verdict.json"
COMPLETE_SENTINEL="$MEMOS_DIR/${SLUG}-complete.md"
BLOCKED_SENTINEL="$MEMOS_DIR/${SLUG}-blocked.md"
LOCKFILE_PATH="$DESK/logs/.rlp-desk-${SLUG}.lock"
STATUS_FILE="$RUNTIME_DIR/status.json"
SESSION_CONFIG="$RUNTIME_DIR/session-config.json"
WORKER_HEARTBEAT="$RUNTIME_DIR/worker-heartbeat.json"
VERIFIER_HEARTBEAT="$RUNTIME_DIR/verifier-heartbeat.json"
# Feature 2: separate heartbeat for the codex verifier in the 4th (consensus)
# pane when parallel consensus is ON — the claude/codex triggers must not both
# write the single VERIFIER_HEARTBEAT concurrently.
CONSENSUS_HEARTBEAT="$RUNTIME_DIR/consensus-heartbeat.json"
# Feature 2: dedicated evidence-isolation lockdir (mkdir-atomic) so two parallel
# verifiers do not race on DB-mutating / E2E reruns. See _evidence_lock.
CONSENSUS_EVIDENCE_LOCK="$RUNTIME_DIR/evidence.lock"
COST_LOG="$LOGS_DIR/cost-log.jsonl"

# US-004 AC4.2: call site for the t0 launch-breadcrumb writer defined above
# (near STATUS_FILE init, per AC4.2) — LOGS_DIR/SLUG have just resolved.
_write_launch_record_t0

# --- Session Naming ---
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
SESSION_NAME="rlp-desk-${SLUG}-${TIMESTAMP}"

# --- State Tracking ---
typeset -A LAST_PANE_CONTENT
typeset -A PANE_IDLE_SINCE
typeset -A WORKER_RESTARTS
typeset -A US_FAIL_HISTORY
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
_FINALIZE_PENDING=0      # D-16: armed when the last per-US pass completes coverage;
                         # the next loop top synthesizes an ALL verify signal and
                         # skips the (fragile) worker round-trip to emit it.
CONSENSUS_ROUND=0        # current consensus round for current US
US_LIST=""               # comma-separated US IDs from PRD (per-us mode)
LOCKFILE_ACQUIRED=0
LOCK_WORKER_MODEL="${LOCK_WORKER_MODEL:-0}"  # 0|1 — set by --lock-worker-model; disables progressive upgrade
_SAME_US_FAIL_COUNT=0         # consecutive same-US fail counter (upgrade trigger at >= 2)
_LAST_FAILED_US=""            # last failed US ID (same-US tracking for upgrade logic)
_MODEL_UPGRADED=0             # 1 if Worker model was auto-upgraded during campaign
_ORIGINAL_WORKER_MODEL=""     # WORKER_MODEL saved before first upgrade (for restore on pass)
_ORIGINAL_WORKER_CODEX_REASONING=""  # WORKER_CODEX_REASONING saved before first upgrade
# --- Feature 1: leader-side mechanical pre-gate ---
PREGATE_FAILURES=0            # same-US mechanical pre-gate fail counter (SEPARATE from
                             # CONSECUTIVE_FAILURES — a pre-gate fail never touches the CB)
_PREGATE_FAIL_US=""          # US the current PREGATE_FAILURES streak is accumulated for
PREGATE_FAIL_CAP="${PREGATE_FAIL_CAP:-3}"  # same-US pre-gate fails at this count → force one
                             # full LLM verifier round instead of another short-circuit
_validate_int_knob PREGATE_FAIL_CAP 3 1
# --- US-001: leader-side done-claim commit-integrity oracle ---
ORACLE_FAILURES=0            # same-US commit-oracle fail counter (SEPARATE from
                             # CONSECUTIVE_FAILURES and PREGATE_FAILURES)
_ORACLE_FAIL_US=""           # US the current ORACLE_FAILURES streak is accumulated for
ORACLE_FAIL_CAP="${ORACLE_FAIL_CAP:-3}"  # same-US oracle fails at this count → force one
                             # full LLM verifier round (safety valve for a false-positive oracle)
_validate_int_knob ORACLE_FAIL_CAP 3 1
typeset -g ITER_START_HEAD=""  # per-iteration HEAD snapshot (AC1.3); persisted in
                             # status.json + restored on relaunch for the oracle baseline
# --- Feature 2: parallel consensus verification (default OFF) ---
CONSENSUS_PARALLEL="${RLP_CONSENSUS_PARALLEL:-0}"  # 1 = dispatch claude + codex verifiers
                             # concurrently (separate panes); 0 = sequential (unchanged)
CONSENSUS_PANE=""            # 4th pane, created lazily at the first parallel consensus round

# =============================================================================
# Utility Functions
# =============================================================================

DEBUG="${DEBUG:-0}"
DEBUG_LOG="$ANALYTICS_DIR/debug.log"

# Source shared business logic
LIB_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$LIB_DIR/lib_ralph_desk.zsh"

# A16: Warn if running in foreground (may conflict with Claude Code pane)
if [[ -z "${RLP_BACKGROUND:-}" ]]; then
  echo "⚠ WARNING: Running in foreground. This may conflict with Claude Code's pane." >&2
  echo "  Recommended: launch via Bash tool with run_in_background: true" >&2
  echo "  Set RLP_BACKGROUND=1 to suppress this warning." >&2
fi

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

# launch_worker_codex() — launch codex Worker TUI, send instruction, verify submission
# Matches launch_worker_claude() pattern for consistent tmux-visible execution.
# Args: $1=pane_id  $2=prompt_file  $3=iteration  $4=worker_launch_cmd
# Returns: 0 on success, 1 on fatal failure
launch_worker_codex() {
  local pane_id="$1"
  local prompt_file="$2"
  local iter="$3"
  local worker_launch="$4"

  log "  Launching Worker codex TUI in pane $pane_id..."
  # Clean pane before launch: kill any lingering process, ensure fresh shell
  local _pre_cmd
  _pre_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo "")
  if [[ "$_pre_cmd" != "zsh" && "$_pre_cmd" != "bash" && -n "$_pre_cmd" ]]; then
    log_debug "Worker pane has lingering process ($_pre_cmd), cleaning..."
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 0.5
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 1
  fi
  paste_to_pane "$pane_id" "$worker_launch"
  tmux send-keys -t "$pane_id" C-m

  # Wait for codex TUI prompt (› pre-0.144, ❯ from 0.144) instead of shell prompt
  local _codex_ready=0
  local _codex_wait=0
  while (( _codex_wait < 30 )); do
    sleep 1
    local _pane_text
    _pane_text=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
    # F-1: on launch codex may show "✨ Update available!" — an arrow-menu whose
    # DEFAULT highlighted option is "1. Update now" (runs `npm install -g
    # @openai/codex`) with "Press enter to continue". Our subsequent Enter would
    # confirm option 1 and the update REPLACES the Worker session (hijack). This
    # check MUST precede the '›' ready check below because the update menu also
    # renders '›'. Move the selection to "2. Skip" (Down) then confirm (Enter).
    # (Guarded: only fires when the update banner is present, so it is harmless
    # in any normal pane state. Key sequence pending live-codex confirmation.)
    if echo "$_pane_text" | grep -qiE 'Update available|1\. Update now' 2>/dev/null; then
      log "  Worker codex: update prompt detected — selecting '2. Skip' (F-1)."
      log_debug "[GOV] iter=$iter codex_update_prompt=skipped role=worker"
      tmux send-keys -t "$pane_id" Down 2>/dev/null; sleep 0.3
      tmux send-keys -t "$pane_id" C-m 2>/dev/null; sleep 1
      (( _codex_wait++ )); continue
    fi
    # F-16: codex 0.141 shows a "Do you trust the contents of this directory?
    # 1. Yes, continue / 2. No, quit" prompt at startup (project-local config/
    # hooks loading). Its '›' is otherwise mis-read as "ready" below, and the
    # worker instruction sent into that menu can land on "No, quit" → codex exits
    # → "worker not active" BLOCK. Accept it (Enter = default "1. Yes, continue")
    # before the ready check. Validated end-to-end: codex then runs the task.
    if echo "$_pane_text" | grep -qiE 'Do you trust|1\. Yes, continue' 2>/dev/null; then
      log "  Worker codex: directory-trust prompt — accepting (F-16)."
      log_debug "[GOV] iter=$iter codex_trust_prompt=accepted role=worker"
      tmux send-keys -t "$pane_id" C-m 2>/dev/null; sleep 1
      (( _codex_wait++ )); continue
    fi
    if echo "$_pane_text" | grep -qE '[›❯]' 2>/dev/null; then
      _codex_ready=1
      log_debug "Worker codex TUI ready after ${_codex_wait}s"
      break
    fi
    (( _codex_wait++ ))
  done
  if (( ! _codex_ready )); then
    log_error "Worker codex TUI not ready after 30s"
    return 1
  fi

  # Send instruction to codex TUI
  sleep 1
  local worker_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$worker_instruction"
  tmux send-keys -t "$pane_id" C-m
  log_debug "Worker codex instruction sent (${#worker_instruction} chars)"

  # Submit loop — verify codex started working
  local submit_attempts=0
  while (( submit_attempts < 15 )); do
    sleep 2
    local pane_check
    pane_check=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$pane_check" | grep -qi "working\|thinking\|Exploring\|Running\|reading\|searching\|editing\|writing" 2>/dev/null; then
      log_debug "Worker codex started working after $((submit_attempts + 1)) checks"
      break
    fi
    if (( submit_attempts == 8 )); then
      log_debug "Adaptive instruction retry: clearing line and re-typing"
      tmux send-keys -t "$pane_id" C-u 2>/dev/null
      sleep 0.1
      paste_to_pane "$pane_id" "$worker_instruction"
      tmux send-keys -t "$pane_id" C-m
    fi
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    (( submit_attempts++ ))
  done
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
  # request-b seal #2 (same gap as launch_verifier_claude): lingering-process
  # guard so a re-dispatch onto a pane still hosting an idle claude TUI starts a
  # fresh process instead of pasting the shell command into the chat.
  local _pre_cmd
  _pre_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo "")
  if [[ "$_pre_cmd" != "zsh" && "$_pre_cmd" != "bash" && -n "$_pre_cmd" ]]; then
    log_debug "Worker pane has lingering process ($_pre_cmd), cleaning..."
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 0.5
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 1
  fi
  paste_to_pane "$pane_id" "$worker_launch"
  tmux send-keys -t "$pane_id" C-m

  # Wait for claude TUI to be ready
  if ! wait_for_pane_ready "$pane_id" 30; then
    log_error "Worker claude failed to start"
    return 1
  fi

  # Send instruction to claude TUI
  sleep 3
  local worker_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$worker_instruction"
  tmux send-keys -t "$pane_id" C-m
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
      tmux send-keys -t "$pane_id" C-m
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
    tmux send-keys -t "$pane_id" "/exit" C-m 2>/dev/null
    sleep 2
    wait_for_pane_ready "$pane_id" 10 2>/dev/null || true
    paste_to_pane "$pane_id" "$worker_launch"
    tmux send-keys -t "$pane_id" C-m
    if wait_for_pane_ready "$pane_id" 30; then
      sleep 3
      paste_to_pane "$pane_id" "$worker_instruction"
      tmux send-keys -t "$pane_id" C-m
      log "  Worker restarted and instruction re-sent"
      log_debug "[FLOW] iter=$iter worker_restart_recovery=success"
    else
      log_error "Worker restart failed — pane not ready"
      log_debug "[FLOW] iter=$iter worker_restart_recovery=failed"
    fi
  fi

  return 0
}

# launch_verifier_codex() — launch codex Verifier TUI, send instruction, verify submission
# Matches launch_verifier_claude() pattern for consistent tmux-visible execution.
# Args: $1=pane_id  $2=prompt_file  $3=iteration  $4=launch_cmd
# Returns: 0 on success
launch_verifier_codex() {
  local pane_id="$1"
  local prompt_file="$2"
  local iter="$3"
  local verifier_launch="$4"

  log "  Launching Verifier codex TUI in pane $pane_id..."
  # Clean pane before launch: kill any lingering process, ensure fresh shell
  local _pre_cmd
  _pre_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo "")
  if [[ "$_pre_cmd" != "zsh" && "$_pre_cmd" != "bash" && -n "$_pre_cmd" ]]; then
    log_debug "Verifier pane has lingering process ($_pre_cmd), cleaning..."
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 0.5
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 1
  fi
  paste_to_pane "$pane_id" "$verifier_launch"
  tmux send-keys -t "$pane_id" C-m

  # Wait for codex TUI prompt (› pre-0.144, ❯ from 0.144) instead of shell prompt
  local _codex_ready=0
  local _codex_wait=0
  while (( _codex_wait < 30 )); do
    sleep 1
    local _pane_text
    _pane_text=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
    # F-1: dismiss codex's "✨ Update available!" launch menu before it hijacks the
    # pane (default option is "1. Update now"). See launch_worker_codex for detail.
    if echo "$_pane_text" | grep -qiE 'Update available|1\. Update now' 2>/dev/null; then
      log "  Verifier codex: update prompt detected — selecting '2. Skip' (F-1)."
      log_debug "[GOV] iter=$iter codex_update_prompt=skipped role=verifier"
      tmux send-keys -t "$pane_id" Down 2>/dev/null; sleep 0.3
      tmux send-keys -t "$pane_id" C-m 2>/dev/null; sleep 1
      (( _codex_wait++ )); continue
    fi
    # F-16: accept codex 0.141's "Do you trust this directory?" startup prompt
    # (Enter = default "1. Yes, continue") before the ready check — see
    # launch_worker_codex for detail. Otherwise the instruction lands in the menu
    # and can select "No, quit" → codex exits → "verifier not active".
    if echo "$_pane_text" | grep -qiE 'Do you trust|1\. Yes, continue' 2>/dev/null; then
      log "  Verifier codex: directory-trust prompt — accepting (F-16)."
      log_debug "[GOV] iter=$iter codex_trust_prompt=accepted role=verifier"
      tmux send-keys -t "$pane_id" C-m 2>/dev/null; sleep 1
      (( _codex_wait++ )); continue
    fi
    if echo "$_pane_text" | grep -qE '[›❯]' 2>/dev/null; then
      _codex_ready=1
      log_debug "Verifier codex TUI ready after ${_codex_wait}s"
      break
    fi
    (( _codex_wait++ ))
  done
  if (( ! _codex_ready )); then
    log_error "Verifier codex TUI not ready after 30s"
    return 1
  fi

  sleep 1
  local verifier_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$verifier_instruction"
  tmux send-keys -t "$pane_id" C-m
  log_debug "Verifier codex instruction sent"

  # Submit loop — verify codex started working
  local submit_attempts=0
  while (( submit_attempts < 15 )); do
    sleep 2
    local vs_check
    vs_check=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)
    if echo "$vs_check" | grep -qi "working\|thinking\|Exploring\|Running\|reading\|searching\|editing\|writing" 2>/dev/null; then
      log_debug "Verifier codex started working after $((submit_attempts + 1)) checks"
      break
    fi
    if (( submit_attempts == 8 )); then
      log_debug "Adaptive instruction retry: clearing line and re-typing"
      tmux send-keys -t "$pane_id" C-u 2>/dev/null
      sleep 0.1
      paste_to_pane "$pane_id" "$verifier_instruction"
      tmux send-keys -t "$pane_id" C-m
    fi
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    sleep 0.3
    tmux send-keys -t "$pane_id" C-m 2>/dev/null
    (( submit_attempts++ ))
  done
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
  # request-b seal #2: lingering-process guard (mirrors launch_worker_codex /
  # launch_verifier_codex). Without it, a submit-anchored RE-DISPATCH lands on a
  # pane still hosting the previous idle claude TUI — the shell launch string is
  # then pasted INTO the claude chat as a user message (corrupting the verifier)
  # instead of starting a fresh process. Fires exactly in the banner-delay case
  # the re-dispatch exists to recover.
  local _pre_cmd
  _pre_cmd=$(tmux display-message -p -t "$pane_id" '#{pane_current_command}' 2>/dev/null || echo "")
  if [[ "$_pre_cmd" != "zsh" && "$_pre_cmd" != "bash" && -n "$_pre_cmd" ]]; then
    log_debug "Verifier pane has lingering process ($_pre_cmd), cleaning..."
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 0.5
    tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 1
  fi
  paste_to_pane "$pane_id" "$verifier_launch"
  tmux send-keys -t "$pane_id" C-m

  if ! wait_for_pane_ready "$pane_id" 30; then
    log_error "Verifier failed to start"
    return 1
  fi

  sleep 3
  local verifier_instruction="Read and execute the instructions in $prompt_file"
  paste_to_pane "$pane_id" "$verifier_instruction"
  tmux send-keys -t "$pane_id" C-m
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
      tmux send-keys -t "$pane_id" C-m
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
# F-14: _append_verified_ledger moved to lib_ralph_desk.zsh (v0.22.3 US-001)
# and extended with a commit-SHA anchor + append-then-lock; the ALL completion
# record writer (_append_verified_ledger_all) and derive_verification_mode
# live alongside it there.

# ② F-8 auto-commit robustness (request-b): stage + commit the Worker's OWN
# uncommitted files, tolerating a campaign-artifact path that lives under a
# .gitignore rule (evidence dirs like test-results/ are force-tracked by repo
# convention, so a NEW receipt/screenshot there makes a plain `git add` refuse
# with "paths ignored by one of your .gitignore files"). Try a normal `git add`
# first; ONLY if that fails retry `git add -f`, STRICTLY limited to the same
# already-scoped worker-file list (never `-A`, never a broadened path) — the list
# was already narrowed to exclude CAMPAIGN_PREEXISTING_DIRTY upstream, so a
# force-add cannot sweep an operator's or non-campaign file. Returns 0 when the
# work is committed, 1 when add/commit could not complete (caller downgrades to
# warn+carryover+continue, NOT a hard BLOCK — the Verifier is the real gate).
_bug8_autocommit() {
  local root="$1" msg="$2"; shift 2
  local -a files=("$@")
  (( ${#files} == 0 )) && return 1
  # --literal-pathspecs (global flag; NOTE: there is no core.literalPathspecs
  # config key — `-c` would be silently ignored): the list comes verbatim from
  # `git diff --name-only`, so a file whose NAME contains a glob metacharacter
  # (`*`, `?`, `[`) must not re-glob at add time — without this, `add -f -- '*'`
  # would sweep the entire tree (operator preexisting-dirty + gitignored files)
  # past the comm scoping.
  if ! git --literal-pathspecs -C "$root" add -- "${files[@]}" 2>/dev/null; then
    # An ignored campaign-artifact path made the plain add refuse. Force-add, but
    # ONLY the pre-scoped worker files — same list, never broadened.
    git --literal-pathspecs -C "$root" add -f -- "${files[@]}" 2>/dev/null || return 1
  fi
  git -C "$root" commit -q -m "$msg" 2>/dev/null || return 1
  return 0
}

# ② F-8 carryover (request-b): when the leader-recovery auto-commit cannot
# complete even with a scoped force-add, the Worker's uncommitted file list is
# appended here so the NEXT worker fix contract re-commits it (write_worker_trigger
# injects then consumes this record). This exists so an unrecoverable git state is
# a graceful continue, not a campaign-killing BLOCK.
_bug8_carryover_file() { print -r -- "${BUG8_CARRYOVER_FILE:-$LOGS_DIR/bug8-carryover.txt}"; }
_bug8_record_carryover() {
  local us_id="$1" files="$2"
  [[ -n "$files" ]] || return 0
  local dest; dest=$(_bug8_carryover_file)
  {
    echo "# us_id=$us_id uncommitted at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '%s\n' "$files"
  } >> "$dest" 2>/dev/null || true
}

# Bug #8 PR-B (codex critic P1.2 fix): shared 4-way gate used by both
# handle_worker_exit_codex and the inline-polling A4 path. Returns:
#   0 = synthesize allowed (caller writes signal_file + emits audit)
#   1 = BLOCKED (this function already wrote sentinel + emitted audit)
# Args: $1=iter  $2=us_id  $3=audit_clean_code (e.g. codex_exit_with_done_claim
#       or inline_polling_a4_clean)
_bug8_check_synth_allowed() {
  local iter="$1"
  local us_id="${2:-${CURRENT_US:-ALL}}"
  local audit_clean="$3"

  # Gate 1: done-claim must exist.
  if [[ ! -f "$DONE_CLAIM_FILE" ]]; then
    log_error "  Bug #8: no done-claim. Refusing to synthesize verify signal."
    log_debug "[GOV] iter=$iter bug8=block_codex_exit_no_done_claim"
    write_blocked_sentinel \
      "Codex worker exited without writing done-claim (refusing to synthesize verify signal)" \
      "$us_id" \
      "infra_failure"
    _emit_a4_fallback_audit "$us_id" "$iter" "blocked_codex_exit_no_done_claim"
    return 1
  fi

  # Gate 1b (D-2): done-claim FRESHNESS. A done-claim that lingered from a PRIOR
  # run/iteration (e.g. a relaunch where the inter-iteration cleanup did not run)
  # must NOT be synthesized into a verify signal for THIS iteration — it would
  # credit a stale/wrong US into the durable ledger. The Worker writes its
  # done-claim DURING this iteration, so a fresh claim is strictly NEWER than this
  # iteration's worker-prompt; an older claim is stale. mtime-based on purpose:
  # done-claim carries no reliable .iteration field (workers omit it), so an
  # iteration match would false-reject every claim and break the A4 synth path.
  local _dc_wp_file="$LOGS_DIR/iter-$(printf '%03d' "$iter").worker-prompt.md"
  if [[ -f "$_dc_wp_file" ]]; then
    # mtime, cross-platform: GNU `stat -c %Y` FIRST (on Linux `stat -f %m` means
    # --file-system + %m=mount-point, returns a non-numeric path with exit 0 so a
    # `-f`-first order would silently mis-read); macOS BSD `stat -c` errors → falls
    # through to `stat -f %m` (the BSD mtime). Correct on both; `echo 0` = unknown.
    local _dc_mt _wp_mt
    _dc_mt=$(stat -c %Y "$DONE_CLAIM_FILE" 2>/dev/null || stat -f %m "$DONE_CLAIM_FILE" 2>/dev/null || echo 0)
    _wp_mt=$(stat -c %Y "$_dc_wp_file" 2>/dev/null || stat -f %m "$_dc_wp_file" 2>/dev/null || echo 0)
    [[ "$_dc_mt" == <-> ]] || _dc_mt=0   # guard: ignore any non-numeric stat output
    [[ "$_wp_mt" == <-> ]] || _wp_mt=0
    if (( _dc_mt > 0 && _wp_mt > 0 && _dc_mt < _wp_mt )); then
      log_error "  Bug #8: done-claim is STALE (mtime $_dc_mt < this iteration's worker-prompt $_wp_mt) — refusing to synthesize from a prior-run claim."
      log_debug "[GOV] iter=$iter bug8=block_stale_done_claim dc_mt=$_dc_mt wp_mt=$_wp_mt"
      write_blocked_sentinel \
        "done-claim is stale (older than this iteration's worker dispatch) — refusing to synthesize a verify signal from a prior-run claim" \
        "$us_id" \
        "infra_failure"
      _emit_a4_fallback_audit "$us_id" "$iter" "blocked_stale_done_claim"
      return 1
    fi
  fi

  # Gate 2: git toplevel must equal $ROOT (canonicalized — macOS resolves
  # /var → /private/var, NTFS may have 8.3 short paths; compare realpaths).
  local _bug8_top _bug8_top_canon _bug8_root_canon
  _bug8_top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)
  _bug8_top_canon=$(cd "$_bug8_top" 2>/dev/null && pwd -P 2>/dev/null)
  _bug8_root_canon=$(cd "$ROOT" 2>/dev/null && pwd -P 2>/dev/null)
  if [[ -z "$_bug8_top" || "$_bug8_top_canon" != "$_bug8_root_canon" ]]; then
    log_error "  Bug #8: git unverifiable at \$ROOT=$ROOT (toplevel='$_bug8_top'). Refusing synthesis."
    log_debug "[GOV] iter=$iter bug8=block_git_unverifiable root=$ROOT toplevel=$_bug8_top"
    write_blocked_sentinel \
      "git status unverifiable at $ROOT (toplevel='$_bug8_top'); refusing to synthesize verify signal" \
      "$us_id" \
      "infra_failure"
    _emit_a4_fallback_audit "$us_id" "$iter" "blocked_git_unverifiable"
    return 1
  fi

  # Gate 3: no UNCOMMITTED changes to TRACKED files (F-6 fix). We compare against
  # HEAD with `git diff --name-only HEAD`, which lists ONLY tracked files modified
  # vs HEAD — untracked cruft (logs, .DS_Store, local config, build/coverage
  # output) the Worker never touched is never listed. Blocking on such cruft
  # false-BLOCKed the campaign at iter 1 on ANY non-pristine repo — the single
  # largest "never completes" cause found in large-campaign dogfood. The Verifier
  # (test-spec) is the real correctness gate for the Worker's committed work; this
  # gate only guards against a Worker that left TRACKED edits uncommitted.
  local _bug8_dirty
  # NEW-4: diff against HEAD, or git's empty-tree when the repo has no commits yet,
  # so a Worker that staged-but-never-committed its work is still detected here.
  _bug8_dirty=$(git -C "$ROOT" diff --name-only "$(_git_dirty_base)" 2>/dev/null)
  if [[ -n "$_bug8_dirty" ]]; then
    # F-8 recovery (F-19 scoped): by Gate 1 a done-claim exists, so uncommitted
    # TRACKED changes are most likely the Worker's own US work it failed to commit
    # — a frequent weak-model slip (the default haiku Worker reports "Committed ..."
    # in its done-claim while the git commit never landed). Historically this
    # TERMINATED the campaign, stranding completed work — the #1 weak-model "never
    # completes" cause. Instead auto-commit the Worker's edits and proceed — but
    # scope the commit to the Worker's OWN files: exclude any tracked file ALREADY
    # dirty before the campaign (CAMPAIGN_PREEXISTING_DIRTY) so an operator's
    # pre-existing uncommitted work is NEVER swept into a Worker-recovery commit.
    # The Verifier (test-spec) is the real correctness gate, so a genuine mid-write
    # bail still FAILs verify → fix loop; Bug #8's "no false PASS" intent is
    # preserved by the Verifier, not by abort.
    # NEW-4 base-drift note (codex re-review): CAMPAIGN_PREEXISTING_DIRTY is captured
    # once in main() BEFORE the loop / any Worker dispatch, so WITHIN A SINGLE LEADER
    # PROCESS it holds only operator pre-existing files — no Worker file is in it, and
    # the within-process empty-tree→HEAD base transition (no-HEAD repo gets its first
    # commit mid-run) cannot drop a real Worker file. (Caveat, PRE-EXISTING and
    # unchanged by NEW-4: on a RELAUNCH the snapshot is re-captured at the new
    # process start, so a prior segment's uncommitted file lands in it and is
    # excluded — that file is then re-done/committed by the fresh-context Worker, so
    # it is benign; and on relaunch HEAD already exists, so NEW-4's empty-tree path is
    # not even taken. Tracked as D-25 report-only, not a NEW-4 regression.)
    local _bug8_worker_files
    _bug8_worker_files=$(comm -23 \
      <(printf '%s\n' "$_bug8_dirty" | sort -u) \
      <(printf '%s\n' "${CAMPAIGN_PREEXISTING_DIRTY:-}" | sort -u) \
      | grep -v '^[[:space:]]*$')
    if [[ -z "$_bug8_worker_files" ]]; then
      # Every dirty tracked file was already dirty BEFORE the campaign — the Worker
      # committed its own work (or made no tracked change). Nothing to recover; do
      # NOT commit the operator's pre-existing edits. Allow synthesis to proceed.
      log "  Bug #8 F-8: only operator's pre-existing edits are dirty — Worker work already committed; proceeding without auto-commit."
      log_debug "[GOV] iter=$iter bug8=preexisting_only_no_commit us_id=$us_id"
    else
      local _bug8_first5
      _bug8_first5=$(printf '%s\n' "$_bug8_worker_files" | head -n 5 | tr '\n' '|' | sed 's/|$//')
      log "  Bug #8 F-8 recovery: done-claim + Worker's uncommitted tracked changes — auto-committing $us_id work (files: $_bug8_first5)."
      log_debug "[GOV] iter=$iter bug8=recover_autocommit us_id=$us_id files='$_bug8_first5'"
      local -a _bug8_add=("${(@f)_bug8_worker_files}")
      # D-20 (codex LOW): fail-safe on an empty file list. The upstream
      # `[[ -z "$_bug8_worker_files" ]]` guard already makes this unreachable, but
      # never let an empty array turn `git diff --quiet HEAD --` into a whole-tree
      # check (which could falsely read "already committed" → false PASS). BLOCK.
      if (( ${#_bug8_add} == 0 )); then
        log_error "  Bug #8: empty worker-file list at auto-commit (unexpected) — refusing synthesis."
        write_blocked_sentinel "worker_incomplete_uncommitted: empty file list at auto-commit" "$us_id" "metric_failure"
        return 1
      fi
      if git -C "$ROOT" diff --quiet HEAD -- "${_bug8_add[@]}" 2>/dev/null; then
        # D-20: the Worker committed these files itself in the window between the
        # dirty-detection above and now (a reap/commit race) — the working tree is
        # already clean vs HEAD for them, i.e. the work IS committed. The old code
        # ran `git add … && git commit`, which exited non-zero ("nothing to commit")
        # and BLOCKED a correct, fully-committed campaign. Treat "already committed"
        # as success: proceed to synthesis (the Verifier still gates correctness).
        log "  Bug #8 F-8 (D-20): Worker files already committed (commit race) — nothing to auto-commit; proceeding."
        log_debug "[GOV] iter=$iter bug8=autocommit_noop_already_committed us_id=$us_id files='$_bug8_first5'"
      elif _bug8_autocommit "$ROOT" "chore(leader-recovery): commit Worker's uncommitted $us_id changes (Bug #8 F-8)" "${_bug8_add[@]}"; then
        log "  Leader-recovery auto-commit OK (Worker files only) — Verifier will gate correctness."
      else
        # ② request-b: the auto-commit could not complete even with a scoped
        # `git add -f` (a genuinely unwritable index / broken git state). A new
        # campaign-artifact under a gitignored evidence path is now recoverable
        # via the force-add above, so reaching here means an infra-level git
        # failure — which must NOT hard-BLOCK a campaign whose work is otherwise
        # done. Warn loudly, carry the uncommitted list into the next Worker fix
        # contract, and proceed to synthesis: the Verifier remains the
        # completeness gate (it FAILs on missing/uncommitted deliverables → fix
        # loop), so "no false PASS" is preserved without killing the run.
        log_error "  Bug #8 F-8: leader-recovery auto-commit could NOT complete even with a scoped force-add — proceeding WITHOUT commit; carrying files to the next fix contract (Verifier remains the completeness gate). Uncommitted: $_bug8_first5"
        log_debug "[GOV] iter=$iter bug8=autocommit_failed_continue us_id=$us_id files='$_bug8_first5'"
        _bug8_record_carryover "$us_id" "$_bug8_worker_files"
      fi
    fi
  fi

  # All gates passed — synthesize allowed.
  return 0
}

handle_worker_exit_codex() {
  local iter="$1"
  local signal_file="$2"

  log "  Codex worker process exited. Checking for done-claim + clean tree..."

  if ! _bug8_check_synth_allowed "$iter" "${CURRENT_US:-ALL}" "codex_exit_with_done_claim"; then
    return 1
  fi

  # All 3 gates passed: done-claim present, git OK, tree clean → synthesize.
  local dc_us_id
  dc_us_id=$(jq -r '.us_id // "unknown"' "$DONE_CLAIM_FILE" 2>/dev/null)
  log "  Codex worker completed with done-claim (us_id=$dc_us_id) and clean tree. Auto-generating signal."
  # codex round 3: was a plain `>` redirect — the ONE monitored-file write in
  # the codebase that did not funnel through atomic_write, so it got no
  # lifecycle lock-mark clearing and no F-26 truncated-write protection.
  # Switched to atomic_write for both: tmp+mv is safe against a mid-write
  # crash, and it now clears any pending SIGNAL_FILE lock-mark automatically.
  echo '{"iteration":'"$iter"',"status":"verify","us_id":"'"$dc_us_id"'","summary":"auto-generated after codex exit (clean tree)","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' | atomic_write "$signal_file"
  # v0.15.4 PR-B2-FIX: codex worker pane already exited — reaper would no-op,
  # but lock done-claim as defense-in-depth so any orphaned subprocess cannot
  # rewrite the file before lib_ralph_desk.zsh:602 archives it.
  # codex P2 sweep F3: no adjacent mark (H2 exclusion) — return code unused, explicit.
  _lock_sentinel "$DONE_CLAIM_FILE" || true
  _emit_a4_fallback_audit "$dc_us_id" "$iter" "codex_exit_with_done_claim_clean"
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
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$CONSENSUS_MODE" != "off" ]]; then
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
  if [[ "$WORKER_ENGINE" = "codex" || "$VERIFIER_ENGINE" = "codex" || "$CONSENSUS_MODE" != "off" ]]; then
    CODEX_BIN=$(command -v codex 2>/dev/null || echo "codex")
    log "  Codex binary:  $CODEX_BIN"
  fi
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
    # US-025 R13 P0: verify tmux new-session exit code; if collision + RLP_BACKGROUND,
    # disambiguate with -bg-<epoch>-<pid> suffix and a residual has-session loop.
    if ! tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$ROOT" 2>/dev/null; then
      if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
        if [[ "${RLP_BACKGROUND:-0}" == "1" ]]; then
          SESSION_NAME="${SESSION_NAME}-bg-$(date +%s)-$$"
          while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
            SESSION_NAME="${SESSION_NAME}-$(awk 'BEGIN{srand();print int(1000+rand()*9000)}')"
          done
          tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$ROOT" || {
            log_error "tmux new-session retry failed for $SESSION_NAME"
            exit 1
          }
        else
          log_error "tmux new-session failed: session $SESSION_NAME already exists (set RLP_BACKGROUND=1 to auto-rename)"
          exit 1
        fi
      else
        log_error "tmux new-session failed and session does not exist: $SESSION_NAME"
        exit 1
      fi
    fi
    # destroy-unattached off keeps the session alive when no tmux client is attached.
    # Best-effort only: it does NOT survive manual `tmux kill-session` or tmux server restart.
    # If either happens, R12 (lifecycle monitor) detects it and writes infra_failure BLOCKED.
    if [[ "${RLP_BACKGROUND:-0}" == "1" ]]; then
      tmux set-option -t "$SESSION_NAME" destroy-unattached off 2>/dev/null
    fi
    LEADER_PANE=$(tmux display-message -p -t "$SESSION_NAME" '#{pane_id}')
    WORKER_PANE=$(tmux split-window -h -d -t "$LEADER_PANE" -P -F '#{pane_id}' -c "$ROOT")
    VERIFIER_PANE=$(tmux split-window -v -d -t "$WORKER_PANE" -P -F '#{pane_id}' -c "$ROOT")

  fi

  # Set pane titles and enable border labels for visual distinction
  local worker_label="Worker ($WORKER_ENGINE:$WORKER_MODEL)"
  local verifier_label="Verifier ($VERIFIER_ENGINE:$VERIFIER_MODEL)"
  [[ "$CONSENSUS_MODE" != "off" ]] && verifier_label="Verifier ($VERIFIER_ENGINE:$VERIFIER_MODEL + consensus)"
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

  # US-024 R12 P0: lifecycle check site #1 — verify all panes/session alive after creation.
  _r12_check_lifecycle "create_session"

  # AC12: Capture baseline commit before writing session config
  BASELINE_COMMIT=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "none")

  # Truncate cost-log for fresh run (previous data in versioned campaign reports)
  # NOTE: ': >' not bare '>' — in zsh a bare redirect with no command runs $NULLCMD
  # (=cat), which blocks reading stdin when the leader has an open TTY (D-1 dogfood hang).
  : > "$COST_LOG"

  # v5.7 §4.2: WITH_SELF_VERIFICATION=1 is hard-rejected at script entry now,
  # so by the time we reach create_session() the flag is guaranteed to be 0.
  # The legacy "NOTE: Agent-mode only; disabling" log line was removed because
  # the deprecation banner at startup is more honest (we exit 2, we don't
  # silently disable).

  # Feature 1/2: record whether a mechanical pre-gate is present and whether
  # parallel consensus is enabled (campaign-start config snapshot).
  local _pregate_state="absent"
  [[ -f "$DESK/plans/pregate-${SLUG}.sh" ]] && _pregate_state="enabled"
  local _consensus_parallel_state="false"
  (( CONSENSUS_PARALLEL )) && _consensus_parallel_state="true"

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
    "consensus_mode": "'"$CONSENSUS_MODE"'",
    "consensus_parallel": '"$_consensus_parallel_state"',
    "pregate": "'"$_pregate_state"'"
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
    "with_self_verification": '"$WITH_SELF_VERIFICATION"',
    "with_self_verification_requested": '"$WITH_SELF_VERIFICATION_REQUESTED"',
    "sv_skipped_reason": "'"$SV_SKIPPED_REASON"'",
    "lane_mode": "'"$LANE_MODE"'",
    "autonomous_mode": '"$AUTONOMOUS_MODE"'
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

# --- Reliable text paste via tmux buffer (avoids send-keys -l char-by-char issues) ---
paste_to_pane() {
  local pane_id="$1"
  local text="$2"
  # D-8/D-13: per-leader+pane tmux buffer name (was a server-GLOBAL "rlp-paste").
  # Two leaders sharing one tmux server (different ROOTs) would ABA the single
  # global buffer — load-A / load-B / paste-A pastes B's text into A's pane. A
  # name keyed by leader pid + pane closes that.
  local _buf="rlp-paste-$$-${pane_id//[^0-9A-Za-z]/}"
  # IMP-09: never write the prompt to a predictable world-readable /tmp file
  # (`/tmp/.rlp-desk-paste-$$.tmp` was PID-predictable, umask-perm'd, and
  # followed a pre-planted symlink — a content leak + clobber vector on shared
  # hosts, on the hot path of every dispatch). Prefer piping via `tmux
  # load-buffer -` (stdin, no temp file). Probe once (cached) since the stdin
  # form is standard but has no floor guarantee here.
  if [[ -z "${_RLP_TMUX_STDIN_OK:-}" ]]; then
    if printf '' | tmux load-buffer -b __rlp_probe - 2>/dev/null; then
      tmux delete-buffer -b __rlp_probe 2>/dev/null
      _RLP_TMUX_STDIN_OK=1
    else
      _RLP_TMUX_STDIN_OK=0
    fi
    typeset -g _RLP_TMUX_STDIN_OK
  fi
  if (( _RLP_TMUX_STDIN_OK )); then
    print -rn -- "$text" | tmux load-buffer -b "$_buf" - 2>/dev/null
  else
    # Fallback: 0600 mktemp with INLINE cleanup (used synchronously here). Do
    # NOT install an EXIT trap — that would overwrite the runner's global
    # `_emit_final_cost_log; cleanup` EXIT trap (codex B2).
    local tmpbuf
    tmpbuf=$(mktemp "${TMPDIR:-/tmp}/.rlp-desk-paste.XXXXXX") || return 1
    print -rn -- "$text" > "$tmpbuf"
    tmux load-buffer -b "$_buf" "$tmpbuf" 2>/dev/null
    rm -f "$tmpbuf"
  fi
  tmux paste-buffer -b "$_buf" -d -t "$pane_id" 2>/dev/null   # -d deletes the buffer after paste
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
    tmux send-keys -t "$pane_id" C-m
    sleep 0.3
  fi
  # Auto-dismiss codex update prompt (select Skip)
  if echo "$initial_capture" | grep -qi "new version\|update.*codex\|codex.*update" 2>/dev/null; then
    log_debug " Codex update prompt detected, selecting Skip"
    tmux send-keys -t "$pane_id" "2" C-m
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
      tmux send-keys -t "$pane_id" C-m
      sleep 0.12
      tmux send-keys -t "$pane_id" C-m
      sleep 2
      continue
    fi

    # Auto-approve permission prompts ("Do you want to create/overwrite X?")
    if echo "$captured" | grep -q "Do you want to" 2>/dev/null; then
      log "  Permission prompt detected, auto-approving..."
      tmux send-keys -t "$pane_id" C-m
      sleep 0.5
      continue
    fi

    # Auto-dismiss codex update prompt (select Skip = option 2)
    if echo "$captured" | grep -qi "new version\|update.*codex\|codex.*update" 2>/dev/null; then
      log "  Codex update prompt detected, selecting Skip..."
      tmux send-keys -t "$pane_id" "2" C-m
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

# --- v5.7 §4.13.a: Mid-execution permission-prompt auto-dismiss (Bug 4 fix) ---
# claude CLI v2.1.114+ surfaces TUI-layer prompts ("Do you want to create...")
# even with --dangerously-skip-permissions on certain Write paths. Without this
# helper, Workers/Verifiers hang until IDLE_NUDGE_THRESHOLD timeout.
#
# Window-bounded match (codex Critic v5.7): require both a prompt phrase AND a
# TUI affordance marker on the SAME, PREVIOUS, or NEXT line. Whole-capture dual
# grep would let unrelated text trigger Enter (R-V5-9 false-positive).
# Per-pane 3-second debounce prevents rapid double-Enter.
zmodload zsh/datetime 2>/dev/null || true
_now_s() { print -- "${EPOCHSECONDS:-$(date +%s)}"; }

typeset -gA LAST_AUTO_APPROVE_TS
# v5.7 §4.16: track when each pane FIRST entered a prompt-stuck state.
# Cleared on first capture without prompt visible. Used for bounded
# prompt-stall escalation (BLOCKED `prompt_stall`) so alive-but-stuck
# Workers can't infinite-wait (codex Critic HIGH finding).
typeset -gA PANE_PROMPT_STUCK_SINCE
typeset -gA PANE_DISMISS_FAILED_COUNT
PROMPT_STALL_TIMEOUT="${PROMPT_STALL_TIMEOUT:-300}"  # 5 min default
PROMPT_DISMISS_FAIL_LIMIT="${PROMPT_DISMISS_FAIL_LIMIT:-20}"  # ~100s of fruitless dismiss attempts
_validate_int_knob PROMPT_STALL_TIMEOUT 300 1      # D-19
_validate_int_knob PROMPT_DISMISS_FAIL_LIMIT 20 1  # D-19

# v5.7 §4.17: generic no-progress timeout (codex Critic HIGH — closes the gap
# where an undetected prompt or alive-but-frozen Worker bypasses Layer 4).
# Independent of prompt detection: if pane content stops changing for this many
# seconds AND signal file still missing, write BLOCKED `infra_failure` reason
# `worker_no_progress` so silent infinite-wait is impossible.
PROGRESS_NO_CHANGE_TIMEOUT="${PROGRESS_NO_CHANGE_TIMEOUT:-600}"  # 10 min default
_validate_int_knob PROGRESS_NO_CHANGE_TIMEOUT 600 1  # D-19
typeset -gA PANE_LAST_CHANGE_TS  # epoch when content last changed
typeset -gA PANE_LAST_CONTENT_FOR_PROGRESS  # captured content for diff

# v0.14.1: codex post-work idle UI grace. When a verifier pane shows codex's
# "Worked for Xm Ys" idle line at byte-stasis time, grant one extra
# CODEX_IDLE_GRACE_S (default 120s) before BLOCK. Per-pane bookkeeping to
# avoid granting it repeatedly. Bug Report #3 (BOS 2026-05-04).
CODEX_IDLE_GRACE_S="${CODEX_IDLE_GRACE_S:-120}"
_validate_int_knob CODEX_IDLE_GRACE_S 120 1  # D-19
typeset -gA PANE_CODEX_IDLE_GRACED
# v0.14.2: per-verifier-pane trace flag — log the verdict-lookup outcome
# exactly once per byte-stasis transition. Bug Report #4 (BOS 2026-05-05).
typeset -gA PANE_VERIFIER_TRACE_LOGGED

# v5.7 §4.17: default-No prompt detection. Pressing Enter on these means
# CANCEL/REJECT, not approve — so we BLOCK with traceability instead of
# silently auto-dismissing the wrong way.
typeset -g _DEFAULT_NO_RE='\[y/N\]|\(yes/no, default no\)|default[: ]+no|^[[:space:]]*N\)'

# v5.7 §4.16: broadened prompt detection (codex Critic MEDIUM).
# v5.7 §4.20 (E2E real-claude-CLI finding): claude v2.1.114+ uses new trust
# prompt format ("Quick safety check: Is this a project you ... trust?")
# and a numbered picker with `❯` cursor adjacent to the digit ("❯1.Yes").
# Old patterns ("Do you trust") missed it entirely → Worker hung 5min until
# iter-timeout. Adds: Quick safety check|trust this (folder|directory) for
# PROMPT_RE; ❯\s*\d+\. (zero-or-more space) and `Enter to confirm` / `1\.
# (Yes|No)` for AFFORDANCE_RE.
typeset -g _PROMPT_RE='Do you (want to|trust)|Confirm execution|Are you sure|Continue\?|Proceed\?|Allow this|Approve this|Press y to|Choose an option|Select \[|Quick safety check|trust this (folder|directory)|Is this a project you'
typeset -g _AFFORDANCE_RE='\(y/n\)|\[Y/n\]|\[y/N\]|\(yes/no|❯[[:space:]]*[0-9]+\.|(^|[[:space:]])1\) (Yes|No)|(^|[[:space:]])[YyNn]\)|press (y|enter) to|Enter to confirm'

# v5.7 §4.18 (E2E real-tmux + omc benchmarking): "active task" markers used
# to distinguish a Worker that is busy producing output (and may legitimately
# print "(y/n)" inside its body text) from a Worker that is *idle at an
# unrecognized prompt*. Mirrors omc-team's `paneHasActiveTask` heuristic
# (src/team/tmux-session.ts:659). When ANY of these markers is in the recent
# pane tail, the Worker is alive — auto_dismiss must NOT fast-fail on a
# suspected-unknown prompt because the affordance text is just transcript.
typeset -g _ACTIVE_TASK_RE='esc to interrupt|background terminal running|^[[:space:]]*[·✻][[:space:]]+[A-Za-z]+(\.{3}|…)'

auto_dismiss_prompts() {
  local pane_id="$1"
  local now
  now=$(_now_s)
  local last=${LAST_AUTO_APPROVE_TS[$pane_id]:-0}

  local capture
  # v5.7 §4.21 (E2E real-claude-CLI finding): claude v2.x trust prompt wraps
  # to ~30 lines on narrow panes. -S -10 missed the question header. -50
  # covers the full prompt.
  capture=$(tmux capture-pane -t "$pane_id" -p -S -50 2>/dev/null) || return 0

  # v5.7 §4.21 (E2E real-claude-CLI finding): claude v2.x trust prompt is
  # multi-line and wraps narrowly, so per-line PROMPT_RE+AFFORDANCE adjacency
  # misses it. Special-case the signature ("Quick safety check ... Enter to
  # confirm" with `❯N.Yes` cursor on option 1). This is default-Yes — Enter
  # approves trust.
  # §4.21.b: tmux narrow-pane wrap breaks the question phrase across lines
  # (`Quick safety\n check`). Normalize all whitespace to single spaces so
  # substring matching works regardless of pane width.
  local _norm_capture="${capture//[$'\n\r\t']/ }"
  while [[ "$_norm_capture" == *"  "* ]]; do _norm_capture="${_norm_capture//  / }"; done
  if { [[ "$_norm_capture" == *"Quick safety check"* ]] || [[ "$_norm_capture" == *"trust this folder"* ]] || [[ "$_norm_capture" == *"trust this directory"* ]]; } \
     && [[ "$_norm_capture" == *"Enter to confirm"* ]] \
     && [[ "$_norm_capture" =~ '❯ ?[0-9]+\. ?Yes' ]]; then
    if (( now - last >= 3 )); then
      log "  Claude v2.x trust prompt detected in pane $pane_id, auto-approving (Enter)"
      log_debug "[FLOW] claude_trust_prompt_auto_approved=true pane=$pane_id"
      tmux send-keys -t "$pane_id" Enter 2>/dev/null
      LAST_AUTO_APPROVE_TS[$pane_id]=$now
    fi
    return 0
  fi
  # Older claude trust prompt format (omc-team parity).
  if [[ "$_norm_capture" == *"Do you trust the contents of this directory"* ]] \
     && { [[ "$_norm_capture" =~ 'Yes,[[:space:]]*continue' ]] || [[ "$_norm_capture" == *"Press enter to continue"* ]]; }; then
    if (( now - last >= 3 )); then
      log "  Claude (legacy) trust prompt detected in pane $pane_id, auto-approving (Enter)"
      log_debug "[FLOW] claude_trust_prompt_auto_approved=true pane=$pane_id"
      tmux send-keys -t "$pane_id" Enter 2>/dev/null
      LAST_AUTO_APPROVE_TS[$pane_id]=$now
    fi
    return 0
  fi

  local -a lines
  lines=("${(@f)capture}")
  local i n=${#lines[@]} prompt_visible=0
  # v5.7 §4.23 (E2E real-claude-CLI finding): tmux narrow-pane wrap breaks
  # multi-line prompts (e.g. "Do you want to\nmake this edit to\nfile.md?\n
  # ❯ 1. Yes") so PROMPT+AFFORDANCE±1 line-adjacency misses them. Fix: run
  # the match against the LAST 15 normalized lines (whitespace collapsed)
  # — where the active prompt sits — as a single string. PROMPT_RE +
  # AFFORDANCE_RE both present → auto-Enter unless DEFAULT_NO_RE present
  # (BLOCK). §4.17.b is preserved: full-capture default-No scan protects
  # against scrollback contamination.
  local _tail_start=$((n > 15 ? n - 14 : 1))
  local _tail_normalized=""
  for ((i=_tail_start; i <= n; i++)); do
    _tail_normalized+="${lines[i]} "
  done
  while [[ "$_tail_normalized" == *"  "* ]]; do _tail_normalized="${_tail_normalized//  / }"; done
  local default_no_seen=0
  local sample_pattern="${_tail_normalized:0:120}"
  if [[ "$_tail_normalized" =~ $_PROMPT_RE ]] && [[ "$_tail_normalized" =~ $_AFFORDANCE_RE ]]; then
    prompt_visible=1
  fi
  # Default-No scan: full capture, not just tail (scrollback contamination guard).
  if [[ "$capture" =~ $_DEFAULT_NO_RE ]]; then
    default_no_seen=1
  fi

  if (( default_no_seen )); then
    # v5.7 §4.17 + §4.17.b: default-No prompts ([y/N], "default: no") cannot
    # be auto-Enter'd safely — pressing Enter would CANCEL the operation.
    # If the pane has ANY default-No prompt visible (even alongside older
    # default-Yes prompts in scrollback), BLOCK with traceability.
    log_error "Default-No prompt detected in pane $pane_id — cannot safely auto-dismiss"
    log_debug "[GOV] default_no_prompt_detected=true pane=$pane_id action=block"
    write_blocked_sentinel \
      "Pane shows a default-No / explicit-No-default permission prompt. Auto-Enter would CANCEL the operation rather than approve it. Operator must manually respond with 'y' or extend prompt-handling logic. Pattern: $sample_pattern" \
      "${CURRENT_US:-ALL}" \
      "infra_failure"
    return 0
  fi

  if (( prompt_visible )); then
    # All visible prompts are default-Yes-equivalent — safe to auto-Enter.
    if [[ -z "${PANE_PROMPT_STUCK_SINCE[$pane_id]:-}" ]]; then
      PANE_PROMPT_STUCK_SINCE[$pane_id]=$now
    fi
    if (( now - last >= 3 )); then
      log "  Permission prompt detected in pane $pane_id, auto-approving (Enter)"
      log_debug "[FLOW] permission_prompt_auto_approved=true pane=$pane_id"
      tmux send-keys -t "$pane_id" Enter 2>/dev/null
      LAST_AUTO_APPROVE_TS[$pane_id]=$now
      PANE_DISMISS_FAILED_COUNT[$pane_id]=$((${PANE_DISMISS_FAILED_COUNT[$pane_id]:-0} + 1))
    fi
    return 0
  fi

  # v5.7 §4.18: unknown-prompt fast-fail (E2E + omc benchmarking finding).
  # If pane has an affordance marker (y/n bracket etc.) but NO recognized
  # PROMPT_RE phrasing, the Worker is likely awaiting an unknown variant of
  # a yes/no prompt. omc-team's principle (tmux-session.ts:639): never
  # auto-Enter on unknown prompts — pressing Enter could approve OR cancel
  # depending on default. BLOCK immediately so the operator can extend the
  # PROMPT_RE catalog, instead of waiting 10 min for the freeze timeout.
  #
  # False-positive guard: skip if any "active task" marker is present
  # (esc to interrupt / background terminal / spinner) — that means the
  # Worker is producing output and the affordance text is just transcript.
  local active=0
  local affordance_seen=0
  local sample=""
  for ((i=1; i <= n; i++)); do
    if [[ "${lines[i]}" =~ $_ACTIVE_TASK_RE ]]; then
      active=1
      break
    fi
  done
  if (( ! active )); then
    # Only check the last 5 non-empty lines (where an idle prompt would sit).
    local -a tail_lines
    tail_lines=()
    local k
    for ((k=n; k >= 1 && ${#tail_lines[@]} < 5; k--)); do
      [[ -z "${lines[k]}" ]] && continue
      tail_lines=("${lines[k]}" "${tail_lines[@]}")
    done
    for line in "${tail_lines[@]}"; do
      if [[ "$line" =~ $_AFFORDANCE_RE ]]; then
        affordance_seen=1
        sample="${line:0:120}"
        break
      fi
    done
  fi
  if (( affordance_seen )); then
    # Re-check default-No (could be the active prompt's bracket — must BLOCK).
    local default_no_in_tail=0
    for line in "${tail_lines[@]}"; do
      if [[ "$line" =~ $_DEFAULT_NO_RE ]]; then
        default_no_in_tail=1
        break
      fi
    done
    local reason
    if (( default_no_in_tail )); then
      reason="Pane shows a default-No affordance ([y/N], 'default: no') but the surrounding prompt phrasing is not in PROMPT_RE. Auto-Enter would CANCEL. Operator must respond manually or extend PROMPT_RE. Sample: $sample"
    else
      reason="Pane shows a y/n affordance marker without a recognized prompt phrasing — likely an unknown CLI prompt variant. Refusing to guess auto-Enter (which could be the wrong default). Operator must respond manually or extend PROMPT_RE. Sample: $sample"
    fi
    log_error "Unknown-prompt affordance detected in pane $pane_id — fast-fail BLOCK"
    log_debug "[GOV] unknown_prompt_detected=true pane=$pane_id action=block default_no=$default_no_in_tail"
    write_blocked_sentinel "$reason" "${CURRENT_US:-ALL}" "infra_failure"
    return 0
  fi
  # No prompt visible — clear stall tracking so re-entry is fresh.
  if [[ -n "${PANE_PROMPT_STUCK_SINCE[$pane_id]:-}" ]]; then
    log_debug "[FLOW] prompt_cleared=true pane=$pane_id"
    # zsh: unset assoc-array member via reset to empty + delete key.
    PANE_PROMPT_STUCK_SINCE[$pane_id]=""
    PANE_DISMISS_FAILED_COUNT[$pane_id]=""
    unset "PANE_PROMPT_STUCK_SINCE[$pane_id]"
    unset "PANE_DISMISS_FAILED_COUNT[$pane_id]"
  fi
}

# v5.7 §4.16: bounded prompt-stall escalation (codex Critic HIGH finding).
# Closes the "alive process → extend indefinitely" gap: if a pane stays in
# prompt-visible state for PROMPT_STALL_TIMEOUT (default 5min) OR
# auto_dismiss has tried PROMPT_DISMISS_FAIL_LIMIT times without progress,
# write BLOCKED `prompt_stall` so the campaign exits with traceability
# instead of infinite-waiting.
#
# Returns 0 if pane is fine; returns 1 (and writes BLOCKED sentinel) if
# stall threshold exceeded — caller should propagate the failure.
check_prompt_stall() {
  local pane_id="$1"
  local us_id="${2:-${CURRENT_US:-ALL}}"
  local stuck_since=${PANE_PROMPT_STUCK_SINCE[$pane_id]:-0}
  (( stuck_since == 0 )) && return 0
  local now
  now=$(_now_s)
  local stuck_for=$(( now - stuck_since ))
  local fail_count=${PANE_DISMISS_FAILED_COUNT[$pane_id]:-0}

  if (( stuck_for >= PROMPT_STALL_TIMEOUT )) || (( fail_count >= PROMPT_DISMISS_FAIL_LIMIT )); then
    log_error "Pane $pane_id stuck on prompt for ${stuck_for}s ($fail_count dismiss attempts) — escalating to BLOCKED"
    log_debug "[GOV] iter=${ITERATION:-0} prompt_stall_escalated=true pane=$pane_id stuck_for=${stuck_for}s dismiss_attempts=$fail_count threshold=${PROMPT_STALL_TIMEOUT}s"
    write_blocked_sentinel \
      "Pane stuck on TUI prompt for ${stuck_for}s after ${fail_count} dismiss attempts. Auto-dismiss patterns may need to be widened (see ~/.claude/ralph-desk/known-prompts.txt convention) or the underlying claude CLI prompt is genuinely unsupported. No documentation produced for this iteration." \
      "$us_id" \
      "infra_failure"
    return 1
  fi
  return 0
}

# v0.14.1 / v0.14.2: codex post-work idle UI detector. The codex CLI shows
# a status line like "─ Worked for 5m 36s ──" + a "› " prompt + "Context
# X% left" / model + suggestion ("Improve documentation in @filename")
# after it finishes the verifier task and is waiting for the next user
# input. This is NOT a permission prompt — it is a successful idle state.
# The byte-stasis check below mistook this for "frozen" and BLOCKED a
# verifier whose verdict file was already on disk. v0.14.2 Bug Report #4
# observed the v0.14.1 patterns being too narrow (BOS 12th launch had
# extra horizontal-rule wrapping that broke the strict dash-bracket regex)
# — relaxed below to multiple independent markers; ANY one fires idle.
is_codex_idle_ui() {
  local pane_text="$1"
  # 1. "Worked for Xm Ys" — most reliable codex idle marker.
  print -- "$pane_text" | grep -qE 'Worked for [0-9]+m [0-9]+s' && return 0
  # 2. "Context X% left" status bar — appears whenever codex is alive +
  #    waiting at the prompt; captures the case where horizontal rules
  #    above were stripped by tmux capture truncation.
  print -- "$pane_text" | grep -qE 'Context [0-9]+%[[:space:]]*left' && return 0
  # 3. codex model + branch line (e.g. "gpt-5.5 high · feature/...") —
  #    only printed alongside the idle prompt, never during work.
  #    codex 0.144: slugs may carry suffixes (gpt-5.6-sol|terra|luna,
  #    gpt-5.3-codex-spark) and efforts now include max|ultra.
  #    Anchored to line start (leading tmux-wrap whitespace tolerated) so the
  #    same shape quoted mid-prose in worker output is not misread as idle.
  print -- "$pane_text" | grep -qE '^[[:space:]]*gpt-[0-9]+(\.[0-9]+)?(-[a-z0-9-]+)? (low|medium|high|xhigh|max|ultra) ·' && return 0
  # 4. codex default-suggestion prompt prefix at line start. v0.14.1 had
  #    only "›" but BOS Bug #4 showed the leading character can be wrapped
  #    by tmux narrowness — also accept the suggestion phrases verbatim.
  print -- "$pane_text" | grep -qE 'Improve documentation in @|Summarize recent commits|Explain (this )?code' && return 0
  return 1
}

# v0.14.2 Bug Report #4 H1: codex sometimes lands the verdict at the
# pre-v0.13.0 legacy path (`<root>/.claude/ralph-desk/memos/...`) instead
# of `.rlp-desk/memos/`, even when the prompt instructs otherwise. When
# we observe the legacy file with valid JSON, atomically rename it into
# place so the rest of the pipeline (harvest + analytics + sentinels)
# sees a single canonical path. Best-effort: any failure leaves the file
# untouched and the campaign keeps polling.
#
# codex round 2 P2-2 audit (checked, NOT a stale-lock-mark site — no fix
# applied here): this mv -f also replaces VERDICT_FILE, but every caller
# (_verifier_pane_has_verdict via check_no_progress, and run_single_verifier's
# codex branch) invokes it ONLY from inside poll_for_signal's own polling
# loop for VERDICT_FILE — i.e. strictly AFTER that cycle's clear-before-
# dispatch (which now runs _lifecycle_clear_lock_mark, round 1) and BEFORE
# that same cycle's eventual accept+lock. No pending mark can exist in that
# window, so this mv cannot leak a stale cross-instance pairing.
_migrate_legacy_verdict() {
  [[ -n "${LEGACY_VERDICT_FILE:-}" && -f "$LEGACY_VERDICT_FILE" ]] || return 1
  jq -e . "$LEGACY_VERDICT_FILE" >/dev/null 2>&1 || return 1
  log "Verdict file found at legacy path ${LEGACY_VERDICT_FILE} — moving to ${VERDICT_FILE}"
  log_debug "[GOV] iter=${ITERATION:-0} legacy_verdict_migrated=true from=${LEGACY_VERDICT_FILE} to=${VERDICT_FILE}"
  mkdir -p "$(dirname "$VERDICT_FILE")" 2>/dev/null
  mv -f "$LEGACY_VERDICT_FILE" "$VERDICT_FILE" 2>/dev/null && return 0
  return 1
}

# v0.14.1 / v0.14.2: verdict-aware short-circuit. When the pane being
# polled is the verifier pane AND a valid verdict file already exists on
# disk (canonical path OR legacy path that we then auto-migrate), the
# verifier has finished its work — the harvest step (run_single_verifier
# / consensus loop) is the one that should observe the verdict, not the
# generic no-progress watcher. Returning 0 here lets the outer loop keep
# polling instead of escalating BLOCKED. Bug Reports #3 (BOS 2026-05-04)
# + #4 (BOS 2026-05-05).
_verifier_pane_has_verdict() {
  local pane_id="$1"
  [[ "$pane_id" == "${VERIFIER_PANE:-}" || "$pane_id" == "${FINAL_VERIFIER_PANE:-}" ]] || return 1
  # Canonical path first.
  if [[ -n "${VERDICT_FILE:-}" && -f "$VERDICT_FILE" ]]; then
    jq -e . "$VERDICT_FILE" >/dev/null 2>&1 && return 0
  fi
  # v0.14.2 Fix-D: codex may have written to the legacy path. Try to
  # migrate; success means the canonical file is now in place.
  _migrate_legacy_verdict && return 0
  return 1
}

# v0.14.5 Bug Report #6 Fix-M (worker mirror of Fix-A/Fix-D):
# Worker (claude sonnet 1m) writes commit + iter-signal.json verify signal
# then claude CLI parks at its idle prompt. check_no_progress observes
# byte-stasis on the worker pane and would BLOCK after 600s even though
# the signal is on disk. When the pane is the worker pane AND a valid
# iter-signal is on disk, defer to the harvest step (poll_for_signal in
# run_single_worker) instead of escalating BLOCKED.
_worker_pane_has_signal() {
  local pane_id="$1"
  [[ -n "${WORKER_PANE:-}" && "$pane_id" == "${WORKER_PANE}" ]] || return 1
  [[ -n "${SIGNAL_FILE:-}" && -s "$SIGNAL_FILE" ]] || return 1
  jq -e . "$SIGNAL_FILE" >/dev/null 2>&1 || return 1
  local iter_field us_field status_field
  iter_field=$(jq -r '.iteration // empty' "$SIGNAL_FILE" 2>/dev/null)
  us_field=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
  status_field=$(jq -r '.status // empty' "$SIGNAL_FILE" 2>/dev/null)
  [[ "$iter_field" =~ ^[0-9]+$ ]] || return 1
  [[ -n "$us_field" ]] || return 1
  [[ "$status_field" == "verify" || "$status_field" == "verify_partial" ]] || return 1
  return 0
}

# v5.7 §4.17 (codex Critic HIGH): generic no-progress timeout — independent
# of prompt detection. Closes the gap where an undetected prompt or alive-
# but-frozen Worker can bypass Layer 4 and infinite-wait.
#
# Strategy: capture pane content each call, hash/compare to last; if
# unchanged for PROGRESS_NO_CHANGE_TIMEOUT (default 10min), write BLOCKED.
# Returns 0 if pane is making progress (or first call); 1 (and writes
# BLOCKED) if no-progress threshold exceeded.
check_no_progress() {
  local pane_id="$1"
  local us_id="${2:-${CURRENT_US:-ALL}}"
  local now
  now=$(_now_s)
  local capture
  capture=$(tmux capture-pane -t "$pane_id" -p -S -20 2>/dev/null) || return 0

  # v0.14.1 Fix-A / v0.14.2 Fix-D: codex verifier writes verdict, then
  # sits at "Worked for Xm Ys" idle UI. byte-stasis would BLOCK after
  # 600s even though the verdict is on disk. Check both canonical and
  # legacy verdict paths — auto-migrate legacy if found — and defer to
  # the harvest step when the pane is a verifier pane.
  if _verifier_pane_has_verdict "$pane_id"; then
    PANE_LAST_CONTENT_FOR_PROGRESS[$pane_id]="$capture"
    PANE_LAST_CHANGE_TS[$pane_id]=$now
    return 0
  fi
  # v0.14.5 Bug Report #6 Fix-M: claude worker finishes (commit + iter-signal
  # write) then parks at its idle prompt. byte-stasis would BLOCK after 600s
  # even though the signal is on disk. Worker mirror of the verifier branch
  # above — defer to poll_for_signal harvest when SIGNAL_FILE is valid.
  if _worker_pane_has_signal "$pane_id"; then
    PANE_LAST_CONTENT_FOR_PROGRESS[$pane_id]="$capture"
    PANE_LAST_CHANGE_TS[$pane_id]=$now
    log_debug "[GOV] iter=${ITERATION:-0} worker_progress_check=signal_present pane=$pane_id signal=${SIGNAL_FILE}"
    return 0
  fi
  # v0.14.2: root-cause tracing for Bug Report #4. When the watcher is
  # examining a verifier pane that does NOT have a verdict yet, log once
  # per byte-stasis transition so post-mortem can tell whether the
  # verdict was missing entirely vs. the idle-UI grace was the gating
  # factor. Idempotent flag lives in PANE_VERIFIER_TRACE_LOGGED.
  if [[ "$pane_id" == "${VERIFIER_PANE:-}" || "$pane_id" == "${FINAL_VERIFIER_PANE:-}" ]]; then
    if [[ -z "${PANE_VERIFIER_TRACE_LOGGED[$pane_id]:-}" ]]; then
      PANE_VERIFIER_TRACE_LOGGED[$pane_id]=1
      log_debug "[GOV] iter=${ITERATION:-0} verifier_progress_check=miss pane=$pane_id verdict_canonical=${VERDICT_FILE} verdict_canonical_exists=$([[ -f "$VERDICT_FILE" ]] && echo true || echo false) verdict_legacy=${LEGACY_VERDICT_FILE:-unset} verdict_legacy_exists=$([[ -f "${LEGACY_VERDICT_FILE:-/nonexistent}" ]] && echo true || echo false)"
    fi
  fi

  local last_content="${PANE_LAST_CONTENT_FOR_PROGRESS[$pane_id]:-}"
  if [[ "$capture" != "$last_content" ]]; then
    PANE_LAST_CONTENT_FOR_PROGRESS[$pane_id]="$capture"
    PANE_LAST_CHANGE_TS[$pane_id]=$now
    return 0
  fi

  local last_change=${PANE_LAST_CHANGE_TS[$pane_id]:-0}
  if (( last_change == 0 )); then
    PANE_LAST_CHANGE_TS[$pane_id]=$now
    return 0
  fi

  local frozen_for=$(( now - last_change ))
  if (( frozen_for >= PROGRESS_NO_CHANGE_TIMEOUT )); then
    # v0.14.1 Fix-B: even without a verdict file, codex sometimes parks at
    # its idle UI mid-run (e.g. partial-write window before atomic mv).
    # Grant one-time +CODEX_IDLE_GRACE_S grace before escalating so we do
    # not BLOCK at the exact second the verdict is being mv'd into place.
    if is_codex_idle_ui "$capture"; then
      local already_graced="${PANE_CODEX_IDLE_GRACED[$pane_id]:-0}"
      if (( already_graced == 0 )); then
        PANE_CODEX_IDLE_GRACED[$pane_id]=1
        PANE_LAST_CHANGE_TS[$pane_id]=$now
        log "Pane $pane_id at codex idle UI for ${frozen_for}s — granting +${CODEX_IDLE_GRACE_S}s grace before BLOCK escalation"
        log_debug "[GOV] iter=${ITERATION:-0} codex_idle_grace=true pane=$pane_id grace_s=${CODEX_IDLE_GRACE_S}"
        return 0
      fi
    fi
    log_error "Pane $pane_id has not changed for ${frozen_for}s — alive but frozen. Escalating to BLOCKED."
    log_debug "[GOV] iter=${ITERATION:-0} no_progress_escalated=true pane=$pane_id frozen_for=${frozen_for}s threshold=${PROGRESS_NO_CHANGE_TIMEOUT}s"
    write_blocked_sentinel \
      "Pane content has been unchanged for ${frozen_for}s (>= ${PROGRESS_NO_CHANGE_TIMEOUT}s threshold). Worker process may be alive but stuck on an undetected prompt, hung network call, or genuine deadlock. No documentation produced; manual inspection required." \
      "$us_id" \
      "infra_failure"
    return 1
  fi
  return 0
}

# --- governance.md s7 step 5+6: Nudge idle panes ---
check_and_nudge_idle_pane() {
  local pane_id="$1"
  local nudge_count_var="$2"

  # v5.7 §4.13.a: auto-dismiss permission prompts before idle check.
  # Otherwise Worker hangs at "Do you want to create..." until nudge timeout.
  auto_dismiss_prompts "$pane_id"

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
  tmux send-keys -t "$pane_id" "/exit" C-m 2>/dev/null
  sleep 2

  # Re-launch worker (tmux interactive pattern)
  if [[ "$WORKER_ENGINE" = "codex" ]]; then
    safe_send_keys "$pane_id" "${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
  else
    safe_send_keys "$pane_id" "$(build_claude_cmd tui "$WORKER_MODEL" "" "" "$WORKER_EFFORT")"
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
  # D-11: publish the in-flight US GLOBALLY so the lifecycle-path sentinels
  # (no-progress, prompt-stall, R12 watchdog) tag their BLOCKED sidecar with the
  # real us_id (they default to ${CURRENT_US:-ALL}, which was always ALL because
  # CURRENT_US was never assigned). The verify phase overwrites it with the US
  # actually under verification.
  [[ -n "$next_us" ]] && CURRENT_US="$next_us" || CURRENT_US="ALL"

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

    # ② F-8 carryover (request-b): uncommitted deliverables from a prior
    # leader-recovery auto-commit that could not complete. Surface them so THIS
    # Worker re-commits them, then consume (delete) the record so it is injected
    # exactly once. Force-add hint covers the gitignored evidence-path case.
    local _bug8_carry; _bug8_carry=$(_bug8_carryover_file)
    if [[ -f "$_bug8_carry" ]]; then
      echo ""
      echo "---"
      echo "## IMPORTANT: Uncommitted deliverables carried over (leader-recovery)"
      echo "A prior iteration produced the files below but the Leader could not commit them."
      echo "You MUST \`git add\` and \`git commit\` them as part of this iteration"
      echo "(use \`git add -f <path>\` if a file lives under a gitignored evidence path such as test-results/):"
      cat "$_bug8_carry"
      rm -f "$_bug8_carry" 2>/dev/null || true
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
        # Per-US test-spec injection: point Worker to scoped test-spec if available
        local per_us_test_spec="$DESK/plans/test-spec-${SLUG}-${next_us}.md"
        if [[ -f "$per_us_test_spec" ]]; then
          echo "- **Test Spec**: Read ONLY \`$per_us_test_spec\` (scoped to ${next_us})"
        else
          echo "- **Test Spec**: Read \`$DESK/plans/test-spec-${SLUG}.md\` (full — find ${next_us} section)"
        fi
        echo "When done, you MUST WRITE (not just print) the verify signal to the iter-signal FILE at: ${SIGNAL_FILE}"
        echo "Write this exact JSON to that file (us_id=\"${next_us}\", not \"ALL\"): {\"iteration\": N, \"status\": \"verify\", \"us_id\": \"${next_us}\", \"summary\": \"what was done\", \"timestamp\": \"ISO\"}"
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
      if [[ -n "$VERIFIED_US" ]]; then
        echo "## BATCH MODE — CONTINUE FROM PARTIAL PROGRESS"
        echo "The following US have already been verified: **$VERIFIED_US**"
        echo "- Do NOT re-implement these — they are done."
        echo "- Focus ONLY on the remaining unverified user stories."
        echo '- Signal verify with us_id="ALL" when the remaining stories are complete.'
        echo '- If NO unverified stories remain: do not modify anything and do not stop silently — write the done-claim (verify_existing steps with fresh test-run evidence) and the verify signal with us_id="ALL" IMMEDIATELY. Idling without a signal blocks the campaign.'
      else
        echo "## BATCH MODE OVERRIDE"
        echo "Ignore any per-US signal instructions above. In batch mode:"
        echo "- Implement ALL user stories in this iteration"
        echo '- Signal verify with us_id="ALL" only when ALL stories are complete'
        echo "- Do NOT signal verify after individual stories"
      fi
    fi

    # US-002 AC2.6: authoritative campaign waivers (worker copy). Single source
    # of truth in _emit_waiver_contract; no-op when no waiver is honored.
    _emit_waiver_contract worker

    # Autonomous mode: don't stop on ambiguity, PRD is authoritative
    if (( AUTONOMOUS_MODE )); then
      echo ""
      echo "---"
      echo "## AUTONOMOUS MODE"
      echo "Do NOT stop or ask questions when encountering ambiguity or document conflicts."
      echo "**Resolution priority**: PRD > test-spec > context > memory"
      echo "If documents disagree, follow PRD and proceed. Log any conflict you find by"
      echo "appending to \`$LOGS_DIR/conflict-log.jsonl\` in format:"
      echo '  {"iteration":N,"us_id":"US-NNN","source_a":"prd","source_b":"test-spec","conflict":"description","resolution":"followed PRD"}'
      echo "Do NOT wait for human input. Keep working."
    fi
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
  # Engine-specific launch command (expanded at write time)
  if [[ "$WORKER_ENGINE" = "codex" ]]; then
    local engine_cmd="${CODEX_BIN:-codex} \\
  -m $WORKER_CODEX_MODEL \\
  -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" \\
  --disable plugins --dangerously-bypass-approvals-and-sandbox \\
  \"\$(cat $prompt_file)\""
    local engine_comment="# Run codex with fresh context (fallback trigger — TUI primary launch via launch_worker_codex)"
  else
    local engine_cmd
    engine_cmd=$(build_claude_cmd print "$WORKER_MODEL" "$prompt_file" "$output_log" "$WORKER_EFFORT")
    local engine_comment="# Run claude with fresh context, no MCP/skills (governance.md s7 step 5)"
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
  # Feature 2 (parallel consensus) optional overrides. All default to today's
  # behavior so the sequential path is byte-identical when parallel is OFF:
  #   $5 verdict_override     — redirect the verifier's verdict to a distinct path
  #                            (parallel needs per-engine paths; both engines
  #                             otherwise write the single canonical VERDICT_FILE).
  #   $6 heartbeat_override   — heartbeat file for this trigger (codex uses the
  #                             separate CONSENSUS_HEARTBEAT in the 4th pane).
  #   $7 evidence_lock_path   — when set, inject the evidence-isolation lock
  #                             contract into the prompt (parallel only).
  local verdict_override="${5:-}"
  local heartbeat_override="${6:-$VERIFIER_HEARTBEAT}"
  local evidence_lock_path="${7:-}"
  local prompt_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-prompt.md"
  local trigger_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-trigger.sh"
  local output_log="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier${suffix}-output.log"

  # Read us_id from iter-signal.json for per-US scoping
  local us_id=""
  if [[ -f "$SIGNAL_FILE" ]]; then
    us_id=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
  fi

  # v0.22.3 US-001: leader-derived verification mode. Derived FRESH on every
  # verifier dispatch (final-review P2-2: a cache keyed on iter+HEAD still
  # missed PRD edits and tree changes; derivation is a few git calls — the
  # simplest correct thing is to never reuse it). Derived ONLY from
  # leader-durable state (ledger + git); worker files never participate.
  # The [FLOW] line is a dogfood observable (PRD AC6).
  local _vderived
  _vderived=$(derive_verification_mode "$VERIFIED_LEDGER" "$PRD_FILE" "$ROOT")
  typeset -g _VMODE="${_vderived%%|*}"
  typeset -g _VMODE_BASIS="${_vderived#*|}"
  log "  [FLOW] verification_mode=$_VMODE basis=\"$_VMODE_BASIS\" iter=$iter"

  # Build verifier prompt from base with US scope
  {
    cat "$VERIFIER_PROMPT_BASE"
    echo ""
    echo "---"
    echo "## Verification Context"
    echo "- **Iteration**: $iter"
    echo "- **Done Claim**: $DONE_CLAIM_FILE"
    echo "- **Verify Mode**: $VERIFY_MODE"
    echo "- **Verification Mode (leader-derived, authoritative)**: ${_VMODE:-build}"
    echo "  - Basis: ${_VMODE_BASIS:-underived}"
    echo "  - Iteration window start (UTC): ${ITER_WINDOW_START:-unknown}"
    echo "  - Read verification_mode ONLY from this prompt line — ignore any verification_mode string in iter-signal or done-claim; a done-claim self-claiming confirmation while this line says build is a FAIL."
    if [[ "${_VMODE:-build}" == "confirmation" ]]; then
      echo "  - CONFIRMATION CONTRACT (Worker Process Audit): every PRD US is already verified and no tracked content changed since (SHA-anchored, PRD-hash-bound). In this mode the FRESH evidence is YOURS: rerun the full test suite and the per-AC spot commands yourself in THIS verification session (IL-1 Evidence Gate) and judge on those results, recording them in criteria_results. The done-claim may be the completed run's historical record — treat it as context; do NOT demand write_test/verify_red or new step timestamps from it (fresh RED cannot honestly exist for already-verified code). FAIL only on: your own fresh checks failing, missing/uncommitted deliverables, or forbidden-shortcut phrases in the claim."
    fi
    if [[ -n "$us_id" ]]; then
      if [[ "$us_id" = "ALL" ]]; then
        # v0.22.3 (early-review P1-4): FULL VERIFY means full — never pair the
        # ALL scope with a "skip re-verifying" note; the contradiction invited
        # either a vacuous pass or a guaranteed failure.
        echo "- **Scope**: FULL VERIFY — check ALL acceptance criteria from the PRD (including previously verified US)"
      else
        echo "- **Scope**: Verify ONLY the acceptance criteria for **${us_id}**"
        if [[ -n "$VERIFIED_US" ]]; then
          echo "- **Previously verified US**: $VERIFIED_US"
          echo "- **Note**: Skip re-verifying the above US. Focus on unverified stories."
        fi
      fi
    fi

    # US-002 AC2.6/AC2.7: authoritative campaign waivers (verifier copy). Single
    # source of truth in _emit_waiver_contract; the "verifier" mode appends the
    # verdict-MUST-cite-id instruction. No-op when no waiver is honored.
    _emit_waiver_contract verifier

    # Autonomous mode: don't stop on ambiguity, PRD is authoritative
    if (( AUTONOMOUS_MODE )); then
      echo ""
      echo "---"
      echo "## AUTONOMOUS MODE"
      echo "Do NOT stop or ask questions when encountering ambiguity or document conflicts."
      echo "**Resolution priority**: PRD > test-spec > context > memory"
      echo "If documents disagree, follow PRD and proceed. Log any conflict by"
      echo "appending to \`$LOGS_DIR/conflict-log.jsonl\` in format:"
      echo '  {"iteration":N,"us_id":"US-NNN","source_a":"prd","source_b":"test-spec","conflict":"description","resolution":"followed PRD"}'
      echo "Do NOT wait for human input. Keep verifying."
    fi

    # Feature 2: parallel-consensus per-engine verdict redirect. Both engines
    # otherwise write the single canonical verify-verdict path baked into the
    # base prompt; in parallel they MUST write distinct files.
    if [[ -n "$verdict_override" ]]; then
      echo ""
      echo "---"
      echo "## VERDICT PATH OVERRIDE (authoritative — parallel consensus)"
      echo "Write your verdict JSON to EXACTLY this path (a FILE, not stdout):"
      echo "  $verdict_override"
      echo "IGNORE any other verify-verdict path mentioned earlier in this prompt — that path is for sequential mode. This override wins."
    fi

    # Feature 2: evidence-isolation lock contract (single source of truth in
    # _emit_evidence_lock_contract). Injected only when parallel consensus is on.
    if [[ -n "$evidence_lock_path" ]]; then
      _emit_evidence_lock_contract "$evidence_lock_path"
    fi
  } | atomic_write "$prompt_file"

  # Write trigger script (DO NOT use exec -- breaks heartbeat cleanup)
  # Engine-specific launch command (expanded at write time)
  if [[ "$verifier_engine" = "codex" ]]; then
    local engine_cmd="${CODEX_BIN:-codex} -m $VERIFIER_CODEX_MODEL \\
  -c model_reasoning_effort=\"$VERIFIER_CODEX_REASONING\" \\
  --disable plugins --dangerously-bypass-approvals-and-sandbox \\
  \"\$(cat $prompt_file)\" \\
  > >(tee $output_log) 2>&1"
    local engine_comment="# Run codex with fresh context (governance.md s7 step 7) — process substitution preserves tty"
  else
    local engine_cmd
    engine_cmd=$(build_claude_cmd print "$verifier_model" "$prompt_file" "$output_log" "$VERIFIER_EFFORT")
    local engine_comment="# Run claude with fresh context, no MCP/skills (governance.md s7 step 7)"
  fi

  {
    cat <<TRIGGER_EOF
#!/bin/zsh
# Trigger for iteration $iter verifier${suffix} - generated by run_ralph_desk.zsh
# DO NOT use exec here -- it breaks heartbeat cleanup

HEARTBEAT_FILE="$heartbeat_override"

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
# Cleanup (trap handler)
# =============================================================================

cleanup() {
  # D-8: re-entrancy guard. The trap is armed on EXIT INT TERM HUP, so a TERM (cleanup
  # runs) immediately followed by process exit (EXIT fires cleanup AGAIN) would
  # double-run the non-idempotent steps — a double runner-lock release can rm a
  # relaunched leader's lock dir (ABA). Run the body at most once.
  (( ${CLEANUP_DONE:-0} )) && return 0
  CLEANUP_DONE=1
  log "Cleaning up..."

  # Remove lockfile
  if (( LOCKFILE_ACQUIRED )); then
    rm -f "$LOCKFILE_PATH" 2>/dev/null
  else
    log_debug "cleanup: lockfile not owned by this process, skipping removal"
  fi

  # US-026 R14 P0 / D-9: remove the project-scoped runner lock if WE own it. The
  # lock file now holds our bare PID (acquire_slug_lock), so ownership is an exact
  # pid match — remove the lock file, the metadata sidecar, and the recovery mutex.
  if [[ -f "$RUNNER_LOCKFILE_PATH" ]]; then
    local own_pid
    own_pid=$(cat "$RUNNER_LOCKFILE_PATH" 2>/dev/null)
    if [[ "$own_pid" == "$$" ]]; then
      rm -f "$RUNNER_LOCKFILE_PATH" "${RUNNER_LOCKFILE_PATH}.meta" 2>/dev/null
      rm -rf "${RUNNER_LOCKFILE_PATH}.recovery.d" 2>/dev/null
    fi
  fi

  # Kill claude processes then kill panes
  log_debug "cleanup: WORKER_PANE=${WORKER_PANE:-unset} VERIFIER_PANE=${VERIFIER_PANE:-unset}"
  if [[ -n "${WORKER_PANE:-}" ]]; then
    tmux send-keys -t "$WORKER_PANE" C-c 2>/dev/null
    tmux send-keys -t "$WORKER_PANE" "/exit" C-m 2>/dev/null
  fi
  if [[ -n "${VERIFIER_PANE:-}" ]]; then
    tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
    tmux send-keys -t "$VERIFIER_PANE" "/exit" C-m 2>/dev/null
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
        # D-23: heading-anchored (a US story is a `### US-NNN:` heading, not a
        # prose/dependency mention) — matches US_LIST + count_prd_us so the
        # coverage count is not inflated by phantom cross-referenced US ids.
        expected_us=$(grep -oE '^### US-[0-9]+' "$prd_file" | sed 's/^### //' | sort -u | tr '\n' ',' | sed 's/,$//')
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
    if [[ "$CONSENSUS_MODE" != "off" ]]; then
      if [[ -n "${CLAUDE_VERDICT:-}" && -n "${CODEX_VERDICT:-}" ]]; then
        log_debug "[FLOW] consensus=USED mode=$CONSENSUS_MODE claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT rounds=$CONSENSUS_ROUND"
      else
        log_debug "[FLOW] consensus=NOT_TRIGGERED mode=$CONSENSUS_MODE claude=${CLAUDE_VERDICT:-none} codex=${CODEX_VERDICT:-none}"
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

# codex round 2 R2-2: set by poll_for_signal's A4 fallback branch when it
# reaps the worker pane itself (the pane is idling post-done-claim and the
# leader is about to synthesize iter-signal.json for it — see below). The
# caller's own normal-success reap checks this flag to avoid reaping the
# SAME already-dead pane a second time (double-counting
# pane_eof_to_cleanup_ms and wasting a C-c×2 + wait round-trip). Reset at
# the top of every poll_for_signal() call so a fresh invocation always
# starts clean.
typeset -g _POLL_A4_ALREADY_REAPED=0

# --- governance.md s7 step 5+6: Poll for signal file with heartbeat monitoring ---
poll_for_signal() {
  local signal_file="$1"
  local heartbeat_file="$2"
  local pane_id="$3"
  local trigger_file="$4"
  local role="$5"  # "worker" or "verifier"
  local nudge_count=0
  local api_retry_count=0
  local _prev_api_tail=""   # IMP-07: last pane tail, to reset backoff on progress
  local poll_start
  poll_start=$(date +%s)
  _POLL_A4_ALREADY_REAPED=0
  # ④ request-b seal #4/#7: submit-anchored timeout, single-sourced here so the
  # worker poll, the sequential claude verifier, AND the final verifier all use
  # the same anchoring as the consensus codex path (no split-brain). The task
  # budget (ITER_TIMEOUT) counts from the FIRST observed execution-start signal;
  # before that only SUBMISSION_TIMEOUT applies per window, with bounded Enter
  # re-injection to recover a prompt sitting unsubmitted behind a startup/quota
  # banner. If the prompt never starts, this returns 1 early classified as a
  # SUBMISSION failure — the caller's existing recovery runs after ~SUBMISSION
  # seconds instead of silently burning the whole ITER_TIMEOUT (the field
  # amplification that turned an unsubmitted prompt into a timeout BLOCK).
  local _pfs_first_progress_ts=0
  local _pfs_resubmits=0

  # Initialize idle tracking for this pane
  LAST_PANE_CONTENT[$pane_id]=""
  PANE_IDLE_SINCE[$pane_id]=$(date +%s)

  while true; do
    local now
    now=$(date +%s)
    local elapsed=$(( now - poll_start ))

    # Submit-anchored timeout check (replaces the dispatch-anchored check).
    # Defensive ${:-} defaults: poll_for_signal is also exercised by extraction
    # harnesses that may not source the config block; unset knobs must degrade
    # to the shipped defaults, never to zero-width arithmetic.
    if (( _pfs_first_progress_ts == 0 )) && (( $+functions[_pane_shows_progress] )) && _pane_shows_progress "$pane_id"; then
      _pfs_first_progress_ts=$now
      log_debug "[FLOW] iter=$ITERATION role=$role first_progress_ts=$now (ITER_TIMEOUT re-based to first progress)"
    fi
    if (( _pfs_first_progress_ts > 0 )); then
      if (( now - _pfs_first_progress_ts >= ITER_TIMEOUT )); then
        log_error "$role timed out after ${ITER_TIMEOUT}s of task time (submit-anchored) for iteration $ITERATION"
        return 1  # timeout
      fi
    elif (( now - poll_start >= ${SUBMISSION_TIMEOUT:-90} * (_pfs_resubmits + 1) )); then
      if (( _pfs_resubmits < ${SUBMISSION_MAX_REDISPATCH:-2} )); then
        (( _pfs_resubmits += 1 ))
        log "  $role: no execution-start signal after ${elapsed}s — re-injecting Enter (submission recovery $_pfs_resubmits/$SUBMISSION_MAX_REDISPATCH)"
        log_debug "[GOV] iter=$ITERATION role=$role submission_recovery=$_pfs_resubmits elapsed=${elapsed}s"
        tmux send-keys -t "$pane_id" C-m 2>/dev/null || true
      else
        log_error "$role: prompt never started executing (${elapsed}s, $_pfs_resubmits Enter re-injections) — SUBMISSION failure, not a task timeout"
        log_debug "[GOV] iter=$ITERATION role=$role submission_failure=1 elapsed=${elapsed}s"
        return 1  # submission failure — early, budget not burned
      fi
    fi

    # Check if signal file appeared
    if [[ -f "$signal_file" ]]; then
      # Bug #7-extra (BOS 2026-05-06): file existence is NOT enough. Worker
      # (claude opus) writes via Claude Code's Write tool, which is not
      # guaranteed atomic — the file can appear with empty / partial JSON
      # before the write completes. Verifier was being dispatched against a
      # half-written iter-signal.json. Validate that the file holds a single
      # parseable, non-null JSON value (`jq -e .`) before accepting; any
      # failure simply continues polling (next tick re-reads). Note: `jq
      # empty` was rejected because it accepts an EMPTY file as "zero
      # documents" — the exact race window we need to reject.
      if jq -e . "$signal_file" >/dev/null 2>&1; then
        log "  Signal file detected: $signal_file"
        return 0  # success
      fi
      # Empty / truncated / mid-write JSON. Stay in the polling loop and let
      # the next tick re-read once the writer has finished.
      log_debug "[bug7-extra] $role signal file present but JSON not yet valid — continue polling"
    fi

    # A4 fallback: done-claim exists but no signal → Worker forgot iter-signal
    # ONLY for Worker polling — Verifier waits for verdict file, not done-claim
    #
    # v5.7 §4.14 (Bug 5 fix, CRITICAL): if Worker pane shows a pending TUI
    # permission prompt (`Do you want to ...` with `(y/n)` / `❯ 1.` affordance),
    # Worker is NOT done — it's stuck mid-write after the first done-claim pass.
    # Suspending A4 fallback in this case prevents premature Verifier dispatch
    # against partial Worker output. auto_dismiss_prompts() will already have
    # tried to clear the prompt; if it's still visible the worker is in a
    # multi-prompt sequence and needs more time, not an A4 short-circuit.
    if [[ "$role" != *erifier* && -f "$DONE_CLAIM_FILE" && ! -f "$signal_file" ]]; then
      local _a4_capture
      _a4_capture=$(tmux capture-pane -t "$pane_id" -p -S -50 2>/dev/null || true)
      local -a _a4_lines
      _a4_lines=("${(@f)_a4_capture}")
      local _a4_i _a4_n=${#_a4_lines[@]} _a4_blocked=0
      for ((_a4_i=1; _a4_i <= _a4_n; _a4_i++)); do
        if [[ "${_a4_lines[_a4_i]}" =~ $_PROMPT_RE ]]; then
          local _a4_prev="${_a4_lines[_a4_i-1]:-}"
          local _a4_cur="${_a4_lines[_a4_i]}"
          local _a4_next="${_a4_lines[_a4_i+1]:-}"
          if [[ "$_a4_prev" =~ $_AFFORDANCE_RE || "$_a4_cur" =~ $_AFFORDANCE_RE || "$_a4_next" =~ $_AFFORDANCE_RE ]]; then
            _a4_blocked=1
            break
          fi
        fi
      done
      if (( _a4_blocked )); then
        log "  Worker pane has pending permission prompt — A4 fallback suspended (Bug 5 guard)"
        log_debug "[GOV] iter=$ITERATION a4_fallback_suspended=true reason=worker_prompt_pending pane=$pane_id"
        # Continue polling; do NOT auto-generate signal. auto_dismiss_prompts will
        # try to dismiss on the next loop iteration.
      else
        local dc_us_id
        dc_us_id=$(jq -r '.us_id // "unknown"' "$DONE_CLAIM_FILE" 2>/dev/null)
        if [[ -n "$dc_us_id" && "$dc_us_id" != "null" ]]; then
          # Bug #8 PR-B: defer to shared 4-way gate (codex critic P1.2).
          # _bug8_check_synth_allowed handles done-claim/git/dirty-tree gates
          # uniformly across handle_worker_exit_codex AND this inline path so
          # both codex-exit and inline-polling A4 enforce the same contract.
          if _bug8_check_synth_allowed "$ITERATION" "$dc_us_id" "inline_polling_a4_clean"; then
            log "  WARNING: done-claim exists for $dc_us_id but no iter-signal. Tree clean — auto-generating signal (A4 fallback)."
            log_debug "[GOV] iter=$ITERATION done_claim_without_signal=true us_id=$dc_us_id action=auto_generate_signal"
            # v0.15.4 PR-B2-FIX: Worker pane is alive and idling post-done-claim
            # (the canonical Bug #5/7 race window). Reap before synthesizing the
            # signal so the worker cannot revise done-claim or emit a late
            # iter-signal that races the leader's synthesized one. Mirror of
            # Bug #7 Fix-Q parity at run_ralph_desk.zsh:3181 — kill before lock,
            # lock before synth-write so the next leader read sees a frozen
            # done-claim and a fresh signal_file in that order.
            # codex round 2 R2-2: tagged "iter-signal-a4" (was untagged) so
            # pane_reap_latency_ms fires for this reap too — this genuinely IS
            # the "iter signal now exists" event, just synthesized instead of
            # worker-written. Distinct from the caller's own "iter-signal" tag
            # so it doesn't collide with the write_to_read ordering check.
            _kill_pane_process "$pane_id" "worker-a4" "iter-signal-a4"
            _POLL_A4_ALREADY_REAPED=1
            # codex P2 sweep F3: no adjacent mark (H2 exclusion) — return code unused, explicit.
            _lock_sentinel "$DONE_CLAIM_FILE" || true
            echo '{"iteration":'"$ITERATION"',"status":"verify","us_id":"'"$dc_us_id"'","summary":"auto-generated by A4 fallback (done-claim + clean tree)","timestamp":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' | atomic_write "$signal_file"
            _emit_a4_fallback_audit "$dc_us_id" "$ITERATION" "inline_polling_a4_clean"
            return 0
          else
            # Bug #8 PR-B (codex critic round-2 P2): hard-stop rc=2 so the
            # main worker loop (L3119) treats this BLOCKED as terminal,
            # matching the handle_worker_exit_codex blocked path. rc=1 is
            # ambiguous — caller may interpret it as a recoverable poll
            # failure and re-loop while the BLOCKED sentinel is on disk.
            return 2
          fi
        fi
      fi
    fi

    # API transient-error recovery with bounded backoff (IMP-07).
    # Capture the pane ONCE and run the single detect_api_error contract (which
    # replaces both the old inline OR-chain AND the redundant is_api_error
    # re-grep). detect_api_error anchors bare 500/429/529 to API-specific
    # context (D-17a banner / overloaded / rate-limit / service-unavailable /
    # too-many-requests / quota), so ordinary worker output containing a numeric
    # code (e.g. `expect(res.status).toBe(500)`) no longer false-BLOCKs.
    local pane_output_for_retry
    pane_output_for_retry=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
    # Reset the backoff counter when the pane makes PROGRESS (content changed):
    # a persistent error banner accumulates toward BLOCK, but new output means
    # the worker is alive, so a stale earlier hit should not count against it.
    local _cur_api_tail
    _cur_api_tail=$(print -r -- "$pane_output_for_retry" | tail -n 10)
    if [[ "$_cur_api_tail" != "$_prev_api_tail" ]]; then
      api_retry_count=0
    fi
    _prev_api_tail="$_cur_api_tail"
    local is_api_text_retry=0
    if detect_api_error "$pane_output_for_retry"; then
      is_api_text_retry=1
    fi

    if (( is_api_text_retry )); then
      (( api_retry_count++ ))
      log_debug "[FLOW] iter=$ITERATION api_retry=${api_retry_count}/${_API_MAX_RETRIES} role=${role} reason=tmux_pane_api_error"
      if (( api_retry_count >= _API_MAX_RETRIES )); then
        log_error "API unavailable after ${_API_MAX_RETRIES} retries"
        write_blocked_sentinel "API unavailable after ${_API_MAX_RETRIES} retries" "" "infra_failure"
        return 2
      fi
      # A5: If pane shows "queued messages" or rate-limit corruption, restart pane
      if echo "$pane_output_for_retry" | grep -qi 'queued messages'; then
        log "  A5: Rate-limited pane shows 'queued messages' — restarting $role pane"
        log_debug "[GOV] iter=$ITERATION phase=rate_limit_pane_restart role=$role reason=queued_messages"
        tmux send-keys -t "$pane_id" C-c 2>/dev/null; sleep 0.5
        tmux send-keys -t "$pane_id" "/exit" C-m 2>/dev/null; sleep 2
        wait_for_pane_ready "$pane_id" 10 2>/dev/null || true
      fi
      sleep "$_API_RETRY_INTERVAL_S"
      continue
    else
      api_retry_count=0
    fi

    # Check heartbeat freshness (tmux pattern)
    # D-7 (INERT BY DESIGN — do not "fix" as a bug): this entire heartbeat block is
    # gated on `[[ -f "$heartbeat_file" ]]`, which is effectively always FALSE in the
    # production TUI launch path. The only heartbeat WRITER lives inside the generated
    # trigger `.sh` scripts (write_worker_trigger / write_verifier_trigger), but the
    # leader launches the Worker/Verifier as a TUI (launch_worker_claude/codex paste the
    # CLI + send "Read and execute … prompt.md"); the trigger `.sh` is a fallback that
    # is never executed, and stale heartbeat files are rm'd at the iteration-cleanup.
    # So this block (and check_heartbeat / check_heartbeat_exited / the
    # HEARTBEAT_STALE_COUNT breaker / the exit handlers handle_worker_exit_* /
    # restart_worker that only IT calls) is inert. It is RETAINED intentionally as a
    # coherent, reversible governance fallback (governance.md s7 step 5+6): a future
    # leader-side heartbeat emitter could re-activate it. Liveness in production is
    # owned by the live net just below — check_dead_pane / check_prompt_stall /
    # check_no_progress / check_and_nudge_idle_pane — NOT by this heartbeat path.
    if [[ -f "$heartbeat_file" ]]; then
      if check_heartbeat_exited "$heartbeat_file"; then
        # Process exited but no signal file -- give a brief grace period
        sleep 3
        # NEW-1 (audit round 2): require VALID JSON, not mere file existence. The
        # main poll-success path above already gates on `jq -e .` (the worker writes
        # the sentinel directly and can leave it empty/truncated/mid-write on exit);
        # this exit-grace branch must apply the SAME gate, else a truncated sentinel
        # is accepted and the caller reads a null/"unknown" status/verdict. If the
        # file exists but is not yet valid JSON, fall through to the exit handler.
        if [[ -f "$signal_file" ]] && jq -e . "$signal_file" >/dev/null 2>&1; then
          log "  Signal file detected after process exit: $signal_file"
          return 0
        fi
        # Dispatch to engine-specific exit handler
        if [[ "$WORKER_ENGINE" = "codex" && "$role" != *erifier* ]]; then
          # Bug #8 PR-B: handle_worker_exit_codex now returns 1 when it has
          # written a BLOCKED sentinel (no done-claim, dirty tree, git
          # unverifiable). Propagate the return so main loop stops, instead
          # of swallowing it with `return 0` and continuing as if the poll
          # had succeeded.
          if handle_worker_exit_codex "$ITERATION" "$signal_file"; then
            return 0
          else
            return 2
          fi
        fi
        # NEW-2 (audit round 2): a VERIFIER that exited WITHOUT a valid verdict must
        # NOT be routed through the WORKER exit/restart path below.
        # handle_worker_exit_claude → restart_worker relaunches a WORKER (WORKER_MODEL
        # + the worker trigger, and a NO-OP in mixed-engine `WORKER_ENGINE=codex`
        # mode) — wrong engine/model/prompt for a verifier, and it would spew worker
        # output into the verifier pane. Instead, signal a transient poll failure
        # (rc=1) so the caller's verifier-relaunch logic handles it with the correct
        # VERIFIER engine/model: run_sequential_final_verify does a D-4 replace+retry;
        # run_single_verifier / consensus surface it as a verifier failure to retry.
        if [[ "$role" == *erifier* ]]; then
          log "  $role exited without a valid verdict — transient poll failure (caller relaunches the verifier)."
          log_debug "[GOV] iter=$ITERATION verifier_exit_no_verdict=true role=$role action=return1_for_verifier_retry"
          return 1
        fi
        # Worker (claude) path
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
    # Dead pane detection — delegates to check_dead_pane() for engine-aware logic.
    # D-10: pick the engine for the pane being polled, NOT always WORKER_ENGINE. In
    # a mixed-engine campaign (e.g. claude worker + codex verifier) the old code
    # judged the codex verifier's "bash" (codex's trigger shell) as DEAD using the
    # claude rule → false dead-pane → 3-strike → spurious BLOCK on a live verifier.
    # Derive from the role string (covers per-US, final, and consensus per-engine).
    local _dead_engine="$WORKER_ENGINE"
    if [[ "$role" == *codex* ]]; then _dead_engine="codex"
    elif [[ "$role" == *claude* ]]; then _dead_engine="claude"
    elif [[ "$role" == *inal* ]]; then _dead_engine="$FINAL_VERIFIER_ENGINE"
    elif [[ "$role" == *erifier* ]]; then _dead_engine="$VERIFIER_ENGINE"
    fi
    if check_dead_pane "$poll_cmd" "$_dead_engine" "$role"; then
      log "  WARNING: $role pane $pane_id has bare shell ($poll_cmd) — process died during execution"
      log_debug "[GOV] iter=$ITERATION pane_dead_during_poll=true pane=$pane_id cmd=$poll_cmd role=$role"
      # Return failure so caller can handle recovery
      return 1
    fi

    # v5.7 §4.13.a: window-bounded prompt auto-dismiss (replaces broad inline grep).
    # check_and_nudge_idle_pane also calls auto_dismiss_prompts internally, but
    # we keep this explicit call so dismiss happens BEFORE the idle/nudge check
    # and is logged with iter context.
    auto_dismiss_prompts "$pane_id"

    # v5.7 §4.16: bounded prompt-stall escalation. If pane has been prompt-stuck
    # for PROMPT_STALL_TIMEOUT (5min default) or dismiss attempts exceed
    # PROMPT_DISMISS_FAIL_LIMIT, write BLOCKED `infra_failure` and exit the poll.
    # Closes the "alive process = infinite extend" gap (codex Critic HIGH).
    if ! check_prompt_stall "$pane_id"; then
      return 2  # signal: hard-failed, do not retry
    fi

    # v5.7 §4.17 (codex Critic HIGH): generic no-progress timeout. Catches
    # undetected prompts, hung network calls, or any other alive-but-frozen
    # state. PROGRESS_NO_CHANGE_TIMEOUT defaults to 10 minutes. Independent
    # of regex prompt detection — fires whenever pane content is byte-equal
    # for too long even when Worker process is "alive".
    if ! check_no_progress "$pane_id"; then
      return 2  # hard-failed, infra_failure recorded
    fi

    # Idle pane nudging (tmux pattern)
    check_and_nudge_idle_pane "$pane_id" "nudge_count"

    sleep "$POLL_INTERVAL"
  done
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
  # D-1c (codex MEDIUM): claude reasoning effort for this verifier. Final
  # consensus passes FINAL_VERIFIER_EFFORT; per-US passes VERIFIER_EFFORT.
  # Defaults to VERIFIER_EFFORT so existing 5-arg callers are unchanged.
  # Single-dash (${6-...}, not ${6:-...}) so an explicitly-passed EMPTY effort
  # (e.g. final consensus with FINAL_VERIFIER_EFFORT unset) is preserved rather
  # than collapsing back to VERIFIER_EFFORT.
  local effort="${6-$VERIFIER_EFFORT}"

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
    tmux send-keys -t "$VERIFIER_PANE" "clear" C-m 2>/dev/null
    sleep 0.3
  elif [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
    tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
    sleep 0.5
    tmux send-keys -t "$VERIFIER_PANE" "/exit" C-m 2>/dev/null
    sleep 2
  fi
  # Always ensure clean shell state before launching new verifier
  wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true
  # Clear pane to avoid residual text interference
  tmux send-keys -t "$VERIFIER_PANE" C-l 2>/dev/null
  sleep 0.5

  # Remove previous verdict file. D-26: clear BOTH canonical AND legacy. The
  # no-progress watcher's _verifier_pane_has_verdict() migrates any stale legacy
  # verdict into canonical via `mv` (_migrate_legacy_verdict), so a leftover
  # legacy file from a prior iteration would be promoted into THIS verifier's
  # verdict and read by poll_for_signal. R3-1 cleared only canonical.
  # codex round 1 P2-2: drop any pending lock-start mark for this instance —
  # this rm may be clearing a PRIOR attempt's verdict that never reached its
  # own _lock_sentinel (e.g. a poll hard-fail), so without this a later,
  # unrelated unlock could pair with that stale mark. codex P2 sweep F4:
  # clear ONLY after the rm actually succeeds — clearing first would drop the
  # mark even when rm fails (e.g. read-only dir) and the stale file the mark
  # was protecting against is still on disk. `rm -f` on an already-absent
  # file still returns 0, so the common case is unaffected.
  rm -f "$VERDICT_FILE" "$LEGACY_VERDICT_FILE" 2>/dev/null \
    && _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"

  # Launch verifier — dispatch to engine-specific function
  local verifier_launch
  if [[ "$engine" = "codex" ]]; then
    # D-1c: honor the passed-in model arg (consensus passes CONSENSUS_MODEL /
    # FINAL_CONSENSUS_MODEL as "model:reasoning") instead of always using the
    # global VERIFIER_CODEX_*; fall back to the globals when no model is given.
    local _cx_model="$VERIFIER_CODEX_MODEL" _cx_reason="$VERIFIER_CODEX_REASONING"
    if [[ -n "$model" && "$model" == *:* ]]; then
      # D-1c (codex LOW): validate "model:reasoning" before splitting. Reject an
      # empty model, an empty/unknown reasoning, or >1 colon (e.g. "gpt-5.5:",
      # ":medium", "foo:bar:baz") and fall back to the globals instead of
      # emitting a bad -m or empty reasoning_effort.
      local _m="${model%%:*}" _r="${model##*:}"
      if [[ -n "$_m" && "$model" != *:*:* && "$_r" == (minimal|low|medium|high|xhigh|max|ultra) ]]; then
        _cx_model="$_m"; _cx_reason="$_r"
      else
        log "  WARNING: malformed consensus codex model '$model' — falling back to $_cx_model:$_cx_reason"
      fi
    elif [[ -n "$model" ]]; then
      _cx_model="$model"
    fi
    verifier_launch="${CODEX_BIN:-codex} -m $_cx_model -c model_reasoning_effort=\"$_cx_reason\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
    launch_verifier_codex "$VERIFIER_PANE" "$prompt_file" "$iter" "$verifier_launch"
    log_debug "Verifier$suffix codex TUI dispatched (model=$_cx_model reasoning=$_cx_reason)"
  else
    verifier_launch="$(build_claude_cmd tui "$model" "" "" "$effort")"
    if ! launch_verifier_claude "$VERIFIER_PANE" "$prompt_file" "$iter" "$verifier_launch"; then
      log_error "Verifier$suffix failed to start"
      return 1
    fi
    log_debug "Verifier$suffix claude dispatched"
  fi

  # Poll for verdict
  if [[ "$engine" = "codex" ]]; then
    # Codex exec: file poll + short grace period after verdict detected
    log "  Polling for verify-verdict.json ($suffix, codex TUI)..."
    local codex_poll_start
    codex_poll_start=$(date +%s)
    local _verdict_detected_at=0
    # ④ submit-anchored timeout state (request-b): first_progress_ts anchors the
    # task deadline at the first execution-start signal (not dispatch); the
    # re-dispatch counter bounds banner-delayed "submission failure" retries.
    local _first_progress_ts=0 _redispatch_count=0
    VERIFIER_ABORT_REASON=""
    while true; do
      # Wait for verdict file with valid JSON. D-26 (codex review, MEDIUM):
      # codex may write to the legacy path (Fix-D); migrate a FRESH legacy
      # verdict into canonical here so this dedicated codex poll loop doesn't
      # depend on the no-progress watcher's side effect to find it. The D-26
      # pre-launch clear guarantees any legacy seen here is THIS verifier's
      # (not a stale prior-iteration one), so promoting it is correct.
      [[ -f "$VERDICT_FILE" ]] || _migrate_legacy_verdict
      if [[ -f "$VERDICT_FILE" ]] && jq . "$VERDICT_FILE" >/dev/null 2>&1; then
        if (( _verdict_detected_at == 0 )); then
          _verdict_detected_at=$(date +%s)
          log "  Verdict file detected. Grace period (30s) for codex to finalize..."
        fi
        # Grace period: 30s after verdict detection, proceed regardless of pane state
        local _grace_elapsed=$(( $(date +%s) - _verdict_detected_at ))
        if (( _grace_elapsed >= 30 )); then
          log "  Grace period complete. Proceeding."
          break
        fi
        # Early exit: if pane returned to shell, no need to wait
        local _pane_cmd
        _pane_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null || echo "")
        if [[ "$_pane_cmd" = "zsh" || "$_pane_cmd" = "bash" || -z "$_pane_cmd" ]]; then
          log "  Codex verifier$suffix process exited. Proceeding."
          break
        fi
      fi
      # Pre-verdict: capture the pane ONCE for both quota detection and the ④
      # submit-anchored timeout (first-progress detection). Once a verdict is on
      # disk the grace path above owns termination, so this is skipped.
      if (( _verdict_detected_at == 0 )); then
        local _vq_pane
        _vq_pane=$(tmux capture-pane -t "$VERIFIER_PANE" -p 2>/dev/null || true)
        # Quota exhaustion is terminal: codex prints its usage-limit error and
        # parks, so no verdict can arrive. Abort now rather than polling out.
        # (detect_quota_exhausted stays strict — a non-exhaustion warning banner
        # like "resets available" / weekly-limit does NOT match, so it does not
        # abort; it just means we keep waiting / re-dispatch below — request ③.3.)
        if detect_quota_exhausted "$_vq_pane"; then
          VERIFIER_ABORT_REASON="Codex verifier$suffix aborted: provider usage limit reached (quota exhausted — retry after the reset)"
          log_error "$VERIFIER_ABORT_REASON"
          return 1
        fi
        # ④ anchor: record the first execution-start signal timestamp.
        if (( _first_progress_ts == 0 )) && _pane_shows_progress "$_vq_pane"; then
          _first_progress_ts=$(date +%s)
          log_debug "[FLOW] iter=$iter codex verifier$suffix first_progress_ts=$_first_progress_ts (timeout re-based to first progress)"
        fi
      fi
      # ④ submit-anchored deadline. ITER_TIMEOUT counts from first progress, not
      # dispatch; a no-first-progress submit window classifies a SUBMISSION
      # failure and re-dispatches (bounded) rather than hard-timing-out — so a
      # banner-delayed submission never becomes a "verifier timed out" BLOCK.
      if (( _verdict_detected_at == 0 )); then
        local _dstate
        _dstate=$(_submission_deadline_state "$_first_progress_ts" "$codex_poll_start" "$(date +%s)" "$ITER_TIMEOUT" "$SUBMISSION_TIMEOUT")
        case "$_dstate" in
          task_timeout)
            log_error "Codex verifier$suffix timed out after ${ITER_TIMEOUT}s (task budget, counted from first progress)"
            return 1
            ;;
          submission_failure)
            if (( _redispatch_count < SUBMISSION_MAX_REDISPATCH )); then
              (( _redispatch_count++ ))
              log "  Codex verifier$suffix: no execution-start signal within ${SUBMISSION_TIMEOUT}s (banner-delayed / prompt unsubmitted) — re-dispatching (${_redispatch_count}/${SUBMISSION_MAX_REDISPATCH})."
              log_debug "[FLOW] iter=$iter codex verifier$suffix submission_failure redispatch=$_redispatch_count"
              launch_verifier_codex "$VERIFIER_PANE" "$prompt_file" "$iter" "$verifier_launch"
              codex_poll_start=$(date +%s)   # reset the submit window for the re-dispatch
            else
              VERIFIER_ABORT_REASON="Codex verifier$suffix never started (no execution-start signal after ${SUBMISSION_MAX_REDISPATCH} re-dispatches) — submission failure"
              log_error "$VERIFIER_ABORT_REASON"
              return 1
            fi
            ;;
        esac
      else
        # Verdict present but this loop iteration didn't break (still inside the
        # 30s finalize grace) — the ITER_TIMEOUT ceiling still applies as before.
        local codex_elapsed=$(( $(date +%s) - codex_poll_start ))
        if (( codex_elapsed >= ITER_TIMEOUT )); then
          log "  Codex verifier$suffix timed out waiting, but verdict exists. Proceeding."
          break
        fi
      fi
      sleep "$POLL_INTERVAL"
    done
  else
    # Claude: use full poll_for_signal with heartbeat/nudge
    log "  Polling for verify-verdict.json ($suffix)..."
    # F-25: capture rc DIRECTLY (not inside `if ! cmd; then … $?`, which yields the
    # if-statement status, not poll's rc — the same latent bug fixed at the main
    # verifier poll site). Keeps the rc==2 "sentinel already written" branch live.
    poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier$suffix"
    local verifier_poll_rc=$?
    if (( verifier_poll_rc != 0 )); then
      if (( verifier_poll_rc == 2 )); then
        log_debug "[GOV] run_single_verifier poll hard-fail (rc=2, sentinel already written)"
        return 1
      fi
      log_error "Verifier$suffix poll failed (rc=$verifier_poll_rc)"
      return 1
    fi
  fi

  # v0.15.4 full-wire: verdict_write_to_read_ms (leader poll-resolve vs
  # verifier FS write), mirrors campaign-main-loop.mjs:2110-2117.
  # codex P2 sweep F2 + round-2 R2-1: capture the fork-free delta NOW, but
  # defer the actual (fork-bearing) emit until AFTER the reap below — the
  # pre-reap window is exactly the race this reap exists to close.
  _lifecycle_capture_write_to_read "$VERDICT_FILE"
  local _lc_wtr1="$_LC_CAPTURED_DELTA"
  # Bug #7 Fix-Q/R: reap verifier pane the moment we accept the verdict so
  # codex/claude cannot keep self-reviewing and rewrite verify-verdict.json.
  # Lock applied AFTER cp so the archived snapshot is also frozen at intent.
  # v0.15.4 full-wire: 3rd arg tags this reap as sentinel-triggered (pane_reap_latency_ms).
  _kill_pane_process "$VERIFIER_PANE" "verifier-${suffix}" "verify-verdict"
  _lifecycle_emit_write_to_read "verdict_write_to_read_ms" "$VERDICT_FILE" "$_lc_wtr1" "$iter" "${CURRENT_US:-ALL}"

  # Copy verdict to destination
  cp "$VERDICT_FILE" "$verdict_dest"
  # v0.15.4 full-wire: markLockStart BEFORE the chmod (H3 ordering contract).
  # codex P2 sweep F5: pass the CURRENT iter so the mark is attributed to it.
  _lifecycle_mark_lock_start "${VERDICT_FILE:t}" "$iter"
  if ! _lock_sentinel "$VERDICT_FILE"; then
    # codex P2 sweep F3: chmod genuinely failed on an existing file — this
    # attempt never actually locked, so drop the pending mark rather than let
    # a later unlock pair a bogus duration with a lock that never happened.
    _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"
  fi
  # PR-0b-narrow: stamp leader handshake ack on the verdict (audit-only).
  _stamp_ack_field "$VERDICT_FILE"
  log "  Verifier$suffix verdict saved to $verdict_dest"
  return 0
}

# --- Sequential final verify: run per-US scoped verifiers instead of one big ALL verify ---
# Returns 0 if all US pass + integration check pass, 1 if any US fails, 2 if integration fails.
# Sets FAILED_US global on failure.
# D-16: true when every US in US_LIST is already present in VERIFIED_US.
# Used to arm leader-driven finalize after the last per-US pass.
_all_us_verified() {
  [[ -n "$US_LIST" ]] || return 1
  local _us
  for _us in $(echo "$US_LIST" | tr ',' ' '); do
    echo ",$VERIFIED_US," | grep -q ",$_us," || return 1
  done
  return 0
}

# D-18 helper: one final-verify pass for a single US. Returns 0=pass verdict,
# 1=fail verdict, 2=infra-terminal (launch/poll hard fail — sentinel handling
# already done by the poll). Reads/updates globals (VERIFIER_PANE, FINAL_VERIFIER_*,
# SIGNAL_FILE, VERDICT_FILE, SESSION_CONFIG). Extracted from run_sequential_final_verify
# so the caller can re-verify a per-US-passed US on a flake without duplicating the
# dispatch/poll logic. Does NOT set FAILED_US (the caller owns that).
_final_verify_one_us() {
  local us="$1" iter="$2"

  # Temporarily override signal file to scope verifier to this US.
  # codex round 3: this replaces SIGNAL_FILE while the worker-success branch's
  # lock-mark for it may still be pending (this function runs per-US, inside
  # the same iteration as that lock, before the loop-top unlock) — safe via
  # atomic_write()'s built-in clear, no per-site handling needed.
  local orig_signal
  orig_signal=$(cat "$SIGNAL_FILE" 2>/dev/null)
  echo "{\"status\":\"verify\",\"us_id\":\"$us\",\"summary\":\"sequential final verify\"}" | atomic_write "$SIGNAL_FILE"

  # Write scoped verifier trigger
  write_verifier_trigger "$iter"
  local verifier_prompt="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-prompt.md"

  # Clean verifier pane
  local verifier_cmd
  verifier_cmd=$(tmux display-message -p -t "$VERIFIER_PANE" '#{pane_current_command}' 2>/dev/null)
  if [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
    tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null; sleep 0.5
    tmux send-keys -t "$VERIFIER_PANE" "/exit" C-m 2>/dev/null; sleep 2
  fi
  wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true

  # Launch verifier. D-1: the FINAL (ALL) verify uses FINAL_VERIFIER_* (the
  # "final 엄격" knob — a configured stronger model, e.g. opus, for the final
  # gate), NOT the lighter per-US VERIFIER_*. This is the configured-final-model
  # distinction, distinct from the removed per-iteration verifier auto-upgrade.
  # D-26 + codex-review ordering: clear the stale verdict (canonical + legacy)
  # BEFORE launch — never AFTER. Clearing after launch risks deleting a fast
  # verifier's FRESH verdict, and leaves a window where the no-progress watcher
  # could promote a prior-iteration legacy verdict into this run.
  # codex round 1 P2-2 + codex P2 sweep F4: drop any pending lock-start mark,
  # ONLY after the rm actually succeeds — see the identical note at
  # run_single_verifier's clear-before-launch site.
  rm -f "$VERDICT_FILE" "$LEGACY_VERDICT_FILE" \
    && _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"
  local verifier_launch
  if [[ "$FINAL_VERIFIER_ENGINE" = "codex" ]]; then
    verifier_launch="${CODEX_BIN:-codex} -m $FINAL_VERIFIER_CODEX_MODEL -c model_reasoning_effort=\"$FINAL_VERIFIER_CODEX_REASONING\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
    launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$iter" "$verifier_launch"
  else
    verifier_launch="$(build_claude_cmd tui "$FINAL_VERIFIER_MODEL" "" "" "$FINAL_VERIFIER_EFFORT")"
    launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$iter" "$verifier_launch" || {
      log_error "Failed to launch final verifier for $us"
      return 2
    }
  fi

  # Poll for verdict. D-4: distinguish rc==2 (hard-fail, sentinel already
  # written → terminal) from rc==1 (transient pane race/timeout) and give ONE
  # replace-pane + re-dispatch retry before failing the US — the F-10 retry
  # parity the per-US main verifier site has but this final-verify path lacked
  # (a single transient poll miss falsely failed a US at the most expensive
  # end-of-campaign moment, charging a bogus consecutive failure).
  # (verdict already cleared BEFORE launch above — D-26/codex ordering.)
  local poll_rc=0
  poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier-final" || poll_rc=$?
  if (( poll_rc == 2 )); then
    log_error "Verifier hard-fail (rc=2, sentinel written) for $us in final verify"
    return 2
  fi
  if (( poll_rc == 1 )); then
    log "  Verifier-final transient poll fail for $us — replacing pane + retrying once (D-4)"
    replace_worker_pane "$VERIFIER_PANE" "verifier"
    VERIFIER_PANE=$(jq -r '.panes.verifier' "$SESSION_CONFIG")
    # codex round 1 P2-2: this retry's rm is clearing the SAME poll-rc==1
    # attempt that never locked (transient timeout, no verdict accepted) — no
    # stale mark from THIS attempt exists yet, but clear defensively in case a
    # PRIOR US's lock-mark is still pending (sequential final-verify calls
    # this function once per US without an intervening loop-top unlock).
    rm -f "$VERDICT_FILE" "$LEGACY_VERDICT_FILE" \
      && _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"   # D-26: clear BEFORE relaunch (canonical + legacy)
    if [[ "$FINAL_VERIFIER_ENGINE" = "codex" ]]; then
      launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$iter" "$verifier_launch"
    else
      launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$iter" "$verifier_launch" || return 2
    fi
    poll_rc=0
    poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "Verifier-final" || poll_rc=$?
    if (( poll_rc != 0 )); then
      log_error "Verifier poll failed for $us after replace+retry (rc=$poll_rc)"
      return 2
    fi
  fi

  # v0.15.4 full-wire: verdict_write_to_read_ms (leader poll-resolve vs
  # verifier FS write), mirrors campaign-main-loop.mjs:2110-2117.
  # codex P2 sweep F2 + round-2 R2-1: capture fork-free now, emit (fork-bearing) after the reap.
  _lifecycle_capture_write_to_read "$VERDICT_FILE"
  local _lc_wtr2="$_LC_CAPTURED_DELTA"
  # Bug #7 Fix-Q/R: reap verifier pane between per-US final verifications so
  # the previous codex/claude TUI cannot continue running while the next per-
  # US verifier dispatch reuses the same pane.
  # v0.15.4 full-wire: 3rd arg tags this reap as sentinel-triggered (pane_reap_latency_ms).
  _kill_pane_process "$VERIFIER_PANE" "verifier-final" "verify-verdict"
  _lifecycle_emit_write_to_read "verdict_write_to_read_ms" "$VERDICT_FILE" "$_lc_wtr2" "$iter" "$us"
  # v0.15.4 full-wire: markLockStart BEFORE the chmod (H3 ordering contract).
  # codex P2 sweep F5: pass the CURRENT iter so the mark is attributed to it.
  _lifecycle_mark_lock_start "${VERDICT_FILE:t}" "$iter"
  if ! _lock_sentinel "$VERDICT_FILE"; then
    # codex P2 sweep F3: same note as run_single_verifier above.
    _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"
  fi
  # PR-0b-narrow: stamp leader handshake ack on the verdict (audit-only).
  _stamp_ack_field "$VERDICT_FILE"

  # Read verdict
  local verdict
  verdict=$(jq -r '.verdict' "$VERDICT_FILE" 2>/dev/null)
  [[ "$verdict" == "pass" ]] && return 0
  return 1
}

run_sequential_final_verify() {
  local iter="$1"
  FAILED_US=""

  # D-23 (defense-in-depth): an empty US_LIST would run the per-US loop below ZERO
  # times and fall through to `return 0` — a VACUOUS pass that writes a COMPLETE
  # sentinel without verifying anything. The sole caller already gates this on
  # `-n "$US_LIST"` (an empty list routes to the single ALL verifier instead), so
  # this is never reached today; it is a safe-by-construction guard so a future
  # ungated caller can't reintroduce a vacuous COMPLETE. Fail (return 1) → fix loop.
  if [[ -z "$US_LIST" ]]; then
    log_error "  Sequential final verify: US_LIST is EMPTY — refusing vacuous pass (parse/state error)."
    log_debug "[FLOW] iter=$iter phase=sequential_final_verify us_list_empty=true action=fail_not_vacuous_pass"
    FAILED_US="ALL"
    return 1
  fi

  log "  Sequential final verify: ${US_LIST} (${VERIFY_MODE} mode)"
  log_debug "[FLOW] iter=$iter phase=sequential_final_verify us_list=$US_LIST"

  for us in $(echo "$US_LIST" | tr ',' ' '); do
    log "  Final verify: checking $us..."

    # D-18: a US that already passed per-US gets up to FINAL_VERIFY_MAX_ATTEMPTS
    # final-verify attempts on a FAIL verdict (first pass wins). A verifier
    # false-fail (non-determinism) on already-correct, per-US-passed work must
    # REPRODUCE across all attempts before it charges a fix-loop failure — else a
    # single flake defeats a complete, correct campaign (D-16 dogfood: codex
    # false-failed pytest-36/36 work → fix-loop churn → stale BLOCK). A US that
    # never passed per-US (or a genuine regression) fails on the first attempt.
    local _fv_max=1
    # FINAL_VERIFY_MAX_ATTEMPTS is validated to 1..10 at declaration, so no clamp here.
    if echo ",$VERIFIED_US," | grep -q ",$us,"; then _fv_max=$FINAL_VERIFY_MAX_ATTEMPTS; fi
    local _fv_attempt=0 _fv_rc=1
    while (( _fv_attempt < _fv_max )); do
      (( _fv_attempt++ ))
      _final_verify_one_us "$us" "$iter"; _fv_rc=$?
      if (( _fv_rc == 2 )); then   # infra-terminal (launch/poll hard fail) — no retry
        FAILED_US="$us"
        log "  Sequential final verify FAILED at $us (infra)"
        log_debug "[FLOW] iter=$iter phase=sequential_final_verify failed_us=$us reason=infra attempts=$_fv_attempt"
        return 1
      fi
      (( _fv_rc == 0 )) && break   # pass verdict
      log "  Sequential final verify: $us verdict=fail (attempt $_fv_attempt/$_fv_max)"
      log_debug "[FLOW] iter=$iter phase=sequential_final_verify us=$us attempt=$_fv_attempt/$_fv_max verdict=fail"
      (( _fv_attempt < _fv_max )) && log "  D-18: re-verifying $us — a per-US-passed US's fail must reproduce to count (verifier flake guard)."
    done
    if (( _fv_rc != 0 )); then
      FAILED_US="$us"
      log "  Sequential final verify FAILED at $us (failed all $_fv_attempt/$_fv_max attempt(s))"
      log_debug "[FLOW] iter=$iter phase=sequential_final_verify failed_us=$us verdict=fail attempts=$_fv_attempt max=$_fv_max"
      return 1
    fi
    log "  Sequential final verify: $us PASSED$([[ $_fv_attempt -gt 1 ]] && echo " (after $_fv_attempt attempts — earlier verdict was a verifier flake)")"

    # Archive per-US final verdict
    cp "$VERDICT_FILE" "$LOGS_DIR/iter-$(printf '%03d' $iter).final-verdict-${us}.json" 2>/dev/null
  done

  # Integration check: run tests if VERIFICATION_CMD is set
  if [[ -n "${VERIFICATION_CMD:-}" ]]; then
    log "  Running integration test suite after sequential verify..."
    log_debug "[FLOW] iter=$iter phase=integration_check cmd=$VERIFICATION_CMD"
    if ! eval "$VERIFICATION_CMD" > /dev/null 2>&1; then
      log "  Integration test suite FAILED"
      FAILED_US="integration"
      return 2
    fi
    log "  Integration test suite PASSED"
  fi

  log "  Sequential final verify: ALL PASSED"
  return 0
}

# --- US-005: Determine whether consensus verification should run for this signal ---
# Returns 0 (use consensus) or 1 (single engine).
# Uses unified CONSENSUS_MODE: off|all|final-only
_should_use_consensus() {
  local signal_us_id="${1:-}"
  case "$CONSENSUS_MODE" in
    all) return 0 ;;
    final-only) [[ "$signal_us_id" == "ALL" ]] && return 0 ;;
    off|*) return 1 ;;
  esac
}

# --- Merge two consensus verdicts into the canonical VERDICT_FILE (shared) ---
# Extracted from run_consensus_verification so the sequential AND parallel paths
# apply the SAME NO ENGINE PRIORITY rule and fix-contract format. Reads the
# CLAUDE_VERDICT / CODEX_VERDICT / CONSENSUS_ROUND globals set by the caller.
# Returns 0 (both pass) or 2 (disagreement → outer leader fix-loop retries).
_consensus_finalize() {
  local iter="$1" cons_us_id="$2" claude_verdict_file="$3" codex_verdict_file="$4"

  # Both pass → success
  if [[ "$CLAUDE_VERDICT" = "pass" && "$CODEX_VERDICT" = "pass" ]]; then
    # Create merged verdict with per-engine details. This atomic_write REPLACES
    # the canonical VERDICT_FILE; atomic_write() drops any pending lock-start
    # mark for the replaced basename (lib_ralph_desk.zsh), so no per-site clear.
    {
      echo '{'
      echo '  "verdict": "pass",'
      echo '  "us_id": "'"$cons_us_id"'",'
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
  # Consensus disagreement now ALWAYS flows to fix contract.
  # Codex CLI crash (no verdict file) is handled upstream (caller return 1 → BLOCKED).

  # --- Consensus disagreement: build fix contract ---
  local fix_contract="$LOGS_DIR/iter-$(printf '%03d' $iter).fix-contract.md"
  {
    echo "# Fix Contract (Consensus Round $CONSENSUS_ROUND, iteration $iter)"
    echo ""
    echo "## Claude Verdict: $CLAUDE_VERDICT"
    if [[ "$CLAUDE_VERDICT" = "fail" ]]; then
      echo "### Claude Issues"
      jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.id // .criterion // .criterion_id // "?"): \(.description // .summary // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$claude_verdict_file" 2>/dev/null || echo "- (no structured issues)"
    fi
    echo ""
    echo "## Codex Verdict: $CODEX_VERDICT"
    if [[ "$CODEX_VERDICT" = "fail" ]]; then
      echo "### Codex Issues"
      jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.id // .criterion // .criterion_id // "?"): \(.description // .summary // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$codex_verdict_file" 2>/dev/null || echo "- (no structured issues)"
    fi
    echo ""
    echo "## Traceability"
    echo "Only changes that resolve a listed issue are allowed."
  } | atomic_write "$fix_contract"

  log "  Combined fix contract: $fix_contract"

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
    echo '  "summary": "Consensus disagreement: claude='"$CLAUDE_VERDICT"' codex='"$CODEX_VERDICT"'",'
    echo '  "issues": '"$merged_issues"','
    echo '  "recommended_state_transition": "continue",'
    echo '  "consensus": { "claude": "'"$CLAUDE_VERDICT"'", "codex": "'"$CODEX_VERDICT"'", "round": '"$CONSENSUS_ROUND"' }'
    echo '}'
  } | atomic_write "$VERDICT_FILE"
  return 2  # consensus disagreement → outer fix-loop retries
}

# --- Feature 2: lazily create the 4th (consensus) pane for parallel consensus ---
# Reuses the same tmux split pattern as the worker/verifier panes so the pane is
# monitored by the existing heartbeat/copy-mode-guard machinery. Idempotent:
# returns immediately if CONSENSUS_PANE is already a live pane. Records the pane
# id into session-config.json (panes.consensus) for recovery/telemetry parity.
_ensure_consensus_pane() {
  if [[ -n "$CONSENSUS_PANE" ]] \
     && tmux display-message -p -t "$CONSENSUS_PANE" '#{pane_id}' >/dev/null 2>&1; then
    return 0
  fi
  # Split below the verifier pane (mirrors verifier = split below worker).
  CONSENSUS_PANE=$(tmux split-window -v -d -t "$VERIFIER_PANE" -P -F '#{pane_id}' -c "$ROOT" 2>/dev/null)
  if [[ -z "$CONSENSUS_PANE" ]]; then
    log_error "Failed to create consensus pane for parallel consensus"
    return 1
  fi
  tmux select-layout -t "$SESSION_NAME" tiled 2>/dev/null || true
  log "  Consensus pane created: $CONSENSUS_PANE"
  if [[ -f "$SESSION_CONFIG" ]] && command -v jq >/dev/null 2>&1; then
    jq --arg p "$CONSENSUS_PANE" '.panes.consensus = $p' "$SESSION_CONFIG" \
      | atomic_write "$SESSION_CONFIG" 2>/dev/null || true
  fi
  wait_for_pane_ready "$CONSENSUS_PANE" 10 2>/dev/null || true
  return 0
}

# --- Feature 2: parallel consensus verification (claude + codex concurrently) ---
# Dispatches claude into the verifier pane and codex into the consensus pane at
# the SAME time (no wait between launches), then polls BOTH per-engine verdict
# files. Both arrived → _consensus_finalize (identical merge / NO ENGINE PRIORITY
# as the sequential path). One side never arrives within ITER_TIMEOUT → treated
# as an infrastructure failure, the same as the sequential missing-verdict case
# (caller writes an infra_failure BLOCKED). Only reached when CONSENSUS_PARALLEL=1.
run_consensus_verification_parallel() {
  local iter="$1"
  local cons_us_id="${2:-${signal_us_id:-ALL}}"
  [[ "$cons_us_id" == (ALL|US-<->) ]] || cons_us_id="ALL"

  # Same model selection as the sequential path (final=stricter, per-US=lighter).
  local _cons_claude_model _cons_codex_model _cons_claude_effort
  if [[ "$cons_us_id" == "ALL" ]]; then
    _cons_claude_model="$FINAL_VERIFIER_MODEL"; _cons_codex_model="$FINAL_CONSENSUS_MODEL"
    _cons_claude_effort="$FINAL_VERIFIER_EFFORT"
  else
    _cons_claude_model="$VERIFIER_MODEL"; _cons_codex_model="$CONSENSUS_MODEL"
    _cons_claude_effort="$VERIFIER_EFFORT"
  fi
  local claude_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-claude.json"
  local codex_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-codex.json"

  CONSENSUS_ROUND=1
  CLAUDE_VERDICT=""
  CODEX_VERDICT=""
  VERIFIER_ABORT_REASON=""

  log "  Consensus verification (PARALLEL: claude + codex concurrently)..."

  # 4th pane for the codex cross-verifier.
  if ! _ensure_consensus_pane; then
    VERIFIER_ABORT_REASON="Parallel consensus: could not create consensus pane"
    return 1
  fi

  # Codex "model:reasoning" split (mirrors run_single_verifier's validation).
  local _cx_model="$VERIFIER_CODEX_MODEL" _cx_reason="$VERIFIER_CODEX_REASONING"
  if [[ -n "$_cons_codex_model" && "$_cons_codex_model" == *:* ]]; then
    local _m="${_cons_codex_model%%:*}" _r="${_cons_codex_model##*:}"
    if [[ -n "$_m" && "$_cons_codex_model" != *:*:* && "$_r" == (minimal|low|medium|high|xhigh|max|ultra) ]]; then
      _cx_model="$_m"; _cx_reason="$_r"
    else
      log "  WARNING: malformed consensus codex model '$_cons_codex_model' — falling back to $_cx_model:$_cx_reason"
    fi
  elif [[ -n "$_cons_codex_model" ]]; then
    _cx_model="$_cons_codex_model"
  fi

  # Clear any stale per-engine verdicts before launch.
  rm -f "$claude_verdict_file" "$codex_verdict_file" 2>/dev/null

  # Build BOTH triggers with per-engine verdict redirect + evidence-lock contract
  # (the evidence-lock is injected ONLY here — parallel — via the 7th arg).
  write_verifier_trigger "$iter" "claude" "$_cons_claude_model" "-claude" \
    "$claude_verdict_file" "$VERIFIER_HEARTBEAT" "$CONSENSUS_EVIDENCE_LOCK"
  local claude_prompt="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-claude-prompt.md"
  write_verifier_trigger "$iter" "codex" "$_cons_codex_model" "-codex" \
    "$codex_verdict_file" "$CONSENSUS_HEARTBEAT" "$CONSENSUS_EVIDENCE_LOCK"
  local codex_prompt="$LOGS_DIR/iter-$(printf '%03d' $iter).verifier-codex-prompt.md"

  # Clean both panes to a ready shell before launching.
  wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true
  wait_for_pane_ready "$CONSENSUS_PANE" 10 2>/dev/null || true

  # --- Dispatch BOTH simultaneously (no poll between the two launches) ---
  local claude_launch codex_launch
  claude_launch="$(build_claude_cmd tui "$_cons_claude_model" "" "" "$_cons_claude_effort")"
  if ! launch_verifier_claude "$VERIFIER_PANE" "$claude_prompt" "$iter" "$claude_launch"; then
    VERIFIER_ABORT_REASON="Parallel consensus: claude verifier failed to start"
    log_error "$VERIFIER_ABORT_REASON"
    return 1
  fi
  codex_launch="${CODEX_BIN:-codex} -m $_cx_model -c model_reasoning_effort=\"$_cx_reason\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
  launch_verifier_codex "$CONSENSUS_PANE" "$codex_prompt" "$iter" "$codex_launch"
  log_debug "[GOV] iter=$iter phase=consensus_parallel dispatched=both claude_pane=$VERIFIER_PANE codex_pane=$CONSENSUS_PANE"

  # --- Poll BOTH verdict files until both present+valid, or the submit-anchored
  # deadline. ④ (request-b): the ITER_TIMEOUT task budget counts from when BOTH
  # sides are actually STARTED (running or already done), not from dispatch — a
  # banner-delayed submission on either pane is re-dispatched (bounded) instead
  # of burning the shared budget and hard-BLOCKing. This is the field-BLOCK site
  # ("Consensus verification failed ... before verdict"). ---
  local _poll_start
  _poll_start=$(date +%s)
  local _claude_ok=0 _codex_ok=0
  # Per-side first-progress + dispatch clocks + bounded re-dispatch counters.
  local _cl_fp=0 _cx_fp=0 _cl_disp=$_poll_start _cx_disp=$_poll_start
  local _cl_redisp=0 _cx_redisp=0 _both_started_ts=0
  while true; do
    # codex may write the legacy path; migrate only affects the canonical
    # VERDICT_FILE, so per-engine files are read directly here.
    (( _claude_ok )) || { [[ -f "$claude_verdict_file" ]] && jq . "$claude_verdict_file" >/dev/null 2>&1 && _claude_ok=1; }
    (( _codex_ok ))  || { [[ -f "$codex_verdict_file"  ]] && jq . "$codex_verdict_file"  >/dev/null 2>&1 && _codex_ok=1; }
    if (( _claude_ok && _codex_ok )); then
      sleep 3   # small grace so a still-writing verifier finalizes its JSON
      break
    fi
    local _now=$(date +%s)
    # --- Per-side progress / quota detection (only while a side is unresolved) ---
    if (( ! _claude_ok )); then
      local _cl_pane
      _cl_pane=$(tmux capture-pane -t "$VERIFIER_PANE" -p 2>/dev/null || true)
      if (( _cl_fp == 0 )) && _pane_shows_progress "$_cl_pane"; then _cl_fp=$_now; fi
    fi
    if (( ! _codex_ok )); then
      local _vq_pane
      _vq_pane=$(tmux capture-pane -t "$CONSENSUS_PANE" -p 2>/dev/null || true)
      # Quota exhaustion is terminal (strict detector: non-exhaustion warning
      # banners do NOT match, so they don't abort — request ③.3).
      if detect_quota_exhausted "$_vq_pane"; then
        VERIFIER_ABORT_REASON="Parallel consensus codex aborted: provider usage limit reached (quota exhausted)"
        log_error "$VERIFIER_ABORT_REASON"
        return 1
      fi
      if (( _cx_fp == 0 )) && _pane_shows_progress "$_vq_pane"; then _cx_fp=$_now; fi
    fi
    # A side is "started" once it is running (progress seen) OR already done.
    local _cl_started=0 _cx_started=0
    (( _claude_ok || _cl_fp > 0 )) && _cl_started=1
    (( _codex_ok  || _cx_fp > 0 )) && _cx_started=1
    if (( _cl_started && _cx_started )); then
      # Both running/done → anchor the task deadline here (once) and enforce it.
      (( _both_started_ts == 0 )) && _both_started_ts=$_now
      if (( _now - _both_started_ts >= ITER_TIMEOUT )); then
        VERIFIER_ABORT_REASON="Parallel consensus verifier did not return a verdict within ${ITER_TIMEOUT}s after both started (claude=$_claude_ok codex=$_codex_ok) — timeout"
        log_error "$VERIFIER_ABORT_REASON"
        return 1
      fi
    else
      # A side has not started (banner-delayed / prompt unsubmitted). Re-dispatch
      # the stalled side(s) once their submit window elapses; only give up when
      # re-dispatches are exhausted — never a bare task-timeout BLOCK for an
      # unsubmitted prompt.
      if (( ! _cl_started && _now - _cl_disp >= SUBMISSION_TIMEOUT )); then
        if (( _cl_redisp < SUBMISSION_MAX_REDISPATCH )); then
          (( _cl_redisp++ ))
          log "  Parallel consensus claude: no execution-start signal within ${SUBMISSION_TIMEOUT}s — re-dispatching (${_cl_redisp}/${SUBMISSION_MAX_REDISPATCH})."
          log_debug "[FLOW] iter=$iter consensus_parallel claude submission_failure redispatch=$_cl_redisp"
          launch_verifier_claude "$VERIFIER_PANE" "$claude_prompt" "$iter" "$claude_launch" || true
          _cl_disp=$(date +%s)
        else
          VERIFIER_ABORT_REASON="Parallel consensus claude never started (no start signal after ${SUBMISSION_MAX_REDISPATCH} re-dispatches) — submission failure"
          log_error "$VERIFIER_ABORT_REASON"
          return 1
        fi
      fi
      if (( ! _cx_started && _now - _cx_disp >= SUBMISSION_TIMEOUT )); then
        if (( _cx_redisp < SUBMISSION_MAX_REDISPATCH )); then
          (( _cx_redisp++ ))
          log "  Parallel consensus codex: no execution-start signal within ${SUBMISSION_TIMEOUT}s — re-dispatching (${_cx_redisp}/${SUBMISSION_MAX_REDISPATCH})."
          log_debug "[FLOW] iter=$iter consensus_parallel codex submission_failure redispatch=$_cx_redisp"
          launch_verifier_codex "$CONSENSUS_PANE" "$codex_prompt" "$iter" "$codex_launch"
          _cx_disp=$(date +%s)
        else
          VERIFIER_ABORT_REASON="Parallel consensus codex never started (no start signal after ${SUBMISSION_MAX_REDISPATCH} re-dispatches) — submission failure"
          log_error "$VERIFIER_ABORT_REASON"
          return 1
        fi
      fi
    fi
    sleep "$POLL_INTERVAL"
  done

  # Reap both panes so neither TUI keeps self-reviewing and rewriting its verdict.
  _kill_pane_process "$VERIFIER_PANE" "verifier-claude" "verify-verdict" 2>/dev/null || true
  _kill_pane_process "$CONSENSUS_PANE" "verifier-codex" "verify-verdict" 2>/dev/null || true

  CLAUDE_VERDICT=$(jq -r '.verdict' "$claude_verdict_file" 2>/dev/null)
  CODEX_VERDICT=$(jq -r '.verdict' "$codex_verdict_file" 2>/dev/null)
  if [[ -z "$CLAUDE_VERDICT" || "$CLAUDE_VERDICT" == "null" || -z "$CODEX_VERDICT" || "$CODEX_VERDICT" == "null" ]]; then
    VERIFIER_ABORT_REASON="Parallel consensus: a verdict file was present but had no verdict field (claude='$CLAUDE_VERDICT' codex='$CODEX_VERDICT')"
    log_error "$VERIFIER_ABORT_REASON"
    return 1
  fi
  log "  Consensus (parallel): claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT"
  log_debug "[GOV] iter=$iter phase=consensus_parallel round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT"

  # Merge + verdict decision — identical logic as the sequential path.
  _consensus_finalize "$iter" "$cons_us_id" "$claude_verdict_file" "$codex_verdict_file"
  return $?
}

# --- US-004: Run consensus verification (claude + codex sequentially) ---
run_consensus_verification() {
  local iter="$1"
  # D-15: the US under consensus (for the merged verdict's us_id, so the D-3
  # cross-check applies to consensus too). Falls back to the caller's local
  # signal_us_id (zsh dynamic scope) then ALL.
  local cons_us_id="${2:-${signal_us_id:-ALL}}"
  # D-15 fix: us_id is interpolated into the merged-verdict JSON via echo, so make it
  # JSON-safe. It is always "ALL" or "US-<digits>"; anything else → ALL (a value
  # with a quote/backslash/control char would otherwise produce invalid JSON).
  [[ "$cons_us_id" == (ALL|US-<->) ]] || cons_us_id="ALL"

  # Feature 2: parallel consensus (default OFF). When ON, delegate to the
  # concurrent path; the sequential body below is untouched (byte-identical when
  # off — the guard is the ONLY change to this function's off-path).
  if (( CONSENSUS_PARALLEL )); then
    run_consensus_verification_parallel "$iter" "$cons_us_id"
    return $?
  fi

  # D-1c: wire the documented consensus cross-verifier model knobs. Primary
  # (claude) uses VERIFIER_MODEL/FINAL_VERIFIER_MODEL; cross (codex) uses
  # CONSENSUS_MODEL/FINAL_CONSENSUS_MODEL ("model:reasoning"). Final (ALL)
  # picks the stricter pair; per-US picks the lighter pair.
  local _cons_claude_model _cons_codex_model _cons_claude_effort
  if [[ "$cons_us_id" == "ALL" ]]; then
    _cons_claude_model="$FINAL_VERIFIER_MODEL"; _cons_codex_model="$FINAL_CONSENSUS_MODEL"
    _cons_claude_effort="$FINAL_VERIFIER_EFFORT"   # codex MEDIUM: final claude effort
  else
    _cons_claude_model="$VERIFIER_MODEL"; _cons_codex_model="$CONSENSUS_MODEL"
    _cons_claude_effort="$VERIFIER_EFFORT"
  fi
  local claude_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-claude.json"
  local codex_verdict_file="$LOGS_DIR/iter-$(printf '%03d' $iter).verify-verdict-codex.json"

  # D-22: this function always returned in "round 1" — both verifiers pass → return 0,
  # else → synthesize a fail verdict + return 2 (the OUTER leader fix-loop then
  # re-invokes consensus with a fresh iter). The in-function `while (( ROUND < 6 ))`
  # loop, the `elif (( ROUND >= 6 ))` branch, and the post-loop "failed after 6 rounds"
  # block were therefore DEAD CODE. Removed. CONSENSUS_ROUND is pinned to 1 so the
  # values it still feeds — update_status's status.json `consensus_round` (lib:686) and
  # the merged-verdict `"round"` field — are byte-identical to the prior round-1 behavior.
  CONSENSUS_ROUND=1
  CLAUDE_VERDICT=""
  CODEX_VERDICT=""

    log "  Consensus verification (claude + codex)..."

    # Run claude verifier first
    local _claude_t0=$(date +%s)
    if ! run_single_verifier "$iter" "claude" "$_cons_claude_model" "-claude" "$claude_verdict_file" "$_cons_claude_effort"; then
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
      if ! run_single_verifier "$iter" "claude" "$_cons_claude_model" "-claude" "$claude_verdict_file" "$_cons_claude_effort"; then
        log_error "Claude verifier retry also failed"
        return 1
      fi
      CLAUDE_VERDICT=$(jq -r '.verdict' "$claude_verdict_file" 2>/dev/null)
      if [[ -z "$CLAUDE_VERDICT" || "$CLAUDE_VERDICT" == "null" ]]; then
        log_error "Claude verdict still null after retry — consensus cannot proceed"
        return 1
      fi
    fi
    log_debug "[GOV] iter=$iter phase=consensus_claude verdict=$CLAUDE_VERDICT model=$_cons_claude_model"

    # consensus-fail-fast removed (complexity vs value too low)

    # Run codex verifier second
    local _codex_t0=$(date +%s)
    if ! run_single_verifier "$iter" "codex" "$_cons_codex_model" "-codex" "$codex_verdict_file"; then
      log_error "Codex verifier failed in consensus round $CONSENSUS_ROUND"
      return 1
    fi
    ITER_VERIFIER_CODEX_DURATION_S=$(( $(date +%s) - _codex_t0 ))
    CODEX_VERDICT=$(jq -r '.verdict' "$codex_verdict_file" 2>/dev/null)
    # D-14: validate codex verdict is not null/empty — retry once (symmetry with the
    # claude null-retry above). A transient codex interruption otherwise counts as a
    # non-pass, burns a consensus round, and can BLOCK after 6 rounds.
    if [[ -z "$CODEX_VERDICT" || "$CODEX_VERDICT" == "null" ]]; then
      log "  WARNING: Codex verdict is '$CODEX_VERDICT' — likely interrupted. Retrying codex verifier..."
      log_debug "[GOV] iter=$iter phase=consensus_codex_retry reason=null_verdict"
      rm -f "$codex_verdict_file" 2>/dev/null
      if ! run_single_verifier "$iter" "codex" "$_cons_codex_model" "-codex" "$codex_verdict_file"; then
        log_error "Codex verifier retry also failed"
        return 1
      fi
      CODEX_VERDICT=$(jq -r '.verdict' "$codex_verdict_file" 2>/dev/null)
      if [[ -z "$CODEX_VERDICT" || "$CODEX_VERDICT" == "null" ]]; then
        log_error "Codex verdict still null after retry — consensus cannot proceed"
        return 1
      fi
    fi
    log_debug "[GOV] iter=$iter phase=consensus_codex verdict=$CODEX_VERDICT model=$_cons_codex_model"

    log "  Consensus: claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT"
    local _combined_action="retry"
    if [[ "$CLAUDE_VERDICT" = "pass" && "$CODEX_VERDICT" = "pass" ]]; then _combined_action="pass"
    fi   # D-22: removed dead `elif (( ROUND >= 6 ))` (ROUND is always 1)
    log_debug "[GOV] iter=$iter phase=consensus round=$CONSENSUS_ROUND claude=$CLAUDE_VERDICT codex=$CODEX_VERDICT combined_action=$_combined_action"

    # Merge + verdict decision (shared with the parallel path — NO ENGINE PRIORITY).
    _consensus_finalize "$iter" "$cons_us_id" "$claude_verdict_file" "$codex_verdict_file"
    return $?
}

# =============================================================================
# Main Leader Loop
# =============================================================================

main() {
  # --- US-026 R14 P0: project-scoped runner lock (per-ROOT, regardless of slug) ---
  # D-9: delegate to acquire_slug_lock — the F-20-proven, race-safe primitive where
  # the PID *is* the lock (`set -C` atomic create writes the pid in one redirect),
  # so there is NO acquire/pid-write gap. The previous dir-based design (mkdir a dir
  # + a separate pid file) had a fundamental gap between acquiring the dir and
  # writing the pid that a recovery mutex alone could not close (codex D-9 R2).
  # Metadata (slug/root) goes to a sidecar for the duplicate message + audit.
  # Different ROOT_HASH → independent parallel runners across projects.
  mkdir -p "$(dirname "$RUNNER_LOCKFILE_PATH")" 2>/dev/null
  if acquire_slug_lock "$RUNNER_LOCKFILE_PATH"; then
    printf '{"pid":%s,"slug":"%s","root":"%s","started_at":"%s"}\n' \
      "$$" "$SLUG" "$ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${RUNNER_LOCKFILE_PATH}.meta" 2>/dev/null
  else
    local existing existing_slug
    existing=$(cat "$RUNNER_LOCKFILE_PATH" 2>/dev/null)
    existing_slug=$(jq -r '.slug // "unknown"' "${RUNNER_LOCKFILE_PATH}.meta" 2>/dev/null || echo unknown)
    echo "duplicate rlp-desk runner detected on this project root. existing pid=${existing:-unknown} slug=$existing_slug, this attempt slug=$SLUG. exiting." >&2
    echo "  Recover with: rm -f '$RUNNER_LOCKFILE_PATH' '${RUNNER_LOCKFILE_PATH}.meta' && rm -rf '${RUNNER_LOCKFILE_PATH}.recovery.d' (only if pid ${existing:-?} is confirmed dead)" >&2
    exit 1
  fi

  # --- Lockfile: prevent duplicate execution (ZSH-4 race-safe, v0.17.1) ---
  # Delegates to acquire_slug_lock (lib_ralph_desk.zsh): atomic set -C fast path +
  # mkdir-mutex-serialized, PID-reaped stale recovery. Race-safe vs concurrent
  # recoverers, gap-starters, and a crashed-recoverer mutex leak.
  if acquire_slug_lock "$LOCKFILE_PATH"; then
    LOCKFILE_ACQUIRED=1
  else
    local lock_pid
    lock_pid=$(cat "$LOCKFILE_PATH" 2>/dev/null)
    log_error "Another instance is already running or won the lock race (PID ${lock_pid:-unknown}). Kill it or rm $LOCKFILE_PATH"
    exit 1
  fi
  # US-023 R11 P2-K: chain `_emit_final_cost_log` so cost-log.jsonl is never silently empty on exit.
  # US-004 AC4.2: chain `_emit_launch_record_outcome` FIRST (so `$?` still reflects the
  # status that triggered the trap) for the best-effort launch-record.json outcome
  # update; HUP is added because tmux teardown delivers SIGHUP, which otherwise skips
  # this EXIT-only trap (SIGKILL remains untrappable — the t0 write above is the real
  # durability guarantee, not this trap).
  trap '_emit_launch_record_outcome; _emit_final_cost_log; cleanup' EXIT INT TERM HUP
  mkdir -p "$LOGS_DIR" "$RUNTIME_DIR" 2>/dev/null

  # --- Analytics directory: always create (campaign.jsonl + metadata.json are always-on) ---
  mkdir -p "$ANALYTICS_DIR" 2>/dev/null
  # IMP-03: hash-free pointer so Node-side readers (SV post-pass in run.mjs)
  # can locate this campaign's analytics dir without reproducing the intra-
  # machine md5 suffix. Written HERE (executed-main, after the mkdir above) —
  # NOT at the top-level config-parse block — so merely sourcing this script
  # (verify harnesses) has no filesystem side effect. Runs before
  # validate_scaffold; a later scaffold-validation failure leaves at worst a
  # consistent unused pointer (readers fall back when the target is absent).
  print -r -- "$ANALYTICS_DIR" > "$DESK/analytics/${SLUG}.current" 2>/dev/null

  # --- debug.log versioning (in analytics dir, --debug only) ---
  if (( DEBUG )) && [[ -f "$DEBUG_LOG" ]]; then
    local dbg_n=1
    while [[ -f "${DEBUG_LOG%.log}-v${dbg_n}.log" ]]; do
      (( dbg_n++ ))
    done
    mv "$DEBUG_LOG" "${DEBUG_LOG%.log}-v${dbg_n}.log"
  fi

  # --- campaign.jsonl versioning (always-on) ---
  if [[ -f "$CAMPAIGN_JSONL" ]]; then
    local cj_n=1
    while [[ -f "${CAMPAIGN_JSONL%.jsonl}-v${cj_n}.jsonl" ]]; do
      (( cj_n++ ))
    done
    mv "$CAMPAIGN_JSONL" "${CAMPAIGN_JSONL%.jsonl}-v${cj_n}.jsonl"
  fi

  # --- metadata.json: always write at campaign start (cross-project identification) ---
  local _metadata_consensus=0
  [[ "$CONSENSUS_MODE" != "off" ]] && _metadata_consensus=1
  jq -n \
    --arg slug "$SLUG" \
    --arg project_root "$ROOT" \
    --arg project_name "$(basename "$ROOT")" \
    --arg campaign_status "running" \
    --arg start_time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg end_time "" \
    --arg worker_model "$WORKER_MODEL" \
    --arg verifier_model "$VERIFIER_MODEL" \
    --argjson debug "$DEBUG" \
    --argjson with_sv "$WITH_SELF_VERIFICATION" \
    --argjson with_sv_requested "$WITH_SELF_VERIFICATION_REQUESTED" \
    --arg sv_skipped_reason "$SV_SKIPPED_REASON" \
    --arg lane_mode "$LANE_MODE" \
    --argjson consensus "$_metadata_consensus" \
    '{slug: $slug, project_root: $project_root, project_name: $project_name, campaign_status: $campaign_status, start_time: $start_time, end_time: $end_time, worker_model: $worker_model, verifier_model: $verifier_model, debug: $debug, with_self_verification: $with_sv, with_self_verification_requested: $with_sv_requested, sv_skipped_reason: $sv_skipped_reason, lane_mode: $lane_mode, consensus: $consensus}' \
    > "$METADATA_FILE"

  # --- Startup ---
  log "Ralph Desk Tmux Runner starting..."
  log "  Slug:            $SLUG"
  log "  Root:            $ROOT"
  log "  Max iterations:  $MAX_ITER"
  log "  Worker model:    $WORKER_MODEL"
  log "  Verifier model:  $VERIFIER_MODEL (per-US) / $FINAL_VERIFIER_MODEL (final)"
  log "  Verify mode:     $VERIFY_MODE"
  log "  Consensus mode:  $CONSENSUS_MODE"
  log "  Consensus model: $CONSENSUS_MODEL (per-US) / $FINAL_CONSENSUS_MODEL (final)"
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
    log_debug "[OPTION] verify_mode=$VERIFY_MODE consensus_mode=$CONSENSUS_MODE max_iter=$MAX_ITER"
    log_debug "[OPTION] cb_threshold=$CB_THRESHOLD effective_cb_threshold=$EFFECTIVE_CB_THRESHOLD iter_timeout=$ITER_TIMEOUT with_self_verification=$WITH_SELF_VERIFICATION (requested=$WITH_SELF_VERIFICATION_REQUESTED skipped=${SV_SKIPPED_REASON:-none}) debug=$DEBUG"

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

    if [[ "$CONSENSUS_MODE" != "off" ]]; then
      log_debug "[OPTION] consensus_flow=mode=$CONSENSUS_MODE each_verify_runs_claude+codex_both_must_pass"
    fi
  fi

  # Extract US list for per-US sequencing
  if [[ "$VERIFY_MODE" = "per-us" ]]; then
    local prd_file="$DESK/plans/prd-$SLUG.md"
    if [[ -f "$prd_file" ]]; then
      # D-23: a US story is a `### US-NNN:` HEADING, not any US-NNN mentioned in
      # prose/dependencies. The unanchored `grep -oE 'US-[0-9]+'` previously used
      # here pulled phantom US ids out of cross-references ("builds on US-009",
      # "Depends on: US-001"), inflating US_LIST + the coverage count and making
      # _all_us_verified (D-16) require a never-verifiable phantom → D-16 never
      # armed. It also DISAGREED with the live re-split (count_prd_us, anchored),
      # so the first PRD edit silently changed the tracked US set. Use the SAME
      # heading-anchored extraction as count_prd_us so initial == live.
      US_LIST=$(grep -oE '^### US-[0-9]+' "$prd_file" | sed 's/^### //' | sort -u | tr '\n' ',' | sed 's/,$//')
    fi

  # F-14 + status.json promotion (Item-4): VERIFIED_US restore precedence,
  # most-durable first —
  #   1. durable append-only ledger (leader-written, structured)
  #   2. status.json verified_us (leader serialization written EVERY phase by
  #      update_status — structured, reliable; promoted ABOVE the prose parse)
  #   3. the Worker's prose "## Completed Stories" — LAST resort (fresh-context
  #      LLM output that can drift; only legacy campaigns without 1 or 2 use it).
  if [[ -f "$VERIFIED_LEDGER" ]]; then
    local ledger_verified
    ledger_verified=$(jq -rR 'fromjson? | .us_id // empty' "$VERIFIED_LEDGER" 2>/dev/null | grep -E '^US-[0-9]+$' | sort -u | tr '\n' ',' | sed 's/,$//')
    if [[ -n "$ledger_verified" ]]; then
      VERIFIED_US="$ledger_verified"
      log "  Restored verified_us from durable ledger: $VERIFIED_US"
      log_debug "[FLOW] restored_verified_us_from_ledger=$VERIFIED_US"
    fi
  fi

    # 2nd source: status.json verified_us — structured leader serialization,
    # more reliable than the prose parse below (Item-4: promoted above prose).
    if [[ -z "$VERIFIED_US" && -f "$STATUS_FILE" ]]; then
      local status_verified
      status_verified=$(jq -r '.verified_us // [] | join(",")' "$STATUS_FILE" 2>/dev/null)
      if [[ -n "$status_verified" ]]; then
        VERIFIED_US="$status_verified"
        log "  Restored verified_us from status.json: $VERIFIED_US"
        log_debug "[FLOW] restored_verified_us_from_status=$VERIFIED_US"
      fi
    fi

  # LAST resort: the Worker's prose "## Completed Stories" (drift-prone; legacy).
  local memory_file="$DESK/memos/${SLUG}-memory.md"
  if [[ -z "$VERIFIED_US" && -f "$memory_file" ]]; then
      local completed_us
      completed_us=$(sed -n '/^## Completed Stories$/,/^## /p' "$memory_file" 2>/dev/null | grep '^- US-' | sed 's/^- \(US-[0-9]*\):.*/\1/' | sort -u | tr '\n' ',' | sed 's/,$//')
      if [[ -n "$completed_us" ]]; then
        VERIFIED_US="$completed_us"
        log "  Loaded completed stories from memory (last-resort prose): $VERIFIED_US"
        log_debug "[FLOW] loaded_verified_us_from_memory=$VERIFIED_US"
      fi
    fi

  fi

  # F-8 scope guard (F-19): snapshot the tracked files that are ALREADY dirty
  # before the campaign touches anything. The F-8 leader-recovery auto-commit
  # (Bug #8 Gate 3) must commit only the Worker's OWN edits and never sweep an
  # operator's pre-existing uncommitted work into a Worker-recovery commit.
  # `git diff --name-only HEAD` lists tracked files modified vs HEAD (staged or
  # not); untracked cruft is excluded and is never auto-committed. Empty when the
  # tree starts clean. Recorded once; excluded at recovery time in Gate 3.
  # request-b seal #3: this capture MUST precede the resume-finalize
  # derive_verification_mode call below — that call applies the ①b
  # preexisting-dirty exclusion, which is empty/unset until this line runs.
  # (Previously captured after the resume block, which nullified ①b on the
  # primary resumed-campaign path — the exact field case it was built for.)
  typeset -g CAMPAIGN_PREEXISTING_DIRTY
  # NEW-4: same HEAD-or-empty-tree base as Gate 3, so the pre-existing-dirty snapshot
  # and the recovery-time dirty check compare against the SAME baseline (the comm -23
  # exclusion in Gate 3 only works if both lists are computed against the same base).
  CAMPAIGN_PREEXISTING_DIRTY=$(git -C "$ROOT" diff --name-only "$(_git_dirty_base)" 2>/dev/null)

  # v0.22.3 (AC6 dogfood finding): resume finalize. If the durable ledger
  # already PROVES completion (the confirmation basis: full coverage, SHA
  # resolves and matches HEAD, PRD hash matches, tree clean), dispatching a
  # worker is not only wasteful — it deadlocks: a worker with nothing to
  # build reasons "no action needed", never writes a signal, and idles into
  # the no-progress guard (observed live). Arm D-16 so the first iteration
  # skips the worker round-trip and goes straight to the ALL verify, which
  # will re-derive confirmation mode for the verifiers. Any weaker state
  # (build basis) leaves the flag off and dispatches the worker as usual.
  local _resume_derived
  _resume_derived=$(derive_verification_mode "$VERIFIED_LEDGER" "$PRD_FILE" "$ROOT")
  if [[ "${_resume_derived%%|*}" == "confirmation" ]]; then
    _FINALIZE_PENDING=1
    log "  Resume finalize armed: ledger proves completion — skipping worker, dispatching ALL verify (${_resume_derived#*|})"
    log_debug "[FLOW] resume_finalize_armed=1 basis=\"${_resume_derived#*|}\""
  fi

  # F-13 (batch-safe): restore the circuit-breaker counter on relaunch. This runs
  # OUTSIDE the per-us block above because consecutive_failures is meaningful in
  # EVERY verify mode — a batch-mode campaign crash-loops the same way, so nesting
  # the restore under `per-us` let a batch relaunch reset its CB to 0 and evade the
  # breaker. status.json persists the counter (lib_ralph_desk.zsh) every phase;
  # only verified_us was ever read back. (verified_us restore stays per-us: batch
  # mode has no per-US progress to rehydrate.) Normal reset-on-progress applies.
  if [[ -f "$STATUS_FILE" ]]; then
    local _status_cf
    _status_cf=$(jq -r '.consecutive_failures // 0' "$STATUS_FILE" 2>/dev/null)
    if [[ "$_status_cf" == <-> && "$_status_cf" -gt 0 ]]; then
      CONSECUTIVE_FAILURES="$_status_cf"
      log "  Restored consecutive_failures from status.json: $CONSECUTIVE_FAILURES"
      log_debug "[FLOW] restored_consecutive_failures_from_status=$CONSECUTIVE_FAILURES"
    fi
    # US-001 AC1.3: restore the per-iteration HEAD snapshot so a relaunch/recovery
    # that re-enters mid-iteration (e.g. phase=verify operator recovery, where the
    # worker-dispatch capture at L4246 is skipped) judges the commit-integrity
    # oracle against the SAME baseline the crashed segment used.
    local _status_ish
    _status_ish=$(jq -r '.iter_start_head // ""' "$STATUS_FILE" 2>/dev/null)
    if [[ -n "$_status_ish" ]]; then
      ITER_START_HEAD="$_status_ish"
      log_debug "[FLOW] restored_iter_start_head_from_status=${ITER_START_HEAD[1,10]}"
    fi
    # D-5: also restore the consecutive-BLOCKS state so the now-live block CB
    # (F-22) survives a relaunch — otherwise a crash-loop resets it to 0 every
    # relaunch and the block breaker is evadable (the same durability hole F-13
    # closed for consecutive_failures). Restore last_block_reason too, else a
    # restored count is immediately reset on the next block (reason wouldn't match).
    local _status_cb _status_lbr
    _status_cb=$(jq -r '.consecutive_blocks // 0' "$STATUS_FILE" 2>/dev/null)
    _status_lbr=$(jq -r '.last_block_reason // ""' "$STATUS_FILE" 2>/dev/null)
    # D-5 fix: restore ATOMICALLY — both the count AND the reason, or neither. A
    # count without its reason is a useless half-state (the next block's reason
    # wouldn't match the empty LAST_BLOCK_REASON and would reset the count to 1
    # anyway), so require both to be present before applying.
    if [[ "$_status_cb" == <-> && "$_status_cb" -gt 0 && -n "$_status_lbr" ]]; then
      CONSECUTIVE_BLOCKS="$_status_cb"
      LAST_BLOCK_REASON="$_status_lbr"
      log "  Restored consecutive_blocks from status.json: $CONSECUTIVE_BLOCKS"
      log_debug "[FLOW] restored_consecutive_blocks_from_status=$CONSECUTIVE_BLOCKS"
    fi
    # D-5b (restore-priority, user-chosen): if the Worker was AUTO-upgraded during a
    # prior segment (model_upgraded==1), restore the upgraded model + its engine
    # triple + the upgrade bookkeeping, so a crash-relaunch resumes at the upgraded
    # model (and the architecture-escalation trigger survives) instead of silently
    # reverting to the base model and re-spending iterations to re-upgrade. Gated on
    # model_upgraded==1 so it ONLY overrides for the auto-upgrade case (a fresh
    # campaign that never upgraded keeps the env/CLI model).
    local _status_mu
    _status_mu=$(jq -r '.model_upgraded // 0' "$STATUS_FILE" 2>/dev/null)
    if [[ "$_status_mu" == "1" ]]; then
      local _s_wm _s_we _s_wcm _s_wcr _s_owm _s_sufc
      _s_wm=$(jq -r '.worker_model // empty' "$STATUS_FILE" 2>/dev/null)
      _s_we=$(jq -r '.worker_engine // empty' "$STATUS_FILE" 2>/dev/null)
      _s_wcm=$(jq -r '.worker_codex_model // empty' "$STATUS_FILE" 2>/dev/null)
      _s_wcr=$(jq -r '.worker_codex_reasoning // empty' "$STATUS_FILE" 2>/dev/null)
      _s_owm=$(jq -r '.original_worker_model // empty' "$STATUS_FILE" 2>/dev/null)
      _s_sufc=$(jq -r '.same_us_fail_count // 0' "$STATUS_FILE" 2>/dev/null)
      if [[ -n "$_s_wm" && -n "$_s_we" ]]; then
        _MODEL_UPGRADED=1
        WORKER_MODEL="$_s_wm"; WORKER_ENGINE="$_s_we"
        [[ -n "$_s_wcm" ]] && WORKER_CODEX_MODEL="$_s_wcm"
        [[ -n "$_s_wcr" ]] && WORKER_CODEX_REASONING="$_s_wcr"
        [[ -n "$_s_owm" ]] && _ORIGINAL_WORKER_MODEL="$_s_owm"
        [[ "$_s_sufc" == <-> ]] && _SAME_US_FAIL_COUNT="$_s_sufc"
        log "  Restored auto-upgraded Worker model: $WORKER_MODEL ($WORKER_ENGINE), orig=${_ORIGINAL_WORKER_MODEL:-?}, same_us_fails=$_SAME_US_FAIL_COUNT (D-5b restore-priority)"
        log_debug "[FLOW] restored_model_upgrade=true worker_model=$WORKER_MODEL engine=$WORKER_ENGINE same_us_fail=$_SAME_US_FAIL_COUNT"
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

  # (merge note, trackB x v0.22.8): the CAMPAIGN_PREEXISTING_DIRTY capture that
  # trackB's base had here was moved EARLIER in main() by v0.22.8 "request-b
  # seal #3" — it must precede the resume-finalize derive_verification_mode
  # call. The single capture site above serves F-8 Gate 3, the ①b mode gate,
  # AND the US-001 oracle tracked-delta exclusion.

  # US-002 AC2.5 (reload point #1 — FRESH campaign entry): load + validate
  # .rlp-desk/plans/waivers.json once, authorized out-of-band via
  # RLP_WAIVERS_SHA256. Fail-closed; honored waivers persist in
  # WAIVERS_HONORED_LINES and are injected into both prompts each iteration.
  typeset -ga WAIVERS_HONORED_LINES; typeset -g WAIVER_REJECTION_SUMMARY=""
  typeset -g WAIVERS_AUTHORIZED_SHA=""
  load_campaign_waivers "$DESK/plans/waivers.json" "$SLUG" "${RLP_WAIVERS_SHA256:-}" "$ROOT"

  # Validate scaffold
  validate_scaffold

  # Check for existing sessions
  check_existing_sessions

  # Create tmux session with pane IDs (governance.md s7 step 1)
  create_session

  # D-22 batch: the EXIT cleanup trap is already armed (EXIT INT TERM HUP) right after
  # lock acquisition above; a second `trap … EXIT` here was redundant (it re-armed
  # only EXIT with the identical handler — INT/TERM already persist — and cleanup()
  # is CLEANUP_DONE-idempotent anyway). Removed; the earlier arm covers this scope.

  # Initialize context hash for stale detection
  PREV_CONTEXT_HASH=$(compute_context_hash)

  # --- governance.md s7: Leader Loop ---
  local HARD_CEILING=$(( ITER_TIMEOUT * 3 ))  # logged but NOT enforced — Worker extends indefinitely when active

  for (( ITERATION = 1; ITERATION <= MAX_ITER; ITERATION++ )); do
    # B3 (zsh-leader port): reset the lifecycle accumulator at iteration entry.
    # CORRECTNESS (not a telemetry-loss bug — verified): a "continue"/start-failed
    # iteration `continue`s BEFORE write_campaign_jsonl (e.g. worker-continue at the
    # `continue)` case, verifier start_failed), so it writes NO campaign.jsonl row at
    # all. This matches the Node leader, whose appendIterationAnalytics
    # (campaign-main-loop.mjs:2101/2117/2156) appends a row ONLY on pass/fail/blocked,
    # never on continue. A pane reap on such an iteration therefore leaves records here
    # with no row to flush into; discarding them at the NEXT iteration entry prevents
    # MIS-ATTRIBUTING them to that next row.
    # codex round 2 R2-3: the unconditional reset below used to ALSO wipe a
    # FAILED flush's retained records (F6 keeps LIFECYCLE_RECORDS intact on
    # an append/build failure specifically so the NEXT flush can retry
    # them) — defeating F6's whole point before that retry ever got a
    # chance to run. Guard on _LC_FLUSH_ATTEMPTED (set by write_campaign_jsonl
    # on every call, success or failure): only discard when the PREVIOUS
    # iteration never attempted a flush at all (the row-less continue case
    # above); when it attempted and failed, leave the records for this
    # iteration's flush to retry.
    if (( ! _LC_FLUSH_ATTEMPTED )); then
      LIFECYCLE_RECORDS=()
    fi
    _LC_FLUSH_ATTEMPTED=0
    # US-024 R12 P0: lifecycle check site #2 — verify session/panes alive at iter entry.
    _r12_check_lifecycle "iter_start"
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

    # PR-A (Bug #10): operator-recovery hygiene check.
    # When the operator hand-rolls a `phase=verify` recovery (jq-patches
    # status.json, writes manual iter-signal.json + done-claim.json, deletes
    # the blocked sentinel), the leader MUST honor that work instead of
    # deleting the artifacts and resetting to phase=worker. Mirrors the
    # Node-side guard in src/node/runner/campaign-main-loop.mjs.
    local SKIP_NEXT_WORKER=0
    local LAST_PHASE=""
    if [[ -f "$STATUS_FILE" ]] && command -v jq >/dev/null 2>&1; then
      LAST_PHASE=$(jq -r '.phase // ""' "$STATUS_FILE" 2>/dev/null)
    fi
    if [[ "$LAST_PHASE" == "verify" ]]; then
      local _iter_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).worker-prompt.md"
      if _validate_operator_recovery_artifacts \
           "$SIGNAL_FILE" "$DONE_CLAIM_FILE" "$STATUS_FILE" "$_iter_prompt"; then
        log "[recovery] Resuming verify phase — operator manual recovery detected (iter=$ITERATION)"
        log_debug "[recovery] iter=$ITERATION skip_worker=true reason=manual_recovery_validated"
        SKIP_NEXT_WORKER=1
        # US-002 AC2.5 (reload point #2 — Bug #10 operator-recovery resume):
        # re-read + re-authorize waivers.json here. An operator who authored a
        # new baseline artifact + waiver during the BLOCK supplies a fresh
        # --waivers-sha256 on resume; a matching hash rotates the authorized
        # snapshot (AC2.4b) and honors the new waiver. A stale/absent hash
        # rejects unauthorized_hash_change — a worker cannot smuggle a waiver in.
        load_campaign_waivers "$DESK/plans/waivers.json" "$SLUG" "${RLP_WAIVERS_SHA256:-}" "$ROOT"
        # v0.22.3 (early-review P1-1): the preserved done-claim's evidence was
        # produced under a PREVIOUS leader; anchor the freshness window to the
        # claim file's own mtime so PR-A-accepted evidence is judged against
        # the window it actually ran in (PR-A validation gates its integrity).
        if [[ -z "${ITER_WINDOW_START:-}" && -f "$DONE_CLAIM_FILE" ]]; then
          local _dc_epoch
          _dc_epoch=$(stat -f %m "$DONE_CLAIM_FILE" 2>/dev/null || stat -c %Y "$DONE_CLAIM_FILE" 2>/dev/null || echo "")
          if [[ -n "$_dc_epoch" ]]; then
            ITER_WINDOW_START=$(date -u -r "$_dc_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null               || date -u -d "@$_dc_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
          fi
        fi
      else
        log "[recovery] phase=verify ignored: ${RECOVERY_FAIL_REASON}"
        log_debug "[recovery] iter=$ITERATION skip_worker=false reason=\"${RECOVERY_FAIL_REASON}\""
      fi
    fi

    # PR-E (Phase C1, stabilization): operator-cleared BLOCKED recovery.
    # Pair to PR-A above. Runs AFTER PR-A (so phase=verify wins) and skipped
    # when SKIP_NEXT_WORKER=1 (PR-A already honored). Resets stale counters
    # in status.json when operator manually deleted the BLOCKED sentinel.
    # Mirrors Node `_validateBlockedRecovery` + branch in campaign-main-loop.mjs.
    if [[ "$LAST_PHASE" == "blocked" && "$SKIP_NEXT_WORKER" -eq 0 ]]; then
      local _blocked_sidecar="$MEMOS_DIR/${SLUG}-blocked.json"
      if _validate_blocked_recovery \
           "$BLOCKED_SENTINEL" "$_blocked_sidecar" "$STATUS_FILE"; then
        local _prev_reason
        _prev_reason=$(jq -r '.last_block_reason // ""' "$STATUS_FILE" 2>/dev/null)
        log "[recovery] Operator-cleared BLOCKED detected (was: ${_prev_reason:-unrecorded}). Resetting counters and resuming as worker. iter=$ITERATION"
        log_debug "[recovery] iter=$ITERATION blocked_recovery=applied reason=\"${BLOCKED_RECOVERY_FAIL_REASON:-sidecar absent or recoverable=true}\""
        # Reset counters in-process. update_status writes fresh status when
        # next phase transition fires. Operator's intent was a clean restart.
        CONSECUTIVE_FAILURES=0
        CONSECUTIVE_BLOCKS=0
        LAST_BLOCK_REASON=""
        # Archive sidecar (rename, not delete) for audit trail.
        _archive_recovered_sidecar "$_blocked_sidecar"
      else
        log "[recovery] phase=blocked ignored: ${BLOCKED_RECOVERY_FAIL_REASON}"
        log_debug "[recovery] iter=$ITERATION blocked_recovery=skipped reason=\"${BLOCKED_RECOVERY_FAIL_REASON}\""
      fi
    fi

    # D-16: leader-driven finalize. The previous iteration's last per-US pass
    # completed coverage and armed _FINALIZE_PENDING instead of dispatching a
    # worker round-trip to emit an ALL signal. Synthesize that ALL verify signal
    # ourselves and skip the worker; the existing verify path (signal_us_id=ALL →
    # run_sequential_final_verify) handles completion AND the fix-loop on failure.
    # Operator recovery (PR-A) takes precedence — only finalize if it did not claim
    # this iteration. A crash before this point loses the flag and safely falls
    # back to the worker round-trip (the pre-D-16 path).
    if (( _FINALIZE_PENDING )) && [[ "$SKIP_NEXT_WORKER" -eq 0 ]]; then
      _FINALIZE_PENDING=0
      log "  Leader finalize (D-16): all US verified ($VERIFIED_US) — synthesizing ALL verify signal, skipping worker round-trip."
      log_debug "[FLOW] iter=$ITERATION d16_finalize=true verified_us=$VERIFIED_US"
      # codex round 3: this atomic_write fires BEFORE the loop-top `if (( !
      # SKIP_NEXT_WORKER ))` unlock block below — and this branch itself just
      # set SKIP_NEXT_WORKER=1, so that unlock block is SKIPPED this pass. The
      # previous iteration's SIGNAL_FILE lock-mark (from its worker-success
      # lock) is therefore still pending when this write replaces the file.
      # Safe by construction now: atomic_write() clears the pending mark for
      # SIGNAL_FILE's basename itself. (A round-2 comment here previously
      # claimed this site was safe because "nothing was pending" — wrong; it
      # was safe only because the worker-success branch a few lines below
      # re-locks and overwrites the stale mark before any unlock could pair
      # with it. The hook makes that coincidence-of-ordering unnecessary.)
      printf '{"iteration": %d, "status": "verify", "us_id": "ALL", "summary": "leader finalize (D-16: all per-US verified)", "timestamp": "%s"}\n' \
        "$ITERATION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" | atomic_write "$SIGNAL_FILE"
      update_status "verify" "running"
      SKIP_NEXT_WORKER=1
    else
      # Any normally-dispatched iteration clears a stale arm (defensive; the flag
      # is consumed above on the immediately-following iteration in practice).
      _FINALIZE_PENDING=0
    fi

    if (( ! SKIP_NEXT_WORKER )); then
      # --- governance.md s7 step 8 (cleanup): Clean previous iteration signals ---
      # Bug #7 Fix-R cleanup: unlock 0o444 sentinels written by the previous
      # iteration's reaper before rm so cleanup does not log permission noise.
      if _unlock_sentinel "$SIGNAL_FILE"; then
        # v0.15.4 full-wire: sentinel_lock_to_unlock_ms pair close, mirrors
        # campaign-main-loop.mjs:1632-1635. codex P2 sweep F3: only mark the
        # unlock when it actually succeeded — an unlock that fails (chmod
        # error) is not a real unlock event and should not be timed.
        _lifecycle_mark_unlock "${SIGNAL_FILE:t}" "$ITERATION"
      fi
      if _unlock_sentinel "$VERDICT_FILE"; then
        _lifecycle_mark_unlock "${VERDICT_FILE:t}" "$ITERATION"
      fi
      rm -f "$SIGNAL_FILE" "$DONE_CLAIM_FILE" "$VERDICT_FILE" "$LEGACY_VERDICT_FILE" 2>/dev/null   # D-26: + legacy verdict
      rm -f "$WORKER_HEARTBEAT" "$VERIFIER_HEARTBEAT" 2>/dev/null

      # --- Clean previous claude session in panes (one-shot lifecycle) ---
      # Only needed from iteration 2 onwards (iteration 1 has fresh panes)
      if (( ITERATION > 1 )); then
        # Send C-c first (in case claude is mid-task), then /exit
        tmux send-keys -t "$WORKER_PANE" C-c 2>/dev/null
        sleep 1
        tmux send-keys -t "$WORKER_PANE" "/exit" C-m 2>/dev/null
        sleep 2
        # Wait for shell prompt before proceeding
        wait_for_pane_ready "$WORKER_PANE" 10 2>/dev/null || true
      fi
    fi

    # Reset per-iteration state
    local worker_nudge_count=0
    local verifier_nudge_count=0
    ITER_VERIFIER_START=""
    ITER_VERIFIER_END=""

    # --- US-004: detect PRD changes for live update + re-split ---
    check_prd_update

    # AC1: capture worker start timestamp (still set for downstream telemetry
    # even when the worker dispatch is skipped — recovery still consumes time).
    ITER_WORKER_START=$(date +%s)

    local worker_launch=""
    if (( ! SKIP_NEXT_WORKER )); then
      # v0.22.3 US-001 (early-review P1-1): iteration window start is stamped
      # ONLY when a worker is actually dispatched. D-16 finalize and PR-A
      # preserved-artifact iterations reuse the window their evidence was
      # produced in — resetting here would make every preserved done-claim's
      # timestamps predate the window and fail confirmation freshness forever.
      ITER_WINDOW_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      # US-001 AC1.3: per-iteration HEAD snapshot, captured ONLY when a worker is
      # actually dispatched (recovery/finalize iterations reuse the restored
      # snapshot, same rationale as ITER_WINDOW_START). '' when the repo has no
      # commits yet — the oracle treats the first commit as an advance. Persisted
      # to status.json by update_status below and restored on relaunch so a
      # crash-and-relaunch into verify re-enters with the correct baseline.
      ITER_START_HEAD=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo "")
      # --- governance.md s7 step 4: Build worker prompt + trigger ---
      write_worker_trigger "$ITERATION"
      local worker_prompt="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).worker-prompt.md"

      update_status "worker" "running"

      # --- governance.md s7 step 5: Execute Worker (dispatched to engine-specific function) ---
      log_debug "[FLOW] iter=$ITERATION phase=worker engine=$WORKER_ENGINE model=$WORKER_MODEL dispatched=true"

      # F-11: a pane-start failure is usually the transient F6.1 spawn race
      # (send-keys before the pane's shell is ready). Replace the pane and retry
      # ONCE before BLOCKing, instead of terminating the campaign on a transient.
      if [[ "$WORKER_ENGINE" = "codex" ]]; then
        worker_launch="${CODEX_BIN:-codex} -m $WORKER_CODEX_MODEL -c model_reasoning_effort=\"$WORKER_CODEX_REASONING\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
        if ! launch_worker_codex "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
          log "  Worker codex failed to start — replacing pane and retrying once (F-11)."
          log_debug "[GOV] iter=$ITERATION worker_start_failed=true action=replace_retry engine=codex"
          replace_worker_pane "$WORKER_PANE" "worker"
          WORKER_PANE=$(jq -r '.panes.worker' "$SESSION_CONFIG")
          if ! launch_worker_codex "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
            write_blocked_sentinel "Worker codex failed to start in pane after replace+retry" "" "infra_failure"
            update_status "blocked" "worker_start_failed"
            return 1
          fi
        fi
      else
        worker_launch="$(build_claude_cmd tui "$WORKER_MODEL" "" "" "$WORKER_EFFORT")"
        if ! launch_worker_claude "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
          log "  Worker claude failed to start — replacing pane and retrying once (F-11)."
          log_debug "[GOV] iter=$ITERATION worker_start_failed=true action=replace_retry engine=claude"
          replace_worker_pane "$WORKER_PANE" "worker"
          WORKER_PANE=$(jq -r '.panes.worker' "$SESSION_CONFIG")
          if ! launch_worker_claude "$WORKER_PANE" "$worker_prompt" "$ITERATION" "$worker_launch"; then
            write_blocked_sentinel "Worker claude failed to start in pane after replace+retry" "" "infra_failure"
            update_status "blocked" "worker_start_failed"
            return 1
          fi
        fi
      fi
    else
      # PR-A (Bug #10): one-shot recovery path. The operator's iter-signal.json
      # is already on disk; polling below picks it up immediately and the loop
      # transitions cleanly into the verifier phase. Persist phase=verify so a
      # subsequent crash-and-relaunch sees the same contract. SKIP_NEXT_WORKER
      # is local to this iteration so iter-N+1 dispatches the worker normally.
      update_status "verify" "running"
      log "[recovery] Skipping worker dispatch for iter=$ITERATION (one-shot, honoring operator manual recovery)"
    fi

    # --- governance.md s7 step 5+6: Poll for Worker completion ---
    # US-024 R12 P0: lifecycle check site #3 — verify panes alive after worker dispatch, before wait-loop.
    _r12_check_lifecycle "post_send"
    log "  Polling for iter-signal.json..."
    local worker_poll_done=0
    while (( ! worker_poll_done )); do
      local worker_poll_rc=0
      if poll_for_signal "$SIGNAL_FILE" "$WORKER_HEARTBEAT" "$WORKER_PANE" "$worker_launch" "Worker"; then
        worker_poll_done=1
        log_debug "[FLOW] iter=$ITERATION poll_signal_received=true"
        # v0.15.4 full-wire: iter_signal_write_to_read_ms (leader poll-resolve vs
        # worker FS write), mirrors campaign-main-loop.mjs:2006-2016.
        # codex P2 sweep F2 + round-2 R2-1: capture fork-free now, emit (fork-bearing) after the reap.
        _lifecycle_capture_write_to_read "$SIGNAL_FILE"
        local _lc_wtr3="$_LC_CAPTURED_DELTA"
        # Bug #7 Fix-Q/R: reap worker pane immediately so claude/codex cannot
        # self-review and rewrite iter-signal.json (1m43s drift observed).
        # v0.15.4 full-wire: 3rd arg tags this reap as sentinel-triggered
        # (pane_reap_latency_ms), since it follows a fresh iter-signal detection.
        # codex round 2 R2-2: skip when poll_for_signal's A4 fallback branch
        # already reaped this SAME pane (tagged "iter-signal-a4") while
        # synthesizing the signal file — reaping again would double-count
        # pane_eof_to_cleanup_ms and waste a full C-c×2 + wait round-trip on
        # an already-dead pane.
        # codex round 3 R3-2: _kill_pane_process is fail-open (always
        # returns 0 — other callers depend on that contract, so it is not
        # changed here) — the A4 flag alone only proves a reap was
        # ATTEMPTED, not that the producer actually died. A cheap liveness
        # recheck (same #{pane_current_command} probe used elsewhere in this
        # file) decides whether a second reap is genuinely still needed.
        local _worker_reap_needed=1
        # codex round 4: fail-SAFE recheck — skip only on a successful probe
        # showing a bare idle shell; probe failure/unknown command => reap.
        if (( _POLL_A4_ALREADY_REAPED )) && ! _a4_pane_still_needs_reap "$WORKER_PANE"; then
          _worker_reap_needed=0
        fi
        if (( _worker_reap_needed )); then
          _kill_pane_process "$WORKER_PANE" "worker" "iter-signal"
        fi
        _lifecycle_emit_write_to_read "iter_signal_write_to_read_ms" "$SIGNAL_FILE" "$_lc_wtr3" "$ITERATION" "${CURRENT_US:-ALL}"
        # v0.15.4 full-wire: markLockStart BEFORE the chmod (H3 ordering contract).
        # codex P2 sweep F5: pass the CURRENT iter so the mark is attributed to it.
        _lifecycle_mark_lock_start "${SIGNAL_FILE:t}" "$ITERATION"
        if ! _lock_sentinel "$SIGNAL_FILE"; then
          # codex P2 sweep F3: same note as run_single_verifier (VERDICT_FILE).
          _lifecycle_clear_lock_mark "${SIGNAL_FILE:t}"
        fi
        # v0.15.4 PR-B2-FIX: same worker pass also produced done-claim. Freeze
        # it alongside iter-signal so Bug #8 gates and the iter-NNN-done-claim
        # archive (lib_ralph_desk.zsh:602) read a snapshot the worker can no
        # longer revise. Symmetric with iter-signal/verdict lock contract.
        # codex P2 sweep F3: no adjacent mark (H2 exclusion — done-claim is
        # never unlocked in the happy path, so it's never mark-tracked); the
        # return code is genuinely unused here, made explicit.
        _lock_sentinel "$DONE_CLAIM_FILE" || true
        # PR-0b-narrow: stamp leader handshake ack on the iter-signal (audit-only).
        _stamp_ack_field "$SIGNAL_FILE"
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
            write_blocked_sentinel "3 consecutive monitor failures (worker not active)" "" "infra_failure"
            update_status "blocked" "monitor_failures"
            return 1
          fi
          log "  WARNING: Worker poll failed (monitor failure $MONITOR_FAILURE_COUNT/3) — will retry"
          update_status "worker" "poll_failed"
          log_debug "[FLOW] iter=$ITERATION poll_worker_dead=true worker_cmd=$worker_cmd retry=true"
          # v0.14.3 P0-5 (Bug Report #5): previously this branch wrote BLOCKED
          # unconditionally even at counter 1/3, so a single transient
          # worker-dead detection halted the campaign in 5s instead of
          # honoring the 3-strike circuit breaker above (L3001-3006). Removed
          # the unconditional sentinel write; the loop now continues so the
          # next polling tick can either confirm the dead state (counter
          # eventually reaches 3 → BLOCKED) or recover (worker resumes →
          # MONITOR_FAILURE_COUNT reset on success at L3025).
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
      verify_partial)
        # US-019 R7 P1-G: Worker explicitly verified a subset of ACs and deferred the rest.
        # Verifier evaluates only verified_acs. Malformed (empty verified_acs) downgrades to blocked.
        local vp_count
        vp_count=$(jq -r '.verified_acs // [] | length' "$SIGNAL_FILE" 2>/dev/null || echo 0)
        if [[ "$vp_count" -eq 0 ]]; then
          # F-12: a Worker formatting slip (verify_partial with empty verified_acs)
          # is recoverable — route it back to the Worker as a soft-fail BOUNDED by
          # the consecutive-failure circuit breaker, instead of a terminal
          # mission_abort that ends the whole campaign on a single malformed signal.
          # A fresh-context Worker that keeps malforming still trips the CB and
          # blocks; one slip just costs an iteration.
          local vp_us_id
          vp_us_id=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
          (( CONSECUTIVE_FAILURES++ ))
          log "  Worker verify_partial malformed (empty verified_acs) — soft-fail retry $CONSECUTIVE_FAILURES/$EFFECTIVE_CB_THRESHOLD (bounded by CB)."
          log_debug "[GOV] iter=$ITERATION verify_partial_malformed=soft_fail consecutive_failures=$CONSECUTIVE_FAILURES threshold=$EFFECTIVE_CB_THRESHOLD"
          update_status "worker" "verify_partial_malformed_retry"
          if (( CONSECUTIVE_FAILURES >= EFFECTIVE_CB_THRESHOLD )); then
            log_error "  verify_partial_malformed repeated $CONSECUTIVE_FAILURES times (>= $EFFECTIVE_CB_THRESHOLD) — blocking."
            write_blocked_sentinel "verify_partial_malformed repeated $CONSECUTIVE_FAILURES times" "${vp_us_id:-${CURRENT_US:-ALL}}" "repeat_axis"
            update_status "blocked" "verify_partial_malformed_cb"
            # request-b incidental #2: was `break`, which fell through to the
            # post-loop "Max iterations reached" path — mislabeling this BLOCKED
            # as a timeout (status overwritten to timeout/max_iter) even though it
            # still returned 1. Return 1 DIRECTLY so the exit stays non-zero AND
            # the terminal status/label remains BLOCKED.
            return 1
          fi
          continue
        fi
        log "  Worker signal verify_partial (verified_acs count=$vp_count). Routing to verify path."
        signal_status="verify"
        ;&
      verify)
        # --- governance.md s7 step 7: Execute Verifier ---
        # Read us_id from signal for per-US scoping
        local signal_us_id=""
        signal_us_id=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
        # F-23: normalize case so a Worker emitting "all"/"All" still triggers the
        # final/ALL verify + completion paths (which match "ALL" exactly). US ids
        # are already uppercase ("US-001"), so this is a no-op for well-formed ids.
        signal_us_id="${signal_us_id:u}"
        # D-11: the US under verification is the in-flight US for lifecycle sentinels
        # fired during the verify poll (no-progress / stall / R12).
        [[ -n "$signal_us_id" ]] && CURRENT_US="$signal_us_id"
        log "  Worker claims done (us_id=${signal_us_id:-all}). Dispatching Verifier..."

        # --- US-001: leader-side done-claim commit-integrity oracle ---
        # Runs on the shared post-done-claim-lock path (normal, codex-synth, and
        # operator-recovery signals all converge here after the done-claim lock at
        # L4352), BEFORE the pre-gate layers below — the oracle is the cheapest
        # leader-side check (pure git). Fires ONLY when the done-claim asserts a
        # successful commit; a no-commit claim (verify_existing/confirmation) or a
        # corroborated claim is a silent no-op → falls through to the pre-gate.
        # On mismatch it takes the SAME short-circuit shape as the pre-gate (skip
        # LLM verification, redispatch the Worker with a machine-generated fix
        # contract, `continue`) via a DISTINCT ORACLE counter; at the cap it forces
        # one full verifier round (whose verdict drives the CB — Principle 4).
        local _oracle_rc=0
        _commit_oracle_check "$DONE_CLAIM_FILE" "${ITER_START_HEAD:-}" || _oracle_rc=$?
        if (( _oracle_rc == 1 )); then
          if _oracle_register_fail "$ITERATION" "${signal_us_id:-ALL}"; then
            log "  Commit-integrity oracle FAILED (${ORACLE_REASON}) — skipping LLM verification, redispatching Worker (oracle fail ${ORACLE_FAILURES}/${ORACLE_FAIL_CAP})."
            log_debug "[DECIDE] iter=$ITERATION phase=oracle_fail trigger=oracle reason=${ORACLE_REASON} oracle_failures=$ORACLE_FAILURES fix_contract=$LOGS_DIR/iter-$(printf '%03d' $ITERATION).fix-contract.md"
            update_status "verifier" "oracle_fail"
            continue
          else
            log "  Commit-integrity oracle failed ${ORACLE_FAIL_CAP}× for ${signal_us_id:-ALL} — forcing full LLM verifier round."
            log_debug "[GOV] iter=$ITERATION phase=oracle action=force_verifier reason=${ORACLE_REASON} us=${signal_us_id:-all}"
          fi
        fi

        # --- Feature 1: leader-side mechanical pre-gate ---
        # Deterministic campaign-defined checks ($DESK/plans/pregate-<slug>.sh) run
        # BEFORE any LLM verifier is dispatched. On fail we skip LLM verification
        # entirely and redispatch the Worker with the mechanical output as the fix
        # contract (same worker-redispatch machinery as a verify-fail round). This
        # can ONLY early-FAIL — a pass proceeds to the unchanged full verification.
        # The pre-gate has its own counter (PREGATE_FAILURES) so it never touches
        # the consecutive-failure circuit breaker; when the same US fails the
        # pre-gate PREGATE_FAIL_CAP times, we force one full LLM verifier round
        # (its verdict then drives the CB as normal) instead of another short-circuit.
        # Two layers, same insertion point (before write_verifier_trigger), in order:
        #   Layer 1 — campaign-static gate script ($DESK/plans/pregate-<slug>.sh).
        #   Layer 2 — replay of verify-* commands the Worker recorded in
        #             done-claim.json execution_steps; a claimed exit that does not
        #             reproduce is a fail.
        # Both feed the SAME per-US PREGATE_FAILURES 3-cap and can ONLY early-FAIL —
        # a pass proceeds to the unchanged full LLM verification (Iron Law). On the
        # 3rd same-US pre-gate fail we force one full verifier round (its verdict
        # drives the CB). _pg_short = short-circuit+redispatch; _pg_force = forced round.
        local _pg_short=0 _pg_force=0
        local _pg_t0=$(date +%s)
        local _pg_deadline=$(( _pg_t0 + ${RLP_PREGATE_TIMEOUT:-300} ))

        # --- Layer 1: static gate script ---
        run_pregate "$ITERATION" "$SLUG"
        if (( PREGATE_RAN )); then
          log_debug "[GOV] iter=$ITERATION phase=pregate layer=1 exit=$PREGATE_EXIT dur=${PREGATE_DUR}s us=${signal_us_id:-all}"
          if (( PREGATE_EXIT != 0 )); then
            if _pregate_register_fail "$ITERATION" "${signal_us_id:-ALL}"; then
              log "  Pre-gate L1 FAILED (exit=$PREGATE_EXIT, ${PREGATE_DUR}s) — skipping LLM verification, redispatching Worker (pre-gate fail ${PREGATE_FAILURES}/${PREGATE_FAIL_CAP})."
              _pg_short=1
            else
              log "  Pre-gate L1 failed ${PREGATE_FAIL_CAP}× for ${signal_us_id:-ALL} — forcing full LLM verifier round."
              log_debug "[GOV] iter=$ITERATION phase=pregate action=force_verifier layer=1 us=${signal_us_id:-all}"
              _pg_force=1
            fi
          fi
        fi

        # --- Layer 2: execution_steps replay (only if L1 did not already resolve) ---
        if (( ! _pg_short && ! _pg_force )); then
          run_pregate_replay "$ITERATION" "$_pg_deadline"
          if (( PREGATE_REPLAY_RAN )); then
            log_debug "[GOV] iter=$ITERATION phase=pregate layer=2 replay_fail=$PREGATE_REPLAY_FAIL us=${signal_us_id:-all}"
          fi
          if (( PREGATE_REPLAY_FAIL )); then
            if _pregate_register_fail_replay "$ITERATION" "${signal_us_id:-ALL}"; then
              log "  Pre-gate L2 FAILED (replay mismatch: ${PREGATE_REPLAY_STEP} claimed=${PREGATE_REPLAY_CLAIMED} actual=${PREGATE_REPLAY_ACTUAL}) — skipping LLM verification, redispatching Worker (pre-gate fail ${PREGATE_FAILURES}/${PREGATE_FAIL_CAP})."
              _pg_short=1
            else
              log "  Pre-gate L2 failed ${PREGATE_FAIL_CAP}× for ${signal_us_id:-ALL} — forcing full LLM verifier round."
              log_debug "[GOV] iter=$ITERATION phase=pregate action=force_verifier layer=2 us=${signal_us_id:-all}"
              _pg_force=1
            fi
          fi
        fi

        # --- Resolve the pre-gate decision ---
        if (( _pg_short )); then
          # Short-circuit: LLM verification skipped, Worker redispatched with the
          # fix contract written by the register-fail helper (L1 or L2).
          log_debug "[DECIDE] iter=$ITERATION phase=pregate_fail trigger=pregate pregate_failures=$PREGATE_FAILURES fix_contract=$LOGS_DIR/iter-$(printf '%03d' $ITERATION).fix-contract.md"
          update_status "verifier" "pregate_fail"
          continue
        elif (( ! _pg_force )); then
          # Both layers passed / absent — a real verifier round follows; reset streak.
          PREGATE_FAILURES=0
          _PREGATE_FAIL_US=""
        fi

        # AC1: capture verifier start timestamp
        ITER_VERIFIER_START=$(date +%s)

        update_status "verifier" "running"

        # --- Sequential final verify: per-US scoped checks instead of one big ALL verify ---
        # D-21: do NOT take the sequential single-verifier path when consensus applies to
        # the final verify — it would BYPASS consensus entirely (run_sequential_final_verify
        # returns 0 before the consensus check below), so `--consensus final-only` was a
        # silent no-op in the DEFAULT per-us mode (the recommended consensus config). When
        # consensus is on, fall through to run_consensus_verification "ALL" (which uses the
        # stricter FINAL_VERIFIER_MODEL + FINAL_CONSENSUS_MODEL and the designed
        # claude+codex final path). The per-US timeout-prevention split is the off-consensus
        # optimization only.
        # The `-n "$US_LIST"` precondition is CORRECT and protective: when US_LIST
        # is empty (a PRD with no `### US-` stories — the init "full PRD fallback"
        # case), this routes the ALL verify AWAY from the per-US sequential split
        # (which would iterate zero US and vacuously return 0) and TO the single
        # ALL verifier below, which performs a REAL verification of the whole PRD.
        # run_sequential_final_verify also self-guards an empty US_LIST defensively.
        if [[ "$signal_us_id" == "ALL" && "$VERIFY_MODE" == "per-us" && -n "$US_LIST" ]] && ! _should_use_consensus "$signal_us_id"; then
          log "  Final ALL verify: using sequential per-US strategy (timeout prevention)"
          local seq_rc=0
          run_sequential_final_verify "$ITERATION" || seq_rc=$?
          if (( seq_rc == 0 )); then
            write_complete_sentinel "Sequential final verify passed (all US verified individually)"
            update_status "complete" "pass"
            # codex P2 sweep F5: this COMPLETE exit skips the loop-top unlock
            # that would normally close out the last iteration's pending
            # lock — flush it now so the sample isn't silently dropped.
            # codex round 2 R2-3: `return 0` right below means there is no
            # "next iteration" for a failed campaign.jsonl flush to retry
            # into, so use the retry-once-then-log-loudly terminal helper
            # instead of a bare fire-and-forget write_campaign_jsonl call.
            _lifecycle_flush_pending_locks
            _write_campaign_jsonl_terminal "$ITERATION" "ALL" "pass"
            return 0
          else
            # Sequential verify failed — fall through to fix loop with failed US
            log "  Sequential final verify failed at ${FAILED_US:-unknown}. Entering fix loop."
            signal_us_id="${FAILED_US:-ALL}"
            # Synthesize a fail verdict for the fix loop. run_sequential_final_
            # verify's per-US calls lock VERDICT_FILE on each per-US pass; if a
            # LATER US then fails, the last-passing US's lock-mark could still
            # be pending here — codex round 3: no per-site clear needed,
            # atomic_write() drops it automatically.
            echo "{\"verdict\":\"fail\",\"summary\":\"Sequential final verify failed at ${FAILED_US:-unknown}\",\"issues\":[{\"severity\":\"critical\",\"criterion\":\"${FAILED_US:-ALL}\",\"description\":\"Failed during sequential final verification\"}]}" | atomic_write "$VERDICT_FILE"
          fi
        fi

        # --- Consensus scope check (US-005: _should_use_consensus handles CONSENSUS_MODE) ---
        local use_consensus=0
        _should_use_consensus "$signal_us_id" && use_consensus=1

        # --- Consensus vs single verification ---
        if (( use_consensus )); then
          # US-004: Run consensus verification (claude + codex sequentially)
          local consensus_rc=0
          run_consensus_verification "$ITERATION" "$signal_us_id" || consensus_rc=$?

          if (( consensus_rc == 2 )); then
            # Consensus disagreement — treat as fail, fix loop will handle
            log "  Consensus disagreement, treating as fail."
          elif (( consensus_rc != 0 )); then
            # Consensus verification failed entirely. When a verifier named its
            # own cause (e.g. provider quota exhausted), surface that instead of
            # the generic text — the operator needs to know whether to fix
            # something or simply wait for a reset.
            log_error "${VERIFIER_ABORT_REASON:-Consensus verification failed (verifier/infra error before verdict)}"
            write_blocked_sentinel "${VERIFIER_ABORT_REASON:-Consensus verification failed (verifier/infra error before verdict)}" "" "infra_failure"
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
            tmux send-keys -t "$VERIFIER_PANE" "clear" C-m 2>/dev/null
            sleep 0.3
          elif [[ "$verifier_cmd" == "node" || "$verifier_cmd" == "claude" || "$verifier_cmd" == "codex" ]]; then
            tmux send-keys -t "$VERIFIER_PANE" C-c 2>/dev/null
            sleep 0.5
            tmux send-keys -t "$VERIFIER_PANE" "/exit" C-m 2>/dev/null
            sleep 2
          fi
          wait_for_pane_ready "$VERIFIER_PANE" 10 2>/dev/null || true

          # D-1: a final/ALL verify reaching the single-engine path (batch mode, or
          # any ALL verify not handled by the per-us sequential path) uses the
          # stronger FINAL_VERIFIER_*; per-US verifies keep the lighter VERIFIER_*.
          # For signal_us_id != ALL, _v_* alias VERIFIER_* EXACTLY — no behavior
          # change on the per-US hot path.
          local _v_eng _v_model _v_cxm _v_cxr _v_eff _v_role
          if [[ "$signal_us_id" == "ALL" ]]; then
            _v_eng="$FINAL_VERIFIER_ENGINE"; _v_model="$FINAL_VERIFIER_MODEL"
            _v_cxm="$FINAL_VERIFIER_CODEX_MODEL"; _v_cxr="$FINAL_VERIFIER_CODEX_REASONING"; _v_eff="$FINAL_VERIFIER_EFFORT"
            # D-10 fix: an ALL verify here runs FINAL_VERIFIER_ENGINE, so the poll's
            # dead-pane check must derive FINAL_VERIFIER_ENGINE too — use the
            # "*inal*" role so poll_for_signal's engine derivation matches _v_eng
            # (else a codex final verifier's "bash" is misjudged with VERIFIER_ENGINE).
            _v_role="Verifier-final"
          else
            _v_eng="$VERIFIER_ENGINE"; _v_model="$VERIFIER_MODEL"
            _v_cxm="$VERIFIER_CODEX_MODEL"; _v_cxr="$VERIFIER_CODEX_REASONING"; _v_eff="$VERIFIER_EFFORT"
            _v_role="Verifier"
          fi

          local verifier_launch
          if [[ "$_v_eng" = "codex" ]]; then
            verifier_launch="${CODEX_BIN:-codex} -m $_v_cxm -c model_reasoning_effort=\"$_v_cxr\" -c mcp_servers='{}' --disable plugins --dangerously-bypass-approvals-and-sandbox"
          else
            verifier_launch="$(build_claude_cmd tui "$_v_model" "" "" "$_v_eff")"
          fi
          log_debug "[FLOW] iter=$ITERATION phase=verifier engine=$_v_eng model=$_v_model scope=${signal_us_id:-all} dispatched=true"

          # R3 (audit round 3): remove any stale verdict BEFORE launching, so the
          # poll below waits for THIS verifier's fresh verdict instead of accepting
          # a leftover one. run_single_verifier (consensus) and _final_verify_one_us
          # already rm here; this inline single-engine path relied solely on the
          # iteration-start cleanup — which is SKIPPED when SKIP_NEXT_WORKER=1
          # (operator-recovery / D-16 finalize). On such a skip iteration a stale
          # VERDICT_FILE from a prior iteration would still be on disk and valid
          # JSON, so poll_for_signal would return it IMMEDIATELY → a wrong pass/fail
          # read from the previous iteration's verdict. Clear it here unconditionally.
          # D-26: also clear legacy — the no-progress watcher migrates a stale
          # legacy verdict into canonical, re-opening the same hole otherwise.
          # codex round 1 P2-2 + codex P2 sweep F4: drop any pending
          # lock-start mark, ONLY after the rm actually succeeds — see the
          # identical note at run_single_verifier's clear site.
          rm -f "$VERDICT_FILE" "$LEGACY_VERDICT_FILE" 2>/dev/null \
            && _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"

          if [[ "$_v_eng" = "codex" ]]; then
            launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"
          else
            if ! launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"; then
              update_status "verifier" "start_failed"
              continue
            fi
          fi

          # Poll for verify-verdict.json — F-10: 3-strike replace+re-dispatch
          # parity with the Worker's MONITOR_FAILURE_COUNT breaker. "Bug Report #5"
          # hardened the Worker poll-fail path (retry-3-then-block) but left the
          # Verifier path as an immediate terminal BLOCK, so a single transient
          # verifier death (API blip / pane-spawn race, also F-11) ended a campaign
          # the Worker path would have survived. rc==2 keeps its original meaning
          # (already-handled → return). Only 3 consecutive failures BLOCK.
          log "  Polling for verify-verdict.json..."
          local _vpoll_strike=0 _vpoll_ok=0
          while (( _vpoll_strike < 3 )); do
            # Capture poll rc DIRECTLY — `$?` after `if cmd; then…fi` is the
            # if-statement's status (0), not cmd's rc (the original `if ! poll;
            # then local rc=$?` had this latent bug, so its `rc==2` branch was
            # dead and a hard-fail double-wrote a sentinel). rc: 0=verdict,
            # 1=timeout (retryable), 2=hard-failed + infra_failure already recorded.
            poll_for_signal "$VERDICT_FILE" "$VERIFIER_HEARTBEAT" "$VERIFIER_PANE" "$verifier_launch" "$_v_role"
            local verifier_poll_rc=$?
            if (( verifier_poll_rc == 0 )); then
              _vpoll_ok=1; break
            fi
            if (( verifier_poll_rc == 2 )); then
              return 1   # hard-failed; poll already recorded infra_failure — do not retry
            fi
            (( _vpoll_strike++ ))
            log "  WARNING: Verifier poll failed (strike $_vpoll_strike/3) — replacing pane and re-dispatching"
            log_debug "[GOV] iter=$ITERATION verifier_monitor_failure=$_vpoll_strike/3"
            update_status "verifier" "poll_failed"
            (( _vpoll_strike >= 3 )) && break
            replace_worker_pane "$VERIFIER_PANE" "verifier"
            VERIFIER_PANE=$(jq -r '.panes.verifier' "$SESSION_CONFIG")
            if [[ "$_v_eng" = "codex" ]]; then
              launch_verifier_codex "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch"
            else
              launch_verifier_claude "$VERIFIER_PANE" "$verifier_prompt" "$ITERATION" "$verifier_launch" || true
            fi
          done
          if (( ! _vpoll_ok )); then
            log_error "Verifier poll failed 3× (dead/stuck after retries)"
            write_blocked_sentinel "Verifier process dead/stuck after 3 retries. Pane preserved for inspection." "" "infra_failure"
            update_status "blocked" "verifier_dead"
            return 1
          fi
          # v0.15.4 full-wire: verdict_write_to_read_ms (leader poll-resolve vs
          # verifier FS write), mirrors campaign-main-loop.mjs:2110-2117.
          # codex P2 sweep F2 + round-2 R2-1: capture fork-free now, emit (fork-bearing) after the reap.
          _lifecycle_capture_write_to_read "$VERDICT_FILE"
          local _lc_wtr4="$_LC_CAPTURED_DELTA"
          # Bug #7 Fix-Q/R: reap verifier pane immediately so codex cannot
          # rewrite verify-verdict.json post-detect (mtime drift fix).
          # v0.15.4 full-wire: 3rd arg tags this reap as sentinel-triggered (pane_reap_latency_ms).
          _kill_pane_process "$VERIFIER_PANE" "verifier" "verify-verdict"
          _lifecycle_emit_write_to_read "verdict_write_to_read_ms" "$VERDICT_FILE" "$_lc_wtr4" "$ITERATION" "${signal_us_id:-${CURRENT_US:-ALL}}"
          # v0.15.4 full-wire: markLockStart BEFORE the chmod (H3 ordering contract).
          # codex P2 sweep F5: pass the CURRENT iter so the mark is attributed to it.
          _lifecycle_mark_lock_start "${VERDICT_FILE:t}" "$ITERATION"
          if ! _lock_sentinel "$VERDICT_FILE"; then
            # codex P2 sweep F3: same note as run_single_verifier above.
            _lifecycle_clear_lock_mark "${VERDICT_FILE:t}"
          fi
          # PR-0b-narrow: stamp leader handshake ack on the verdict (audit-only).
          _stamp_ack_field "$VERDICT_FILE"
        fi

        # AC1: capture verifier end timestamp
        ITER_VERIFIER_END=$(date +%s)

        # --- governance.md s7 step 7: Read verdict via jq ---
        local verdict
        verdict=$(jq -r '.verdict' "$VERDICT_FILE" 2>/dev/null)
        local recommended
        recommended=$(jq -r '.recommended_state_transition' "$VERDICT_FILE" 2>/dev/null)
        # F-23: normalize so a verifier's phrasing variant doesn't strand a
        # genuinely-complete campaign at MAX_ITER. "Complete"/"completed"/"done"
        # all mean complete; comparison below is lowercase-exact.
        recommended="${recommended:l}"
        local verdict_summary
        verdict_summary=$(jq -r '.summary // "no summary"' "$VERDICT_FILE" 2>/dev/null)

        log "  Verifier: verdict=$verdict recommended=$recommended"
        log "  Verifier summary: \"$verdict_summary\""
        local _issues_count=$(jq '.issues | length' "$VERDICT_FILE" 2>/dev/null || echo 0)
        log_debug "[GOV] iter=$ITERATION phase=verdict engine=$VERIFIER_ENGINE verdict=$verdict recommended=$recommended us_id=${signal_us_id:-all} issues=$_issues_count"

        case "$verdict" in
          pass)
            # D-3 fix: snapshot the CB BEFORE the pass-success reset so a wrong-US
            # "pass" (us_id mismatch, handled below) accumulates the CB across
            # iterations instead of restarting from 0 each time (the reset on the
            # next line would otherwise defeat the mismatch soft-fail's CB bound).
            local _cf_before_pass=$CONSECUTIVE_FAILURES
            CONSECUTIVE_FAILURES=0
            CONSENSUS_ROUND=0
            _SAME_US_FAIL_COUNT=0
            _LAST_FAILED_US=""
            # F-22b: a pass is real progress — reset the consecutive-BLOCKS state
            # too so the now-live block CB counts only blocks with NO intervening
            # success ("consecutive" in the true sense, not cumulative).
            CONSECUTIVE_BLOCKS=0
            LAST_BLOCK_REASON=""
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

            # --- Verified US tracking (both per-us and batch modes) ---
            if [[ -n "$signal_us_id" && "$signal_us_id" != "ALL" ]]; then
              # D-3: cross-check the verdict's OWN us_id against the US the leader
              # scoped this verify to. If the verifier graded a DIFFERENT US, do
              # NOT credit signal_us_id (it was not actually verified) — soft-fail
              # so the Worker re-runs the contracted US. Acts ONLY on a PRESENT
              # mismatch (absent verdict us_id = trust the scope), so a correctly-
              # scoped verifier is never affected.
              local _verdict_us_id
              _verdict_us_id=$(jq -r '.us_id // empty' "$VERDICT_FILE" 2>/dev/null)
              _verdict_us_id="${_verdict_us_id:u}"
              if [[ -n "$_verdict_us_id" && "$_verdict_us_id" != "$signal_us_id" ]]; then
                log_error "  Verdict us_id mismatch: verifier graded $_verdict_us_id but leader scoped $signal_us_id — NOT crediting (soft-fail)."
                log_debug "[GOV] iter=$ITERATION verdict_us_id_mismatch verdict_us=$_verdict_us_id signal_us=$signal_us_id"
                update_status "verifier" "us_id_mismatch"
                # D-3 fix: undo the pass-entry CB reset so consecutive mismatches
                # actually accumulate toward the breaker (else each restarts at 0).
                CONSECUTIVE_FAILURES=$_cf_before_pass
                if _bump_consecutive_failure; then
                  write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive verdict us_id mismatches" "" "repeat_axis"
                  update_status "blocked" "consecutive_failures"
                  return 1
                fi
              else
                # Add this US to verified list. D-12: dedup — a fresh-context Worker
                # can re-submit an already-verified US (memory drift); don't
                # double-credit it (mirrors the fail/partial-progress guard, and
                # keeps VERIFIED_US + the ledger + the coverage count honest).
                if echo ",$VERIFIED_US," | grep -q ",$signal_us_id,"; then
                  log "  US $signal_us_id already verified — not re-crediting (dedup)."
                  log_debug "[FLOW] iter=$ITERATION verified_us_dedup=$signal_us_id"
                else
                  if [[ -n "$VERIFIED_US" ]]; then
                    VERIFIED_US="${VERIFIED_US},${signal_us_id}"
                  else
                    VERIFIED_US="$signal_us_id"
                  fi
                  log "  US $signal_us_id verified. Verified so far: $VERIFIED_US"
                  log_debug "[FLOW] iter=$ITERATION verified_us_update=$signal_us_id verified_us_total=$VERIFIED_US"
                  # F-14: durable source-of-truth. On append failure the
                  # in-session credit stands but the durable record is gone —
                  # a later resume falls back to build mode (safe: re-verifies
                  # instead of confirming), so surface it loudly and continue.
                  _append_verified_ledger "$signal_us_id" \
                    || log_error "durable ledger append failed for $signal_us_id — a resume will re-verify (build mode) instead of confirming"
                fi
                update_status "verifier" "pass_us"
                # D-16: if this pass completed coverage (every US in US_LIST is now
                # verified), arm leader-driven finalize so the NEXT loop top runs the
                # sequential final verify DIRECTLY — instead of a worker round-trip
                # whose only job is to emit an ALL signal (a fragile extra LLM
                # iteration, observed hanging on an API rate-limit in SV CRITICAL).
                if [[ "$VERIFY_MODE" == "per-us" && -n "$US_LIST" ]] && _all_us_verified; then
                  _FINALIZE_PENDING=1
                  log "  Coverage complete ($VERIFIED_US) — arming leader finalize (D-16, no worker round-trip)."
                  log_debug "[FLOW] iter=$ITERATION d16_arm_finalize=true verified_us=$VERIFIED_US"
                else
                  : # more US remain → Worker will do next US on next iteration
                fi
              fi
            elif [[ "$recommended" == (complete|completed|done) || "$signal_us_id" == "ALL" ]]; then
              # Final full verify passed or complete recommended
              write_complete_sentinel "$verdict_summary"
              update_status "complete" "pass"
              # codex P2 sweep F5 + round-2 R2-3: same notes as the
              # sequential-final-verify COMPLETE exit above — flush before
              # the terminal write, use the retry-once-then-loud-log helper.
              _lifecycle_flush_pending_locks
              _write_campaign_jsonl_terminal "$ITERATION" "${signal_us_id:-ALL}" "pass"
              return 0
            else
              log "  Verifier passed but did not recommend complete. Continuing."
              update_status "verifier" "pass_continue"
            fi
            ;;
          fail)
            # --- governance.md s7½: Fix Loop (adapted for tmux lean mode) ---

            # Parse per_us_results from verdict to track partial progress (batch + per-us)
            local _prev_verified="$VERIFIED_US"
            if jq -e '.per_us_results' "$VERDICT_FILE" &>/dev/null; then
              local _newly_passed
              _newly_passed=$(jq -r '.per_us_results | to_entries[] | select(.value == "pass") | .key' "$VERDICT_FILE" 2>/dev/null)
              for _pus in $(echo "$_newly_passed"); do
                if ! echo ",$VERIFIED_US," | grep -q ",$_pus,"; then
                  if [[ -n "$VERIFIED_US" ]]; then
                    VERIFIED_US="${VERIFIED_US},${_pus}"
                  else
                    VERIFIED_US="$_pus"
                  fi
                  log "  Partial progress: $_pus passed (overall FAIL). Verified so far: $VERIFIED_US"
                  _append_verified_ledger "$_pus" \
                    || log_error "durable ledger append failed for $_pus — a resume will re-verify (build mode) instead of confirming"
                fi
              done
              log_debug "[FLOW] iter=$ITERATION partial_progress prev=$_prev_verified now=$VERIFIED_US"
            fi

            # Partial progress resets consecutive failures (progress was made)
            if [[ "$VERIFIED_US" != "$_prev_verified" ]]; then
              CONSECUTIVE_FAILURES=0
              # F-22b: partial progress also resets the consecutive-blocks state.
              CONSECUTIVE_BLOCKS=0
              LAST_BLOCK_REASON=""
              log "  Progress detected — consecutive_failures reset to 0"
              log_debug "[GOV] iter=$ITERATION consecutive_failures_reset=partial_progress"
            fi

            (( CONSECUTIVE_FAILURES++ ))
            record_us_failure "${signal_us_id:-unknown}"
            check_model_upgrade "${signal_us_id:-unknown}"

            # Mid-CB warning: alert at halfway point (governance §8 early warning)
            if (( CONSECUTIVE_FAILURES == EFFECTIVE_CB_THRESHOLD / 2 )); then
              log "  [WARN] Mid-CB: $CONSECUTIVE_FAILURES/${EFFECTIVE_CB_THRESHOLD} consecutive failures — consider reviewing AC quality"
              log_debug "[GOV] iter=$ITERATION mid_cb_warning=true consecutive_failures=$CONSECUTIVE_FAILURES threshold=$EFFECTIVE_CB_THRESHOLD"
            fi
            local verdict_summary_fail
            verdict_summary_fail=$(jq -r '.summary // "no summary"' "$VERDICT_FILE" 2>/dev/null)
            log "  Verifier FAILED (consecutive: $CONSECUTIVE_FAILURES). Building fix contract..."

            # Extract issues from verdict for next Worker's fix contract
            local fix_contract="$LOGS_DIR/iter-$(printf '%03d' $ITERATION).fix-contract.md"
            {
              echo "# Fix Contract (from Verifier iteration $ITERATION)"
              echo ""
              if [[ -n "$VERIFIED_US" ]]; then
                if [[ "${signal_us_id:-}" == "ALL" ]]; then
                  # v0.22.3 (final-review P1-1): an ALL/consensus failure may
                  # implicate exactly the already-verified stories — a blanket
                  # do-not-touch would forbid the entire repair scope and the
                  # fix loop could never converge. Scope Lock still applies:
                  # only changes tied to the verdict's issues are in scope.
                  echo "## Previously verified US (context)"
                  echo "$VERIFIED_US" | tr ',' '\n' | sed 's/^/- /'
                  echo ""
                  echo "**This failure is at the FINAL/ALL verification. You MAY modify previously verified stories, but ONLY where a change is tied to a listed issue below (Scope Lock). Do not rewrite passing work that no issue implicates.**"
                  echo ""
                else
                  echo "## Verified US (do NOT re-implement these)"
                  echo "$VERIFIED_US" | tr ',' '\n' | sed 's/^/- /'
                  echo ""
                  echo "**Focus ONLY on unverified user stories. The above are already verified.**"
                  echo ""
                fi
              fi
              echo "## Summary"
              echo "$verdict_summary_fail"
              echo ""
              echo "## Issues (from verify-verdict.json)"
              jq -r '.issues[]? | "- [\(.severity // "unknown")] \(.id // .criterion // .criterion_id // "?"): \(.description // .summary // "no description")\(if .fix_hint then " (hint: \(.fix_hint))" else "" end)"' "$VERDICT_FILE" 2>/dev/null || echo "- (no structured issues available)"
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
                write_blocked_sentinel "architecture escalation: Worker upgraded to ceiling model (${WORKER_MODEL}), ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures" "" "repeat_axis"
              else
                log_debug "[GOV] iter=$ITERATION circuit_breaker=consecutive_failures detail=\"${EFFECTIVE_CB_THRESHOLD} consecutive verification failures\""
                log_error "Circuit breaker: ${EFFECTIVE_CB_THRESHOLD} consecutive verification failures"
                write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive verification failures" "" "repeat_axis"
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
            # F-22: count request_info toward the CB so a verifier looping on
            # request_info trips the breaker instead of spinning to MAX_ITER.
            if _bump_consecutive_failure; then
              write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive non-advancing verdicts (request_info)" "" "repeat_axis"
              update_status "blocked" "consecutive_failures"
              return 1
            fi
            ;;
          blocked)
            local _verdict_cat
            _verdict_cat=$(_classify_cross_us_or_metric "$verdict_summary")
            # F-22: a transient/first "blocked" no longer kills the campaign —
            # absorb as a soft-fail with grace; terminate only on a genuine infra
            # block, the same reason repeated >= BLOCK_CB_THRESHOLD, or the CB.
            if _block_with_grace "Verifier verdict: blocked - $verdict_summary" "$_verdict_cat"; then
              write_blocked_sentinel "Verifier verdict: blocked - $verdict_summary" "" "$_verdict_cat"
              update_status "blocked" "verifier_blocked"
              return 1
            fi
            log "  Verifier verdict=blocked absorbed as soft-fail (consecutive_failures=$CONSECUTIVE_FAILURES; reason not yet repeated ${BLOCK_CB_THRESHOLD}×) — Worker will retry."
            update_status "verifier" "blocked_softfail"
            ;;
          *)
            log_error "Unknown verdict: $verdict"
            update_status "verifier" "unknown_verdict"
            # F-22: unknown verdict is a soft-fail that counts toward the CB
            # (was: silent continue to MAX_ITER with no diagnostic BLOCK).
            if _bump_consecutive_failure; then
              write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive unrecognized verifier verdicts" "" "repeat_axis"
              update_status "blocked" "consecutive_failures"
              return 1
            fi
            ;;
        esac
        ;;
      blocked)
        # --- governance.md s7 step 6: blocked -> write sentinel (with grace) ---
        local _signal_cat
        _signal_cat=$(_classify_cross_us_or_metric "$signal_summary")
        # F-22: a transient/first Worker-reported "blocked" no longer kills the
        # campaign — absorb as a soft-fail with grace (same gate as the verifier
        # blocked path); terminate only on infra, repeated reason, or the CB.
        if _block_with_grace "Worker reported blocked: $signal_summary" "$_signal_cat"; then
          write_blocked_sentinel "Worker reported blocked: $signal_summary" "" "$_signal_cat"
          update_status "blocked" "worker_blocked"
          return 1
        fi
        log "  Worker status=blocked absorbed as soft-fail (consecutive_failures=$CONSECUTIVE_FAILURES) — re-dispatching Worker."
        update_status "worker" "blocked_softfail"
        ;;
      *)
        log_error "Unknown signal status: $signal_status"
        update_status "worker" "unknown_status"
        # F-22: unknown signal status is a soft-fail that counts toward the CB
        # (was: silent continue to MAX_ITER).
        if _bump_consecutive_failure; then
          write_blocked_sentinel "${EFFECTIVE_CB_THRESHOLD} consecutive unrecognized worker signals" "" "repeat_axis"
          update_status "blocked" "consecutive_failures"
          return 1
        fi
        ;;
    esac

    # --- step 7d: Archive iteration artifacts before cleanup ---
    archive_iter_artifacts "$ITERATION"

    # --- AC5: Write per-iteration cost estimate ---
    write_cost_log "$ITERATION"
    # codex round 2 R2-3: check the return code — write_campaign_jsonl
    # already log_errors internally on failure and retains LIFECYCLE_RECORDS
    # for the NEXT iteration's flush to retry (F6 + the guarded loop-top
    # reset above); this caller-side log_error adds iteration-specific
    # visibility rather than silently ignoring the failure.
    if ! write_campaign_jsonl "$ITERATION" "${signal_us_id:-unknown}" "${signal_status:-unknown}"; then
      log_error "campaign.jsonl row for iter=$ITERATION was not written — lifecycle metrics retained, will retry on the next flush"
    fi

    # --- governance.md s7 step 8: Write result log ---
    write_result_log "$ITERATION" "$signal_status"

    # --- governance.md s7 step 8: Circuit breaker - stale context check ---
    if ! check_stale_context; then
      log_debug "[GOV] iter=$ITERATION circuit_breaker=stale_context detail=\"context unchanged for 3 consecutive iterations\""
      write_blocked_sentinel "Context unchanged for 3 consecutive iterations (stale)" "" "context_limit"
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
      elif [[ "$_cli_rest" == *" "* ]]; then
        WORKER_EFFORT="${_cli_rest##* }"
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
      elif [[ "$_cli_rest" == *" "* ]]; then
        VERIFIER_EFFORT="${_cli_rest##* }"
      fi
      ;;
    --lock-worker-model)
      LOCK_WORKER_MODEL=1
      ;;
    --autonomous)
      AUTONOMOUS_MODE=1
      ;;
    --lane-strict)
      # P1-E opt-in: lane mtime audit escalates to BLOCKED instead of WARN.
      # See governance §7¾.
      LANE_MODE="strict"
      ;;
    --test-density-strict)
      # US-018 R6 P1-F opt-in: AC with < 3 tests fails init (exit 1) instead of WARN.
      # See governance §7f.
      TEST_DENSITY_MODE="strict"
      ;;
    --final-verifier-model)
      (( _cli_i++ ))
      _cli_parsed=$(parse_model_flag "${@[$_cli_i]:-}" "final-verifier") || exit 1
      FINAL_VERIFIER_ENGINE="${_cli_parsed%% *}"
      _cli_rest="${_cli_parsed#* }"
      FINAL_VERIFIER_MODEL="${_cli_rest%% *}"
      if [[ "$FINAL_VERIFIER_ENGINE" = "codex" ]]; then
        FINAL_VERIFIER_CODEX_MODEL="$FINAL_VERIFIER_MODEL"
        FINAL_VERIFIER_CODEX_REASONING="${_cli_rest##* }"
      elif [[ "$_cli_rest" == *" "* ]]; then
        FINAL_VERIFIER_EFFORT="${_cli_rest##* }"
      fi
      ;;
    --consensus)
      (( _cli_i++ ))
      CONSENSUS_MODE="${@[$_cli_i]:-off}"
      ;;
    --consensus-model)
      (( _cli_i++ ))
      CONSENSUS_MODEL="${@[$_cli_i]:-gpt-5.6-terra:medium}"
      ;;
    --final-consensus-model)
      (( _cli_i++ ))
      FINAL_CONSENSUS_MODEL="${@[$_cli_i]:-gpt-5.6-sol:high}"
      ;;
    --final-consensus)
      # Legacy: map to new --consensus final-only
      CONSENSUS_MODE="final-only"
      ;;
    --verify-consensus)
      # Legacy: map to new --consensus all
      CONSENSUS_MODE="all"
      ;;
  esac
  (( _cli_i++ ))
done
unset _cli_i _cli_parsed _cli_rest

# Effective CB threshold: doubled when consensus mode is active. Computed
# here (after CLI parsing, not at module top) so CLI-driven consensus
# (--consensus, --final-consensus, --verify-consensus) gets the doubling too,
# not just the legacy-flag/env-var CONSENSUS_MODE activation resolved above.
if [[ "$CONSENSUS_MODE" != "off" ]]; then
  EFFECTIVE_CB_THRESHOLD=$(( CB_THRESHOLD * 2 ))
else
  EFFECTIVE_CB_THRESHOLD=$CB_THRESHOLD
fi

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
_main_rc=$?
# request-b incidental #2: make the terminal exit code authoritative on the
# sentinel state so EVERY blocked termination exits NON-ZERO and COMPLETE exits
# 0 — independent of which internal return path fired (a late background-watchdog
# BLOCKED could otherwise race a return 0, and some historical block paths
# mislabeled). The EXIT trap (_emit_final_cost_log; cleanup) still runs; zsh
# preserves the code across it, so this only pins what main hands back.
if [[ -f "$COMPLETE_SENTINEL" ]]; then
  exit 0
elif [[ -f "$BLOCKED_SENTINEL" ]]; then
  (( _main_rc != 0 )) && exit "$_main_rc"
  exit 1
fi
exit "$_main_rc"
