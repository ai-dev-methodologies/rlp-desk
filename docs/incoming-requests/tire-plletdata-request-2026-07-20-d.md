# rlp-desk 4차 요청 (개정 4판) — 계획 게이트의 명문화·우회 방지 + worktree 격리 + BLOCKED 원인 필드 — 2026-07-20

요청자: tire-plletdata PO 세션 (Claude Code). 실캠페인 pa-foundation(8 US, per-us, consensus all, worker gpt-5.6-terra:high, verifier claude-opus-4-8:high, final claude-fable-5:max, codex 교차 gpt-5.6-sol:xhigh)에서 하루 동안 **BLOCKED 6회·수동 재기동 9회**를 실측하고, 그 전체 인과를 복기해 도출한 요청이다.

이전 요청과의 관계: 1~2차(모델 사다리·엔진 판별·pregate 2층·consensus 병렬·재개-런 모드게이트·F-8 auto-commit·제출 보장)는 **모두 배포·설치본 검증 완료**, 이번 캠페인에서 실전 검증도 됐다(§5). 3차(부트스트랩 갭)는 non-blocking으로 별도 전달. 이 문서는 4차이며, **초판~2판에서 요청했던 "오너-질의 채널·제자리 재개"는 철회**됐다(경위는 §1).

---

## §1. 사건 전체 서사 (maintainer가 우리 세션 없이도 맥락을 갖도록 상세 기록)

### 배경
- 이 프로젝트는 rlp-desk로 "PA 수치 근거" 캠페인을 연속 수행 중. 오늘 두 캠페인(authz-alignment, pa-canonical-identity)을 **pa-foundation 하나로 통합**하기로 했다 (사용자 원칙: "큰 작업을 US로 분해해 연속 자동수행" — 캠페인 분절 금지).
- 원래의 pa-canonical-identity는 `/rlp-desk brainstorm` 정식 절차를 탔다. 그러나 **통합 재편(pa-foundation, 8 US)은 PO가 brainstorm 절차 밖에서 PRD를 직접 작성**했고, 실행 중 US-000(등록부 정합화)도 무게이트로 삽입했다.

### 인과 사슬 (핵심)
1. **절차 우회**: 통합 PRD가 brainstorm의 계획-깎기 게이트(IL-2 Ambiguity 점수표·Task Sizing §1c·의존 규칙)를 한 번도 통과하지 않음.
2. **그 결과 통과된 결함 2종**:
   - **Task Sizing 위반**: US-000이 실측 4개 거버넌스 층(의미 승인 12건 → 신규 표면 62건 등록 → provenance 지문 18건 rebaseline → E2E 수리) = 3+ iteration짜리 과대 US. 게이트를 돌렸다면 3~4개 US로 분할됐을 것.
   - **자율성 위반 AC**: "임의 승인 금지 — 오너 결정 필요 시 멈춰라"류 AC를 계약에 설계. 워커는 이 AC를 충실히 따라 **6회 BLOCKED**했다 (워커 판단은 전부 옳았다 — 허위 주장 0, 임의 승인 0).
3. **1차 오진**: PO가 이 정지들을 "도구에 오너-질의 채널이 없어서"라고 오진하고 이 요청서 초판에 "워커 오너-질의 채널·제자리 일시정지·재개"를 요청하려 했다.
4. **사용자 정정 2회**:
   - "US 순서는 정해진 대로 모두 진행" — PO가 막힌 US를 건너뛰는 재배열을 지시했다가 기각됨 (뒤 US는 앞 US가 성립한 환경에서 검증돼야 검증 연쇄가 유효).
   - **"오너 결정이 필요한 사항을 왜 만드는가? ralph loop를 수행하려고 만든 프레임이 rlp-desk다"** — human-in-the-loop 채널은 컨셉 역행. 정지가 반복되면 도구가 아니라 **계약을 고쳐야** 한다. 오늘의 오너-결정 6회는 전부 계획 시점에 위임 규칙(등록 관례·원장 갱신 규칙·합성 fixture 판정)으로 명시 가능했던 것들이었다.
5. **최종 정리**: 오너-질의 채널 요청 철회. PO 측 조치: ① PRD에 "위임 규칙" 절 소급 추가(실행 중 오너 인터랙션 0 보장, blocked 정당 사유는 비가역 파괴·계약 자체 변경·보호 경로 위반 3종뿐) ② 소급 Ambiguity Gate 실행(32 AC: PASS 29/WARN 3/REJECT 0 — 게이트가 돌면 작동함을 확인) ③ 운영 규약에 "PRD 재편·US 추가 시 게이트 재실행 필수, 점수표 제시, 약식 금지" 기록.
6. **남은 구멍 (이 요청서의 존재 이유)**: 위 재발 방지는 전부 **사용자/PO의 기억과 규율**에 의존한다. 도구 수준에서는 **brainstorm 명령 밖에서 PRD를 만들거나 고쳐도 init·run이 아무 저항 없이 실행**된다 — 게이트가 절차에 있지, 산출물에 바인딩돼 있지 않다.

### 사용자 원지시 (취지 verbatim)
- "애초에 rlp-desk 브레인스토밍을 할 때와 계획을 만들 때, PRD 자체를 만들 때 (실행 중) 사용자 인터랙션이 있게 만들면 안 된다. **이 규칙을 rlp-desk에 규칙으로 명시해 놔라.**"
- "이때 Iron Law 등을 반영해서 계획을 깎도록 했던 절차를 무시한 것일 수 있다 — 확인해라." (확인 결과: 실제로 무시됐음, §1-1)

---

## §2. 요청 ① 계획 게이트의 명문화 + 우회 방지 (최우선 — 사용자 확정 지시)

### ①-a. 무인-완주 계획 규칙을 brainstorm/init 스킬 규칙으로 명문화

brainstorm·init·PRD 작성 규칙에 다음을 명시해 달라:

> **캠페인 실행 중 사용자/오너 인터랙션은 0이어야 한다. 이를 보장하지 못하는 PRD는 완성이 아니다.**
> 1. 모든 결정은 계획 단계에서 소진한다 — 캠페인이 만날 결정 부류(신규 표면/산출물 등록 관례, 원장·레지스트리 갱신 규칙, fixture·합성데이터 처분, 알려진 baseline 처분 등)를 brainstorm에서 식별해 **"위임 규칙" 절**로 PRD에 명시한다 (PRD 스캐폴드의 필수 절로 포함 권장).
> 2. PRD·AC에 "오너/사용자 결정 필요 시 멈춘다"류 게이트 설계 금지. blocked 정당 사유는 ① 비가역 파괴 ② 계약 자체의 변경 필요 ③ 보호 경로 위반 필요 — 3가지뿐임을 워커 프롬프트에도 명시 (`--autonomous`의 "PRD is authoritative"와 짝).
> 3. brainstorm 완료 게이트(Ambiguity Gate 옆)에 **무인-완주 점검** 추가: "이 PRD로 루프가 사람 없이 완주 가능한가? 실행 중 인터랙션을 유발할 AC/제약이 있는가?" — 있으면 REJECT, 위임 규칙으로 변환 후 진행.

### ①-b. 게이트 우회 방지 — 게이트를 절차가 아니라 산출물에 바인딩

현상: 게이트(IL-2 점수표·Task Sizing·의존 규칙·무인-완주 점검)는 brainstorm **절차** 안에만 존재한다. PRD를 절차 밖에서 작성하거나(이번 통합 사례), 실행 중 US를 추가·재편해도(이번 US-000 사례) init/run은 아무 확인 없이 실행된다. 절차를 우회하면 게이트는 존재하지 않는 것과 같다.

요청 (구현 방식은 maintainer 재량 — 아래는 예시):
- brainstorm 게이트 통과 시 **gate-receipt**(PRD 콘텐츠 해시 + 점수표 요약 + 통과 시각)를 plans/에 기록.
- `init`·`run`이 현재 PRD 해시를 receipt와 대조 — 불일치(무게이트 작성·게이트 후 수정)면 **감지·표면화**하고 게이트 재실행을 안내 (하드 차단 vs 경고+override 플래그는 재량). 신규 US 추가·AC 변경은 반드시 불일치로 잡히게.
- 재편의 정식 경로 제공: 예) `/rlp-desk revise <slug>` — 수정된 PRD에 게이트(점수표 제시 포함)만 재실행하고 receipt 갱신.

수용 기준: 게이트를 거치지 않았거나 게이트 후 변경된 PRD로 run을 시작하면 반드시 감지·표면화된다. 정식 재편 경로가 존재한다. 기존 캠페인(receipt 없는 구 PRD)은 경고만(하위호환).

## §3. 요청 ② 캠페인 worktree 격리 옵션

- 공유 체크아웃에서는 동시 세션의 미커밋 작업이 전체-트리 게이트(typecheck·registry)를 오염시켜 루프가 자력으로 뚫을 수 없는 BLOCKED를 만든다 (오늘 1호 BLOCKED 실측: 캠페인 외부 파일 14개가 pregate fail 유발).
- `--worktree` 플래그: run 시 리더가 전용 worktree(HEAD 기준 캠페인 브랜치) 생성, ROOT 전환. 종료 후 보존(감독자가 PR 머지), `clean --remove-worktree`로 정리. 스캐폴드는 리더가 복사, `pnpm install --frozen-lockfile` 1회(부트 로그에 소요 표기).

수용 기준: 캠페인 실행 중 원본 체크아웃 편집이 캠페인 게이트에 영향 0. 기본값(미사용) 경로는 바이트 동일(회귀 0).

## §4. 요청 ③ BLOCKED 센티널 구조화 원인 필드 (P3)

- `cause: infra|contract_gap|defect` 필드 추가. `contract_gap`(계약이 위임을 빠뜨림 — 감독자가 PRD를 고쳐야 하는 신호)이 오늘 6회 중 3회였고 전부 수동 분류했다. ①이 배포되면 contract_gap은 계획 단계에서 예방되므로, 남는 infra/defect의 자동 라우팅용.

## §5. 참고 — 이번 캠페인에서 실전 검증된 기존 배포분 (감사 겸 보고)

- **pregate 2층**: 오염 트리를 LLM 라운드 소모 없이 iteration 1에서 기계 차단 — 설계 의도대로 작동.
- **F-8 auto-commit**: ignored-경로 산출물 다수(receipt·스크린샷) 상황에서 BLOCKED 재발 0.
- **제출 보장·타임아웃 재기산**: 미제출 idle·제출지연發 타임아웃 오인 0.
- **워커 품질**(terra:high, "+1단 시작" 규약): 전 iteration 허위 주장 0·임의 승인 0·프로파일 기반 진단 수행. 오늘의 모든 정지는 워커 판단이 옳았고, 결함은 계획(무게이트 PRD)에 있었다.

## §6. 실증 데이터 위치

- 캠페인 로그·BLOCKED 원문 6종·오너 계약 6건: tire-plletdata `.rlp-desk/logs/pa-foundation/`, `.rlp-desk/memos/pa-foundation-memory.md`
- 전체 복기: `.rlp-desk/logs/pa-foundation/po-mid-campaign-retro.md` (타임라인·독트린·PO 오판 기록)
- 소급 Ambiguity Gate 점수표: PASS 29 / WARN 3 / REJECT 0 (32 AC) — 게이트가 돌면 실제로 결함을 거른다는 증거

## 우선순위

**① (a+b, 계획 게이트) > ② (worktree) > ③ (cause 필드).** ①은 사용자 확정 지시("이 규칙을 rlp-desk에 규칙으로 명시해 놔라")다.
