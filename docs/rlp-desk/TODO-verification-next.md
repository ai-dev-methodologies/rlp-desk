# Verification Policy — Next Iterations

> Items scoped out of the feature/verification-policy branch.
> P0-P2 (governance + templates) are complete. These items are planned for subsequent iterations.

---

## --with-self-verification Flag (Campaign-Level Analysis)

Post-campaign analysis that reads all iteration artifacts and generates a versioned report.

### Concept
- Separate from `--debug` (which logs Leader decisions)
- After COMPLETE/BLOCKED/TIMEOUT/INTERRUPTED (tmux-mode only), Leader analyzes all done-claims and verdicts
- Generates `.rlp-desk/analytics/<slug>--<hash8>/self-verification-report.md` (unversioned, `--mode tmux`; older reports moved aside to `-v{N}.md` — Node writer, `generateSVReport()`) or `.rlp-desk/analytics/<slug>--<hash8>/self-verification-report-NNN.md` (versioned, `--mode native`; written by hand by the Leader per rlp-desk.md step ⑨) — two real, un-unified writers, same directory, different filenames; see rlp-desk.md "Analytics Directory". A third writer, `lib_ralph_desk.zsh`'s `generate_sv_report()`, is dead code (its `$TMUX` early return is always taken by the time its only caller — after the campaign loop — runs) and never produces a file — do not read it.
- Per-run data stored in `.rlp-desk/analytics/<slug>--<hash8>/self-verification-data.json` (overwritten each run, not cumulative across runs)

### Report Sections (10-section template defined in rlp-desk.md step ⑨; see also `generateSVReport()` in `src/node/reporting/campaign-reporting.mjs`)
1. Automated Validation Summary
2. Failure Deep Dive
3. Worker Process Quality (§1f audit)
4. Verifier Judgment Quality (§1f audit)
5. AC Lifecycle
6. Test-Spec Adherence
7. Patterns: Strengths & Weaknesses
8. Recommendations for Next Cycle (Brainstorm / PRD / Test-Spec)
9. Cost & Performance
10. Blind Spots

### Open Design Items
- [x] Automated report generation — done for `--mode tmux` (ARCH Wave C-SV: `generateSVReport()` runs as a Node post-pass after the zsh leader exits). `--mode native` still relies on the Leader (LLM) authoring the report itself per the rlp-desk.md step ⑨ template — that path remains manual.
- [x] Cross-campaign trend analysis (compare report-001 vs report-002) — done: `node ~/.claude/ralph-desk/node/run.mjs trend [<slug>] [--json] [--last N]` (read-only reader over `campaign*.jsonl`; `src/node/reporting/campaign-trend.mjs`, `tests/node/d1-campaign-trend.test.mjs`)
- [x] Integration with brainstorm — done (rlp-desk.md brainstorm step 0 "SV Report Feedback" reads the latest prior report; governance §8½)

---

## P3: External Tool Integration + Domain Specialization

P0-P2 (governance policies + templates) form the foundation. P3 requires external dependencies and is planned for separate feature branches.

### P3-1: Domain Rule Packs
- **Purpose**: Domain-specific verification rule sets (finance, healthcare, security)
- **Why separate**: Different in nature from universal governance. Requires plugin architecture.
- [x] Plugin loading mechanism design — done: JSON rule packs found by name (project `.rlp-desk/rule-packs/` then shipped), rendered into the test-spec by `node ~/.claude/ralph-desk/node/run.mjs rule-pack apply <slug> --pack <name>` (manual, idempotent; `src/node/tools/rule-pack.mjs`, `tests/node/d2-rule-pack.test.mjs`)
- [x] Finance domain rule pack (first) — done: `rule-pack apply <slug> --pack finance` (`src/node/rule-packs/finance.pack.json`, 11 rules; engineering guidance, not a compliance certification; owner/domain review of the rule text still advised before release)
- [x] Rule pack authoring guide — done: `docs/rlp-desk/rule-pack-authoring.md`

### P3-2: Playwright Agents
- **Purpose**: Automated verification for visual/content task types (screenshot comparison, accessibility checks)
- **Why separate**: Requires Playwright installation + browser binaries + CI environment setup.
- [x] Playwright integration wrapper — done: `node ~/.claude/ralph-desk/node/run.mjs visual <detect|run>` wraps the project's own `@playwright/test` (never installs anything), parsed against real 1.64.1 captures in `tests/fixtures/visual/` (`src/node/tools/visual.mjs`, `tests/node/d3-visual-wrapper.test.mjs`); exit 0 pass / 1 fail / 2 cannot judge / 64 usage
- [x] Screenshot comparison verification logic — done: comparison stays Playwright's `toHaveScreenshot`; `visual run` adds the baseline-integrity guard (`--baseline-ref`: modified/deleted baselines fail, added ones are listed for review), rejects `--update-snapshots`, normalizes `screenshot_failures`, and the verdict policy is governance §1d "Visual Verdict" (a configured visual gate that cannot run is FAIL)
- [x] CI environment guide — done: `docs/rlp-desk/visual-verification-guide.md` (install, browser cache, same-OS baselines, determinism settings, baseline review, tmux/native notes)

### P3-3: Mutahunter / Spec Kit
- **Purpose**: Automated mutation testing execution for CRITICAL risk
- **Why separate**: Requires language-specific tool wrappers (mutmut, Stryker, go-mutesting). Governance defines the Gate only.
- [x] Language-specific mutation tool wrappers — done: `node ~/.claude/ralph-desk/node/run.mjs mutation <detect|run>` with Stryker, mutmut 3.x and go-mutesting adapters, parsers built against real captures in `tests/fixtures/mutation/` (`src/node/tools/mutation.mjs`, `tests/node/d4-mutation-wrapper.test.mjs`); tools are never installed by the wrapper
- [x] Mutation score collection + verdict integration — done: one uniform score (`(killed+timeout)/(killed+timeout+survived+no_coverage+unknown)`), exit 0 / 1 / 2 / 64, and the CRITICAL Checkpoint 2 verdict rule in governance §1c½ (a configured gate that cannot run is FAIL `MUT-GATE-UNMET`; brainstorm runs `mutation detect` before the test-spec `Tool:` line names a tool)
- [x] Spec Kit: test-spec auto-generation helper — done: `node ~/.claude/ralph-desk/node/run.mjs speckit <spec.md> [--slug S] [--out F]` drafts a test-spec skeleton (stdout by default, banner, TODO methods, `needs_quantification`, `[NEEDS CLARIFICATION]` surfaced, unfilled template rejected, never writes a sealable name); built against the real Spec Kit v1.2.3 template in `tests/fixtures/speckit/` (`src/node/tools/speckit.mjs`, `tests/node/d5-speckit-draft.test.mjs`); brainstorm step 2.5 also tells the Leader to read `specs/*/spec.md`
