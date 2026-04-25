# rlp-desk 0.11.1 — Tmux session/pane lifecycle resilience (ralplan v3)

> v3: Codex Critic ITERATE 흡수 (7 patches): 단일 5s 권위 timeout, mid-iter pane death 감지, SESSION_NAME `$$` + rand 충돌 회피, destroy-unattached 한계 명시, shasum 대체 체인, mkdir atomic lock, self-V mechanical fixture (grep-only 금지).
> v2: Architect 1차 ITERATE 흡수 — ground-truth 검증으로 bug premise 수정. 실제 session-config.json pane 필드는 정상 기록, 진짜 결함은 tmux session 자체 사라짐.

## Context

소비자 handoff `coordination/handoffs/2026-04-26-rlp-desk-tmux-pane-disappearance-bug.md` (P0) + ground-truth 검증.

### 보고된 증상 vs 실제 ground truth

| 항목 | 보고 | 실제 (검증 후) |
|---|---|---|
| session-config.json pane 필드 | 4 fields = null | leader=%1007, worker=%1016, verifier=%1017 (정상) |
| tmux pane lifecycle | %1014/%1015 사라짐 | session `ai-blog-system-624` 자체가 사라짐 → 모든 pane 함께 사망 |
| process state | 살아있음 | runner pid 83304 살아있음 (tmux session 만 dropped) |

**진짜 문제**: tmux session 의 lifetime 이 wrapper terminal / claude-code session 의 lifetime 과 묶여 있어서, 외부 close 시 session 이 사망 → 모든 pane id 가 stale 됨.

### 검증 evidence (현재 시각)

```
$ tmux ls | grep ai-blog
ai-blog-system-625  (ai-blog-system-624 부재)

$ cat .../blog-v31-flywheel-telemetry/runtime/session-config.json | jq .panes
{ "leader": "%1007", "worker": "%1016", "verifier": "%1017" }
```

→ pane id 는 작성 시점엔 valid 였으나 session 이 사라져 pane 도 dead.

## 근본 원인 (revised)

**session lifecycle ↔ wrapper lifecycle decoupling 부족**:

1. **H1 (확인)** — runner 가 `tmux new-session -d -s "$SESSION_NAME"` 으로 detached session 생성. 그러나 wrapper 가 nohup 으로 spawn 시 wrapper 자신의 terminal close 가 자식 tmux client 도 함께 끊고, attached client 가 0 이 되면 일부 환경에서 session GC 됨 (특히 tmux server 재시작 / 사용자 manual kill).
2. **H2 (확인)** — wrapper duplicate spawn race (96581 + 83265) 로 두 wrapper 가 동일 desk 의 다른 mission 진입. 한 쪽 cleanup 이 다른 쪽 session 영향.
3. **H3 (가능성 낮음, 폐기)** — pane id 캡처 시점 race. 실제 file 검증 결과 pane id 는 valid → 캡처 자체는 성공.

→ H1 + H2 가 주범. 보고된 H3 (캡처 race) 는 실제 ground truth 와 모순되어 폐기.

## RALPLAN-DR

**Principles**:
1. **Fail loud, not silent** — session/pane 사망 시 명시 alert (next iter 진입 직전 detect)
2. **Defense-in-depth** — H1 + H2 동시 차단 (단일 fix 부족)
3. **Backward-compat** — 기존 single-mission 인터랙티브 운영 그대로
4. **Self-verification mechanical** — 변경 코드 직접 invoke + grep anti-tautology

**Decision Drivers**:
1. session 이 외부 영향으로 사라져도 wrapper / 사용자 가 즉시 인지
2. duplicate wrapper spawn 시 second-mover 가 명시 reject
3. 작성된 session-config 가 "live" 와 "stale" 구분 가능

**Viable Options**:

- **A (채택)** — 3-pronged + Architect ITERATE 흡수:
  - **R12 — Pane lifecycle monitor** — 3 검증 시점: (a) `create_session()` 직후, (b) main loop 매 iter 진입 직전, (c) 매 worker/verifier `send-keys` 직후 wait-loop 진입 직전. 각 pane `#{pane_dead}` + session `has-session` 확인. dead 발견 시 즉시 BLOCKED with `reason_category=infra_failure` + recoverable=true + suggested_action=restart. **단일 권위 timeout: 5s 총 — 1초 간격 5회 polling 후 fail (Critic 불일치 해소)**.
  - **R13 — Detached session protection** — RLP_BACKGROUND=1 이면 `tmux set -t "$SESSION_NAME" destroy-unattached off` 적용해 attached client 0 일 때도 session 유지. `tmux new-session` exit code 명시 검증, fail 시 dedicated 새 이름 (`${SESSION_NAME}-bg-$(date +%s)`) 으로 retry 1회. **NEW-3: SESSION_NAME 이미 SLUG 포함하므로 중복 suffix 안 함**.
  - **R14 — Project-scoped runner lockfile** — `RUNNER_LOCKFILE_PATH="$DESK/logs/.rlp-desk-runner-$(echo "$ROOT" | shasum | cut -c1-8).lock"`. 동일 project root 에서 duplicate runner spawn 차단, 다른 project 의 동시 runner 는 허용. stale pid (`kill -0` fail) 시 갱신 + log 안내.
- B — R14 only (race 차단으로 충분) — H1 (session GC) 잔존 → 폐기.
- C — skip background mode — wrapper API breaking → 폐기.

**Pre-implementation gate (NEW-4)**: 본 plan 채택 전, 위 ground-truth 검증 (실제 session-config.json 파일 + `tmux ls` 출력) 완료. 실제 결함 = session 사망 + lockfile 부재 두 축으로 확정.

## 해결 계획

### Fix R12: Pane lifecycle monitor + bounded retry

**대상**: `src/scripts/lib_ralph_desk.zsh` 신규 helper + `src/scripts/run_ralph_desk.zsh` main loop 진입점

**변경**:
1. `lib_ralph_desk.zsh` 신규:
   ```zsh
   _verify_pane_alive() {
     local pane_id="$1"
     [[ -z "$pane_id" ]] && return 1
     local dead
     dead=$(tmux display-message -p -t "$pane_id" '#{pane_dead}' 2>/dev/null)
     [[ "$dead" == "0" ]]
   }
   _verify_session_alive() {
     local session="$1"
     [[ -z "$session" ]] && return 1
     tmux has-session -t "$session" 2>/dev/null
   }
   ```
2. `run_ralph_desk.zsh` 3 검증 시점에 helper 호출:
   ```zsh
   _r12_check_lifecycle() {
     local site="$1"  # "create" | "iter_start" | "post_send"
     local _attempts=0
     while ! _verify_session_alive "$SESSION_NAME" || \
            ! _verify_pane_alive "$LEADER_PANE" || \
            ! _verify_pane_alive "$WORKER_PANE" || \
            ! _verify_pane_alive "$VERIFIER_PANE"; do
       (( _attempts++ ))
       if (( _attempts >= 5 )); then
         log_error "[r12:$site] tmux session/pane dead after 5×1s polling (5s total budget). session=$SESSION_NAME panes leader=$LEADER_PANE worker=$WORKER_PANE verifier=$VERIFIER_PANE"
         tmux list-panes -a -F '#{session_name}:#{pane_id} dead=#{pane_dead}' 2>&1 | head -20 >> "$DEBUG_LOG"
         write_blocked_sentinel "tmux session/pane dead during $site" "${CURRENT_US:-ALL}" "infra_failure"
         exit 1
       fi
       sleep 1
     done
   }
   ```
   호출: `create_session` 끝, main loop 진입 직전, 모든 `paste_to_pane`/`send-keys` 직후 wait-loop 시작 전.
3. **단일 권위 timeout: 5s 총** (5회 × 1s polling), 다른 모든 "3 retries"/"4s" 표현 제거.

**검증 (us024)**:
- AC1: `_verify_pane_alive` + `_verify_session_alive` helper 정의
- AC2: create_session + main loop iter 진입 + post-send-keys 3 시점에서 caller 가 helper 호출
- AC3: behavioural — 죽은 pane id fixture → exit 1 with `infra_failure` sentinel
- AC4 (Critic): mid-iter pane kill fixture — worker pane 을 send-keys 직후 외부에서 kill → 다음 wait-loop 진입 시 R12 가 5s 안에 BLOCKED with `reason_category=infra_failure`

### Fix R13: Detached session protection + new-session exit-code verify

**대상**: `src/scripts/run_ralph_desk.zsh:744` `create_session()`

**변경**:
1. `tmux new-session -d -s "$SESSION_NAME"` 실행 후 즉시 `$?` 검증:
   ```zsh
   if ! tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$ROOT" 2>/dev/null; then
     if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
       if [[ "${RLP_BACKGROUND:-0}" == "1" ]]; then
         # daemon mode: 충돌 회피 (Critic NEW-3: epoch + pid + rand 4-digit 까지 강화)
         SESSION_NAME="${SESSION_NAME}-bg-$(date +%s)-$$"
         while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
           SESSION_NAME="${SESSION_NAME}-$(awk 'BEGIN{srand();print int(1000+rand()*9000)}')"
         done
         tmux new-session -d -s "$SESSION_NAME" -x 200 -y 50 -c "$ROOT" || die "tmux new-session retry failed: $SESSION_NAME"
       fi
     else
       die "tmux new-session failed and session does not exist: $SESSION_NAME"
     fi
   fi
   ```
2. RLP_BACKGROUND=1 이면 새/재생성된 session 마다 즉시 `tmux set-option -t "$SESSION_NAME" destroy-unattached off` 호출 — attached client 0 일 때도 session 유지.
   **한계 명시 (Critic R13)**: 이 옵션은 best-effort. **수동 `tmux kill-session` 또는 tmux server 재시작에는 보호 안 됨**. 둘 중 하나가 발생하면 session 은 사라지며, R12 (lifecycle monitor) 가 다음 검증 시점에서 BLOCKED 처리한다.

**검증 (us025)**:
- AC1: `tmux new-session` 실패 시 dedicated 이름으로 retry 1회 (RLP_BACKGROUND only)
- AC2: RLP_BACKGROUND=1 시 `destroy-unattached off` 호출 grep
- AC3: SESSION_NAME 변경 시 session-config 의 session_name 가 최종 이름 반영

### Fix R14: Project-scoped runner lockfile

**대상**: `src/scripts/run_ralph_desk.zsh:231` 부근 (LOCKFILE_PATH 정의)

**변경**:
1. 신규 변수 — shasum 대체 체인 (Critic R14 portability):
   ```zsh
   ROOT_HASH=$(printf '%s' "$ROOT" | { shasum 2>/dev/null || sha1sum 2>/dev/null || cksum; } | awk '{print substr($1,1,8)}')
   RUNNER_LOCKFILE_PATH="$DESK/logs/.rlp-desk-runner-$ROOT_HASH.lock"
   RUNNER_LOCKDIR="${RUNNER_LOCKFILE_PATH}.d"
   ```
2. 기존 `LOCKFILE_PATH` (per-SLUG) 그대로 유지 — concurrent same-slug 차단
3. **mkdir atomic lock 패턴 (Critic R14 race fix)** — check-then-write race 차단:
   ```zsh
   if ! mkdir "$RUNNER_LOCKDIR" 2>/dev/null; then
     existing=$(jq -r '.pid' "$RUNNER_LOCKFILE_PATH" 2>/dev/null || echo 0)
     existing_slug=$(jq -r '.slug // "unknown"' "$RUNNER_LOCKFILE_PATH" 2>/dev/null || echo unknown)
     if [[ "$existing" -gt 0 ]] && kill -0 "$existing" 2>/dev/null; then
       log_error "duplicate rlp-desk runner detected on this project root. existing pid=$existing slug=$existing_slug, this attempt slug=$SLUG. exiting."
       echo "  Recover with: rm -rf '$RUNNER_LOCKDIR' '$RUNNER_LOCKFILE_PATH' (after confirming pid $existing is not active)" >&2
       exit 1
     fi
     # stale: 다른 wrapper 가 이미 stale 청소 중일 수 있음 — atomic mkdir 재시도
     rm -rf "$RUNNER_LOCKDIR"
     mkdir "$RUNNER_LOCKDIR" 2>/dev/null || {
       log_error "failed to acquire runner lock after stale cleanup; another wrapper raced ahead. exit 1"
       exit 1
     }
     log "  stale runner lockfile cleaned (pid $existing dead) — acquired"
   fi
   printf '{"pid":%s,"slug":"%s","root":"%s","started_at":"%s"}\n' \
     "$$" "$SLUG" "$ROOT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$RUNNER_LOCKFILE_PATH"
   ```
4. cleanup trap 에서 own_slug 확인 후 `RUNNER_LOCKDIR` + `RUNNER_LOCKFILE_PATH` 둘 다 rm:
   ```zsh
   if [[ -f "$RUNNER_LOCKFILE_PATH" ]]; then
     own_slug=$(jq -r '.slug' "$RUNNER_LOCKFILE_PATH" 2>/dev/null)
     [[ "$own_slug" == "$SLUG" ]] && rm -rf "$RUNNER_LOCKDIR" "$RUNNER_LOCKFILE_PATH"
   fi
   ```

**검증 (us026)**:
- AC1: `RUNNER_LOCKFILE_PATH` 변수 정의 + project root hash
- AC2: 동일 root 에서 alive duplicate runner → exit 1 + 명시 메시지
- AC3: stale pid 시 lockfile 갱신 (no exit)
- AC4: 다른 root (다른 hash) 의 동시 runner 는 허용 (multi-project parallelism preserved)
- AC5: cleanup trap 이 own_slug 일치 시만 삭제

### Self-verification scenario (mechanical, real fixture)

`tests/test_self_verification_0_11_1.sh` — **grep-only 금지 (Critic Self-V)**. 각 함수가:
1. 임시 desk fixture (mktemp dir + plans/PRD + memos/)
2. 실제 helper 직접 invoke (zsh -c source) 또는 mini runner 진입
3. 구체 process exit code + 생성된 파일 / log line 검증
4. anti-tautology 보조 grep — primary 가 아닌 secondary

```bash
test_r12_pane_dead_blocks() {
  # 1) 가짜 dead pane id 로 _verify_pane_alive 호출
  # 2) tmux new-session 으로 alive session 만든 후 일부러 kill
  # 3) helper 가 false 반환하는지 + 호출자가 exit 1 + sentinel 작성하는지 확인
  zsh -c "source $LIB; _verify_pane_alive '%99999'" && fail "expected dead detection"
  # ... real fixture run + assert sentinel.md exists with reason_category=infra_failure
}
test_r13_session_disambiguation() {
  # 1) tmux new-session -d -s "test-session-fixture" alive
  # 2) RLP_BACKGROUND=1 + SESSION_NAME="test-session-fixture" 으로 create_session-like 진입
  # 3) 실제 새로 생긴 session 이름이 ${name}-bg-... 인지 + alive 인지 확인
}
test_r14_lockfile_duplicate_reject() {
  # 1) RUNNER_LOCKDIR mkdir
  # 2) ${LOCK}/pid file 에 alive pid 작성 (sleep & 으로 백그라운드)
  # 3) 두 번째 mkdir 시도 → exit 1 + stderr 에 "duplicate" 출력 검증
}
test_r14_lockfile_other_root_allowed() {
  # 1) ROOT=/tmp/r1 인 lockfile 존재
  # 2) ROOT=/tmp/r2 의 hash 가 다름 → 두 번째 mkdir 성공
}
```
각 함수 종료 시 (a) exit code 검증, (b) 생성된 sentinel/log 파일 존재 확인, (c) 패치된 함수가 호출되었음을 grep 으로 secondary 증명.

## 변경 대상 파일

```
src/scripts/run_ralph_desk.zsh   # R12 caller, R13 create_session 가드, R14 lockfile
src/scripts/lib_ralph_desk.zsh   # R12 _verify_pane_alive, _verify_session_alive
src/governance.md                # §7e (lane 옆) 신규 §7h "Tmux session lifecycle"
tests/test_us024_pane_lifecycle.sh
tests/test_us025_session_disambiguation.sh
tests/test_us026_runner_lockfile.sh
tests/test_self_verification_0_11_1.sh
```

## 검증

1. **LOW** — `zsh -n`, `node --check` (~10s)
2. **MEDIUM** — us024–026 신규 (~30s)
3. **CRITICAL** — us017–023 + us012–016 + us001/us007 무손실 (~3min)
4. **자가검증 매핑** — 4 함수 mechanical anti-tautology

## ADR

- **Decision**: R12 (pane/session monitor + bounded retry) + R13 (detached session protection + new-session verify) + R14 (project-root-hashed lockfile). Bug report 의 null-field 주장은 ground-truth 와 모순되어 폐기, 진짜 결함 (session lifecycle GC + duplicate wrapper) 에 집중.
- **Drivers**: visual feedback 회복, duplicate wrapper 안전, multi-project 병렬 보존.
- **Alternatives considered**: R14 only (H1 잔존), skip background (API breaking), `--isolated-session` flag (over-engineering).
- **Consequences**:
  - 기존 single-mission 인터랙티브 영향 없음 (R13 dedicated 이름 retry 는 RLP_BACKGROUND only)
  - duplicate wrapper 시 second-mover 명시 차단, 사용자 명령으로 lockfile 복구 가능
  - 매 검증 시점 최대 5s 추가 (단일 권위 budget: 5×1s polling). 최선 케이스는 0s (첫 시도 alive).
  - 다른 project 동시 runner 는 hash 분리로 그대로 동작
- **Follow-ups**:
  - tmux pane lifecycle dashboard
  - mission-level pane 격리 옵션 (`--isolated-session`)
  - bug-report contract: 다음번부터 consumer 가 evidence 파일 (실제 session-config.json + tmux ls 출력) 첨부
