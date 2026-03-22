# RLP Desk Self-Test System

## How it works

1. This session creates test projects in `/tmp/rlp-test-<name>/`
2. Runs rlp-desk via tmux mode (panes visible in current window)
3. Waits for completion (polls status.json)
4. Reads debug.log and auto-evaluates [PLAN]/[EXEC]/[VALIDATE]
5. Reports pass/fail with specific failures
6. If fail → fix code → re-run

## Test Suite

### Test A: Agent + per-US verify (3 US)
```
Dir: /tmp/rlp-test-perus/
Slug: perus
Options: --verify-mode per-us --debug
Expect: 3 US verified individually + final ALL verify + COMPLETE
```

### Test B: Agent + batch verify
```
Dir: /tmp/rlp-test-batch/
Slug: batch
Options: --verify-mode batch --debug
Expect: 1 verify at end + COMPLETE
```

### Test C: tmux + per-US verify
```
Dir: /tmp/rlp-test-tmux/
Slug: tmux
Options: --mode tmux --verify-mode per-us --debug
Expect: panes split + per-US verify + COMPLETE
```

### Test D: codex worker
```
Dir: /tmp/rlp-test-codex/
Slug: codex
Options: --worker-engine codex --debug
Expect: worker_engine=codex in EXEC logs
```

### Test E: consensus verify
```
Dir: /tmp/rlp-test-consensus/
Slug: consensus
Options: --verify-consensus --debug
Expect: claude_verdict + codex_verdict in logs
```

## Evaluation Script

After each test, run:
```bash
LOG="/tmp/rlp-test-<name>/.claude/ralph-desk/logs/<slug>/debug.log"
echo "=== PLAN ===" && grep '\[PLAN\]' "$LOG"
echo "=== EXEC ===" && grep '\[EXEC\]' "$LOG"
echo "=== VALIDATE ===" && grep '\[VALIDATE\]' "$LOG"
```

Paste output to this session for automated evaluation.