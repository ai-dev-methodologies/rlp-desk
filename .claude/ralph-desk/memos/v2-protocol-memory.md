# v2-protocol - Campaign Memory

## Stop Status
continue

## Objective
RLP Desk v1 프로토콜에 분석 결과 반영: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.

## Current State
Iteration 3 - US-005 + US-006 완료. governance.md §7½ Fix Loop Protocol 추가, protocol-reference.md Fix Loop 상세 스펙 추가, rlp-desk.md fail 분기 Fix Loop 참조 확장, init_ralph_desk.zsh worker prompt "Before you start" 섹션 추가.

## Completed Stories
- US-001: Enhanced Memory Format — protocol-reference.md에 Completed Stories, Key Decisions, Criteria 섹션 추가. governance.md §7에 새 섹션 파싱 설명 추가. init script 메모리 템플릿 업데이트.
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log — 3개 문서에 ①½ prep cleanup 단계 추가. protocol-reference.md에 iter-NNN.result.md 형식 정의. [leader-measured]/[git-measured] authorship label 추가. 루프 단계 번호 일관성 확인.
- US-003: Circuit Breaker Enhancement — governance.md §8에 연속 실패 CB 2개 추가. protocol-reference.md CB 테이블 업데이트 + consecutive_failures 필드 + criterion-based "same error" 정의. rlp-desk.md CB 섹션 업데이트. 3개 문서 일관.
- US-004: Verifier Independence Reform — protocol-reference.md verify-verdict.json에 3-state verdict(pass|fail|request_info) + severity 필드 추가. git diff scope 명시. memory orientation-only 명시. uncertain=fail 제거. governance.md §2 Verifier 역할 업데이트. rlp-desk.md ⑦에 request_info 분기 추가.
- US-005: Fix Loop Protocol — governance.md §7½에 Fix Loop Protocol 섹션 추가 (severity 순 정렬, fix_hint non-authoritative, traceability rule, consecutive_failures Leader 관리). protocol-reference.md에 Fix Loop 상세 스펙 + Fix Contract Format 추가. rlp-desk.md ⑦ fail 분기를 5단계 Fix Loop 참조로 확장.
- US-006: Worker Prompt Template Enhancement — init_ralph_desk.zsh worker prompt에 "Before you start" 섹션 추가 (4개 읽기 순서). Scope rules 3가지 추가. "iteration 완료 시 변경사항 커밋" 규칙 추가.

## Next Iteration Contract
**Story**: US-007 — Verifier Prompt Template Enhancement
**Task**: init 스크립트의 verifier prompt 템플릿을 US-004 개혁에 맞게 업데이트.
1. "If uncertain, verdict = fail" 규칙 제거
2. "If uncertain, verdict = request_info (구체적 질문을 summary에 기술)"로 대체
3. "scope 식별: `git diff --name-only`로 변경 파일 확인 후 해당 파일 + 관련 imports만 읽기" 추가
4. "Campaign Memory는 orientation 참고만 가능" 명시
5. verdict JSON에 `request_info` 추가, issues에 `severity` 필드 추가
6. "Smoke test 실행" 단계 추가 (PRD에 정의된 경우)

**Criteria**:
- `! grep -q "uncertain.*fail" src/scripts/init_ralph_desk.zsh`
- `grep -q "request_info" src/scripts/init_ralph_desk.zsh`
- `grep -q "git diff" src/scripts/init_ralph_desk.zsh` (verifier template에서)
- smoke test: `grep -q "request_info" /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md`
- smoke test: `grep -q "git diff" /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md`

동시에 US-008도 처리 가능 (S 크기, 독립적):
**Story**: US-008 — Scaffold & Template Updates
1. PRD 템플릿의 User Story에 `- **Depends on**: []` 필드 추가
2. PRD 템플릿의 User Story에 `- **Size**: S|M|L` 필드 추가
3. status.json 초기값에 `consecutive_failures: 0` 포함되도록 문서에 명시 (protocol-reference.md)
4. 선택적 `plans/quality-spec-<slug>.md` 파일 언급 (protocol-reference.md에서 설명)

**Criteria (US-008)**:
- `grep -q "Depends on" src/scripts/init_ralph_desk.zsh`
- `grep -q "quality-spec" docs/protocol-reference.md`

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

## Patterns Discovered
- 3개 핵심 문서(governance, protocol-reference, rlp-desk.md)는 루프 단계 구조가 동일해야 함.
- init script의 heredoc에서 $ 포함 변수는 EOF 앞 따옴표 없이 써야 interpolation됨.
- governance.md의 grep 검사는 정확한 문자열이 필요 — "Clean previous"가 없으면 test-spec grep이 실패함 (pre-existing gap from iter 1, not introduced by iter 2).
- test-spec grep은 case-sensitive — 본문 작성 시 grep 대상 문자열과 대소문자 일치 확인 필수.

## Learnings
- governance.md는 개요, protocol-reference.md는 상세 스펙, rlp-desk.md는 실행 지침. 세 문서가 같은 내용을 다른 추상화 수준으로 설명.
- 메모리 템플릿의 Criteria 예시는 init script 자체에서 제네릭하게 작성해야 첫 번째 Worker가 PRD를 읽고 채울 수 있음.
- US-004의 request_info verdict는 Verifier가 "모르겠으면 fail"하는 것보다 구체적 질문으로 Leader에게 판단을 위임하는 것이 더 안전함.
- Fix Loop의 traceability rule은 Worker scope creep 방지에 핵심. fix_hint를 non-authoritative로 명시하면 Worker가 더 나은 해법을 선택할 수 있음.

## Evidence Chain
- Iteration 1: smoke test PASS (Completed Stories, Key Decisions, Criteria in generated memory)
- Iteration 1: content verification PASS (US-001 6/6, US-002 10/10 grep checks)
- Iteration 1: loop step consistency PASS (① ①½ ② ③ ④ ⑤ ⑥ ⑦ ⑧ in all 3 docs)
- Iteration 1: git diff --stat: 4 files changed, 83 insertions(+), 6 deletions(-)
- Iteration 2: US-003 verification PASS (5/5 grep checks: consecutive in governance+rlp-desk+protocol-reference, consecutive_failures in status.json, acceptance criterion in protocol-reference)
- Iteration 2: US-004 verification PASS (8/8 grep checks: request_info in all 3 docs, git diff scope, severity, orientation, no uncertain=fail)
- Iteration 2: git diff --stat: 4 files changed (governance.md, protocol-reference.md, rlp-desk.md, memory.md)
- Iteration 3: US-005 verification PASS (6/6 grep checks: Fix Loop in governance, traceability in protocol-reference, severity in governance, Fix Loop in rlp-desk.md, fix_hint non-authoritative, consecutive_failures)
- Iteration 3: US-006 verification PASS (4/4 grep checks: Before you start, commit rule, Campaign Memory read order, Scope rules)
- Iteration 3: smoke test PASS (worker has Before you start, commit rule, Scope rules; memory has Completed Stories, Key Decisions)
- Iteration 3: git diff --stat: 4 files changed, 86 insertions(+), 12 deletions(-)
