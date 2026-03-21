# RLP Desk Evaluation Checklist

Run each test in a separate project directory. After completion, paste the results to Claude for evaluation.

---

## Test 1: Agent + per-US verify (기본)

```bash
mkdir /tmp/eval-perus && cd /tmp/eval-perus && git init
/rlp-desk brainstorm "Python greeter: greet(name), farewell(name) + pytest"
# Settings: 3 US, per-us verify, worker: sonnet, verifier: opus, max-iter: 10
/rlp-desk run greeter --verify-mode per-us
```

**평가 기준:**
- [ ] Brainstorm이 engine, verify-mode, consensus 질문했는가
- [ ] US-001 완료 후 verify 실행됐는가 (per-US)
- [ ] US-002 완료 후 verify 실행됐는가
- [ ] US-003 완료 후 verify 실행됐는가
- [ ] 마지막에 ALL verify (전체 AC 검증) 실행됐는가
- [ ] COMPLETE sentinel 작성됐는가
- [ ] status.json에 verified_us 배열이 있는가
- [ ] Leader가 iteration 사이에 멈추지 않고 자동 진행했는가

**확인 명령어:**
```bash
cat .claude/ralph-desk/logs/greeter/status.json | jq '.verified_us, .verify_mode'
cat .claude/ralph-desk/memos/greeter-complete.md
ls .claude/ralph-desk/logs/greeter/iter-*.verifier-prompt.md | wc -l
```

---

## Test 2: Agent + batch verify

```bash
mkdir /tmp/eval-batch && cd /tmp/eval-batch && git init
/rlp-desk init batch-test "Python adder: add(a,b), subtract(a,b) + pytest"
# Edit PRD manually with 2 US, then:
/rlp-desk run batch-test --verify-mode batch
```

**평가 기준:**
- [ ] Worker가 모든 US 완료 후에만 verify 실행됐는가
- [ ] 중간 iteration에 verify 없이 continue만 했는가
- [ ] 마지막에 한번 verify → COMPLETE

**확인 명령어:**
```bash
cat .claude/ralph-desk/logs/batch-test/status.json | jq '.verify_mode'
ls .claude/ralph-desk/logs/batch-test/iter-*.verifier-prompt.md | wc -l
# batch면 verifier prompt 1개만 있어야 함
```

---

## Test 3: tmux 기본 (tmux 안에서)

```bash
# tmux 안에서 실행
mkdir /tmp/eval-tmux && cd /tmp/eval-tmux && git init
/rlp-desk init tmux-test "Python counter: increment(), decrement(), get() + pytest"
# Edit PRD with 2 US
/rlp-desk run tmux-test --mode tmux --debug
```

**평가 기준:**
- [ ] 현재 window에서 pane split 됐는가 (오른쪽에 Worker/Verifier)
- [ ] Worker pane에 claude TUI가 보이는가
- [ ] instruction이 자동 전달됐는가 (30초 내)
- [ ] 완료 후 pane이 남아있는가
- [ ] debug.log가 생성됐는가

**확인 명령어:**
```bash
tmux list-panes -F '#{pane_id} #{pane_current_command}'
cat .claude/ralph-desk/logs/tmux-test/debug.log | tail -10
cat .claude/ralph-desk/logs/tmux-test/status.json
```

---

## Test 4: tmux + per-US verify

```bash
# tmux 안에서
mkdir /tmp/eval-tmux-perus && cd /tmp/eval-tmux-perus && git init
/rlp-desk init tmux-perus "Python math: add(a,b), multiply(a,b), power(a,b) + pytest"
# Edit PRD with 3 US
/rlp-desk run tmux-perus --mode tmux --verify-mode per-us --debug
```

**평가 기준:**
- [ ] 매 US 완료 후 Verifier pane에 claude가 뜨는가
- [ ] Verifier가 해당 US의 AC만 검증하는가 (prompt에 scope 명시)
- [ ] 마지막에 ALL verify가 실행되는가
- [ ] debug.log에 per-US verify 흐름이 기록되는가

**확인 명령어:**
```bash
cat .claude/ralph-desk/logs/tmux-perus/status.json | jq '.verified_us'
cat .claude/ralph-desk/logs/tmux-perus/debug.log | grep "us_id"
```

---

## Test 5: tmux 밖 거부

```bash
# tmux 밖에서 실행 (새 터미널 또는 tmux 없는 세션)
cd /tmp/eval-tmux
/rlp-desk run tmux-test --mode tmux
```

**평가 기준:**
- [ ] "ERROR: tmux mode requires running inside a tmux session" 출력
- [ ] exit code 1
- [ ] LLM이 우회 시도하지 않고 멈췄는가

---

## Test 6: codex worker (codex 설치 필요)

```bash
mkdir /tmp/eval-codex && cd /tmp/eval-codex && git init
/rlp-desk init codex-test "Python fizzbuzz: fizzbuzz(n) returns list + pytest"
/rlp-desk run codex-test --worker-engine codex --codex-model gpt-5.4
```

**평가 기준:**
- [ ] Worker가 codex exec로 실행됐는가 (Bash 사용)
- [ ] Verifier는 claude(Agent)로 실행됐는가
- [ ] status.json에 worker_engine: "codex"가 있는가

**확인 명령어:**
```bash
cat .claude/ralph-desk/logs/codex-test/status.json | jq '.worker_engine'
```

---

## Test 7: consensus verify (codex 설치 필요)

```bash
mkdir /tmp/eval-consensus && cd /tmp/eval-consensus && git init
/rlp-desk init consensus-test "Python validator: is_palindrome(s) + pytest"
/rlp-desk run consensus-test --verify-consensus
```

**평가 기준:**
- [ ] Worker 완료 후 claude verifier 실행
- [ ] 이어서 codex verifier 실행
- [ ] 둘 다 pass → COMPLETE
- [ ] status.json에 claude_verdict, codex_verdict 필드 있는가

**확인 명령어:**
```bash
cat .claude/ralph-desk/logs/consensus-test/status.json | jq '.claude_verdict, .codex_verdict, .verify_consensus'
```

---

## Test 8: brainstorm 질문 확인

```bash
/rlp-desk brainstorm "any description"
```

**평가 기준:**
- [ ] Engine 질문 (claude/codex) 나오는가
- [ ] Verify mode 질문 (per-us/batch) 나오는가
- [ ] Verify consensus 질문 나오는가
- [ ] 사용자가 선택할 수 있는가 (자동 결정 안 하는가)

---

## 평가 제출 방법

테스트 완료 후 아래 정보를 Claude에게 제출:

```bash
# 각 테스트 디렉토리에서 실행
echo "=== STATUS ===" && cat .claude/ralph-desk/logs/<slug>/status.json
echo "=== SENTINEL ===" && cat .claude/ralph-desk/memos/<slug>-complete.md 2>/dev/null || echo "NOT COMPLETE"
echo "=== DEBUG ===" && tail -20 .claude/ralph-desk/logs/<slug>/debug.log 2>/dev/null || echo "NO DEBUG LOG"
echo "=== VERIFIER PROMPTS ===" && ls .claude/ralph-desk/logs/<slug>/iter-*.verifier*.md 2>/dev/null | wc -l
```

이 출력을 붙여넣으면 평가합니다.
