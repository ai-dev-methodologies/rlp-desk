# rlp-desk CI Setup (v5.7 §4.25)

> SV gate is a mechanical contract: every PR touching `src/node/**`, `src/scripts/**`, `src/commands/rlp-desk.md`, or `src/governance.md` MUST pass `tests/sv-gate-full.sh` before merge.

## Local development

### Fast gate (~30s)

Run before every commit:

```sh
zsh tests/sv-gate-fast.sh
# or
npm run sv-gate:fast
```

Checks:
- 35+ code-pattern greps (each tracked v5.7 fix has the expected code)
- All Node unit tests (~50)
- 5 critical zsh unit tests

### Full gate (~5 min)

Run before merge / release:

```sh
zsh tests/sv-gate-full.sh
# or
npm run sv-gate:full
```

Adds:
- REAL tmux E2E (mocked tmux capture, 9 scenarios)
- REAL campaign E2E (haiku worker/verifier, max-iter 3, iter-timeout 300s)
- Asserts `<slug>-complete.md` OR `<slug>-blocked.md` exists post-run (file-guarantee invariant)

**Pre-conditions for full gate**:
- Inside a tmux session (`echo $TMUX` not empty)
- `claude` CLI in PATH
- `node` >= 16 in PATH
- `~/.claude/ralph-desk/` synced from latest `src/` (run `bash install.sh` or manual sync)

## GitHub Actions

The fast gate runs on every PR via `.github/workflows/sv-gate.yml`:

```yaml
name: SV Gate
on: [push, pull_request]
jobs:
  sv-gate-fast:
    runs-on: macos-latest  # zsh + tmux available
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: '22' }
      - run: bash install.sh    # syncs to ~/.claude/ralph-desk
        env: { REPO_URL: file://${{ github.workspace }} }
      - run: zsh tests/sv-gate-fast.sh
```

The full gate (with REAL campaign E2E) is NOT run in CI — it requires:
- Anthropic API key (haiku worker/verifier)
- Live tmux session (CI runners are non-interactive)
- ~3-5 min wallclock per run

Operators MUST run `tests/sv-gate-full.sh` locally before merging to `main`.

## Branch protection (manual)

Required for the SV gate to be enforceable:

1. Go to `https://github.com/<owner>/rlp-desk/settings/branches`
2. Add rule for `main`:
   - ✅ Require a pull request before merging
   - ✅ Require status checks to pass before merging
   - ✅ Search and select: `sv-gate-fast`
   - ✅ Require branches to be up to date before merging
3. Document the manual step here. Branch protection cannot be enforced via committed YAML alone — it is a repo-admin setting.

## Forks / non-GitHub repos

`tests/sv-gate-fast.sh` and `tests/sv-gate-full.sh` are pure zsh + Node — no GitHub-specific dependencies. Forks should:

1. Run `npm run sv-gate:fast` in their CI (Travis, GitLab CI, etc.) using the same OS-level prereqs (macOS or Linux + zsh + tmux + node + claude CLI).
2. Optionally run `npm run sv-gate:full` in a scheduled job (nightly) since it requires live API key.

## Gate failure interpretation

| Failure mode | Meaning | Action |
|--------------|---------|--------|
| Code-pattern grep failed | Tracked fix's expected code is missing | Restore the fix or update `tests/sv-gate-fast.sh` if the pattern legitimately changed |
| Node unit test failed | Behavioral regression | Fix the code; do NOT relax the test |
| zsh unit test failed | Behavioral regression in shell helpers | Fix the helper |
| REAL tmux E2E failed | Real tmux capture/send-keys broke | Investigate tmux version or pane state |
| REAL campaign E2E failed (no sentinel) | **FILE-GUARANTEE VIOLATED** — Worker/Verifier exited without artifact AND backstop did NOT catch | Critical bug; investigate `_ensureTerminalSentinel` and `_handlePollFailure` paths |

## Memo: SV gate is the contract

The SV gate exists because AI assistants (including the Leader itself) miss steps. Mechanical .sh verification is the only enforceable contract — code review, "I tested it locally", and unit-test-only verification are not sufficient. Plan v5.7 explicitly forbids commits that have not passed `tests/sv-gate-full.sh`.
