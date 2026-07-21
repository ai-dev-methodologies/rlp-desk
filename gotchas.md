# Gotchas — rlp-desk

Lessons from failures. Format: Symptom / Root cause / Recovery / Prevention (one line each).

## 2026-07-08 — test:zsh harness forced zsh onto bash-shebang tests (IMP-18)
- Symptom: `npm run test:zsh` failed bash-shebang tests (`BASH_SOURCE` empty under zsh → SCRIPT_DIR resolved wrong), while 18/69 test files were silently rotting.
- Root cause: the harness loop ran `zsh "$f"` unconditionally; a red harness meant nobody ran the suite, so v0.13.0 path migration (`.claude/ralph-desk` → `.rlp-desk`) and later contract refactors (D-9 lock redesign, D-18 final-verify extraction, D-22 consensus dead-code removal, RC-1 TMUX guard) never got mirrored into these tests.
- Recovery: dispatch by shebang (`case "$(head -1 "$f")" in *zsh*) zsh;; *) bash;; esac`), then remediate all 18 stale files against current contracts with per-file git forensics.
- Prevention: a test harness that is itself red gets ignored and hides debt — keep `test:full` runnable and green in CI; when changing a runtime contract (paths, log messages, function extraction), grep tests/ for the old pattern in the same PR.

## 2026-07-08 — P3 banner-strip verify false-FAILs on unbannered installed files
- Symptom: release post-verify P3 reported drift on `node/MANIFEST.txt` right after a clean publish.
- Root cause: postinstall does not inject a DO-NOT-EDIT banner into `.txt` files, so an unconditional `tail -n +2` banner-strip removes the first real line before diffing.
- Recovery: strip the banner only when line 1–2 actually contains `DO NOT EDIT`; otherwise compare verbatim.
- Prevention: any banner-aware verification (CLAUDE.md §4.5, runbook P3) must detect the banner per file, not assume it.

## 2026-07-08 — ambient $TMUX leaks into zsh -f test harnesses
- Symptom: tests that shell out to `generate_sv_report()` (Agent-mode-only, guarded by an early-return when `$TMUX` is set) fail with no report produced when the test session itself runs inside tmux.
- Root cause: `zsh -f` inherits the caller's exported `$TMUX`; the RC-1 guard (d288dce) then short-circuits.
- Recovery: `unset TMUX` at the top of generated harness scripts.
- Prevention: any test exercising an Agent-mode-only code path must explicitly clear tmux-context env vars; do not assume the CI/dev session is tmux-free.

## 2026-07-10 — codex exec hangs waiting on stdin in non-interactive review calls
- Symptom: `codex exec "<review prompt>"` intermittently hit the 10-minute Bash timeout with only "Reading additional input from stdin..." in the log.
- Root cause: codex exec reads stdin when it is a pipe/tty; under the tool harness the stream stayed open, so codex waited indefinitely before starting.
- Recovery: append `< /dev/null` to every non-interactive `codex exec` invocation.
- Prevention: treat `< /dev/null` as mandatory in scripted codex review loops (poller/critic wrappers).

## 2026-07-11 — codex 0.144 renders its prompt as ❯ (U+276F), not › (U+203A)
- Symptom: dogfood campaign BLOCKED at iteration 1; console said the codex pane was "not ready after 30s" even though the pane was healthy and idle at its prompt.
- Root cause: the two launch ready-loops grepped only `›` (the 0.141 glyph). The later stall/paste path already accepted both, which is why only launch broke.
- Recovery: `grep -qE '[›❯]'` at both launch ready-loops (`tests/test_codex_ready_glyph.sh` pins it).
- Prevention: never pin a single TUI glyph. When a vendor CLI bumps a minor, re-capture a live pane before trusting a cosmetic grep.

## 2026-07-11 — a provider quota wall looks exactly like a hung verifier
- Symptom: with the glyph bug fixed, the campaign still BLOCKED. The instruction WAS pasted, the codex pane sat static for the full 600s ITER_TIMEOUT, and the sentinel said only "verifier/infra error before verdict". Hours of "why didn't Enter submit?" followed.
- Root cause: NOT a code bug. The codex account was out of usage — the pane's last line read `ERROR: You've hit your usage limit ... try again at 3:08 AM.` `detect_api_error()` cannot see this (no numeric code; "usage limit" is not an outage phrase), so the leader polled to timeout.
- Recovery: `detect_quota_exhausted()` (lib) + an abort check in the codex verifier poll loop; the sentinel now names the cause via `VERIFIER_ABORT_REASON`.
- Prevention: when a pane looks "stuck with no progress", READ THE LAST PANE LINE before theorising about submission/keying. Anchor the detector on "hit your usage limit" / "usage limit reached" — never a bare "usage limit", because the D-17a transient banner literally contains "(not your usage limit)" and must stay on the recoverable backoff path.

## 2026-07-11 — running a bash test with `zsh tests/foo.sh` fakes a total failure
- Symptom: `zsh tests/test_us009_api_retry_guard.sh` reported 0/13 PASS; it looked like a fresh regression from an unrelated lib edit.
- Root cause: the file is `#!/usr/bin/env bash`. Forcing zsh on it reproduces exactly the harness bug fixed in IMP-18 (v0.18.7).
- Recovery: run `npm run test:zsh` (it shebang-dispatches) or invoke the file's own interpreter.
- Prevention: never hand-pick the interpreter for a test file. Also: before blaming your own diff for a suite going red, re-run that suite on stashed-clean HEAD.

## 2026-07-11 — resume/confirmation iterations deadlock the codex Worker Process Audit (2x reproduced)
- Symptom: restarting a campaign over an already-complete deliverable ends BLOCKED `context_limit` ("Context unchanged for 3 consecutive iterations") after codex fails the Worker Process Audit every round; claude passes the same rounds.
- Root cause: leader startup cleanup discards the original done-claim (which held the real TDD execution_steps), and a worker re-verifying finished code cannot honestly produce fresh write_test/verify_red-exit-1 evidence — so the audit can never pass and the context goes stale.
- Recovery: full fresh build in VERIFY_MODE=batch — the build iteration's done-claim carries the complete plan→write_test→verify_red→implement→verify_green sequence in one shot (slugify went COMPLETE at iter 1 with sol:xhigh consensus).
- Prevention: don't resume a finished campaign expecting a consensus-only replay; if resume becomes a real workflow, fix governance (audit accepts a confirmation-mode done-claim, or leader preserves the verified done-claim across restarts) via ralplan+codex. Also: `init --mode fresh` OVERWRITES existing PRD/test-spec with blank templates — re-author plans afterwards.

## 2026-07-14 — the verifier-side resume fix was not enough: the WORKER leg deadlocks too
- Symptom: with confirmation-mode verification implemented and unit-green, the AC6 resume dogfood still BLOCKED — the resumed worker looked at the completed state, honestly reasoned "no action needed", never wrote an iter-signal, and idled into the 600s no-progress guard.
- Root cause: D-16 leader-finalize (skip the worker when all US are verified) arms via an IN-MEMORY flag that a restart loses; the resume therefore dispatched a worker that had nothing it could honestly do.
- Recovery: at startup, if derive_verification_mode already proves completion from the durable ledger, re-arm the finalize flag — the resume then goes straight to the ALL verify (4m09s to COMPLETE in the rerun).
- Prevention: for any "loop skips a stage when state says done" design, ask where that decision LIVES — an in-memory flag silently reintroduces the skipped stage after every restart. And: unit-testing the verifier contract cannot catch a worker-leg deadlock; only the end-to-end resume dogfood did.

## 2026-07-14 — correction: the "leader stdout spam" was the READER, not the leader
- The earlier diagnosis that the zsh leader spams "can't find session: -d" was wrong. The leader consoles were always clean (793 real lines); the noise was injected by MY OWN read pipelines — `tr -d '\000'` in a Claude-Code shell resolves to the user's `alias tr='tmux rename-session -t'`, which eats the stream and prints the tmux error instead.
- Rule: in any shell that sources user rc files, never assume core utilities are unshadowed. `command tr` (or avoiding tr) is mandatory in diagnostic pipelines, and `type <util>` is the first probe whenever output looks impossible.

- **tests/의 bash/zsh 혼재 — 수동 실행 시 shebang 필수 확인 (동일 세션 2회 재발, 2026-07-20).** `npm run test:zsh` 러너는 head -1의 shebang을 보고 bash/zsh를 디스패치하지만, 수동으로 `zsh tests/test_X.sh`를 치면 bash 테스트의 `${BASH_SOURCE[0]}`가 미해석 → `REPO_ROOT` 붕괴 → 모든 grep 단언이 "expected 1 got 0"으로 **조용히 전멸**(테스트 자체는 돌아가는 것처럼 보임). 증상: 무관한 AC까지 전부 FAIL. 복구: `head -1`로 shebang 확인 후 맞는 인터프리터로 재실행. 재발 방지: 수동 실행은 `bash tests/...` 기본, zsh 전용(`#!/bin/zsh`)만 zsh로. (us009 오진단 1회 + "좀비 테스트 6종" 오탐 4건이 같은 원인)

## 2026-07-21 — pane-content 검증은 viewport 위치에 의존하면 안 된다 (④ 에코검증 P1 회귀)
- Symptom: v0.22.18 launch echo-verify가 갓 split된 pane에서 100% 오탐 → `launch paste echo mismatch` 3연발 → `[infra_failure]` BLOCKED, 재기동 4연속 즉사 (34~37차).
- Root cause: `capture-pane -p | tail -10`은 "내용이 하단에 있다"(사용된 쉘 레이아웃)를 가정한다. 그러나 **갓 만든 pane은 첫 프롬프트를 viewport 최상단에 그리고 그 아래 ~30행이 빈 줄** → tail -10은 빈 줄만 취함 → `$()`가 후행 개행 제거 → `_tail=""` → prefix grep 영구 실패. 명령 에코 자체는 온전했다(상단에). 즉 랩 대응(-10)만으로는 프롬프트-상단 케이스를 못 덮는다.
- Recovery: tail 전에 빈 줄 제거 — `capture-pane -p | grep -v '^[[:space:]]*$' | tail -10`. 위치 무관해지고 -10(랩 대응) 유지. 보조로 첫 paste 전 쉘-준비 대기(가시 non-blank 텍스트 등장까지 bounded poll, fail-open).
- Prevention: **pane/터미널 내용 단언은 viewport 위치 독립적으로 작성한다** — tail -N을 raw capture에 쓰기 전 blank 제거. 테스트는 반드시 "프롬프트 상단 + 후행 빈 줄" 픽스처를 포함(사용된-쉘 레이아웃만 테스트하면 이 케이스가 새어나간다).
- 관련(같은 보고서 ②): `tmux display-message -p '#{pane_id/session_name}'`는 **호출한 쉘의 pane이 아니라 attached 클라이언트의 활성 pane**을 보고한다(다중 클라이언트 시 오퍼레이터 pane/타 세션 채택 → pane 흩어짐). "내 pane/세션"이 필요하면 **`$TMUX_PANE`(호출 프로세스 고유 pane, 활성-pane drift 무관)**를 우선하고 세션은 그 pane에서 파생(`display-message -p -t "$LEADER_PANE"`). LEADER_PANE·SESSION_NAME을 둘 다 활성 클라이언트에서 잡으면 self-consistent-but-wrong이라 세션 불변식(pane session == SESSION_NAME)도 못 잡는다.
