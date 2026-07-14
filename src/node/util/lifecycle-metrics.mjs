// v0.15.4 PR-B4 — Lifecycle observability helper.
//
// Plan: docs/plans/v0.15-phase-b-plan-v3.md §B4.
// Audit: docs/plans/v0.15-phase-b-lifecycle-audit.md §3 Table 2.
//
// Five metrics tracked, ALWAYS ON (v0.22.4 removed the opt-out flag after
// two default-ON dogfood release cycles with no opt-out use):
//   - iter_signal_write_to_read_ms     leader-poll-resolves vs worker-FS-write
//   - verdict_write_to_read_ms          leader-poll-resolves vs verifier-FS-write
//   - pane_eof_to_cleanup_ms            kill-start -> process-exit-confirmed (killPaneProcess +
//                                       waitForProcessExit settle)
//   - pane_reap_latency_ms              SAME window as pane_eof_to_cleanup_ms — recorded in
//                                       addition to it only when the reap followed a sentinel
//                                       observation (iter-signal/verify-verdict), tagged with
//                                       sentinel_type. NOT a distinct "sentinel-observed to
//                                       shell-idle" window — reapProducer (below) computes one
//                                       reapMs and records() it under both names. (v0.15.4 P2
//                                       sweep F1: corrected from an earlier, inaccurate doc
//                                       description; round-2 R2-4: this header's own
//                                       pane_eof_to_cleanup_ms line still undersold the window as
//                                       ending at killPaneProcess return, when reapProducer's
//                                       reapMs actually ends after waitForProcessExit settles —
//                                       both lines now describe the identical window in identical
//                                       terms. The zsh leader mirrors this exact same-window,
//                                       same-endpoint behavior in _kill_pane_process.)
//   - sentinel_lock_to_unlock_ms        per type, _lock vs _unlock (object)
//
// Emission discipline:
//   - debug.log: tagged [LIFECYCLE] per record (when enabled)
//   - campaign.jsonl: ONE batched lifecycle_metrics object per iteration
//                     (the collector accumulates, the iter-end flush emits)

export class LifecycleMetricsCollector {
  // env is accepted (and ignored) so legacy callers passing the removed
  // opt-out env keep constructing without error.
  constructor({ env = process.env, debugLog = null } = {}) {
    void env;
    this._debugLog = debugLog;
    this._records = [];
    this._sentinelLockTimes = new Map();
  }

  // Record a single timing metric. value is in milliseconds. ctx is a flat
  // object of audit fields (iter, us_id, pane_id, sentinel_type, etc).
  record(name, valueMs, ctx = {}) {
    // codex-r0 preempt (F7 parity, closure item on the P2 sweep): a negative
    // or non-finite value_ms (clock skew, NaN) is DROPPED entirely instead
    // of clamped to 0. A clamp-and-keep let a corrupted measurement silently
    // satisfy a "<= band" regression check (B3/B4) as a false PASS. Mirrors
    // the zsh leader's log_lifecycle_metric fix (P2 sweep F7) — this was
    // originally landed as a deliberate zsh-only divergence from Node's
    // clamp behavior, but Node's clamp has the exact same defect, so there
    // is no reason to keep it. A genuine 0 (real sub-ms measurement) is
    // still kept.
    if (!Number.isFinite(valueMs) || valueMs < 0) {
      if (this._debugLog) {
        this._debugLog('LIFECYCLE', { metric: name, dropped: true, raw_value_ms: valueMs, ...ctx });
      }
      return;
    }
    const entry = {
      metric: name,
      value_ms: Math.round(valueMs),
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
    this._sentinelLockTimes.set(sentinelType, t);
  }

  markUnlock(sentinelType, ctx = {}, t = Date.now()) {
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
