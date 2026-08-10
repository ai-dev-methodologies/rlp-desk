---
description: "Fresh-context RLP Desk — brainstorm, init, run, status, logs, clean"
argument-hint: "<brainstorm|init|run|status|logs|clean> <slug> [options]"
---

# RLP Desk for Claude Code

**YOU are the leader.** You orchestrate fresh-context workers/verifiers via Agent().

The user invoked: `/rlp-desk $ARGUMENTS`

Parse the first word of `$ARGUMENTS` as the subcommand.

---

## `brainstorm <description>`

Planning phase BEFORE init. Interactively define the contract **with the user**.

You MUST ask the user about each item below. Do NOT decide for them.
Present your suggestion, then wait for the user's confirmation or change.

Ask about these items one by one (or in small groups):
1. **Slug** — short identifier (e.g., `auth-refactor`). Suggest one, ask if OK.
2. **Objective** — what the loop achieves
2.5. **Codebase Exploration** — Before proposing user stories, examine the project:
   - Read the project's entry points, key modules, and test structure
   - Identify architectural patterns in use (frameworks, conventions, test setup)
   - Note constraints the Worker will encounter (dependencies, build system, existing code style)
   - Present findings: "I explored the codebase and found: [patterns], [constraints], [existing tests]. This informs the US breakdown below."
   - If the project is new/empty, skip this step and note "greenfield project."
3. **User Stories** — discrete units with testable acceptance criteria. Propose a breakdown, ask the user to confirm/modify.
   - Apply INVEST criteria: each US must be Independent, Negotiable, Valuable, Estimable, Small, Testable.
   - **Dependency Rule (per-us mode)**:
     - Each AC may reference only the same US or earlier verified US' artifacts.
     - Forbidden in per-us mode: future-US references such as "post-iter US-(N+M) batch", "new US-(M) artifact", "windowed M\d+ verdict produced by US-(M)".
     - If cross-US measurement is unavoidable, fold the verifying AC into the last measurement US and do not reference it from earlier US.
     - Batch verify-mode (`--verify-mode batch`) allows cross-US AC because all stories are verified together; this rule applies only when `--verify-mode per-us` is used.
   - **Task Sizing (governance §1c)**: Size each US within the Worker's comfortable zone — smaller than what the Worker can handle, not at its ceiling. Max 3-4 ACs, max 2 files. If a US feels "just barely doable" for the target model, split it further.
   - Each AC MUST use Given/When/Then format with **domain language only** (no class names, API paths, DB tables):
     ```
     Given [precondition in domain language]
     When [action in domain language]
     Then [expected outcome with quantitative criteria]
     ```
   - Include at least 1 negative test per US ("must NOT happen").
   - Include boundary cases per US (empty, max, zero, concurrent).
   - **Task Type** per US: `code` | `visual` | `content` | `integration` | `infra`
   - **Risk Level** per US (governance §1c): `LOW` | `MEDIUM` | `HIGH` | `CRITICAL`
4. **Iteration Unit** — what one worker does per iteration. Explicitly ask:
   - "One US per iteration (bounded, incremental verification)?"
   - "All stories at once (faster, single verification)?"
   - Default recommendation: one US per iteration for 3+ stories.
5. **Verification Commands** — build, test, lint commands
6. **Completion / Blocked Criteria**
6.5. **위임 규칙 (Delegated Decisions)** — a campaign runs with **ZERO owner/user interaction**. Enumerate every decision class the loop could meet at runtime and pre-decide it now, so the worker never needs to ask. At minimum decide: 신규 표면/산출물 등록 관례 (how new files/surfaces get registered), 원장·레지스트리 갱신 규칙 (how ledgers/registries are updated), fixture·합성데이터 처분 (how test fixtures / synthetic data are produced and disposed), 알려진 baseline 처분 (how known baselines are rebaselined). These become the PRD's REQUIRED **위임 규칙 (Delegated Decisions)** section. Do NOT author any AC of the shape "stop and ask the owner when …": the ONLY legitimate blocked reasons are ① irreversible destruction, ② the contract itself must change, ③ a protected path would be violated. Any other "owner decision needed" is a planning miss — convert it into a delegation rule here.
7. **Worker / Verifier Model** — Evaluate PRD complexity using 5 factors (overall = highest factor), then recommend model.

   **Complexity Evaluation Table**:

   | Factor | LOW | MEDIUM | HIGH | CRITICAL |
   |--------|-----|--------|------|----------|
   | US count | 1-2 | 3-5 | 6-10 | 10+ |
   | File change scope | single | 2-5 files | 6+ files | cross-repo |
   | Logic complexity | simple | conditionals | algorithms | security |
   | External dependencies | none | 1-2 | 3+ | distributed |
   | Existing code impact | new only | modify | refactor | architecture |

   **Codex Detection** — check if codex CLI is installed (`command -v codex`).

   **Model mapping — Claude-only** (codex not installed):

   | Complexity | Worker | per-US Verifier | Final Verifier | Consensus |
   |------------|--------|-----------------|----------------|-----------|
   | LOW | haiku | claude-sonnet-5:high | claude-fable-5:max | off |
   | MEDIUM | sonnet | claude-opus-5:low | claude-fable-5:max | off |
   | HIGH | opus | claude-opus-5:high | claude-fable-5:max | off |
   | CRITICAL | opus | claude-opus-5:max | claude-fable-5:max + human | off |

   **Model mapping — Cross-engine** (codex installed, recommended; luna-first
   per governance §4 — workers start cheap, ladder escalates on observed
   failure only):

   | Complexity | Worker (cost lane) | Worker (speed lane) | per-US Verifier | Final Verifier | Consensus (per-US leg) |
   |------------|--------------------|---------------------|-----------------|----------------|------------------------|
   | LOW | gpt-5.6-luna:high | gpt-5.6-luna:high | claude-sonnet-5:high | claude-fable-5:max | gpt-5.6-luna:max (per-US leg if `--consensus all`; default final-only) |
   | MEDIUM | gpt-5.6-luna:xhigh | gpt-5.6-luna:xhigh | claude-opus-5:low | claude-fable-5:max | gpt-5.6-terra:high (per-US leg if `--consensus all`; default final-only) |
   | HIGH | gpt-5.6-luna:max | gpt-5.6-sol:medium | claude-opus-5:high | claude-fable-5:max | gpt-5.6-sol:medium (all) |
   | CRITICAL | gpt-5.6-sol:high | gpt-5.6-sol:high | claude-opus-5:max | claude-fable-5:max + human | gpt-5.6-sol:high (all) |

   Final Consensus (all complexities): `gpt-5.6-sol:xhigh`.

   **Lane question** — if any US is HIGH or above, ask the user ONCE (and log
   `[DECIDE] phase=lane lane=<cost|speed> reason=<answer>`); no question when
   all US are LOW/MEDIUM (lanes are identical there), none for CRITICAL rows
   (lane-independent):

   > This campaign contains HIGH-complexity US. Execution profile?
   > - **Long-term / cost lane (recommended for unattended/overnight
   >   campaigns)**: sol-grade quality is absorbed by terra:max; minimizes
   >   Sol usage; iterations may be slower.
   > - **Speed lane**: HIGH US go straight to sol; no terra hop.

   Compose the recommended run command from the chosen lane's Worker column
   (cost: HIGH=`gpt-5.6-luna:max` / speed: HIGH=`gpt-5.6-sol:medium`); the
   presets below illustrate the cost lane — adapt per the lane decision. Log
   `[DECIDE] phase=lane lane=<choice>`.

   **Worker model selection** (cross-engine, codex 0.144 / GPT-5.6 generation, luna-first per governance §4 — see model-upgrade-table.md for the full catalog):
   - **gpt-5.6-luna** — default recommendation for LOW/MEDIUM and the cost-lane HIGH start (see the Cross-engine table above for the exact effort per complexity; `luna:high` ≈ the old `terra:medium` quality tier per the Artificial Analysis index tie at 46, at roughly 1/10 the cost after the 2026-07-30 API price cut). Escalation up the ladder (`luna:high → luna:max` directly — the MEDIUM manual `luna:xhigh` entry also joins the ladder at `:max`, then `luna:max` jumps model to `terra:max`, escalating further to `sol:xhigh`) is automatic on observed failure only — CRITICAL rows start above the ladder and are exempt from luna-first.
   - **gpt-5.6-sol** — HIGH speed-lane start and CRITICAL start (frontier agentic model; HIGH speed lane starts at `sol:medium`, CRITICAL at `sol:high` — `sol:xhigh` is the final ladder ceiling, so starting below it keeps upgrade headroom)
   - **gpt-5.6-terra** — manual quota-first start (`terra:max` ≈ the sol:high–xhigh quality midpoint, slower than sol; escalates to `sol:xhigh` on repeated failure) — not a brainstorm default, but available via `--worker-model` when Sol quota is the binding constraint
   - **gpt-5.5 / gpt-5.4 / gpt-5.4-mini** — previous-generation models, still fully supported (low..xhigh ladders) if the account lacks 5.6 access
   - **spark:high** — only when US is small enough for spark's 100k context (single-file, AC count <= 4, simple logic). Do NOT use as primary recommendation — spark context window is too small for most tasks
   - Aliases: `sol`/`terra`/`luna`/`spark` expand to their full slugs; `max`/`ultra` reasoning efforts exist only on the 5.6 family, and only `max` exists for `luna` (no `luna:ultra`). Ladder behavior differs by family: within `luna` the ladder raises effort straight to `:max` before any model jump (`luna:high → luna:max`; the MEDIUM manual `luna:xhigh` start also joins the ladder at `:max` — it is not an extra rung) — `luna:max` then jumps model on a quota-first hop to `terra:max`, which escalates further to `sol:xhigh`. `terra` and `sol` each keep their own `:xhigh` ladder ceiling before any model jump (e.g. `terra:high → terra:xhigh → sol:high`; `sol` climbs to `:xhigh` and stops there — the final ceiling). `sol:max` / `sol:ultra` / `terra:ultra` are manual-only starting keys with no forward escalation (dead ends).

   **Verifier model selection** (fully-explicit, version-pinned, per complexity):
   - **per-US Verifier** — `claude-sonnet-5:high` (LOW) / `claude-opus-5:low` (MEDIUM) / `claude-opus-5:high` (HIGH) / `claude-opus-5:max` (CRITICAL). Version-pinned full ids (not the floating `sonnet`/`opus` aliases) so the verify tier does not silently drift when the alias remaps. The claude engine accepts effort on both short aliases (`opus:max`) AND full ids (`claude-opus-5:high`).
   - **Final Verifier `claude-fable-5:max`** — the final gate runs the top model at top effort (`:max`), unchanged across all complexities. Version-pinned + explicit effort for the same drift reason.
   - When `--consensus` is on, the **claude leg** of consensus reuses the verifier model+effort for per-US and the final-verifier model+effort for the final pass — so with explicit verifier efforts the consensus claude legs are also fully explicit (no implicit default). `--consensus-model` / `--final-consensus-model` configure only the **codex leg**.

   **Context window behavior (claude models — v0.14.6+)**:
   - All claude models default to **200K**. `sonnet` and `opus` aliases both run at the standard window.
   - To request 1M, append the explicit `[1m]` suffix on the full model id:
     - `claude-opus-4-7[1m]` — 1M attempted via `ANTHROPIC_BETA=context-1m-2025-08-07`. Works on most Claude Max accounts.
     - `claude-sonnet-4-6[1m]` — 1M attempted, **but** requires the Anthropic "Extra usage" toggle at https://claude.ai/settings/usage. Without that toggle the worker fails at the first API call with `Extra usage is required for 1M context`.
   - rlp-desk does NOT pre-check entitlement — the explicit `[1m]` is honored as-is. If the API rejects it, you will see the error immediately and can re-run with the standard alias or the opus 1M form.
   - **Default recommendation when 1M is genuinely needed:** prefer `claude-opus-4-7[1m]` over `claude-sonnet-4-6[1m]` because opus 1M does not require a separate entitlement toggle.

   Present complexity score with evidence to the user, e.g.: "I rate this MEDIUM because: US count=4 (MEDIUM), file scope=2 (MEDIUM), logic=conditionals (MEDIUM), deps=none (LOW), impact=modify (MEDIUM). Highest=MEDIUM."

   **If codex IS installed** — say: "Codex is installed. I recommend cross-engine Worker for cost savings (Pro token pool separation) and cross-engine blind-spot coverage (claude Verifier catches issues codex Worker misses)."

   **If codex is NOT installed** — say: "Codex is not installed. Defaulting to claude-only Worker. Note: without a second engine, your Verifier shares the same perspective as the Worker — there is a risk of blind spots where both Worker and Verifier miss the same issue. To unlock cross-engine coverage: `npm install -g @openai/codex`"

8. **Batch Capacity Check** — when verify-mode is batch and PRD is large:
   - batch + spark + AC > 4 → warn "spark 100k context limit — switch to a full-context model (gpt-5.6-luna / gpt-5.6-terra / gpt-5.5) or split smaller"
   - batch + full-context codex model (gpt-5.6-*, gpt-5.5, gpt-5.4*) + AC > 15 → warn "too many ACs for single batch — consider wave split (3-4 US per wave)"
   - per-us → no warning (US-level processing, no limit concern)
9. **Verify Mode** — per-us (default) or batch. Ask: "Verify after each user story (per-us, recommended) or only after all stories are done (batch)?" Default recommendation: per-us for 2+ stories.
10. **Consensus** — Ask: "Use cross-engine consensus? off (single engine), final-only (cross-engine on final verify only), or all (cross-engine on every verify). Requires codex CLI." Default: off. Recommended: final-only when codex is installed.
11. **Max Iterations** — suggest based on story count, ask if OK.
12. **Operational Context** — Auto-detect: scan project root for `package.json` (scripts.dev/start), `Makefile`, `docker-compose.yml`, `manage.py`. If detected, ask:
   - "Does this project require a running server/service during development?" (y/n)
   - If yes: "Server start command?" (pre-fill from detected scripts, e.g., `npm run dev`)
   - "Server port?" (e.g., 7001)
   - "Health check URL?" (e.g., `http://localhost:7001/health`) — optional
   - Pass to init: `--server-cmd "CMD" --server-port PORT --server-health URL`
   - If no server needed: skip. Init generates prompts without operational context.

   **US generation guidance when server context is present:**
   - Each US that modifies server/application code SHOULD include an AC or note:
     "Given server is running, When code is modified, Then server is restarted and health check passes"
   - Do NOT assume the Worker model will restart servers on its own — spell it out in the AC or rely on the operational rules injected by init.

After all items are confirmed:

0. **SV Report Feedback** — If a prior campaign's self-verification report exists:
   a. Scan `~/.claude/ralph-desk/analytics/` for directories matching this project (by slug or project root)
   b. Read the latest `self-verification-report.md` from each matching directory
   c. Extract from §7 (Patterns) and §8 (Recommendations):
      - Which US types/sizes failed most frequently
      - Which AC quality dimensions scored lowest
      - Which model tiers underperformed for this project's complexity
      - Specific brainstorm/PRD/test-spec recommendations from prior campaigns
   d. Present findings to user: "Prior campaign analysis found: [patterns]. Recommendations: [suggestions]."
   e. If no prior reports exist, skip and note "No prior campaign data available."
   (governance §8½)
1. **Ambiguity Gate (IL-2)** — score each AC per governance §1a IL-2 (6 dimensions, 0-12 points).
   If ANY AC scores below 6: **REJECT** — refine that AC before proceeding.
   If all ACs score 6-9: **WARN** — proceed with logged warning, show low-scoring dimensions.
   If all ACs score 10-12: **PASS** — clean.
   Present the score table to the user before proceeding.
1.5. **무인-완주 점검 (Unattended-completion check)** — ask, for this exact PRD: "Can the loop run to completion with ZERO human interaction? Is there any AC or constraint that would induce a runtime owner/user decision?" Any interaction-inducing AC (e.g. "stop and confirm with the owner", "await sign-off", "ask which convention to use") is a **REJECT** — do not proceed. Convert it into a delegation rule in the PRD's **위임 규칙** section (신규 표면/산출물 등록 관례, 원장·레지스트리 갱신 규칙, fixture·합성데이터 처분, baseline 처분). The only legitimate runtime blocks are ① irreversible destruction, ② contract-change-required, ③ protected-path violation; a PRD may not manufacture any other stopping point. A PRD that cannot guarantee unattended completion is **not complete**.
   **작업 유형 분류 (Work-type classification, request-f §2; 검증형 vision-adopt §4)** — as a second judgment axis in this same step, classify every US into one of three types. **명세형 (specification-type)** — the contract can be written up-front, eligible for the loop. **발굴형 (discovery-type)** — the contract only emerges by digging (부채 청산, 미지 원인 수사, 전수 열거류); this is a **REJECT**: do not put it into the campaign — run **선행 정찰 (prior reconnaissance)** by the supervisor or a context-retaining single agent, outside the loop, until the digging produces a contractable outcome, then convert that outcome (열거 목록/원인 특정/확정 수리 지시) into a specification-type US and re-inject it into the PRD. **검증형 (verification-type)** — the contract IS writable up-front, but the deliverable is *verifying/confirming existing behavior*, so a TDD RED phase is structurally impossible (no new code to turn red→green; an honest fresh RED cannot exist for already-satisfied behavior). A verification-type US is **NOT a reject** — it stays in the campaign but is auto-assigned the doctrine-based alternative gate (`verify_existing` — run the covering tests, record exit codes, confirm every AC is covered by PASSING tests) instead of write_test→verify_red→implement→verify_green, so the TDD-RED mandate never misfires as a false FAIL (governance IL-2¾ §2). Judgment hint: AC verbs like "전수 열거하라 / 원인을 특정하라" (enumerate exhaustively / identify the cause) signal discovery-type; "이 목록을 등록하라 / 이 함수를 이렇게 수리하라" (register this list / repair this function this way) signal specification-type; "이 동작이 유지되는지 검증하라 / 회귀가 없는지 확인하라" (verify existing behavior still holds / confirm no regression) signal verification-type. Mid-campaign rule: if a discovery-type fragment surfaces DURING a campaign, split only that fragment out to a parallel supervisor investigation; re-inject only the confirmed contract that results, never the raw discovery task itself.
2. Present the full contract summary.
3. **Self-Verification** — Ask: "Enable self-verification? Worker records step-by-step evidence, Verifier cross-validates process. Recommended for MEDIUM+ risk." Default: yes for HIGH/CRITICAL, no for LOW/MEDIUM.
4. **Re-execution check**: After slug is confirmed, check if `.rlp-desk/plans/prd-<slug>.md` already exists. If a PRD already exists for this slug, ask: "A PRD already exists for this slug. Improve the existing PRD or start fresh?" (fresh resets runtime state but PRESERVES authored plans; add `--reset-plans` to wipe them with a versioned backup)
   - "improve" → pass `--mode improve` to init
   - "start fresh" → pass `--mode fresh` to init
   - If no PRD exists: standard first-run (no --mode needed)
5. On approval, offer to run `init`.
6. **Seal the gate (REQUIRED — gate-receipt binding).** Once `init` has written the PRD and test-spec files (`prd-<slug>.md` + any `prd-<slug>-US-*.md`; `test-spec-<slug>.md` + any `test-spec-<slug>-US-*.md`), run:
   ```
   node ~/.claude/ralph-desk/node/run.mjs gate-receipt <slug> --scorecard "PASS:<n> WARN:<m> REJECT:<k>"
   ```
   This writes `.rlp-desk/plans/gate-receipt-<slug>.json` (content hash of every sealed contract file — PRD **and** test-spec — plus a per-file hash map, the scorecard summary, and `passed_at`). `init` and `run` compare the live contract hash against this receipt and WARN loudly on any drift (see below), and on drift the specific changed file(s) are recorded to the append-only `.rlp-desk/logs/<slug>/contract-revisions.jsonl` audit chain. A campaign whose PRD or test-spec was authored or edited **outside** this gate has no matching receipt, and the drift is surfaced at run start. **Do not skip this step** — it is what binds the Ambiguity/무인-완주 gates to the artifact instead of to your memory of having run them.

Do NOT create files during brainstorm (the PRD is written by `init`; the gate-receipt is written after `init`, in step 6 above).
Do NOT auto-decide iteration unit — the user MUST explicitly choose.

### `revise <slug>` — re-gate a modified PRD

When you must change a PRD after it was sealed (add a US, edit an AC, restructure), do it through the formal re-gate path so the receipt stays authoritative:

1. Edit the PRD files (`prd-<slug>.md` / `prd-<slug>-US-*.md`) and/or the test-spec files (`test-spec-<slug>.md` / `test-spec-<slug>-US-*.md`) — both are sealed by the receipt.
2. **Re-run the gate scorecard** on the modified PRD — score every AC per the Ambiguity Gate (IL-2) AND re-run the 무인-완주 점검 above. Present the new score table.
3. Re-seal: `node ~/.claude/ralph-desk/node/run.mjs gate-receipt <slug> --scorecard "PASS:<n> WARN:<m> REJECT:<k>"` — this refreshes `gate-receipt-<slug>.json` to the new PRD hash.

Editing a PRD without re-gating is exactly the bypass request-d closes: the next `run` will detect the hash mismatch and WARN loudly (baseline.log + startup banner + `status.json` `gate_receipt:"mismatch"`). Ungated changes are never silently accepted.

---

## `init <slug> [objective]`

Run: `~/.claude/ralph-desk/init_ralph_desk.zsh <slug> "<objective>" [--mode fresh|improve] [--reset-plans]`
If brainstorm was done, auto-fill:
- PRD and test-spec with the brainstorm results
- Campaign memory "Key Decisions" with architectural decisions from brainstorm
- Campaign memory "Patterns Discovered" with codebase exploration findings (from step 2.5)

**After init completes, STOP. Do NOT auto-run the loop.**

Tell the user:
1. The scaffold has been created — list the generated files
2. Ask them to review/edit the PRD and test-spec if needed
3. Present run options with explanations and ONE recommendation. The user MUST copy and paste the command themselves.

   Check if codex CLI is installed: run `command -v codex` in shell or check if the binary exists.

   **If codex IS installed** — show cross-engine presets first:

   ```
   Available run commands (copy the one you want):

   # ★ Recommended: fully-explicit cross-engine config (every role pinned model:effort, no implicit defaults):
   # Verifier tier shown (claude-opus-5:high) is the HIGH-complexity example — the per-complexity table above governs; --consensus-model here is the per-US leg (terra:high), --final-consensus-model is the final leg (sol:xhigh, always stricter).
   /rlp-desk run <actual-slug> --mode tmux --worker-model gpt-5.6-luna:high --verifier-model claude-opus-5:high --final-verifier-model claude-fable-5:max --consensus all --consensus-model gpt-5.6-terra:high --final-consensus-model gpt-5.6-sol:xhigh --verify-mode per-us --debug

   # Small tasks only (single-file, AC <= 4, simple logic — spark 100k context limit):
   /rlp-desk run <actual-slug> --mode tmux --worker-model spark:high --consensus final-only --debug

   # Critical (full consensus on every verify):
   /rlp-desk run <actual-slug> --mode tmux --worker-model gpt-5.6-sol:high --consensus all --debug

   # Claude-only:
   /rlp-desk run <actual-slug> --debug

   # Full options reference:
   #   --mode native|tmux                     (default: native; legacy `agent` redirects to native)
   #                                          tmux: run inside a tmux session; the Leader anchors on its own pane and keeps the canonical layout (Leader visible at a readable width; Worker/Verifier/Consensus in one right column). Started outside tmux it fails fast ("start tmux first").
   #   --worker-model MODEL                   claude (haiku|sonnet|opus|claude-opus-5:high, effort optional) or codex (gpt-5.6-sol:high|luna:high|terra:high|spark:high) (default: haiku)
   #   --lock-worker-model                    disable auto model upgrade
   #   --verifier-model MODEL                 per-US verifier (default: sonnet; recommended per complexity: claude-sonnet-5:high/claude-opus-5:low/claude-opus-5:high/claude-opus-5:max — version-pinned + explicit effort)
   #   --final-verifier-model MODEL           final ALL verifier (default: opus; recommended claude-fable-5:max — top model + top effort)
   #   --consensus off|all|final-only         cross-engine consensus; claude leg reuses verifier/final-verifier model+effort (default: off)
   #   --consensus-model MODEL                per-US cross-verifier — codex leg only (default: gpt-5.6-terra:high)
   #   --final-consensus-model MODEL          final cross-verifier — codex leg only (default: gpt-5.6-sol:xhigh)
   #   --consensus-parallel                   run claude+codex consensus verifiers concurrently (default: off)
   #   --verify-mode per-us|batch             (default: per-us)
   #   --cb-threshold N                       (default: 6)
   #   --max-iter N                           (default: 100)
   #   --iter-timeout N                       tmux only (default: 600)
   #   --pre-gate-timeout N                   mechanical pre-gate soft timeout, seconds (default: 300)
   #   --pre-gate-cmd-timeout N               layer-2 replay per-command timeout, seconds (default: 120)
   #   --debug                                debug logging
   #   --with-self-verification               post-campaign SV report
   #   --flywheel off|on-fail                 direction review on fail (default: off)
   #   --flywheel-model MODEL                 flywheel reviewer model (default: opus)
   #   --flywheel-guard off|on                  guard validates flywheel decisions (default: off)
   #   --flywheel-guard-model MODEL             guard reviewer model (default: opus)
   ```

   **If codex is NOT installed** — show claude-only presets + install recommendation:

   ```
   Available run commands (copy the one you want):

   # ★ Recommended: tmux mode + claude-only (real-time visibility):
   /rlp-desk run <actual-slug> --mode tmux --debug

   # Native Agent() mode (slash leader, short / interactive campaigns):
   /rlp-desk run <actual-slug> --mode native --debug

   # Install codex for cost savings + cross-engine blind-spot coverage:
   npm install -g @openai/codex

   # Full options reference:
   #   --mode native|tmux                     (default: native; legacy `agent` redirects to native)
   #                                          tmux: run inside a tmux session; the Leader anchors on its own pane and keeps the canonical layout (Leader visible at a readable width; Worker/Verifier/Consensus in one right column). Started outside tmux it fails fast ("start tmux first").
   #   --worker-model MODEL                   haiku|sonnet|opus, or full claude id with effort (claude-opus-5:high) (default: haiku)
   #   --lock-worker-model                    disable auto model upgrade
   #   --verifier-model MODEL                 per-US verifier (default: sonnet; recommended per complexity: claude-sonnet-5:high/claude-opus-5:low/claude-opus-5:high/claude-opus-5:max — version-pinned + explicit effort)
   #   --final-verifier-model MODEL           final ALL verifier (default: opus; recommended claude-fable-5:max — top model + top effort)
   #   --verify-mode per-us|batch             (default: per-us)
   #   --cb-threshold N                       (default: 6)
   #   --max-iter N                           (default: 100)
   #   --iter-timeout N                       tmux only (default: 600)
   #   --pre-gate-timeout N                   mechanical pre-gate soft timeout, seconds (default: 300)
   #   --pre-gate-cmd-timeout N               layer-2 replay per-command timeout, seconds (default: 120)
   #   --debug                                debug logging
   #   --with-self-verification               post-campaign SV report
   #   --flywheel off|on-fail                 direction review on fail (default: off)
   #   --flywheel-model MODEL                 flywheel reviewer model (default: opus)
   #   --flywheel-guard off|on                  guard validates flywheel decisions (default: off)
   #   --flywheel-guard-model MODEL             guard reviewer model (default: opus)
   ```

   Replace `<actual-slug>` with the real slug from this init (e.g. `auth-refactor`).

**CRITICAL: Do NOT offer to run for the user. Do NOT ask "shall I run?" or offer to execute. The user MUST type the run command themselves. Just present the options, recommend one, and STOP.**

---

## `run <slug> [options]`

**YOU are the leader. Do NOT delegate leadership.**

Options (parse from `$ARGUMENTS`):
- `--mode native|tmux` (default: `native`) — execution mode. `native` = slash command is the leader, calls `Agent(...)` (claude) and `Bash("codex exec ...")` (codex). `tmux` = slash command spawns the zsh runner via `node run.mjs --mode tmux`. Legacy `--mode agent` typed against the slash command emits a deprecation notice and redirects to `--mode native` (NOT to be confused with `node run.mjs --mode agent`, which is the deprecated Node-leader alpha — see "Direct Node CLI invocation" below).
- `--worker-model MODEL` (default: `haiku`) — Worker model. Format: `model` (no colon) = claude engine; `model:effort` = claude engine when `model` is a claude name (short alias `haiku`/`sonnet`/`opus` OR full versioned id `claude-*`), otherwise codex engine (`model:reasoning`). Examples: `haiku`, `sonnet`, `opus`, `opus:max`, `claude-opus-5:high`, `claude-fable-5:max`, `claude-opus-5[1m]:high` (1M context + effort), `spark:high`, `gpt-5.6-sol:xhigh`, `gpt-5.5:high`, `gpt-5.6-luna:max` (cost-lane HIGH start), `gpt-5.6-terra:max` (manual quota-first start — quality ≈ sol:high–xhigh midpoint, slower; escalates to sol:xhigh on failure). Parsed by `parse_model_flag()` which auto-splits engine/model/effort-or-reasoning; a colon-bearing name is codex ONLY when the model part is neither a claude short alias nor a `claude-*`/`claude` name.
- `--lock-worker-model` — disable automatic model upgrade on failure. Worker stays on the specified model regardless of consecutive failures.
- `--verifier-model MODEL` (default: `sonnet`; recommended per complexity: `claude-sonnet-5:high` (LOW) / `claude-opus-5:low` (MEDIUM) / `claude-opus-5:high` (HIGH) / `claude-opus-5:max` (CRITICAL)) — per-US verification model. Campaign-fixed (no progressive upgrade). Lighter than final verifier. Claude engine accepts `model:effort` on both short aliases (`opus:max`) AND full `claude-*` ids (`claude-opus-5:high`); version-pinning prevents alias drift.
- `--final-verifier-model MODEL` (default: `opus`; recommended `claude-fable-5:max`) — final ALL verification model. Independent from per-US verifier. Used only for the final full-AC verify pass. The final gate runs the top model at top effort (`claude-fable-5:max`).
- `--consensus off|all|final-only` (default: `off`) — cross-engine consensus verification mode.
  - `off`: single-engine verification only
  - `all`: cross-engine consensus on every verify (per-US and final)
  - `final-only`: cross-engine consensus only on the final ALL verify
- `--consensus-model MODEL` (default: `gpt-5.6-terra:high`) — per-US cross-verifier model. Configures the **codex leg only**; the claude leg of per-US consensus reuses `--verifier-model` (model + effort). Lighter weight for cost efficiency. Brainstorm recommends per complexity: `gpt-5.6-luna:max` (LOW) / `gpt-5.6-terra:high` (MEDIUM) / `gpt-5.6-sol:medium` (HIGH) / `gpt-5.6-sol:high` (CRITICAL).
- `--final-consensus-model MODEL` (default: `gpt-5.6-sol:xhigh`) — final cross-verifier model. Configures the **codex leg only**; the claude leg of final consensus reuses `--final-verifier-model` (model + effort). Stricter. Note: spark is not allowed here (100k output limit).
- `--consensus-parallel` (default: OFF) — run the claude and codex consensus verifiers **concurrently** (claude in the verifier pane, codex in a 4th consensus pane) instead of sequentially. Both verdict files are polled and merged with the same NO ENGINE PRIORITY rule (both must pass). Because the two verifiers re-run evidence at the same time, both prompts carry an evidence-isolation lock contract (acquire `.rlp-desk/logs/<slug>/runtime/evidence.lock` before any DB-mutating or E2E rerun). When off, the sequential consensus path is byte-identical to before.
- `--verify-mode per-us|batch` (default: `per-us`) — verification strategy
  - `per-us`: verify after each US, then final full verify of all AC
  - `batch`: verify only after all US done (legacy behavior)
- `--cb-threshold N` — circuit breaker threshold: consecutive failures before BLOCKED (default: 6). When `--consensus` is not `off`, effective threshold is automatically doubled (e.g., default becomes 12).
- `--max-iter N` (default: 100)
- `--iter-timeout N` — per-iteration timeout in seconds (default: 600). Enforced in tmux mode only. Agent mode: not enforced (Agent() has no timeout API). Effort-aware: the effective worker budget is ×1.5 for `:xhigh` and ×2.0 for `:max` efforts (applies on top of the value you set); verifier/consensus waits use the base value.
- `--pre-gate-timeout N` — overall soft timeout in seconds for the mechanical pre-gate, bounding layer 1 (gate script) + layer 2 (execution_steps replay) combined (default: 300). See the pre-gate convention below.
- `--pre-gate-cmd-timeout N` — per-command soft timeout in seconds for the layer-2 execution_steps replay (default: 120). A per-command timeout counts as a replay mismatch (fail).
- `--waivers-sha256 HASH` — out-of-band authorization for `.rlp-desk/plans/waivers.json` (fail-closed campaign waiver channel — see the "Campaign waivers" preparation step below). Must equal `shasum -a 256 .rlp-desk/plans/waivers.json`; a present waivers.json whose hash this flag does not authorize has every waiver in it rejected.
- `--debug` — enable debug logging (writes to ~/.claude/ralph-desk/analytics/<slug>/debug.log)
- `--with-self-verification` — enable campaign-level self-verification analysis. After COMPLETE, Leader analyzes all iteration records (done-claims + verdicts) and generates a campaign self-verification summary with patterns and recommendations for next planning cycle. (Note: execution_steps and reasoning are ALWAYS recorded per governance §1f — this flag adds post-campaign analysis.)

### Analytics Directory (`~/.claude/ralph-desk/analytics/<slug>/`)
When `--debug` or `--with-self-verification` is active, analytics data is written to a user-level directory for cross-project aggregation. Contents:
- `metadata.json` — campaign metadata: slug, project_root, campaign_status, start_time, end_time
- `debug.log` — debug output (versioned: `debug-v{N}.log` on re-execution)
- `campaign.jsonl` — per-iteration structured data (versioned: `campaign-v{N}.jsonl` on re-execution). Schema: iter, us_id, worker_model, worker_engine, verifier_model, verifier_engine, consensus_mode, claude_verdict, codex_verdict, duration_worker_s, duration_verifier_s, project_root, slug, timestamp
- `self-verification-data.json` — cumulative SV records (agent-mode only, when `--with-self-verification`)
- `self-verification-report-NNN.md` — versioned SV reports (when `--with-self-verification`)

Cross-project aggregation: scan `~/.claude/ralph-desk/analytics/` and read each slug's `metadata.json` to discover project_root, campaign_status, and timestamps. Slug directories use `<slug>--<root_hash>` format to prevent collision across projects.

### Mode Selection

Parse the `--mode` flag. Slash command canonical labels:

- `--mode native` (default): **Native Agent() path** below. The slash command IS the leader. It calls `Agent(description=…, model=<m>, mode="bypassPermissions", prompt=…)` for claude workers/verifiers and `Bash("OMX_STATE_ROOT='<campaign runtime dir>/omx-state' codex exec --model <m> --reasoning-effort <r> --disable plugins --disable hooks <prompt>")` for codex workers/verifiers. `OMX_STATE_ROOT` isolates every codex launch from the operator's interactive omx state (`.rlp-desk/logs/<slug>/runtime/omx-state`, mkdir -p'd before first use) — stale interactive-session state can otherwise block/wedge campaign codex workers (stale-lock incident 2026-08-09).
- `--mode tmux`: **zsh runner path** below. The slash command shells out to `node ~/.claude/ralph-desk/node/run.mjs run --mode tmux …` which spawns `run_ralph_desk.zsh` as a subprocess.

Legacy `--mode agent` typed against this slash command emits a deprecation notice and redirects to `--mode native`. **Do NOT confuse `/rlp-desk run --mode agent`** (slash command, redirects to Native Agent()) **with** `node run.mjs run --mode agent` (deprecated Node-leader alpha, direct CLI invocation, unrelated code path — see "Direct Node CLI invocation" below).

> **Stability tiers:**
> - `--mode tmux` is the **stable, production** path. The slash command spawns
>   the Node leader, which spawns `run_ralph_desk.zsh` — the zsh runner has the
>   full safety net (heartbeat, copy-mode guard, prompt-stall, no-progress
>   detection, claude model upgrade chain). Recommend this for autonomous
>   campaigns.
> - `--mode native` is **for short / interactive campaigns**. Native Agent()
>   has no timeout API (platform constraint). Long-running autonomous campaigns
>   SHOULD use `--mode tmux`.

#### Tmux Mode (`--mode tmux`)

When `--mode tmux` is specified (v0.14.0+: `run.mjs` accepts the same flags as before but spawns `run_ralph_desk.zsh` as a subprocess and inherits stdio. ARCH Wave C: `--with-self-verification` **is honored** under tmux mode via a Node post-pass that runs after the zsh leader exits (see §348). `--flywheel`/`--flywheel-guard` are deprecated (ADR-001) and remain unimplemented in the zsh leader):

1. **Validate scaffold** — same as Agent() mode: check `.rlp-desk/prompts/<slug>.worker.prompt.md` etc.
2. **Check sentinels** — same as Agent() mode.
3. **Check prerequisites** — verify `tmux`, `jq`, and `node` (>= 16) are installed. If not, report what is missing and stop.
4. **Locate Node leader** — find `~/.claude/ralph-desk/node/run.mjs`. If not found, tell the user to reinstall (`npm install` or `bash install.sh`).
5. **Launch** — shell out to the Node leader. **All dynamic args (slug + model values) MUST be passed through shell single-quote escaping** (v5.7 §4.12 G11) so bracketed model ids like `claude-opus-4-7[1m]` survive zsh parsing:

```bash
node ~/.claude/ralph-desk/node/run.mjs run '<slug>' \
  --mode tmux \
  --max-iter <N> \
  --worker-model '<value>' \
  [--lock-worker-model] \
  --verifier-model '<value>' \
  --final-verifier-model '<value>' \
  --consensus <off|all|final-only> \
  --consensus-model '<value>' \
  --final-consensus-model '<value>' \
  --verify-mode <per-us|batch> \
  --cb-threshold <N> \
  --iter-timeout <N> \
  [--debug] [--autonomous] \
  [--lane-strict]              # was env LANE_MODE=strict \
  [--test-density-strict]      # was env TEST_DENSITY_MODE=strict \
  [--with-self-verification] \
  [--flywheel on-fail --flywheel-model '<value>'] \
  [--flywheel-guard on --flywheel-guard-model '<value>']
```

**Quoting contract (v5.7 §4.1)**: every `'<value>'` placeholder above must be replaced with the user's flag value wrapped in single quotes via the equivalent of `shellQuote(value)` — `"'" + value.replace(/'/g, "'\\''") + "'"` for POSIX correctness. The slug, all model values, and any future dynamic flag must follow this rule. A slug or model containing brackets / spaces / single quotes / dollar signs / backticks must NOT break the leader invocation.

**Env-var translation (v5.7 §4.1)**: the slash command historically built `LANE_MODE=strict zsh ...` and `TEST_DENSITY_MODE=strict zsh ...` from CLI flags. The Node leader uses CLI flags instead — translate `--lane-strict` and `--test-density-strict` into the corresponding flags. Direct env-var users (running zsh directly) are unaffected.

6. **If the Node leader exits with error** — report the error to the user and STOP. Do NOT attempt to work around it. Do NOT create tmux sessions yourself. Do NOT re-launch in a different way. Tell the user what went wrong and suggest `--mode native` (slash command Native Agent() path) as alternative.
7. **If successful** — tell the user the tmux session has been started. The Node leader takes over as the deterministic Leader. No Agent() calls are made in tmux mode.

**IMPORTANT RULES:**
- Tmux mode requires the user to already be inside a tmux session. If the leader rejects because $TMUX is not set, do NOT try to create a tmux session yourself. Tell the user: "Start tmux first, then retry."
- MUST launch with `run_in_background: true` so `/rlp-desk` returns control immediately while preserving live tmux visibility.
- Run-in-background is used so the shell can keep the command visible and keep the pane layout stable for status checks and completion flow.
- Do NOT kill panes after completion. Panes stay alive for inspection. User cleans up with `/rlp-desk clean <slug> --kill-session`.
- ARCH Wave C (ADR-001): `--with-self-verification` **is honored** under `--mode tmux`. The zsh leader cannot generate the SV report in-pane (`claude --print` hangs without a TTY — hence its `$TMUX` early-return), so `run.mjs` runs the **pure-filesystem** `generateSVReport` as a **post-pass after the zsh child exits**, reading the campaign's on-disk done-claim/verdict artifacts. `--flywheel` and `--flywheel-guard` are **deprecated** (ADR-001) and remain unimplemented in the zsh leader; the Node leader emits a stderr WARNING for those two only. The slash command's Native Agent() (`--mode native`) does not yet implement SV/flywheel.
- **For `--mode tmux` only**: the slash command invokes `node ~/.claude/ralph-desk/node/run.mjs run --mode tmux ...`. Do NOT invoke `~/.claude/ralph-desk/run_ralph_desk.zsh` directly — the Node router resolves the runner path, runs legacy detection, and surfaces actionable errors when the runner is missing. **For `--mode native`**, the slash command does NOT invoke the Node CLI — it acts as the leader itself; see Native Agent() Mode section below.

**tmux UX model (5 items):**
- The session returns immediately after launch (`run_in_background: true`) so the command returns control to the parent CLI.
- Worker/Verifier panes remain visible to the user during execution.
- Users check progress with the **status command**: `/rlp-desk status <slug>`.
- On completion, the command returns a completion notification before the loop ends.
- Native Agent() mode remains unchanged, and no tmux-specific behavior is mixed into it.

#### Native Agent() Mode (`--mode native` or default)

The slash command IS the leader. Workers/Verifiers are spawned via `Agent(model=…, mode="bypassPermissions", prompt=…)` (claude) or `Bash("OMX_STATE_ROOT='<campaign runtime dir>/omx-state' codex exec --model <m> --reasoning-effort <r> --disable plugins --disable hooks <prompt>")` (codex) — the `OMX_STATE_ROOT` prefix isolates the codex launch from the operator's interactive omx state (see §"Execute Worker" below).

### Native Agent() Safety Contract

This contract MUST be observed in every iteration of the leader loop below. Future PRs deleting any of these guarantees break the slash command's behavior.

1. **Turn-keepalive**: every status report uses `Bash("echo '...'")` to emit messages. NEVER output plain text without an accompanying tool call. Plain text = turn ends = loop stops. (Mitigation for commit `29fd29b` platform constraint, permanent.)
2. **no `subagent_type` parameter**: the `Agent(...)` call form is exactly `Agent(description=…, model=<m>, mode="bypassPermissions", prompt=…)`. Do NOT pass `subagent_type`. (Mitigation for commit `920a31c`: `subagent_type="executor"` overrode `bypassPermissions` and surfaced a permission popup; permanent.)
3. **`mode="bypassPermissions"` mandatory**: every claude `Agent()` worker/verifier dispatch must include `mode="bypassPermissions"`.
4. **Long-running campaigns: prefer `--mode tmux`** for production. Native Agent() has no timeout API (platform constraint) — if `bypassPermissions` fails to suppress an interactive prompt at the SDK level, the call hangs indefinitely with no rlp-desk-side watchdog.

**Why Native Agent() is structurally immune to Bug 4/5 (mid-execution prompt hang & A4 premature dispatch)**: Worker/Verifier run non-interactively under the platform's bypass — they have no tmux pane, no TUI surface, and cannot surface a `[y/N]` prompt to the parent Leader. The auto-dismiss / prompt-stall / no-progress timeouts in `run_ralph_desk.zsh` (v5.7 §4.13.b / §4.16 / §4.17) are therefore tmux-only by design.

**Tradeoff**: because `Agent()` has no timeout API, Native Agent() iterations are not bounded — if the platform's `bypassPermissions` ever fails to suppress an interactive prompt at the SDK level, the call hangs indefinitely with no rlp-desk-side watchdog. Use `--mode tmux` if you need bounded execution time.

#### Direct Node CLI invocation (`node run.mjs run <slug> --mode agent` — deprecated alpha)

Direct invocation of `node ~/.claude/ralph-desk/node/run.mjs run <slug> --mode agent` **hard-errors (exit 2) as of this release** (per [ADR-001](../../docs/plans/adr-001-leader-consolidation.md) §3) — it was the deprecated Node-leader alpha path, and the dated breaking change has now landed. Direct CLI invocation redirects to `--mode tmux` (production) / `--mode native` (slash), and the **Node-CLI default mode is now `tmux`**. This is unrelated to the slash command's legacy `--mode agent` → native redirect — different code, different leader, different lifecycle. The `src/node/**` engine modules (which still back the Native Agent() path and the test suite, and retain SV/flywheel implementations not yet ported to Native Agent()) are **retained** — only the direct-CLI `--mode agent` *entry point* hard-errors. For production tmux orchestration, use `--mode tmux` (the **canonical** leader). For Claude Code Native Agent() campaigns, use `/rlp-desk run <slug> --mode native` from a Claude Code session.

**Deprecation schedule** (per [ADR-001](../../docs/plans/adr-001-leader-consolidation.md) §3 — applies to the Node-CLI `--mode agent` entry point ONLY; the `src/node/**` engine modules are retained throughout):

| Version | Behavior of `node run.mjs run <slug> --mode agent` |
|---------|-----------------------------------------------------|
| 0.16.x  | runs, with a louder deprecation banner |
| **0.17.0** | **hard-errors** (exit 2) with a redirect to `--mode tmux` / `--mode native`; the Node-CLI default also flips to `tmux` |
| 0.18.0  | the `--mode agent` dispatch branch is removed (engine modules stay) |

External wrappers calling `--mode agent` must migrate to `--mode tmux` by 0.17.0. This is a breaking CLI change for that entry point, announced in CHANGELOG at each step.

### Preparation
1. Validate scaffold: `.rlp-desk/prompts/<slug>.worker.prompt.md` etc.
2. **Codex CLI pre-validation**: If `--consensus` is not `off` OR any of `--worker-model` / `--verifier-model` / `--final-verifier-model` / `--consensus-model` / `--final-consensus-model` resolves to the **codex engine**, check that `codex` CLI exists in PATH. Resolve engine via `parse_model_flag()` (the DETECTED engine), NOT by "contains a colon" — a colon-bearing claude id like `claude-opus-5:high` or `opus:max` is still the claude engine and must NOT trip the codex check. If codex CLI not found → STOP immediately, print install instructions (`npm install -g @openai/codex`), do not start the loop.
3. Check sentinels (complete/blocked). Found → tell user `/rlp-desk clean <slug>`.
3a. **Done-claim commit-integrity oracle**: runs AFTER each Worker done-claim, BEFORE the mechanical pre-gate (3b below) and BEFORE dispatching the LLM Verifier — on every signal path (normal Worker signal, codex-exit fallback synth, operator-recovery resume). When done-claim.json asserts a successful `commit` step, the Leader checks it against git ground truth: HEAD must have advanced beyond the iteration-start snapshot, the claimed `commit_sha` (when present) must resolve and be reachable from HEAD, and the tracked working tree must be clean of worker-attributable changes after the claim. Worker MUST record the resulting commit SHA as `commit_sha` on the `commit` step when claiming `exit_code: 0` — a commit-claim without `commit_sha` is tolerated only if HEAD actually advanced; once `commit_sha` is emitted the full check applies. No commit asserted (e.g. `verify_existing`, confirmation mode) → silent no-op. The inverse is also checked: when a done-claim carries **no `write_test` step** (confirmation/verification shape) and its claimed commit's tree equals its parent's, that **empty commit** is rejected (`empty_commit_on_confirmation_claim`) — a verification pass that changed no files must not manufacture a commit to look productive, and the fix contract tells the Worker to DROP it rather than create another. A root commit or shallow clone (no parent to diff against) is an accepted boundary, never an infra failure. On mismatch: LLM verification is skipped and the Worker is redispatched with a machine-generated `COMMIT-INTEGRITY` fix contract (governance §1f½), not a free-text verifier finding.
3b. **Mechanical pre-gate (optional, TWO layers)**: runs AFTER each Worker done-claim and BEFORE dispatching the LLM Verifier, in order. **Layer 1** — if `.rlp-desk/plans/pregate-<slug>.sh` exists, the tmux leader runs it (plain shell script via `zsh`, from the project root); exit 0 = pass, non-zero = fail. **Layer 2** — after layer 1 passes, the leader replays the verify-* commands the Worker recorded in `done-claim.json` `execution_steps[]` (existing §1f schema) and compares each replayed exit code to the CLAIMED `exit_code` (EQUALITY — a `verify_red` claiming non-zero that replays to the same non-zero is a MATCH; claimed 0 / actual ≠0 is a FAIL). Only `^verify*` steps with a non-null command that begins with an allowlisted tool and contains no denylisted pattern are replayed; others are skipped (logged, not run, not a fail). Per-command timeout is `--pre-gate-cmd-timeout` (default 120s); the whole pre-gate is bounded by `--pre-gate-timeout` (default 300s). On fail (either layer) LLM verification is skipped and the Worker is redispatched with a fix contract (`PRE-GATE FAILURE (mechanical)` or `PRE-GATE FAILURE (replay mismatch)`). Keep layer-1 checks deterministic only (compile / lint / file existence / test count) — no LLM-judgment checks; replay only catches false claims, so command omission / test sufficiency stay the Verifier's job. `init` scaffolds a commented `pregate-<slug>.sh.example`; copy it to `pregate-<slug>.sh` to activate layer 1 (layer 2 needs no scaffold — it reads done-claim). Absent gate + no eligible steps = no-op. The pre-gate can only early-FAIL — it never produces a pass (Iron Law preserved; see governance §3a).
3c. **Campaign waivers (optional, fail-closed)**: at fresh campaign entry (and again on operator-recovery resume), the Leader loads and validates `.rlp-desk/plans/waivers.json` against `--waivers-sha256` (see governance §3a½ for the full policy). A waiver is honored ONLY when it is well-formed, bound to the running campaign slug, and its named baseline artifact exists with a matching sha256 and actually contains the claimed `finding_id` for that `gate` — proving the finding is pre-existing, never a campaign-introduced regression. A `waivers.json` present without a matching `--waivers-sha256` has every waiver rejected. Honored waivers are injected into both the Worker and Verifier prompts every iteration; a Verifier verdict that passes a waived gate MUST cite the waiver id in its reasoning.
   - **Conventions**: `waivers.json` is a JSON array of `{ "id", "campaign_slug", "gate", "finding_id", "baseline_artifact_path", "baseline_artifact_sha256", "reason" }` (all seven required, non-empty strings). Baseline artifacts conventionally live at `.rlp-desk/plans/baseline/<gate>.json` with minimal schema `{ "gate": "<gate>", "captured_at": "<iso8601>", "findings": [ { "finding_id": "<id>", "severity": "<sev>", ... } ] }`; a relative `baseline_artifact_path` resolves against the project root.
   - **Capture recipe 1 (baseline artifact)** — prove a finding predates the campaign: run the gate, save its JSON output as the artifact, then `shasum -a 256 .rlp-desk/plans/baseline/<gate>.json` → paste into `baseline_artifact_sha256`.
   - **Capture recipe 2 (authorization)** — bind `waivers.json` to this (re)start out-of-band: `shasum -a 256 .rlp-desk/plans/waivers.json` → pass as `--waivers-sha256 <hash>`. Both recipes are operator-side, out-of-band — a Worker cannot forge either.
4. Clean previous `done-claim.json`, `verify-verdict.json`.
5. **Always**: write baseline log entry to `.rlp-desk/logs/<slug>/baseline.log`: `[timestamp] iter=0 phase=start slug=<slug> worker_model=<model> verifier_model=<model>`. Baseline.log captures 1 line per iteration for lightweight post-mortem (always-on, no flag needed).
6. If `--debug`: also create/clear `~/.claude/ralph-desk/analytics/<slug>/debug.log`. Define a helper: to "debug_log" means append a timestamped line to this file via `Bash("echo \"[$(date '+%Y-%m-%d %H:%M:%S')] $msg\" >> ~/.claude/ralph-desk/analytics/<slug>/debug.log")`. When `--debug` is active, debug.log contains all baseline.log fields plus detailed phase logs.
   - **4-category log system**: all debug_log entries use exactly one of: `[GOV]` (governance checks: IL enforcement, CB triggers, scope lock, verdict evaluation), `[DECIDE]` (leader decisions: model selection, fix contracts, escalation), `[OPTION]` (configuration snapshot at loop start: thresholds, modes, models), `[FLOW]` (execution progress: worker/verifier dispatch, signal reads, phase transitions)
   - **Re-execution versioning**: If `debug.log` already exists at `--debug` start, rename it to `debug-v{N}.log` (N = next available integer ≥ 1) before creating a fresh `debug.log`.
   - **baseline.log lifecycle**: baseline.log is deleted on re-execution (when `init --mode improve` or `init --mode fresh` is run).
7. Capture baseline commit: `Bash("git rev-parse HEAD 2>/dev/null || echo none")` → store as `BASELINE_COMMIT`. Include in the first `status.json` write as `baseline_commit` field.
8. **Launch breadcrumb (`--mode tmux`, always-on)**: `logs/<slug>/launch-record.json` is written synchronously at process start — before scaffold validation, before any dependency check can exit early — so a campaign that dies before iteration 1 still leaves a post-mortem trail (zero-artifact abandonment guardrail). `run.mjs` writes a provisional record (`phase: "parsing"`) before flag parsing, then overwrites it with `phase: "launched"` (+ pid, mode, parsed options) once options parse; the zsh leader rewrites the same file with its own t0 record (`leader: "zsh"`, its pid, `phase: "launched"`) before its dependency checks can exit early, and a best-effort exit trap (EXIT/INT/TERM/HUP) updates it to `phase: "exited"` with the exit code. SIGKILL is untrappable — a `kill -9`'d campaign keeps the t0 record with no outcome update, which alone still proves the campaign launched.

### Leader Loop

**CRITICAL: DO NOT STOP between iterations.** You MUST continue the loop automatically until a sentinel is written (COMPLETE or BLOCKED) or max_iter is reached. Do NOT pause to ask the user. Do NOT wait for confirmation. The loop is fully autonomous.

**PLATFORM CONSTRAINT (Agent mode):** In Agent mode, the Leader is an LLM in Claude Code's turn-based model. A turn ENDS when the response contains no tool calls. This means:
- **NEVER output plain text without an accompanying tool call.** Text-only output = turn ends = loop stops.
- **Use `Bash("echo '...'")` for all status reports** instead of plain text. This keeps the tool-call chain alive.
- **After every step result, IMMEDIATELY start the next step's tool call in the SAME response.** For example, after reading the verdict (⑦c), report via Bash("echo") AND start ⑧'s tool calls in one response.
- If you output "Iter 1 complete, moving to iter 2" as plain text without a tool call, the turn terminates and the loop breaks. This is a platform constraint, not a compliance issue — no amount of "DO NOT STOP" text can override it.

If `--debug`, at loop start debug_log the following (3 [OPTION] entries):
- `[OPTION] slug=<slug> max_iter=<N> verify_mode=<mode> consensus_mode=<off|all|final-only>`
- `[OPTION] cb_threshold=<N> effective_cb_threshold=<N> lock_worker_model=<0|1>`
- `[OPTION] worker_model=<model> verifier_model=<model> final_verifier_model=<model> consensus_model=<model> final_consensus_model=<model>`

For each iteration (1 to max_iter):

**① Check sentinels**
```bash
test -f .rlp-desk/memos/<slug>-complete.md  # → done
test -f .rlp-desk/memos/<slug>-blocked.md   # → stop
```

**①½ Prep-stage cleanup**
```bash
rm -f .rlp-desk/memos/<slug>-done-claim.json
rm -f .rlp-desk/memos/<slug>-verify-verdict.json
```

**② Read memory.md** → Stop Status, Next Iteration Contract
- Also read **Completed Stories** → verified work so far
- Also read **Key Decisions** → settled architectural choices
- If `--debug`: debug_log `[FLOW] iter=N phase=read_memory stop_status=<status> contract="<summary>"`

**③ Decide model** (§4 of governance.md — luna-first)
- Previous iteration failed with failure_category spec/implementation/integration → upgrade model
- failure_category environment/flaky (incl. verifier refusal, capacity stall) → SAME model, recover and retry
- Simple repetitive task → keep current Worker model (luna-first start is already minimal)
- User specified → use that
- If `--debug`: debug_log `[DECIDE] iter=N phase=model_select worker_model=<model> reason=<reason>`

**④ Build worker prompt (Prompt Assembly Protocol)**
1. Capture `WORKING_DIR` once: use `$PWD` from when `/rlp-desk run` was invoked. Store for all prompt construction.
2. Read `.rlp-desk/prompts/<slug>.worker.prompt.md` — use its content **verbatim**. Do NOT rewrite, paraphrase, or regenerate paths. The prompt file contains correct absolute paths from init.
2a. **Per-US PRD injection** (when targeting a specific `us_id`, not "ALL"):
   - Check if `.rlp-desk/plans/prd-<slug>-{us_id}.md` exists (created by init split)
   - If yes: in the assembled prompt text, replace the full PRD reference (`prd-<slug>.md`) with the per-US file path (`prd-<slug>-{us_id}.md`) — so Worker reads only the relevant US section
   - If no per-US file: fall back to full PRD (`prd-<slug>.md`) with no change needed
   - Note: this absolute-path substitution is permitted — only absolute→relative rewrites are forbidden.
3. Prepend meta comment: `## WORKING_DIR: {absolute path}` — Worker must use this as its working directory.
4. Append iteration number + memory contract.
5. Write to `.rlp-desk/logs/<slug>/iter-NNN.worker-prompt.md` (audit trail).
- Note: Worker ALWAYS records execution_steps in done-claim.json per governance §1f. No flag needed. A `commit` step claiming `exit_code: 0` MUST also carry `commit_sha` (the resulting commit SHA) — the Leader verifies this claim against git before any Verifier is dispatched (governance §1f½ / preparation step 3a above); a claimed commit git does not corroborate fails the iteration mechanically.
- **Rewriting paths from absolute to relative WILL break worktree campaigns. Only additions (WORKING_DIR header, iteration context) are allowed.**

**④½ Contract review** (agent mode only)
- Before dispatching Worker, spawn a lightweight review: "Is this iteration contract sufficient to achieve the US's AC? Any missing steps?"
- If `--debug`: debug_log `[GOV] iter=N phase=contract_review scope_lock=<us_id|null> ac_count=<N> result=<ok|issues>`
- In tmux mode: skip (shell leader cannot reason). Log: `[FLOW] iter=N phase=contract_review skipped=tmux_mode`

**⑤ Execute Worker**
- If `--debug`: debug_log `[FLOW] iter=N phase=worker engine=<engine> model=<model> dispatched=true`

Determine engine from `--worker-model` format: plain name (e.g., `haiku`) = claude engine; `model:effort` where `model` is a claude name — short alias `haiku`/`sonnet`/`opus` OR full versioned id `claude-*` (e.g., `opus:max`, `claude-opus-5:high`) — = claude engine; any other `model:reasoning` (e.g., `spark:high`) = codex engine. Use `parse_model_flag()` to split.

If claude engine (default):
```
Agent(
  description="rlp-desk worker iter-NNN",
  model=<worker_model>,
  mode="bypassPermissions",
  prompt=<full worker prompt text>
)
```
- Agent returns synchronously. No polling needed.
- Each Agent() = fresh context. Guaranteed.

If codex engine:
```
Bash("OMX_STATE_ROOT='.rlp-desk/logs/<slug>/runtime/omx-state' codex exec --model <codex_model> --reasoning-effort <codex_reasoning> --disable plugins --disable hooks <full worker prompt text>")
```
- Codex runs as a subprocess via Bash(), not Agent().
- Each Bash() call = fresh context for codex.
- `OMX_STATE_ROOT` prefixes EVERY codex launch (worker, verifier, and consensus — see ⑦a/⑦b below), pointed at the campaign-scoped `.rlp-desk/logs/<slug>/runtime/omx-state` **root** (mkdir -p it before the first launch if absent). `OMX_STATE_ROOT` is a root, not the state dir itself — actual state lands one level deeper, at `.rlp-desk/logs/<slug>/runtime/omx-state/.omx/state/…`. oh-my-codex hooks read project-local `.omx/state/` by default; without isolation, stale interactive-session state (e.g. an unreleased input_lock, or a large pre-existing `.omx/state/sessions/` tree from the operator's own Claude Code sessions) can block/wedge a campaign codex worker. `--disable plugins` does NOT cover hooks.json native hooks, so env isolation is required (3 incidents 2026-08-09 — see failure-modes.md F1.18).
- **`--disable plugins --disable hooks` on EVERY codex launch (worker, verifier, consensus) — see failure-modes.md F1.19.** `~/.codex/hooks.json` registers the oh-my-codex native hook on 7 lifecycle events globally (SessionStart, PreToolUse, PostToolUse, UserPromptSubmit, PreCompact, PostCompact, Stop), and `--disable plugins` does not cover native hooks. Its `UserPromptSubmit` **keyword-detector** scans the prompt of every codex launch and auto-activates deep-interview from ordinary prose in **our own** worker prompt (`Don't assume.`, seeded by the shared worker prompt); `PreToolUse` then blocks every write tool for the rest of that codex session — observed 2026-08-09, 11 blocks, worker aborted with zero files written. **This is NOT stale operator state**: it happens inside the campaign's own isolated `OMX_STATE_ROOT`, so `OMX_STATE_ROOT` cannot prevent it (keep it anyway — it still isolates an `omx` CLI a worker may invoke directly).
- **Probe ONCE, before the first codex dispatch, and reuse the result for the whole campaign.** An unknown feature name is a hard error (`codex --disable bogus` → `Error: Unknown feature flag`), which on an older CLI would break every launch. Run `Bash("codex features list | awk '{print $1}' | grep -qx hooks && echo yes || echo no")` one time and remember the answer; if `no`, omit `--disable hooks` from every launch (keep `--disable plugins`). Do NOT re-probe per dispatch — it costs ~40ms on every worker/verifier/consensus leg for no benefit. Escape hatch: if the operator set `RLP_CODEX_HOOKS=1`, skip the probe and omit `--disable hooks`.
- **If a codex dispatch fails with `Unknown feature flag`** (the probe went stale because the operator updated codex mid-campaign), retry that dispatch exactly once without `--disable hooks`, and omit the flag for the rest of the campaign. Do not retry a second time, and do not apply this to any other failure text.
- Do NOT add `--dangerously-bypass-approvals-and-sandbox` to these `codex exec` launches. Native codex works under the default approval/sandbox posture; adding it here would be a silent posture change, not a parity fix.


**⑥ Read memory.md again** (Worker updated it)

*Channel A — memory.md **"Stop Status"** section.* This is the control-flow channel for step ⑥ and its value set is `continue|verify|blocked`. It is a **different channel** from `iter-signal.json`'s `status` field below; never carry a value across between them.
- `stop=continue` → go to ⑧
- `stop=verify` → go to ⑦
- `stop=blocked` → write BLOCKED sentinel, stop

*Channel B — `iter-signal.json`.* Written by the Worker, canonical key `status`, values `continue|verify|verify_partial|blocked`.
- Also read `iter-signal.json` for `us_id` field (which US was just completed)
- If `iter-signal.json` has `"status":"verify_partial"` → the Worker finished only part of `us_id`. Go to ⑦ and verify the completed part scoped to `us_id`, then return to ④ for the remainder — do NOT mark `us_id` complete and do NOT treat it as an unknown state. (The shared worker prompt authorizes `verify_partial`, so the leader must have a branch for it.)
- If `--debug`: debug_log `[FLOW] iter=N phase=worker_done_signal engine=<engine> status=<stop_status> us_id=<us_id>`

**CRITICAL: Immediately proceed to ⑦. Do NOT pause, do NOT ask the user, do NOT wait for confirmation. The loop is autonomous.**

**⑦ Execute Verifier**

**Per-US mode** (default, `--verify-mode per-us`):
- Read `us_id` from `iter-signal.json` (e.g., "US-001" or "ALL")
- Build verifier prompt scoped to `us_id`:
  - If `us_id` is a specific story: "Verify ONLY the acceptance criteria for {us_id}"
  - If `us_id` is "ALL": "Verify ALL acceptance criteria (final full verify)"
- Write to `iter-NNN.verifier-prompt.md`
- Track verified US in `status.json` field `verified_us` (array)
- After verifier passes a specific US:
  - Add that US to `verified_us` in status.json
  - If more US remain → Worker does next US → verify → ...
  - If all US individually passed → signal final full verify (us_id=ALL)
  - **Sequential final verify** (timeout prevention): Instead of one big ALL verify, loop through each US individually with scoped verifier. After all per-US pass, run the project's test suite as a cross-US integration check. Only COMPLETE if both per-US checks and integration check pass.
  - After sequential final verify passes → COMPLETE

**Batch mode** (`--verify-mode batch`):
- Legacy behavior: verify only when Worker signals all work is done
- Verifier checks all AC at once

**⑦a Dispatch Verifier**
- Note: Verifier ALWAYS records reasoning in verify-verdict.json per governance §1f. No flag needed.
- **Prompt Assembly Protocol (same as ④)**: Read verifier prompt file verbatim. Prepend `## WORKING_DIR: {absolute path}`. Do NOT rewrite paths.
- If `--debug`: debug_log `[FLOW] iter=N phase=verifier engine=<engine> model=<model> scope=<us_id> dispatched=true`

Determine which verifier model to use based on scope:
- If `us_id` is a specific story (per-US verify) → use `--verifier-model` (default: sonnet)
- If `us_id` is "ALL" (final verify) → use `--final-verifier-model` (default: opus)

Determine engine from the selected verifier model format (same as Worker): plain name = claude; `model:effort` with a claude model name (short alias OR full `claude-*` id, e.g. `claude-opus-5:high`) = claude; any other `model:reasoning` = codex.

If claude engine (default):
```
Agent(
  description="rlp-desk verifier iter-NNN (us_id)",
  model=<selected_verifier_model>,
  mode="bypassPermissions",
  prompt=<full verifier prompt text with US scope>
)
```

If codex engine:
```
Bash("OMX_STATE_ROOT='.rlp-desk/logs/<slug>/runtime/omx-state' codex exec --model <codex_model> --reasoning-effort <codex_reasoning> --disable plugins --disable hooks <full verifier prompt text>")
```
- Same `OMX_STATE_ROOT` isolation as the Worker codex launch (④ above) — one shared campaign-scoped omx-state dir per campaign.

**⑦b Consensus Verification** (when `--consensus` is `all`, or `final-only` and scope is ALL):
After the primary verifier runs, run a cross-engine second verifier:
- Determine cross-verifier model based on scope:
  - per-US verify → use `--consensus-model` (default: gpt-5.6-terra:high)
  - final ALL verify → use `--final-consensus-model` (default: gpt-5.6-sol:xhigh)
- If primary engine is claude → cross-verifier uses codex (the consensus model) — dispatched with the same `OMX_STATE_ROOT`-prefixed `Bash("...")` form as ④/⑦a above (one shared campaign-scoped omx-state dir per campaign, not a separate one for consensus)
- If primary engine is codex → cross-verifier uses claude `opus` (fixed)
- Both produce `verify-verdict.json` (Leader renames to `verify-verdict-claude.json` and `verify-verdict-codex.json`)
- **Both pass** → proceed (next US or COMPLETE)
- **Either fails** → combine issues from both verdicts into a single fix contract → Worker retry
- Max 6 consensus rounds per US. After 6 rounds → BLOCKED.

**NO ENGINE PRIORITY (ABSOLUTE):** There is no primary or secondary engine. Claude and Codex have EQUAL weight. If one passes and the other fails, the verdict is FAIL — always. The Leader MUST NOT override, prioritize, or dismiss either engine's verdict. "Claude priority", "primary engine override", "infrastructure failure" (when a valid verdict file exists), or any similar rationalization = governance violation. Infrastructure failure means ONLY: CLI crash (exit ≠ 0), timeout, or verdict file not generated.

**⑦c Read verdict(s)**
- Read `verify-verdict.json` (or both `-claude.json` and `-codex.json` if consensus):
  - `pass` + `complete` → write COMPLETE sentinel, report done!
  - `pass` + specific US → add to `verified_us`, Worker does next US
  - `fail` + `continue` → **run Fix Loop** (governance.md §7½):
    1. Read `issues` array, sort by severity (`critical` → `major` → `minor`)
    2. Build structured fix contract with traceability rule
    3. Include `fix_hint` values labeled `(suggestion, non-authoritative)` if present
    4. Include impacted tests from test-spec (so Worker can run them before and after the fix)
    5. Increment `consecutive_failures` in `status.json`
    6. If `consecutive_failures >= cb_threshold` for same US → **Architecture Escalation** (governance §7¾): stop fixing, report to user
       - If `--debug`: debug_log `[GOV] iter=N phase=CB_trigger consecutive_failures=<N> us_id=<us_id> action=architecture_escalation`
    7. Go to ⑧ with fix contract as next Worker contract
  - `request_info` → Leader reads Verifier's questions, decides outcome (or relays to Worker in next contract) → go to ⑧
  - `blocked` → write BLOCKED sentinel, stop
- If `--debug`: debug_log `[GOV] iter=N phase=verdict engine=<engine> verdict=<pass|fail|request_info> us_id=<us_id> L1=<status> L2=<status> L3=<status> L4=<status>`
- If `--debug`: debug_log `[GOV] iter=N phase=sufficiency test_count=<N> ac_count=<N> ratio=<N> verdict=<pass|fail>`

**⑦d Archive iteration artifacts** (always — independent of --debug)
After reading the verdict, archive to `logs/<slug>/`:
- `iter-NNN-done-claim.json` ← copy from `memos/<slug>-done-claim.json`
- `iter-NNN-verify-verdict.json` ← copy from `memos/<slug>-verify-verdict.json`
(Preserved across clean; data source for campaign report generation and SV analysis.)

**CRITICAL: Immediately proceed to ⑧. Do NOT pause, do NOT ask the user. Continue the loop.**

**⑧ Write result log and report to user, continue loop**
- Write `logs/<slug>/iter-NNN.result.md`:
  - Result status `[leader-measured]`
  - Files changed: cumulative working tree state via `git diff --stat HEAD` `[git-measured]` (note: cumulative in tmux mode, not per-iteration delta)
  - Verifier verdict `[leader-measured]`
- **Record cost & performance per iteration**:
  - Agent mode: record `total_tokens` and `duration_ms` from Agent() return metadata for both Worker and Verifier
  - Tmux mode: record `duration_seconds` from shell timing. Estimate tokens from file sizes: `(prompt_bytes + done_claim_bytes + verdict_bytes) / 4` — label as "estimated"
  - Write to `status.json`: `{"iter_N": {"worker_tokens": N, "worker_duration_ms": N, "verifier_tokens": N, "verifier_duration_ms": N, "token_source": "measured|estimated"}}`
- Write `status.json`
- Report via tool call: `Bash("echo 'Iter N | US-NNN | verdict | model | next_action'")` — NEVER plain text. This keeps the turn alive for the next iteration.
- **Always**: append to baseline.log: `[timestamp] iter=N verdict=<pass|fail|continue> us=<us_id> model=<worker_model>`
- **Always**: append JSONL to `~/.claude/ralph-desk/analytics/<slug>/campaign.jsonl`: `{"iter":N,"us_id":"US-NNN","verdict":"pass|fail","worker_model":"...","worker_engine":"...","verifier_model":"...","verifier_engine":"...","consensus_mode":"off|all|final-only","duration_worker_s":N,"duration_verifier_s":N,"timestamp":"ISO8601"}`
- If `--debug`: debug_log `[FLOW] iter=N phase=result status=<result> consecutive_failures=<N> verified_us=<list>`

At loop end (COMPLETE, BLOCKED, or TIMEOUT):
- If `--debug`: debug_log `[FLOW] result=<COMPLETE|BLOCKED|TIMEOUT> iterations=<N> verified_us=<list>`

**⑨ Campaign Self-Verification** (when `--with-self-verification` is enabled):

After the loop ends, the Leader performs post-campaign analysis:

1. **Collect data**: Read all archived `iter-NNN.result.md`, done-claim.json (with execution_steps), and verify-verdict.json (with reasoning) from `logs/<slug>/`
2. **Write cumulative data**: `~/.claude/ralph-desk/analytics/<slug>/self-verification-data.json` — normalized iteration records (agent-mode only artifact)
3. **Generate versioned report**: `~/.claude/ralph-desk/analytics/<slug>/self-verification-report-NNN.md` (NNN = auto-increment from existing reports)
4. **Report to user**: Display the full report content

Report template (10 sections):

```
# Campaign Self-Verification Report: <slug>
Report Version: NNN | Generated: timestamp | Campaign: slug — objective
Schema Version: governance hash | Data Quality: N% iterations complete

## 1. Automated Validation Summary
Table: Iter | US | Worker Verdict | Verifier Verdict | Outcome

## 2. Failure Deep Dive (per failed iteration)
Per failure: Worker steps → Verifier reasoning → Root cause → Resolution

## 3. Worker Process Quality (§1f audit)
Table: Iter | US | Steps | verify_red? | RED exit≠0? | verify_green? | Test-First? | E2E? | AC linked?
Aggregate: TDD compliance %, RED confirmation %, E2E evidence %, step completeness %
Audit: each step object must have "step" field with value from §1f vocabulary (write_test, verify_red, implement, verify_green, refactor, verify_e2e, commit, verify) + ac_id + command + exit_code

## 4. Verifier Judgment Quality (§1f audit)
Table: Iter | US | Checks | All Basis? | Independent? | IL-1? | Layer? | Sufficiency? | Anti-Gaming? | Worker Audit?
Aggregate: Reasoning completeness %, Independent verification %, §1f category coverage %
Audit: verify all 5 mandatory check categories (IL-1, Layer Enforcement, Test Sufficiency, Anti-Gaming, Worker Process Audit) are present. The Worker Process Audit is mode-aware (v0.22.3): in leader-derived confirmation mode (all US verified, SHA-anchored unchanged tree) the verifier judges on its OWN fresh reruns instead of demanding RED-before-GREEN from the done-claim.

## 5. AC Lifecycle
Table: US | AC | First Claimed (iter) | First Verified (iter) | Reopen Count | Final Status

## 6. Test-Spec Adherence
Spec completeness (layers/commands/mappings present)
Spec execution fidelity (exact checks run and cited)

## 7. Patterns: Strengths & Weaknesses
Strengths: what worked well
Weaknesses: systemic issues

## 8. Recommendations for Next Cycle
### Brainstorm (missing scenarios/constraints) — citing iter/AC
### PRD (ambiguous or oversized ACs) — citing iter/AC
### Test-Spec (missing layers, weak mappings) — citing iter/AC

## 9. Cost & Performance
Table: Iter | Role | Model | Tokens | Duration | Source
Aggregate: total Worker tokens, total Verifier tokens, total campaign tokens, total duration
Source: "measured" (Agent mode) or "estimated" (Tmux mode, from file sizes / 4)

## 10. Blind Spots
What this report CANNOT prove from available data

## Data Provenance Rule
Report content MUST be derivable from: done-claim.json (execution_steps), verify-verdict.json (reasoning),
PRD, and test-spec. Information from source code inspection that is not in these files must be excluded
or explicitly marked as "[source-inspection]" with justification.
```

**⑩ Campaign Report** (always — independent of `--debug` and `--with-self-verification`)

After the loop ends (COMPLETE, BLOCKED, or TIMEOUT), generate `logs/<slug>/campaign-report.md`:

1. If `campaign-report.md` already exists, rename it to `campaign-report-v{N}.md` (N = next available integer ≥ 1) before writing new.
2. Generate report with 8 required sections:
   - **Objective**: From PRD
   - **Execution Summary**: Iterations run, terminal state (COMPLETE/BLOCKED/TIMEOUT), elapsed time
   - **US Status**: Each US with final verified/failed/pending status (from `status.json`)
   - **Verification Results**: Per-US and final verify outcomes (from archived iter artifacts)
   - **Issues Encountered**: Fix contracts and failure verdicts from campaign
   - **Cost & Performance**: computed deterministically by the leader — this
     section is code output, not prose for the LLM to compose. Both leaders
     read `models.json`'s `cost_factors` table (shipped-first) to convert
     codex-leg tokens to a sol-equivalent: total = Σ(iteration tokens ×
     factor), factors sol 1.0 / terra 0.4 / luna 0.04 (2026-07-30 API
     prices). Coverage differs by leader (LOW-3, SV gate — doc was
     previously over-scoped for Node):
     - **zsh** (`generate_campaign_report` reading `cost-log.jsonl`):
       full block — per-iter token/duration data, the sol-equivalent line,
       Claude legs listed by count only (separate subscription pool — no
       factor conversion), the escalation count (ladder moves), and the
       final model reached per US.
     - **Node** (`summarizeCost` reading `campaign.jsonl`): iteration
       record count, total duration, and the sol-equivalent line only — no
       Claude-legs breakdown, escalation count, or final-model-per-US lines
       today.
     On both leaders, rows lacking model/token attribution (pre-enrichment
     logs, or non-worker-dispatch rows on the Node side) are still counted
     into the raw total where applicable and surfaced as "(N iteration(s)
     unattributed)" rather than silently dropped. If per-iter token data is
     estimated (tmux bytes÷4 basis rather than real usage), the summary is
     marked "estimated".
   - **SV Summary**: If `--with-self-verification` ran, pointer to SV report file; otherwise "N/A — --with-self-verification not enabled"
   - **Files Changed**: `git diff --stat <baseline_commit>` (working tree vs baseline, includes uncommitted changes and untracked files). Note: may include pre-existing uncommitted changes if the campaign started in a dirty worktree.
3. Data sources: `status.json` (baseline_commit, per-iter data), archived `iter-NNN-done-claim.json` / `iter-NNN-verify-verdict.json`, PRD, git diff.
4. If `--with-self-verification` was enabled: ⑨ SV report runs first, then ⑩ Campaign Report (which includes the SV Summary section pointing to the SV report file).

### Circuit Breaker
- context-latest.md unchanged 3 iterations → BLOCKED
- Same acceptance criterion fails 2 consecutive iterations → upgrade model, retry once, then BLOCKED
- 3 consecutive **fail** verdicts on 3 unique criterion IDs → upgrade model per the ladder (claude: →opus; codex: next ladder step), retry once, then BLOCKED
- max_iter reached → TIMEOUT, report to user

Track `consecutive_failures` in `status.json` (increment on `fail`, reset on `pass`, unchanged by `request_info`). Only **fail** verdicts count for CB chains — `request_info` does not break or contribute.

Track `verified_us` (array of US IDs that passed verification) in `status.json` when using `--verify-mode per-us`.

When `--consensus` is not `off`, also track in `status.json`:
- `consensus_round`: current consensus round for this US (resets per US)
- `claude_verdict`: latest claude verifier verdict for this US
- `codex_verdict`: latest codex verifier verdict for this US

### Important Rules
- Each Agent() = new process = fresh context
- YOU track iteration count
- Write `status.json` after each iteration
- Worker claim ≠ complete. Only YOU write COMPLETE sentinel after verifier pass.
- **NEVER modify rlp-desk infrastructure files** (`~/.claude/ralph-desk/*`, `~/.claude/commands/rlp-desk.md`). If you or a Worker/Verifier discovers a bug in rlp-desk itself, write BLOCKED sentinel with reason `"rlp-desk bug: <description>"` and STOP. Do NOT attempt to fix rlp-desk — report the bug to the user.

---

## `status <slug>`
Read `.rlp-desk/logs/<slug>/runtime/status.json` and display a detailed report:

```
Campaign: <slug>
Iteration: <iteration> / <max_iter>
Phase: <phase> | Last Result: <last_result>
Worker Model: <worker_model> | Verifier: <verifier_model> (per-US) / <final_verifier_model> (final)
Verify Mode: <verify_mode> | Consensus: <consensus_mode>
Consecutive Failures: <consecutive_failures>
Escalation-Eligible Failures: <escalation_eligible_failures>   # omitted when the leader does not persist it
Verified US: <verified_us array, comma-separated>
Updated: <updated_at_utc> (elapsed: now - updated_at)
```

If `status.json` does not exist, display "No active campaign for <slug>."
If the campaign has a `complete` or `blocked` sentinel, show that status prominently.
Read the last `verify-verdict.json` to show the most recent verdict summary and any failure issues.

## `logs <slug> [N]`
- No N: show latest `iter-*.worker-prompt.md` summary
- With N: read `iter-N.worker-prompt.md` and `iter-N.verifier-prompt.md`

## `clean <slug> [--kill-session]`
Remove:
- `.rlp-desk/memos/<slug>-complete.md`
- `.rlp-desk/memos/<slug>-blocked.md`
- `.rlp-desk/memos/<slug>-done-claim.json`
- `.rlp-desk/memos/<slug>-verify-verdict.json`
- `.rlp-desk/memos/<slug>-iter-signal.json`
- `.rlp-desk/logs/<slug>/circuit-breaker.json`
- `.rlp-desk/logs/<slug>/runtime/session-config.json`
- `.rlp-desk/logs/<slug>/runtime/worker-heartbeat.json`
- `.rlp-desk/logs/<slug>/runtime/verifier-heartbeat.json`
- `.rlp-desk/memos/<slug>-escalation.md`
Note: `campaign-report.md`, `campaign-report-v{N}.md`, `iter-NNN-done-claim.json`, and `iter-NNN-verify-verdict.json` are intentionally preserved across clean for historical comparison. Analytics files (`debug.log`, `campaign.jsonl`, `self-verification-data.json`, `self-verification-report-NNN.md`) at `~/.claude/ralph-desk/analytics/<slug>/` are NOT affected by project-level clean.

If `--kill-session` is passed, clean up Worker/Verifier tmux panes using session-config.json:
```bash
# Read pane IDs from session-config.json (safe — targets only Worker/Verifier panes)
SESSION_CONFIG=".rlp-desk/logs/<slug>/runtime/session-config.json"
if [ -f "$SESSION_CONFIG" ] && command -v jq &>/dev/null; then
  WORKER_PANE=$(jq -r '.panes.worker // empty' "$SESSION_CONFIG")
  VERIFIER_PANE=$(jq -r '.panes.verifier // empty' "$SESSION_CONFIG")

  for pane_id in "$WORKER_PANE" "$VERIFIER_PANE"; do
    if [ -n "$pane_id" ]; then
      tmux send-keys -t "$pane_id" C-c 2>/dev/null
      tmux send-keys -t "$pane_id" "/exit" Enter 2>/dev/null
    fi
  done
  sleep 2
  for pane_id in "$WORKER_PANE" "$VERIFIER_PANE"; do
    if [ -n "$pane_id" ]; then
      tmux kill-pane -t "$pane_id" 2>/dev/null
    fi
  done
else
  echo "WARNING: session-config.json not found or jq not installed."
  echo "Cannot safely identify Worker/Verifier panes. Kill them manually."
fi
```
**CRITICAL: NEVER use `grep -i 'claude\|codex'` to find panes to kill.** The user's own Claude Code session matches those patterns. Always use the specific pane IDs from session-config.json.

## `analytics [slug]`

Cross-project analytics dashboard. Scans `~/.claude/ralph-desk/analytics/` for all campaign data.

- No slug: show summary across all projects (total campaigns, pass/fail rate, average iterations, total cost)
- With slug: show detailed analytics for that project (per-US pass rate, model upgrade frequency, iteration distribution, cost per US)

Data sources:
- `campaign.jsonl` — per-iteration structured records
- `metadata.json` — project root, campaign status, timestamps
- `self-verification-data.json` — campaign-level quality metrics

## `resume <slug>`

Resume a previously interrupted campaign. Equivalent to `run <slug>` but explicitly restores state:

1. Read `.rlp-desk/logs/<slug>/runtime/status.json` for `verified_us`, `iteration`, `consecutive_failures`
2. Read `.rlp-desk/memos/<slug>-memory.md` for completed stories and next iteration contract
3. Check for sentinels (`complete.md`, `blocked.md`) — if present, inform user and stop
4. If no sentinels, invoke `run <slug>` with the same options from the previous session (stored in status.json fields: `worker_model`, `verifier_model`, `final_verifier_model`, `verify_mode`, `consensus_mode`)
5. The runner automatically restores `verified_us` from memory or status.json on startup

Example:
```
/rlp-desk resume my-feature
```

## No args or `help`
```
/rlp-desk brainstorm <description>          Plan before init (interactive)
/rlp-desk init  <slug> [objective]          Create project scaffold
/rlp-desk run   <slug> [options]            Run loop (native=Native Agent() leader (slash), tmux=zsh leader (production); legacy `agent` redirects to `native` — direct Node CLI `--mode agent` is deprecated alpha)
/rlp-desk status <slug>                     Show loop status
/rlp-desk logs  <slug> [N]                  Show iteration log
/rlp-desk clean <slug> [--kill-session]     Reset for re-run (--kill-session kills tmux)

Run options:
  --mode native|tmux                   Execution mode (default: native)
  --worker-model MODEL                 Worker model: haiku|sonnet|opus|claude-opus-5:high (claude, effort optional) or gpt-5.6-sol:high|luna:high|terra:high|spark:high (codex) (default: haiku)
  --lock-worker-model                  Disable auto model upgrade on failure
  --verifier-model MODEL               per-US verifier (default: sonnet; recommended per complexity: claude-sonnet-5:high/claude-opus-5:low/claude-opus-5:high/claude-opus-5:max)
  --final-verifier-model MODEL         Final ALL verifier (default: opus; recommended claude-fable-5:max)
  --consensus off|all|final-only       Cross-engine consensus; claude leg reuses verifier/final-verifier (default: off)
  --consensus-model MODEL              per-US cross-verifier — codex leg only (default: gpt-5.6-terra:high)
  --final-consensus-model MODEL        Final cross-verifier — codex leg only (default: gpt-5.6-sol:xhigh)
  --verify-mode per-us|batch           Verification strategy (default: per-us)
  --cb-threshold N                     Consecutive failures before BLOCKED (default: 6)
  --max-iter N                         Max iterations (default: 100)
  --iter-timeout N                     Per-iteration timeout, tmux only (default: 600)
  --waivers-sha256 HASH                Out-of-band authorization for .rlp-desk/plans/waivers.json (fail-closed waiver channel)
  --debug                              Debug logging (~/.claude/ralph-desk/analytics/<slug>/debug.log)
  --with-self-verification             Campaign self-verification analysis (post-loop report)
```

## Architecture

### Native Agent() Mode (default: `--mode native`)
```
[This session = LEADER (LLM, slash command itself)]
        │
  Agent()├──▶ [Worker: claude subagent (fresh context, mode="bypassPermissions")]
        │     └── reads desk files, implements, updates memory
        │
  Agent()└──▶ [Verifier: claude subagent (fresh context, mode="bypassPermissions")]
        │     └── reads done-claim, runs checks, writes verdict
        │
  Bash() ───▶ [Worker/Verifier: codex CLI subprocess]
              └── `codex exec --model <m> --reasoning-effort <r> --disable plugins --disable hooks <prompt>`
```

### Tmux Mode (`--mode tmux`)
```
[tmux session: rlp-desk-<slug>-<timestamp>]
+-------------------------------------+
| Leader pane (shell loop)            |
| - writes prompts to files           |
| - sends short triggers via send-keys|
| - polls iter-signal.json            |
| - monitors heartbeat files          |
| - writes sentinels                  |
+------------------+------------------+
| Worker pane      | Verifier pane    |
| bash trigger.sh  | bash trigger.sh  |
| -> claude -p ... | -> claude -p ... |
| heartbeat writer | heartbeat writer |
| (fresh context)  | (fresh context)  |
+------------------+------------------+
```
