# rlp-desk Failure Modes Atlas

> Origin: 2026-05-08 (audit B-NEW-1, derived from omc-team's "Gotchas" pattern). Single canonical reference for known failure modes across the rlp-desk substrate. Each entry is FMEA-style: cause → symptom → detection → recovery.

This atlas consolidates Bug #5/6/7/8/10 + lifecycle race + sentinel contention failure patterns. New failure modes are added here once verified, with a back-link to the originating bug report or audit doc.

---

## §1 — Subprocess lifecycle (tmux + Worker/Verifier panes)

### F1.1 — Worker pane idle false-positive (Bug #6)
| Field | Value |
|---|---|
| Symptom | Leader marks worker as "no progress" while iter-signal.json was already written |
| Root cause | Worker TUI returns to idle prompt after writing sentinel; capture-pane shows stasis byte-equality without observing the FS write |
| Detection | `tests/test-bug6-worker-idle-false-positive.sh`; `_worker_pane_has_signal` short-circuit in `check_no_progress` |
| Recovery | Existing fix-M short-circuits BLOCKED escalation when iter-signal.json is present. No operator action required |
| Reference | `src/scripts/run_ralph_desk.zsh` `_worker_pane_has_signal` helper |

### F1.2 — Post-sentinel pane race (Bug #7)
| Field | Value |
|---|---|
| Symptom | Verify-verdict.json mtime drifts 30-120s after leader observes it; iter-N+1 worker dispatched while iter-N verifier's pane is still alive |
| Root cause | Without explicit teardown, claude/codex TUI continues self-reviewing after sentinel write |
| Detection | `tests/sv-real-llm/scenarios/bug-07-post-sentinel-race.test.sh` (real-LLM), `tests/node/test-sentinel-reaper-invariant.test.mjs` (unit) |
| Recovery | `_kill_pane_process` (Bug #7 Fix-Q) at zsh `lib_ralph_desk.zsh:257-272` and Node `pane-manager.mjs:91-116`. `_lock_sentinel` (Fix-R) freezes the file mtime |
| Reference | Bug #7 PR-A; v0.15.4 PR-B2-FIX extends to done-claim sentinel |

### F1.3 — done-claim race (v0.15.4 PR-B2-FIX target)
| Field | Value |
|---|---|
| Symptom | Worker writes done-claim.json then idles 30-120s before iter-signal.json. Worker may revise done-claim mid-flight; A4 fallback synthesizes signal from a stale done-claim |
| Root cause | Original Bug #7 Fix-Q only reaped at iter-signal observation. Done-claim was unguarded |
| Detection | `tests/node/test-sentinel-reaper-invariant.test.mjs` case 5 (done-claim ALIVE pane → kill) |
| Recovery | `_kill_pane_process` + `_lock_sentinel "$DONE_CLAIM_FILE"` at 4 substrate sites (3 zsh + 1 Node). See `docs/plans/v0.15-phase-b-plan-v3.md` §B2-FIX |
| Reference | v0.15.4 commit `2b5af6c`; audit `docs/plans/v0.15.4-pre-release-audit.md` §1 C2 |

### F1.4 — Worker dead on reuse (Bug #5)
| Field | Value |
|---|---|
| Symptom | At iter-N+1 entry, leader dispatches into a previously-killed worker pane; tmux returns "can't find pane" |
| Root cause | `_r12_check_lifecycle` not enforced strictly enough between iters |
| Detection | `tests/sv-real-llm/scenarios/bug-05-worker-dead-on-reuse.test.sh`; `[r12]` log markers |
| Recovery | R12 lifecycle monitor at iter-entry: detect dead pane within 5s budget → either replace pane OR write BLOCKED with infra_failure (no silent advance) |
| Reference | Bug #5 BOS 2026-05-05 |

### F1.5 — Worker incomplete with leader fallback (Bug #8)
| Field | Value |
|---|---|
| Symptom | Codex worker exits without writing iter-signal.json; leader synthesizes one from done-claim, but tree may be dirty |
| Root cause | Pre-Bug-#8: leader synthesized verify signal whenever done-claim existed, regardless of git state. Caused false PASSes when worker bailed mid-write |
| Detection | `_bug8_check_synth_allowed` 3-gate (done-claim present + git OK + tree clean); 4 BLOCK_TAGS variants |
| Recovery | Refuse synthesis on Gate 1/2/3 fail; write BLOCKED sentinel with appropriate failure_category (infra_failure / metric_failure) |
| Reference | Bug #8 PR-B; src/scripts/run_ralph_desk.zsh L644-695 |

### F1.6 — Operator-recovery artifact mismatch (Bug #10)
| Field | Value |
|---|---|
| Symptom | Operator manually clears BLOCKED sentinel + writes iter-signal/done-claim, but artifacts mismatch status.json or have stale mtime |
| Root cause | No validation pass when leader resumes from operator-cleared BLOCKED state |
| Detection | `_validate_operator_recovery_artifacts` 5-gate (file exists, parses, us_id matches, iteration matches, mtime > prompt mtime); `tests/node/test-blocked-recovery-hygiene.test.mjs` |
| Recovery | Pre-resume validator returns 0 only when all 5 gates pass; sets `RECOVERY_FAIL_REASON` for caller logging on failure |
| Reference | PR-A Bug #10; lib_ralph_desk.zsh L298-380 |

---

## §2 — Sentinel file contention

### F2.1 — Concurrent write-during-read window
| Field | Value |
|---|---|
| Symptom | Leader's `jq` parse on iter-signal.json fails with "unexpected EOF" when polled mid-write |
| Root cause | Worker writes sentinel non-atomically; leader's poll catches a partial state |
| Detection | "JSON not yet valid — continue polling" log entry; `tests/node/test-sentinel-exclusive.mjs` |
| Recovery | `writeSentinelExclusive` uses O_EXCL; `_lock_sentinel` chmod 0o444 prevents post-observe rewrite; jq -e parse retried on next poll tick |
| Reference | v5.7 §4.24 file-guarantee contract; sv-gate-fast §4.24 checks |

### F2.2 — Locked sentinel blocks next iter's writer
| Field | Value |
|---|---|
| Symptom | Iter-N+1 worker EACCES on iter-signal.json write because iter-N lock (chmod 0o444) was never released |
| Root cause | `_unlock_sentinel` not invoked at iter-start |
| Detection | "Permission denied" in worker stderr; `lib_ralph_desk.zsh` lifecycle test |
| Recovery | `unlockSentinelFile(paths.signalFile)` + `unlockSentinelFile(paths.verdictFile)` called defensively at every iter start (campaign-main-loop.mjs L1552-1555) |
| Reference | v5.7 §4.25; campaign-main-loop.mjs unlockSentinelFile call sites |

### F2.3 — Locked file orphans across upgrades
| Field | Value |
|---|---|
| Symptom | npm install of new rlp-desk version EACCES on previously-locked installed files |
| Root cause | Installed files chmod 0o444 from prior version; postinstall.js attempts straight overwrite |
| Detection | "EACCES: permission denied" during `npm install` |
| Recovery | `scripts/postinstall.js:163-167` walks installed dir, chmod 0o644 BEFORE copy; user-facing fallback documented in S1 runbook (`npm uninstall -g` first) |
| Reference | scripts/postinstall.js unlock-walk; v0.15.4 S1 rollback runbook |

---

## §3 — Telemetry & observability (v0.15.4+)

### F3.1 — lifecycle_metrics field absent (B4 telemetry regression)
| Field | Value |
|---|---|
| Symptom | `campaign.jsonl.lifecycle_metrics` is null even when `RLP_LIFECYCLE_METRICS=1` |
| Root cause | `LifecycleMetricsCollector` instantiated with wrong env (e.g. options.env shadows process.env) |
| Detection | `tests/node/test-campaign-jsonl-shape.test.mjs` AC4.3 (flag-set populated case); B3 Stage 1 presence assertion |
| Recovery | Inject explicit collector via `options.lifecycleMetrics`, OR set `env: { RLP_LIFECYCLE_METRICS: '1' }` in run() options |
| Reference | v0.15.4 PR-B4 + audit fix C2 |

### F3.2 — Stage 2 false-PASS on absent metric
| Field | Value |
|---|---|
| Symptom | B3 Stage 2 assertion PASSes on band check even when telemetry never emitted |
| Root cause | jq query collapsed `null|empty` to `max=0`; band check `0 ≤ band` always true |
| Detection | `tests/node/test-b3-band-revalidation.test.mjs` percentile + bucket cases |
| Recovery | Pre-compute `entry_count` via flatten\|length; SKIP when 0; only run band check on non-empty data |
| Reference | v0.15.4 audit C1 fix; commit `21e12ed` |

### F3.3 — sentinel_lock_to_unlock_ms unmeasurable for done-claim
| Field | Value |
|---|---|
| Symptom | Metric never emits for done-claim sentinel even though lock IS applied |
| Root cause | Production happy-path never calls `unlockSentinelFile(doneClaimFile)`; only signalFile + verdictFile are unlocked at iter start |
| Detection | Inspection: `lifecycle_metrics.sentinel_lock_to_unlock_ms` array contains iter-signal.json + verify-verdict.json entries but never done-claim.json |
| Recovery | Documented in `lifecycle-metrics.mjs` markLockStart() — done-claim intentionally excluded from this metric. Future: emit at lib_ralph_desk.zsh:602 archival site if needed |
| Reference | v0.15.4 audit H2; commit `feb1701` |

### F3.4 — Synthetic baseline drift from production
| Field | Value |
|---|---|
| Symptom | B1 §4.2 synthetic numbers differ from B3 empirical p95 by >25% |
| Root cause | Synthetic anchored to zsh leader's POLL_INTERVAL=5s; production scenarios run via Node leader (100ms poll). Different leader, different floor |
| Detection | `tests/sv-real-llm/lib/b3-band-revalidation.mjs` runs 5-iter sandbox + compares |
| Recovery | Refit `B3_BAND_*_MS` constants in `tests/sv-real-llm/lib/b3-lifecycle-assertions.sh`. See revalidation findings doc |
| Reference | v0.15.4 audit H4; revalidation doc `docs/plans/v0.15-phase-b3-revalidation-findings.md` |

---

## §4 — Release / packaging

### F4.1 — A2 dry-run before version bump
| Field | Value |
|---|---|
| Symptom | `npm publish --dry-run` exits non-zero with EPUBLISHCONFLICT |
| Root cause | Plan v6 placed A2 in preflight before Step 2 (version bump). With package.json still at prior version, dry-run targets registry-existing version |
| Detection | First-time observed in 2026-05-07 release attempt; documented as plan defect |
| Recovery | Split into A2 (pre-bump: tolerate EPUBLISHCONFLICT exit; verify tarball assembled) + A2' (post-bump: strict exit-0 dry-run) |
| Reference | v0.15.4 audit C3; runbook §1 + §2 step 2.5 |

### F4.2 — Internal docs leak in npm tarball
| Field | Value |
|---|---|
| Symptom | npm-published tarball ships `docs/plans/*` (internal audit + planning) totaling ~280KB |
| Root cause | package.json `files` glob entry `"docs/"` was overly broad |
| Detection | `npm pack --dry-run \| grep "docs/plans"` (M5 verification command) |
| Recovery | Narrow glob to `"docs/rlp-desk/"`. postinstall.js syncs only from `docs/rlp-desk/`, so this is safe |
| Reference | v0.15.4 audit M5; commit `d26421e` |

---

## §5 — Add new entries

When a new failure mode is identified:
1. Pick the smallest existing §N category that fits (or §6 if none)
2. Use the same field schema (Symptom / Root cause / Detection / Recovery / Reference)
3. Cross-link to the originating bug doc, audit, or test
4. Optional: add a sv-gate-fast grep guard to enforce the recovery contract

When a failure mode is permanently retired:
1. Move to §7 "Retired" (do NOT delete — historical reference)
2. Note retirement reason (e.g., "design changed in v0.16; replaced by ...")

---

## §6 — Open issues (no recovery yet)

### F6.1 — us006 real-tmux boundary test flakiness
| Field | Value |
|---|---|
| Symptom | `tests/node/us006-campaign-main-loop.test.mjs` AC6.1 boundary case (real tmux session w/ 4 panes) intermittently fails 2-5 of 377 Node suite tests on first run; passes cleanly on retry |
| Root cause | Real tmux session creation + pane process spawn race: `tmux send-keys` may fire before pane's shell is fully ready, causing `can't find pane` warnings (which are non-fatal but timing-sensitive assertions occasionally trip) |
| Detection | Observed 2026-05-07 + 2026-05-08 in v0.15.4 release pipeline preflight; first-run fail-count varies 2-5 of 377 |
| Recovery | Runbook §2 S2 retry-once policy: re-run `npm run test:node`. Second run consistently 377/377 PASS |
| Reference | v0.15.4 release pipeline observation; runbook §7.5.3 Stage 2 INFO-band-exceeded path is unrelated but uses same retry-once mental model |

**Why "open"**: the flake is in the test, not in production code. Adding retry-once to npm test:node script would mask actual regressions. Better fix: redesign the AC6.1 boundary test to use `wait-for-pane-ready` synchronization before sending keys. Deferred to a future v0.15.x patch — not release-blocking.

---

## §7 — Retired

(none as of 2026-05-08)
