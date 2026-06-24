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
After every commit that changes ANY src/ file, sync ALL distributable files to local install. Not just the changed ones — ALL of them. Then verify with the **banner-aware procedure below** (NOT naive `diff -q` / `diff -rq` — post-v0.12.0 installed files have line-1 banners that naive diff treats as drift; see §4.5 verification recipe).

**Runtime files (always sync via `npm install` / postinstall.js — Node canonical):**
```
src/commands/rlp-desk.md        → ~/.claude/commands/rlp-desk.md
src/governance.md               → ~/.claude/ralph-desk/governance.md
src/model-upgrade-table.md      → ~/.claude/ralph-desk/model-upgrade-table.md
src/node/**                     → ~/.claude/ralph-desk/node/   (recursive, v0.12.0+)
src/scripts/run_ralph_desk.zsh  → ~/.claude/ralph-desk/run_ralph_desk.zsh   (v0.14.0+, see below)
src/scripts/lib_ralph_desk.zsh  → ~/.claude/ralph-desk/lib_ralph_desk.zsh   (v0.14.0+)
src/scripts/init_ralph_desk.zsh → ~/.claude/ralph-desk/init_ralph_desk.zsh  (v0.14.0+)
```

**zsh leader is the production `--mode tmux` backend (v0.14.0 inversion — NOT opt-in)**:
`src/scripts/{run,lib,init}_ralph_desk.zsh` are **synced by `postinstall.js`** to
`~/.claude/ralph-desk/{run,lib,init}_ralph_desk.zsh` (flat path), AND ship via
`bash install.sh` (curl). The Node CLI does **not** run campaigns itself for
`--mode tmux`: `src/node/run.mjs` shells out to
`~/.claude/ralph-desk/run_ralph_desk.zsh` (run.mjs:296) and hard-errors if it is
missing ("run `npm install` to sync"). So the zsh leader is canonical, not legacy.
The contract is pinned by `tests/node/us008-cli-entrypoint.test.mjs` AC8.1:
"postinstall installs the Node runtime **AND** the zsh tmux runner under
`~/.claude/ralph-desk`". (History: a pre-v0.14.0 design made the Node leader the
only `--mode tmux` backend and had postinstall *delete* the zsh files; that broke
production tmux flows — no heartbeat / copy-mode guard / prompt-stall in Node — so
v0.14.0 restored the zsh runner as canonical. Any doc text saying "npm install
removes the zsh wrappers" is describing that obsolete design.) v0.13.0 `.rlp-desk/`
path migration is mirrored in these scripts.

**Sync consequence:** a commit that changes only a `src/scripts/*_ralph_desk.zsh`
file STILL requires local sync (it is a runtime file). The canonical channel is
`npm install` / postinstall (files are `chmod 0o444` + banner-headed — never edit
the installed copies). Verify with the banner-aware recipe in §4.5 (for the
shebanged `.zsh`, strip the line-2 banner: `sed '/^# .*DO NOT EDIT/d' <installed>`
then diff against `src/scripts/<file>.zsh`).

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
docs/rlp-desk/signal-protocol.md             → ~/.claude/ralph-desk/docs/rlp-desk/signal-protocol.md
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
0. **Preflight (auto, all BLOCKING)** per `docs/plans/v0.15.4-release-runbook.md` §1: A1 `gh auth status` / A2 `npm publish --dry-run` (auth+scope; pre-bump tolerates EPUBLISHCONFLICT) / A3 sv-gate-fast / A4 `npm run test:node` / A5 trigger-file diff oracle (anchor uses commit SHA, not git tag — `npm version --no-git-tag-version` policy means `vX.Y.Z` tags do not exist locally).
1. All changes committed and pushed
2. `npm version patch|minor|major --no-git-tag-version`
2a. **A2' post-bump dry-run** — re-run `npm publish --dry-run`; strict exit-0 required for the new version.
3. Commit version bump
4. Push to main
5. `gh release create vX.Y.Z` with release notes
6. `npm publish`
7. Local file sync (banner-aware verification per §4.5)
7a. **Post-publish verify (P1-P5, auto, all BLOCKING)** per runbook §3: P1 fresh `npm install` / P2 banner-strip diff (3 ref files) / P3 recursive Node sync (banner-aware per-file, NOT `diff -rq`) / P4 chmod 0o444 verify / P5 `npm view @ai-dev-methodologies/rlp-desk@vX.Y.Z version` (allow single retry on registry propagation lag).
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
- **Lifecycle observability (v0.15.4+)**: `src/node/util/lifecycle-metrics.mjs` is the B4 emitter. Gated by `RLP_LIFECYCLE_METRICS=1`. Emit sites in `src/node/runner/campaign-main-loop.mjs` (Node leader) and `src/scripts/lib_ralph_desk.zsh` `log_lifecycle_metric` (zsh leader).
- **Failure modes atlas**: `docs/rlp-desk/failure-modes.md` is the canonical FMEA-style reference for known race patterns (done-claim, sentinel, B3 stage 2). New failure modes are added there with `Symptom / Root cause / Detection / Recovery / Reference` schema.
- **Release runbook (v0.15.4+)**: `docs/plans/v0.15.4-release-runbook.md` is the executable contract for release pipeline (preflight A1-A5, steps 1-7 with 4 user gates, post-verify P1-P5). Supersedes ad-hoc release procedure.
