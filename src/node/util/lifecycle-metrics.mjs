// v0.15.4 PR-B4 — Lifecycle observability helper.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §3 Table 2.
//
// Five metrics tracked, ON BY DEFAULT since the v0.15.5 full-wire (opt out
// with RLP_LIFECYCLE_METRICS=0):
//   - iter_signal_write_to_read_ms     leader-poll-resolves vs worker-FS-write
//   - verdict_write_to_read_ms          leader-poll-resolves vs verifier-FS-write
//   - pane_eof_to_cleanup_ms            pane process exit vs killPaneProcess return
//   - pane_reap_latency_ms              sentinel (iter-signal/verify-verdict) observed vs C-c×2 + waitForExit
//   - sentinel_lock_to_unlock_ms        per type, _lock vs _unlock (object)
//
// Emission discipline:
//   - debug.log: tagged [LIFECYCLE] per record (when enabled)
//   - campaign.jsonl: ONE batched lifecycle_metrics object per iteration
//                     (the collector accumulates, the iter-end flush emits)
// When explicitly disabled (RLP_LIFECYCLE_METRICS=0):
//   - record() is a no-op (early return) — zero overhead beyond a Map check
//   - flush() returns null so analytics writer can branch on the field

const ENV_FLAG_NAME = 'RLP_LIFECYCLE_METRICS';

// Default ON: any value other than the literal string '0' enables telemetry,
// including unset. '0' is the sole explicit opt-out.
export function lifecycleMetricsEnabled(env = process.env) {
  return env[ENV_FLAG_NAME] !== '0';
}

export class LifecycleMetricsCollector {
  constructor({ env = process.env, debugLog = null } = {}) {
    this._enabled = lifecycleMetricsEnabled(env);
    this._debugLog = debugLog;
    this._records = [];
    this._sentinelLockTimes = new Map();
  }

  get enabled() {
    return this._enabled;
  }

  // Record a single timing metric. value is in milliseconds. ctx is a flat
  // object of audit fields (iter, us_id, pane_id, sentinel_type, etc).
  record(name, valueMs, ctx = {}) {
    if (!this._enabled) return;
    const entry = {
      metric: name,
      value_ms: Math.max(0, Math.round(valueMs)),
      ts: new Date().toISOString(),
      ...ctx,
    };
    this._records.push(entry);
    if (this._debugLog) {
      // Best-effort fire-and-forget. The debug-log helper is itself best-
      // effort (appendFile error swallowed), so we don't await it.
      this._debugLog('LIFECYCLE', { metric: name, value_ms: entry.value_ms, ...ctx });
    }
  }

  // Convenience: pair-bookkeeping for sentinel_lock_to_unlock_ms (object-
  // valued metric keyed by sentinel type). Call markLockStart at chmod 0o444
  // time, markUnlock at chmod 0o644 time (or end-of-iter for never-unlocked).
  //
  // v0.15.4 audit H2: done-claim is intentionally NOT instrumented with this
  // pair. In production happy path done-claim is locked-but-never-unlocked
  // (campaign-main-loop unlocks only signalFile + verdictFile at iter start);
  // markUnlock for done-claim never fires, so the metric would silently never
  // emit. Future work: emit at lib_ralph_desk.zsh:602 archival site if needed.
  //
  // v0.15.4 audit H3: callers must invoke markLockStart BEFORE the chmod
  // operation, not after, so the metric covers full lock duration including
  // chmod execution time. Sub-ms skew, but semantically correct.
  markLockStart(sentinelType, t = Date.now()) {
    if (!this._enabled) return;
    this._sentinelLockTimes.set(sentinelType, t);
  }

  markUnlock(sentinelType, ctx = {}, t = Date.now()) {
    if (!this._enabled) return;
    const start = this._sentinelLockTimes.get(sentinelType);
    if (start === undefined) return;
    this.record('sentinel_lock_to_unlock_ms', t - start, {
      ...ctx,
      sentinel_type: sentinelType,
    });
    this._sentinelLockTimes.delete(sentinelType);
  }

  // Snapshot + reset for end-of-iteration flush. Returns null when disabled
  // so the analytics writer can omit the field cleanly.
  flush() {
    if (!this._enabled) return null;
    const records = this._records;
    this._records = [];
    // Group by metric name for compact campaign.jsonl shape:
    //   { iter_signal_write_to_read_ms: [{value_ms,ts,...}, ...], ... }
    const grouped = {};
    for (const r of records) {
      const { metric, ...rest } = r;
      if (!grouped[metric]) grouped[metric] = [];
      grouped[metric].push(rest);
    }
    return grouped;
  }
}
