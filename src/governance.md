# Ralph Desk Governance v2

Fresh-context independent verification protocol.
The Leader orchestrates, while Worker/Verifier run in isolated fresh contexts every iteration.

---

## 1. Core Principles

- **Fresh context per iteration**: Worker/Verifier start fresh every time. No prior conversation.
- **Filesystem = memory**: State exists only on the filesystem (PRD, memory, context, memos).
- **Worker claim ≠ complete**: A Worker's DONE is merely a claim. The Verifier must independently verify before it's confirmed.
- **Verifier is independent**: The Verifier judges based on evidence alone, without knowledge of the Worker's reasoning process.
- **Sentinels are Leader-owned**: Only the Leader writes COMPLETE/BLOCKED sentinels.
- **Claude models only**: haiku, sonnet, opus.

## 2. Roles

### Leader (current session)
- Operates the loop, selects models, controls flow
- Dispatches Worker/Verifier via Agent()
- Reads memory to assess state, writes sentinels
- **Does NOT write or execute code**

### Worker (fresh context)
- Performs one bounded action per iteration
- Updates context and memory (so the next fresh worker can continue)
- Writes done-claim.json when claiming completion

### Verifier (fresh context)
- Independently verifies Worker's done claim
- Identifies scope via `git diff --name-only` — reads changed files and related imports only
- Runs commands directly to collect fresh evidence
- Campaign Memory is for orientation only — not the source of truth
- Writes verdict (`pass` | `fail` | `request_info`) — if uncertain, use `request_info` with specific questions; Leader decides
- Delegates deterministic checks (type hints, linting, security) to tools defined in test-spec
- Focuses on AC verification, semantic review, and smoke tests
- **Must NEVER modify code or write sentinel files**

## 3. State Flow

```
RUNNING → DONE_CLAIMED → VERIFYING → COMPLETE | CONTINUE | BLOCKED
```

## 4. Model Routing (Claude only)

| Role | Default Model | Override Criteria |
|------|---------------|-------------------|
| Worker (simple) | haiku | Single file, clear change |
| Worker (standard) | sonnet | Most tasks (default) |
| Worker (complex) | opus | Architecture changes, multi-file, prior iteration failure |
| Verifier | opus | Independent verification requires thoroughness |
| Verifier (lightweight) | sonnet | Simple, well-defined checks only |

The Leader decides each iteration. Decision criteria:
- Previous iteration failed → upgrade model
- Simple repetitive task → downgrade model
- User explicitly specified → use as given

## 5. Execution: Unified Agent() Approach

All environments (Claude Code, OpenCode) use the same Agent tool.

```
# Worker
Agent(
  subagent_type="executor",
  model="sonnet",
  prompt=worker_prompt,
  mode="bypassPermissions"
)

# Verifier
Agent(
  subagent_type="executor",
  model="sonnet",
  prompt=verifier_prompt,
  mode="bypassPermissions"
)
```

Characteristics:
- Each call = fresh context (new subprocess)
- Synchronous return. No polling or signal files needed.
- After Agent completes, read memory.md to assess state.
- No tmux required.
- Monitor in real-time via ctrl+o (Claude Code UI).
- Prompts are still logged to logs/ for audit trail.

## 6. File Structure

### User-level (central)
```
~/.claude/ralph-desk/
├── init_ralph_desk.zsh        # Scaffold generator (automation)
├── governance.md              # This document
└── templates/                 # Prompt templates
```

### Project-local
```
.claude/ralph-desk/
├── prompts/
│   ├── <slug>.worker.prompt.md      # Worker base prompt
│   └── <slug>.verifier.prompt.md    # Verifier base prompt
├── context/
│   └── <slug>-latest.md             # Current frontier (Worker updates)
├── memos/
│   ├── <slug>-memory.md             # Campaign memory (Worker updates)
│   ├── <slug>-done-claim.json       # Worker's completion claim (runtime)
│   ├── <slug>-verify-verdict.json   # Verifier's verdict (runtime)
│   ├── <slug>-complete.md           # SENTINEL (Leader only)
│   └── <slug>-blocked.md            # SENTINEL (Leader only)
├── plans/
│   ├── prd-<slug>.md                # PRD (shared contract)
│   └── test-spec-<slug>.md          # Verification criteria
└── logs/<slug>/
    ├── iter-NNN.worker-prompt.md    # Audit trail prompt copy
    ├── iter-NNN.verifier-prompt.md  # Audit trail prompt copy
    ├── iter-NNN.result.md           # Iteration result (leader-measured + git-measured)
    └── status.json                  # Leader's loop state
```

## 7. Leader Loop Protocol

```
for iteration in 1..max_iter:

  ① Check sentinels
     - complete.md exists → stop
     - blocked.md exists → stop

  ①½ Prep-stage cleanup
     - Delete done-claim.json if exists
     - Delete verify-verdict.json if exists

  ② Read memory.md → check Stop Status, Next Iteration Contract
     - Also parse Completed Stories (verified work so far)
     - Also parse Key Decisions (settled architectural choices)

  ③ Select model
     - Default or situational decision (see §4)
     - Context unchanged for 3 consecutive iterations → BLOCKED

  ④ Build Worker prompt
     - Base prompt + iteration number + contract from memory
     - Log to logs/<slug>/iter-NNN.worker-prompt.md

  ⑤ Execute Worker: Agent(subagent_type="executor", model=selected, prompt=prompt)
     - Synchronous return, wait for completion

  ⑥ Read memory.md again → check Worker's updated state
     - "continue" → go to ⑧
     - "verify"   → go to ⑦
     - "blocked"  → write BLOCKED sentinel, stop

  ⑦ Execute Verifier
     - Build prompt → log to logs/<slug>/iter-NNN.verifier-prompt.md
     - Agent(subagent_type="executor", model=selected, prompt=prompt)
     - Read verify-verdict.json:
       • pass + complete → write COMPLETE sentinel, stop
       • fail + continue → go to ⑧
       • blocked → write BLOCKED sentinel, stop

  ⑧ Write iter-NNN.result.md to logs/<slug>/ (result status + git diff --stat)
     Update status.json, report to user, continue to next iteration
```

## 7½. Fix Loop Protocol

When the Verifier returns `fail`, the Leader runs the Fix Loop before issuing the next Worker contract:

1. **Read issues** from `verify-verdict.json` — sort by severity (`critical` → `major` → `minor`)
2. **Build fix contract** — include each issue as a numbered task with criterion reference
   - `fix_hint` (if present) is passed as `(suggestion, non-authoritative)` — Worker may ignore
3. **Traceability rule**: "Only changes that resolve a listed issue are allowed — every change must be justified by the issue it addresses"
4. **Update status.json** — increment `consecutive_failures`; reset to 0 on any `pass`

The `consecutive_failures` counter is maintained by the Leader in `status.json`.

**Fix contract format:**
```
Fix issues from Verifier verdict (iter-NNN):

1. [critical] US-002 AC3: <description> — fix_hint: (suggestion, non-authoritative) <hint>
2. [major] US-001 AC1: <description>

Traceability: only changes that resolve a listed issue are allowed.
Every change must be justified by the issue it addresses.
```

## 8. Circuit Breaker

| Condition | Verdict |
|-----------|---------|
| context-latest.md unchanged for 3 consecutive iterations | BLOCKED |
| Same acceptance criterion fails 2 consecutive iterations | Upgrade model, retry once; if still failing → BLOCKED |
| 3 consecutive failures on different acceptance criteria | Upgrade to opus, retry once; if still failing → BLOCKED |
| max_iter reached | TIMEOUT (report to user) |

The Leader tracks `consecutive_failures` in `status.json`. "Same error" means the same acceptance criterion fails in two consecutive Verifier verdicts.

## 9. Change Policy

- Changes to the shared workflow → modify this document
- Project-specific objectives/criteria → modify project-local files
- Init script changes → modify init_ralph_desk.zsh
