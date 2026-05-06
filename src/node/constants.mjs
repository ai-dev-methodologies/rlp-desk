// Shared runtime constants. Single-source for cross-module values.

// Anthropic Claude API beta header for the 1M-token context window. Injected
// only when the user explicitly opts in via the '[1m]' suffix on the model
// id — see wantsOneMillionContext() below.
//
// Docs: https://docs.anthropic.com/en/docs/build-with-claude/context-windows
// (search "1M context") — header rotates with each beta phase.
export const ONE_MILLION_BETA = 'context-1m-2025-08-07';

// v0.14.6: 1M context is opt-in only via the explicit '[1m]' suffix on the
// model id. Previously rlp-desk auto-injected ANTHROPIC_BETA for any opus
// model; in practice that produced surprising results (opus alias still
// reported a 200K window in real CLI calls, and sonnet[1m] requires a
// separate "Extra usage" entitlement). New rule: user is the source of
// truth. Type the suffix to opt in; otherwise both opus and sonnet run at
// the standard 200K context.
export function wantsOneMillionContext(model) {
  if (!model) return false;
  return String(model).toLowerCase().endsWith('[1m]');
}
