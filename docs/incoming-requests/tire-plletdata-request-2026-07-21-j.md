# rlp-desk 9차 요청 — 명세-이탈·외부-오류 상태의 fail-fast/자동복구 하드닝 4건 — 2026-07-21

요청자: tire-plletdata PO 세션 (pa-foundation 캠페인, v0.22.16 운용 중, 현재 5/8 US 원장 등재·정상 항해).
공통 주제: **"조용히 이상 상태로 계속 가는 것"의 금지** — 오배치·빈값·스톨을 즉시 감지해 자동복구하거나 명시적으로 죽여달라. 오늘 하루에 네 계열이 전부 실사고로 관측됐다.

## ① (P1) codex "Selected model is at capacity" 스톨 — 무기한 대기, 자동 대응 없음

**증상**: US-005 워커(terra:high) 실행 중 codex TUI가 아래를 출력하고 **무기한 정지**. 진행 신호(Working 스피너) 소멸, 리더는 폴링만 계속 — 타임아웃(1800s)까지 무의미 대기 코스였고, 오너가 직접 목격해 수동으로 "계속 해."를 입력해 즉시 재개됐다.
```
⚠ Selected model is at capacity. Please try a different model.
```
- 오너 원지시: *"capacity 나오면서 모델매핑 문제 생기면 멈춰(스톨). 이것도 개선해야 해."*
- 실측: 리더 로그에 해당 캡처 349라인 누적(같은 스톨의 반복 캡처) = 폴러가 상태를 '보고'는 있었지만 '해석'하지 못함. 수동 개입 후 즉시 정상 재개 = 순수 일시 오류.
- **요청**:
  1. 알려진 **오류-배너 패턴 사전**(capacity / rate limit / transient error 계열)을 폴러에 추가 — 감지 + 진행신호 부재 시 **자동 재개 주입** (재개 문구는 설정 가능하게).
  2. 같은 스톨이 N회(제안: 3회) 반복되면 **모델 사다리 폴백**(기존 upgrade ladder의 lateral 버전) 또는 `[infra_failure] model capacity`로 **fail-fast BLOCKED** — 조용한 무기한 스톨만은 금지.
  3. v0.22.16의 `RLP_SUBMIT_BANNER_RE`(제출-차단 배너)와 별도 계열임에 유의 — 이건 제출 후 **실행 중 오류 스톨**이라 재주입 조건(에코 존재)이 다르다.
- **수용 기준**: capacity 배너 + 무진행 상태가 ≤60초 내 자동 재개되거나, 반복 시 명시적 BLOCKED. 정상 실행 중(스피너 존재) 오탐 주입 0.
- **우리 임시 조치**: 세션 워치독(45s 주기, 배너+무진행 → 재개 문구 주입, 120s 쿨다운) 운용 중 — 배포 시 제거. 경로: tire 세션 스크래치패드 `capacity-watchdog.sh`.

## ② (P2) 러너 pane 생성이 자기 세션에 고정되지 않음 — 타 세션 오염

**증상**: 리더가 tmux 밖(detached)에서 기동된 상태에서 워커/검증자 pane split이 **당시 활성이던 무관한 세션**(다른 프로젝트의 리뷰 인박스 세션)에 생성됐다. 오너가 직접 목격("왜 pane을 review-inbox-session으로 연결해").
- 후속 피해: PO가 pane을 수동 이동(join-pane)해 복구 시도 → 리더의 pane 장부가 깨져 `[infra_failure] tmux session/pane dead during iter_start`로 캠페인 사망 (32차).
- **요청**: 모든 `split-window`에 자기 세션/윈도우 명시 타깃(-t) 고정. 리더가 tmux 밖에서 기동된 경우(LEADER_PANE 부재) **활성 세션 유용 금지** — 자기 세션을 만들어 그 안에서만 배치하거나, 명시적 에러로 기동 거부.
- **수용 기준**: 리더 기동 위치와 무관하게 캠페인 pane이 캠페인 세션 밖에 생성되는 일 0.
- 참고: 우리는 이후 "리더를 캠페인 세션 내 전용 pane에서 기동"으로 운용 전환해 해소했다(33차부터 무사고). 그래도 도구가 막아주는 게 맞다.

## ③ (P2) in-campaign 워커 재기동 시 `model_reasoning_effort=""` 빈값 → 기동 실패 → BLOCKED

**증상**: US 전환 직후 워커 pane 재기동에서 러너가 생성한 codex 명령이 effort 빈값으로 조립됐다:
```
/opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="" ...
Error loading config.toml: reasoning_effort must not be empty
```
- codex 미기동 → 트리거 문장이 쉘로 노출(`/usr/bin/Read: ... not a valid identifier`) → "worker not active" 3연속 → BLOCKED (31차 iter-006, US-002 verified 직후 US-003 디스패치에서).
- 최초 기동은 정상(`gpt-5.6-terra:high` 파싱 OK), **재기동 경로에서만** effort가 소실된 것으로 보인다.
- **요청**: 재기동 경로의 model:effort 파싱 수리 + 명령 조립 후 **빈값 sanity check**(빈 effort면 조립 단계에서 fail).
- **증거**: `/tmp/pa-foundation-leader-31.log` 말미 pane_check 블록 (명령 원문·에러 원문 포함).

## ④ (P3) pane 쉘 rc 인터랙티브 프롬프트가 기동 명령 첫 글자를 삼킴

**증상**: oh-my-zsh 업데이트 프롬프트(`[Y/n]`)가 떠 있는 pane에 기동 명령을 paste하면 첫 글자가 프롬프트 응답으로 소비되어 `opt/homebrew/bin/codex...`(선두 `/` 소실)로 깨진다 → CLI 미기동.
- **요청**: pane 기동 paste 후 **에코 검증→Enter**(첫 줄이 기대 명령 prefix와 일치할 때만 제출) 또는 pane 쉘 기동 시 rc-프롬프트 무력화 env 주입.
- **증거**: `/tmp/pa-foundation-leader-29.log` :42~53. 우리 임시 조치: omz update epoch 캐시 갱신(로컬 한정·일시적).

## 로그·증거 경로 일습 (절대경로)

- ① capacity 스톨: `/tmp/pa-foundation-leader-33.log` (`at capacity` 349라인, 2026-07-21 16:5x 구간), 수동 해소 후 정상 재개는 동 로그 후속 iteration 진행으로 확인
- ② 오배치·사망: `/tmp/pa-foundation-leader-32.log` (`tmux session/pane dead during iter_start`), 32차 BLOCKED sidecar: tire `.rlp-desk/logs/pa-foundation/blocked-archive/`
- ③ effort 빈값: `/tmp/pa-foundation-leader-31.log` 말미 pane_check
- ④ 첫-글자 삼킴: `/tmp/pa-foundation-leader-29.log` :42~53
- analytics: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/analytics/pa-foundation--d467238d/campaign-v*.jsonl`
- 캠페인 로그/메모: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/logs/pa-foundation/`, `.rlp-desk/memos/`

## 우선순위 정리

①이 P1(현행 캠페인 라이브 리스크, 임시 워치독으로 봉합 중) / ②③ P2(운용 규율로 회피 중이나 도구가 막아야 재발 차단) / ④ P3(로컬 조치됨).
