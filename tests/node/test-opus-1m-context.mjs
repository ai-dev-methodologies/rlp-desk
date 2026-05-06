import { test } from 'node:test';
import assert from 'node:assert/strict';

import { buildClaudeCmd } from '../../src/node/cli/command-builder.mjs';
import { ONE_MILLION_BETA, wantsOneMillionContext } from '../../src/node/constants.mjs';

// v0.14.6: 1M context window is opt-in only via the explicit '[1m]' suffix
// on the model id. Both opus and sonnet without the suffix run at 200K.
// File name kept as test-opus-1m-context.mjs for git history continuity;
// content replaced to match the new explicit-opt-in policy.

test('ONE_MILLION_BETA is the documented header literal', () => {
  assert.equal(ONE_MILLION_BETA, 'context-1m-2025-08-07');
});

test('wantsOneMillionContext: opus alias → false (no [1m] suffix)', () => {
  assert.equal(wantsOneMillionContext('opus'), false);
});

test('wantsOneMillionContext: sonnet alias → false', () => {
  assert.equal(wantsOneMillionContext('sonnet'), false);
});

test('wantsOneMillionContext: haiku alias → false', () => {
  assert.equal(wantsOneMillionContext('haiku'), false);
});

test('wantsOneMillionContext: claude-opus-4-7 (no suffix) → false', () => {
  assert.equal(wantsOneMillionContext('claude-opus-4-7'), false);
});

test('wantsOneMillionContext: claude-opus-4-7[1m] → true', () => {
  assert.equal(wantsOneMillionContext('claude-opus-4-7[1m]'), true);
});

test('wantsOneMillionContext: claude-sonnet-4-6[1m] → true', () => {
  assert.equal(wantsOneMillionContext('claude-sonnet-4-6[1m]'), true);
});

test('wantsOneMillionContext: case-insensitive match on [1M] / [1m]', () => {
  assert.equal(wantsOneMillionContext('claude-opus-4-7[1M]'), true);
  assert.equal(wantsOneMillionContext('CLAUDE-OPUS-4-7[1m]'), true);
});

test('wantsOneMillionContext: empty / null / undefined → false', () => {
  assert.equal(wantsOneMillionContext(''), false);
  assert.equal(wantsOneMillionContext(null), false);
  assert.equal(wantsOneMillionContext(undefined), false);
});

test('buildClaudeCmd opus alias: omits ANTHROPIC_BETA (200K default)', () => {
  const cmd = buildClaudeCmd('tui', 'opus');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
  assert.match(cmd, /--model 'opus'/);
});

test('buildClaudeCmd sonnet alias: omits ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'sonnet');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
});

test('buildClaudeCmd haiku alias: omits ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'haiku');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
});

test('buildClaudeCmd claude-opus-4-7 (no suffix): omits ANTHROPIC_BETA', () => {
  const cmd = buildClaudeCmd('tui', 'claude-opus-4-7');
  assert.doesNotMatch(cmd, /ANTHROPIC_BETA/);
});

test('buildClaudeCmd claude-opus-4-7[1m]: prepends ANTHROPIC_BETA AND survives Bug 1 quoting', () => {
  const cmd = buildClaudeCmd('tui', 'claude-opus-4-7[1m]');
  assert.match(cmd, /ANTHROPIC_BETA='context-1m-2025-08-07'/);
  assert.match(cmd, /--model 'claude-opus-4-7\[1m\]'/);
});

test('buildClaudeCmd claude-sonnet-4-6[1m]: prepends ANTHROPIC_BETA (entitlement responsibility on user)', () => {
  const cmd = buildClaudeCmd('tui', 'claude-sonnet-4-6[1m]');
  assert.match(cmd, /ANTHROPIC_BETA='context-1m-2025-08-07'/);
  assert.match(cmd, /--model 'claude-sonnet-4-6\[1m\]'/);
});

test('buildClaudeCmd claude-opus-4-7[1m] with effort: ANTHROPIC_BETA precedes binary', () => {
  const cmd = buildClaudeCmd('tui', 'claude-opus-4-7[1m]', { effort: 'high' });
  assert.match(cmd, /^DISABLE_OMC=1 ANTHROPIC_BETA='context-1m-2025-08-07' claude /);
  assert.match(cmd, /--effort 'high'$/);
});

test('buildClaudeCmd opus alias with effort: no ANTHROPIC_BETA, effort still applied', () => {
  const cmd = buildClaudeCmd('tui', 'opus', { effort: 'high' });
  assert.match(cmd, /^DISABLE_OMC=1 claude /);
  assert.match(cmd, /--effort 'high'$/);
});
