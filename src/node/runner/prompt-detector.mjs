// v0.13.0: early-detect Claude Code permission prompts in worker stdout.
// Pre-v0.13.0 the leader only noticed via 30-min pollForSignal timeout, which
// hid the failure category. Now we surface BLOCKED with category=permission_prompt
// within seconds so wrappers can react.

const SIGNATURES = [
  /Do you want to /,
  /\u276F\s*1\.\s*Yes/,
  /allow Claude to edit its own settings/,
  /1\.\s*Yes(?:,?\s*and allow Claude)/,
];

export function detectPermissionPrompt(chunk) {
  if (typeof chunk !== 'string' || chunk.length === 0) {
    return false;
  }

  for (const pattern of SIGNATURES) {
    if (pattern.test(chunk)) {
      return true;
    }
  }
  return false;
}

export const PERMISSION_PROMPT_CATEGORY = 'permission_prompt';

export function buildPermissionPromptBlocked(slug, iteration, snippet) {
  const trimmedSnippet = typeof snippet === 'string'
    ? snippet.split(/\r?\n/).slice(0, 5).join('\n').slice(0, 600)
    : '';
  return {
    slug,
    iteration: iteration ?? 0,
    reason_category: 'infra_failure',
    failure_category: PERMISSION_PROMPT_CATEGORY,
    recoverable: false,
    suggested_action: 'switch_worker_to_codex_or_use_agent_mode',
    evidence_snippet: trimmedSnippet,
  };
}
