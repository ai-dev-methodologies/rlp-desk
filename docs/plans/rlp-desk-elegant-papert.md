# rlp-desk 0.10.1 Multi-mission Autonomy + Sentinel JSON + Lane Enforcement (ralplan v6)

## Context

소비자 fix prompt(2026-04-25, "rlp-desk 0.10.1 Fix Request"):
- P0-A [BLOCKER] Multi-mission autonomy — 옵션 B `next_mission_candidate` 표준 권고
- P0-B [HIGH] tmux SV skip — **이미 main에 머지됨 (PR #4 RC-1)**
- P0-C [HIGH] PRD per-us cross-US lint — **이미 main에 머지됨 (PR #4 RC-2)**
- P1-D [MEDIUM] BLOCKED sentinel JSON taxonomy
- P1-E [MEDIUM] Lane separation runtime enforcement

현재 상황 (정확):
- main HEAD = `d288dce` (PR #4 squash 머지). main의 `lib_ralph_desk.zsh`는 markdown 첫 줄(`# Campaign Blocked`).
- feature branch `fix/rc1-tmux-sv-skip-and-rc2-prd-cross-us-lint`에 commit `a7f917a`가 있어 src/ working tree는 이미 `BLOCKED: <us_id>` 첫 줄로 통일된 상태(Risk D fix). 즉 src/와 main이 다름 — 본 plan은 a7f917a를 main으로 가져오는 단일 PR에 R2/R3/R4를 더해 통합.
- 본 작업은 a7f917a + P0-A + P1-D + P1-E를 새 PR로 main에 머지(사용자 명시: cherry-pick 안 함, solo project).

본 v6는 v4의 보수적 결정을 새 요구의 wrapper 친화성 우선으로 갱신 + Architect/Critic의 9개 ITERATE 패치를 모두 흡수한 결과다.

## 5개 P 항목 vs 현재 상황 매핑

| 항목 | 처리 |
|---|---|
| **P0-A** Multi-mission autonomy (옵션 B) | **채택, 본 PR R2** |
| **P0-B** tmux SV skip | **DONE — main `d288dce`** |
| **P0-C** PRD per-us lint | **DONE — main `d288dce`** |
| **P1-D** Sentinel JSON taxonomy | **채택, 본 PR R3** (JSON sidecar + 6 domain 카테고리) |
| **P1-E** Lane runtime enforcement | **절충 채택, 본 PR R4** (WARN-default + `--lane-strict` opt-in) |
| **Risk D** zsh sentinel 첫 줄 통일 | **본 PR R1** (a7f917a 통합) |

본 PR scope: R1 + R2 + R3 + R4. PR 분할 옵션은 §28 alternative 참조.

## RALPLAN-DR 요약

- **Principles**:
  1. **Wrapper-first contract**: sentinel JSON sidecar + 명시적 categories + recoverable + suggested_action.
  2. **Backward-compat first**: 기존 markdown sentinel 보존, JSON은 sidecar 신규.
  3. **Silent failure 0 (정정)**: BLOCKED은 4채널 표면화 (sentinel/status/console/report). lane WARN-mode도 silent 아님 — analytics 이벤트 + audit log + log_warn 3 채널 emit. "Silent"는 wrapper가 발견 못 하는 상태를 의미하지, "non-blocking"이 아님.
  4. **No silent stubs**: 모든 신규 옵션은 동작 명세 + 검증 시나리오 동반.
- **Decision Drivers**:
  1. Consumer wrapper 코드 단순화 (`scripts/launch_sustained_flywheel.sh` 400 lines → ~100 lines 가능).
  2. mission chain이 spec staging만으로 가능 (코드 수정 0).
  3. wrapper가 BLOCKED reason을 regex 우회 패턴 없이 분기.
- **Viable Options 비교 — Sentinel taxonomy 형식 (P1-D)**:
  - **A. JSON sidecar (`<slug>-blocked.json`) + markdown sentinel 보존(채택)** — wrapper-friendly(`jq .reason_category`). markdown은 첫 줄 `BLOCKED: <us_id>`(R1) + Reason 라인 보존. **Write order contract** (Architect/Critic ITERATE 흡수): JSON sidecar 먼저 atomic_write → markdown sentinel 나중에 atomic_write. 불변 invariant: **markdown 존재 ⇒ JSON 존재 보장**. wrapper는 markdown sentinel을 watch하고, 발견 시 JSON을 read; markdown이 보이는데 JSON이 없으면 fopen retry(최대 5회 × 50ms). atomic_write는 single-file rename atomicity만 제공하지만, write order + reader retry로 cross-file race 차단.
  - **B. Markdown extension만(v4 plan안, 탈락)** — wrapper가 grep 4종 패턴 알아야. wrapper-friendly 부족.
  - **C. JSON 단일(탈락)** — 기존 markdown 파서 깸. backward-compat 위배.
  - 결정: A. write order contract로 race condition 해결.
- **Viable Options 비교 — 카테고리 분류 (P1-D, Critic ITERATE 흡수)**:
  - **A. 6 domain (reason_category, primary) + 4 code (failure_category, secondary)(채택)**:
    - `reason_category` (primary, wrapper 분기 기준): `metric_failure / cross_us_dep / context_limit / infra_failure / repeat_axis / mission_abort`. 도메인 시그널, wrapper의 `jq .reason_category` 한 줄 분기.
    - `failure_category` (secondary, diagnostic only): `spec / implementation / integration / flaky | null`. verifier verdict의 codebase 결함 분류.
    - governance §1f에 명시: "wrapper MUST branch on `reason_category`. `failure_category` is diagnostic only — do NOT branch on it."
  - **B. 6 카테고리만(domain only, 탈락)** — verifier 정보 손실.
  - **C. 4 카테고리만(code only, 탈락)** — wrapper가 도메인 의미 부족.
  - **D. v4 5 카테고리 단일(탈락)** — abstract.
  - 결정: A. 두 필드 동시 expose + 우선순위 명시.
- **Viable Options 비교 — Lane enforcement (P1-E)**:
  - **A. WARN-default + `--lane-strict` opt-in BLOCKED 승격(채택, downgrade 적용)** — default WARN: analytics + audit log + log_warn (silent 아님). strict: lane 위반 → BLOCKED. **Strict downgrade(Critic ITERATE 흡수)**: strict의 lane 위반 BLOCKED은 **`recoverable=true` + `suggested_action=retry_after_fix`** (terminal_alert 아님). 부정확한 mtime audit이 캠페인을 종신 종료할 권한 비대칭을 완화.
  - **B. 항상 strict (탈락)**.
  - **C. 항상 WARN (탈락)**.
  - 결정: A.
- **Viable Options 비교 — PR 분할 (Architect/Critic ITERATE 흡수)**:
  - **A. 단일 PR — R1+R2+R3+R4(채택)** — 사용자 명시(solo project, cherry-pick 거부). 4 변경이 sentinel 형식으로 강결합.
  - **B. 2-PR 분할 — (R1+R2) / (R3+R4)** — codex review fatigue 분산. R1(sentinel 첫 줄)+R2(flywheel emit)는 작고 독립적, R3(JSON sidecar)+R4(lane)는 sentinel 강결합. review 비용 quadratic이라 분할이 더 효율 가능.
  - 결정: A 채택, 단 review iteration이 5+ 도달 시 B로 split fallback. ralplan max iteration(5) 초과 시 자동으로 split 결정 트리거.

## Self-Critique (Architect/Critic 9 patches 흡수)

v5에서 Architect 7 + Critic 9 violations 모두 흡수:
- §44/57: atomic_write 두 번 = atomicity 거짓 → write order contract + reader retry로 명시 race 해결.
- §134/144: 라인 카운트 부정확(5/14) → 정확값(4/11)로 정정. 카테고리 매핑 표 재작성.
- §38↔§53: silent-failure-0 ↔ WARN default 모순 → "Silent failure 0"의 의미를 "wrapper가 발견 못하는 상태 0"으로 명확화. WARN도 analytics + audit + log 3 채널 emit이라 silent 아님.
- §51: 6+4 카테고리 우선순위 누락 → primary/secondary 명시.
- §150-152: cross-US 키워드 휴리스틱 미정의 → 정확 토큰 리스트 명시.
- §174: strict의 BLOCKED 권한 비대칭 → recoverable=true + retry_after_fix downgrade.
- §218: 신규 docs sync 검증 누락 → 명시 추가.
- §157-162: race-condition fixture 누락 → us015에 추가.
- §28: 2-PR 분할 alternative 누락 → 명시 + review iteration 5+ 시 fallback.

---

## 해결 계획

### Fix R1: Risk D — zsh sentinel 첫 줄 `BLOCKED: <us_id>` 통일

**현재 main 상태**: `lib_ralph_desk.zsh:709` write_blocked_sentinel이 `# Campaign Blocked` markdown 헤더 첫 줄 작성. Node 측은 `BLOCKED: <us_id>` 첫 줄. main이 두 형식 혼재.
**현재 feature branch 상태**: a7f917a이 src/ working tree에 적용 — 첫 줄 통일됨. 본 PR로 main에 가져옴.

**대상**: 이미 commit a7f917a에 적용 완료. 본 PR에서 그대로 통합.
- `src/scripts/lib_ralph_desk.zsh` write_blocked_sentinel 첫 줄 `BLOCKED: <us_id>` (us_id = optional 2번째 인자, fallback `${CURRENT_US:-ALL}`).
- write_complete_sentinel 동일 패턴.
- AC19 4건 회귀 (us013) 이미 a7f917a에 포함.

### Fix R2: P0-A Multi-mission autonomy — `next_mission_candidate` emit

**대상**:
1. `src/scripts/init_ralph_desk.zsh` flywheel prompt heredoc (~ line 634+) — JSON 형식 명세에 `next_mission_candidate` 옵션 필드 명시:
   ```
   Optionally include `next_mission_candidate` field in the JSON output:
   - null when no next mission is suggested
   - "<slug>" when flywheel recommends a specific next mission for the wrapper
   ```
2. `src/node/runner/campaign-main-loop.mjs` line 582 인근(flywheelSignal 파싱) — `state.next_mission_candidate = flywheelSignal.next_mission_candidate ?? null`. 모든 status.json write에 직렬화.
3. `src/governance.md` §7 (flywheel-signal.json 형식 표) — `next_mission_candidate` (string | null, optional) 추가.
4. `docs/multi-mission-orchestration.md` — emit 측 spec 1단락 추가.

**검증**: `tests/test_us014_next_mission_candidate.sh` 신규 (4 AC).

### Fix R3: P1-D BLOCKED sentinel JSON taxonomy + Write order contract

**채택**: JSON sidecar 신규 + markdown sentinel 보존. write order: JSON 먼저 → markdown 나중.

**JSON sidecar schema** (governance §1f Failure Taxonomy 추가):
```json
{
  "schema_version": "2.0",
  "slug": "<slug>",
  "us_id": "<us_id or ALL>",
  "blocked_at_iter": <int>,
  "blocked_at_utc": "<iso8601>",
  "reason_category": "metric_failure | cross_us_dep | context_limit | infra_failure | repeat_axis | mission_abort",
  "reason_detail": "<full reason text>",
  "failure_category": "spec | implementation | integration | flaky | null",
  "recoverable": true | false,
  "suggested_action": "next_mission_chain | restart | retry_after_fix | terminal_alert"
}
```

**Wrapper contract 명시 (governance §1f)**:
- `reason_category` is **primary** — wrapper MUST branch on this field.
- `failure_category` is **secondary, diagnostic only** — do NOT branch on it; logging/triage only.
- Read order: wrapper watches markdown sentinel. When markdown appears, read JSON sidecar. If JSON not yet visible (race), fopen retry up to 5 × 50ms before failing. **Invariant: markdown 존재 ⇒ JSON 존재 (writer가 JSON 먼저 atomic_write 보장)**.

**카테고리 매핑 (BLOCKED 진입 분기 → reason_category)**:
- **Node side (`campaign-main-loop.mjs`, 4곳, Architect 정정값)**:
  - L610 flywheel inconclusive → `mission_abort` (recoverable=false, action=`terminal_alert`)
  - L638 flywheel retries-exhausted → `mission_abort` (recoverable=false, action=`terminal_alert`)
  - L754 verifier-blocked → cross-US 토큰 검사 → `cross_us_dep` 또는 `metric_failure` (recoverable=true, action=`retry_after_fix`)
  - L797 model-upgrade-exhausted → `repeat_axis` (recoverable=false, action=`next_mission_chain`)
- **zsh side (`run_ralph_desk.zsh`, 11곳, Architect 정정값)**:
  - L1611 API unavailable → `infra_failure` (recoverable=true, action=`restart`)
  - L2307/2314 worker spawn fail → `infra_failure` (recoverable=true, action=`restart`)
  - L2357/2365 monitor fail → `infra_failure` (recoverable=true, action=`restart`)
  - L2452 consensus exhausted → `repeat_axis` (recoverable=false, action=`next_mission_chain`)
  - L2511 verifier dead → `infra_failure` (recoverable=true, action=`restart`)
  - L2645/2649 cb_threshold reached → `repeat_axis` (recoverable=false, action=`next_mission_chain`)
  - L2667 verdict blocked → cross-US 토큰 검사 → `cross_us_dep` 또는 `metric_failure`
  - L2679 worker signal blocked → 본문 토큰 검사 → `cross_us_dep` 또는 `metric_failure`
  - L2702 context stale → `context_limit` (recoverable=false, action=`next_mission_chain`)

**Cross-US 토큰 리스트 (정확 명시, Critic ITERATE 흡수)** — 다음 토큰 중 하나라도 매치하면 `cross_us_dep`, 아니면 `metric_failure`:
- `depends on US-`
- `blocking US-`
- `awaits US-`
- `post-iter US-`
- `requires US-` + 다른 US 번호 참조
- `cross-US`
- 한국어: `US-X 산출물`, `신규 US-X`, `post-iter`

**대상 파일**:
1. `src/node/runner/campaign-main-loop.mjs` — 신규 helper `_classifyBlock(verdict|null, source, state)` + `_writeBlockedJson(paths, classification)`. 4 BLOCKED 분기에서 호출. Write order: JSON 먼저 → markdown 나중.
2. `src/scripts/lib_ralph_desk.zsh:709` (write_blocked_sentinel) — 신규 4번째 인자 `category` (default `metric_failure`). 함수 내부에서 JSON sidecar 작성(markdown 작성 직전, atomic_write 두 번을 정확한 순서로). 
3. `src/scripts/run_ralph_desk.zsh` — 11곳 호출처 각각 적절한 category 인자 추가 (위 매핑).
4. `src/governance.md` §1f — Failure Taxonomy(6 + 4) + JSON schema + Wrapper contract + Read order/Invariant 명시.
5. `docs/protocol-reference.md` — “Blocked Sentinel JSON Schema + Write Order Contract” 섹션.

**검증**: `tests/test_us015_sentinel_json_taxonomy.sh` 신규 (포함):
- 6 reason_category fixture × 11+4 호출처에서 emit 가능. 단 정확 11+4 호출처 모두 매핑된 category가 정의되어 있는지 grep 정합 검사.
- JSON sidecar schema 모든 필수 필드.
- markdown sentinel(legacy) 보존 — backward-compat.
- wrapper용 `jq .reason_category` 한 줄 분기.
- recoverable/suggested_action 매핑 정합.
- **Race-condition fixture (Critic ITERATE 흡수)**: 별도 zsh 서브셸에서 atomic_write을 순서대로 호출하고, intermediate state에서 markdown만 보이는 순간이 없는지 검증 (markdown은 JSON 작성 후에만 작성됨). reader retry는 5×50ms로 fixture에서 직접 시뮬레이션.
- Cross-US 토큰 리스트 7종 모두 매치 → `cross_us_dep` 분류.

### Fix R4: P1-E Lane runtime enforcement (절충, downgrade 적용)

**채택**: WARN-default + `--lane-strict` opt-in BLOCKED 승격. strict의 BLOCKED은 `recoverable=true` + `retry_after_fix`로 downgrade.

**대상**:
1. `src/scripts/run_ralph_desk.zsh` — `--lane-strict` CLI 플래그. session-config + metadata.json에 `lane_mode: "warn"|"strict"` 직렬화.
2. `src/node/run.mjs` — `--lane-strict` 플래그 stub.
3. `src/node/runner/campaign-main-loop.mjs` post-iteration — PRD/test-spec/memory mtime 비교(start mtime 스냅샷 + end mtime). 변동 시:
   - default warn: analytics `event_type='lane_violation_warning'` + log_warn + audit log entry.
   - strict: 위 + sentinel BLOCKED with **`reason_category='infra_failure'` + `recoverable=true` + `suggested_action='retry_after_fix'`** (Critic downgrade).
4. `~/.claude/ralph-desk/logs/<slug>/lane-audit.json` audit log — 위반 1건당 entry. 빈 캠페인도 빈 array `[]`로 초기화.
5. `src/governance.md` §7¾ — “Lane Enforcement” 섹션:
   - WARN(default): informational, 자율 운영 무중단, audit log + analytics.
   - STRICT(opt-in): BLOCKED with recoverable=true + retry_after_fix. 부정확 audit가 종신 종료를 결정 안 함.
6. `src/scripts/init_ralph_desk.zsh` Worker prompt에 lane 명시 (governance §7¾ 참조).

**비-목표**: chmod 강제 ACL, git_blame last_modifier (mtime + heuristic만).

**검증**: `tests/test_us016_lane_enforcement.sh` 신규
- `--lane-strict` 플래그 파싱.
- session-config / metadata.json `lane_mode` 직렬화.
- mtime fixture:
  - default WARN: lane_violation_warning analytics + audit, BLOCKED 안 됨.
  - strict: BLOCKED + JSON sidecar `recoverable=true` + `retry_after_fix`. terminal_alert 아닌 retry_after_fix 검증.
- audit log 파일 빈 캠페인도 생성.
- governance §7¾ 텍스트 정합.

---

## 변경 대상 파일 표

```
[runtime sync 대상]
src/scripts/init_ralph_desk.zsh        # R2(flywheel prompt), R4(worker lane)
src/scripts/run_ralph_desk.zsh         # R3(11 호출처 카테고리), R4(--lane-strict + lane_mode)
src/scripts/lib_ralph_desk.zsh         # R1(이미 a7f917a), R3(JSON sidecar + write order)
src/commands/rlp-desk.md               # R4(--lane-strict 명시)
src/governance.md                      # R3(§1f Failure Taxonomy + 6+4 + Wrapper contract + Read order), R4(§7¾ WARN+STRICT downgrade), R2(§7 flywheel signal)
src/node/runner/campaign-main-loop.mjs # R1(Risk D 통합), R2(next_mission_candidate), R3(_classifyBlock + _writeBlockedJson + write order), R4(mtime audit + strict 분기)
src/node/run.mjs                       # R4(--lane-strict stub)

[문서 — 자동 sync (docs/blueprints/* wildcard 또는 명시 항목)]
docs/protocol-reference.md             # R3(Blocked Sentinel JSON Schema + Write Order), R2(next_mission_candidate)
docs/multi-mission-orchestration.md    # R2 emit 측 spec

[테스트]
tests/test_us013_prd_cross_us_lint.sh  # R1 AC19 (이미 a7f917a)
tests/test_us014_next_mission_candidate.sh # R2 신규
tests/test_us015_sentinel_json_taxonomy.sh # R3 신규 (race-condition fixture 포함)
tests/test_us016_lane_enforcement.sh   # R4 신규

[배포 / sync 검증 (Critic ITERATE 흡수)]
install.sh                             # 신규 zsh 없음, 변경 0
package.json#files                     # src/scripts/ 미포함 side issue (별도 PR)
CLAUDE.md (Local File Sync 표)         # 변경 0 (기존 6 runtime + 2 docs 표 그대로 사용; 신규 docs/protocol-reference.md/multi-mission-orchestration.md는 이미 표에 있음)
```

## 검증 (Self-Verification Gate + 종단 회귀 + 신규 검증 항목)

CLAUDE.md "Self-Verification Gate (ABSOLUTE)" 3 시나리오 + 4 신규 회귀 + Critic-요구 추가 검증:

1. **LOW** — `zsh -n` 모든 수정 zsh + `node --check` 모든 mjs. (~10s)
2. **MEDIUM** — 신규 회귀:
   - **us014 (R2 P0-A)**: prompt 명시, leader 직렬화, null fallback, governance §7 형식 표. (~20s)
   - **us015 (R3 P1-D)**:
     - 6 reason_category fixture 매핑 정확.
     - 11+4 호출처 정합 (grep 검증, Architect/Critic 라인 카운트 정정 반영).
     - JSON sidecar schema 필수 필드.
     - markdown sentinel 보존.
     - **Race-condition fixture**: write order(JSON 먼저, markdown 나중) 검증, reader retry 5×50ms.
     - Cross-US 토큰 7종 매치 → `cross_us_dep`. (~60s)
   - **us016 (R4 P1-E)**: lane_mode 직렬화, default WARN(BLOCKED 안 됨), strict(recoverable=true + retry_after_fix), audit log 생성, governance §7¾. (~40s)
3. **CRITICAL** — 회귀 무손실: us001/us007/us008(known 1 fail)/us012/us013 모두 통과. (~90s)

**추가 검증 (Critic ITERATE 흡수)**:
- 신규 docs sync 검증: `docs/protocol-reference.md` + `docs/multi-mission-orchestration.md`이 `~/.claude/ralph-desk/docs/`에 sync된 후 `diff -q` clean. CLAUDE.md “Local File Sync (ABSOLUTE)” 표에 두 파일 포함 여부 직접 확인 (현재 표에 둘 다 있음).
- `gh pr` 전 `codex review` 0 issues — 단일 PR이라 review iteration이 5+ 도달 시 2-PR split fallback 트리거.

## ralplan v6 컨센서스 상태

본 plan은 v6. ralplan v5→v6 iteration: Architect 7 violations + Critic 9 file:line patches 흡수 완료.

## ADR (간결)

- **Decision**: 5 P 항목 중 P0-B/P0-C는 main에 이미 있음(DONE). 나머지 P0-A + P1-D + P1-E + Risk D를 단일 PR로 통합. JSON sidecar(P1-D) + write order contract(JSON 먼저 → markdown) + 6 domain + 4 code 두 카테고리 with primary/secondary 우선순위. WARN-default + strict opt-in with recoverable=true downgrade(P1-E). flywheel emit(P0-A) + zsh sentinel 통일(R1).
- **Drivers**: wrapper 코드 단순화, mission chain 코드 수정 0, regex 우회 패턴 제거, atomicity race 차단.
- **Alternatives considered**: markdown extension만(v4안 탈락), 5 카테고리 단일(탈락), JSON 단일(탈락), 항상 strict(탈락), 항상 WARN(탈락), terminal_alert(downgrade 적용으로 탈락), 2-PR split(review iteration 5+ 시 fallback alternative).
- **Why chosen**: A 옵션들이 모두 backward-compat + wrapper-friendly + race 차단 + downgrade로 권한 비대칭 완화.
- **Consequences**:
  - consumer wrapper가 `jq .reason_category` 한 줄 분기 → 단순화.
  - mission chain이 spec staging만으로 가능.
  - Lane strict mode가 강한 환경에서 retry_after_fix로 안전 종료 — 부정확 audit가 캠페인 종신 종료 안 함.
  - JSON sidecar + markdown sentinel 두 파일 race는 write order + reader retry로 차단.
  - 단일 PR이지만 review iteration 5+ 시 split fallback.
- **Follow-ups**: `package.json#files`에 `src/scripts/` 명시(별도 PR), helper `rlp-desk auto-chain`(옵션 A, wrapper 책임 분리), git_blame 정확 actor 식별.
