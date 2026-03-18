# v2-protocol - Campaign Memory

## Stop Status
continue

## Objective
RLP Desk v1 프로토콜에 분석 결과 반영: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.

## Current State
Iteration 2 - US-003 + US-004 완료. governance.md, protocol-reference.md, rlp-desk.md 업데이트.

## Completed Stories
- US-001: Enhanced Memory Format — protocol-reference.md에 Completed Stories, Key Decisions, Criteria 섹션 추가. governance.md §7에 새 섹션 파싱 설명 추가. init script 메모리 템플릿 업데이트.
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log — 3개 문서에 ①½ prep cleanup 단계 추가. protocol-reference.md에 iter-NNN.result.md 형식 정의. [leader-measured]/[git-measured] authorship label 추가. 루프 단계 번호 일관성 확인.
- US-003: Circuit Breaker Enhancement — governance.md §8에 연속 실패 CB 2개 추가. protocol-reference.md CB 테이블 업데이트 + consecutive_failures 필드 + criterion-based "same error" 정의. rlp-desk.md CB 섹션 업데이트. 3개 문서 일관.
- US-004: Verifier Independence Reform — protocol-reference.md verify-verdict.json에 3-state verdict(pass|fail|request_info) + severity 필드 추가. git diff scope 명시. memory orientation-only 명시. uncertain=fail 제거. governance.md §2 Verifier 역할 업데이트. rlp-desk.md ⑦에 request_info 분기 추가.

## Next Iteration Contract
**Story**: US-005 — Fix Loop Protocol
**Task**: Verifier fail 시 구조화된 수정 루프 정의. Leader가 issues를 구조화해서 Worker에게 전달.
1. governance.md에 "Fix Loop Protocol" 섹션 추가 (§7과 §8 사이 또는 §7 내부 sub-section)
   - Verifier fail → Leader가 verdict issues 읽기 → severity 순 정렬 → next contract에 구조화된 issues 전달
   - fix_hint는 `(suggestion, non-authoritative)` 표시와 함께 optional
   - traceability rule: "수정에 필요한 변경만 허용 (모든 변경은 issue 해결에 대한 정당화 필요)"
   - consecutive_failures 카운터가 status.json에서 Leader가 관리함을 명시
2. protocol-reference.md에 Fix Loop 상세 스펙 추가 (별도 섹션)
3. rlp-desk.md ⑦의 fail 분기를 Fix Loop 참조로 확장

**Criteria**:
- `grep -q "Fix Loop" src/governance.md`
- `grep -q "traceability" docs/protocol-reference.md`
- `grep -q "severity" src/governance.md` (Fix Loop에서 severity 순 정렬 언급)
- rlp-desk.md fail 분기에 Fix Loop 참조 존재
- fix_hint가 "(suggestion, non-authoritative)" 표기로 optional임이 명시됨

동시에 US-006도 처리 가능 (S 크기, US-005와 독립):
**Story**: US-006 — Worker Prompt Template Enhancement
1. init_ralph_desk.zsh의 worker prompt에 "Before you start" 섹션 추가
2. 읽기 순서: 1. Campaign Memory → 2. PRD → 3. Test Spec → 4. Latest Context
3. 3가지 scope 규칙: (1) 프로젝트 루트 밖 파일 금지, (2) 프롬프트 파일 수정 금지, (3) next contract에 없는 작업 금지
4. "iteration 완료 시 변경사항 커밋" 규칙 추가

## Key Decisions
- Iteration 1: US-001+US-002 동시 처리 (둘 다 S 크기, 독립적). 모두 단순 Markdown 추가 변경.
- Iteration 1: ①½ 표기 사용 (prep cleanup이 ①과 ② 사이임을 명확히).
- Iteration 1: YAML 언급을 "No YAML" 문장으로 처리 (memory spec 마지막에 명시적 거부 선언).
- Iteration 2: US-003+US-004 동시 처리 (둘 다 독립적). US-004에서 "uncertain=fail" 완전 제거하고 request_info로 대체.
- Iteration 2: verify-verdict.json issues 배열에 fix_hint 필드 추가 (US-005 Fix Loop와의 연계를 위해 미리 포함).
- Iteration 2: "Same error" 판별 기준을 "동일 acceptance criterion ID가 연속 2회 Verifier issues에 등장"으로 명확화.

## Patterns Discovered
- 3개 핵심 문서(governance, protocol-reference, rlp-desk.md)는 루프 단계 구조가 동일해야 함.
- init script의 heredoc에서 $ 포함 변수는 EOF 앞 따옴표 없이 써야 interpolation됨.
- governance.md의 grep 검사는 정확한 문자열이 필요 — "Clean previous"가 없으면 test-spec grep이 실패함 (pre-existing gap from iter 1, not introduced by iter 2).

## Learnings
- governance.md는 개요, protocol-reference.md는 상세 스펙, rlp-desk.md는 실행 지침. 세 문서가 같은 내용을 다른 추상화 수준으로 설명.
- 메모리 템플릿의 Criteria 예시는 init script 자체에서 제네릭하게 작성해야 첫 번째 Worker가 PRD를 읽고 채울 수 있음.
- US-004의 request_info verdict는 Verifier가 "모르겠으면 fail"하는 것보다 구체적 질문으로 Leader에게 판단을 위임하는 것이 더 안전함.

## Evidence Chain
- Iteration 1: smoke test PASS (Completed Stories, Key Decisions, Criteria in generated memory)
- Iteration 1: content verification PASS (US-001 6/6, US-002 10/10 grep checks)
- Iteration 1: loop step consistency PASS (① ①½ ② ③ ④ ⑤ ⑥ ⑦ ⑧ in all 3 docs)
- Iteration 1: git diff --stat: 4 files changed, 83 insertions(+), 6 deletions(-)
- Iteration 2: US-003 verification PASS (5/5 grep checks: consecutive in governance+rlp-desk+protocol-reference, consecutive_failures in status.json, acceptance criterion in protocol-reference)
- Iteration 2: US-004 verification PASS (8/8 grep checks: request_info in all 3 docs, git diff scope, severity, orientation, no uncertain=fail)
- Iteration 2: git diff --stat: 4 files changed (governance.md, protocol-reference.md, rlp-desk.md, memory.md)
