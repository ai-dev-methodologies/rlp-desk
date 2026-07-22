// vision-adopt §2/§3: the closed reason_category enum + the category-level
// (recoverable, suggested_action) defaults for the Node leader. These are pinned
// against the zsh leader (_blocked_recoverable_for_category /
// _blocked_action_for_category) by tests/fixtures/recoverable-parity/matrix.json.
//
// reason_category is PRIMARY — wrappers branch on it for recovery decisions.
// Within a category the recoverable DEFAULT is CONSTANT: for every RECOGNIZED
// block source, _classifyBlock's per-source recoverable equals the category
// default here, and the parity test enforces both directions.
//
// ONE deliberate exception: _classifyBlock's `default:` branch (an UNRECOGNIZED
// source) fails safe with reason_category=metric_failure + recoverable=FALSE —
// intentionally stricter than metric_failure's category default (true), because
// an unclassified block must never be auto-retried. Callsites may also override
// the emitted recoverable/suggested_action per block (e.g. the transient
// infra_failure callsites). So a WRAPPER MUST read the emitted `recoverable`/
// `suggested_action` fields, never re-derive them from reason_category alone.
// The unknown-source exception is pinned by tests/fixtures/recoverable-parity/
// matrix.json (`unknown_source`).
//
// §2 reconciliation (fail-fast wins — owner ruling): infra_failure is
// recoverable=FALSE. Every infra_failure SOURCE (pane exit / timeout /
// prompt-block / git-unverifiable / leader-exit) needs human investigation, not
// a blind auto-retry. The genuinely-transient infra callsites (API backoff
// exhaustion, model-capacity stall, lifecycle restart) opt back into
// recoverable=true + restart at the callsite; they are the documented exception,
// not the category default.
//
// §3: external_fact — the campaign halted on a contract gap that needs an
// owner-supplied out-of-repo fact. recoverable=false (no model can synthesize
// the fact); suggested_action=retry_after_fix (update the contract with the
// fact, then relaunch). Halt semantics are unchanged — this only makes the halt
// machine-legible; there is no runtime owner-interaction channel.

export const REASON_CATEGORIES = Object.freeze([
  'metric_failure',
  'cross_us_dep',
  'contract_violation',
  'context_limit',
  'infra_failure',
  'repeat_axis',
  'mission_abort',
  'external_fact',
]);

export const CATEGORY_RECOVERABLE = Object.freeze({
  metric_failure: true,
  cross_us_dep: true,
  contract_violation: true,
  context_limit: false,
  infra_failure: false,
  repeat_axis: false,
  mission_abort: false,
  external_fact: false,
});

// Category-level default action. Node's _classifyBlock emits richer per-source
// actions for infra_failure (investigate_pane_logs / investigate_git_state /
// manual_prompt_response / …); this generic 'investigate' is the category
// default the zsh leader uses where it cannot distinguish the source.
export const CATEGORY_ACTION = Object.freeze({
  metric_failure: 'retry_after_fix',
  cross_us_dep: 'retry_after_fix',
  contract_violation: 'retry_after_fix',
  context_limit: 'next_mission_chain',
  infra_failure: 'investigate',
  repeat_axis: 'next_mission_chain',
  mission_abort: 'terminal_alert',
  external_fact: 'retry_after_fix',
});

export function isReasonCategory(value) {
  return REASON_CATEGORIES.includes(value);
}

export function categoryRecoverable(category) {
  return CATEGORY_RECOVERABLE[category] ?? false;
}

export function categoryAction(category) {
  return CATEGORY_ACTION[category] ?? 'terminal_alert';
}
