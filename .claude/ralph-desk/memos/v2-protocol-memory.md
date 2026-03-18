# v2-protocol - Campaign Memory

## Stop Status
verify

## Objective
RLP Desk v1 프로토콜에 분석 결과 반영: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.

## Current State
Iteration 4 - US-007 + US-008 완료. init_ralph_desk.zsh verifier prompt US-004 개혁 반영 (uncertain=fail 제거, request_info 도입, git diff scope, orientation, severity, smoke test). PRD 템플릿에 Depends on + Size 필드 추가. protocol-reference.md에 quality-spec 언급 추가. 전체 8개 US 완료.

## Completed Stories
- US-001: Enhanced Memory Format — protocol-reference.md에 Completed Stories, Key Decisions, Criteria 섹션 추가. governance.md §7에 새 섹션 파싱 설명 추가. init script 메모리 템플릿 업데이트.
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log — 3개 문서에 ①½ prep cleanup 단계 추가. protocol-reference.md에 iter-NNN.result.md 형식 정의. [leader-measured]/[git-measured] authorship label 추가.
- US-003: Circuit Breaker Enhancement — governance.md §8에 연속 실패 CB 2개 추가. protocol-reference.md CB 테이블 업데이트 + consecutive_failures 필드 + criterion-based "same error" 정의. rlp-desk.md CB 섹션 업데이트.
- US-004: Verifier Independence Reform — protocol-reference.md verify-verdict.json에 3-state verdict(pass|fail|request_info) + severity 필드 추가. git diff scope 명시. memory orientation-only 명시. uncertain=fail 제거. governance.md §2 Verifier 역할 업데이트. rlp-desk.md ⑦에 request_info 분기 추가.
- US-005: Fix Loop Protocol — governance.md §7½에 Fix Loop Protocol 섹션 추가 (severity 순 정렬, fix_hint non-authoritative, traceability rule, consecutive_failures Leader 관리). protocol-reference.md에 Fix Loop 상세 스펙 + Fix Contract Format 추가. rlp-desk.md ⑦ fail 분기를 5단계 Fix Loop 참조로 확장.
- US-006: Worker Prompt Template Enhancement — init_ralph_desk.zsh worker prompt에 "Before you start" 섹션 추가 (4개 읽기 순서). Scope rules 3가지 추가. "iteration 완료 시 변경사항 커밋" 규칙 추가.
- US-007: Verifier Prompt Template Enhancement — init_ralph_desk.zsh verifier prompt에서 "uncertain=fail" 제거, "request_info" 도입. git diff scope 식별 단계 추가. Campaign Memory orientation-only 명시. verdict JSON에 request_info 추가, issues에 severity 필드 추가. Smoke test 실행 단계(6번) 추가.
- US-008: Scaffold & Template Updates — PRD 템플릿 User Story에 Depends on + Size 필드 추가. protocol-reference.md에 Project Plans Files 섹션 추가 (quality-spec-<slug>.md 설명 포함).

## Next Iteration Contract
(none — all stories complete, stop=verify)

## Key Decisions
- Iteration 1: US-001+US-002 동시 처리 (둘 다 S 크기, 독립적). 모두 단순 Markdown 추가 변경.
- Iteration 1: ①½ 표기 사용 (prep cleanup이 ①과 ② 사이임을 명확히).
- Iteration 1: YAML 언급을 "No YAML" 문장으로 처리 (memory spec 마지막에 명시적 거부 선언).
- Iteration 2: US-003+US-004 동시 처리 (둘 다 독립적). US-004에서 "uncertain=fail" 완전 제거하고 request_info로 대체.
- Iteration 2: verify-verdict.json issues 배열에 fix_hint 필드 추가 (US-005 Fix Loop와의 연계를 위해 미리 포함).
- Iteration 2: "Same error" 판별 기준을 "동일 acceptance criterion ID가 연속 2회 Verifier issues에 등장"으로 명확화.
- Iteration 3: Fix Loop를 §7½로 배치 (§7 루프와 §8 CB 사이). 별도 섹션으로 분리하여 명확성 확보.
- Iteration 3: "traceability" grep 테스트는 case-sensitive — 본문에 소문자 "traceability" 포함하여 해결.
- Iteration 3: US-007+US-008을 다음 iteration에 묶어서 처리 (둘 다 S 크기, init_ralph_desk.zsh 대상).
- Iteration 4: quality-spec을 "Project Plans Files" 섹션으로 protocol-reference.md에 추가 (init 생성 대상 아님, 수동 생성).
- Iteration 4: US-008 AC3(consecutive_failures 문서화)은 이미 protocol-reference.md status.json 섹션에 존재함 — 추가 작업 불필요.

## Patterns Discovered
- 3개 핵심 문서(governance, protocol-reference, rlp-desk.md)는 루프 단계 구조가 동일해야 함.
- init script의 heredoc에서 $ 포함 변수는 EOF 앞 따옴표 없이 써야 interpolation됨.
- governance.md의 grep 검사는 정확한 문자열이 필요 — "Clean previous"가 없으면 test-spec grep이 실패함 (pre-existing gap from iter 1).
- test-spec grep은 case-sensitive — 본문 작성 시 grep 대상 문자열과 대소문자 일치 확인 필수.

## Learnings
- governance.md는 개요, protocol-reference.md는 상세 스펙, rlp-desk.md는 실행 지침. 세 문서가 같은 내용을 다른 추상화 수준으로 설명.
- 메모리 템플릿의 Criteria 예시는 init script 자체에서 제네릭하게 작성해야 첫 번째 Worker가 PRD를 읽고 채울 수 있음.
- US-004의 request_info verdict는 Verifier가 "모르겠으면 fail"하는 것보다 구체적 질문으로 Leader에게 판단을 위임하는 것이 더 안전함.
- Fix Loop의 traceability rule은 Worker scope creep 방지에 핵심. fix_hint를 non-authoritative로 명시하면 Worker가 더 나은 해법을 선택할 수 있음.
- init script heredoc에서 escape 없는 \`...\` 백틱은 command substitution으로 해석됨 — 리터럴 백틱은 \\\` 이스케이프 필요.

## Evidence Chain
- Iteration 1: smoke test PASS (Completed Stories, Key Decisions, Criteria in generated memory)
- Iteration 1: content verification PASS (US-001 6/6, US-002 10/10 grep checks)
- Iteration 1: loop step consistency PASS (① ①½ ② ③ ④ ⑤ ⑥ ⑦ ⑧ in all 3 docs)
- Iteration 1: git diff --stat: 4 files changed, 83 insertions(+), 6 deletions(-)
- Iteration 2: US-003 verification PASS (5/5 grep checks)
- Iteration 2: US-004 verification PASS (8/8 grep checks)
- Iteration 2: git diff --stat: 4 files changed
- Iteration 3: US-005 verification PASS (6/6 grep checks)
- Iteration 3: US-006 verification PASS (4/4 grep checks)
- Iteration 3: smoke test PASS
- Iteration 3: git diff --stat: 4 files changed, 86 insertions(+), 12 deletions(-)
- Iteration 4: US-007 verification PASS (6/6 grep checks: no uncertain=fail, request_info, git diff, orientation, severity, smoke test)
- Iteration 4: US-008 verification PASS (3/3 grep checks: Depends on, Size, quality-spec)
- Iteration 4: smoke test PASS (verifier has request_info, git diff, no uncertain=fail, orientation, severity, smoke test step; PRD has Depends on)
- Iteration 4: full test-spec suite PASS (all 8 stories)
- Iteration 4: git diff --stat: 2 files changed, 25 insertions(+), 7 deletions(-)
