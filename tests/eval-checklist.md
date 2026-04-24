# RLP Desk Evaluation Checklist

Run each test in a separate project directory. After completion, paste the results to Claude for evaluation.

---

## Test 1: Agent + per-US verify (default)

```bash
mkdir /tmp/eval-perus && cd /tmp/eval-perus && git init
/rlp-desk brainstorm "Python greeter: greet(name), farewell(name) + pytest"
# Settings: 3 US, per-us verify, worker: sonnet, verifier: opus, max-iter: 10
/rlp-desk run greeter --verify-mode per-us
```

**Pass criteria:**
- [ ] Brainstorm asked about engine, verify-mode, and consensus
- [ ] Verify ran after US-001 completion (per-US)
- [ ] Verify ran after US-002 completion
- [ ] Verify ran after US-003 completion
- [ ] Final ALL verify (full AC check) ran at the end
- [ ] COMPLETE sentinel written
- [ ] `status.json` contains `verified_us` array
- [ ] Leader continued automatically between iterations (no pause)

**Verification commands:**
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

**Pass criteria:**
- [ ] Verify ran only after all US were completed
- [ ] Intermediate iterations used continue (no verify)
- [ ] Single verify at the end → COMPLETE

**Verification commands:**
```bash
cat .claude/ralph-desk/logs/batch-test/status.json | jq '.verify_mode'
ls .claude/ralph-desk/logs/batch-test/iter-*.verifier-prompt.md | wc -l
# batch mode should have only 1 verifier prompt
```

---

## Test 3: tmux basic (run inside tmux)

```bash
# Run inside a tmux session
mkdir /tmp/eval-tmux && cd /tmp/eval-tmux && git init
/rlp-desk init tmux-test "Python counter: increment(), decrement(), get() + pytest"
# Edit PRD with 2 US
/rlp-desk run tmux-test --mode tmux --debug
```

**Pass criteria:**
- [ ] Current window split into panes (Worker/Verifier on the right)
- [ ] Claude TUI visible in Worker pane
- [ ] Instruction delivered automatically (within 30s)
- [ ] Panes remain after completion
- [ ] `debug.log` created

**Verification commands:**
```bash
tmux list-panes -F '#{pane_id} #{pane_current_command}'
cat .claude/ralph-desk/logs/tmux-test/debug.log | tail -10
cat .claude/ralph-desk/logs/tmux-test/status.json
```

---

## Test 4: tmux + per-US verify

```bash
# Run inside tmux
mkdir /tmp/eval-tmux-perus && cd /tmp/eval-tmux-perus && git init
/rlp-desk init tmux-perus "Python math: add(a,b), multiply(a,b), power(a,b) + pytest"
# Edit PRD with 3 US
/rlp-desk run tmux-perus --mode tmux --verify-mode per-us --debug
```

**Pass criteria:**
- [ ] Claude appeared in Verifier pane after each US completion
- [ ] Verifier checked only the scoped US acceptance criteria (scope in prompt)
- [ ] Final ALL verify ran at the end
- [ ] `debug.log` recorded per-US verify flow

**Verification commands:**
```bash
cat .claude/ralph-desk/logs/tmux-perus/status.json | jq '.verified_us'
cat .claude/ralph-desk/logs/tmux-perus/debug.log | grep "us_id"
```

---

## Test 5: tmux rejection outside tmux

```bash
# Run OUTSIDE tmux (new terminal or non-tmux session)
cd /tmp/eval-tmux
/rlp-desk run tmux-test --mode tmux
```

**Pass criteria:**
- [ ] Error message: "tmux mode requires running inside a tmux session"
- [ ] Exit code 1
- [ ] LLM did not attempt workarounds

---

## Test 6: codex worker (requires codex CLI)

```bash
mkdir /tmp/eval-codex && cd /tmp/eval-codex && git init
/rlp-desk init codex-test "Python fizzbuzz: fizzbuzz(n) returns list + pytest"
/rlp-desk run codex-test --worker-engine codex --worker-codex-model gpt-5.5
```

**Pass criteria:**
- [ ] Worker executed via codex exec (using Bash)
- [ ] Verifier executed via claude (using Agent)
- [ ] `status.json` contains `worker_engine: "codex"`

**Verification commands:**
```bash
cat .claude/ralph-desk/logs/codex-test/status.json | jq '.worker_engine'
```

---

## Test 7: consensus verify (requires codex CLI)

```bash
mkdir /tmp/eval-consensus && cd /tmp/eval-consensus && git init
/rlp-desk init consensus-test "Python validator: is_palindrome(s) + pytest"
/rlp-desk run consensus-test --verify-consensus
```

**Pass criteria:**
- [ ] Claude verifier ran after Worker completion
- [ ] Codex verifier ran after Claude verifier
- [ ] Both passed → COMPLETE
- [ ] `status.json` contains `claude_verdict` and `codex_verdict` fields

**Verification commands:**
```bash
cat .claude/ralph-desk/logs/consensus-test/status.json | jq '.claude_verdict, .codex_verdict, .verify_consensus'
```

---

## Test 8: brainstorm questions

```bash
/rlp-desk brainstorm "any description"
```

**Pass criteria:**
- [ ] Engine question asked (claude/codex)
- [ ] Verify mode question asked (per-us/batch)
- [ ] Verify consensus question asked
- [ ] User allowed to choose (no auto-decisions)

---

## Submitting Results

After completing tests, run the following in each test directory:

```bash
echo "=== STATUS ===" && cat .claude/ralph-desk/logs/<slug>/status.json
echo "=== SENTINEL ===" && cat .claude/ralph-desk/memos/<slug>-complete.md 2>/dev/null || echo "NOT COMPLETE"
echo "=== DEBUG ===" && tail -20 .claude/ralph-desk/logs/<slug>/debug.log 2>/dev/null || echo "NO DEBUG LOG"
echo "=== VERIFIER PROMPTS ===" && ls .claude/ralph-desk/logs/<slug>/iter-*.verifier*.md 2>/dev/null | wc -l
```

Paste the output to Claude for automated evaluation.
