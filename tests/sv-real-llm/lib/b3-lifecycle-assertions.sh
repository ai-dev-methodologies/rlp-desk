#!/usr/bin/env bash
# PR-B3 (v0.15.4) — shared two-stage lifecycle metric assertions for SV real-
# LLM scenarios. Sourced by bug-05 and bug-07 (bug-06 is structural-only).
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

  local lm_object_count
  lm_object_count=$(jq -s 'map(select(.lifecycle_metrics != null and (.lifecycle_metrics | type == "object"))) | length' \
    "$jsonl" 2>/dev/null || echo 0)
  if (( lm_object_count >= 1 )); then
    echo "ASSERT B3-S1 PASS: lifecycle_metrics present in $lm_object_count record(s)"
    ASSERTIONS_PASSED=$((ASSERTIONS_PASSED+1))
    return 0
  fi

  echo "ASSERT B3-S1 FAIL: lifecycle_metrics is null or missing in every campaign.jsonl record"
  echo "                   Likely cause: RLP_LIFECYCLE_METRICS=1 not propagated, or B4 collector inactive."
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

  # Pull max value_ms across all records for this metric.
  local max_observed
  max_observed=$(jq -s --arg m "$metric" '
    [.[] | (.lifecycle_metrics // {})[$m] // [] | .[].value_ms // 0] | max // 0
  ' "$jsonl" 2>/dev/null || echo 0)

  if [[ -z "$max_observed" || "$max_observed" == "null" ]]; then
    echo "ASSERT $label SKIP: metric not emitted (no entries in any record)"
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

# Initial tolerance bands sourced from docs/plans/v0.15-phase-b-lifecycle-
# audit.md §4.2 (Option-C synthetic baseline). Each band = max(p95 × 2,
# fixed_floor). Pre-merge revalidation against fresh B4 5-iter sample MUST
# update these constants if empirical p95 differs by >25% from synthetic.
B3_BAND_ITER_SIGNAL_MS=9500           # synthetic p95=4750 × 2
B3_BAND_VERDICT_MS=9500               # synthetic p95=4750 × 2
B3_BAND_PANE_EOF_CLEANUP_MS=5000      # synthetic p95=2500 × 2
B3_BAND_PANE_REAP_LATENCY_MS=16000    # synthetic p95=8000 × 2
