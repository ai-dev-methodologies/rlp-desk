# Plan: Enable Flywheel **and Self-Verification** in tmux Mode via Node.js Leader Routing

> Status: **v5.7 — codex Critic APPROVED** (final, all 4 bug-report items + autonomy/install hardening + Opus 1M closed). Full ralplan trail: v3 APPROVE → v4 user lock-in → v5 user scope expand → v5.1 Planner → v5.2 Architect → v5.2 codex ITERATE → v5.3 codex APPROVE → v5.4 Bug 1 → v5.4 codex ITERATE → v5.5 codex APPROVE → v5.6 Bug 4 → v5.6 codex ITERATE → v5.7 codex APPROVE. Implementation-ready. Pending user approval gate per CLAUDE.md.
> Author: claude-opus-4-7
> Date: 2026-04-27
> Target version: 0.12.0
> Risk classification: **DELIBERATE** (release-breaking distribution gap + §1f SV gate trigger + user-visible execution backbone change).

---

## 0. Change Log

### v5.5 → v5.6 (Bug 4 — mid-execution permission prompt, 2026-04-27 evening)

External bug reporter added Bug 4 (HIGH): Worker / Verifier panes mid-execution emit `Do you want to create <file>?` prompts despite `--dangerously-skip-permissions`. The polling loop's `check_and_nudge_idle_pane()` doesn't recognize them → workers hang to nudge timeout.

**Planner verification (key findings)**:
- `run_ralph_desk.zsh:1828-1836` ALREADY has auto-approve logic in `poll_worker_for_signal()`. So worker poll path is partially covered. But `check_and_nudge_idle_pane()` and verifier/brainstorm poll sites are NOT.
- **Node leader has ZERO permission-prompt handling** — `signal-poller.mjs` and `campaign-main-loop.mjs` poll for sentinels but do not dismiss prompts. Critical gap because v5.5 routes tmux through Node leader.
- v5.5's `--add-dir` whitelist does NOT eliminate Bug 4. `--dangerously-skip-permissions` is a tool-permission flag; the `Do you want to create` is a TUI-layer prompt that claude CLI v2.1.114 still surfaces in some Write paths. Different layer.
- Reporter's `(create|overwrite|edit|delete)` regex is NARROWER than the existing `Do you want to` match. Keep the broader pattern.
- False-positive risk: a Worker tool output rendering literal `Do you want to ...` text → blanket auto-Enter could disrupt mid-stream output.

**v5.6 mitigation (§4.13 new)**:

| Section | v5.5 → v5.6 |
|---------|-------------|
| §4.13 (new) | Extract `auto_dismiss_prompts(pane_id)` helper from existing zsh line-1828 block. Call from: `check_and_nudge_idle_pane()` entry, every `poll_*_for_signal()` site, brainstorm/init pane-wait paths. Apply false-positive guard: capture last 10 lines + require TUI affordance marker (`(y/n)`, `[Y/n]`, `[y/N]`, `❯ 1.`, `1) Yes`) + 3-second debounce per pane (epoch map). Pattern: keep broad `"Do you want to"` and `"Do you trust"`, add `"Confirm execution"`, `"Are you sure"`, `"Continue\?"` for completeness. |
| §4.13 (Node leader mirror) | `src/node/runner/signal-poller.mjs` (or equivalent) gains an `autoDismissPrompts(paneId)` helper invoked at the top of every poll iteration. Same pattern set, same affordance guard, same debounce. **This is the larger gap** — zsh runner had partial coverage; Node leader had zero. |
| §2 G12 (new) | Acceptance: a campaign in tmux mode where Worker emits `Do you want to create memos/<slug>-iter-signal.json?` is auto-dismissed within ≤ POLL_INTERVAL seconds (default 5s) and the campaign continues without nudge-timeout. Negative test: a Worker tool-output line containing the literal text `Do you want to learn more` (no TUI affordance marker on adjacent lines) is NOT auto-dismissed. |
| §6 | New risk R-V5-9 (HIGH): false-positive auto-Enter disrupts intentional Worker output → mitigation = false-positive guard from §4.13. |
| §6 | New risk R-V5-10 (MEDIUM): `Do you want to` patterns evolve in future claude CLI versions → mitigation = `~/.claude/ralph-desk/known-prompts.txt` referenced by `auto_dismiss_prompts()`, easy to update without source change. |
| §5.1 | New tests: `tests/test_us0XX_tmux_permission_prompt_dismiss.sh` (zsh path) + `tests/node/us0XX-permission-prompt-dismiss.test.mjs` (Node leader path) + `tests/test_us0XX_false_positive_no_dismiss.sh` (negative test). |

User's "Bug 5" recollection: Planner searched all `.claude/` files in `bless-two-surge-v3-lab` — only Bug 1–4 documented. No P0/P1/P2/P3 priority structure exists in writing. Treated as a recollection mismatch; v5.6 covers everything that IS in writing.

### v5.3 → v5.4 (External bug report, 2026-04-27 PM)

External bug report from `/Users/kyjin/dev/own/bless-two-surge-v3-lab/.claude/ralph-desk/RLP_DESK_BUGREPORT_2026-04-27.md` documents 3 bugs. Mapping:

| Bug | Priority | v5.3 coverage | v5.4 action |
|-----|----------|---------------|-------------|
| Bug 1 — `--model $model` unquoted; `claude-opus-4-7[1m]` brackets parsed as zsh glob → Worker process dies → BLOCKED `infra_failure` | HIGH | NOT covered | **§4.12 new — defensive shell-quoting on every `--model` emission**. Source-level fix at `lib_ralph_desk.zsh:45`, `command-builder.mjs:18`, `campaign-main-loop.mjs:572, 585`. Includes Worker/Verifier/Flywheel/Guard/SV-report builders. |
| Bug 2 — `--with-self-verification` silent disable in tmux | LOW | Covered: §4.7 (SV report parity), §4.11 (force-disable removed when routed to Node leader) | No new action — verification: G3 already asserts SV artifacts present in tmux. |
| Bug 3 — `--flywheel on-fail` silent ignore in tmux | MEDIUM | Covered: §4.1 (route to Node leader), §4.2 (zsh runner banner exit-2 with flywheel flags), §3 (Option D rejection rationale) | No new action — verification: G1, G2 already assert flywheel pipeline runs in tmux. |

**Recontextualization of the 2026-04-27 AM "unauthorized edit"**: The other Claude session in `bless-two-surge-v3-lab` modified `~/.claude/ralph-desk/lib_ralph_desk.zsh` line 45 to add single-quotes around `$model`. That edit was a **legitimate attempt to fix Bug 1**, executed through the wrong channel (install file directly, not source). User decided "외부수정은 이번만 넘어가자" while still requiring §4.10 to prevent recurrence — both stances remain correct. v5.4 lands the proper source fix; §4.10 ensures future fixes route through source.

| Section | v5.3 → v5.4 |
|---------|-------------|
| §4.12 (new) | Defensive shell-quoting of `$model` on every `--model` emission. Single-quote the model value: `--model '$model'` in zsh, `parts.push("'", model, "'")` (or equivalent shell-escape) in Node command-builder. Defends against bracket / wildcard / space chars in any future model id without enumerating them. |
| §2 G11 (new) | Acceptance: a model id containing `[`, `]`, `*`, or `?` does NOT cause Worker process death. |
| §6 (new risk) | Future model id naming conventions may use additional shell-special chars; mitigation = quoting (already applied). |

### v5.1 → v5.2 (Architect re-review, 2026-04-27 PM)

User-rejected Architect proposals (kept v5.1 as-is):
- "Defer §4.11.b/§4.11.c to 0.13.x" — REJECTED. User: "모두 다 변경하자".
- "Demote chmod from 0o444 to 0o644" — REJECTED. Cross-Claude-session threat: both sessions run as the same OS owner, so 0o644 (owner-writable) fails to block them. The whole point of `0o444` is the friction that forces an explicit `chmod u+w` before edit, signaling "you're touching a derived artifact."

Applied Architect deltas:

| Section | v5.1 → v5.2 |
|---------|-------------|
| §4.11.b | **Worktree `<project-root>` semantics defined**: `git rev-parse --show-toplevel` (worktree-aware) when invoked inside a git tree; falls back to `process.cwd()` when not. Document in §4.11.b: "in a `git worktree`, project-local analytics live inside the worktree path, not the main repo. Each worktree campaign owns its own analytics." This matches user expectation (a worktree is a campaign sandbox) and matches existing rlp-desk multi-mission worktree handling. |
| §4.11.b | **Concurrent campaigns in same project (codex Critic v5.3 fix — MAJOR)**: relocate per-campaign locks to `<project-root>/.claude/ralph-desk/locks/<slug>.lock` (one file per slug, NOT one project-wide `.lock`). flock semantics on each slug-specific lock; multiple slugs can run in parallel without serialization. US-026's home-tree lockfile (`~/.claude/ralph-desk/.lock`) remains for cross-project Leader registration. Document the two-tier lock layout: home tree = Leader registry mutex, project tree = per-slug campaign lock. |
| §5.1 | **New regression test**: `tests/test_install_lib_tamper_detection.sh` — seed installed `lib_ralph_desk.zsh` with the unauthorized `'$model'` quoting (the actual 2026-04-27 incident), run sync, assert TAMPER detected and re-sync recovers source content + chmod 0o444 + banner. |
| §6 | New risks: WSL/Windows chmod silent no-op (NTFS); install.sh `chmod` failure swallowing (Pre-mortem #2). |
| §7 (release notes follow-up) | Add: "to fully uninstall, run `chmod -R u+w ~/.claude/ralph-desk && rm -rf ~/.claude/ralph-desk`. `npm uninstall -g rlp-desk` does NOT remove these files because they were postinstall-copied, not npm-managed; without `chmod u+w` first, `rm` (without `-f`) prompts on read-only files." |
| §4.10 | install.sh: `set -e` discipline mandatory; do NOT use `chmod u+w "$target" 2>/dev/null \|\| true` (Architect Pre-mortem #2 — masks tmpfs/`ro`-bind-mount failures). Use `chmod u+w "$target" \|\| { echo "[install] FATAL: cannot unlock $target. Filesystem may be read-only."; exit 1; }`. |
| §4.10 | **Documented escape hatch**: ship a one-line `~/.claude/ralph-desk/UNLOCK.md` describing `chmod -R u+w ~/.claude/ralph-desk` for debug sessions. The banner in installed files references this file by name. |

### v5 → v5.1 (Planner re-verification, 2026-04-27 PM)

| Section | v5 → v5.1 |
|---------|-----------|
| §4.10 | (a) Per-extension banner format (`<!-- ... -->` for `.md`, `# ...` for `.zsh/.sh`, `// ...` for `.mjs/.js`) — `# DO NOT EDIT` text was leaking into rendered Markdown. (b) **chmod-before-copy fix**: `fs.chmodSync(target, 0o644)` BEFORE `fs.copyFileSync()` then `chmodSync(0o444)` AFTER — without this, every 0.12 upgrade fails EACCES on the read-only target from a prior install (R-V5-1, release-blocker). |
| §4.11.b | Surface count corrected from 12 → ~28; campaign-main-loop.mjs:60 identified as the actual Node write site; ~10 internal threads to wire `projectRoot`; tests/node/test-sv-report.mjs fixtures included. Allocate separate stacked commit for threading vs text edits. |
| §4.11.c | (a) **Leader-only guardrail**: Worker/Verifier/Flywheel/Guard prompt templates MUST NOT reference `registry.jsonl`; enforce via CI grep lint. (b) Migration idempotency rules: `.migrated` marker, stale-`project_root` log+skip, home dir rename only after full success. |
| §6 | New HIGH risk: postinstall.js EACCES on read-only target if chmod-before-copy ordering not in place (release-blocker without §4.10b fix). New MEDIUM risk: §4.11.b scope effort underestimated (28 sites, not 12). |

### v4 → v5 (autonomous-mode integrity, 2026-04-27)

**Trigger**: Two production-symptom reports during another project's rlp-desk run.

1. Another Claude session in another project directly edited `~/.claude/ralph-desk/lib_ralph_desk.zsh` (changing `--model $model` → `--model '$model'`). This violates CLAUDE.md "Local File Sync" — installed files are derived artifacts, never edit targets. Re-sync executed; root cause is that nothing in the installed file flags it as derived.
2. `/rlp-desk run --mode tmux` with `--dangerously-skip-permissions` still triggers yes/no prompts because Worker prompts reference `~/.claude/ralph-desk/analytics/<slug>/...` (cross-cwd home-dir absolute paths). The claude CLI's permissions bypass does NOT cover writes outside cwd unless those paths are explicitly whitelisted with `--add-dir`.

| Section | v4 → v5 |
|---------|---------|
| §4.10 (new) | **Install-file write protection** — every file copied by `postinstall.js` and `install.sh` gets a leading banner `# DO NOT EDIT — generated from <source-path>. Edit source and re-sync.` + `chmod a-w` after copy so accidental edits fail loudly. |
| §4.11 (new) | **Autonomous-mode permission integrity** — (a) all claude invocations get `--add-dir "$HOME/.claude/ralph-desk" --add-dir "$ROOT"` so Worker has authorized access to both campaign cwd and the home rlp-desk tree, (b) move per-campaign analytics from `~/.claude/ralph-desk/analytics/<slug>/` to **project-local** `.claude/ralph-desk/analytics/<slug>/`, (c) cross-project rollup moves to a `~/.claude/ralph-desk/registry.jsonl` index that the Leader updates on campaign start/end, never referenced inside Worker/Verifier prompts. |
| §2 G9, G10 | New acceptance criteria for the two policies. |
| §6 | New risks: (1) registry.jsonl drift if a campaign exits abnormally, (2) Worker still prompts if `--add-dir` set is incomplete on edge cases. |

### v3 → v4 (user lock-in 2026-04-27)

| Section | v3 → v4 |
|---------|---------|
| §9 | Q1–Q4 all RESOLVED (off / flywheel-SV-only exit / yes preflight / single-shot 0.12.0). |
| §4.9 (new) | **Opus 1M context auto-enable** — every claude invocation that uses `--model opus` automatically prepends `ANTHROPIC_BETA=context-1m-2025-08-07` so 1M-context window is on by default for Opus, no per-call flag. |
| §2 G8 (new) | Acceptance criterion + verification for the 1M context env var. |
| §6 | New risk row for Opus 1M cost surprise. |

### v1 → v2

| Section | v1 → v2 |
|---------|---------|
| Title / §1 / §2 | Added `--with-self-verification` to scope. Same root cause as flywheel gap (zsh runner force-disables; Node leader supports). |
| §1 Evidence | Line numbers corrected: `campaign-main-loop.mjs` flywheel pipeline at **L575-892** (was 571). Added SV evidence rows. |
| §3 | Added **Option D** (loud rejection) and the Architect's two-phase synthesis as a discussion. |
| §4.1 | Added env-var → flag translation (BLOCK_CB_THRESHOLD/LANE_MODE/TEST_DENSITY_MODE). Path corrected to `~/.claude/ralph-desk/node/` (drop `src/`). |
| §4.2 | SV deprecation banner added alongside flywheel. |
| §4.4 | Rewritten — `install.sh` does NOT ship `src/node/**` today. Manifest-based fix added. Removed dead "package.json:files" fallback. |
| §4.5 | Path corrected (drop `src/`). Switched to `rsync -a --delete` + `diff -rq`. |
| §4.6 | New — telemetry/4-category schema parity. |
| §4.7 | New — SV report parity verification. |
| §5.1 | Added `tests/test_install_sh_includes_node_sources.sh` (curl-install smoke test). |
| §6 | New risk row for curl-install distribution gap. Pane count clarification. |
| §9 | Added Q3 (Node ≥16 preflight in install.sh), Q4 (phasing — flywheel/SV deferred to 0.13?). |

---

## 1. Problem Statement

Two related bugs have a **single root cause**: the slash command `/rlp-desk run --mode tmux` shells out to `run_ralph_desk.zsh`, which silently force-disables features the Node.js leader already supports.

### 1.1 Flywheel silent no-op

`--flywheel`, `--flywheel-model`, `--flywheel-guard`, `--flywheel-guard-model` exist in `src/node/run.mjs` (`run.mjs:26-29, 68-71, 162-...`), are wired through `campaign-main-loop.mjs:575-892` (full `dispatchFlywheel` + `dispatchGuard` + retry-with-feedback + `flywheel_guard_count` tracking), and operate identically in tmux and agent modes inside the Node leader. But `/rlp-desk run --mode tmux` invokes `zsh ~/.claude/ralph-desk/run_ralph_desk.zsh` (`src/commands/rlp-desk.md:306`), bypassing the Node leader entirely. A `grep -i flywheel` against `run_ralph_desk.zsh` returns **0 matches**. Result: every `--flywheel on-fail` request in tmux mode is silently ignored.

### 1.2 `--with-self-verification` silent disable

`run_ralph_desk.zsh:62-68` contains an explicit force-disable:

```zsh
# RC-1: SV is Agent-mode only — disable for tmux runner before any metadata is written
if (( WITH_SELF_VERIFICATION )); then
  WITH_SELF_VERIFICATION=0
  SV_SKIPPED_REASON="tmux_runner"
fi
```

Runtime evidence (user report 2026-04-27):

> ⚠️ `--with-self-verification`는 agent-mode 전용 → tmux 모드에서 자동 disable 됨 (campaign-report.md만 생성)

But the Node leader explicitly **does** generate SV reports in tmux mode: `campaign-main-loop.mjs:728, 993, 1037` invoke `generateSVReport()` whenever `options.withSelfVerification` is true, mode-agnostically. `campaign-reporting.mjs:568-575` writes `self-verification-report.md` + `self-verification-data.json` regardless of mode. The `tmux_runner` skip is a self-imposed restriction in the zsh path only.

### 1.3 Evidence

| Source | Finding |
|--------|---------|
| `src/scripts/run_ralph_desk.zsh` | `grep -i flywheel`: 0 hits. SV force-disabled at L62-68 with `SV_SKIPPED_REASON=tmux_runner`. |
| `src/node/runner/campaign-main-loop.mjs:575-892` | Flywheel + Guard pipeline, mode-agnostic. |
| `src/node/runner/campaign-main-loop.mjs:728, 993, 1037` | `generateSVReport()` called whenever `withSelfVerification=true`, no mode check. |
| `src/node/reporting/campaign-reporting.mjs:568-575` | SV artifacts: `self-verification-report.md`, `self-verification-data.json`. |
| `src/commands/rlp-desk.md:289-307` | Slash command shells out to zsh. Env-var passthrough at L291-305 omits FLYWHEEL\* and never converts BLOCK_CB_THRESHOLD/LANE_MODE/TEST_DENSITY_MODE to Node CLI flags. |
| `package.json:11` | `"src/node/"` already in `files` — npm tarball ships Node sources. |
| `scripts/postinstall.js:14, 27-31, 123` | `copyNodeRuntime()` installs Node sources to **`~/.claude/ralph-desk/node/`** (NOT `~/.claude/ralph-desk/src/node/`). Legacy `*.zsh` deleted on every install. |
| `install.sh` | Curls only `*.zsh` + markdown. **Does NOT download `src/node/**`.** Curl-install users have no Node leader. |
| `docs/blueprints/blueprint-flywheel-enhancement.md:33, 296` | Original design defers zsh implementation; documents the Node-only escape hatch but routes no user surface to it. |

---

## 2. Goals

When `/rlp-desk run --mode tmux ...` is invoked with `--flywheel`, `--flywheel-guard`, or `--with-self-verification`, all three pipelines MUST execute identically to `--mode agent`.

### 2.1 Success Criteria

| ID | Criterion | Verification |
|----|-----------|--------------|
| G1 | tmux + `--flywheel on-fail` produces a flywheel pane and dispatches Flywheel agent on FAIL. | E2E tmux test: induce one Verifier FAIL, assert `flywheel-signal.json` written + consumed within iter timeout. |
| G2 | tmux + `--flywheel-guard on` triggers Guard, retries Flywheel on `fail` (max 2), BLOCKS on retries-exhausted with `flywheel_exhausted` reason_category. | E2E tmux test. |
| G3 | tmux + `--with-self-verification` produces `self-verification-report.md` and `self-verification-data.json` under `~/.claude/ralph-desk/analytics/<slug>/`, and the campaign-report no longer carries `sv_skipped_reason: tmux_runner`. | E2E test asserts both artifacts exist and JSON does not contain `tmux_runner`. |
| G4 | Direct `zsh run_ralph_desk.zsh` with FLYWHEEL or WITH_SELF_VERIFICATION env vars exits with a banner pointing to the Node command. Without those vars, runs unchanged. | Unit test. |
| G5 | All existing tmux behaviors pass (US-021, US-023, US-024, US-025, US-026, 0.11.1 SV E2E, all flywheel Node tests). | Regression suite. |
| G6 | `governance.md §6½` lists tmux as supported. `src/commands/rlp-desk.md` no longer states "tmux 모드에서 자동 disable" for SV. | Doc diff. |
| G7 | `bash install.sh` in a clean container produces `~/.claude/ralph-desk/node/run.mjs` AND `~/.claude/ralph-desk/node/runner/campaign-main-loop.mjs` AND `~/.claude/ralph-desk/node/reporting/campaign-reporting.mjs`. Subsequent `/rlp-desk run --mode tmux` does NOT 404. | New smoke test. |
| G8 | Every claude invocation routed by the Node leader with `--model opus` (Worker, Verifier, Final Verifier, Flywheel, Guard) is prefixed with `ANTHROPIC_BETA=context-1m-2025-08-07`. Non-opus claude calls and codex calls are NOT prefixed. | Unit test on `buildClaudeCmd()` + integration assertion via `tmux send-keys` capture for flywheel/guard dispatch commands. |
| G9 | (a) On filesystems that honor POSIX mode bits (ext4, APFS, HFS+, etc.), direct edits to `~/.claude/ralph-desk/*` files fail with EACCES. On non-honoring filesystems (WSL1/NTFS, `tmpfs noexec`, certain bind mounts) install completes with a documented `[install] WARNING` per R-V5-5 — chmod enforcement is treated as best-effort, not a hard guarantee. (b) Banner format is **per-extension** (codex Critic v5.3 fix — MINOR): `.md` first line is `<!-- DO NOT EDIT — generated from <source>. Edit source and re-sync. See ~/.claude/ralph-desk/UNLOCK.md. -->`; `.zsh`/`.sh` keep shebang on line 1, banner `# DO NOT EDIT ...` on line 2; `.mjs`/`.js` first line is `// DO NOT EDIT ...`; `.json` (none today) gets a sidecar `<file>.banner.txt`. | Test: per-extension `head -1` (or `head -2` for shebanged) content match plus `chmod` introspection. The chmod test uses `[[ "$(stat -c %a)" == "444" ]]` (Linux) / `stat -f %Lp` (macOS); on filesystems that no-op chmod, the test asserts the install-time WARNING was emitted instead. |
| G10 | A full `/rlp-desk run --mode tmux --autonomous` campaign in a fresh project, with `--dangerously-skip-permissions` already enabled, completes with **zero** yes/no prompts surfaced to the user. Per-campaign analytics live under `<project>/.claude/ralph-desk/analytics/<slug>/`; only the cross-project `~/.claude/ralph-desk/registry.jsonl` is touched in the home tree. | Smoke test in clean container: spy on stdin for any `yes/no` prompt token; assert prompt-count = 0. |
| G11 | A model id containing zsh-special characters (`[`, `]`, `*`, `?`, space, single quote `'`) does NOT cause Worker / Verifier / Flywheel / Guard process death. Concrete repro from external Bug 1: `WORKER_MODEL='claude-opus-4-7[1m]'` runs to completion in both `--mode tmux` and `--mode agent`. The single-quote case validates the `shellQuote()` helper's POSIX escape contract claimed in §4.12. | Unit + smoke: parametrized over `['opus', 'claude-opus-4-7[1m]', 'claude-opus-4-7*test', 'model with spaces', "model'quote", "weird$model`bt"]` — all dispatch successfully; emit captured `--model` arg literal-equals input after shell parsing. |
| G12 | A tmux campaign where Worker emits `Do you want to create memos/<slug>-iter-signal.json?` mid-execution auto-dismisses within ≤ POLL_INTERVAL seconds (default 5s) and the campaign continues without nudge-timeout. Coverage: zsh runner (legacy non-flywheel path) AND Node leader (post-§4.1 routing). **Negative test**: a Worker tool-output line containing the literal text `Do you want to learn more` (no TUI affordance marker on adjacent lines) is NOT auto-dismissed. | E2E in tmux: stub Worker that prints `Do you want to create test.json? (y/n)`, assert auto-Enter within 5s. Negative E2E: stub Worker prints `Do you want to learn more about Rust?` (no marker), assert NO auto-Enter and Worker output preserved. |

---

## 3. Approach: Option A — Routing Migration (recommended)

The slash command's tmux dispatch (`src/commands/rlp-desk.md:289-307`) stops shelling to `run_ralph_desk.zsh` and instead invokes the Node.js leader's `run --mode tmux` subcommand. The Node leader already:

- Creates panes for leader + worker + verifier + flywheel; Guard reuses the flywheel pane (verified L575-892 — see §6 risk for pane-count assertion).
- Implements 0.11.1 R12+R13+R14 pane-lifecycle resilience (US-024/025/026).
- Implements consecutive_blocks circuit breaker (`flywheel_inconclusive` / `flywheel_exhausted` reasons at L430-431).
- Generates SV reports (L728/993/1037) — no `tmux_runner` skip.

`run_ralph_desk.zsh` is retained as a deprecated entry: prints a banner; exits non-zero only when called with FLYWHEEL or WITH_SELF_VERIFICATION env vars; otherwise behaves as today for backward compatibility within the 0.x minor.

### 3.1 Alternatives Considered

| Option | Why not |
|--------|---------|
| **B — Port flywheel + SV pipelines to zsh** | ~400+ LOC zsh duplication (320 flywheel + ~100 SV), two parallel implementations to verify per CLAUDE.md §1f gate, blueprint §3 explicitly defers zsh. Violates DR-3 (surgical change). |
| **C — Hybrid IPC (zsh shells out to Node helper)** | Splits one iteration across two runtimes mid-loop; sentinel + pane state crosses a process boundary every retry; reintroduces lifecycle ownership ambiguity that US-024/025/026 just sealed. |
| **D — Loud rejection (refuse `--flywheel`/`--with-self-verification` in tmux)** | Honors least-surprise without engine swap risk, but defeats the whole point: tmux is the recommended long-run mode (`README.md:292`) and is exactly where flywheel + SV add the most value. |

### 3.2 Architect's Phasing Synthesis (kept open as Q4)

The Architect proposed splitting risk:
- **0.12.0**: routing migration only; reject `--flywheel` / `--with-self-verification` in tmux (Option D applied).
- **0.13.0**: enable flywheel + SV in tmux once 0.12.x telemetry shows clean engine-swap behavior.

**Tradeoff**: phasing buys regression isolation at the cost of one extra release cycle delaying the user-visible feature. Decision deferred to user — see §9 Q4. Default plan target = 0.12.0 single-shot.

---

## 4. Detailed Changes

### 4.1 Slash command rewiring — `src/commands/rlp-desk.md`

Replace the env-var-style dispatch block at L289-307 with a Node.js invocation. Convert env-var-style configs the slash command historically built into Node CLI flags:

```bash
node ~/.claude/ralph-desk/node/run.mjs run "<slug>" \
  --mode tmux \
  --max-iter <N> \
  --worker-model <model> \
  [--lock-worker-model] \
  --verifier-model <model> \
  --final-verifier-model <model> \
  --consensus <off|all|final-only> \
  --consensus-model <model> \
  --final-consensus-model <model> \
  --verify-mode <per-us|batch> \
  --cb-threshold <N>                # was env BLOCK_CB_THRESHOLD \
  --iter-timeout <N> \
  [--debug] [--autonomous] \
  [--lane-strict]                   # was env LANE_MODE=strict \
  [--test-density-strict]           # was env TEST_DENSITY_MODE=strict \
  [--with-self-verification] \
  [--flywheel on-fail --flywheel-model <model>] \
  [--flywheel-guard on --flywheel-guard-model <model>]
```

- §5 (`Locate runner script`): locate `~/.claude/ralph-desk/node/run.mjs` (postinstall canonical path).
- §6 (error handling): unchanged — Node leader exits with same conventions.
- Tmux preflight ($TMUX, tmux/jq presence) stays in the slash command.
- Add Node ≥16 preflight in slash command path (matches `postinstall.js:102-107`).
- L316 of `rlp-desk.md` ("`run_ralph_desk.zsh` spawns claude CLI to generate SV report") must be **deleted** — Node leader generates SV directly via `generateSVReport()`.
- **Dynamic-arg quoting (codex Critic v5.5)**: every dynamic CLI argument emitted by the slash command — `<slug>`, `--worker-model VALUE`, `--verifier-model VALUE`, `--final-verifier-model VALUE`, `--consensus-model VALUE`, `--final-consensus-model VALUE`, `--flywheel-model VALUE`, `--flywheel-guard-model VALUE` — must pass through the `shellQuote()` helper (§4.12) before emission. A slug or model id containing brackets, spaces, single quotes, dollar signs, or backticks must not break the leader invocation. The slash command's emitted command is conceptually `node ~/.claude/ralph-desk/node/run.mjs run ${shellQuote(slug)} --mode tmux --worker-model ${shellQuote(workerModel)} ...`.

### 4.2 Deprecation banner — `src/scripts/run_ralph_desk.zsh`

Replace the RC-1 force-disable block (L62-68) and add a top-of-script gate:

```zsh
if [[ -n "${FLYWHEEL:-}" || -n "${FLYWHEEL_GUARD:-}" || "${WITH_SELF_VERIFICATION:-0}" == "1" ]]; then
  print -u2 "ERROR: --flywheel and --with-self-verification require the Node leader."
  print -u2 "       run_ralph_desk.zsh no longer supports them as of 0.12.0."
  print -u2 ""
  print -u2 "Use: node \"\${DESK_DIR:-\$HOME/.claude/ralph-desk}/node/run.mjs\" run \"\$LOOP_NAME\" --mode tmux \\"
  print -u2 "       ${FLYWHEEL:+--flywheel \"$FLYWHEEL\"} ${FLYWHEEL_MODEL:+--flywheel-model \"$FLYWHEEL_MODEL\"} \\"
  print -u2 "       ${FLYWHEEL_GUARD:+--flywheel-guard \"$FLYWHEEL_GUARD\"} ${FLYWHEEL_GUARD_MODEL:+--flywheel-guard-model \"$FLYWHEEL_GUARD_MODEL\"} \\"
  if [[ "${WITH_SELF_VERIFICATION:-0}" == "1" ]]; then
    print -u2 "       --with-self-verification"
  fi
  exit 2
fi
print -u2 "[notice] run_ralph_desk.zsh is deprecated as of 0.12.0. Prefer: node node/run.mjs run --mode tmux ..."
```

Quoting tightened (Architect feedback) — defends against IFS surprises.

The remaining `RC-1` block (and its consumers at L858, L903, L2298, L2330) is removed: with the gate above, `WITH_SELF_VERIFICATION=1` cannot reach this code path.

### 4.3 Governance update — `src/governance.md`

§6½ — confirm flywheel mode-agnostic (no caveat). Add an SV note: *"--with-self-verification is supported in both agent and tmux modes via the Node leader."*

### 4.4 Distribution parity — npm AND curl install paths

| Path | Today | After |
|------|-------|-------|
| npm postinstall (`scripts/postinstall.js:123` `copyNodeRuntime`) | Copies `src/node/` → `~/.claude/ralph-desk/node/`. ✅ Already correct. | Unchanged. |
| `install.sh` curl-pipe-shell | Downloads `*.zsh` + markdown only. ❌ No Node sources. | **Manifest-driven**: ship `src/node/MANIFEST.txt` (one relative path per line, regenerated by `scripts/build-node-manifest.js`, run as `prepublishOnly`). `install.sh` curls the manifest then curls each listed file into `$DESK_DIR/node/<relpath>`. |

Why manifest, not `git archive` / `npm pack`: keeps curl-install dependency-free (Architect tradeoff DR-1 vs DR-4), and the manifest regenerator runs in CI so it cannot rot.

**Drift prevention (Critic MINOR)**: `prepublishOnly` alone runs only at `npm publish`, so a developer who commits a new Node file would push a stale manifest to `main` and break curl install before the next release. Add a CI step on every PR: regenerate the manifest in a temp file, then `git diff --exit-code MANIFEST.txt -- src/node/MANIFEST.txt`. Fail the PR if drift is detected.

### 4.5 Local sync rule — `CLAUDE.md`

Replace the "Runtime files" sync block addition with:

```text
src/node/**                            → ~/.claude/ralph-desk/node/  (recursive)
```

Verification block adds:

```bash
rsync -an --delete src/node/ ~/.claude/ralph-desk/node/ | grep -v '^$' && echo "DRIFT" || echo "OK"
diff -rq src/node ~/.claude/ralph-desk/node
```

Both must report no diff.

### 4.6 Telemetry / 4-category log parity (Architect flag)

Confirm Node leader writes `[GOV]`, `[DECIDE]`, `[OPTION]`, `[FLOW]` lines to `debug.log` for tmux mode the same way the zsh runner does (zsh: L2330). If not, port. Acceptance: identical 4-category prefixes appear in tmux and agent debug logs. Add to §5.2 regression.

### 4.7 SV report parity (Architect flag)

Confirm Node leader's `generateSVReport()` produces the same artifact set as the zsh runner used to (campaign-report.md + self-verification-report.md + self-verification-data.json under `~/.claude/ralph-desk/analytics/<slug>/`). Add to §5.2 regression. Cross-reference `tests/test_us012_sv_tmux_skip_traceability.sh` — that test's pre-existing assertion on `sv_skipped_reason=tmux_runner` must be **inverted**: after this change, tmux SV must NOT be skipped.

### 4.8 `lib_ralph_desk.zsh` disposition (Architect flag)

`postinstall.js` legacy cleanup deletes orphan zsh files on each install. `lib_ralph_desk.zsh` is still part of `runtimeSources`. With the deprecated zsh runner retained, lib must remain distributed. State explicitly in CLAUDE.md sync rule. No change unless the runner is removed in 0.13.x.

### 4.9 Opus 1M context auto-enable

**Rationale**: Anthropic's Claude API exposes the 1M-token context window for Opus via the beta header `context-1m-2025-08-07`. The `claude` CLI honors this when invoked with `ANTHROPIC_BETA=context-1m-2025-08-07` in the environment. RLP Desk dispatches Opus for Verifier, Final Verifier, Flywheel, and Guard roles routinely; long-running campaigns hit the default 200K context ceiling on dense PRDs + verdict histories + traceability artifacts. Auto-enabling 1M context for Opus removes the silent truncation footgun without requiring per-call flags.

**Implementation surface (4 call sites)**:

1. `src/node/cli/command-builder.mjs:11-30 buildClaudeCmd()` — when `model === 'opus'`, prepend `ANTHROPIC_BETA="context-1m-2025-08-07"` to the env preamble (alongside `DISABLE_OMC=1`).
2. `src/node/runner/campaign-main-loop.mjs:572 buildFlywheelTriggerCmd()` — same prepend when `flywheelModel === 'opus'`.
3. `src/node/runner/campaign-main-loop.mjs:585 buildGuardCmd()` — same prepend when `guardModel === 'opus'`.
4. `src/scripts/lib_ralph_desk.zsh:45 base=` — same prepend when `$model == "opus"` (kept for the deprecated zsh runner's remaining valid uses; failing to honor it would silently regress Opus campaigns started via direct zsh).

**Constant**: extract the beta header literal to one place — add `export const OPUS_1M_BETA = 'context-1m-2025-08-07';` in a new `src/node/constants.mjs` (or co-locate in `command-builder.mjs`). Other three sites import / reference it. zsh path mirrors via a `readonly OPUS_1M_BETA="context-1m-2025-08-07"` near the top of `lib_ralph_desk.zsh`.

**Acceptance**: Unit test asserts `buildClaudeCmd('tui', 'opus')` output contains `ANTHROPIC_BETA="context-1m-2025-08-07"` and `buildClaudeCmd('tui', 'sonnet')` does NOT. Integration test snapshots `tmux send-keys` payloads for flywheel/guard panes when `--flywheel-model opus` and `--flywheel-guard-model opus` and asserts the env prefix. Negative test: `--worker-model sonnet` produces no prefix.

**No CLI flag**: do NOT add `--opus-1m on|off`. The whole point is to make 1M the implicit default for Opus. If a future user wants to opt out, they can override `ANTHROPIC_BETA=` upstream of the slash command — a documented escape hatch, not a maintained flag.

### 4.10 Install-file write protection

**Rationale**: Across multi-project parallel work, a Claude session in project B may directly edit `~/.claude/ralph-desk/lib_ralph_desk.zsh` to fix a perceived issue, breaking the canonical-source invariant from CLAUDE.md "Local File Sync". This already happened (see §0 v5 trigger #1).

**Implementation**:

1. `scripts/postinstall.js` and `install.sh` both, after copying any file into `~/.claude/ralph-desk/` (or `~/.claude/commands/rlp-desk.md`), perform two operations:
   a. Inject a banner header. **Per-extension format** (Planner v5.1 correction — `# DO NOT EDIT` text leaks into rendered `.md` docs):
      - `.md` files: `<!-- DO NOT EDIT — generated from <source-rel-path>. Edit source and re-sync. -->` on line 1.
      - `.zsh` / `.sh` (shebang line 1): keep `#!` on line 1, banner `# DO NOT EDIT — generated from <source-rel-path>. Edit source and re-sync.` on line 2.
      - `.mjs` / `.js` (no shebang in current sources): `// DO NOT EDIT — generated from <source-rel-path>. Edit source and re-sync.` on line 1.
      - `.json` (none today): no inline banner; rely on `chmod a-w` alone. Future JSON additions get a sidecar `<file>.banner.txt`.
   b. **`chmod a-w` ordering — Planner v5.1 fix (R-V5-1 release-blocker)**: postinstall.js cannot `fs.copyFileSync()` over a `chmod a-w` target — fails with EACCES on every upgrade. Required pseudocode for every copy site (`copyMarkdownDirectory`, `copyNodeRuntime`, every direct `fs.copyFileSync` in postinstall.js):
      ```js
      if (existsSync(target)) { fs.chmodSync(target, 0o644); }   // unlock if already write-protected
      fs.copyFileSync(src, target);
      injectBanner(target);                                       // per-extension rule above
      fs.chmodSync(target, 0o444);                                // a-w lock
      ```
      Same logic in `install.sh` — **hard-fail per v5.2 Architect (R-V5-6)**, NEVER swallow errors:
      ```bash
      set -e   # hard-fail mandatory
      if [[ -e "$target" ]]; then
        chmod u+w "$target" || { echo "[install] FATAL: cannot unlock existing $target. Filesystem may be read-only or unsupported."; exit 1; }
      fi
      curl -fsSL "$url" -o "$target" || { echo "[install] FATAL: download failed for $url"; exit 1; }
      inject_banner "$target"
      chmod a-w "$target" || { echo "[install] WARNING: chmod a-w failed on $target. Filesystem may not honor POSIX mode bits (WSL1/NTFS/tmpfs); cross-session edit protection unavailable."; }
      ```
      The final `chmod a-w` is warning-only because R-V5-5 acknowledges some filesystems silently no-op chmod; the upgrade still completes correctly there, just without the lock-down benefit.
2. The banner is detected by re-syncing logic in CLAUDE.md's `diff -q` step — if a re-synced file's banner matches but a deeper line differs, the source/install drift is genuine; if banner is absent on a file that should have one, an unauthorized direct edit happened and the install/sync block reports it as TAMPER detected.
3. New helper script `scripts/sync-installed.sh` that any project can invoke to force re-sync from a checked-out source tree (eliminates the "I don't want to npm install" excuse). Same chmod ordering applies.

**Out of scope**: signing or hash verification — banner + chmod is sufficient for this threat model (cooperating tools, not malicious actors).

### 4.11 Autonomous-mode permission integrity

**Rationale**: `--dangerously-skip-permissions` covers Claude Code's slash-command permission tier but not cross-cwd writes by the spawned `claude` process. Today, Worker prompts reference `~/.claude/ralph-desk/analytics/<slug>/debug.log` (home-tree write) and `~/.claude/ralph-desk/run_ralph_desk.zsh` (home-tree read), forcing prompts on every campaign even with skip-permissions on. The user's directive: rlp-desk is autonomous; all in-prompt paths must be project-relative; cross-project rollup must not leak into Worker's prompt surface.

**Three coordinated changes**:

#### 4.11.a `--add-dir` whitelist on every claude invocation

In `src/node/cli/command-builder.mjs:11-30 buildClaudeCmd()`, accept a `cwdRoot` and add:

```js
parts.push('--add-dir', `"${homeRalphDeskDir}"`, '--add-dir', `"${cwdRoot}"`);
```

Mirror in `lib_ralph_desk.zsh:45 base=` and the two campaign-main-loop builders (`buildFlywheelTriggerCmd`, `buildGuardCmd`). Worker inherits cwd = `cwdRoot` so the second `--add-dir` is technically redundant, but kept explicit for resilience to future cwd refactors.

#### 4.11.b Per-campaign analytics move project-local

Migrate the per-`<slug>` analytics directory from `~/.claude/ralph-desk/analytics/<slug>/` to `<project-root>/.claude/ralph-desk/analytics/<slug>/`. **Planner v5.1 correction** — actual surface is ~28 sites, not 12 as v5 estimated:

- `src/scripts/init_ralph_desk.zsh` — write metadata.json, debug.log paths.
- `src/scripts/run_ralph_desk.zsh:249` — `ANALYTICS_DIR="$HOME/.claude/ralph-desk/analytics/${SLUG}--..."` ← actual write site, must thread `$ROOT`.
- `src/node/runner/campaign-main-loop.mjs:60` — `analyticsDir: path.join(os.homedir(), '.claude', 'ralph-desk', 'analytics', slug)` ← **the actual Node write site**, must accept `projectRoot` and join from there.
- ~14 internal call-sites in `campaign-main-loop.mjs` and `campaign-reporting.mjs` that thread `analyticsFile` / `analyticsDir`.
- `src/node/reporting/campaign-reporting.mjs:568-575` (SV report write).
- `src/commands/rlp-desk.md` lines 121, 264, 267, 275, 316, 333, 530, 541, 542, 673, 704, 718, 751 (12 references rewritten to `.claude/ralph-desk/analytics/<slug>/`).
- `src/governance.md:499` (analytics path documentation).
- `tests/node/test-sv-report.mjs` (8 fixture references — fixture paths only, but must be updated to mirror the new layout for accurate test coverage).

After this, every Worker/Verifier prompt path is project-relative. The clean command's gitignore guidance covers `.claude/ralph-desk/analytics/`.

**Effort note**: §4.11.b is the largest chunk in the plan — threading `projectRoot` through ~10 Node call sites is mechanical but touchy. Allocate a separate stacked commit for the threading work and another for the rlp-desk.md / governance.md text edits.

#### 4.11.c Registry index for cross-project rollup

To preserve cross-project status visibility, the Leader writes one line per campaign-state-change to `~/.claude/ralph-desk/registry.jsonl`:

```jsonl
{"ts":"2026-04-27T15:00:00Z","slug":"my-feat","project_root":"/Users/.../my-project","status":"running","worker_model":"opus","verifier_model":"opus"}
{"ts":"2026-04-27T16:42:00Z","slug":"my-feat","project_root":"/Users/.../my-project","status":"complete"}
```

The status command (`/rlp-desk status` without slug) reads `registry.jsonl` and dereferences each `project_root` to read that project's local analytics. Worker/Verifier never see this file. This is one home-tree write per state change made by the Leader process only, which already runs in the slash-command tier where `--dangerously-skip-permissions` plus the new `--add-dir` whitelist applies.

**Leader-only guardrail (Planner v5.1 add)**: Worker / Verifier / Flywheel / Guard prompt templates MUST NOT reference `registry.jsonl`. Enforce via CI lint:

```bash
# fail PR if any Worker/Verifier-bound prompt mentions registry.jsonl
grep -rn 'registry\.jsonl' src/commands src/scripts src/node | grep -v -E '^[^:]+:[^:]+:.*(Leader|leader)' && exit 1 || exit 0
```

Only the Leader (slash-command-tier process) ever opens this file. With §4.11.a `--add-dir "$HOME/.claude/ralph-desk"` covering it, the Leader's append succeeds without prompts; Workers never see the path so cwd-escape never triggers.

**Migration**: a one-time `~/.claude/ralph-desk/migrate-v0.12.sh` (run once via postinstall on first 0.12 install) walks `~/.claude/ralph-desk/analytics/*/metadata.json`, reads each `project_root`, and copies the slug dir into `${project_root}/.claude/ralph-desk/analytics/<slug>/`, then writes a registry.jsonl entry. **Idempotency rules (Planner v5.1)**:

- Idempotent re-run: if `${project_root}/.claude/ralph-desk/analytics/<slug>/.migrated` marker exists, skip.
- Stale source: if `metadata.json.project_root` directory no longer exists (Planner verified 46 existing dirs, many point to deleted tmp dirs), log to `migrate-v0.12.log` as `skip_stale_root` and continue — do NOT abort the whole migration.
- Preserve: home `~/.claude/ralph-desk/analytics/` is renamed to `analytics.legacy.<timestamp>/` only AFTER all reachable slugs migrate successfully. If any in-flight failure occurs, no rename — operator can re-run.
- Documented in 0.12 release notes.

### 4.12 Defensive shell-quoting of model values (Bug 1 fix)

**Rationale (external bug report Bug 1, HIGH)**: The `--model $model` invocation in `lib_ralph_desk.zsh:45` and the equivalent in `command-builder.mjs:18` / `campaign-main-loop.mjs:572,585` emit the model id unquoted into a zsh-evaluated command string. A model id like `claude-opus-4-7[1m]` (Opus 1M-context bracket-id form, used by some users instead of the `ANTHROPIC_BETA` env-var path adopted in §4.9) is parsed by zsh as a character-class glob, the glob fails to match any file, and the Worker process dies → BLOCKED `infra_failure: Worker process dead/stuck`.

**Implementation surface (4 call sites — same as §4.9 Opus 1M)**:

1. `src/scripts/lib_ralph_desk.zsh:45` — use zsh's built-in `${(qq)var}` expansion modifier, which produces a single-quote-escaped form that handles brackets, spaces, and embedded single quotes correctly. Concrete change:
   ```zsh
   # BEFORE (Bug 1):
   local base="DISABLE_OMC=1 $CLAUDE_BIN --model $model --mcp-config '...'"
   # AFTER (v5.5 — codex Critic clarified):
   local base="DISABLE_OMC=1 $CLAUDE_BIN --model ${(qq)model} --mcp-config '...'"
   ```
   `${(qq)model}` expands the variable AND wraps the result in single quotes with proper internal escaping. Verified: zsh `print -- ${(qq)foo}` for `foo='claude-opus-4-7[1m]'` emits `'claude-opus-4-7[1m]'` (literal brackets safe); for `foo="model'with'quote"` emits `'model'\''with'\''quote'` (POSIX-correct escape).
   **Important — NOT `--model '$model'`**: that literal would pass the string `$model` (single quotes suppress expansion). The `${(qq)model}` modifier is the only correct primitive in zsh; bash equivalent is `printf '%q' "$model"`.
2. `src/node/cli/command-builder.mjs:18 buildClaudeCmd()` — instead of `parts.push('--model', model)`, push the model with shell-safe single-quote escaping:
   ```js
   // src/node/util/shell-quote.mjs
   export function shellQuote(s) {
     return "'" + String(s).replace(/'/g, "'\\''") + "'";
   }
   // command-builder.mjs:
   parts.push('--model', shellQuote(model));
   ```
   The `'\''` POSIX escape closes the single-quote, inserts an escaped literal single-quote, then reopens — survives all reasonable shells (sh/bash/zsh/dash).
3. `src/node/runner/campaign-main-loop.mjs:572 buildFlywheelTriggerCmd()` — same `shellQuote()` wrap on `flywheelModel`.
4. `src/node/runner/campaign-main-loop.mjs:585 buildGuardCmd()` — same wrap on `guardModel`.

**Same `shellQuote()` helper applies to all dynamic CLI args** (codex Critic v5.5 §4.1 clarification): the slash command's outer shell-tier emission of `node ~/.claude/ralph-desk/node/run.mjs run "<slug>" --worker-model <model> ...` must also pass `slug`, `worker-model`, `verifier-model`, `final-verifier-model`, `flywheel-model`, `flywheel-guard-model` through `shellQuote()` (or zsh `${(qq)...}`) before emission. A slug containing a backtick, dollar sign, or shell metachar must not break the leader invocation. Document this rule in §4.1 explicitly.

**Cross-cutting**: also wrap `--worker-model`, `--verifier-model`, `--final-verifier-model`, `--flywheel-model`, `--flywheel-guard-model` values in the slash-command's Node leader invocation (§4.1) — a model id with brackets must survive the `node ~/.claude/ralph-desk/node/run.mjs run --worker-model 'claude-opus-4-7[1m]' ...` shell tier *and* the inner claude CLI invocation.

**Unit test**: parametrized over the model id list in G11 — assert each builder produces a string that, when re-parsed by zsh, yields the original model id literal.

**Note vs §4.9 Opus 1M**: §4.9 standardizes the env-var approach (`ANTHROPIC_BETA=context-1m-2025-08-07`) which keeps `--model opus` (no brackets). §4.12 is the defensive fix for users who pass bracketed model ids directly anyway. Both ship in 0.12.0; they are independent, non-overlapping.

### 4.13 Mid-execution permission-prompt auto-dismiss (Bug 4 fix)

**Rationale (external Bug 4, HIGH)**: claude CLI v2.1.114 with `--dangerously-skip-permissions` STILL surfaces TUI-layer prompts (`Do you want to create <file>?`, `Do you trust this directory?`, `Confirm execution`, `Are you sure`) on certain Write tool paths. Without auto-dismiss in the polling loop, Worker hangs until `IDLE_NUDGE_THRESHOLD` (default 30s) and possibly times out at `MAX_NUDGES`. Planner-verified: `poll_worker_for_signal()` at `run_ralph_desk.zsh:1828-1836` already has partial coverage; **`check_and_nudge_idle_pane()`, verifier-poll sites, brainstorm/init pane-wait, and the entire Node leader poll path do NOT.**

**Implementation surface**:

#### 4.13.a zsh runner — extract reusable helper

Refactor `run_ralph_desk.zsh:1828-1836` into a top-level helper, plus per-pane debounce map. **codex Critic v5.7 corrections applied**: enforce true line-adjacency (not whole-capture dual grep), and explicit `EPOCHSECONDS` portability via `zsh/datetime` module with `date +%s` fallback.

```zsh
# Top-of-file: portable epoch primitive
zmodload zsh/datetime 2>/dev/null || true
_now_s() { print -- "${EPOCHSECONDS:-$(date +%s)}"; }

typeset -gA LAST_AUTO_APPROVE_TS  # epoch per pane_id, debounce 3s

# Patterns are line-bound: prompt phrase on one line, affordance on the SAME, PREVIOUS, or NEXT line.
_PROMPT_RE='Do you (want to|trust)|Confirm execution|Are you sure|Continue\?'
_AFFORDANCE_RE='\(y/n\)|\[Y/n\]|\[y/N\]|❯ 1\.|^[[:space:]]*1\) Yes'

auto_dismiss_prompts() {
  local pane_id="$1"
  local now=$(_now_s)
  local last=${LAST_AUTO_APPROVE_TS[$pane_id]:-0}
  (( now - last < 3 )) && return 0

  local capture
  capture=$(tmux capture-pane -t "$pane_id" -p -S -10 2>/dev/null) || return 0

  # Walk lines; for each line matching _PROMPT_RE, check ±1 line for _AFFORDANCE_RE.
  local -a lines
  lines=("${(@f)capture}")
  local i n=${#lines[@]}
  for ((i=1; i <= n; i++)); do
    if [[ "${lines[i]}" =~ $_PROMPT_RE ]]; then
      local prev="${lines[i-1]:-}"
      local cur="${lines[i]}"
      local next="${lines[i+1]:-}"
      if [[ "$prev" =~ $_AFFORDANCE_RE || "$cur" =~ $_AFFORDANCE_RE || "$next" =~ $_AFFORDANCE_RE ]]; then
        log "[FLOW] permission_prompt_auto_approved=true pane=$pane_id"
        tmux send-keys -t "$pane_id" Enter 2>/dev/null
        LAST_AUTO_APPROVE_TS[$pane_id]=$now
        return 0
      fi
    fi
  done
}
```

**Why this matters (codex Critic v5.7 HIGH finding)**: a whole-capture dual-grep would let unrelated `Do you want to learn more` (in pane line 3) plus an unrelated `(y/n)` (in pane line 9 — say, from a previous prompt remnant) trigger Enter. The window-bounded check (±1 line) ensures the affordance is part of the SAME prompt block, not arbitrary nearby text.

Call sites — replace the inline grep with `auto_dismiss_prompts "$pane_id"`:
1. `check_and_nudge_idle_pane()` — at function entry, before idle check (Bug 4's specific complaint).
2. `poll_worker_for_signal()` — replace existing inline block.
3. `poll_verifier_for_signal()` (and any final-verifier / consensus poll variant) — currently uncovered.
4. Brainstorm / init pane-wait paths — uncovered.

The pattern `Do you want to` is broad (covers create/overwrite/edit/delete/append/etc); explicitly DO NOT narrow to `(create|overwrite|edit|delete)` per Planner v5.6 — broader is safer.

#### 4.13.b Node leader — new module

Create `src/node/runner/prompt-dismisser.mjs`. **codex Critic v5.7 correction applied**: enforce true line-adjacency (±1 line window), not whole-capture independent matches.

```js
const PROMPT_RE = /Do you (want to|trust)|Confirm execution|Are you sure|Continue\?/;
const AFFORDANCE_RE = /\(y\/n\)|\[Y\/n\]|\[y\/N\]|❯ 1\.|^\s*1\) Yes/;
const DEBOUNCE_MS = 3000;
const lastApprovalAt = new Map();

export async function autoDismissPrompts(paneId, sendKeys, capturePane, log) {
  const now = Date.now();
  if (now - (lastApprovalAt.get(paneId) ?? 0) < DEBOUNCE_MS) return false;

  const capture = await capturePane(paneId, { startLine: -10 }).catch(() => '');
  if (!capture) return false;

  const lines = capture.split('\n');
  for (let i = 0; i < lines.length; i++) {
    if (!PROMPT_RE.test(lines[i])) continue;
    const prev = lines[i - 1] ?? '';
    const cur  = lines[i];
    const next = lines[i + 1] ?? '';
    if (AFFORDANCE_RE.test(prev) || AFFORDANCE_RE.test(cur) || AFFORDANCE_RE.test(next)) {
      log({ category: 'FLOW', event: 'permission_prompt_auto_approved', pane_id: paneId });
      await sendKeys(paneId, 'Enter');
      lastApprovalAt.set(paneId, now);
      return true;
    }
  }
  return false;
}
```

Call from the top of every poll iteration in `signal-poller.mjs` and `campaign-main-loop.mjs:pollForSignal()`. Same pattern set, same window-bounded affordance guard (prompt line ±1 line), same 3-second debounce.

#### 4.13.c Known-patterns list (R-V5-10 mitigation)

Optionally externalize the pattern list to `~/.claude/ralph-desk/known-prompts.txt` so future claude CLI prompt-text changes can be patched without a source release. zsh and Node both read this file at startup; missing file falls back to baked-in defaults. Out of scope for v0.12.0 if it complicates §4.10 write-protection — **deferred to 0.13.x** unless the upstream prompt text changes during 0.12.x.

#### 4.13.d Pre-existing line-1828 block disposition

The current inline `Do you want to` grep at `run_ralph_desk.zsh:1828-1836` is REPLACED by `auto_dismiss_prompts "$pane_id"`. The existing log line `"Permission prompt detected during poll, auto-approving..."` is rotated into the helper as a structured `[FLOW]` log entry per §4.6 telemetry parity.

---

## 5. Test Plan

### 5.1 New tests

| Test file | Purpose | Risk |
|-----------|---------|------|
| `tests/test_us0XX_tmux_flywheel_routing.sh` | E2E tmux + `--flywheel on-fail`, induce 1 FAIL, assert flywheel pane created, signal consumed, Worker re-dispatched. | MEDIUM |
| `tests/test_us0XX_tmux_flywheel_guard.sh` | E2E tmux + `--flywheel-guard on`, stub bad-direction signal, assert Guard verdict consumed, Flywheel re-runs once, then BLOCKS on exhaustion with `flywheel_exhausted` reason. | MEDIUM |
| `tests/test_us0XX_tmux_self_verification.sh` | E2E tmux + `--with-self-verification`, assert `self-verification-report.md` + `self-verification-data.json` written, `sv_skipped_reason ≠ tmux_runner`. | MEDIUM |
| `tests/test_us0XX_zsh_runner_deprecation.sh` | Unit: `FLYWHEEL=on-fail zsh run_ralph_desk.zsh` and `WITH_SELF_VERIFICATION=1 zsh ...` both exit 2 with banners. Without those vars, runs unchanged. | LOW |
| `tests/test_install_sh_includes_node_sources.sh` | Sandbox `bash install.sh` against fixture, assert `~/.claude/ralph-desk/node/run.mjs` + `node/runner/campaign-main-loop.mjs` + `node/reporting/campaign-reporting.mjs` exist post-install. **Fixture strategy**: add `REPO_URL` env-var override to `install.sh` (default `https://raw.githubusercontent.com/...`) and the test points it at a local `python3 -m http.server`-served working tree, so curl pulls from local instead of GitHub. | HIGH (release-blocker if missing) |
| `tests/node/us0XX-tmux-flywheel-pane.test.mjs` | Node-level: assert pane allocation (4-pane normal, Guard reuses flywheel pane — assert pane count + isolation by signal-file naming). | LOW |
| `tests/node/us0XX-opus-1m-context.test.mjs` | Unit + integration: `buildClaudeCmd('tui', 'opus')` and `buildFlywheelTriggerCmd({flywheelModel:'opus'})` and `buildGuardCmd({guardModel:'opus'})` all contain `ANTHROPIC_BETA="context-1m-2025-08-07"`. Same builders with `'sonnet'`/`'haiku'` do NOT. zsh equivalent in `lib_ralph_desk.zsh` covered by a separate shellcheck-friendly snapshot test. | LOW |
| `tests/test_us0XX_tmux_permission_prompt_dismiss.sh` | **Parametrized over 4 call sites (codex Critic v5.7 split)**: (1) `check_and_nudge_idle_pane()` — Worker idle ≥ IDLE_NUDGE_THRESHOLD with prompt visible; (2) `poll_worker_for_signal()` — prompt fires mid-Worker run; (3) `poll_verifier_for_signal()` — prompt fires mid-Verifier run; (4) brainstorm/init pane-wait — prompt fires during scaffold setup. For each: stub prompt text + `(y/n)` marker into pane; assert `auto_dismiss_prompts()` sends Enter within ≤ POLL_INTERVAL seconds; assert `[FLOW] permission_prompt_auto_approved=true pane=<id>` in debug.log. | MEDIUM |
| `tests/node/us0XX-permission-prompt-dismiss.test.mjs` | Unit + integration (Node leader path, Bug 4 §4.13.b): mock pane capture returns `Do you want to create file.json?\n(y/n)`; assert `autoDismissPrompts()` returns true and called `sendKeys(paneId, 'Enter')` once. Negative: capture returns `Do you want to learn more about Rust?` with no affordance marker; assert returns false and `sendKeys` NOT called. Debounce: two consecutive captures within 3s — second returns false. | MEDIUM |
| `tests/test_us0XX_false_positive_no_dismiss.sh` | Negative E2E (G12): Worker stubs print `Do you want to learn more about Rust?` (no `(y/n)` marker on adjacent line); assert NO Enter sent; pane content preserved. Idempotent. | LOW |

### 5.2 Regression (must remain green)

```text
tests/test_us006_init_presets.sh
tests/test_us012_sv_tmux_skip_traceability.sh        # assertion must be INVERTED in this PR
tests/test_us021_consecutive_blocks.sh
tests/test_us023_cost_log_nonempty.sh
tests/test_us024_pane_lifecycle.sh
tests/test_us025_session_disambiguation.sh
tests/test_us026_runner_lockfile.sh
tests/test_self_verification_0_11_1.sh
tests/node/us006-campaign-main-loop.test.mjs
tests/node/test-flywheel.mjs
tests/node/test-flywheel-guard.mjs
tests/node/test-sv-flywheel-guard.mjs
```

Plus telemetry parity (§4.6) and SV artifact parity (§4.7) checks.

### 5.3 Self-Verification (governance §1f, CLAUDE.md gate — all 3 must PASS)

| Scenario | Risk | Levels |
|----------|------|--------|
| 1. `--mode tmux --flywheel off` (no-op routing path; baseline preservation) | LOW | L1 + L3 |
| 2. `--mode tmux --flywheel on-fail --with-self-verification` end-to-end with one induced FAIL; verify SV artifacts AND flywheel signal both consumed in same campaign | MEDIUM | L1 + L2 + L3 (real integration) |
| 3. `--mode tmux --flywheel on-fail --flywheel-guard on` with retry-on-`fail` and final BLOCK on retries-exhausted; assert pane-count = 4, Guard verdict file isolated from Flywheel signal file | CRITICAL | L1 + L2 + L3 + security check + L3 error-path E2E |

---

## 6. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Curl-install user (`bash install.sh`) has no Node leader after upgrade → `/rlp-desk run --mode tmux` fails with `MODULE_NOT_FOUND`. | HIGH (without §4.4 fix) → LOW (with) | HIGH | §4.4 manifest-driven install + §5.1 smoke test as release-blocker. |
| Node leader's tmux pane management has subtle behavioral diffs vs. zsh runner (engine-swap risk per Architect antithesis). | MEDIUM | HIGH | All US-024/025/026 tests run on Node path explicitly before publish. Optional Q4 phasing fallback to 0.13.x flywheel/SV enable. |
| Users with hardcoded `run_ralph_desk.zsh` in CI/scripts break silently. | MEDIUM | MEDIUM | Banner is non-fatal for non-flywheel/non-SV uses. Release notes user-facing changes. |
| `install.sh` regression — manifest forgets a new Node file, breaks curl install. | MEDIUM | MEDIUM | Manifest regenerated by `prepublishOnly` script + `tests/test_install_sh_includes_node_sources.sh` smoke. |
| `flywheel_pane_id` / Guard pane collision on small terminals. | LOW | LOW | Existing `tests/node/us006-campaign-main-loop.test.mjs:151` covers 4-pane layout; new §5.1 test asserts Guard reuses flywheel pane and verdict file naming prevents collision. |
| Env-var users (`BLOCK_CB_THRESHOLD=10 zsh ...`) silently lose configuration after slash command translates only known env vars. | MEDIUM | LOW | Slash command translates the documented set (BLOCK_CB_THRESHOLD, LANE_MODE, TEST_DENSITY_MODE). Direct zsh users are unaffected (they still use env vars). Document explicitly. |
| Telemetry schema drift — Node leader misses one of `[GOV]/[DECIDE]/[OPTION]/[FLOW]` categories → analytics break. | LOW | MEDIUM | §4.6 + §5.2 parity check. |
| Inverting `tests/test_us012_sv_tmux_skip_traceability.sh` accidentally ratifies a regression. | LOW | MEDIUM | Inversion done as a separate commit with rationale comment + before/after fixtures. |
| Opus 1M context auto-enable causes silent cost surprise — Anthropic prices >200K-token Opus requests at a higher tier; campaigns that never needed 1M may now incur higher per-call cost when they happen to exceed 200K. | MEDIUM | MEDIUM | (a) Document the auto-enable explicitly in 0.12 release notes user-facing section. (b) Add a `[OPTION]` debug.log line emitted at loop start when any opus-routed role is configured: `[OPTION] opus_1m_context=on (beta=context-1m-2025-08-07)`. (c) `cost-log.jsonl` already records per-call usage; the existing analytics surface makes the cost diff visible without new infra. |
| Anthropic deprecates or renames the `context-1m-2025-08-07` beta header. | LOW | MEDIUM | Single-source constant `OPUS_1M_BETA` in `src/node/constants.mjs` (and zsh mirror) — one-line update on header rotation. Add a brief comment citing Anthropic docs URL beside the constant. |
| `~/.claude/ralph-desk/registry.jsonl` drifts when a campaign is killed mid-run (no `complete` line written) → `/rlp-desk status` shows stale `running` entries. | MEDIUM | LOW | Status command treats entries with `ts` older than the campaign's heartbeat-stale threshold as `stale`; offer `/rlp-desk clean --reap` to mark them `aborted`. Append-only never breaks; it only accumulates. |
| `--add-dir` whitelist incomplete → Worker still hits a yes/no prompt for an edge-case path (e.g., a worktree's main-tree git dir). | LOW | MEDIUM | G10 smoke test asserts zero prompts. If hit in the wild, fix is additive: add another `--add-dir` to the whitelist; non-breaking. |
| Migration script `migrate-v0.12.sh` fails or partially completes (e.g., `project_root` no longer exists). | MEDIUM | LOW | Migration is idempotent: re-runs skip already-migrated slugs. On unreachable `project_root`, log to `~/.claude/ralph-desk/migrate-v0.12.log` and skip rather than abort. Legacy dir kept for one minor as fallback. |
| Banner header injection breaks shebang parsing on `*.zsh` files (banner inserted before `#!/bin/zsh`). | LOW | HIGH | Injection rule: if first line starts with `#!`, banner goes on line 2; otherwise line 1. Unit-test both cases. **Per-extension format** mandatory (§4.10 v5.1): `.md` uses `<!-- ... -->`, `.mjs/.js` uses `// ...`, `.zsh/.sh` uses `# ...`. |
| **R-V5-1** postinstall.js `fs.copyFileSync` over a `chmod a-w` target → EACCES on every 0.12.0 upgrade. Release-blocker if chmod-before-copy ordering missing. | HIGH (without §4.10b fix) → LOW (with) | HIGH | §4.10 v5.1 mandates `chmodSync(target, 0o644)` BEFORE every copy then `chmodSync(0o444)` AFTER. Same in `install.sh` via `chmod u+w` / `chmod a-w`. Unit test simulates pre-locked target then re-installs. |
| **R-V5-2** `# DO NOT EDIT` banner pollutes rendered Markdown in `~/.claude/ralph-desk/README.md` etc. | MEDIUM (without per-ext fix) → LOW (with) | LOW | §4.10 v5.1 per-extension banner format keeps `<!-- ... -->` invisible in rendered Markdown. |
| **R-V5-3** §4.11.b scope underestimated — 28 sites including 10 Node call-sites threading `projectRoot`. | MEDIUM | LOW | Allocate separate stacked commits (threading vs text edits) per §4.11.b note. CI: assert no `os.homedir()` reference inside `analyticsDir` derivation in `campaign-main-loop.mjs` after migration. |
| **R-V5-4** Stale `project_root` entries (deleted tmp dirs) in 46 existing analytics → migration loud-skips. | LOW | LOW | `migrate-v0.12.log` records every skip with reason `skip_stale_root`. Cosmetic only; idempotent. |
| **R-V5-5** WSL1 / NTFS / `tmpfs` silent `chmod` no-op → install completes but write-protect inactive; cross-session edits succeed without TAMPER detection. | LOW | MEDIUM | postinstall.js after `chmodSync(0o444)` calls `fs.statSync().mode & 0o222` and warns `[install] WARNING: filesystem does not honor chmod a-w; cross-session edit protection unavailable.` install.sh similarly. Documented in 0.12 release notes "known limitations". |
| **R-V5-6** install.sh `chmod u+w "$target" 2>/dev/null \|\| true` silently swallows real failures (Architect Pre-mortem #2). | MEDIUM | MEDIUM | Replace with hard-fail variant per §4.10 v5.2; `set -e` at top of install.sh; explicit `\|\| { echo FATAL ...; exit 1; }` on every chmod. |
| **R-V5-7** Worktree campaigns silently lose analytics when worktree is `git worktree remove`'d. | LOW | LOW | `<project-root>` resolves to worktree per §4.11.b v5.2; `~/.claude/ralph-desk/registry.jsonl` retains the entry as the Leader's record. On registry read, missing project-root → mark `archived` not `running`. |
| **R-V5-8** Concurrent campaigns in the same project. | LOW | MEDIUM | Two-tier lock per §4.11.b v5.3 — home tree US-026 `.lock` arbitrates Leader registry mutex; project tree `<project>/.claude/ralph-desk/locks/<slug>.lock` is **per-slug** (one file per campaign, allowing parallel slugs in the same project). flock semantics on each slug-specific lock. Documented limit: ≤4 concurrent campaigns per project (resource bound, not a hard semantic). Test: spawn 2 same-project campaigns with distinct slugs simultaneously, assert both complete without lock contention. |
| **R-V5-9** False-positive auto-Enter from §4.13 disrupts intentional Worker output containing literal text like `Do you want to learn more`. | MEDIUM | HIGH | Two-layer guard: (1) require BOTH prompt phrase AND TUI affordance marker (`(y/n)`, `[Y/n]`, `❯ 1.`, etc.) on adjacent capture lines; (2) 3-second debounce per pane prevents rapid double-Enter. G12 includes a negative test verifying non-prompt text is NOT auto-dismissed. |
| **R-V5-10** Future claude CLI versions change `Do you want to` prompt text → §4.13 patterns become stale → workers hang again. | MEDIUM | MEDIUM | (a) Pattern set kept BROAD (`Do you want to` matches all action verbs, not just `(create\|overwrite\|edit\|delete)`). (b) v0.13.x deferred enhancement: externalize patterns to `~/.claude/ralph-desk/known-prompts.txt` for hot-swap without source release. (c) `[FLOW] permission_prompt_auto_approved=true` log line surfaces in cost-log.jsonl analytics — operators can detect "auto-approve count = 0" anomaly indicating pattern drift. |

---

## 7. Out of Scope

- New flywheel cognitive patterns (CEO-pattern internalization §2 of blueprint-flywheel-enhancement.md).
- Removing `run_ralph_desk.zsh` entirely. Deferred to 0.13.x once telemetry shows zero direct invocations.
- Migrating non-tmux callers — agent mode is unaffected.

---

## 8. Rollout

1. Branch `feat/tmux-flywheel-and-sv-routing`.
2. Implement §4.1 → §4.9 in stacked commits (slash command → zsh banner → install.sh manifest → CLAUDE.md sync → governance → docs → Opus 1M constant + 4 call sites).
3. Run §5.1 + §5.2 to green.
4. Run all 3 §5.3 self-verification scenarios with full Worker+Verifier dispatch (no scaffold-only).
5. ralplan close-out (this doc) + codex review (CLAUDE.md Review Process — must reach 0 issues).
6. User approval gate per CLAUDE.md.
7. Merge → bump 0.12.0 (minor — new user-facing behavior, deprecation, distribution change) → release notes (user-facing only) → `npm publish` (explicit user approval).
8. Local sync per CLAUDE.md §"Local File Sync" using new recursive rule.
9. Verify all `diff -q` lines (recursive `src/node`) show no output.
10. Smoke: in a clean container, run `bash install.sh` then `/rlp-desk run --mode tmux ...` end-to-end.

---

## 9. Open Questions — RESOLVED (user lock-in 2026-04-27)

| # | Question | Decision |
|---|----------|----------|
| Q1 | Default `--flywheel` for `--mode tmux` | **`off`** (keep current). Documentation may recommend `on-fail` per use-case. |
| Q2 | Banner exit policy | **flywheel/SV-only exit 2**; non-flywheel/non-SV uses still print only a non-fatal `[notice]`. |
| Q3 | `install.sh` Node ≥16 preflight | **Yes** — add preflight matching `postinstall.js:102-107`. |
| Q4 | Single-shot 0.12.0 vs phased | **Single-shot 0.12.0** (routing + flywheel + SV + Opus 1M context together). Engine swap and feature enable land together. |

All four are locked. No further user gating before implementation begins on §4 changes.

---

## 10. ADR — Architecture Decision Record

**Decision**
Route `/rlp-desk run --mode tmux` from `run_ralph_desk.zsh` to the Node.js leader (`node ~/.claude/ralph-desk/node/run.mjs run --mode tmux ...`) so that `--flywheel`, `--flywheel-guard`, and `--with-self-verification` execute in tmux mode identically to agent mode. Retain the zsh runner as a deprecated entry that exits 2 with a banner when called with FLYWHEEL or WITH_SELF_VERIFICATION env vars; otherwise unchanged. Ship `src/node/**` to the curl-install path via a CI-regenerated `MANIFEST.txt`. **Auto-enable Opus 1M context** by prepending `ANTHROPIC_BETA=context-1m-2025-08-07` to every `claude` invocation that uses `--model opus`. **Lock down installed files** with banner + `chmod a-w` so cross-project Claude sessions cannot silently corrupt the canonical install. **Make autonomous-mode actually autonomous**: every claude invocation gets `--add-dir "$HOME/.claude/ralph-desk" --add-dir "$ROOT"`; per-campaign analytics relocate to project-local `.claude/ralph-desk/analytics/<slug>/`; cross-project rollup uses an append-only `~/.claude/ralph-desk/registry.jsonl` index that no Worker/Verifier prompt ever references.

**Drivers**
1. The user's runtime warning: `--with-self-verification`는 agent-mode 전용 → tmux 모드에서 자동 disable. Same silent-no-op pattern as `--flywheel`. Both root-cause to `run_ralph_desk.zsh` force-disabling features the Node leader supports.
2. R12+R13+R14 (0.11.1) tmux pane-lifecycle resilience already lives in the Node leader; rebuilding it in zsh would re-open hardened wounds (US-024/025/026).
3. CLAUDE.md §1f Self-Verification Gate triples cost when there are two implementations to verify; one path is cheaper and aligns with the blueprint §3 single-source-of-truth design.

**Alternatives considered**
- **B — Port flywheel + SV pipelines to zsh**: ~400+ LOC duplication, double SV verification cost, contradicts blueprint §3.
- **C — Hybrid IPC (zsh shells out to Node helper)**: splits one iteration across two runtimes; reintroduces lifecycle ownership ambiguity that 0.11.1 just sealed.
- **D — Loud rejection (refuse `--flywheel`/`--with-self-verification` in tmux)**: honors least-surprise but defeats the purpose — tmux is the recommended long-run mode where these features matter most.
- **Phasing (Architect synthesis)**: 0.12.0 routing only / 0.13.0 enable. Rejected as default because the routing migration's only justification is the feature gap; phasing ships an unobserved engine swap with no user-visible benefit. Kept open as Q4.

**Why chosen**
Option A is the only choice that satisfies all 5 principles simultaneously (single source of truth, least surprise, surgical change, distribution parity once §4.4 is fixed, backward compat within minor). It reuses 0.11.1 tmux hardening, eliminates the duplicated SV/flywheel logic that would require parallel verification, and turns the user's silent-no-op bug into a single-fix outcome rather than two.

**Consequences**
- (+) `--flywheel on-fail`, `--flywheel-guard on`, `--with-self-verification` all work in tmux from 0.12.0.
- (+) Opus calls automatically use 1M context — long campaigns no longer silently truncate at 200K.
- (+) Eliminates the SV-skipped traceability footnote in `tests/test_us012_sv_tmux_skip_traceability.sh` (assertion inverted).
- (+) Long-term, `run_ralph_desk.zsh` removable in 0.13.x once telemetry shows zero direct usage.
- (-) Engine-swap risk: Node leader becomes the user-facing tmux entry point for the first time; mitigated by §5.2 regression suite + §5.3 SV gate (3 scenarios) + §6 test_install_sh_includes_node_sources smoke.
- (-) Curl-install path needs the new MANIFEST mechanism (§4.4); CI drift check (§4.4) added to prevent rot.
- (-) Direct `zsh run_ralph_desk.zsh` users with FLYWHEEL/WITH_SELF_VERIFICATION env vars in CI break (exit 2 banner). Non-flywheel users unaffected.
- (-) Opus 1M context cost surprise — campaigns occasionally exceeding 200K may move into Anthropic's >200K pricing tier without an explicit opt-in. Documented in release notes; observable via `cost-log.jsonl`.
- (+) Cross-project rlp-desk sessions can no longer silently corrupt installed files (banner + chmod a-w; tamper detected on next sync).
- (+) Autonomous-mode is genuinely autonomous: zero yes/no prompts when `--dangerously-skip-permissions` is on.
- (-) One-time migration of legacy `~/.claude/ralph-desk/analytics/<slug>/` to project-local. Idempotent; logged; legacy dir preserved one minor.

**Follow-ups**
1. Q1–Q4 LOCKED (§9). No further user gating before §4 implementation.
2. Implement §4.1–§4.11 in stacked commits on `feat/tmux-flywheel-and-sv-routing-and-autonomy`.
3. CLAUDE.md update: add Node sources to recursive sync rule (§4.5) — must land in same PR.
4. Add `OPUS_1M_BETA` constant in `src/node/constants.mjs` and zsh mirror; cite Anthropic docs URL in comment for future header rotation.
5. Add banner header + `chmod a-w` logic to both `postinstall.js` and `install.sh` (§4.10).
6. Add `--add-dir` whitelist to all 4 claude invocation builders (§4.11.a).
7. Migrate every `~/.claude/ralph-desk/analytics/<slug>/` reference in code + prompts + docs to project-local (§4.11.b). Write `migrate-v0.12.sh` and registry indexer (§4.11.c).
8. Re-sync executed today (2026-04-27) to revert unauthorized `'$model'` quoting edit. No code change required for that single-event repair; §4.10 prevents recurrence.
9. 0.13.x candidate: remove `run_ralph_desk.zsh` if telemetry shows zero direct invocations across 0.12.x.
10. CI: manifest drift check (§4.4) + Node leader regression on tmux path (§5.2) + Opus 1M unit test + autonomous-mode prompt-count smoke test (G10) + install-file banner+chmod test (G9).
