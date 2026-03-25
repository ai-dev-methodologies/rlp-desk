# Getting Started

This guide walks you through your first RLP Desk loop using a simple Python calculator example.

## Prerequisites

- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and authenticated
- A terminal with bash or zsh

## Step 1: Install RLP Desk

```bash
npm install -g @ai-dev-methodologies/rlp-desk
```

Or without npm:

```bash
curl -sSL https://raw.githubusercontent.com/ai-dev-methodologies/rlp-desk/main/install.sh | bash
```

This installs three files:
- `~/.claude/commands/rlp-desk.md` — the slash command
- `~/.claude/ralph-desk/init_ralph_desk.zsh` — the scaffold generator
- `~/.claude/ralph-desk/governance.md` — the protocol document

## Step 2: Create a Project

```bash
mkdir calculator-demo && cd calculator-demo
git init
```

## Step 3: Brainstorm

Open Claude Code and run:

```
/rlp-desk brainstorm "Python calculator module with add, subtract, multiply, divide functions and pytest tests"
```

The brainstorm phase interactively determines:

| Item | Example |
|------|---------|
| **Slug** | `loop-test` |
| **Objective** | Implement calc.py + test_calc.py |
| **User Stories** | US-001: calculator functions (Given/When/Then AC format) |
| **Task Type & Risk** | code, LOW |
| **Iteration Unit** | One user story per iteration |
| **Verification** | `python3 -m pytest test_calc.py -v` |
| **Models** | Worker: sonnet, Verifier: opus |
| **Ambiguity Gate (IL-2)** | AC quality score ≥ 6 required to proceed |
| **Max Iterations** | 10 |

On approval, brainstorm offers to run `init` automatically.

## Step 4: Initialize (if not done in brainstorm)

```
/rlp-desk init loop-test "Python calculator with tests"
```

This creates the scaffold:

```
.claude/ralph-desk/
├── prompts/
│   ├── loop-test.worker.prompt.md
│   └── loop-test.verifier.prompt.md
├── context/
│   └── loop-test-latest.md
├── memos/
│   └── loop-test-memory.md
├── plans/
│   ├── prd-loop-test.md
│   └── test-spec-loop-test.md
└── logs/loop-test/
```

## Step 5: Customize the PRD

Edit `.claude/ralph-desk/plans/prd-loop-test.md` to define your user stories and acceptance criteria. See [`examples/calculator/`](../examples/calculator/.claude/ralph-desk/plans/prd-loop-test.md) for a complete example.

Key sections:
- **User Stories** with Given/When/Then acceptance criteria, Task Type, and Risk Level
- **Boundary Cases** for each US
- **Verification Layers** (L1-L4 based on risk level per governance §1c)
- **Technical Constraints** (e.g., "Python 3 + pytest only")
- **Done When** conditions (must reference Evidence Gate §1b)

## Step 6: Define the Test Spec

Edit `.claude/ralph-desk/plans/test-spec-loop-test.md` to specify verification commands:

```markdown
## Verification Commands
### Test
python3 -m pytest test_calc.py -v

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| calc.py exists | automated | test -f calc.py |
| All tests pass | automated | python3 -m pytest test_calc.py -v |
```

## Step 7: Run the Loop

```
/rlp-desk run loop-test
```

What happens:

1. **Iteration 1**: Worker reads the PRD, implements `calc.py` (US-001), updates memory
2. **Iteration 2**: Worker reads memory, implements `test_calc.py` (US-002), writes done-claim
3. **Iteration 3**: Verifier runs all checks, writes pass verdict
4. Leader writes COMPLETE sentinel, reports success

You'll see status updates after each iteration:

```
Iteration 1 | Worker (sonnet) | US-001 complete, continuing
Iteration 2 | Worker (sonnet) | All stories done, requesting verification
Iteration 3 | Verifier (opus) | PASS — all criteria met
✓ COMPLETE
```

## Step 8: Check Status

At any point during or after a run:

```
/rlp-desk status loop-test
/rlp-desk logs loop-test        # latest iteration
/rlp-desk logs loop-test 2      # specific iteration
```

## Step 9: Re-run (if needed)

If you want to run the loop again:

```
/rlp-desk clean loop-test
/rlp-desk run loop-test
```

`clean` removes runtime artifacts (sentinels, claims, verdicts) but preserves the PRD, test spec, and prompts.

## Tips

- **Start small**: One or two user stories for your first loop
- **Use Given/When/Then**: "Given 10 and 5, When add, Then 15" — not "function works well"
- **Set risk levels**: LOW for docs/config, MEDIUM for features, HIGH for deploys, CRITICAL for security/finance
- **Include verification commands**: The verifier needs concrete commands to run
- **One story per iteration**: Each worker should do one bounded action
- **Check logs when stuck**: `logs/<slug>/iter-NNN.worker-prompt.md` shows exactly what the worker received
- **Review done-claims**: Worker's `execution_steps` show exactly what was done and in what order
- **Review verdict reasoning**: Verifier's `reasoning` shows why each judgment was made
