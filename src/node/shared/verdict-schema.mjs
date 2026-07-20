// Verdict-schema normalizer (US-003, PRD campaign-hardening-v1).
//
// THREE distinct producer shapes emit AC-verdict JSON with different field
// names for the same concepts:
//   - verifier verdict template (init_ralph_desk.zsh:852-874):
//       issues[].id / issues[].description; reasoning[] is an array of
//       {check, decision, basis}; criteria_results[]; top-level us_id.
//   - sequential-final failure (run_ralph_desk.zsh:4595, zsh production):
//       issues[].criterion / issues[].description; no reasoning; no us_id.
//   - Node integration-failure (campaign-main-loop.mjs, oracle):
//       issues[].criterion_id / issues[].summary; no reasoning; no us_id.
//
// This module absorbs the UNION of those shapes so a consumer can read a
// single normalized field regardless of which producer wrote the verdict.
// It does NOT replace one field with another — each producer keeps emitting
// its own field name; the fallback chain here is what changes, not the
// producers. When a field is genuinely absent from every shape, the
// normalized value is `undefined` (or the documented fallback string for
// issue text/label) so callers can distinguish "absent in source" from
// "misread by generator".

function firstPresent(...values) {
  for (const value of values) {
    if (value !== undefined && value !== null && value !== '') {
      return value;
    }
  }
  return undefined;
}

// IMP-01: canonical verdict/transition string tables. The zsh leader mirrors
// these exactly (_normalize_verdict in lib_ralph_desk.zsh); parity is pinned by
// tests/fixtures/verdict-schema/verdict-string-cases.json driven through BOTH
// implementations. Rules: strip CR, trim, lowercase, collapse space/hyphen runs
// to "_", then a CLOSED synonym map. Unknown values pass through canonicalized
// but unmapped so the leader's unknown-verdict CB branch still fires. null and
// undefined pass through untouched.
export const VERDICT_SYNONYMS = Object.freeze({
  passed: 'pass',
  failed: 'fail',
  failure: 'fail',
  block: 'blocked',
});
export const TRANSITION_SYNONYMS = Object.freeze({
  completed: 'complete',
  done: 'complete',
});

function normalizeToken(raw, synonyms) {
  if (raw === undefined || raw === null) return raw;
  const v = String(raw)
    .replace(/\r/g, '')
    .trim()
    .toLowerCase()
    .replace(/[\s-]+/g, '_');
  return synonyms[v] ?? v;
}

export function normalizeVerdictString(raw) {
  return normalizeToken(raw, VERDICT_SYNONYMS);
}
export function normalizeTransitionString(raw) {
  return normalizeToken(raw, TRANSITION_SYNONYMS);
}

// AC label = first present of id | criterion | criterion_id | label.
// Text = first present of description | summary | text.
// The trailing `label`/`text` fallbacks make normalizeIssue idempotent: an
// already-normalized issue (which carries `label`/`text` but none of the raw
// producer field names) round-trips unchanged instead of collapsing to the
// "?" / "no description" absent-fallbacks. This is what lets IMP-06 hoist
// normalization to the ingestion boundary safely — a stray second application
// (partial revert, a re-introduced per-item call) can no longer mangle issues.
// Byte-identical for the three raw producer shapes (their earlier fields win).
export function normalizeIssue(issue) {
  const src = issue ?? {};
  return {
    label: firstPresent(src.id, src.criterion, src.criterion_id, src.label) ?? '?',
    severity: src.severity ?? 'major',
    text: firstPresent(src.description, src.summary, src.text) ?? 'no description',
    fix_hint: src.fix_hint,
  };
}

// reasoning is an array of {check, decision, basis} in every current
// producer. Also tolerant of a legacy object-keyed shape
// ({ il1_compliance: "...", layer_enforcement: "...", ... }) in case any
// consumer/test fixture still emits that form.
export function normalizeReasoning(reasoning) {
  if (Array.isArray(reasoning)) {
    return reasoning.map((entry) => ({
      check: entry?.check,
      decision: entry?.decision,
      basis: entry?.basis,
    }));
  }

  if (reasoning && typeof reasoning === 'object') {
    return Object.entries(reasoning).map(([check, basis]) => ({
      check,
      decision: undefined,
      basis,
    }));
  }

  return [];
}

// Normalizes a full verdict object: issues + reasoning get shape-mapped,
// criteria_results and us_id are passed through untouched (present when the
// producer carries them, undefined/empty otherwise — never synthesized).
export function normalizeVerdict(verdict) {
  const src = verdict ?? {};
  return {
    ...src,
    us_id: src.us_id,
    verdict: normalizeVerdictString(src.verdict),
    recommended_state_transition: normalizeTransitionString(src.recommended_state_transition),
    issues: (src.issues ?? []).map(normalizeIssue),
    reasoning: normalizeReasoning(src.reasoning),
    criteria_results: src.criteria_results ?? [],
  };
}
