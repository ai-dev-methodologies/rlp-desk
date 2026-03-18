Execute the plan for v2-protocol.

## Project
RLP Desk v1 프로토콜을 v2로 개선. 핵심 변경: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.

## Project Root
`/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol`

## Before you start
1. **Campaign Memory** 읽기: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-memory.md` → Next Iteration Contract가 당신의 임무
2. **PRD** 읽기: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/plans/prd-v2-protocol.md` → acceptance criteria 확인
3. **Test Spec** 읽기: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/plans/test-spec-v2-protocol.md` → 검증 방법 확인
4. **Latest Context** 읽기: `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/context/v2-protocol-latest.md` → 현재 상태 파악

## Iteration rules
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly ONE bounded next action (Next Iteration Contract에 기술된 작업).
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- Write evidence artifacts.
- **Iteration 완료 시 변경사항을 커밋하라** (commit message에 iteration 번호와 story ID 포함).

## Scope rules (절대 위반 금지)
- 프로젝트 루트 밖 파일 생성/수정 금지
- 이 프롬프트 파일 및 PRD/test-spec 수정 금지
- Next Iteration Contract에 없는 작업 금지

## Working with protocol documents
이 프로젝트는 Markdown 문서를 수정하는 작업이다. 핵심 파일:
- `src/governance.md` — 핵심 프로토콜 (9개 섹션)
- `docs/protocol-reference.md` — 상세 스펙
- `src/commands/rlp-desk.md` — 슬래시 커맨드
- `src/scripts/init_ralph_desk.zsh` — scaffold 생성기

**3개 핵심 문서(governance, protocol-reference, rlp-desk.md)는 항상 일관성을 유지해야 한다.**
한 문서를 수정하면 나머지 2개에도 해당 변경이 반영되어야 하는지 확인할 것.

## Stop behavior
- Objective achieved → write done-claim JSON to `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-done-claim.json`, exit
- Autonomous blocker → write to `/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/.claude/ralph-desk/memos/v2-protocol-blocked.md`, exit
- Otherwise → set stop=continue, define next iteration contract in memory, exit

## Objective
RLP Desk v1 프로토콜에 분석 결과 반영: Enhanced Markdown memory, Verifier git-diff scope, 3-state verdict, fix loop, circuit breaker 개선.
