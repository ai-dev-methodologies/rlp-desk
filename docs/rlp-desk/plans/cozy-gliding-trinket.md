# Plan: 리팩토링 실행 검증 + v05-remaining 재시작

## Context
Engine path refactoring Phase 0~7 완료 (38 TDD 구조적 테스트 pass).
하지만 **실제 tmux 실행 검증**을 안 했음. 리팩토링이 실제 캠페인에서 정상 동작하는지 확인 필요.

## 검증 순서

### Step 1: 좀비 runner + sentinel 정리
```bash
ps aux | grep run_ralph_desk | grep -v grep | awk '{print $2}' | xargs kill 2>/dev/null
for p in $(tmux list-panes -F '#{pane_id}' | grep -v '%360'); do tmux kill-pane -t "$p" 2>/dev/null; done
rm -f .claude/ralph-desk/memos/v05-remaining-blocked.md
rm -f .claude/ralph-desk/memos/v05-remaining-complete.md
rm -f .claude/ralph-desk/memos/v05-remaining-done-claim.json
rm -f .claude/ralph-desk/memos/v05-remaining-verify-verdict.json
rm -f .claude/ralph-desk/memos/v05-remaining-iter-signal.json
rm -f .claude/ralph-desk/logs/v05-remaining/session-config.json
```

### Step 2: v05-remaining 캠페인 실행 (spark worker)
```bash
LOOP_NAME="v05-remaining" ROOT="$PWD" MAX_ITER=15 \
WORKER_MODEL=gpt-5.3-codex-spark WORKER_ENGINE=codex \
WORKER_CODEX_MODEL=gpt-5.3-codex-spark WORKER_CODEX_REASONING=medium \
VERIFIER_MODEL=sonnet VERIFIER_ENGINE=claude \
VERIFY_MODE=per-us VERIFY_CONSENSUS=0 CB_THRESHOLD=6 \
ITER_TIMEOUT=600 DEBUG=1 WITH_SELF_VERIFICATION=1 \
  zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
```
(run_in_background=true)

### Step 3: 검증 체크리스트
- [ ] Pane 3개 생성됨 (leader + worker + verifier)
- [ ] Worker pane에서 codex exec 실행됨 (bash trigger, dead pane 오판 없음)
- [ ] Worker 완료 후 heartbeat exited → signal auto-generate
- [ ] Verifier(sonnet) 정상 시작 + verdict 작성
- [ ] US-002 이상 진행 (이전 US-001은 이미 verified)
- [ ] 좀비 runner 없음 (ps 확인)

### Step 4: 실패 시 대응
- codex worker 시작 실패 → trigger script 내용 확인 + 수동 실행 테스트
- verifier timeout → runner log tail + pane 상태 확인
- BLOCKED → sentinel 원인 분석 + 수정 후 재시도

### Step 5: 성공 시
- 캠페인 진행 모니터링 (status 확인)
- 완료 대기 또는 다음 세션 handoff

## 파일
- `src/scripts/run_ralph_desk.zsh` — 리팩토링된 runner
- `~/.claude/ralph-desk/run_ralph_desk.zsh` — 로컬 동기화된 사본
- `.claude/ralph-desk/logs/v05-remaining/` — 캠페인 아티팩트
