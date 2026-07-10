import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  CODEX_IDLE_RE,
  isCodexIdleUi,
} from '../../src/node/runner/prompt-dismisser.mjs';

// v0.14.1: codex post-work idle UI detection. Bug Report #3 (BOS 2026-05-04)
// reported that the codex CLI's "─ Worked for 5m 36s ──" / "Context X% left"
// idle banner was being misclassified as "frozen" by the byte-stasis watcher.
// These tests freeze the wire-level fixtures so a future regex change cannot
// silently break the recognizer.

test('isCodexIdleUi: matches the BOS Bug #3 pane capture verbatim', () => {
  const paneText = `─ Worked for 5m 36s ──────────────────────────────
› Summarize recent commits
gpt-5.5 high · feature/phase-1-bc-implementation · Context 66% left · 1.85M in · 13…`;
  assert.equal(isCodexIdleUi(paneText), true);
});

test('isCodexIdleUi: matches "Worked for 30s" short-duration variant', () => {
  const paneText = '─ Worked for 0m 30s ──';
  assert.equal(isCodexIdleUi(paneText), true);
});

test('isCodexIdleUi: matches the "Context X% left" status line alone', () => {
  const paneText = 'gpt-5.5 high · main · Context 87% left';
  assert.equal(isCodexIdleUi(paneText), true);
});

test('isCodexIdleUi: matches "Context X%left" without the space (status truncation)', () => {
  // Some terminals trim a trailing space when the bar wraps; the regex tolerates
  // the "X%left" form so a narrow pane does not break detection.
  const paneText = 'Context 99%left';
  assert.equal(isCodexIdleUi(paneText), true);
});

test('isCodexIdleUi: returns false for codex working state ("worked" word elsewhere)', () => {
  const paneText = 'I worked through the spec and now I am running tests';
  assert.equal(isCodexIdleUi(paneText), false);
});

test('isCodexIdleUi: returns false for empty / nullish input', () => {
  assert.equal(isCodexIdleUi(''), false);
  assert.equal(isCodexIdleUi(null), false);
  assert.equal(isCodexIdleUi(undefined), false);
});

test('isCodexIdleUi: returns false for claude-style permission prompt', () => {
  const paneText = `Do you want to create file.json?
  (y/n)`;
  assert.equal(isCodexIdleUi(paneText), false);
});

test('CODEX_IDLE_RE: exported regex is reusable + immutable contract', () => {
  // Regression guard: callers (e.g. signal-poller) may import the constant
  // directly. Freeze the alternation so accidental edits surface here.
  assert.ok(CODEX_IDLE_RE instanceof RegExp);
  assert.ok(CODEX_IDLE_RE.source.includes('Worked for'));
  assert.ok(CODEX_IDLE_RE.source.includes('Context'));
});

// v0.14.2 — Bug Report #4 (BOS 2026-05-05) pattern relaxations. The
// v0.14.1 strict regex required the surrounding horizontal rule to match;
// tmux capture truncation occasionally dropped those rules so the pattern
// missed in production. These cases freeze the relaxed alternation.

test('isCodexIdleUi v0.14.2: matches "Worked for" without horizontal-rule wrapping', () => {
  assert.equal(isCodexIdleUi('Worked for 5m 14s'), true);
});

test('isCodexIdleUi v0.14.2: matches "Context X%left" without space (wrapped pane)', () => {
  assert.equal(isCodexIdleUi('Context 57%left'), true);
});

test('isCodexIdleUi v0.14.2: matches codex model+branch line ("gpt-5.5 high · branch")', () => {
  assert.equal(
    isCodexIdleUi('gpt-5.5 high · feature/phase-1-bc-implementation · Context 57% left'),
    true,
  );
});

test('isCodexIdleUi v0.14.2: matches codex default suggestion "Improve documentation in @"', () => {
  assert.equal(isCodexIdleUi('› Improve documentation in @bos/db'), true);
});

test('isCodexIdleUi v0.14.2: matches codex default suggestion "Summarize recent commits"', () => {
  assert.equal(isCodexIdleUi('› Summarize recent commits'), true);
});

test('isCodexIdleUi v0.14.2: matches codex default suggestion "Explain this code"', () => {
  assert.equal(isCodexIdleUi('› Explain this code'), true);
});

test('isCodexIdleUi v0.14.2: still rejects "worked through" prose (no false positive)', () => {
  assert.equal(isCodexIdleUi('I worked through the spec and ran tests'), false);
});

// codex 0.144 / GPT-5.6: suffixed model slugs (gpt-5.6-sol|terra|luna) and the
// new max|ultra reasoning efforts appear on the idle status line. The pre-5.6
// pattern (bare gpt-X.Y + low..xhigh) matched neither — mirror of the zsh
// is_codex_idle_ui cases in tests/test_codex_idle_no_progress.sh.
test('isCodexIdleUi: gpt-5.6-sol max · main (suffixed slug + max effort)', () => {
  assert.equal(isCodexIdleUi('gpt-5.6-sol max · main'), true);
});

test('isCodexIdleUi: gpt-5.6-terra ultra · feature/foo', () => {
  assert.equal(isCodexIdleUi('gpt-5.6-terra ultra · feature/foo'), true);
});

test('isCodexIdleUi: gpt-5.3-codex-spark high · main (suffixed slug, old effort)', () => {
  assert.equal(isCodexIdleUi('gpt-5.3-codex-spark high · main'), true);
});

test('isCodexIdleUi: model name in prose without effort·branch shape stays false', () => {
  assert.equal(isCodexIdleUi('gpt-5.6-sol finished reviewing the maximum retry logic'), false);
});


test('isCodexIdleUi: status-line shape quoted mid-prose stays false (anchored match)', () => {
  assert.equal(isCodexIdleUi('the worker printed gpt-5.6-sol max · main earlier'), false);
});

test('isCodexIdleUi: leading whitespace before the status line still matches', () => {
  assert.equal(isCodexIdleUi('   gpt-5.6-sol max · main'), true);
});
