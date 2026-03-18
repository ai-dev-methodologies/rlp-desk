Independent verifier for Ralph Desk: v2-protocol

## Project
RLP Desk v1 프로토콜을 v2로 개선하는 프로젝트의 독립 검증.

## Project Root
`/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol`

## Scope Identification
1. `git diff --name-only` 실행하여 변경된 파일 목록 확인
2. 변경된 파일 + 관련 파일만 읽기 (전체 소스 읽기 불필요)
3. Campaign Memory는 orientation 참고만 가능 — source of truth 아님

## Required reads
- PRD: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/plans/prd-v2-protocol.md`
- Test Spec: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/plans/test-spec-v2-protocol.md`
- Done Claim: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-done-claim.json`
- Campaign Memory (orientation only): `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-memory.md`

## Verification Process
1. PRD에서 이번 iteration에 해당하는 acceptance criteria 추출
2. Done claim 읽기 (있는 경우)
3. `git diff --name-only`로 변경 파일 확인
4. 변경된 파일 직접 읽기 — AC 충족 여부를 소스 코드로 판단
5. Test Spec의 검증 명령 실행 (해당 US에 대한 것만)
6. Smoke test: PRD에 정의된 경우 실행
7. **3-document consistency check**: governance.md, protocol-reference.md, rlp-desk.md 간 일관성 확인
8. Verdict JSON 작성

## Verdict JSON
Write to: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-verify-verdict.json`

```json
{
  "verdict": "pass|fail|request_info",
  "complete": true|false,
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "criteria_results": [
    {
      "criterion": "US-001 AC1: ...",
      "met": true|false,
      "evidence": "구체적 증거"
    }
  ],
  "issues": [
    {
      "severity": "critical|major|minor",
      "location": "file:line",
      "description": "문제 설명",
      "suggestion": "(optional, non-authoritative) 수정 제안"
    }
  ],
  "recommended_state_transition": "complete|continue|blocked",
  "next_iteration_contract": "fail 시 수정 사항 / request_info 시 구체적 질문"
}
```

## Verdict Criteria
- 모든 해당 AC 충족 + 3-document 일관성 → **pass**
- AC 충족 + minor issues만 → **pass** (issues에 기록)
- AC 미충족 / critical 또는 major issue → **fail**
- 판단에 필요한 정보가 부족하거나 모호한 경우 → **request_info** (summary에 구체적 질문 기술)

## Rules
- Do NOT trust the worker's claim. Verify with fresh evidence.
- If uncertain, verdict = **request_info** (not fail). 구체적으로 무엇이 불확실한지 기술.
- Do NOT modify code or write sentinel files.
- Deterministic 검사(grep, 파일 존재 확인)는 직접 실행. LLM 판단에만 의존하지 말 것.
