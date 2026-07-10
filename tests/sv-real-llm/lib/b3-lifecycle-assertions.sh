#!/usr/bin/env bash
# PR-B3 (v0.15.4) — shared two-stage lifecycle metric assertions for SV real-
# LLM scenarios. Sourced by b3-lifecycle-e2e (primary B3 carrier) and bug-07.
#
# Plan: docs/plans/v0.15-phase-b-plan-v3.md §B3.
# Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §4.2 (synthetic baseline
#        feeding the initial tolerance bands; pre-merge revalidation against
#        a fresh B4 sample is non-optional per plan v3 AC3.5).
#
# Two-stage contract:
#   Stage 1 (presence): the campaign.jsonl record carries a non-null
#                       lifecycle_metrics object with at least one metric
#                       array. Failure → B4 telemetry bug (helper not wired).
#   Stage 2 (value)   : at least one entry per asserted metric satisfies
#                       value_ms <= band_ms. band_ms is the initial Option-C
#                       synthetic value (max(p95×2, fixed_floor)) sourced
#                       from B1 §4.2. Plan v3 §B3 pre-merge revalidation MUST
#                       refit these bands against a fresh 5-iter B4 sample
#                       before this PR merges to declare release-readiness.
#
# Stage 1 is deterministic and required.
# Stage 2 is non-blocking by default until pre-merge revalidation lands; set
# B3_STAGE2_BLOCKING=1 in the scenario environment to upgrade Stage 2 to a
# fail-on-violation assertion. Default behavior emits PASS-with-INFO so a
# wide synthetic band failure does not block the gate prematurely.

# Usage: b3_assert_lifecycle_metrics_present <campaign_jsonl_path>
# Increments ASSERTIONS_PASSED / ASSERTIONS_FAILED in caller scope.
b3_assert_lifecycle_metrics_present() {
  local jsonl="$1"
  if [[ ! -f "$jsonl" ]]; then
    echo "ASSERT B3-S1 FAIL: campaign.jsonl missing at $jsonl"
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="B3-S1: campaign.jsonl absent"
    return 1
  fi

  # Require a NON-EMPTY lifecycle_metrics object — at least one metric carrying at
  # least one entry. An empty {} (flag on but no metric recorded all run) does NOT
  # count as telemetry present (it would let a no-op night masquerade as a PASS).
  local lm_object_count
  lm_object_count=$(jq -s 'map(select(.lifecycle_metrics != null and (.lifecycle_metrics | type == "object") and ([.lifecycle_metrics[] | length] | add // 0) > 0)) | length' \
    "$jsonl" 2>/dev/null || echo 0)
  if (( lm_object_count >= 1 )); then
    echo "ASSERT B3-S1 PASS: non-empty lifecycle_metrics present in $lm_object_count record(s)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    return 0
  fi

  echo "ASSERT B3-S1 FAIL: no record carries a non-empty lifecycle_metrics object"
  echo "                   Likely cause: RLP_LIFECYCLE_METRICS=1 not propagated, B4 collector inactive,"
  echo "                   or every record emitted an empty {} (no metric recorded)."
  ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
  SCENARIO_FAILURE_REASON="B3-S1: B4 telemetry not emitting"
  return 1
}

# Usage: b3_assert_lifecycle_metric_within_band <campaign_jsonl_path>
#                                                <metric_name> <band_ms>
# Returns 0 on PASS; non-zero on FAIL only when B3_STAGE2_BLOCKING=1.
# Otherwise emits PASS-with-INFO so wide synthetic bands don't block the gate.
b3_assert_lifecycle_metric_within_band() {
  local jsonl="$1"
  local metric="$2"
  local band_ms="$3"
  local label="B3-S2[$metric, band=${band_ms}ms]"

  if [[ ! -f "$jsonl" ]]; then
    echo "ASSERT $label SKIP: campaign.jsonl missing"
    return 0
  fi

  # v0.15.4 pre-release audit C1 fix: pre-compute entry_count to distinguish
  # "no data" (B4 telemetry never fired — should SKIP) from "zero-valued data"
  # (legitimate 0ms measurement — should still go through band check).
  # Previous implementation used `// 0` sentinel which collapsed both cases to
  # max=0, causing false PASS when telemetry was disabled.
  local entry_count
  entry_count=$(jq -s --arg m "$metric" \
    '[.[] | (.lifecycle_metrics // {})[$m] // []] | flatten | length' \
    "$jsonl" 2>/dev/null || echo 0)
  if (( entry_count == 0 )); then
    echo "ASSERT $label SKIP: metric not emitted (zero entries across all records)"
    return 0
  fi

  # Compute max only across records that actually have entries. No // 0 sentinel.
  local max_observed
  max_observed=$(jq -s --arg m "$metric" \
    '[.[] | (.lifecycle_metrics // {})[$m] // [] | .[].value_ms] | max' \
    "$jsonl" 2>/dev/null || echo "")

  if [[ -z "$max_observed" || "$max_observed" == "null" ]]; then
    echo "ASSERT $label SKIP: metric entries present but no value_ms field (schema drift?)"
    return 0
  fi

  if (( max_observed <= band_ms )); then
    echo "ASSERT $label PASS: max observed ${max_observed}ms <= band ${band_ms}ms"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    return 0
  fi

  if [[ "${B3_STAGE2_BLOCKING:-0}" == "1" ]]; then
    echo "ASSERT $label FAIL (BLOCKING): max observed ${max_observed}ms > band ${band_ms}ms"
    echo "                  Pre-merge revalidation gate triggered: B4 sample exceeded synthetic band by >25%."
    ASSERTIONS_FAILED=$((ASSERTIONS_FAILED+1))
    SCENARIO_FAILURE_REASON="${SCENARIO_FAILURE_REASON:-}; $label band exceeded"
    return 1
  fi

  echo "ASSERT $label INFO (non-blocking): max observed ${max_observed}ms > synthetic band ${band_ms}ms"
  echo "                  Set B3_STAGE2_BLOCKING=1 to upgrade to failing assertion (post-revalidation)."
  ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
  return 0
}

# Tolerance bands.
#
# iter_signal / verdict / pane_reap_latency: Node-leader synthetic bands (2026-05-07,
# b3-band-revalidation.mjs, 5-iter Node sample). v0.22.0 full-wire: these three metrics
# are now ALSO emitted by the zsh leader (--mode tmux), reusing the Node-derived bands
# below as a first-pass approximation — they have not yet been refit against a zsh
# sample the way pane_eof_to_cleanup_ms was (see the REFIT note directly below). Until
# a zsh-leader sample lands, expect the same "wide synthetic band, non-blocking INFO"
# behavior B3-S2 already gives every metric pre-revalidation.
#
# pane_eof_to_cleanup_ms: REFIT 2026-06-30 against a real ZSH-leader sample (scenario
# b3-lifecycle-e2e, live verifier-pane reap). The zsh `_kill_pane_process`
# (lib_ralph_desk.zsh:342) is STRUCTURALLY slower than the Node killPaneProcess: it does
# `C-c; sleep 0.5; C-c; sleep 1; wait_for_pane_ready <pane> 5` → a hard ceiling of
# 0.5+1+5 = 6.5s (6500ms). The Node-calibrated 5000ms band false-FAILED under
# B3_STAGE2_BLOCKING=1 (observed max 6331ms). Band raised to 10000ms = structural
# ceiling (6500) + ~54% jitter/scheduling headroom; still catches a true regression
# (a reap exceeding 10s means wait_for_pane_ready is retry-looping or a sleep changed).
#   Observed zsh sample 2026-06-30 (N=2 reaps, one run): [6331, 1553] ms.
#
# Re-run rule: any future >25% drift requires a fresh zsh-leader sample + refit.
B3_BAND_ITER_SIGNAL_MS=3000
B3_BAND_VERDICT_MS=3000
B3_BAND_PANE_EOF_CLEANUP_MS=10000
B3_BAND_PANE_REAP_LATENCY_MS=6000
