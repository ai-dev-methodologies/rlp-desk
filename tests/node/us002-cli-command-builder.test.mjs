import test from 'node:test';
import assert from 'node:assert/strict';

test('US-002 AC2.1 happy: buildClaudeCmd tui includes claude flags and effort', async () => {
  const { buildClaudeCmd } = await import('../../src/node/cli/command-builder.mjs');

  // v0.14.6: opus alias defaults to 200K (no ANTHROPIC_BETA). Use the
  // explicit '[1m]' suffix to opt in to 1M — see test-opus-1m-context.mjs.
  const command = buildClaudeCmd('tui', 'opus', { effort: 'max' });

  // v5.7 §4.12 (Bug 1): model and effort values are shellQuoted (POSIX
  // single-quote wrap) to defend against bracketed model ids like
  // 'claude-opus-4-7[1m]' that zsh would otherwise expand as a glob.
  assert.ok(command.startsWith('DISABLE_OMC=1'));
  assert.match(command, /^DISABLE_OMC=1 claude /);
  assert.doesNotMatch(command, /ANTHROPIC_BETA/);
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

  const command = buildCodexCmd('tui', 'gpt-5.6-sol', { reasoning: 'high' });

  assert.match(
    command,
    // US-001: `--disable hooks` joins `--disable plugins` (F1.19 native-hook
    // isolation). Node emits it unconditionally as dead-code parity.
    /^codex -m 'gpt-5\.6-sol' -c 'model_reasoning_effort="high"' --disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox$/,
  );
});

test('US-002 AC2.2 boundary: buildCodexCmd omits reasoning when it is undefined', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildCodexCmd('tui', 'gpt-5.6-sol', {});

  assert.equal(
    command,
    // US-001: see the AC2.2 happy case above.
    "codex -m 'gpt-5.6-sol' --disable plugins --disable hooks --dangerously-bypass-approvals-and-sandbox",
  );
});

test('US-002 GAP-2: buildCodexCmd single-quotes model + reasoning (shell-injection defense)', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  const command = buildCodexCmd('tui', 'gpt-5.6-sol', { reasoning: 'high"; rm -rf / #' });

  // model + reasoning are emitted as single-quoted args, at parity with buildClaudeCmd.
  assert.match(command, /-m 'gpt-5\.6-sol'/);
  assert.match(command, /-c 'model_reasoning_effort=/);
  // After stripping single-quoted spans, none of the injected shell syntax survives.
  const bare = command.replace(/'(?:[^']|'\\'')*'/g, '');
  assert.ok(!/;|\brm\b/.test(bare), `reasoning injection escaped single-quoting: ${bare}`);
});

test('US-002 AC2.2 negative: buildCodexCmd rejects unsupported modes', async () => {
  const { buildCodexCmd } = await import('../../src/node/cli/command-builder.mjs');

  assert.throws(() => buildCodexCmd('print', 'gpt-5.6-sol', { reasoning: 'high' }), /unknown mode/i);
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

test('parseModelFlag: inherited object keys are not treated as aliases (constructor:max)', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');
  // A plain-object alias table would resolve CODEX_MODEL_ALIASES['constructor'] to
  // Object.prototype.constructor (truthy) and emit a function as the model.
  assert.deepEqual(parseModelFlag('constructor:max'), {
    engine: 'codex',
    model: 'constructor',
    reasoning: 'max',
  });
});

// Full versioned claude ids WITH effort route to the claude engine (parity with
// the short opus:max alias above). Effort is a separate axis kept verbatim.
test('parseModelFlag returns claude engine and effort for claude-opus-4-8:high', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('claude-opus-4-8:high', 'verifier'), {
    engine: 'claude',
    model: 'claude-opus-4-8',
    effort: 'high',
  });
});

test('parseModelFlag returns claude engine and effort for claude-fable-5:max', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('claude-fable-5:max', 'final-verifier'), {
    engine: 'claude',
    model: 'claude-fable-5',
    effort: 'max',
  });
});

// claude-fable-5-1: same claude-* prefix match as claude-fable-5, but with a
// SECOND hyphenated numeric segment. isClaudeModelName uses a plain
// startsWith('claude-') check (not a regex tied to one numeric segment), so
// this must resolve identically to the claude-fable-5 case above.
test('parseModelFlag returns claude engine and effort for claude-fable-5-1:max', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('claude-fable-5-1:max', 'final-verifier'), {
    engine: 'claude',
    model: 'claude-fable-5-1',
    effort: 'max',
  });
});

// gpt-6-astra: new codex model family, typed verbatim (full slug) must still
// route to the codex engine with reasoning preserved.
test('parseModelFlag returns codex engine and reasoning for gpt-6-astra:high', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('gpt-6-astra:high', 'worker'), {
    engine: 'codex',
    model: 'gpt-6-astra',
    reasoning: 'high',
  });
});

// astra alias (CODEX_MODEL_ALIASES, same convention as sol/terra/luna) must
// expand to the full gpt-6-astra slug.
test('parseModelFlag expands the astra alias to gpt-6-astra', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('astra:high', 'worker'), {
    engine: 'codex',
    model: 'gpt-6-astra',
    reasoning: 'high',
  });
});

// Bracket+colon combo: the 1M context suffix must survive alongside effort. The
// model part keeps the [1m] verbatim (buildClaudeCmd reads it for the 1M header).
test('parseModelFlag keeps the [1m] suffix for claude-opus-4-8[1m]:high', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('claude-opus-4-8[1m]:high', 'worker'), {
    engine: 'claude',
    model: 'claude-opus-4-8[1m]',
    effort: 'high',
  });
});

// Bare `claude` (no version, no colon) stays the claude engine.
test('parseModelFlag treats bare claude as the claude engine', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('claude', 'worker'), {
    engine: 'claude',
    model: 'claude',
  });
});

// fable: bare short alias `claude --help` documents alongside opus/sonnet —
// a REAL bug found and fixed in the Fable 5.1 wave: CLAUDE_MODELS previously
// only had haiku/sonnet/opus, so `--worker-model fable` was misclassified as
// codex (only the versioned `claude-fable-5-1` id worked, via startsWith).
test('parseModelFlag treats bare fable as the claude engine', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('fable', 'worker'), {
    engine: 'claude',
    model: 'fable',
  });
});

test('parseModelFlag returns claude engine and effort for fable:max', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('fable:max', 'final-verifier'), {
    engine: 'claude',
    model: 'fable',
    effort: 'max',
  });
});

test('isClaudeEngine returns true for bare fable and fable:max', async () => {
  const { isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');

  assert.equal(isClaudeEngine('fable'), true);
  assert.equal(isClaudeEngine('fable:max'), true);
});

// SV-gate finding, same class as the bare-fable bug above: a bare (no-colon)
// codex alias — astra/sol/terra/luna/spark, written without a `:reasoning`
// suffix — was unconditionally classified as engine:'claude' by
// parseModelFlag's colonCount===0 branch, disagreeing with isClaudeEngine
// (which already checked isClaudeModelName on the bare name and correctly
// said "not claude" for all five). Fixed by checking the shared
// CODEX_MODEL_ALIASES table before defaulting to claude.
for (const [aliasName, fullSlug] of [
  ['spark', 'gpt-5.3-codex-spark'],
  ['sol', 'gpt-5.6-sol'],
  ['terra', 'gpt-5.6-terra'],
  ['luna', 'gpt-5.6-luna'],
  ['astra', 'gpt-6-astra'],
]) {
  test(`parseModelFlag treats bare ${aliasName} (no colon) as the codex engine, matching isClaudeEngine`, async () => {
    const { parseModelFlag, isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');

    assert.deepEqual(parseModelFlag(aliasName, 'worker'), {
      engine: 'codex',
      model: fullSlug,
    });
    // Parity: isClaudeEngine already correctly said "not claude" for the
    // bare alias before this fix — assert the two entry points agree.
    assert.equal(isClaudeEngine(aliasName), false);
  });
}

// Regression: a bare name that is genuinely not a known codex alias (and not
// a claude id) still defaults to the claude engine — the fix narrows the
// bare-branch exception to the five known codex aliases, it does not flip
// the documented "model (no colon) = claude engine" default for every name.
test('parseModelFlag still defaults an unrecognized bare name to the claude engine', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('some-unknown-model', 'worker'), {
    engine: 'claude',
    model: 'some-unknown-model',
  });
});

// Team-lead review follow-up: fixing only the five known codex ALIASES and
// leaving a bare, real codex model id (e.g. "gpt-5.6-sol", no colon) misclassified
// as claude made the rule unguessable — five names fixed, actual ids still
// broken, disagreeing with isClaudeEngine('gpt-5.6-sol') which already correctly
// says "not claude". Any bare gpt-* id now routes to codex directly (no
// alias table lookup needed, it's already the real slug).
test('parseModelFlag treats a bare gpt-* id (no colon) as the codex engine, matching isClaudeEngine', async () => {
  const { parseModelFlag, isClaudeEngine } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('gpt-5.6-sol', 'worker'), {
    engine: 'codex',
    model: 'gpt-5.6-sol',
  });
  assert.equal(isClaudeEngine('gpt-5.6-sol'), false);
});

test('parseModelFlag treats a bare gpt-6-astra (no colon) as the codex engine', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('gpt-6-astra', 'worker'), {
    engine: 'codex',
    model: 'gpt-6-astra',
  });
});

test('parseModelFlag treats a bare gpt-5.3-codex-spark (the spark alias\'s full slug, no colon) as the codex engine', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');

  assert.deepEqual(parseModelFlag('gpt-5.3-codex-spark', 'worker'), {
    engine: 'codex',
    model: 'gpt-5.3-codex-spark',
  });
});

// codex 0.144 / GPT-5.6 aliases — mirror of the zsh parse sites (spark precedent).
test('parseModelFlag maps sol:max to gpt-5.6-sol with max reasoning', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');
  assert.deepEqual(parseModelFlag('sol:max'), {
    engine: 'codex',
    model: 'gpt-5.6-sol',
    reasoning: 'max',
  });
});

test('parseModelFlag maps terra:ultra and luna:high to their full slugs', async () => {
  const { parseModelFlag } = await import('../../src/node/cli/command-builder.mjs');
  assert.deepEqual(parseModelFlag('terra:ultra'), {
    engine: 'codex',
    model: 'gpt-5.6-terra',
    reasoning: 'ultra',
  });
  assert.deepEqual(parseModelFlag('luna:high'), {
    engine: 'codex',
    model: 'gpt-5.6-luna',
    reasoning: 'high',
  });
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

  assert.deepEqual(parseModelFlag('gpt-5.6-sol:'), {
    engine: 'codex',
    model: 'gpt-5.6-sol',
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
  assert.equal(isClaudeEngine('gpt-5.6-sol:high'), false);
  assert.equal(isClaudeEngine('gpt-5.6-sol:xhigh'), false);
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
