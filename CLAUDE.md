# CLAUDE.md — rlp-desk Project Instructions

## Mandatory Rules

### Commit & Publish Gate (ABSOLUTE — no exceptions)
- **NEVER commit without explicit user approval.** Always show the diff summary and ask "커밋할까요?" before `git commit`.
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

### Local File Sync
- After every commit that changes `src/commands/rlp-desk.md`, `src/governance.md`, or `src/scripts/init_ralph_desk.zsh`, copy the updated files to local install:
  - `src/commands/rlp-desk.md` → `~/.claude/commands/rlp-desk.md`
  - `src/governance.md` → `~/.claude/ralph-desk/governance.md`
  - `src/scripts/init_ralph_desk.zsh` → `~/.claude/ralph-desk/init_ralph_desk.zsh`

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
