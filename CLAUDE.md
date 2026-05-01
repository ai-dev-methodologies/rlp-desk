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

**Runtime files (always sync via `npm install` / postinstall.js — Node canonical):**
```
src/commands/rlp-desk.md        → ~/.claude/commands/rlp-desk.md
src/governance.md               → ~/.claude/ralph-desk/governance.md
src/model-upgrade-table.md      → ~/.claude/ralph-desk/model-upgrade-table.md
src/node/**                     → ~/.claude/ralph-desk/node/   (recursive, v0.12.0+)
```

**Legacy shell wrappers (synced ONLY via `bash install.sh` curl path)**:
`src/scripts/{init,run,lib}_ralph_desk.zsh` ship in the npm tarball but are
**not** installed by `postinstall.js` (Node-canonical design from v5.7+;
`npm install` actively removes them — see `tests/node/us008-cli-entrypoint.test.mjs:47`
for the contract). They remain in the source tree for shell-only environments
that install via `bash install.sh` (curl from GitHub). v0.13.0 path migration
(`.rlp-desk/`) is mirrored in those scripts so legacy shell users get the same
behavior. Treat zsh wrappers as opt-in, not part of the canonical sync.

**v0.12.0+ note (v5.7 §4.10)**: installed files are write-protected (`chmod 0o444`)
+ banner-headed (`<!-- DO NOT EDIT ... -->` for `.md`, `# ...` for shell, `// ...`
for `.mjs`/`.js`). Re-running `npm install rlp-desk` (or `bash install.sh`) is the
canonical channel — never edit installed files directly. For temporary debug see
`~/.claude/ralph-desk/UNLOCK.md`.

**Reference docs (always sync):**
```
README.md                       → ~/.claude/ralph-desk/README.md
install.sh                      → ~/.claude/ralph-desk/install.sh
docs/rlp-desk/architecture.md            → ~/.claude/ralph-desk/docs/rlp-desk/architecture.md
docs/rlp-desk/getting-started.md         → ~/.claude/ralph-desk/docs/rlp-desk/getting-started.md
docs/rlp-desk/protocol-reference.md      → ~/.claude/ralph-desk/docs/rlp-desk/protocol-reference.md
docs/rlp-desk/TODO-verification-next.md  → ~/.claude/ralph-desk/docs/rlp-desk/TODO-verification-next.md
docs/rlp-desk/multi-mission-orchestration.md → ~/.claude/ralph-desk/docs/rlp-desk/multi-mission-orchestration.md
docs/rlp-desk/internal/*                 → ~/.claude/ralph-desk/docs/rlp-desk/internal/
docs/rlp-desk/blueprints/*               → ~/.claude/ralph-desk/docs/rlp-desk/blueprints/
docs/rlp-desk/plans/*                    → ~/.claude/ralph-desk/docs/rlp-desk/plans/
```

**Verification (mandatory after sync — v5.7 §4.5)**:

Post-v0.12.0, installed files have an injected banner (line 1 for `.md`/`.mjs`/`.js`,
line 2 for shebanged `.zsh`/`.sh`) plus `chmod 0o444`. A naive `diff -q` will report
a banner-line difference. Use the banner-aware verification below instead.

```bash
# 1. Banner + chmod sanity (every installed runtime file)
for f in ~/.claude/commands/rlp-desk.md \
         ~/.claude/ralph-desk/governance.md \
         ~/.claude/ralph-desk/node/run.mjs ; do
  test -f "$f" || { echo "MISSING: $f"; exit 1; }
  head -2 "$f" | grep -qE 'DO NOT EDIT' || { echo "NO BANNER: $f"; exit 1; }
  [[ "$(stat -f %Lp "$f" 2>/dev/null || stat -c %a "$f")" == "444" ]] \
    || echo "WARN: $f not 0o444 (filesystem may not honor chmod)"
done

# 2. Body equality (strip banner before diff)
strip_banner() { tail -n +2 "$1" | grep -v -E '^(<!-- |# |// )DO NOT EDIT' || true; }
diff <(cat src/governance.md) <(strip_banner ~/.claude/ralph-desk/governance.md) | head

# 3. Recursive Node tree check (v5.7 §4.5)
diff -rq src/node ~/.claude/ralph-desk/node | grep -v 'DO NOT EDIT'
```

All checks must report no body difference. Banner + chmod are install artifacts;
the source of truth remains the `src/` tree.

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
