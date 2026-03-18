---
description: "Fresh-context RLP Desk — brainstorm, init, run, status, logs, clean"
argument-hint: "<brainstorm|init|run|status|logs|clean> <slug> [options]"
---

# RLP Desk for Claude Code

**YOU are the leader.** You orchestrate fresh-context workers/verifiers via Agent().

The user invoked: `/rlp-desk $ARGUMENTS`

Parse the first word of `$ARGUMENTS` as the subcommand.

---

## `brainstorm <description>`

Planning phase BEFORE init. Interactively define the contract with the user.

Determine all of the following:
1. **Slug** — short identifier (e.g., `auth-refactor`)
2. **Objective** — what the loop achieves
3. **User Stories** — discrete units with testable acceptance criteria
4. **Iteration Unit** — one worker does per iteration (default: one user story)
5. **Verification Commands** — build, test, lint commands
6. **Completion / Blocked Criteria**
7. **Worker / Verifier Model** — haiku, sonnet, opus
8. **Max Iterations**

Present the contract summary. On approval, offer to run `init`.
Do NOT create files during brainstorm.

---

## `init <slug> [objective]`

Run: `~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>"`
If brainstorm was done, auto-fill PRD and test-spec with the results.

---

## `run <slug> [options]`

**YOU are the leader. Do NOT delegate leadership.**

Options (parse from `$ARGUMENTS`):
- `--max-iter N` (default: 100)
- `--worker-model MODEL` (default: sonnet)
- `--verifier-model MODEL` (default: opus)

### Preparation
1. Validate scaffold: `.claude/ralph-desk/prompts/<slug>.worker.prompt.md` etc.
2. Check sentinels (complete/blocked). Found → tell user `/rlp-desk clean <slug>`.
3. Clean previous `done-claim.json`, `verify-verdict.json`.

### Leader Loop

For each iteration (1 to max_iter):

**① Check sentinels**
```bash
test -f .claude/ralph-desk/memos/<slug>-complete.md  # → done
test -f .claude/ralph-desk/memos/<slug>-blocked.md   # → stop
```

**①½ Prep-stage cleanup**
```bash
rm -f .claude/ralph-desk/memos/<slug>-done-claim.json
rm -f .claude/ralph-desk/memos/<slug>-verify-verdict.json
```

**② Read memory.md** → Stop Status, Next Iteration Contract
- Also read **Completed Stories** → verified work so far
- Also read **Key Decisions** → settled architectural choices

**③ Decide model** (§4 of governance.md)
- Previous iteration failed → upgrade model
- Simple task → downgrade
- User specified → use that

**④ Build worker prompt**
- Read `.claude/ralph-desk/prompts/<slug>.worker.prompt.md`
- Combine with iteration number + memory contract
- Write to `.claude/ralph-desk/logs/<slug>/iter-NNN.worker-prompt.md` (audit trail)

**⑤ Execute Worker via Agent()**
```
Agent(
  description="rlp-desk worker iter-NNN",
  subagent_type="executor",
  model=<worker_model>,
  mode="bypassPermissions",
  prompt=<full worker prompt text>
)
```
- Agent returns synchronously. No polling needed.
- Each Agent() = fresh context. Guaranteed.

**⑥ Read memory.md again** (Worker updated it)
- `stop=continue` → go to ⑧
- `stop=verify` → go to ⑦
- `stop=blocked` → write BLOCKED sentinel, stop

**⑦ Execute Verifier via Agent()**
- Build verifier prompt, write to `iter-NNN.verifier-prompt.md`
```
Agent(
  description="rlp-desk verifier iter-NNN",
  subagent_type="executor",
  model=<verifier_model>,
  mode="bypassPermissions",
  prompt=<full verifier prompt text>
)
```
- Read `verify-verdict.json`:
  - `pass` + `complete` → write COMPLETE sentinel, report done!
  - `fail` + `continue` → read issues (sorted by severity), build Fix Loop contract → go to ⑧
  - `request_info` → Leader reads Verifier's questions, decides outcome (or relays to Worker in next contract) → go to ⑧
  - `blocked` → write BLOCKED sentinel, stop

**⑧ Write result log and report to user, continue loop**
- Write `logs/<slug>/iter-NNN.result.md`:
  - Result status `[leader-measured]`
  - Files changed via `git diff --stat HEAD~1 HEAD` `[git-measured]`
  - Verifier verdict `[leader-measured]`
- Write `status.json`
- Report: iteration N, phase, model used, result

### Circuit Breaker
- context-latest.md unchanged 3 iterations → BLOCKED
- Same acceptance criterion fails 2 consecutive iterations → upgrade model, retry once, then BLOCKED
- 3 consecutive failures on different acceptance criteria → upgrade to opus, retry once, then BLOCKED
- max_iter reached → TIMEOUT, report to user

Track `consecutive_failures` in `status.json` (increment on `fail`, reset on `pass`).

### Important Rules
- Each Agent() = new process = fresh context
- YOU track iteration count
- Write `status.json` after each iteration
- Worker claim ≠ complete. Only YOU write COMPLETE sentinel after verifier pass.

---

## `status <slug>`
Read `.claude/ralph-desk/logs/<slug>/status.json` and display.

## `logs <slug> [N]`
- No N: show latest `iter-*.worker-prompt.md` summary
- With N: read `iter-N.worker-prompt.md` and `iter-N.verifier-prompt.md`

## `clean <slug>`
Remove:
- `.claude/ralph-desk/memos/<slug>-complete.md`
- `.claude/ralph-desk/memos/<slug>-blocked.md`
- `.claude/ralph-desk/memos/<slug>-done-claim.json`
- `.claude/ralph-desk/memos/<slug>-verify-verdict.json`
- `.claude/ralph-desk/logs/<slug>/circuit-breaker.json`

## No args or `help`
```
/rlp-desk brainstorm <description>     Plan before init (interactive)
/rlp-desk init  <slug> [objective]     Create project scaffold
/rlp-desk run   <slug> [--opts]        Run loop (this session = leader)
/rlp-desk status <slug>                Show loop status
/rlp-desk logs  <slug> [N]             Show iteration log
/rlp-desk clean <slug>                 Reset for re-run
```

## Architecture
```
[This session = LEADER]
        │
  Agent()├──▶ [Worker: executor (fresh context)]
        │     └── reads desk files, implements, updates memory
        │
  Agent()└──▶ [Verifier: executor (fresh context)]
              └── reads done-claim, runs checks, writes verdict
```
