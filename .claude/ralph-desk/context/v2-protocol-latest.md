# v2-protocol - Latest Context

## Current Frontier
### Completed
- US-001: Enhanced Memory Format (protocol-reference.md, governance.md, init_ralph_desk.zsh)
- US-002: Leader Loop Prep-stage Cleanup & Post-execution Log (all 3 docs + init script)
- US-003: Circuit Breaker Enhancement (governance.md §8, protocol-reference.md CB table + status.json, rlp-desk.md)
- US-004: Verifier Independence Reform (protocol-reference.md verify-verdict.json 3-state + severity + scope + orientation, governance.md §2, rlp-desk.md ⑦ request_info branch)

### In Progress
(none)

### Next
- US-005: Fix Loop Protocol (governance.md Fix Loop section, protocol-reference.md Fix Loop spec, rlp-desk.md fail branch expansion)
- US-006: Worker Prompt Template Enhancement (init_ralph_desk.zsh worker prompt "Before you start" section)

## Key Decisions
- US-003+US-004 동시 처리 완료 (독립적).
- verify-verdict.json에 fix_hint 필드 미리 추가 (US-005 Fix Loop와의 연계).
- "Same error" 판별: 동일 acceptance criterion ID가 연속 2회 Verifier issues에 등장.
- request_info: Verifier 불확실 시 구체적 질문 → Leader 판단 (uncertain=fail 제거).

## Known Issues
- test-spec의 `grep -q "Clean previous" src/governance.md` 검사는 pre-existing gap (governance.md는 "Prep-stage cleanup" + "Delete done-claim.json" 사용). US-003/004 scope 밖.

## Files Changed This Iteration
- src/governance.md (US-003: §8 CB 2개 추가, US-004: §2 Verifier 역할 업데이트)
- docs/protocol-reference.md (US-003: CB 테이블 + consecutive_failures + criterion 정의, US-004: verify-verdict.json 3-state + severity + scope + orientation)
- src/commands/rlp-desk.md (US-003: CB 섹션 업데이트, US-004: ⑦ request_info 분기 추가)

## Verification Status
- US-003 grep checks: PASS (5/5)
- US-004 grep checks: PASS (8/8)
- no uncertain=fail in protocol-reference: PASS
- request_info in all 3 docs: PASS
