# Verification Policy — Next Iterations

> Items scoped out of the feature/verification-policy branch.
> P0-P2 (governance + templates) are complete. These items are planned for subsequent iterations.

---

## --with-self-verification Flag (Campaign-Level Analysis)

Post-campaign analysis that reads all iteration artifacts and generates a versioned report.

### Concept
- Separate from `--debug` (which logs Leader decisions)
- After COMPLETE/BLOCKED/TIMEOUT, Leader analyzes all done-claims and verdicts
- Generates `logs/<slug>/self-verification-report-NNN.md` (versioned per run)
- Cumulative data stored in `logs/<slug>/self-verification-data.json`

### Report Sections (9-section template defined in rlp-desk.md step 9)
1. Automated Validation Summary
2. Failure Deep Dive
3. Worker Process Quality (§1f audit)
4. Verifier Judgment Quality (§1f audit)
5. AC Lifecycle
6. Test-Spec Adherence
7. Patterns: Strengths & Weaknesses
8. Recommendations for Next Cycle (Brainstorm / PRD / Test-Spec)
9. Blind Spots

### Open Design Items
- [ ] Automated report generation (currently manual Leader analysis)
- [ ] Cross-campaign trend analysis (compare report-001 vs report-002)
- [ ] Integration with brainstorm (Leader reads previous report at brainstorm start)

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
