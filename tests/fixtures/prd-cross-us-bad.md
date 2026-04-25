# PRD: Cross-US Dependency Lint — Bad Fixture

This PRD intentionally contains a cross-US dependency to exercise the
init-time lint (`init_ralph_desk.zsh`'s `_detect_cross_us_refs`).

US-001's AC3 references US-003, which makes the AC unsatisfiable inside a
single per-us iteration scoped to US-001. Under `VERIFY_MODE=per-us` the
lint MUST exit 2; under `VERIFY_MODE=batch` it MUST warn and exit 0.

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
- AC3:
  - Given: post-iter 신규 batch 6 run (US-003)
  - When: aggregator windowed 재집계
  - Then: M1 (windowed N=6) verdict ∈ {improved, partial}

### US-002: Axis 10 — Outline scoring rubric
- Risk: LOW
- AC1:
  - Given: rubric file is missing
  - When: leader writes the rubric
  - Then: rubric file exists with 5 dimensions

### US-003: Mission 5 measurement batch
- Risk: HIGH
- AC1:
  - Given: previous mission artifacts are present
  - When: leader runs the measurement batch
  - Then: batch JSON is written
