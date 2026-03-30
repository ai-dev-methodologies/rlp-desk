# CLAUDE.md — rlp-desk Project Instructions

## Mandatory Rules

### Commit & Publish Gate (ABSOLUTE — no exceptions)
- **NEVER commit without explicit user approval.** Always show the diff summary and ask before `git commit`.
- **NEVER run `npm publish` without explicit user approval.** Always confirm version number and ask before publishing.
- **NEVER push to remote without explicit user approval.**
- These rules apply regardless of context — autopilot, ralph, team, or any execution mode.

### Run Command Gate (ABSOLUTE — no exceptions)
- After brainstorm or init, present run command options with explanations and ONE recommendation.
- **NEVER auto-run the loop.** The user MUST copy and paste the run command themselves.
- **NEVER ask "shall I run?" or offer to execute.** Just present options and STOP.
- This ensures the user consciously chooses execution parameters before committing compute resources.

### Self-Verification Gate (ABSOLUTE — no exceptions)
- When `src/commands/rlp-desk.md`, `src/governance.md`, or `src/scripts/init_ralph_desk.zsh` is changed, **MUST run 3 self-verification scenarios before commit**:
  1. **LOW risk** (e.g., simple function) — L1+L3 only, L2/L4 N/A
  2. **MEDIUM risk** (e.g., feature with file I/O) — L1+L2+L3, real integration
  3. **CRITICAL risk** (e.g., security/crypto) — L1+L2+L3+security check, L3 error-path E2E
- Each scenario: Worker (with execution_steps) → Verifier (with reasoning, 5 categories) → PASS
- All 3 must PASS before commit is allowed. No exceptions, no "scaffold-only" verification.
- If any scenario FAIL: fix the issue, re-run the failing scenario, then re-verify all 3.

### Local File Sync (ABSOLUTE — no exceptions)
After every commit that changes ANY src/ file, sync ALL distributable files to local install. Not just the changed ones — ALL of them. Then verify with `diff -q`.

**Runtime files (always sync):**
```
src/commands/rlp-desk.md        → ~/.claude/commands/rlp-desk.md
src/governance.md               → ~/.claude/ralph-desk/governance.md
src/model-upgrade-table.md      → ~/.claude/ralph-desk/model-upgrade-table.md
src/scripts/init_ralph_desk.zsh → ~/.claude/ralph-desk/init_ralph_desk.zsh
src/scripts/run_ralph_desk.zsh  → ~/.claude/ralph-desk/run_ralph_desk.zsh
src/scripts/lib_ralph_desk.zsh  → ~/.claude/ralph-desk/lib_ralph_desk.zsh
```

**Reference docs (always sync):**
```
README.md                       → ~/.claude/ralph-desk/README.md
install.sh                      → ~/.claude/ralph-desk/install.sh
docs/architecture.md            → ~/.claude/ralph-desk/docs/architecture.md
docs/getting-started.md         → ~/.claude/ralph-desk/docs/getting-started.md
docs/protocol-reference.md      → ~/.claude/ralph-desk/docs/protocol-reference.md
docs/TODO-verification-next.md  → ~/.claude/ralph-desk/docs/TODO-verification-next.md
docs/internal/*                 → ~/.claude/ralph-desk/docs/internal/
docs/blueprints/*               → ~/.claude/ralph-desk/docs/blueprints/
```

**Verification (mandatory after sync):**
```bash
diff -q src/commands/rlp-desk.md ~/.claude/commands/rlp-desk.md
diff -q src/governance.md ~/.claude/ralph-desk/governance.md
diff -q src/scripts/init_ralph_desk.zsh ~/.claude/ralph-desk/init_ralph_desk.zsh
diff -q src/scripts/run_ralph_desk.zsh ~/.claude/ralph-desk/run_ralph_desk.zsh
diff -q src/scripts/lib_ralph_desk.zsh ~/.claude/ralph-desk/lib_ralph_desk.zsh
diff -q README.md ~/.claude/ralph-desk/README.md
```
All must show no output (identical). Any diff = sync incomplete.

### Release Notes Rule
- Release notes MUST only contain **user-facing features and fixes**.
- NEVER include CLAUDE.md changes, internal dev process rules, or review history in release notes.
- CLAUDE.md is for AI working on this repo, NOT a feature of the npm-distributed rlp-desk.


### Release Workflow
1. All changes committed and pushed
2. `npm version patch|minor|major --no-git-tag-version`
3. Commit version bump
4. Push to main
5. `gh release create vX.Y.Z` with release notes
6. `npm publish`
7. Local file sync
- Steps 1-7 require user approval at each stage.

## Review Process
- Use ralplan (Planner→Architect→Critic) + codex review for governance/template changes
- codex review must reach 0 issues before merge
- E2E verification with real Worker+Verifier execution required

## Key Architecture
- Source files: `src/commands/rlp-desk.md`, `src/governance.md`, `src/scripts/init_ralph_desk.zsh`
- Governance sections: §1a-§1f (Iron Laws through Traceability), §7¾ (Architecture Escalation)
- §1f (Execution & Judgment Traceability) is always-on, not flag-gated
- `--with-self-verification` enables post-campaign analysis only
