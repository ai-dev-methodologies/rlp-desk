# Plan — v0.14.0 Recovery: 원래 의도대로 동작 회복 (zsh primary for tmux)

> **상위 우선순위 plan. 아래 v0.13.0 plan은 history reference로 보존.**
> **Trigger**: 사용자 평가 — "rlp-desk가 못 쓸 폐급, 통제 불가능 수준". v0.13.0/v0.13.1 fix는 빙산 일각.
> **Target version**: 0.14.0
> **승인된 strategy**: 경로 A (zsh restoration as tmux primary; Node leader는 `--mode agent`만 담당)

---

## A. Context (v0.14.0)

### 문제 진단

2026-04-12 Node port 시점부터 v0.13.x까지, **Node leader가 zsh runner의 핵심 안전망 11개를 누락한 채 ship**. 사용자(BOS) 평가는 "통제 불가능". v0.13.0/v0.13.1 patch는 다음 2개만 해결:
1. `.claude/` sensitive prompt hang
2. detached session UX 회귀

**여전히 누락된 것** (file:line 인용):
| # | 기능 | zsh location | Node 상태 |
|---|------|--------------|----------|
| 1 | Copy-mode 가드 send-keys | `safe_send_keys` L976-1083 | 없음 (pane-manager.mjs:50-53 단순 send-keys) |
| 2 | Heartbeat 주기적 쓰기 + staleness 감지 | L1735-1750, L1158 | 없음 |
| 3 | No-progress 10분 byte-stasis 감지 | `check_no_progress` L2372-2420 | 없음 |
| 4 | Prompt-stall 5분 timeout | `check_prompt_stall` L2298-2370 | 없음 |
| 5 | Stale-context 3 consecutive unchanged iter | `check_stale_context` lib L1162-1179 | 없음 |
| 6 | Claude 모델 upgrade chain (haiku→sonnet→opus) | `get_next_model` lib L136-155 | 없음 (codex chain만) |
| 7 | LOCK_WORKER_MODEL flag 처리 | lib L197 | 없음 |
| 8 | Codex update prompt auto-dismiss | L1007-1011 | 없음 |
| 9 | Pane lifecycle cleanup | `cleanup_panes` L3310-3320 | 없음 (`_ensureTerminalSentinel` 부분만) |
| 10 | 사용자 pane-kill graceful detection | L134-150 | 없음 |
| 11 | Cleanup trap (C-c → /exit → kill-pane) | L1864-2014 | 부분만 |

### 핵심 결정

**zsh를 tmux mode primary path로 복원, Node leader는 `--mode agent`(LLM-driven orchestration) 단독 담당**.

**근거**:
- zsh runner는 v0.12.0 deprecation 전까지 6주+ production 검증.
- Node port의 누락 11개를 모두 port = 5-7일 + 새 회귀 위험. zsh 복원 = 1-2일 + 검증된 코드.
- Node leader는 LLM이 worker/verifier를 spawn하는 agent mode에 고유 가치 — tmux 기계적 orchestration은 zsh가 더 잘함.
- 사용자 즉시 회복 우선.

---

## B. Approach (6 Phases)

### Phase 1 — zsh deprecation 게이트 해제 (Day 1, 2시간)

**파일**: `src/scripts/run_ralph_desk.zsh`
- L69-90: `--flywheel`/`--with-self-verification`/`--flywheel-guard` hard-reject 블록 제거. zsh가 이 flag들을 다시 honor.
- L91 "deprecated" 메시지 제거.
- `RALPH_DESK_VERSION` 0.14.0으로 갱신.

### Phase 2 — Node `--mode tmux` → zsh subprocess 라우팅 (Day 1, 4시간)

**파일**: `src/node/run.mjs`
- `parseRunOptions()` 후 `runRunCommand()` 진입에서 `mode === 'tmux'` 분기:
  - `~/.claude/ralph-desk/run_ralph_desk.zsh` 경로 확인 (postinstall이 sync 보장).
  - 모든 옵션을 env vars로 변환 (`LOOP_NAME`, `WORKER_MODEL`, `FLYWHEEL`, `FLYWHEEL_GUARD`, `WITH_SELF_VERIFICATION`, `MAX_ITER`, `ITER_TIMEOUT`, `CB_THRESHOLD`, `CONSENSUS_*`, `LOCK_WORKER_MODEL` 등).
  - `child_process.spawn('zsh', [zshPath], { env, stdio: 'inherit' })`로 위임.
  - exit code 그대로 propagate.
- legacy detection (`detectLegacyDeskInRunMode`) 호출은 zsh spawn 전에 유지.
- claude+tmux warning 유지 (zsh도 같은 worker engine 분기에서 적용).

**파일**: `src/node/runner/campaign-main-loop.mjs`
- `run()` 진입에서 `options.mode === 'tmux'`일 때 가드: `throw new Error('tmux mode is delegated to zsh — invoke via run.mjs router')`. dead-code 표시 + 회귀 방지.

### Phase 3 — postinstall + install.sh가 zsh를 항상 sync (Day 1, 1시간)

**파일**: `scripts/postinstall.js`
- 현재 `legacyFiles` 배열로 zsh 3개 삭제 → **유지·sync로 변경**.
- `runtimeSources`에 `src/scripts/{init,run,lib}_ralph_desk.zsh` → `~/.claude/ralph-desk/` 추가 (또는 `scripts/` 하위 — install.sh와 일관성 결정).
- banner-aware sync.

**파일**: `tests/node/us008-cli-entrypoint.test.mjs:47`
- 기존 "removes legacy zsh scripts" 테스트 invert: zsh 3개가 install 후 존재 + spawnable 검증.

### Phase 4 — Node `--mode agent` 라벨링 (Day 2, 2시간)

**파일**: `src/node/run.mjs`, `src/commands/rlp-desk.md`, `README.md`
- `--mode agent` 진입 시 stderr 경고: "agent mode is alpha — for production use --mode tmux".
- README mode 표:
  - `tmux` (stable, zsh-backed)
  - `agent` (alpha, Node-native)
- v0.13.0/0.13.1 fix(`.claude/` 마이그레이션, prompt-detector, claude+tmux warning)는 모두 agent mode에서 잔존 — Node 단독 가치 보존.

### Phase 5 — 검증 시나리오 (Day 2-3, 1일)

**Self-verification gate (`tests/sv-self-verify-0.14.sh`)** — v0.13 시나리오 + 신규:
- L5.1 (CRITICAL) BOS 회귀: claude worker + tmux mode + 1 iter 완주 (실제 tmux session 생성, kill-session cleanup).
- L5.2 (CRITICAL) zsh subprocess routing: `--mode tmux` 호출이 `child_process.spawn('zsh', ...)`로 위임됐는지 mock 검증.
- L5.3 (CRITICAL) flag → env var conversion 단언 (모든 supported flag 1개씩).
- L5.4 (MEDIUM) zsh deprecation 게이트 제거 검증 (L69-90).
- L5.5 (MEDIUM) postinstall이 zsh 3개를 install (us008 invert).
- L5.6 (MEDIUM) `--mode agent` warning 출력 검증.
- L5.7 (UX) attached tmux 안에서 leader+worker+verifier panes 사용자 현재 window에 표시 (zsh L815-823 동작).

### Phase 6 — Ship (Day 3)

CLAUDE.md release workflow 그대로:
1. self-verification gate 17/17 PASS.
2. ralplan + codex review (기존 mandate).
3. version bump 0.14.0.
4. CHANGELOG: "Restore zsh as primary tmux runner. Node tmux delegates to validated zsh codepath. Node agent mode marked alpha."
5. commit + push + gh release + npm publish.
6. local sync banner-aware verify.

---

## C. v0.13.x에서 보존되는 것

- `.claude/ralph-desk/` → `.rlp-desk/` 경로 마이그레이션 (init mode auto-mv, run mode 안내) — zsh도 v0.13.0에서 이미 반영됨.
- `RLP_DESK_RUNTIME_DIR` env override.
- prompt-detector + signal-poller permission_prompt 감지 — agent mode 전용.
- BLOCK_TAGS.PERMISSION_PROMPT 상수.
- claude+tmux warning (run.mjs 진입 시).

---

## D. v0.15.0+ 점진 port 백로그 (deferred)

**P0 (2주 내, agent mode parity 위해)**:
- heartbeat 메커니즘
- copy-mode 가드 send-keys
- prompt-stall 5분 timeout
- no-progress 10분 byte-stasis

**P1**:
- stale-context 감지
- claude 모델 upgrade chain (haiku→sonnet→opus)
- LOCK_WORKER_MODEL flag

**P2**:
- codex update prompt auto-dismiss
- pane lifecycle cleanup
- user-kill graceful detection
- cleanup trap full parity

---

## E. Critical Files

```
src/scripts/run_ralph_desk.zsh          # Phase 1 — deprecation 게이트 해제
src/scripts/lib_ralph_desk.zsh          # 변경 없음 (zsh helpers 그대로)
src/scripts/init_ralph_desk.zsh         # 변경 없음 (v0.13.0 마이그레이션 그대로)
src/node/run.mjs                        # Phase 2 — tmux mode 라우터
src/node/runner/campaign-main-loop.mjs  # Phase 2 — tmux mode 가드
scripts/postinstall.js                  # Phase 3 — zsh sync 복원
tests/node/us008-cli-entrypoint.test.mjs # Phase 3 — invert
src/commands/rlp-desk.md                # Phase 4 — mode 표 갱신
README.md                                # Phase 4 — stable/alpha 표시
package.json                             # Phase 6 — 0.14.0
tests/sv-self-verify-0.14.sh             # Phase 5 — 신규 SV gate
```

---

## F. 검증 (E2E)

1. **BOS 회귀 (CRITICAL)**: BOS 프로젝트 worktree에서 `node ~/.claude/ralph-desk/node/run.mjs run bos-phase-1 --mode tmux --worker-model sonnet --max-iter 1 --iter-timeout 600` → tmux session 생성, leader/worker/verifier panes 사용자 현재 window에 split, 1 iter sentinel write 성공, no permission prompt hang.
2. **Local sync**: `npm install` 후 `~/.claude/ralph-desk/run_ralph_desk.zsh` 존재 + banner.
3. **Backward compat**: v0.13.x mid-campaign 사용자 — `mv .claude/ralph-desk .rlp-desk` 안내 그대로.

---

## G. 기각된 대안

- **B (Node 전면 port)**: 11 features × 평균 3시간 + parity 회귀테스트 = 5-7일 + 신규 버그 위험. v0.15.0+ 점진 port로 deferred.
- **C (단독 라벨링)**: experimental 라벨만으로는 "통제 불가능" 즉시 해소 불가. 경로 A에 흡수.

---

# v0.13.0 (HISTORY) — Claude worker `.claude/` sensitive prompt hang 수정

> **Source bug report**: `/Users/kyjin/dev/doul/bos/docs/exec-plans/active/2026-05-01-rlp-desk-bug-report.md`
> **Severity**: HIGH — `--mode tmux` + `--worker-model sonnet/haiku/opus` 조합에서 모든 campaign blocking
> **Target version**: 0.13.0 (breaking — project-local sentinel 경로 이동) — **SHIPPED**, but coverage was a sliver of the real failure surface (see v0.14.0 plan above).

---

## 1. Context

### 문제

`<project>/.claude/ralph-desk/memos/<slug>-done-claim.json` 등 sentinel 작성 시
Claude Code가 `.claude/` 경로를 self-modification suspect로 hardcoded 처리하여
permission prompt를 띄움. `--dangerously-skip-permissions`로도 우회 X.
Worker hang → Leader pollForSignal 30분 timeout → BLOCKED(`infra_failure`).

Codex worker(gpt-5.5:* 등)에서는 미발생 — Claude Code의 sensitive 정책 외부.
즉 **현재는 Claude 계열 worker가 사실상 사용 불가**.

### 핵심 결정

프로젝트-로컬 runtime 디렉토리를 `<project>/.claude/ralph-desk/`에서
`<project>/.rlp-desk/`로 이동.

**근거**:
- Claude Code의 sensitive 검사 트리거는 `.claude/` 디렉토리명 자체.
- 디렉토리명만 바꾸면 회피 (영감 출처 design-desk도 `.claude/` 안에 sentinel을 두지 않음).
- `~/.claude/ralph-desk/`(설치 위치 + cross-project analytics)는 변경 없음 — Leader가
  자기 자신의 install dir을 self-modify할 일은 없으므로 sensitive 검사 트리거 안 함.

### 비-목표

- `~/.claude/ralph-desk/` 설치 경로 변경 (registry, analytics, leader binaries 유지)
- `--mode agent` 폐지 (Fix-1로 자동 해결되므로 그대로 유지)

---

## 2. Approach (3단계)

### Phase 1 — Fix-1: 프로젝트-로컬 sentinel 경로 이동 (`.claude/ralph-desk/` → `.rlp-desk/`)

**변경 대상 파일** (Explore 결과):

| File | 위치 | 변경 내용 |
|------|------|----------|
| `src/node/init/campaign-initializer.mjs` | L5, L13 | `GITIGNORE_RULE` + `deskRoot` 상수 |
| `src/scripts/init_ralph_desk.zsh` | L77, L1091, L1100, L1105-1137 | `DESK` 변수 + permission marker 패턴 |
| `src/scripts/run_ralph_desk.zsh` | L255 | `DESK` 변수 |
| `src/scripts/lib_ralph_desk.zsh` | L57 | 홈 디렉토리 변수 주석 명확화 (변경 없음, 주석만) |
| `src/node/runner/campaign-main-loop.mjs` | L44-80 | 경로 빌드 함수 |
| `src/commands/rlp-desk.md` | 24개 라인 | 모든 `.claude/ralph-desk/` → `.rlp-desk/` 참조 |
| `src/governance.md` | 6개 라인 | 경로 문서화 |

**유지(변경 없음)**:
- `src/node/runner/leader-registry.mjs` (홈 디렉토리 `~/.claude/ralph-desk/registry.jsonl`)
- `install.sh`, `scripts/postinstall.js` (홈 디렉토리 설치)

**Worker/Verifier `--add-dir` whitelist**:
- 기존: `--add-dir "$HOME/.claude/ralph-desk" "$ROOT"` (lib_ralph_desk.zsh:57-58).
- `$ROOT`가 이미 whitelist이므로 `$ROOT/.rlp-desk`는 **자동 포함** — 별도 추가 불필요.
- 핵심은 디렉토리명 변경 자체로 sensitive 검사 trigger를 회피하는 것이지, sandbox/permission 변경이 아님.

**Runtime dir override (Synthesis — 미래 회피책)**:

`deskRoot`를 환경변수 `RLP_DESK_RUNTIME_DIR`로 외부화. 기본값 `.rlp-desk/`. 향후 platform이 또 sensitive 검사를 확장하면 사용자가 즉시 `RLP_DESK_RUNTIME_DIR=.rlp-runtime/` 등으로 우회 가능. P1(don't fight platform)을 코드 단에 영속화.

**Migration race-safety (atomic — Codex Critic 반영)**:

이 절차는 **init 모드 진입 시에만** 실행. run 모드는 §2 Phase 3 정책대로 자동 mv 수행 안 함(경고 + 수동 안내).

- 락 파일 위치: `<project>/.rlp-desk-migration.lock` (target dir 외부 — target dir이 아직 없을 수 있으므로 parent `<project>/`에 둠).
- 락 획득: `fs.openSync(lockPath, 'wx')` (exclusive create — TOCTOU 없음). 이미 존재하면 "다른 프로세스가 마이그레이션 중" 에러로 즉시 abort.
- init 모드 마이그레이션 절차 (락 보유 상태):
  1. 양쪽(legacy `.claude/ralph-desk/` + new `.rlp-desk/`) 존재 여부 검사.
  2. 둘 다 존재 → 자동 mv **거부** + 사용자 정리 안내 (pre-mortem #1 binding).
  3. legacy만 존재 → `fs.renameSync(legacy, new)` (원자적, 같은 파일시스템 내).
  4. 둘 다 없음 → noop (정상 init).
- run 모드(legacy 발견 시): mv 시도하지 않고 비-zero exit + 수동 명령 안내. 진행 중 캠페인 보호.
- 락 해제: `try/finally`로 `fs.unlinkSync(lockPath)` 보장. 프로세스 crash 시 다음 실행에서 stale 락 감지(mtime > N분) 시 경고 후 제거.
- `fresh` 모드(`campaign-initializer.mjs:20`의 `fs.rm({recursive:true})`)는 마이그레이션 완료 후 새 경로에서만 실행.

### Phase 2 — Fix-2: Claude worker + tmux 조합 경고

**위치**: `src/node/cli/command-builder.mjs` (이미 `CLAUDE_MODELS = Set(['haiku','sonnet','opus'])` 존재).

**로직**: `parseRunOptions()` (`src/node/run.mjs:101-180`) 파싱 후
`runRunCommand` 진입 시점에 다음 검증 추가:

```js
// src/node/run.mjs (파싱 후 검증 단계)
if (mode === 'tmux' && isClaudeEngine(workerModel)) {
  console.warn(
    'WARNING: Claude worker in tmux mode may hang on .claude/ sentinel writes.\n' +
    'After v0.13.0, sentinels live in <project>/.rlp-desk/ which avoids this.\n' +
    'If hang persists, switch to --worker-model gpt-5.5:high (codex) or --mode agent.'
  );
}
```

PRD brainstorm 플로우(`src/commands/rlp-desk.md`)에도 동일 경고 문구 노출.

**Observability — sentinel hang early-detect 휴리스틱** (Architect synthesis):

기존 Leader pollForSignal은 30분 timeout으로만 감지 → silent failure. 보강:
- Worker pane stdout에 `Do you want to ` / `❯ 1. Yes` 등 prompt 시그니처 grep → 즉시 BLOCKED + `category=permission_prompt`로 라벨링.
- 위치: `src/node/runner/prompt-dismisser.mjs` 또는 별도 `prompt-detector.mjs`.
- 효과: 다음 platform 변화 시에도 30분이 아니라 수 초 내 발견.

### Phase 3 — 마이그레이션 도우미 (legacy `.claude/ralph-desk/` 감지)

**위치**: `src/node/init/campaign-initializer.mjs` 진입 시 + `src/node/runner/campaign-main-loop.mjs` `ensureScaffold()` 직전.

**로직**:
1. `<project>/.claude/ralph-desk/`가 존재하고 `<project>/.rlp-desk/`가 없으면
   감지 후 다음 중 하나:
   - **자동 mv** (init 모드): scaffold가 새로 만들어지는 단계라면 §2 Migration race-safety 절차로 자동 이동.
   - **경고 + 수동 명령 안내** (run 모드): 비-zero exit + "기존 캠페인이 있습니다. `mv .claude/ralph-desk .rlp-desk` 후 재실행하세요."
2. 양쪽 다 존재 시 — 모드 무관하게 자동 mv **거부** + 비-zero exit + 사용자 정리 안내(stderr에 "both directories exist" 포함). §2 Migration race-safety + §3a MEDIUM-B 검증과 일치.
3. `.gitignore`에서 `.claude/ralph-desk/` 라인 제거 + `.rlp-desk/` 라인 추가 (init 시점, mv 성공 후).

---

## 3. Verification

CLAUDE.md mandate에 따라 commit 전 다음을 모두 통과해야 함:

### 3a. Self-Verification (6 scenarios — `src/governance.md`/`init_ralph_desk.zsh` 변경 시 mandatory; executable commands)

각 시나리오: Worker(execution_steps) → Verifier(reasoning, 5 categories) → PASS.

#### LOW (단위 — `isClaudeEngine()` + env 해석)
```bash
node --test tests/node/test-claude-engine-detect.mjs
# expected: tests passed; isClaudeEngine('sonnet') === true; resolveDeskRoot(env={RLP_DESK_RUNTIME_DIR:'.x'}) === '.x'
```

#### MEDIUM-A (auto-mv 정상 케이스 — pre-mortem #2 part)
```bash
TMP=$(mktemp -d); cd "$TMP"; git init -q
mkdir -p .claude/ralph-desk/memos && echo data > .claude/ralph-desk/memos/x.md
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous
test ! -d .claude/ralph-desk && test -f .rlp-desk/memos/x.md && \
  grep -q '"Read(.rlp-desk/\*\*)"' .claude/settings.local.json
# expected: exit 0, all assertions PASS
```

#### MEDIUM-B (conflict 거부 — pre-mortem #1 binding)
```bash
TMP=$(mktemp -d); cd "$TMP"; git init -q
mkdir -p .claude/ralph-desk .rlp-desk
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous 2> stderr.log
test $? -ne 0 && grep -q 'both directories exist' stderr.log
# expected: non-zero exit, conflict 안내
```

#### HIGH-A (claude+tmux E2E — AC4 binding, primary fix 검증)
```bash
TMP=$(mktemp -d); cd "$TMP"; git init -q
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous
timeout 600 node ~/.claude/ralph-desk/node/run.mjs run testslug \
  --mode tmux --worker-model sonnet --max-iter 1 --iter-timeout 300
test $? -eq 0 && test -f .rlp-desk/memos/testslug-done-claim.json
# expected: exit 0, sentinel hang 없이 완료
```

#### HIGH-B (codex+tmux 회귀 — AC5 binding, P3 first-class)
```bash
TMP=$(mktemp -d); cd "$TMP"; git init -q
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous
timeout 600 node ~/.claude/ralph-desk/node/run.mjs run testslug \
  --mode tmux --worker-model gpt-5.5:high --max-iter 1 --iter-timeout 300
test $? -eq 0 && test -f .rlp-desk/memos/testslug-done-claim.json
# expected: exit 0, codex worker 회귀 없음
```

#### OBSERVABILITY (prompt 조기 감지 — AC6 binding)
```bash
# 모의 worker stdout에 "❯ 1. Yes" 라인 주입 → prompt-detector가 5초 이내 BLOCKED 작성
node tests/node/test-prompt-detector-e2e.mjs
jq -r .category .rlp-desk/memos/testslug-blocked.json
# expected: "permission_prompt"
```

### 3b. Review

- **ralplan** (Planner→Architect→Critic): governance/template 변경이므로 mandatory.
- **codex review**: 0 issue 도달까지 반복 (CLAUDE.md mandate).

### 3c. Local sync 검증

CLAUDE.md `Local File Sync` 섹션의 banner-aware verification 절차로
모든 `src/` 변경분이 `~/.claude/ralph-desk/`에 sync되었는지 확인:

```bash
diff -rq src/node ~/.claude/ralph-desk/node | grep -v 'DO NOT EDIT'
# expected: empty output (모든 파일이 banner 차이 외에 동일)
```

### 3d. 수동 reproduction (버그 리포터 시나리오 재현)

```bash
# legacy 경로 시뮬레이션
mkdir -p /tmp/test-rlp-desk/.claude/ralph-desk
cd /tmp/test-rlp-desk

# init → 마이그레이션 또는 신규 .rlp-desk 생성 확인
node ~/.claude/ralph-desk/node/run.mjs init test-slug --autonomous

# 검증: .rlp-desk/ 존재 + .gitignore 갱신
test -d .rlp-desk && echo PASS || echo FAIL
grep -q '^.rlp-desk/$' .gitignore && echo PASS || echo FAIL

# 1-iter campaign with claude worker
node ~/.claude/ralph-desk/node/run.mjs run test-slug \
  --mode tmux --worker-model sonnet --max-iter 1 --iter-timeout 600
# 기대: sentinel hang 없이 1 iteration 완료
```

---

## 4. Release Plan

- **버전**: `0.13.0` (npm minor bump — 자동 마이그레이션 + run 모드 명확한 안내로 사용자 영향 흡수).
- **Release notes** (user-facing only — CLAUDE.md mandate; 최상단에 BREAKING 라벨 강조):
  - **BREAKING**: project-local runtime이 `.claude/ralph-desk/` → `.rlp-desk/`로 이동.
    init 모드는 자동 마이그레이션, run 모드는 경고 + 수동 `mv .claude/ralph-desk .rlp-desk` 안내.
  - **NEW**: `RLP_DESK_RUNTIME_DIR` 환경변수로 runtime 디렉토리 override 가능 (미래 platform 변화 회피용).
  - **FIX**: Claude worker + tmux 조합 sentinel write hang 해결.
  - **NEW**: claude worker + tmux 조합 경고 + permission prompt 조기 감지(BLOCKED `category=permission_prompt`).
  - **Roadmap note**: 1.0.0에서 legacy 감지 로직 deprecation 예정 (deprecation cycle 약속).

---

## 5. Critical files (이 plan 실행 시 수정 대상 요약)

```
src/node/init/campaign-initializer.mjs       # deskRoot 상수 + GITIGNORE_RULE + 마이그레이션 감지
src/node/runner/campaign-main-loop.mjs       # 경로 빌드 함수 + ensureScaffold() 전 legacy 검사
src/node/cli/command-builder.mjs             # isClaudeEngine() helper export
src/node/run.mjs                             # parseRunOptions() 후 tmux+claude 경고
src/scripts/init_ralph_desk.zsh              # DESK 변수 + permission marker (.rlp-desk/**)
src/scripts/run_ralph_desk.zsh               # DESK 변수
src/scripts/lib_ralph_desk.zsh               # 변경 없음 ($ROOT 이미 whitelist이므로 .rlp-desk 자동 포함; 주석만 명확화)
src/commands/rlp-desk.md                     # 24개 라인 경로 참조 갱신
src/governance.md                            # 6개 라인 경로 문서화
package.json                                 # version 0.13.0
```

---

## 6. Resolved decisions (사용자 확정 — 추천안)

- **마이그레이션 정책**: init 모드 = 자동 mv, run 모드 = 경고 + 수동 mv 안내. 사용자 데이터(memos, plans)
  존재 시 init은 새 scaffold가 만들어지는 시점이라 안전하게 이동 가능, run은 진행 중인 campaign일 수
  있으므로 명시적 사용자 확인 필요.
- **버전 강도**: `0.13.0` (npm minor). Project-local 경로 변경은 breaking이지만 자동 마이그레이션
  도우미 + run 모드 명확한 안내가 있으므로 minor로 충분. major(1.0.0)는 후속 안정화 단계에서.
- **`--mode agent` 처리**: Fix-1(경로 이동)으로 자동 해결. agent mode worker도 동일하게 `.rlp-desk/`에
  쓰므로 Claude Code sensitive trigger 발생 안 함. 별도 작업 불필요.

---

## 7. RALPLAN-DR Deliberation Summary

### Principles

1. **Don't fight platform-reserved namespaces** — Claude Code hardcoded sensitive policy 우회 불가; 회피만이 답.
2. **Project-local runtime은 git 트리에 머물러야** — 캠페인 memory/plans는 iteration 간 영속 필요.
3. **Cross-engine fallback은 first-class** — codex worker는 영구적 회피책이 아닌 동등한 옵션.
4. **마이그레이션 안전성 우선, 자동화는 명확히 안전한 시점에만** — init 모드는 fresh scaffold 시점이라 자동 mv, run 모드는 진행 중 캠페인 보호를 위해 경고 + 수동 mv. "default 자동"이 아닌 "context-aware 자동/수동 선택".

### Decision Drivers (top 3)

1. **Unblock HIGH severity blocker** — claude-worker + tmux 모든 캠페인 차단 중.
2. **Minimize breaking surface** — 진행 중 campaign 손실 방지.
3. **Reference parity** — design-desk(영감 출처)도 sentinel을 `.claude/` 밖에 둠.

### Viable Options

| Option | Pros | Cons |
|---|---|---|
| **A. `.rlp-desk/` 이동 (권장)** | `.claude/` trigger 완전 회피, design-desk 패턴 일치, git 트리 유지 | 모든 사용자 마이그레이션 필요 (자동화로 완화) |
| **B. `.claude/ralph-desk/` 유지 + 권한 escape** | 경로 변경 없음 | 사용자 repro에서 permission allowlist도 우회 실패. Claude Code 내부 동작 의존 → brittle |
| **C. `$TMPDIR/rlp-desk-<slug>/`** | 프로젝트 트리 청결 | git 추적 끊김, campaign memory 영속성 깨짐, resume 취약 |

### Invalidation rationale

- **B**: 버그 리포트 §2 표에서 `Read/Edit/Write(.claude/ralph-desk/**)` allowlist 추가가 실패함이 입증. Claude Code의 sensitive 게이트는 일반 permission 시스템과 별도로 동작 → 의존 불가.
- **C**: campaign memory(`memos/<slug>-memory.md` 등)는 iteration 간 영속이 핵심 설계. tmpfs 기반은 OS 재부팅/clean 시 유실되어 resume 불가능.

→ **A가 유일한 viable option**.

### Pre-mortem (3 scenarios — verification §3a에 명시 binding)

1. **자동 mv가 사용자 데이터 덮어쓰기**: 양쪽 디렉토리 모두 존재 시 mv 충돌 → mitigation: §2 Phase 3의 atomic lock + 충돌 거부. **검증**: §3a MEDIUM-B.
2. **권한 marker 누락**: `.rlp-desk/**` permission이 `init_ralph_desk.zsh`에 추가 안 되면 worker가 새 경로에서도 prompt 발생 → mitigation: permission marker 패턴 갱신 + assertion. **검증**: §3a MEDIUM-A의 `grep -q '"Read(.rlp-desk/\*\*)"' .claude/settings.local.json` 단언 + §3a HIGH-A의 1-iter 캠페인 sentinel write 성공(end-to-end).
3. **Sandbox `--add-dir` 미커버**: `$ROOT`가 이미 whitelist이므로 자동 포함이지만, 만약 `--add-dir` 인자 변경으로 회귀하면 sandbox가 새 경로 거부 → mitigation: 통합 테스트에서 worker 명령 빌드 결과 단언. **검증**: §3a HIGH-A의 worker spawn 단계에서 `claude --add-dir "$ROOT" ...` 명시 확인 + §3d 수동 1-iter 재현.

### Acceptance Criteria (자동 검증 가능 — pass 신호 명시)

- [ ] **AC1** — `<project>/.rlp-desk/`만 사용. 검증: `find . -type d -path '*.claude/ralph-desk' -newer <campaign-start-marker> | wc -l` == 0.
- [ ] **AC2** — Legacy `.claude/ralph-desk/` 존재 시 init은 자동 mv 후 `.gitignore`에 `.rlp-desk/` 라인 존재. 검증: `test ! -d .claude/ralph-desk && test -d .rlp-desk && grep -q '^\.rlp-desk/$' .gitignore`.
- [ ] **AC3** — Run 모드에서 legacy 발견 시 비-zero exit + stderr에 `mv .claude/ralph-desk .rlp-desk` 안내 문자열 포함. 검증: `node run.mjs run ...; echo $? != 0; grep -q "mv .claude/ralph-desk" stderr.log`.
- [ ] **AC4** — `--mode tmux --worker-model sonnet` 1-iter 캠페인 600초 이내 종료 + `done-claim.json` 존재 + exit 0. 검증: `timeout 600 node run.mjs run ... --max-iter 1; test $? == 0 && test -f .rlp-desk/memos/<slug>-done-claim.json`.
- [ ] **AC5** — `--worker-model gpt-5.5:high` 1-iter 캠페인 동일 단언(AC4 패턴) — 회귀 없음.
- [ ] **AC6** — Permission prompt 조기 감지: worker에 mock prompt 주입 시 5초 이내 BLOCKED + sentinel `category=permission_prompt`. 검증: `jq -r .category .rlp-desk/memos/<slug>-blocked.json == "permission_prompt"`.

---

## 8. ADR (Architectural Decision Record)

- **Decision**: Project-local sentinel/runtime을 `.claude/ralph-desk/` → `.rlp-desk/`로 이동.
- **Drivers**: Claude Code hardcoded sensitive policy로 worker hang. 우회 불가 → 디렉토리 명 변경.
- **Alternatives considered**: B(`.claude/` 유지 + escape) — 사용자 repro에서 입증 실패. C(`$TMPDIR/`) — campaign memory 영속성 손상.
- **Why chosen**: A는 design-desk 참조 패턴과 일치하고, sensitive trigger의 root cause(`.claude/` 디렉토리명)를 직접 회피. 자동 마이그레이션으로 사용자 영향 최소화.
- **Consequences**: 0.13.0 minor breaking. 모든 사용자 `.gitignore` + 디렉토리 갱신 필요(자동화). 문서 업데이트 광범위(rlp-desk.md 24 lines, governance.md 6 lines).
- **Follow-ups**:
  1. **1.0.0 deprecation cycle**: legacy `.claude/ralph-desk/` 감지 로직 제거 (사용자에게 1 minor 사이클 마이그레이션 시간 확보).
  2. **`~/.claude/ralph-desk/` 이동 검토**: 현재 sensitive trigger 미발생이지만 platform 변화 대비 1.x에서 검토.
  3. **Permission prompt 조기 감지**: `prompt-detector.mjs` 추가 후 다른 platform-shaped silent failure에도 재사용 (예: codex CLI의 미래 정책 변화).
  4. **Steelman 대응**: Architect 지적("`.rlp-desk/`도 미래 sensitive화 가능") — `RLP_DESK_RUNTIME_DIR` env 외부화로 기술적 대응 완료. 정책 모니터링은 운영 영역.
