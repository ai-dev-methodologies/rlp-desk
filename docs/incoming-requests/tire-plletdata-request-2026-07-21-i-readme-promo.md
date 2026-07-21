# rlp-desk 홍보 제안 — "결정론 pre-gate 깔때기"를 README.md 전면 특장점으로 (docs/promo) — 2026-07-21

요청자: tire-plletdata PO 세션 (오너 직접 지시: *"이걸 rlp-desk에서 전면적인 홍보로 내밀도록 하라. 사례와 함께. GitHub README.md에 넣게 하자."*)

## 제안 요지

rlp-desk의 검증 스택이 실전에서 증명한 **"기계가 잡을 건 기계가, LLM은 실질 판정만"** 깔때기 구조를 README의 전면 특장점(hero feature)으로 올리자. 다른 Ralph-loop/자율 에이전트 프레임과의 차별점이 바로 이 지점이다 — 대부분의 프레임은 "LLM이 LLM을 검증"하는 구조라 검증 비용이 라운드마다 반복되는데, rlp-desk는 결정론 층이 앞단에서 소음을 걸러 **LLM 검증 라운드가 실질 결함에만 소비**된다.

## 깔때기 구조 (README 다이어그램 제안)

```
Worker done-claim
   │
   ▼
① 기계 pre-gate ─ 초 단위 · 토큰 0
   ├─ L1: 캠페인 스크립트 (typecheck·registry·lockfile·형식 lint)
   └─ L2: done-claim 명령 replay (claimed vs actual 대조)
   │  결함 시: LLM 디스패치 없이 즉시 워커 반려 (출력 tail = fix contract)
   ▼
② per-US 검증 (claude) ─ 실질 결함 판정
   ▼
③ cross-engine 교차 (codex) ─ 타 엔진 관점 반증
   ▼
④ final 검증 (top-tier + cross) ─ 캠페인당 1회 최후 방어
```

## 실전 사례 3건 (실측 — README 사례로 사용 가능, 프로젝트명은 "a production analytics project"로 익명화 권장)

### 사례 1 — L2 replay가 허위 RED 주장을 초 단위 검출 (2026-07-21, v0.22.16)

워커가 "AC 전부 green + TDD RED 재현 완료" done-claim 제출 → **L2 replay가 `verify_red claimed=1 actual=0` 불일치 검출** → LLM 검증(opus ~19분 + codex 라운드)을 아예 디스패치하지 않고 즉시 재디스패치. 워커는 다음 iteration에서 증거를 보정했다.
- 절감: 라운드당 20~25분의 LLM 검증이 **수 초의 결정론 replay로 대체**
- 로그: `/tmp/pa-foundation-leader-33.log` (`Pre-gate L2 FAILED (replay mismatch: verify_red claimed=1 actual=0) — skipping LLM verification, redispatching Worker`)

### 사례 2 — 형식 결함이 LLM 라운드를 태우던 것을 L1 lint로 봉합

cross-engine 검증(consensus all)에서 codex 다리가 done-claim의 AC별 TDD 순서 라벨 누락만으로 2라운드 연속 fail — **산출물 AC 4개는 전부 실검증 통과 상태**에서 누적 ~65분 소모. 캠페인 L1 스크립트에 jq 결정론 lint(AC별 write_test→verify_red→implement→verify_green 순서 검사)를 추가해 봉합 → 이후 같은 계열 재발 0. (이 lint의 도구 내장은 8차 요청서 `tire-plletdata-request-2026-07-21-h.md` 참조 — README 반영 시 내장 기능으로 소개하면 더 강력)
- 로그: tire-plletdata `.rlp-desk/logs/pa-foundation/iter-002.verify-verdict-codex.json`, `iter-004.verify-verdict-codex.json`

### 사례 3 — 깔때기 정비 전후의 극적 대비 (숫자가 곧 카피)

- 정비 전: per-US codex 교차 판정 **pass 0 / fail 15** — 대부분 독트린 라우팅·형식 소음. 라운드당 20~25분(실측 1,211~1,543s)
- 정비 후(원장 시드 + story-scoped + pre-gate lint): **바로 다음 US에서 캠페인 첫 양 엔진 동시 pass** — codex 다리가 소음 0으로 실질 판정만 수행
- 교훈이자 카피: *"교차 검증이 낭비였던 게 아니라, 기계가 할 일을 LLM에게 시킨 구조가 낭비였다"*
- 데이터: tire-plletdata `.rlp-desk/analytics/pa-foundation--d467238d/campaign-v*.jsonl`

## README 구성 제안 (패턴 제시 — 확정 명세 아님, maintainer 재량)

1. hero 문단: "Deterministic pre-gates catch what machines can catch — your LLM verification rounds are spent on real defects only."
2. 위 깔때기 다이어그램
3. 사례 1·3을 2~3줄 실측 인용 (사례 2는 8차 반영 후 내장 기능으로 소개)
4. 부가 특장점과 연결: Evidence Gate·verified.jsonl 원장·anti-gaming(허위 주장 시 replay가 잡음)까지 "증명 가능성" 서사로 묶기
5. 래칫 서사: 실패 계열이 발생할 때마다 결정론 층으로 내려가 재발 비용이 0이 되는 구조 (ledger-seed, story-scoped, request-g, pre-gate가 전부 이 패턴)

## 가드레일

- 사례에서 우리 프로젝트 식별 정보(도메인·지표 체계·비즈니스 맥락)는 제거하고 "a production analytics project" 수준으로 익명화 권장
- 수치(라운드 시간·pass/fail 카운트)는 그대로 써도 무방 — 우리 쪽 이의 없음

## 로그·증거 경로 일습 (절대경로, maintainer 검증용)

- 리더 로그(사례 1): `/tmp/pa-foundation-leader-33.log`
- codex 형식-fail verdict(사례 2): `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/logs/pa-foundation/iter-002.verify-verdict-codex.json`, `iter-004.verify-verdict-codex.json`
- analytics 원장(사례 3): `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/analytics/pa-foundation--d467238d/campaign-v*.jsonl`
- L1 lint 참조 구현: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/plans/pregate-pa-foundation.sh` (4번 검사)
- 8차 요청서(내장화): `docs/incoming-requests/tire-plletdata-request-2026-07-21-h.md`
