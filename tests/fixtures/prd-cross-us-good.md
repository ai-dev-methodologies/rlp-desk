# PRD: Cross-US Dependency Lint — Good Fixture

Per-us-mode-compatible PRD. Each US AC references only the same US or
earlier verified US. Cross-US measurement is folded into the last
measurement US (US-003), and earlier US never reference future US.

## Plan

### US-001: Axis 9 — Writer prompt few-shot examples
- Risk: MEDIUM
- AC1:
  - Given: writer prompt template lacks few-shot block
  - When: leader injects 3 curated examples
  - Then: prompt file contains the new section
- AC2:
  - Given: examples include both positive and counter examples
  - When: worker reads the prompt
  - Then: token count stays under 8000

### US-002: Axis 10 — Outline scoring rubric
- Risk: LOW
- AC1:
  - Given: rubric file is missing
  - When: leader writes the rubric
  - Then: rubric file exists with 5 dimensions

### US-003: Mission 5 measurement batch
- Risk: HIGH
- AC1:
  - Given: US-001 prompt update is verified
  - When: leader runs the measurement batch
  - Then: batch JSON is written
- AC2:
  - Given: aggregator reads the batch JSON
  - When: windowed M1 is recomputed
  - Then: verdict ∈ {improved, partial} (or fail with concrete reason)
