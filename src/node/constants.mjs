// Shared runtime constants. Single-source for cross-module values.

// Anthropic Claude API beta header that activates the 1M-token context window
// for Opus models. Auto-prepended to every claude CLI invocation that uses
// --model opus so long campaigns no longer silently truncate at 200K.
//
// Docs: https://docs.anthropic.com/en/docs/build-with-claude/context-windows
// (search "1M context") — header rotates with each beta phase.
export const OPUS_1M_BETA = 'context-1m-2025-08-07';

// Model id that triggers Opus 1M auto-enable. Plain string match against the
// --model value (post-shellQuote stripping). Bracketed form
// 'claude-opus-4-7[1m]' is also Opus and benefits from this; pattern match
// covers both.
export function isOpusModel(model) {
  if (!model) return false;
  const m = String(model).toLowerCase();
  return m === 'opus' || m.startsWith('claude-opus-');
}
