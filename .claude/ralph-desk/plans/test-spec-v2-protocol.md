# Test Specification: v2-protocol

## Verification Commands

### Consistency Check (3-document alignment)
```bash
# governance.md, protocol-reference.md, rlp-desk.md 간 핵심 용어/구조 일관성 검증
cd /Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol

# Circuit breaker 수가 3개 문서에서 동일해야 함
echo "=== CB count check ==="
grep -c "BLOCKED" src/governance.md
grep -c "BLOCKED" docs/protocol-reference.md
grep -c "BLOCKED" src/commands/rlp-desk.md

# request_info verdict가 3개 문서에 존재해야 함
echo "=== request_info check ==="
grep -l "request_info" src/governance.md docs/protocol-reference.md src/commands/rlp-desk.md
```

### Init Script Smoke Test
```bash
# 임시 디렉토리에서 init 스크립트 실행 후 생성 파일 확인
cd /tmp && mkdir -p rlp-test && cd rlp-test && git init
ROOT=/tmp/rlp-test bash /Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol/src/scripts/init_ralph_desk.zsh smoke-test "test objective"

# 생성된 파일 존재 확인
test -f /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.worker.prompt.md && echo "PASS: worker prompt" || echo "FAIL: worker prompt"
test -f /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md && echo "PASS: verifier prompt" || echo "FAIL: verifier prompt"
test -f /tmp/rlp-test/.claude/ralph-desk/memos/smoke-test-memory.md && echo "PASS: memory" || echo "FAIL: memory"

# 새 섹션 존재 확인
grep -q "Completed Stories" /tmp/rlp-test/.claude/ralph-desk/memos/smoke-test-memory.md && echo "PASS: memory has Completed Stories" || echo "FAIL: missing Completed Stories"
grep -q "Key Decisions" /tmp/rlp-test/.claude/ralph-desk/memos/smoke-test-memory.md && echo "PASS: memory has Key Decisions" || echo "FAIL: missing Key Decisions"
grep -q "Before you start" /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.worker.prompt.md && echo "PASS: worker has Before You Start" || echo "FAIL: missing Before You Start"
grep -q "request_info" /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md && echo "PASS: verifier has request_info" || echo "FAIL: missing request_info"
grep -q "git diff" /tmp/rlp-test/.claude/ralph-desk/prompts/smoke-test.verifier.prompt.md && echo "PASS: verifier has git diff" || echo "FAIL: missing git diff"
grep -q "Depends on" /tmp/rlp-test/.claude/ralph-desk/plans/prd-smoke-test.md && echo "PASS: PRD has Depends on" || echo "FAIL: missing Depends on"

# Cleanup
rm -rf /tmp/rlp-test
```

### Content Verification
```bash
cd /Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol

# US-001: Enhanced Memory — YAML 없어야 함
echo "=== US-001 ==="
! grep -q "YAML" docs/protocol-reference.md && echo "PASS: no YAML in memory spec" || echo "CHECK: YAML mentioned — verify not in memory section"
grep -q "Completed Stories" docs/protocol-reference.md && echo "PASS: Completed Stories" || echo "FAIL"
grep -q "Key Decisions" docs/protocol-reference.md && echo "PASS: Key Decisions" || echo "FAIL"
grep -q "Criteria" docs/protocol-reference.md && echo "PASS: Criteria in contract" || echo "FAIL"

# US-002: Prep-stage cleanup
echo "=== US-002 ==="
grep -q "Clean previous" src/governance.md && echo "PASS: prep cleanup in governance" || echo "FAIL"
grep -q "result.md" docs/protocol-reference.md && echo "PASS: result.md spec" || echo "FAIL"

# US-003: Circuit breaker
echo "=== US-003 ==="
grep -q "consecutive" src/governance.md && echo "PASS: consecutive in governance" || echo "FAIL"
grep -q "consecutive_failures" docs/protocol-reference.md && echo "PASS: counter in status.json" || echo "FAIL"
grep -q "acceptance criterion" docs/protocol-reference.md && echo "PASS: criterion-based matching" || echo "FAIL"

# US-004: Verifier reform
echo "=== US-004 ==="
grep -q "request_info" docs/protocol-reference.md && echo "PASS: 3-state verdict" || echo "FAIL"
grep -q "git diff" docs/protocol-reference.md && echo "PASS: git diff scope" || echo "FAIL"
grep -q "severity" docs/protocol-reference.md && echo "PASS: severity in issues" || echo "FAIL"
grep -q "orientation" docs/protocol-reference.md && echo "PASS: memory orientation" || echo "FAIL"

# US-005: Fix loop
echo "=== US-005 ==="
grep -q "Fix Loop" src/governance.md && echo "PASS: fix loop in governance" || echo "FAIL"
grep -q "traceability" docs/protocol-reference.md && echo "PASS: traceability rule" || echo "FAIL"

# US-006: Worker prompt
echo "=== US-006 ==="
grep -q "Before you start" src/scripts/init_ralph_desk.zsh && echo "PASS: before you start" || echo "FAIL"
grep -q "commit" src/scripts/init_ralph_desk.zsh && echo "PASS: commit rule" || echo "FAIL"

# US-007: Verifier prompt
echo "=== US-007 ==="
! grep -q "uncertain.*fail" src/scripts/init_ralph_desk.zsh && echo "PASS: no uncertain=fail" || echo "FAIL: still has uncertain=fail"
grep -q "request_info" src/scripts/init_ralph_desk.zsh && echo "PASS: request_info in template" || echo "FAIL"

# US-008: Scaffold
echo "=== US-008 ==="
grep -q "Depends on" src/scripts/init_ralph_desk.zsh && echo "PASS: depends_on in PRD template" || echo "FAIL"
grep -q "quality-spec" docs/protocol-reference.md && echo "PASS: quality-spec mentioned" || echo "FAIL"
```

## Criteria -> Verification Mapping

| Criterion | Method | Command/Check |
|-----------|--------|---------------|
| US-001 AC1: Completed Stories in memory spec | grep | `grep "Completed Stories" docs/protocol-reference.md` |
| US-001 AC2: Criteria in contract | grep | `grep "Criteria" docs/protocol-reference.md` |
| US-001 AC3: Key Decisions | grep | `grep "Key Decisions" docs/protocol-reference.md` |
| US-001 AC4: Existing sections preserved | manual | Memory spec still has Patterns/Learnings/Evidence |
| US-001 AC5: No YAML memory | grep | `! grep "YAML" docs/protocol-reference.md` (memory section) |
| US-001 AC6: governance sync | manual | §7 mentions new sections |
| US-002 AC1-3: Prep cleanup in 3 docs | grep | See content verification above |
| US-002 AC4: result.md format | manual | Spec includes Result + Files Changed + authorship |
| US-002 AC5: Authorship labels | grep | `grep "leader-measured\|git-measured" docs/protocol-reference.md` |
| US-002 AC6: Loop step consistency | manual | Compare step numbers across 3 docs |
| US-003 AC1-3: Consecutive CB in 3 docs | grep | See content verification above |
| US-003 AC4: status.json counter | grep | `grep "consecutive_failures" docs/protocol-reference.md` |
| US-003 AC5: Criterion-based matching | grep | `grep "acceptance criterion" docs/protocol-reference.md` |
| US-003 AC6: CB consistency | manual | Compare CB tables across 3 docs |
| US-004 AC1: git diff scope | grep | `grep "git diff" docs/protocol-reference.md` |
| US-004 AC2: Memory orientation | grep | `grep "orientation" docs/protocol-reference.md` |
| US-004 AC3: 3-state verdict | grep | `grep "request_info" docs/protocol-reference.md` |
| US-004 AC4: request_info definition | manual | Definition present in protocol-reference |
| US-004 AC5: Severity field | grep | `grep "severity" docs/protocol-reference.md` |
| US-004 AC6: No uncertain=fail | grep | `! grep "uncertain.*fail" docs/protocol-reference.md` |
| US-004 AC7-8: Tool delegation + focus | manual | Verifier section specifies delegation |
| US-004 AC9-10: governance + rlp-desk sync | manual | request_info branch in both docs |
| US-005 AC1-7: Fix loop protocol | grep + manual | See content verification above |
| US-006 AC1-5: Worker template | grep on init script | See init smoke test above |
| US-007 AC1-6: Verifier template | grep on init script | See init smoke test above |
| US-008 AC1-6: Scaffold updates | grep on init script | See init smoke test above |
