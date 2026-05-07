# Bug Report #7 — Post-Sentinel Process Race Fix

## Context

BOS 사용자가 19th launch에서 측정한 race window:
- iter-1 verifier가 verdict detect 후 **1m 43s** 뒤 `verify-verdict.json` 재수정 (file mtime 증거)
- iter-1 verifier post-verdict 후속 활동 **2m 1s**
- iter-1 verifier ↔ iter-2 worker 동시 작업 약 **2분**

Bug report:
`/Users/kyjin/dev/doul/bos/docs/exec-plans/active/2026-05-06-rlp-desk-bug-report-7-post-sentinel-process-race.md`

### Root cause

Leader는 `iter-signal.json` / `verify-verdict.json` 발견 즉시 다음 iter로 진입하지만, 그 sentinel을 쓴 Worker/Verifier process(claude/codex TUI)는 **명시적으로 종료되지 않는다**. tmux pane은 살아 있고 TUI는 idle prompt로 회귀 후 자체 self-review를 수행 → sentinel 재수정·working tree 오염·토큰 낭비.

### 모드 영향 범위 (중요)

`--mode tmux`(zsh runner)와 `--mode agent`(Node leader) **둘 다 영향**. Node leader도 `defaultSendKeys`/`defaultCreatePane`(`src/node/tmux/pane-manager.mjs`)을 통해 실제 tmux pane 위에서 worker/verifier를 실행한다 (`src/node/runner/campaign-main-loop.mjs:1077-1080`, `1116-1133`). Agent 모드 면역이라는 초기 가설은 부정확.

### 비대칭 (현 상태)

| 경로 | Worker 후처리 | Verifier 후처리 |
|---|---|---|
| Node leader | 없음 | 없음 |
| zsh runner | 다음 iter 시작 시 cleanup (`run_ralph_desk.zsh:2948-2956`) — race window 5s+ | dispatch 직전 cleanup (`3160-3180`) — 같은 iter 내에선 보호되나 final iter 종료 후 또는 cross-iter race는 불보호 |

---

## Approach (Fix-Q + Fix-R, 최소 surgical 조합)

| Fix | 효과 | 채택 |
|---|---|---|
| **Q** Sentinel detect 즉시 producing pane에 Ctrl+C → process 종료 | race를 ~1초 안에 직접 차단 | **YES (primary)** |
| **R** Sentinel 파일 chmod 0444로 재수정 차단 | Q가 늦거나 fail해도 mtime 동결 | **YES (defense-in-depth)** |
| S Pane lifecycle 전면 리팩토링 | 효과는 있으나 surface가 너무 큼. 기존 prep cleanup (zsh 2948-2956)으로 부분 커버됨. Karpathy "surgical changes" 원칙 위반 | NO |
| T post-sentinel 30s 안전망 timeout | Q가 fail-open이고 다음 iter prep cleanup이 backup이라 중복 | NO |

근거:
- Q는 producer를 ~1초 내 죽여서 root cause 차단. 기존 패턴 정확히 미러 (zsh `run_ralph_desk.zsh:2384-2397`, Ctrl+C 더블 송신 + `wait_for_pane_ready`).
- R은 chmod 실패에 관대(EPERM/ENOTSUP 무시 — `scripts/postinstall.js:104` `tryLockFile` 선례). WSL1/NTFS/tmpfs 등 chmod no-op 환경에서도 graceful degradation.
- S/T 제거로 review surface 최소화.

---

## Concrete code changes

### Node leader

#### 1. `src/node/tmux/pane-manager.mjs` — helper 추가 (line 77 뒤)

신규 export:
- `sendRawKey(paneId, key)` — `runTmux(['send-keys', '-t', paneId, key])`. `sendKeys`(`-l --` literal text)와 분리: C-c 같은 raw key용.
- `killPaneProcess(paneId, { sendRawKey, waitForExit, gracePeriodMs=800, exitTimeoutMs=5000, log })`:
  1. `sendRawKey('C-c')` → `await sleep(gracePeriodMs)` → `sendRawKey('C-c')` (double press, zsh `375-376` 미러).
  2. `await waitForExit(paneId, { timeoutMs: exitTimeoutMs }).catch(log)` — fail-open.
  3. raw key 송신 자체의 TmuxError도 catch+log (이미 죽은 pane에 안전).

기존 `waitForProcessExit` (line 55) 그대로 재사용.

#### 2. `src/node/shared/fs.mjs` — helper 추가 (line 61 뒤)

- `lockSentinelFile(filePath, { log })` — `fs.chmod(filePath, 0o444)`, error 시 한 번만 경고 로그. `tryLockFile`(`scripts/postinstall.js:104`) 선례 미러.
- `unlockSentinelFile(filePath)` — `fs.chmod(filePath, 0o644)`, 실패 무시. iter cleanup 직전에 호출.

#### 3. `src/node/runner/campaign-main-loop.mjs` — wire + call sites

DI 슬롯 추가 (line 1077-1080):
```
const sendRawKey = options.sendRawKey ?? defaultSendRawKey;
const waitForProcessExit = options.waitForProcessExit ?? defaultWaitForProcessExit;
const killPaneProcess = options.killPaneProcess ?? defaultKillPaneProcess;
const lockSentinel = options.lockSentinelFile ?? lockSentinelFile;
```

내부 wrapper:
```
async function reapProducer(paneId, sentinelFile) {
  await killPaneProcess(paneId, { sendRawKey, waitForExit: waitForProcessExit, log: console.error });
  if (sentinelFile) await lockSentinel(sentinelFile, { log: console.error });
}
```

호출 사이트 (성공 + `validateArtifact` 통과 직후):

| Site | Line | 호출 |
|---|---|---|
| Flywheel poll | 1267-1277 다음 (1285 앞) | `reapProducer(state.flywheel_pane_id ?? state.verifier_pane_id, paths.flywheelSignalFile)` |
| Guard poll | 1305-1315 다음 (1323 앞) | `reapProducer(guardPaneId, paths.flywheelGuardVerdictFile)` |
| Worker poll | 1422-1432 다음 (1456 앞) | `reapProducer(state.worker_pane_id, paths.signalFile)` |
| Verifier poll | 1489-1513 다음 (1522 앞) | `reapProducer(state.verifier_pane_id, paths.verdictFile)` |
| Final per-US verifier (`runFinalSequentialVerify`) | 890-894 다음 (896 앞) | `reapProducer(verifierPaneId, paths.verdictFile)` — `runFinalSequentialVerify` 시그니처에 `reapProducer` 추가 + 호출처(1185-1194) 전달 |

iter cleanup unlock — `fs.unlink(...)` 호출 직전 `unlockSentinelFile` 호출:
- L1291 (`flywheelSignalFile`)
- L1328 (`flywheelGuardVerdictFile`)
- 루프 상단 (1145 직후) — Worker `signalFile` / Verifier `verdictFile` 방어적 unlock (다음 iter producer가 atomic rename으로 덮어쓸 때 대비)

### zsh runner

#### 4. `src/scripts/lib_ralph_desk.zsh` — helper 추가 (`atomic_write` 다음, line 245 뒤)

```
_kill_pane_process() {
  local pane_id="$1" role="${2:-producer}"
  log_debug "[bug7] kill_pane_process pane=$pane_id role=$role"
  tmux send-keys -t "$pane_id" C-c 2>/dev/null
  sleep 0.5
  tmux send-keys -t "$pane_id" C-c 2>/dev/null
  sleep 1
  wait_for_pane_ready "$pane_id" 5 2>/dev/null || true
}

_lock_sentinel() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  chmod 0444 "$file" 2>/dev/null || true
}

_unlock_sentinel() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  chmod 0644 "$file" 2>/dev/null || true
}
```

#### 5. `src/scripts/run_ralph_desk.zsh` — call sites

| Site | Line | 호출 |
|---|---|---|
| Worker poll 성공 직후 | 3003 (`worker_poll_done=1` 분기 안, `log_debug` 다음) | `_kill_pane_process "$WORKER_PANE" "worker"; _lock_sentinel "$SIGNAL_FILE"` |
| Verifier poll 성공 직후 (main path) | 3202 통과 후, 3215 앞 (`ITER_VERIFIER_END`) | `_kill_pane_process "$VERIFIER_PANE" "verifier"; _lock_sentinel "$VERDICT_FILE"` |
| Final-verify per-US (`run_sequential_final_verify`) | 2524 통과 후, 다음 iter 진입 전 | `_kill_pane_process "$VERIFIER_PANE" "verifier-final"; _lock_sentinel "$VERDICT_FILE"` |
| Codex grace path | `dispatch_verifier_per_us` (2420 그레이스 종료 직후, 2471 `cp` 앞) | `_kill_pane_process "$VERIFIER_PANE" "verifier-${suffix}"; _lock_sentinel "$VERDICT_FILE"` |
| Consensus path | `run_consensus_verification` 내 각 `poll_for_signal` 성공 직후 | 동일 패턴 |

prep cleanup unlock — line 2948-2956 cleanup 직전:
```
_unlock_sentinel "$SIGNAL_FILE"; _unlock_sentinel "$VERDICT_FILE"
rm -f "$SIGNAL_FILE" "$DONE_CLAIM_FILE" "$VERDICT_FILE" 2>/dev/null
```

---

## Files to modify

| 파일 | 변경 |
|---|---|
| `src/node/tmux/pane-manager.mjs` | `sendRawKey`, `killPaneProcess` export 추가 |
| `src/node/shared/fs.mjs` | `lockSentinelFile`, `unlockSentinelFile` export 추가 |
| `src/node/runner/campaign-main-loop.mjs` | DI + `reapProducer` + 5개 call site + iter cleanup unlock |
| `src/scripts/lib_ralph_desk.zsh` | `_kill_pane_process`, `_lock_sentinel`, `_unlock_sentinel` 추가 |
| `src/scripts/run_ralph_desk.zsh` | 4-5개 call site + prep cleanup unlock |
| `tests/node/us006-campaign-main-loop.test.mjs` | `createTmuxFakes()`에 `killPaneProcess`/`lockSentinelFile` 레코더 추가 + Bug-7 테스트 3건 |
| `tests/node/test-kill-pane-process.test.mjs` | NEW — helper 단위 테스트 |
| `tests/node/test-lock-sentinel-file.test.mjs` | NEW — chmod 단위 테스트 |
| `tests/test-bug7-post-sentinel-race.sh` | NEW — 실제 tmux 통합 테스트 (Bug #6 패턴 미러) |

배포는 단일 PR (helper는 call site 없으면 no-op이라 review surface 작음).

---

## Reused functions (참조)

- Node: `pane-manager.mjs:50` `sendKeys`, `pane-manager.mjs:55` `waitForProcessExit` (5s timeout, shell 감지)
- Node: `shared/fs.mjs:6-23` `writeFileAtomic`, `42-61` `writeSentinelExclusive`
- Node: `scripts/postinstall.js:104` `tryLockFile` (chmod 0o444 선례)
- zsh: `lib_ralph_desk.zsh:240-245` `atomic_write`, `1075-1137` `wait_for_pane_ready`
- zsh: `run_ralph_desk.zsh:2384-2397` 검증된 verifier-cleanup 패턴 (Ctrl+C + /exit + wait), `375-376/529-530` 더블 Ctrl+C 패턴

---

## Testing strategy

### 단위 테스트 (Node)

`tests/node/test-kill-pane-process.test.mjs` (NEW):
- AC1 정상: C-c → sleep → C-c → waitForExit 순서 (fake recorder 검증).
- AC2 fail-open: `waitForExit` 가 TmuxError throw 시 helper resolve.
- AC3 dead-pane: `sendRawKey` throw 시 resolve.
- AC4 grace: gracePeriodMs 준수 (fake clock 또는 tolerance 검증).

`tests/node/test-lock-sentinel-file.test.mjs` (NEW):
- AC1: lock 후 mode `& 0o222 === 0` (chmod 무시 FS는 skip).
- AC2: 존재하지 않는 path에 lock — throw 안 함.
- AC3: unlock 후 writable.

### 통합 테스트 (Node)

`tests/node/us006-campaign-main-loop.test.mjs` 확장:
1. **Bug-7-A**: Worker pollForSignal 성공 → next dispatchVerifier 전에 `killPaneProcess('%worker')` + `lockSentinelFile(signalFile)` 호출 순서 검증.
2. **Bug-7-B**: Verifier verdict pass 후 next iter dispatchWorker 전에 `killPaneProcess('%verifier')` + `lockSentinelFile(verdictFile)`.
3. **Bug-7-C**: `killPaneProcess`가 throw해도 run() 정상 완료.

`createTmuxFakes()`(line 83)에 fake `killPaneProcess`/`lockSentinelFile` 레코더 추가 (기존 30+ 테스트 호환 보장).

### 통합 테스트 (zsh)

`tests/test-bug7-post-sentinel-race.sh` (NEW, `test-bug6-worker-idle-false-positive.sh` 패턴 미러):
- Scenario 1: tmux 세션에 `sleep 600` 띄우고 `_kill_pane_process` 호출 → 2s 안에 `pane_current_command`가 zsh/bash로 회귀.
- Scenario 2: `_lock_sentinel` → mode 0444 검증 → `_unlock_sentinel` → writable → `rm -f` 성공.
- Scenario 3 (REAL_E2E gated): 1-iter 캠페인 + stub claude(sentinel write 후 sleep 120) → 10s 후 verdict file mtime delta == 0.

### Self-Verification 시나리오 (CLAUDE.md gate, 3건 필수)

`src/scripts/run_ralph_desk.zsh` 수정 — MEDIUM-HIGH risk:
- **LOW**: helper 단위 테스트 + 기존 Node/zsh 회귀 테스트 통과.
- **MEDIUM**: 1-iter 실제 캠페인. Worker → Verifier 전이 시점에 `pane_current_command` 캡처, 2s 내 shell 회귀 검증. Verdict file mtime 동결 검증.
- **CRITICAL**: 2-iter 캠페인 (verify→fail→verify→pass). iter-N+1 worker dispatch가 iter-N verifier `pane_current_command == zsh` 확인 후에만 발생 — 타임스탬프 로그 캡처. `--mode agent`와 `--mode tmux` 둘 다 실행.

---

## Verification end-to-end

1. **단위**: `node --test tests/node/test-kill-pane-process.test.mjs tests/node/test-lock-sentinel-file.test.mjs` 통과.
2. **통합 (Node)**: `node --test tests/node/us006-campaign-main-loop.test.mjs` 통과 — call order 단언이 회귀 가드.
3. **라이브 tmux**: `_kill_pane_process` 호출 후 2s 내 `tmux display-message -p '#{pane_current_command}' -t $pane`가 `zsh`/`bash` 반환.
4. **mtime 동결**: `stat -f %m verify-verdict.json`을 detect 시점과 +10s 시점에 측정해 delta == 0. Bug report의 1m43s 증거를 직접 반박.
5. **Pane 출력**: `tmux capture-pane -p` 결과에 `Worked for Xm Ys` / `esc to interrupt` 신규 표식 없음.
6. **두 모드**: 스모크 테스트를 `--mode tmux`(zsh runner)와 `--mode agent`(Node leader) 각각 실행 — 둘 다 4초 내 shell 회귀 검증.
7. **재현 시나리오**: 19th launch와 동일 조건(claude opus 1m worker + gpt-5.5:high codex verifier)으로 캠페인 1회 실행 후 leader log + file mtime 비교 — race 0.

---

## Risk / mitigation

| Risk | 가능성 | 완화 |
|---|---|---|
| C-c가 producer artifact 쓰기 중간 인터럽트 | LOW — sentinel은 detect 시점에 이미 디스크에 존재 | `MalformedArtifactError` 경로가 partial write 처리 |
| chmod 0444가 다음 iter cleanup의 `unlink` 차단 | LOW | `_unlock_sentinel` / `unlockSentinelFile`이 unlink 직전 실행. 대부분 Unix FS는 dir-perms 기준이라 0444 파일도 unlink 가능 |
| Producer가 atomic rename으로 sentinel 재기록 (chmod 우회) | POSSIBLE | Q(kill)이 ~1s 내 producer 죽이므로 rewrite window가 2분 → 1초로 축소. 게다가 leader는 이미 in-band로 sentinel 소비 |
| `killPaneProcess`가 죽은 pane에 throw | POSSIBLE | helper 내부 catch + 단위 테스트 AC2/AC3로 회귀 가드 |
| chmod 0444 silent no-op (WSL1/NTFS/tmpfs) | OBSERVED (postinstall.js 선례) | 한 번만 경고 로그. Q(kill)이 primary defense라 graceful degradation |
| 기존 us006 테스트 회귀 | MEDIUM | `createTmuxFakes()`에 fake helper 레코더 추가 — 기존 호출자는 자동 주입 받음 |
