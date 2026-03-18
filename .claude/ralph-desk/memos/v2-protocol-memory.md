# v2-protocol - Campaign Memory

## Stop Status
continue

## Objective
RLP Desk v1 프로토콜에 분석 결과 반영: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.

## Current State
Iteration 1 - US-001 + US-002 완료. protocol-reference.md, governance.md, rlp-desk.md, init_ralph_desk.zsh 업데이트.

## Completed Stories
- US-001: Enhanced Memory Format — protocol-reference.md에 Completed Stories, Key Decisions, Criteria 섹션 추가. governance.md §7에 새 섹션 파싱 설명 추가. init script 메모리 템플릿 업데이트.
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log — 3개 문서에 ①½ prep cleanup 단계 추가. protocol-reference.md에 iter-NNN.result.md 형식 정의. [leader-measured]/[git-measured] authorship label 추가. 루프 단계 번호 일관성 확인.

## Next Iteration Contract
**Story**: US-003 — Circuit Breaker Enhancement
**Task**: 연속 실패 3회 CB 추가. status.json에 consecutive_failures 추가. "같은 issue" 판별 기준 명확화.
1. governance.md §8에 새 CB 행 추가: "3 consecutive failures (different errors) → upgrade to opus → retry once → BLOCKED"
2. protocol-reference.md Circuit Breakers 테이블에 동일 추가
3. rlp-desk.md Circuit Breaker 섹션에 동일 추가
4. protocol-reference.md status.json 스펙에 `consecutive_failures: 0` 필드 추가
5. "같은 에러" 판별 기준: "동일 acceptance criterion이 2회 연속 fail"로 명시
6. 3개 문서 간 CB 조건/동작 일관성 확인

**Criteria**:
- governance.md §8에 consecutive 관련 CB 존재
- protocol-reference.md status.json에 consecutive_failures 필드 존재
- protocol-reference.md에 "acceptance criterion" 기반 판별 기준 명시
- 3개 문서 CB 내용 일관

동시에 US-004도 처리 가능 (M 크기, US-003과 독립):
**Story**: US-004 — Verifier Independence Reform
1. protocol-reference.md Verifier 섹션에 "scope 식별: git diff --name-only 사용" 명시
2. memory.md를 "orientation 참고만 가능, source of truth 아님"으로 명시
3. verify-verdict.json 스펙에 "verdict": "pass|fail|request_info" (3-state)
4. request_info 의미 정의: 판단 불가 시 구체적 질문, Leader가 결정
5. issues 배열에 "severity": "critical|major|minor" 추가
6. "확신 없으면 fail" 규칙 제거
7. "deterministic 검사는 도구에 위임" 명시
8. governance.md §2 Verifier 역할 업데이트
9. rlp-desk.md Verifier 실행 후 request_info 분기 추가

## Key Decisions
- Iteration 1: US-001+US-002 동시 처리 (둘 다 S 크기, 독립적). 모두 단순 Markdown 추가 변경.
- Iteration 1: ①½ 표기 사용 (prep cleanup이 ①과 ② 사이임을 명확히).
- Iteration 1: YAML 언급을 "No YAML" 문장으로 처리 (memory spec 마지막에 명시적 거부 선언).

## Patterns Discovered
- 3개 핵심 문서(governance, protocol-reference, rlp-desk.md)는 루프 단계 구조가 동일해야 함.
- init script의 heredoc에서 $ 포함 변수는 EOF 앞 따옴표 없이 써야 interpolation됨.

## Learnings
- governance.md는 개요, protocol-reference.md는 상세 스펙, rlp-desk.md는 실행 지침. 세 문서가 같은 내용을 다른 추상화 수준으로 설명.
- 메모리 템플릿의 Criteria 예시는 init script 자체에서 제네릭하게 작성해야 첫 번째 Worker가 PRD를 읽고 채울 수 있음.

## Evidence Chain
- Iteration 1: smoke test PASS (Completed Stories, Key Decisions, Criteria in generated memory)
- Iteration 1: content verification PASS (US-001 6/6, US-002 10/10 grep checks)
- Iteration 1: loop step consistency PASS (① ①½ ② ③ ④ ⑤ ⑥ ⑦ ⑧ in all 3 docs)
- Iteration 1: git diff --stat: 4 files changed, 83 insertions(+), 6 deletions(-)
