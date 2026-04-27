import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildClaudeCmd } from '../../src/node/cli/command-builder.mjs';
import { OPUS_1M_BETA, isOpusModel } from '../../src/node/constants.mjs';

// G8 — v5.7 §4.9: Opus 1M context auto-enable.

test('OPUS_1M_BETA is the documented header literal', () => {
  assert.equal(OPUS_1M_BETA, 'context-1m-2025-08-07');
});

test('isOpusModel: opus → true', () => {
  assert.equal(isOpusModel('opus'), true);
});

test('isOpusModel: claude-opus-4-7 → true', () => {
  assert.equal(isOpusModel('claude-opus-4-7'), true);
});

test('isOpusModel: claude-opus-4-7[1m] (Bug 1 form) → true', () => {
  assert.equal(isOpusModel('claude-opus-4-7[1m]'), true);
});

test('isOpusModel: sonnet → false', () => {
  assert.equal(isOpusModel('sonnet'), false);
});

test('isOpusModel: haiku → false', () => {
  assert.equal(isOpusModel('haiku'), false);
});

test('isOpusModel: empty → false', () => {
  assert.equal(isOpusModel(''), false);
  assert.equal(isOpusModel(null), false);
  assert.equal(isOpusModel(undefined), false);
});

test('buildClaudeCmd opus: prepends ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'opus');
  assert.match(cmd, /ANTHROPIC_BETA='context-1m-2025-08-07'/);
  assert.match(cmd, /--model 'opus'/);
});

test('buildClaudeCmd sonnet: omits ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'sonnet');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
});

test('buildClaudeCmd haiku: omits ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'haiku');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
});

test('buildClaudeCmd claude-opus-4-7[1m]: prepends ANTHROPIC_BETA AND survives Bug 1 quoting', () => {
  const cmd = buildClaudeCmd('tui', 'claude-opus-4-7[1m]');
  assert.match(cmd, /ANTHROPIC_BETA='context-1m-2025-08-07'/);
  assert.match(cmd, /--model 'claude-opus-4-7\[1m\]'/);
});

test('buildClaudeCmd opus with effort: ANTHROPIC_BETA precedes binary', () => {
  const cmd = buildClaudeCmd('tui', 'opus', { effort: 'high' });
  // Order: DISABLE_OMC=1 ANTHROPIC_BETA=... claude --model 'opus' ...
  assert.match(cmd, /^DISABLE_OMC=1 ANTHROPIC_BETA='context-1m-2025-08-07' claude /);
  assert.match(cmd, /--effort 'high'$/);
});
