# rlp-desk 5차 요청 — P1 버그: 제출-감지 함수에 pane ID 오전달 → 정상 실행 중인 verifier를 계통적으로 사살 — 2026-07-21

요청자: tire-plletdata PO 세션. **P1 (완주 차단 — 실캠페인에서 claude-verifier 다리 4회 연속 사살 실측, 재현 100%).** 소스-레벨 원인까지 특정 완료 — 수리는 한 줄 계열이다.

## 증상 (pa-foundation 캠페인, 13·21·22·23차 기동에서 동일)

- 워커가 US 작업을 완주하고 done-claim 제출 → 리더가 claude verifier 디스패치 → verifier는 **정상 실행 중**(pane 캡처: 스피너 "Osmosing… thinking with high effort", 파일 읽기, 도구 사용 🔧6, ctx 8%, 토큰 흐름)인데,
- 리더는 "no execution-start signal after 91s → 182s"로 **실행 중인 TUI에 Enter 재주입 2회**(부작용: 실행 방해), 273s에 `SUBMISSION failure` 판정 → `Consensus verification failed (verifier/infra error before verdict)` → 캠페인 BLOCKED.
- 결과: **작업이 완성돼도 검증을 영원히 통과할 수 없음** (4회 연속 실측).

## 원인 (소스 특정 — 설치본 v0.22.7+ 2026-07-20 배포분)

**인자 계약 불일치**: `run_ralph_desk.zsh`의 submit-anchored 폴링(≈:2942)이

```zsh
if (( _pfs_first_progress_ts == 0 )) && (( $+functions[_pane_shows_progress] )) && _pane_shows_progress "$pane_id"; then
```

으로 **pane ID**(`%2065`)를 전달하는데, `lib_ralph_desk.zsh`의

```zsh
_pane_shows_progress() {
  local snap="$1"            # ← 스냅샷 텍스트를 기대
  print -r -- "$snap" | grep -qiE "$_RLP_PROGRESS_RE" && return 0
  print -r -- "$snap" | grep -qE '[1-9][0-9]* in\b' && return 0
```

는 **스냅샷 텍스트**를 기대한다. 결과적으로 리터럴 문자열 `%2065`를 grep → **어떤 pane도 영원히 "진행 없음"** → first_progress_ts가 절대 설정되지 않음 → SUBMISSION_TIMEOUT×(재주입+1) 후 무조건 제출 실패.

- 참고: 같은 파일의 codex-verifier 경로(≈:3420 부근)와 워커 경로도 동일 함수를 쓰는 호출부가 있는지 전수 점검 권장 (우리 실측에서는 claude-verifier 다리에서 4회 확정 재현).
- 여담: `_RLP_PROGRESS_RE` 스피너 동사 목록에 신형 CLI 동사("Osmosing" 등)가 없지만, 이번 사살의 원인은 그것이 아니라 위 인자 버그다 (pane 텍스트에는 목록에 있는 "thinking"이 다수 존재했음). 다만 동사 하드코딩 접근 자체의 취약성도 함께 재고 권장 — 대안: trigger가 이미 쓰는 heartbeat 파일 갱신, 또는 `tee` 출력 파일 크기 증가를 진행 신호로 사용 (pane 텍스트 파싱 비의존).

## 수리 제안

- 호출부를 `_pane_shows_progress "$(tmux capture-pane -t "$pane_id" -p 2>/dev/null)"`로 (또는 함수가 id를 받으면 내부에서 capture하도록 시그니처 통일). **행위 테스트**: "실행 중 pane(스피너/토큰 표시 포함 스냅샷)에서 first_progress가 설정된다 / pane ID 문자열로는 설정되지 않는다(회귀 고정)".
- 재발 방지 제안: 이런 인자 계약은 zsh라 타입 체크가 없으니, 함수 첫 줄에 `[[ "$1" == %* ]] && { log_error "..."; }` 같은 가드 또는 호출부-함수 페어 테스트.

## 임시 우회 (tire 측 — 배포 전까지 사용 중)

`SUBMISSION_TIMEOUT=3600 SUBMISSION_MAX_REDISPATCH=0` env로 제출-실패 창을 검증 소요보다 크게 벌려 verdict 파일 도착이 먼저 오게 함 (제출-감지는 여전히 눈멀지만 사살은 방지). 단 이러면 ④의 "제출-후 기산" 보호가 무력화되므로(fp가 영원히 0 → ITER_TIMEOUT 미적용) 근본 수리가 필요하다.

## 요청 ② (★P1로 상향 — 아래 실증 확보) — 스토리-스코프 confirmation mode

- 현행 `derive_verification_mode`는 **PRD 전 US가 원장에 있어야만** confirmation — 다중 US 캠페인의 진행 중간(예: US-000만 완료)에는 구조적으로 build 고정이라, 이미 green인 스토리의 재검증에서 codex build 독트린과 충돌한다 (3차 요청서의 부트스트랩 갭과 동족, 이번엔 단일 런 내에서 관측).
- 제안 (캠페인 워커가 현장에서 제안한 설계 그대로 전달): **us_id 단위의 PRD-hash-bound·SHA-anchored verified 항목이 있으면 그 스토리에 한해 confirmation** — malformed 원장·PRD 드리프트·미해결 커밋·campaign-era dirt의 fail-closed 검사는 전부 유지.
- 효과: 다중 US 캠페인에서 완료 스토리의 재검증이 정직하게 가능해짐 (fake RED 유혹 원천 제거).
- **P1 상향 실증 (2026-07-21, iteration 12·13 verdict 원문 — 완벽한 테스트 케이스)**: US-000(8-US 캠페인의 1번째 스토리, 작업 전부 green: 26/26·74/74·508/943·receipt PASS 33/33)의 재검증에서 —
  - claude(opus:high) **pass**: "mode-derivation limitation, not a work defect… TDD substance is git-anchored (8 RED→GREEN ancestor commits) + all ACs pass on the verifier's own fresh evidence → warning"
  - codex(sol:xhigh) **fail**: "historical commits and archives cannot substitute for the required build-mode execution_steps sequence"
  - NO ENGINE PRIORITY → fail 반복 → CB(연속 8) → 캠페인 BLOCKED. **작업이 완벽해도 다중 US 캠페인의 1번 스토리를 codex 합의로 통과시킬 방법이 도구상 존재하지 않는다.** verdict 원문: tire-plletdata `.rlp-desk/logs/pa-foundation/iter-012~013.verify-verdict-{claude,codex}.json
- 참고: 이 벽은 US가 과대해 다중 iteration에 걸릴 때 특히 치명적(마지막 claim이 필연적으로 verify_existing) — 우리의 Task-Sizing 위반(US-000 과대)이 노출을 앞당겼지만, 정상 크기 US도 재검증 국면(재개·infra 재시도)에서 동일하게 걸린다 (①의 pane-id 버그로 검증 다리가 죽고 재시도한 것이 바로 그 국면이었다).

## 실증 데이터

- 리더 로그: tire-plletdata `/tmp/pa-foundation-leader-23.log` :447~:673 (pane 캡처 debug 라인들 — 실행 중 스냅샷과 "no execution-start signal" 판정이 같은 시간대에 공존)
- pane 캡처 원문: 위 로그의 `pane_output_for_retry` 블록들 (Osmosing/thinking/🔧6 상태에서 91s·182s Enter 재주입 기록)
- BLOCKED 센티널 4종: `.rlp-desk/memos/` 이력 + `.rlp-desk/logs/pa-foundation/`
