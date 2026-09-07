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
- [ ] Cross-campaign trend analysis (compare report-001 vs report-002)
- [x] Integration with brainstorm — done (rlp-desk.md brainstorm step 0 "SV Report Feedback" reads the latest prior report; governance §8½)

---

## P3: External Tool Integration + Domain Specialization

P0-P2 (governance policies + templates) form the foundation. P3 requires external dependencies and is planned for separate feature branches.

### P3-1: Domain Rule Packs
- **Purpose**: Domain-specific verification rule sets (finance, healthcare, security)
- **Why separate**: Different in nature from universal governance. Requires plugin architecture.
- [ ] Plugin loading mechanism design
- [ ] Finance domain rule pack (first)
- [ ] Rule pack authoring guide

### P3-2: Playwright Agents
- **Purpose**: Automated verification for visual/content task types (screenshot comparison, accessibility checks)
- **Why separate**: Requires Playwright installation + browser binaries + CI environment setup.
- [ ] Playwright integration wrapper
- [ ] Screenshot comparison verification logic
- [ ] CI environment guide

### P3-3: Mutahunter / Spec Kit
- **Purpose**: Automated mutation testing execution for CRITICAL risk
- **Why separate**: Requires language-specific tool wrappers (mutmut, Stryker, go-mutesting). Governance defines the Gate only.
- [ ] Language-specific mutation tool wrappers
- [ ] Mutation score collection + verdict integration
- [ ] Spec Kit: test-spec auto-generation helper
