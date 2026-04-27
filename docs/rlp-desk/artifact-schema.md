# rlp-desk Artifact Schema (v5.7 §4.25)

> Worker/Verifier write JSON artifacts that the Leader reads. The schema validator at the READ boundary enforces these contracts. **Violation → BLOCKED `contract_violation/malformed_artifact`** (recoverable).

## Validated artifacts

| File | Written by | Read by | `signal_type` |
|------|-----------|---------|---------------|
| `<slug>-iter-signal.json` | Worker | Leader (worker poll) | `signal` |
| `<slug>-verify-verdict.json` (per-US) | Verifier | Leader (verifier poll) | `verdict` |
| `<slug>-verify-verdict.json` (final ALL) | Verifier | Leader (final-verifier poll) | `verdict` |
| `<slug>-flywheel-signal.json` | Flywheel | Leader (flywheel poll) | `flywheel_signal` |
| `<slug>-flywheel-guard-verdict.json` | Guard | Leader (guard poll) | `flywheel_guard_verdict` |
| `<slug>-done-claim.json` | Worker | Leader (analytics, A4 fallback) | `done_claim` |

## Required structural fields (validated by `validateArtifact`)

| Field | Type | Constraint | Notes |
|-------|------|------------|-------|
| `slug` | string | === campaign slug | OPTIONAL for backward compat. If present, must match. |
| `iteration` | integer | ≥ `iteration_floor` (current state.iteration) | OPTIONAL for backward compat. Worker may advance, never regress. |
| `signal_type` | string | === expected per read context | OPTIONAL for backward compat. Discriminates artifacts at read time. |
| `us_id` | string | ∈ `usList ∪ {'ALL'}` | OPTIONAL for backward compat. Closed-set check. |

The validator is structural-minimum + semantic-anchor. It does NOT validate downstream business fields (e.g. `verdict.verdict`, `signal.status`); those are checked by their respective consumers.

## Examples

### Valid worker signal
```json
{
  "slug": "sum-fn",
  "iteration": 1,
  "signal_type": "signal",
  "us_id": "US-001",
  "status": "verify",
  "summary": "implementation done; tests pass"
}
```

### Valid verifier verdict
```json
{
  "slug": "sum-fn",
  "iteration": 1,
  "signal_type": "verdict",
  "us_id": "US-001",
  "verdict": "pass",
  "criteria_results": [...]
}
```

### Violation: wrong slug
```json
{
  "slug": "wrong-campaign",   // ← BLOCKED contract_violation
  "iteration": 1,
  ...
}
```
→ `Malformed artifact at slug: expected sum-fn, got wrong-campaign`

### Violation: us_id outside allowed set
```json
{
  "us_id": "US-999"   // ← BLOCKED contract_violation (US-999 ∉ [US-001, ALL])
}
```
→ `Malformed artifact at us_id: expected one of [US-001, ALL], got US-999`

### Violation: iteration regress
```json
{
  "iteration": 0   // ← floor is 1; regress not allowed
}
```
→ `Malformed artifact at iteration: expected >= 1, got 0`

## Backward compatibility

Existing artifacts written before v5.7 §4.25 do not carry `slug`/`signal_type`/`iteration` fields. The validator skips any field not present (`undefined` is allowed). Workers/Verifiers SHOULD start emitting these fields for stronger contract enforcement, but legacy artifacts continue to work.

## Feedback loop closure

When `MalformedArtifactError` fires:
1. `_handlePollFailure` writes BLOCKED with `reason_category: contract_violation`, `failure_category: malformed_artifact`, `recoverable: true`.
2. `reason_detail` includes the structured error: `Malformed artifact at <field>: expected <expected>, got <got>`.
3. Operators reviewing `<slug>-blocked.json` see the precise contract violation and can update the Worker prompt template (`prompts/<slug>.worker.prompt.md`) to require the missing/correct field.
4. On re-run after fix, the Worker writes a compliant artifact and the campaign proceeds.

## Authoring guidance

- Worker prompt templates SHOULD instruct the LLM to include `slug`, `iteration`, `signal_type`, and `us_id` in every JSON artifact.
- The fix-contract (`buildFixContract` in `campaign-main-loop.mjs`) already feeds verifier failures back to the next Worker; future enhancement: feed `MalformedArtifactError` details directly into the next Worker prompt without requiring user re-run.

## Audit

- Schema unit tests: `tests/node/test-artifact-schema.mjs` (7 violation scenarios)
- E2E: Schema violations are exercised in `tests/sv-gate-full.sh` (REAL campaign E2E asserts `complete.md` or `blocked.md` exists — schema violations route to the latter)
