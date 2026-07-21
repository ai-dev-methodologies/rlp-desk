# tire 검증 보고 — v0.22.16 (7차 회신) + 요청받은 pane 캡처 2회분 — 2026-07-21

## 설치본 검증: clean

- 구현 존재 확인: `known submit-blocking banner detected — early Enter re-inject (request-g)` 로그 라인이 **양 루프 모두**에 존재 (run:2965 범용 + run:3441 codex 전용), `RLP_SUBMIT_BANNER_RE` env 노브 확인 (lib:3405).
- 정규식 기능 검증 (실측 원문 그대로):
  - `You have 1 usage limit reset available. Run /usage to use one.` → **MATCH** ✓
  - `increased plan usage.` → **MATCH** ✓
  - `hit your usage limit… resets at …` (진짜 소진) → **no-match** ✓ (안전 분리)

## 라이브 관측 계획 (정직 고지)

- 현재 도는 캠페인 리더는 v0.22.16 **이전에 기동**된 프로세스라 신코드가 비활성 — 이 런이 끝나는 시점까지는 우리 20초 워치독을 유지하고, **다음 재기동부터 워치독을 제거**한 뒤 배너 재현 시 `request-g` 로그 라인 + ≤15초 해소를 관측해 보고하겠다. clean이면 그 시점에 이 건 종결 동의.

## 요청받은 pane 캡처 (①번 정황 조사용 — 재사용 pane 잔여 텍스트 오탈출 가설)

**캡처 1 — 1회차 (사용자 직접 목격, 수동 Enter 전. pane %2092, codex verifier, iter-002 디스패치 직후):**
```
  increased plan usage.
• You have 1 usage limit reset available. Run /usage to use one.
› Read and execute the instructions in /Users/plletdata/
  Documents/AI/kyjin/tire-plletdata/.rlp-desk/logs/pa-
  foundation/iter-002.verifier-codex-prompt.md
  gpt-5.6-sol xhigh · feat/tire-dashboard-current-state · Contex…
```
- 특징: 진행 신호 0 (Working/esc/스피너 없음), 트리거 에코 존재, 배너 2종 동시. Enter 주입 → **6초 만에** `Explored / Read iter-002.verifier-codex-prompt.md / Working` 전환.
- **① 가설 관련 정황**: 이 pane은 직전 라운드의 codex 세션 종료 잔여(`Token usage: total=… codex resume …` 텍스트)가 히스토리에 남은 **재사용 pane**이었다 — "재사용 pane 잔여 텍스트에 blind-루프 verb 정규식이 조기탈출" 가설과 부합하는 정황.

**캡처 2 — 2회차 (워치독 자동 감지 11:04:22, 동일 pane %2092):**
```
(히스토리 상단) • You have 1 usage limit reset available. Run /usage to use one.
(입력창) › Read and execute the instructions in … (트리거 에코, 진행 신호 0)
```
- 워치독 Enter 주입 → **9초 만에** Working 전환. 3회차(12:14:37)도 동일 패턴·8초 해소 — 총 3회 전부 같은 배너·같은 pane 재사용 조건.

## 소결

- 세 번 모두 "codex 세션 잔여 텍스트가 있는 재사용 pane + reset-available 배너" 조합 — ① 가설(blind-루프 조기탈출)과 정합적이다. v0.22.16의 3조건 AND(에코+무진행+배너)는 이 조합을 정확히 겨냥하므로 해소될 것으로 기대한다. 라이브 관측 결과는 다음 보고에서.
