import { test } from 'node:test';
import assert from 'node:assert/strict';
import { shellQuote } from '../../src/node/util/shell-quote.mjs';

// G11 — Bug 1 (v5.7 §4.12): defensive shell-quoting for model ids and dynamic args.
// Verifies POSIX single-quote escape contract under shell-special characters.

test('shellQuote: simple alphanumeric', () => {
  assert.equal(shellQuote('opus'), "'opus'");
});

test('shellQuote: bracketed model id (Bug 1 repro)', () => {
  assert.equal(shellQuote('claude-opus-4-7[1m]'), "'claude-opus-4-7[1m]'");
});

test('shellQuote: glob asterisk', () => {
  assert.equal(shellQuote('claude-opus-4-7*test'), "'claude-opus-4-7*test'");
});

test('shellQuote: spaces preserved', () => {
  assert.equal(shellQuote('model with spaces'), "'model with spaces'");
});

test('shellQuote: single quote escape per POSIX', () => {
  // The contract: 'foo'\\''bar' — close, escaped quote, reopen.
  assert.equal(shellQuote("model'quote"), "'model'\\''quote'");
});

test('shellQuote: dollar and backtick remain literal inside single quotes', () => {
  assert.equal(shellQuote('weird$model`bt'), "'weird$model`bt'");
});

test('shellQuote: numeric/non-string coerced via String()', () => {
  assert.equal(shellQuote(123), "'123'");
});

test('shellQuote: empty string', () => {
  assert.equal(shellQuote(''), "''");
});

test('shellQuote: round-trip through sh -c eval (POSIX shell parser)', async () => {
  const { execFile } = await import('node:child_process');
  const { promisify } = await import('node:util');
  const run = promisify(execFile);
  const inputs = [
    'opus',
    'claude-opus-4-7[1m]',
    'claude-opus-4-7*test',
    'model with spaces',
    "model'quote",
    'weird$model`bt',
  ];
  for (const input of inputs) {
    const cmd = `printf %s ${shellQuote(input)}`;
    const { stdout } = await run('/bin/sh', ['-c', cmd]);
    assert.equal(stdout, input, `round-trip failed for ${JSON.stringify(input)}`);
  }
});
