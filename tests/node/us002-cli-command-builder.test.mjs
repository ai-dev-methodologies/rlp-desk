import test from 'node:test';
import assert from 'node:assert/strict';

test('US-002 AC2.1 happy: buildClaudeCmd tui includes claude flags and effort', async () => {
  const { buildClaudeCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildClaudeCmd('tui', 'opus', { effort: 'max' });

  // v5.7 §4.12 (Bug 1): model and effort values are shellQuoted (POSIX
  // single-quote wrap) to defend against bracketed model ids like
  // 'claude-opus-4-7[1m]' that zsh would otherwise expand as a glob.
  // v5.7 §4.9 (Opus 1M): ANTHROPIC_BETA env is auto-prepended for Opus.
  assert.ok(command.startsWith('DISABLE_OMC=1'));
  assert.match(command, /^DISABLE_OMC=1 ANTHROPIC_BETA='context-1m-2025-08-07' claude /);
  assert.match(
    command,
    /--model 'opus' --mcp-config '\{"mcpServers":\{\}\}' --strict-mcp-config --dangerously-skip-permissions --effort 'max'$/,
  );
});

test('US-002 AC2.1 boundary: buildClaudeCmd omits effort when it is empty', async () => {
  const { buildClaudeCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildClaudeCmd('tui', 'sonnet', { effort: '' });

  assert.match(
    command,
    /^DISABLE_OMC=1 claude --model 'sonnet' --mcp-config '\{"mcpServers":\{\}\}' --strict-mcp-config --dangerously-skip-permissions$/,
  );
  assert.doesNotMatch(command, /--effort/);
});

test('US-002 AC2.1 negative: buildClaudeCmd rejects unsupported modes', async () => {
  const { buildClaudeCmd } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => buildClaudeCmd('print', 'opus', { effort: 'max' }), /unknown mode/i);
});

test('US-002 AC2.2 happy: buildCodexCmd tui includes codex model and reasoning flags', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildCodexCmd('tui', 'gpt-5.5', { reasoning: 'high' });

  assert.match(
    command,
    /^codex -m gpt-5\.5 -c model_reasoning_effort="high" --disable plugins --dangerously-bypass-approvals-and-sandbox$/,
  );
});

test('US-002 AC2.2 boundary: buildCodexCmd omits reasoning when it is undefined', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildCodexCmd('tui', 'gpt-5.5', {});

  assert.equal(
    command,
    'codex -m gpt-5.5 --disable plugins --dangerously-bypass-approvals-and-sandbox',
  );
});

test('US-002 AC2.2 negative: buildCodexCmd rejects unsupported modes', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => buildCodexCmd('print', 'gpt-5.5', { reasoning: 'high' }), /unknown mode/i);
});

test('US-002 AC2.3 happy: parseModelFlag returns claude engine and effort for opus:max', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('opus:max', 'worker'), {
    engine: 'claude',
    model: 'opus',
    effort: 'max',
  });
});

test('US-002 AC2.3 boundary: parseModelFlag keeps an empty effort for claude model values', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('sonnet:', 'worker'), {
    engine: 'claude',
    model: 'sonnet',
    effort: '',
  });
});

test('US-002 AC2.3 negative: parseModelFlag rejects an empty model before the colon', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => parseModelFlag(':max', 'worker'), /model is required/i);
});

test('US-002 AC2.4 happy: parseModelFlag maps spark:medium to codex spark defaults', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('spark:medium'), {
    engine: 'codex',
    model: 'gpt-5.3-codex-spark',
    reasoning: 'medium',
  });
});

test('US-002 AC2.4 boundary: parseModelFlag keeps an empty reasoning for codex values', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('gpt-5.5:'), {
    engine: 'codex',
    model: 'gpt-5.5',
    reasoning: '',
  });
});

test('US-002 AC2.4 negative: parseModelFlag rejects an empty codex model alias', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => parseModelFlag(':medium'), /model is required/i);
});

test('US-002 AC2.5 happy: parseModelFlag rejects values with more than one colon', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => parseModelFlag('a:b:c'), /invalid format/i);
});

test('US-002 AC2.5 boundary: parseModelFlag rejects an empty triple-colon format', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => parseModelFlag('::'), /invalid format/i);
});

test('US-002 AC2.5 negative: parseModelFlag rejects extra segments for spark aliases', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => parseModelFlag('spark:medium:extra'), /invalid format/i);
});

// v0.13.0 US-001: isClaudeEngine helper for tmux+claude warning + observability
test('isClaudeEngine returns true for bare claude model names', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');
  assert.equal(isClaudeEngine('haiku'), true);
  assert.equal(isClaudeEngine('sonnet'), true);
  assert.equal(isClaudeEngine('opus'), true);
});

test('isClaudeEngine returns true for claude- prefixed model ids', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');
  assert.equal(isClaudeEngine('claude-opus-4-7'), true);
  assert.equal(isClaudeEngine('claude-sonnet-4-6'), true);
});

test('isClaudeEngine honors model:effort syntax with claude prefix', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');
  assert.equal(isClaudeEngine('haiku:max'), true);
  assert.equal(isClaudeEngine('opus:high'), true);
});

test('isClaudeEngine returns false for codex models', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');
  assert.equal(isClaudeEngine('gpt-5.5:high'), false);
  assert.equal(isClaudeEngine('gpt-5.5:xhigh'), false);
  assert.equal(isClaudeEngine('spark'), false);
  assert.equal(isClaudeEngine('spark:medium'), false);
  assert.equal(isClaudeEngine('gpt-5.3-codex-spark:high'), false);
});

test('isClaudeEngine returns false for unknown/empty input', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');
  assert.equal(isClaudeEngine(''), false);
  assert.equal(isClaudeEngine(undefined), false);
  assert.equal(isClaudeEngine(null), false);
});
