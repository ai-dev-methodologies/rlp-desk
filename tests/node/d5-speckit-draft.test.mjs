import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import { listTestSpecFiles } from '../../src/node/util/gate-receipt.mjs';

// D5 (TODO L60) — `speckit <spec.md>`: deterministic test-spec DRAFT from a Spec Kit spec.md.
// Built against the REAL template captured from github/spec-kit v1.2.3 (tests/fixtures/speckit/):
//   spec-template-v1.2.3.md  verbatim upstream template (must be REJECTED: unfilled placeholders)
//   spec-sample-v1.2.3.md    hand-filled sample (no filled upstream example exists)
// Counted over the sample file: 2 stories, 3 scenarios each (6), 3 edge cases, 4 FRs, and exactly
// one Then without a digit (story 1 scenario 2, line 25). Variants of the sample built in this file
// are DERIVED (string edits of the real sample), never captured output.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const SAMPLE = path.join(repoRoot, 'tests', 'fixtures', 'speckit', 'spec-sample-v1.2.3.md');
const TEMPLATE = path.join(repoRoot, 'tests', 'fixtures', 'speckit', 'spec-template-v1.2.3.md');
const libZsh = path.join(repoRoot, 'src', 'scripts', 'lib_ralph_desk.zsh');

async function tmp(t) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'rlp-d5-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

function runMain(argv, cwd = repoRoot) {
  let stdout = '';
  let stderr = '';
  return main(argv, {
    cwd,
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
  }).then((code) => ({ code, stdout, stderr }));
}

const rel = 'tests/fixtures/speckit/spec-sample-v1.2.3.md';
const read = (file) => readFileSync(file, 'utf8');
const sampleText = () => read(SAMPLE);
const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

async function snapshotDir(dir) {
  const out = {};
  for (const name of (await fs.readdir(dir, { recursive: true })).sort()) {
    const full = path.join(dir, name);
    const stat = await fs.stat(full);
    out[name] = stat.isFile() ? sha256(await fs.readFile(full)) : 'dir';
  }
  return out;
}

async function writeDerived(dir, name, mutate) {
  const file = path.join(dir, name);
  await fs.writeFile(file, mutate(read(SAMPLE)), 'utf8');
  return file;
}

test('1: the real sample parses into exact counts (JSON summary)', async () => {
  const res = await runMain(['speckit', rel, '--slug', 'demo', '--json']);
  assert.equal(res.code, 0, res.stderr);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.schema, 'rlp-desk.speckit/1');
  assert.equal(doc.feature, 'Password Reset by Email');
  assert.equal(doc.slug, 'demo');
  assert.deepEqual(doc.source, { path: rel, sha256: sha256(sampleText()) });
  assert.deepEqual(doc.counts, { stories: 2, scenarios: 6, edge_cases: 3, functional_requirements: 4 });
  assert.deepEqual(doc.stories.map((s) => [s.id, s.priority, s.title, s.scenarios.length]), [
    ['US-001', 'P1', 'Request a reset link', 3],
    ['US-002', 'P2', 'Set a new password from the link', 3],
  ]);
  const first = doc.stories[0].scenarios[0];
  assert.deepEqual(
    [first.ac, first.given, first.when, first.then],
    ['AC1', 'a registered account with email `ana@example.com`', 'the user submits that email on the reset form', 'one reset email is sent within 60 seconds'],
  );
  assert.deepEqual(doc.functional_requirements.map((f) => f.id), ['FR-001', 'FR-002', 'FR-003', 'FR-004']);
  assert.equal(doc.edge_cases.length, 3);
  assert.deepEqual(doc.needs_clarification, []);
  assert.deepEqual(doc.ignored_sections, []);
  assert.deepEqual(doc.not_imported, ['Key Entities', 'Success Criteria', 'Assumptions']);
});

test('2: every AC gets a table row and three test stubs (happy, negative, boundary)', async () => {
  const res = await runMain(['speckit', rel, '--slug', 'demo']);
  assert.equal(res.code, 0, res.stderr);
  const lines = res.stdout.split('\n');
  const rows = lines.filter((l) => /^\| US-\d{3} AC\d+:/.test(l));
  assert.equal(rows.length, 6, 'table rows counted over the draft');
  assert.ok(rows.every((r) => /\| TODO \| TODO \|$/.test(r)));
  assert.ok(lines.includes('| Criterion | Method | Command |'));
  const stubs = lines.filter((l) => /^\*\*T-\d{3}-AC\d+-(happy|negative|boundary)\*\*/.test(l));
  assert.equal(stubs.length, 18, 'stubs counted over the draft = 6 ACs x 3');
  for (const us of ['001', '002']) {
    for (const ac of [1, 2, 3]) {
      for (const kind of ['happy', 'negative', 'boundary']) {
        assert.ok(stubs.some((l) => l.startsWith(`**T-${us}-AC${ac}-${kind}**`)), `T-${us}-AC${ac}-${kind}`);
      }
    }
  }
  assert.ok(lines.includes('## US-001: Request a reset link'));
  assert.ok(lines.includes('## US-002: Set a new password from the link'));
});

test('3: a Then without a digit is flagged needs_quantification (exactly US-001 AC2 in the sample)', async () => {
  const doc = JSON.parse((await runMain(['speckit', rel, '--json'])).stdout);
  assert.deepEqual(doc.needs_quantification, ['US-001 AC2']);
  assert.equal(doc.stories[0].scenarios[1].needs_quantification, true);
  assert.equal(doc.stories[0].scenarios[0].needs_quantification, false);
  const draft = (await runMain(['speckit', rel])).stdout;
  assert.match(draft, /needs_quantification[^\n]*US-001 AC2/);
  const flaggedRows = draft.split('\n').filter((l) => /^\| US-\d{3} AC\d+:.*\[needs_quantification\]/.test(l));
  assert.equal(flaggedRows.length, 1);
  assert.match(flaggedRows[0], /^\| US-001 AC2:/);
});

test('4: banner first line states source, sha256 and that the draft is unsealed', async () => {
  const draft = (await runMain(['speckit', rel, '--slug', 'demo'])).stdout;
  const first = draft.split('\n')[0];
  assert.equal(
    first,
    `<!-- DRAFT from Spec Kit ${rel} sha256 ${sha256(sampleText())}; not sealed; still subject to the brainstorm scorecard -->`,
  );
  assert.match(draft, /Suggested file name: `\.rlp-desk\/plans\/test-spec-demo\.speckit-draft\.md`/);
  const noSlug = (await runMain(['speckit', rel])).stdout;
  assert.match(noSlug, /test-spec-<slug>\.speckit-draft\.md/);
});

test('5: unknown structure is rejected fail-closed (exit 1, stdout empty, nothing written)', async (t) => {
  const dir = await tmp(t);
  const out = path.join(dir, 'out.speckit-draft.md');
  const cases = [
    ['em dash in the story heading', (s) => s.replace('### User Story 1 - Request', '### User Story 1 — Request'), /line 14.*User Story/],
    ['missing priority', (s) => s.replace(' (Priority: P2)', ''), /User Story 2/],
    ['malformed scenario line', (s) => s.replace('**When** the user submits that email', 'the user submits that email'), /line 24/],
    ['scenario numbering gap', (s) => s.replace('\n2. **Given** an email address', '\n4. **Given** an email address'), /line 25.*numbering/],
    ['story without scenarios', (s) => s.replace(/\*\*Acceptance Scenarios\*\*:\n\n1\. \*\*Given\*\* a reset link issued 10[\s\S]*?\n\n---\n/, '\n---\n'), /User Story 2.*no Acceptance Scenarios/],
    ['duplicate story number', (s) => s.replace('### User Story 2 -', '### User Story 1 -'), /duplicate.*User Story 1/],
    ['unknown ### heading inside the stories section', (s) => s.replace('### Edge Cases', '### Surprise Section\n\n### Edge Cases'), /line \d+.*Surprise Section/],
    ['unnumbered requirement bullet', (s) => s.replace('- **FR-002**:', '- System MUST expire links;\n- **FR-002**:'), /requirement/],
    ['no stories at all', (s) => s.replace(/### User Story[\s\S]*?### Edge Cases/, '### Edge Cases'), /no user stories/],
  ];
  for (const [label, mutate, expected] of cases) {
    const file = await writeDerived(dir, 'derived.md', mutate);
    const res = await runMain(['speckit', file, '--out', out]);
    assert.equal(res.code, 1, `${label}: ${res.stdout}`);
    assert.equal(res.stdout, '', `${label}: stdout must be empty`);
    assert.match(res.stderr, expected, label);
  }
  assert.deepEqual(await fs.readdir(dir), ['derived.md'], 'no draft written by any rejected input');
});

test('6: the raw upstream template is REJECTED, not turned into a garbage draft', async (t) => {
  const dir = await tmp(t);
  const out = path.join(dir, 'tpl.speckit-draft.md');
  const res = await runMain(['speckit', TEMPLATE, '--out', out]);
  assert.equal(res.code, 1);
  assert.equal(res.stdout, '');
  assert.match(res.stderr, /unfilled Spec Kit template/);
  assert.match(res.stderr, /\[FEATURE NAME\]/);
  assert.match(res.stderr, /\[Brief Title\]/);
  assert.deepEqual(await fs.readdir(dir), []);

  // A single leftover placeholder in an otherwise filled spec is rejected too.
  const file = await writeDerived(dir, 'one-left.md', (s) => s.replace('one reset email is sent within 60 seconds', '[expected outcome]'));
  const one = await runMain(['speckit', file]);
  assert.equal(one.code, 1);
  assert.match(one.stderr, /\[expected outcome\]/);

  // Markdown links, checkboxes, inline code and NEEDS CLARIFICATION markers are NOT placeholders.
  const fine = await writeDerived(dir, 'fine.md', (s) => s
    .replace('one reset email is sent within 60 seconds', 'one email is sent within 60 seconds (see [policy](https://example.com/p)) and `list[0]` is set'));
  assert.equal((await runMain(['speckit', fine])).code, 0);
});

test('7: NEEDS CLARIFICATION markers and HTML comments (derived edits of the sample)', async (t) => {
  const dir = await tmp(t);
  const file = await writeDerived(dir, 'clar.md', (s) => s
    .replace('- **FR-003**: System MUST NOT reveal whether an email address has an account', '- **FR-003**: System MUST NOT reveal whether an email address has an account for [NEEDS CLARIFICATION: retention period not specified]')
    .replace('### Edge Cases', '<!--\n  ### User Story 9 - [Hidden Title] (Priority: P9)\n  1. **Given** [x], **When** [y], **Then** [z]\n-->\n### Edge Cases'));
  const frLine = read(file).split('\n').findIndex((l) => l.startsWith('- **FR-003**')) + 1;
  const res = await runMain(['speckit', file, '--json']);
  assert.equal(res.code, 0, res.stderr);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.counts.stories, 2, 'content inside <!-- --> is skipped');
  assert.deepEqual(doc.needs_clarification, [
    { line: frLine, where: 'FR-003', text: '[NEEDS CLARIFICATION: retention period not specified]' },
  ]);
  const draft = (await runMain(['speckit', file])).stdout;
  assert.ok(draft.split('\n').some((l) => /^- needs_clarification/.test(l)), 'header names the markers');
  assert.match(draft, /FR-003[^\n]*retention period not specified/);

  // An unknown top-level ## section is reported, never silently dropped.
  const extra = await writeDerived(dir, 'extra.md', (s) => `${s}\n## Clarifications\n\n### Session 2026-10-25\n\n- Q: x? -> A: y\n`);
  const doc2 = JSON.parse((await runMain(['speckit', extra, '--json'])).stdout);
  assert.deepEqual(doc2.ignored_sections, [{ heading: 'Clarifications', line: read(extra).split('\n').findIndex((l) => l === '## Clarifications') + 1 }]);
  assert.match((await runMain(['speckit', extra])).stdout, /Ignored sections[^\n]*Clarifications/);
});

test('8: deterministic: same input gives byte-identical output (stdout, --json, --out)', async (t) => {
  const dir = await tmp(t);
  const a = await runMain(['speckit', rel, '--slug', 'demo']);
  const b = await runMain(['speckit', rel, '--slug', 'demo']);
  assert.equal(a.stdout, b.stdout);
  const ja = await runMain(['speckit', rel, '--json']);
  const jb = await runMain(['speckit', rel, '--json']);
  assert.equal(ja.stdout, jb.stdout);
  assert.ok(!/\d{4}-\d{2}-\d{2}T\d{2}:/.test(a.stdout + ja.stdout), 'no clock in the output');
  const out = path.join(dir, 'x.speckit-draft.md');
  assert.equal((await runMain(['speckit', rel, '--slug', 'demo', '--out', out])).code, 0);
  assert.equal(read(out), a.stdout);
});

test('9: default writes nothing; --out writes only that path and refuses sealable names and foreign files', async (t) => {
  const dir = await tmp(t);
  const before = await snapshotDir(dir);
  await runMain(['speckit', SAMPLE, '--slug', 'demo'], dir);
  assert.deepEqual(await snapshotDir(dir), before, 'no --out: nothing written');

  const plans = path.join(dir, '.rlp-desk', 'plans');
  const good = path.join(plans, 'test-spec-demo.speckit-draft.md');
  const ok = await runMain(['speckit', SAMPLE, '--slug', 'demo', '--out', good], dir);
  assert.equal(ok.code, 0, ok.stderr);
  assert.deepEqual(await fs.readdir(plans), ['test-spec-demo.speckit-draft.md'], 'only the requested path appears');
  const again = await runMain(['speckit', SAMPLE, '--slug', 'demo', '--out', good], dir);
  assert.equal(again.code, 0, 're-running over our own draft is allowed');

  for (const name of ['test-spec-demo.md', 'test-spec-demo-US-001.md', 'test-spec-other.md']) {
    const target = path.join(plans, name);
    const res = await runMain(['speckit', SAMPLE, '--slug', 'demo', '--out', target], dir);
    assert.equal(res.code, 1, name);
    assert.match(res.stderr, /sealable|test-spec/i, name);
    assert.equal(existsSyncSafe(target), false, `${name} must not be created`);
  }

  // Never overwrite an existing non-draft file, whatever its name.
  const notes = path.join(plans, 'notes.md');
  await fs.writeFile(notes, 'precious\n');
  const clobber = await runMain(['speckit', SAMPLE, '--out', notes], dir);
  assert.equal(clobber.code, 1);
  assert.equal(read(notes), 'precious\n');
  assert.match(clobber.stderr, /overwrite/);
});

function existsSyncSafe(file) {
  try { readFileSync(file); return true; } catch { return false; }
}

test('10: the draft can never be sealed or split by accident (gate-receipt listing) and still splits via the real zsh splitter', async (t) => {
  const dir = await tmp(t);
  const plans = path.join(dir, 'plans');
  await fs.mkdir(plans);
  const draft = path.join(plans, 'test-spec-demo.speckit-draft.md');
  assert.equal((await runMain(['speckit', rel, '--slug', 'demo', '--out', draft])).code, 0);
  assert.deepEqual(listTestSpecFiles(plans, 'demo'), [], 'gate-receipt does not list the draft');

  const probe = spawnSync('zsh', ['-c', 'true']);
  if (probe.error || probe.status !== 0) {
    t.skip('zsh not available: splitter half skipped');
    return;
  }
  const split = spawnSync('zsh', ['-c', `source '${libZsh}'; split_test_spec_by_us '${draft}' demo`], { encoding: 'utf8' });
  assert.equal(split.status, 0, split.stderr);
  const files = (await fs.readdir(plans)).filter((f) => /^test-spec-demo-US-\d+\.md$/.test(f)).sort();
  assert.deepEqual(files, ['test-spec-demo-US-001.md', 'test-spec-demo-US-002.md']);
  for (const f of files) {
    const content = read(path.join(plans, f));
    assert.equal(content.split('\n').filter((l) => /^##\s+US-\d+/.test(l)).length, 1, f);
    assert.match(content.split('\n')[0], /^<!-- DRAFT from Spec Kit/, `${f}: banner travels with the global header`);
  }
  // The split files ARE sealable names; that is the deliberate human step (copy/merge, scorecard, seal).
  assert.equal(listTestSpecFiles(plans, 'demo').length, 2);
});

test('11: the draft satisfies the >=3 tests per AC density rule (real zsh _lint_test_density)', async (t) => {
  const probe = spawnSync('zsh', ['-c', 'true']);
  if (probe.error || probe.status !== 0) {
    t.skip('zsh not available: density lint skipped');
    return;
  }
  const dir = await tmp(t);
  const draft = path.join(dir, 'test-spec-demo.speckit-draft.md');
  assert.equal((await runMain(['speckit', rel, '--slug', 'demo', '--out', draft])).code, 0);
  const prd = path.join(dir, 'prd.md');
  const acs = (n) => Array.from({ length: n }, (_, i) => `- AC${i + 1}: x`).join('\n');
  await fs.writeFile(prd, `### US-001: a\n${acs(3)}\n\n### US-002: b\n${acs(3)}\n`);
  const lint = spawnSync('zsh', ['-c', `LOGS_DIR='${dir}'; source '${libZsh}'; _lint_test_density '${prd}' '${draft}' strict; echo EXIT=$?`], { encoding: 'utf8' });
  assert.match(lint.stdout, /EXIT=0/);
  assert.ok(!/density warning/i.test(lint.stderr), lint.stderr);
  // Control: dropping the stubs of one AC makes the same lint complain (the check can fail).
  const thin = read(draft).split('\n').filter((l) => !l.startsWith('**T-001-AC1-')).join('\n');
  const thinFile = path.join(dir, 'thin.md');
  await fs.writeFile(thinFile, thin);
  const lint2 = spawnSync('zsh', ['-c', `LOGS_DIR='${dir}'; source '${libZsh}'; _lint_test_density '${prd}' '${thinFile}' warn`], { encoding: 'utf8' });
  assert.match(lint2.stderr, /US-001 has 6 tests for 3 ACs/);
});

test('12: usage, errors, dispatch and help', async (t) => {
  const dir = await tmp(t);
  assert.match((await runMain(['--help'])).stdout, /^  speckit <spec\.md>/m);
  const help = await runMain(['speckit', '--help']);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /speckit <spec\.md>/);
  assert.match(help.stdout, /--out/);

  assert.equal((await runMain(['speckit'])).code, 64, 'missing path');
  assert.equal((await runMain(['speckit', rel, '--bogus'])).code, 64, 'unknown option');
  assert.equal((await runMain(['speckit', rel, 'extra.md'])).code, 64, 'two paths');
  assert.equal((await runMain(['speckit', rel, '--out'])).code, 64, 'missing value');

  const missing = await runMain(['speckit', path.join(dir, 'nope.md')]);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /nope\.md/);

  const badSlug = await runMain(['speckit', rel, '--slug', '../x']);
  assert.equal(badSlug.code, 1, 'IMP-08: slug is rejected, never normalized');
  const goodSlug = await runMain(['speckit', rel, '--slug', 'demo-1']);
  assert.equal(goodSlug.code, 0);
});

test('13: --out through a symlink is refused (dangling link to a sealable name, link to a foreign file), and name case does not matter', async (t) => {
  const dir = await tmp(t);
  const plans = path.join(dir, 'plans');
  await fs.mkdir(plans);
  const sealable = path.join(plans, 'test-spec-demo.md');

  // Dangling symlink with an innocent name pointing at a sealable name that does not exist yet.
  const dangling = path.join(dir, 'draft.md');
  await fs.symlink(sealable, dangling);
  const res = await runMain(['speckit', SAMPLE, '--slug', 'demo', '--out', dangling], dir);
  assert.equal(res.code, 1, res.stdout);
  assert.match(res.stderr, /symlink/i);
  assert.equal(existsSyncSafe(sealable), false, 'the sealable test-spec must not be created through the link');

  // Symlink to an existing foreign file: content intact.
  const foreign = path.join(dir, 'foreign.md');
  await fs.writeFile(foreign, 'precious\n');
  const link = path.join(dir, 'link.speckit-draft.md');
  await fs.symlink(foreign, link);
  const res2 = await runMain(['speckit', SAMPLE, '--out', link], dir);
  assert.equal(res2.code, 1);
  assert.equal(read(foreign), 'precious\n');

  // Even a symlink to a previous draft is refused (no write-through).
  const prev = path.join(dir, 'prev.speckit-draft.md');
  assert.equal((await runMain(['speckit', SAMPLE, '--out', prev], dir)).code, 0);
  const link2 = path.join(dir, 'link2.speckit-draft.md');
  await fs.symlink(prev, link2);
  assert.equal((await runMain(['speckit', SAMPLE, '--out', link2], dir)).code, 1);

  // Case-insensitive filesystems (APFS default) fold these onto the sealable names.
  for (const name of ['TEST-SPEC-demo.md', 'Test-Spec-demo-us-001.md']) {
    const target = path.join(plans, name);
    const r = await runMain(['speckit', SAMPLE, '--out', target], dir);
    assert.equal(r.code, 1, name);
    assert.equal(existsSyncSafe(target), false, name);
  }
});

test('14: wrapped FR / edge-case lines are merged, and a wrapped NEEDS CLARIFICATION marker is still found', async (t) => {
  const dir = await tmp(t);
  const file = await writeDerived(dir, 'wrapped.md', (s) => s
    .replace('- **FR-003**: System MUST NOT reveal whether an email address has an account',
      '- **FR-003**: System MUST NOT reveal whether an email address\n  has an account for [NEEDS CLARIFICATION: retention\n  period not specified]')
    .replace('- What happens when the user opens the same reset link twice?',
      '- What happens when the user opens\nthe same reset link twice?'));
  const res = await runMain(['speckit', file, '--json']);
  assert.equal(res.code, 0, res.stderr);
  const doc = JSON.parse(res.stdout);
  assert.deepEqual(doc.counts, { stories: 2, scenarios: 6, edge_cases: 3, functional_requirements: 4 });
  const fr3 = doc.functional_requirements.find((f) => f.id === 'FR-003');
  assert.equal(fr3.text, 'System MUST NOT reveal whether an email address has an account for [NEEDS CLARIFICATION: retention period not specified]');
  assert.equal(doc.edge_cases[0].text, 'What happens when the user opens the same reset link twice?');
  assert.equal(doc.needs_clarification.length, 1);
  assert.equal(doc.needs_clarification[0].where, 'FR-003');
  assert.equal(doc.needs_clarification[0].text, '[NEEDS CLARIFICATION: retention period not specified]');

  // A placeholder on a continuation line is still caught.
  const bad = await writeDerived(dir, 'wrapped-bad.md', (s) => s
    .replace('- **FR-002**: System MUST expire each reset link 60 minutes after it is issued',
      '- **FR-002**: System MUST expire each reset link\n  [specific capability]'));
  const r2 = await runMain(['speckit', bad]);
  assert.equal(r2.code, 1);
  assert.match(r2.stderr, /\[specific capability\]/);

  // The draft lists the merged FR on one line.
  const draft = (await runMain(['speckit', file])).stdout;
  assert.ok(draft.split('\n').some((l) => l.startsWith('- FR-003: System MUST NOT reveal whether an email address has an account for')));
});

test('15: indented continuation paragraphs are merged; any other unrecognized line in FR / edge-case sections fails closed', async (t) => {
  const dir = await tmp(t);
  // Indented paragraph after a blank line belongs to the preceding bullet (Markdown list semantics).
  const merged = await writeDerived(dir, 'para.md', (s) => s
    .replace('- **FR-002**: System MUST expire each reset link 60 minutes after it is issued',
      '- **FR-002**: System MUST expire each reset link 60 minutes after it is issued\n\n  unless the user has already used it [NEEDS CLARIFICATION: grace period?]')
    .replace('- What happens when the user opens the same reset link twice?',
      '- What happens when the user opens the same reset link twice?\n\n    Consider two browser tabs.'));
  const res = await runMain(['speckit', merged, '--json']);
  assert.equal(res.code, 0, res.stderr);
  const doc = JSON.parse(res.stdout);
  assert.equal(doc.functional_requirements.find((f) => f.id === 'FR-002').text,
    'System MUST expire each reset link 60 minutes after it is issued unless the user has already used it [NEEDS CLARIFICATION: grace period?]');
  assert.equal(doc.edge_cases[0].text, 'What happens when the user opens the same reset link twice? Consider two browser tabs.');
  assert.deepEqual(doc.needs_clarification.map((m) => m.where), ['FR-002']);
  assert.deepEqual(doc.counts, { stories: 2, scenarios: 6, edge_cases: 3, functional_requirements: 4 });

  // Unindented prose after a blank line, or prose before the first bullet: fail closed, never silently dropped.
  const cases = [
    ['unindented paragraph after an FR', (s) => s.replace('- **FR-002**: System MUST expire each reset link 60 minutes after it is issued', '- **FR-002**: System MUST expire each reset link 60 minutes after it is issued\n\nLinks also expire on logout.'), /Links also expire on logout/],
    ['prose before the first FR', (s) => s.replace('### Functional Requirements\n\n', '### Functional Requirements\n\nThese are the rules.\n\n'), /These are the rules/],
    ['unindented paragraph after an edge case', (s) => s.replace('- What happens when the user opens the same reset link twice?', '- What happens when the user opens the same reset link twice?\n\nAlso consider mobile.'), /Also consider mobile/],
  ];
  for (const [label, mutate, expected] of cases) {
    const file = await writeDerived(dir, 'bad.md', mutate);
    const r = await runMain(['speckit', file]);
    assert.equal(r.code, 1, label);
    assert.equal(r.stdout, '', label);
    assert.match(r.stderr, expected, label);
  }

  // The upstream boilerplate line is known and ignored (kept by many authors).
  const boiler = await writeDerived(dir, 'boiler.md', (s) => s.replace('- **FR-004**:', '*Example of marking unclear requirements:*\n\n- **FR-004**:'));
  assert.equal((await runMain(['speckit', boiler])).code, 0);
});
