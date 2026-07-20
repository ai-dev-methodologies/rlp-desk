# rlp-desk 수정 요청 (미해결분만) — 2026-07-20 2차

요청자: tire-plletdata PO 세션. **이전 요청(사다리·엔진판별·pre-gate·병렬화)은 v0.22.5/6/7로 모두 배포 완료 — 이 문서에는 그것들을 담지 않는다.** 아래 3건은 실캠페인(pa-live-audit-unblock)에서 재발 확인된 미해결 항목이다.

전제: 현재 설치본 v0.22.7. `~/.claude/ralph-desk/` 직접 수정 금지 — 소스 레포에서 고쳐 로컬 배포.

---

## 요청 ① codex verifier의 재개-런(resumed campaign) mode-awareness ★최우선 (완주 차단 확정)

### 증상 (완주 불가 3중 확증)
캠페인이 중단→재개되면 이미 검증된 US의 test-first(RED/GREEN) 기록은 **이전 런의 아카이브**(`.rlp-desk/logs/<slug>/iter-NNN-done-claim.json`)에 있고 현재 done-claim에는 없다. 이때 codex 교차/최종 verifier가 매번 fail:
> "current done claim records plan → implement → verify_existing and omits the mandatory write_test → verify_red → verify_green sequence. The successful archive assertion cannot substitute for the strict build-mode done-claim contract."

**실측 (pa-live-audit-unblock, 27 iteration 시도, 3+ BLOCKED로 확정)**: verdict 매트릭스 = claude 4/4 pass, codex 4/4 fail(전부 US-001 재검증 또는 ALL). **US-002 per-US는 codex도 pass**(교차 정상 작동) — 막힌 건 오직 **재개-런에서 US-001 재검증**.

### 근본 교착 (세 조건 동시 → 워커가 뭘 해도 불가)
1. **build 모드 영구 고정**: confirmation 모드 조건 = `git status --porcelain --untracked-files=no` 완전 클린인데, **프로젝트에 사용자 소유 미커밋 파일이 상주**(본 사례 13개, 캠페인 불가침)하면 트리가 절대 안 비어 영구 build. (derive_verification_mode의 마지막 게이트 "tracked working tree is dirty".)
2. **정직한 RED 불가**: 재검증 대상 US의 테스트가 이미 GREEN(구현 완료됨) → 이 런에서 새 verify_red(exit≠0)를 정직하게 못 만듦.
3. **아카이브 인용 거부**: codex가 아카이브 RED/GREEN을 done-claim에 복사·provenance 명기해도 "archive assertion cannot substitute"로 3회 기각.
→ 결과: **dirty-트리 상주 프로젝트에서 재개된 캠페인은 codex 교차로 영원히 완주 불가.** claude는 mode-aware라 통과, codex만 막힘(NO ENGINE PRIORITY 위반 상태).

### 원인
v0.22.3 leader-derived "confirmation mode" 계약문이 **claude verifier 프롬프트에만 주입되고 codex 프롬프트엔 없음.** 더 근본은 confirmation 모드 진입 조건이 "**전체 tracked 트리 클린**"이라 dirty-트리 프로젝트를 배제 — 이 조건이 과도.

### 요청 (2단)
- **a) codex 프롬프트에 confirmation-mode 계약문 주입** (claude와 동일). 리더가 final/교차 디스패치 시 아카이브 done-claim 경로를 codex 프롬프트에 함께 넣고 "아카이브 증거 = 공식 증거"로 승격.
- **b) confirmation 모드 진입 조건 완화**: "전체 트리 클린" → "**캠페인이 건드리는 파일 집합만 클린**(사용자/무관 dirty 파일 무시)". 현재는 캠페인과 무관한 사용자 작업이 상주하기만 해도 모든 재검증이 build로 떨어져 codex가 막힌다. 캠페인 산출물·PRD 대상 파일 기준 SHA 대조로 판정.
- NO ENGINE PRIORITY 유지 — 양 엔진이 같은 모드 계약.

### 수용 기준
- dirty-트리 상주 프로젝트에서 재개된 캠페인이라도, 캠페인 대상 파일이 검증 commit과 일치하면 codex가 confirmation 판정(아카이브 RED/GREEN 부재를 fail 사유로 안 씀)
- 캠페인 대상 파일이 실제 변경된 경우(진짜 build)엔 strict 계약 유지 (회귀 0)
- 재개-런에서 claude=pass/codex=fail 비대칭 0

---

## 요청 ② leader-recovery auto-commit 견고화 (Bug #8 F-8)

### 증상 (2회 재발 → BLOCKED)
iteration 종료 시 리더가 워커 미커밋 산출물을 auto-commit(F-8)하는데, add 목록에 `.gitignore`된 경로의 **신규(untracked)** 파일이 하나라도 섞이면 `git add`가 거부:
```
The following paths are ignored by one of your .gitignore files: test-results
[ERROR] Bug #8: leader-recovery auto-commit failed. Refusing synthesis.
```
→ 즉시 BLOCKED. 실제로 `test-results/`는 저장소 `.gitignore:66`에 있으나 receipt/스크린샷은 **역사적으로 force-track되는 저장소 관례**라, 신규 evidence 파일이 이 함정에 빠진다.

### 요청 (택1 또는 조합)
- a) F-8 auto-commit의 add를 캠페인 산출물 경로에 한해 `git add -f`로 (ignored여도 track). 위험 경로(비-캠페인)는 제외.
- b) add 실패를 **hard-BLOCK이 아니라 경고+계속**으로 다운그레이드하고, 커밋 못 한 파일을 다음 워커 iteration 계약으로 이월(verifier가 어차피 완결성 게이트).
- 근거: ignored 경로의 신규 파일이 정당한 캠페인 산출물인 경우가 실재(evidence 디렉토리 관례). 현재는 이 정상 케이스가 캠페인을 죽인다.

### 수용 기준
- ignored-경로 신규 캠페인 산출물이 있어도 auto-commit 성공 또는 graceful 계속 (BLOCKED 0)
- 비-캠페인/위험 경로는 여전히 커밋 안 함 (회귀 0)

---

## 요청 ③ 프롬프트 제출 보장 (미전송 대기 방지)

### 증상 (반복 — 실제로 캠페인 2회 BLOCKED시킴)
worker/verifier pane에 트리거 프롬프트가 **입력창에 담긴 채 Enter 안 눌려 대기**. pane: `› Read and execute the instructions in ...` + `0 in · 0 out` + `Working` 문구 없음(= 실행 미시작). 관측 트리거: codex CLI가 프롬프트 앞에 usage-limit/weekly-limit **경고 배너**("N usage limit resets available", "less than 25% of your weekly limit")를 렌더하며 자동 제출 타이밍이 밀림. 기존 prompt-stall/auto-dismiss/heartbeat가 이 케이스를 못 잡음(heartbeat는 "pane 살아있음"만 봄).

**★핵심 악화 경로 (2026-07-20 실측)**: 미전송으로 pane이 idle인 동안 **리더의 consensus 폴링 타이머(ITER_TIMEOUT)는 계속 흐른다** → 프롬프트가 뒤늦게(수동/워치독 Enter로) 실행돼도 이미 20분 경과 → `Consensus verification failed (verifier/infra error before verdict)`로 **BLOCKED**. 즉 "미전송"이 "타임아웃 BLOCKED"로 증폭됨. codex 계정은 정상(직접 호출 OK), 작업도 정상(US 전부 통과, claude 판정 pass) — 순수 배너發 제출지연 → 타이머 경합.

### 요청
1. 트리거 send-keys 후 **제출 확인 루프**: N초(5~10s) 내 실행 시작 신호(`Working`/`esc to interrupt`/토큰 in>0/heartbeat 갱신) 없으면 Enter 재주입(최대 M회), 그래도 무반응이면 기존 stall 경로로. **(제출 확인 주기는 짧게 — 2~3s 권장. 실측상 20s 주기 워치독은 배너 대기를 못 이기고 타임아웃과 경합에서 짐.)**
2. 제출 감지는 배너-내성 있게: 입력창에 프롬프트 텍스트가 에코된 채 진행 신호 없음 = "미제출" 판정. 단일 glyph 의존 금지(gotchas 교훈).
3. `detect_quota_exhausted`는 "소진"만 봄 — **"리셋 여유 있음/한도 근접" 경고 배너(비-소진)가 제출을 지연시키는 케이스**를 별도 처리(경고 무시하고 제출 재시도).
4. **★타임아웃 시계를 "제출 후"부터 재기산**: ITER_TIMEOUT/consensus 폴링 상한은 **프롬프트가 실제 실행 시작(첫 진행 신호)된 시점**부터 세어야 한다. 미제출 대기 구간(배너 렌더~Enter 성공)은 타임아웃에서 제외 — 아니면 제출 지연이 그대로 작업 타임아웃으로 오인된다. (또는: 첫 진행 신호를 못 받은 상태의 타임아웃은 "작업 실패"가 아니라 "제출 실패"로 분류해 재제출 경로로, hard-BLOCK 금지.)

### 수용 기준
- 배너 렌더 후에도 프롬프트가 N초 내 자동 실행 시작(미제출 idle 0), worker·verifier·codex 교차 pane 공통
- 정상 즉시 제출 케이스엔 재주입 안 함(진행 신호 감지 시 skip, 회귀 0)
- 미제출 대기가 길어져도 그것만으로 consensus/iter 타임아웃 BLOCKED가 발생하지 않음(제출-후 기산 또는 제출실패 분류)

---

## 부수 버그 2건

1. `run_ralph_desk.zsh:4918` 부근 — BLOCKED 종료 로그에 `command not found: the` 출력(문장 오타로 단어가 명령 실행된 것으로 보임). 무해하나 정리 필요.
2. **BLOCKED 종료의 exit code 불일치**: 초기 BLOCKED는 exit 1, 최근 BLOCKED 종료는 exit 0으로 관측 — 종료코드 의미 일관화(BLOCKED = 비영 권장, 래퍼가 성공으로 오판 방지).

---

## 공통
- `npm run test:full` green + 로컬 배포(npm install) 후 알려주면 tire 세션이 설치본 재검증 후 다음 캠페인부터 사용.
- 우선순위: **①(재개-런×dirty트리 완주 차단 — 실측 27 iteration/3+ BLOCKED로 확정, 최우선)** > ②(auto-commit BLOCKED, 2회 재발) ≈ ③(미전송→타임아웃 증폭, tire 세션 임시 워치독으로 방어 중) > 부수.
- 실증: pa-live-audit-unblock 캠페인이 작업물 완성(US 2/2 구현·검증·PO독립검증 green)에도 ① 때문에 codex 교차 COMPLETE 불가. tire 세션이 임시 zsh 워치독(미전송 Enter 주입 2s)·자동재개 감독으로 완주 시도했으나 ①은 도구 밖 해결 불가로 확인 — 이 요청들이 그 임시 방어를 대체할 근본 수정임.
- tests/ 동일 PR grep(레포 gotcha: runtime contract 변경 시 tests 갱신).
