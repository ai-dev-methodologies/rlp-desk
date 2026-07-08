# Gotchas — rlp-desk

Lessons from failures. Format: Symptom / Root cause / Recovery / Prevention (one line each).

## 2026-07-08 — test:zsh harness forced zsh onto bash-shebang tests (IMP-18)
- Symptom: `npm run test:zsh` failed bash-shebang tests (`BASH_SOURCE` empty under zsh → SCRIPT_DIR resolved wrong), while 18/69 test files were silently rotting.
- Root cause: the harness loop ran `zsh "$f"` unconditionally; a red harness meant nobody ran the suite, so v0.13.0 path migration (`.claude/ralph-desk` → `.rlp-desk`) and later contract refactors (D-9 lock redesign, D-18 final-verify extraction, D-22 consensus dead-code removal, RC-1 TMUX guard) never got mirrored into these tests.
- Recovery: dispatch by shebang (`case "$(head -1 "$f")" in *zsh*) zsh;; *) bash;; esac`), then remediate all 18 stale files against current contracts with per-file git forensics.
- Prevention: a test harness that is itself red gets ignored and hides debt — keep `test:full` runnable and green in CI; when changing a runtime contract (paths, log messages, function extraction), grep tests/ for the old pattern in the same PR.

## 2026-07-08 — ambient $TMUX leaks into zsh -f test harnesses
- Symptom: tests that shell out to `generate_sv_report()` (Agent-mode-only, guarded by an early-return when `$TMUX` is set) fail with no report produced when the test session itself runs inside tmux.
- Root cause: `zsh -f` inherits the caller's exported `$TMUX`; the RC-1 guard (d288dce) then short-circuits.
- Recovery: `unset TMUX` at the top of generated harness scripts.
- Prevention: any test exercising an Agent-mode-only code path must explicitly clear tmux-context env vars; do not assume the CI/dev session is tmux-free.
