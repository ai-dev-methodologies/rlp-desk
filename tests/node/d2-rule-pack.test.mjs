import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { main } from '../../src/node/run.mjs';
import {
  writeGateReceipt,
  verifyGateReceipt,
} from '../../src/node/util/gate-receipt.mjs';

// D2 (TODO L44-46) — domain rule packs: JSON data packs rendered into the
// test-spec by `rule-pack apply`. Design: .omc/artifacts/backlog-2026-10-25/d-roadmap-design.md D2.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const shippedFinance = path.join(repoRoot, 'src', 'node', 'rule-packs', 'finance.pack.json');
const libZsh = path.join(repoRoot, 'src', 'scripts', 'lib_ralph_desk.zsh');
const BEGIN_RE = /^<!-- rlp-desk:rule-pack:begin name=([a-z][a-z0-9-]*) version=(\d+\.\d+\.\d+) sha256=([0-9a-f]{64}) -->$/;
const END_RE = /^<!-- rlp-desk:rule-pack:end name=([a-z][a-z0-9-]*) -->$/;

async function createProject(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'd2-rule-pack');
  await fs.mkdir(tempRoot, { recursive: true });
  const dir = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => { await fs.rm(dir, { recursive: true, force: true }); });
  return dir;
}

function runMain(argv, cwd) {
  let stdout = '';
  let stderr = '';
  return main(argv, {
    cwd,
    stdout: { write: (s) => { stdout += s; } },
    stderr: { write: (s) => { stderr += s; } },
  }).then((code) => ({ code, stdout, stderr }));
}

const SPEC = [
  '# Test Spec: demo',
  '',
  '## Verification Commands',
  '- npm test',
  '',
  '## US-001: Alpha',
  '### Test 1: happy',
  '### Test 2: negative',
  '### Test 3: boundary',
  '',
  '## US-002: Beta',
  '**T-002-AC1-happy** y',
  '',
].join('\n');

async function writeSpec(project, slug = 'demo', body = SPEC) {
  const plans = path.join(project, '.rlp-desk', 'plans');
  await fs.mkdir(plans, { recursive: true });
  const file = path.join(plans, `test-spec-${slug}.md`);
  await fs.writeFile(file, body, 'utf8');
  return { plans, file };
}

async function readShipped() {
  return JSON.parse(await fs.readFile(shippedFinance, 'utf8'));
}

async function writeProjectPack(project, name, pack) {
  const dir = path.join(project, '.rlp-desk', 'rule-packs');
  await fs.mkdir(dir, { recursive: true });
  const file = path.join(dir, `${name}.pack.json`);
  await fs.writeFile(file, `${JSON.stringify(pack, null, 2)}\n`, 'utf8');
  return file;
}

function blockOf(content) {
  const lines = content.split('\n');
  const b = lines.findIndex((l) => BEGIN_RE.test(l));
  const e = lines.findIndex((l) => END_RE.test(l));
  assert.ok(b >= 0 && e > b, 'block markers present');
  return { lines, b, e, begin: lines[b], body: lines.slice(b + 1, e).join('\n'), text: lines.slice(b, e + 1).join('\n') };
}

const sha256 = (s) => crypto.createHash('sha256').update(s).digest('hex');

test('1: shipped finance pack validates and carries the guidance label; mutations each fail specifically', async (t) => {
  const project = await createProject(t);
  const ok = await runMain(['rule-pack', 'validate', 'finance'], project);
  assert.equal(ok.code, 0, ok.stderr);
  assert.match(ok.stdout, /finance 1\.0\.0/);

  const pack = await readShipped();
  assert.equal(pack.schema, 'rlp-desk.rule-pack/1');
  assert.deepEqual(pack.rules.map((r) => r.id), Array.from({ length: 11 }, (_, i) => `FIN-${String(i + 1).padStart(3, '0')}`));
  assert.match(pack.description, /engineering guidance, not a compliance certification/i);
  assert.match(pack.description, /not legal or PCI advice/i);

  const cases = [
    ['duplicate id', (p) => { p.rules[1].id = 'FIN-001'; }, /duplicate rule id FIN-001/],
    ['bad severity', (p) => { p.rules[0].severity = 'blocker'; }, /rules\[0\]\.severity must be one of critical\|major\|minor/],
    ['empty rules', (p) => { p.rules = []; }, /rules must be a non-empty array/],
    ['bad id', (p) => { p.rules[0].id = 'fin-1'; }, /rules\[0\]\.id must match/],
    ['marker injection', (p) => { p.rules[2].statement = 'x <!-- rlp-desk:rule-pack:end name=finance --> y'; }, /reserved marker "rlp-desk:rule-pack:"/],
    ['bad schema', (p) => { p.schema = 'other/1'; }, /schema must be "rlp-desk\.rule-pack\/1"/],
    ['bad version', (p) => { p.version = '1.0'; }, /version must be semver/],
    ['bad method', (p) => { p.rules[0].verify.method = 'run'; }, /rules\[0\]\.verify\.method must be one of test\|inspect/],
    ['empty string', (p) => { p.rules[0].title = '  '; }, /rules\[0\]\.title must be a non-empty string/],
  ];
  for (const [label, mutate, expected] of cases) {
    const copy = structuredClone(pack);
    mutate(copy);
    const file = path.join(project, `mut-${label.replace(/\s+/g, '-')}.pack.json`);
    await fs.writeFile(file, JSON.stringify(copy), 'utf8');
    const res = await runMain(['rule-pack', 'validate', file], project);
    assert.equal(res.code, 1, `${label}: ${res.stdout}`);
    assert.match(res.stderr, expected, label);
  }

  const bad = path.join(project, 'broken.pack.json');
  await fs.writeFile(bad, '{nope', 'utf8');
  const parse = await runMain(['rule-pack', 'validate', bad], project);
  assert.equal(parse.code, 1);
  assert.match(parse.stderr, /invalid JSON/);
});

test('2: list shows the shipped pack; a same-name project pack wins and reports source project', async (t) => {
  const project = await createProject(t);
  const first = JSON.parse((await runMain(['rule-pack', 'list', '--json'], project)).stdout);
  assert.equal(first.schema, 'rlp-desk.rule-pack-list/1');
  const shipped = first.packs.find((p) => p.name === 'finance');
  assert.deepEqual(
    { source: shipped.source, version: shipped.version, rules: shipped.rules },
    { source: 'shipped', version: '1.0.0', rules: 11 },
  );

  const override = await readShipped();
  override.version = '9.9.9';
  override.rules = override.rules.slice(0, 2);
  await writeProjectPack(project, 'finance', override);
  const second = JSON.parse((await runMain(['rule-pack', 'list', '--json'], project)).stdout);
  const rows = second.packs.filter((p) => p.name === 'finance');
  assert.equal(rows.length, 1);
  assert.deepEqual({ source: rows[0].source, version: rows[0].version, rules: rows[0].rules }, { source: 'project', version: '9.9.9', rules: 2 });

  const text = await runMain(['rule-pack', 'list'], project);
  assert.match(text.stdout, /finance\s+9\.9\.9\s+project\s+2/);
});

test('3: invalid pack names are rejected before any file read (no traversal)', async (t) => {
  const project = await createProject(t);
  const { file } = await writeSpec(project);
  // A valid pack sitting where `../x` would resolve from <desk>/rule-packs/.
  await fs.writeFile(path.join(project, '.rlp-desk', 'x.pack.json'), JSON.stringify(await readShipped()), 'utf8');
  const before = await fs.readFile(file, 'utf8');
  for (const name of ['../x', 'A_b', 'a'.repeat(40), 'x/y', '-ab']) {
    const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', name], project);
    assert.equal(res.code, 1, name);
    assert.match(res.stderr, /invalid pack name/, name);
    if (name.startsWith('-')) continue; // a leading dash is parsed as an option by validate (usage error)
    const val = await runMain(['rule-pack', 'validate', name], project);
    assert.equal(val.code, 1, `validate ${name}`);
    assert.match(val.stderr, /invalid pack name/, `validate ${name}`);
  }
  assert.equal(await fs.readFile(file, 'utf8'), before);
  const unknown = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'nosuchpack'], project);
  assert.equal(unknown.code, 1);
  assert.match(unknown.stderr, /pack not found: nosuchpack/);
});

test('4: apply inserts the block before the first ## US- heading; sha256 covers the body; the rest is untouched', async (t) => {
  const project = await createProject(t);
  const { file } = await writeSpec(project);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  const after = await fs.readFile(file, 'utf8');
  const { lines, b, e, begin, body, text } = blockOf(after);
  const marker = BEGIN_RE.exec(begin);
  assert.equal(marker[1], 'finance');
  assert.equal(marker[2], '1.0.0');
  assert.equal(marker[3], sha256(body));
  // Block sits in the global header: after the existing header, before ## US-001.
  const firstUs = lines.findIndex((l) => /^##\s+US-\d+/.test(l));
  assert.equal(lines[firstUs], '## US-001: Alpha');
  assert.ok(e < firstUs && b > lines.indexOf('## Verification Commands'));
  assert.equal(lines[e + 1], '');
  // Everything outside the block (and its single trailing blank line) is byte-identical.
  assert.equal(after.replace(`${text}\n\n`, ''), SPEC);
  // Block text: label, rules table, no US heading, one row per rule.
  assert.match(body, /^## Domain Rule Pack: finance \(v1\.0\.0\)$/m);
  assert.match(body, /engineering guidance, not a compliance certification/i);
  assert.match(body, /not legal or PCI advice/i);
  assert.match(body, /cite the rule ID in `issues\[\]\.id`/);
  assert.equal(body.split('\n').filter((l) => /^\| FIN-\d{3} \|/.test(l)).length, 11);
  assert.ok(!body.split('\n').some((l) => /^##\s+US-/.test(l)));
});

test('5: apply is idempotent; a changed pack version replaces the block instead of duplicating it', async (t) => {
  const project = await createProject(t);
  const { file } = await writeSpec(project);
  await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  const once = await fs.readFile(file, 'utf8');
  const again = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(again.code, 0);
  assert.equal(await fs.readFile(file, 'utf8'), once);
  assert.match(again.stdout, /unchanged/);

  const bumped = await readShipped();
  bumped.version = '1.0.1';
  await writeProjectPack(project, 'finance', bumped);
  const replaced = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(replaced.code, 0);
  assert.match(replaced.stdout, /replaced/);
  const after = await fs.readFile(file, 'utf8');
  assert.equal(after.split('\n').filter((l) => l.startsWith('<!-- rlp-desk:rule-pack:begin')).length, 1);
  assert.match(after, /name=finance version=1\.0\.1 /);
  assert.equal(after.replace(blockOf(after).text + '\n\n', ''), SPEC);
});

test('6: per-US test-spec files get the block too; applying first survives the zsh splitter', async (t) => {
  const project = await createProject(t);
  const { plans, file } = await writeSpec(project);
  const perUs = path.join(plans, 'test-spec-demo-US-001.md');
  await fs.writeFile(perUs, '# Test Spec: demo\n\n## Verification Commands\n- npm test\n\n## US-001: Alpha\n### Test 1: happy\n', 'utf8');
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance', '--json'], project);
  assert.equal(res.code, 0, res.stderr);
  const doc = JSON.parse(res.stdout);
  // gate-receipt listing order: main spec first, then per-US files.
  assert.deepEqual(doc.files.map((f) => `${f.file}:${f.action}`), [
    'test-spec-demo.md:inserted',
    'test-spec-demo-US-001.md:inserted',
  ]);
  const perUsAfter = await fs.readFile(perUs, 'utf8');
  const lines = perUsAfter.split('\n');
  assert.ok(lines.findIndex((l) => BEGIN_RE.test(l)) < lines.indexOf('## US-001: Alpha'));

  // Inverse order: block lives in the main spec's header, then the real splitter runs.
  if (!existsSync('/bin/zsh') && spawnSync('zsh', ['-c', 'true']).status !== 0) {
    t.diagnostic('zsh unavailable: splitter half skipped');
    return;
  }
  for (const f of await fs.readdir(plans)) {
    if (/-US-\d+\.md$/.test(f)) await fs.rm(path.join(plans, f));
  }
  const split = spawnSync('zsh', ['-c', `source '${libZsh}'; split_test_spec_by_us '${file}' demo`], { encoding: 'utf8' });
  assert.equal(split.status, 0, split.stderr);
  const splitFiles = (await fs.readdir(plans)).filter((f) => /^test-spec-demo-US-\d+\.md$/.test(f)).sort();
  assert.deepEqual(splitFiles, ['test-spec-demo-US-001.md', 'test-spec-demo-US-002.md']);
  for (const f of splitFiles) {
    const content = await fs.readFile(path.join(plans, f), 'utf8');
    const ls = content.split('\n');
    const bi = ls.findIndex((l) => BEGIN_RE.test(l));
    const usi = ls.findIndex((l) => /^##\s+US-\d+/.test(l));
    assert.ok(bi >= 0 && bi < usi, `${f}: block must precede the US heading`);
    assert.equal(ls.filter((l) => BEGIN_RE.test(l)).length, 1, f);
  }
});

test('7: a test-spec without any ## US- heading gets the block appended; a missing test-spec writes nothing', async (t) => {
  const project = await createProject(t);
  const plain = '# Test Spec: demo\n\nJust prose.\n';
  const { file } = await writeSpec(project, 'demo', plain);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  const after = await fs.readFile(file, 'utf8');
  assert.ok(after.startsWith(plain));
  const { text } = blockOf(after);
  assert.equal(after, `${plain}\n${text}\n`);
  const again = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(again.code, 0);
  assert.equal(await fs.readFile(file, 'utf8'), after);

  const empty = await createProject(t);
  const missing = await runMain(['rule-pack', 'apply', 'ghost', '--pack', 'finance'], empty);
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /test-spec not found/);
  assert.equal(existsSync(path.join(empty, '.rlp-desk')), false);
});

test('8: an existing gate-receipt triggers the re-seal warning, and the block is covered by the seal', async (t) => {
  const project = await createProject(t);
  const { plans } = await writeSpec(project);
  await fs.writeFile(path.join(plans, 'prd-demo.md'), '# PRD\n## US-001: Alpha\n', 'utf8');
  const sealed = writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1 WARN:0 REJECT:0' }).receipt;
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');

  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  assert.match(res.stderr, /gate-receipt/);
  assert.match(res.stderr, /re-run/i);
  assert.notEqual(verifyGateReceipt(plans, 'demo').status, 'ok');
  const resealed = writeGateReceipt(plans, 'demo', { scorecard: 'PASS:1 WARN:0 REJECT:0' }).receipt;
  assert.notEqual(resealed.prd_sha256, sealed.prd_sha256);
  assert.equal(verifyGateReceipt(plans, 'demo').status, 'ok');

  // No receipt: no warning.
  const other = await createProject(t);
  await writeSpec(other);
  const quiet = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], other);
  assert.doesNotMatch(quiet.stderr, /gate-receipt/);
});

test('9: the zsh test-density lint reports the same output before and after apply', async (t) => {
  const zshProbe = spawnSync('zsh', ['-c', 'true']);
  if (zshProbe.error || zshProbe.status !== 0) {
    t.skip('zsh not available');
    return;
  }
  const project = await createProject(t);
  const prd = '# PRD\n## US-001: Alpha\n- AC1: a\n- AC2: b\n\n## US-002: Beta\n- AC1: c\n';
  await fs.writeFile(path.join(project, 'prd.md'), prd, 'utf8');
  const lint = (specFile) => spawnSync('zsh', ['-c', `LOGS_DIR='${project}'; source '${libZsh}'; _lint_test_density '${path.join(project, 'prd.md')}' '${specFile}' warn; echo EXIT=$?`], { encoding: 'utf8' });
  const { file } = await writeSpec(project); // 3 tests under US-001 (needs 6) and 1 under US-002 (needs 3)
  const before = lint(file);
  assert.match(before.stderr, /US-001 has 3 tests for 2 ACs/);
  assert.match(before.stderr, /US-002 has 1 tests for 1 ACs/);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  const after = lint(file);
  assert.equal(after.stderr, before.stderr);
  assert.equal(after.stdout, before.stdout);
});

test('10: dispatch, usage errors and determinism', async (t) => {
  const project = await createProject(t);
  const top = await runMain(['--help'], project);
  assert.match(top.stdout, /^ {2}rule-pack /m);
  const help = await runMain(['rule-pack', '--help'], project);
  assert.equal(help.code, 0);
  assert.match(help.stdout, /Usage: node src\/node\/run\.mjs rule-pack/);
  assert.equal((await runMain(['rule-pack'], project)).code, 0); // bare command prints usage
  assert.equal((await runMain(['rule-pack', 'bogus'], project)).code, 64);
  assert.equal((await runMain(['rule-pack', 'apply', 'demo'], project)).code, 64); // --pack required
  assert.equal((await runMain(['rule-pack', 'list', '--bogus'], project)).code, 64);
  const bad = await runMain(['rule-pack', 'apply', '../x', '--pack', 'finance'], project);
  assert.equal(bad.code, 1);
  assert.match(bad.stderr, /invalid slug/);

  const a = await runMain(['rule-pack', 'list', '--json'], project);
  const b = await runMain(['rule-pack', 'list', '--json'], project);
  assert.equal(a.stdout, b.stdout);
  await writeSpec(project);
  const j1 = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance', '--json'], project);
  const j2 = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance', '--json'], project);
  assert.equal(JSON.parse(j1.stdout).files[0].action, 'inserted');
  assert.equal(JSON.parse(j2.stdout).files[0].action, 'unchanged');
});

test('11: rule text is rendered on one table row; pipes are escaped', async (t) => {
  const project = await createProject(t);
  const { file } = await writeSpec(project);
  const pack = await readShipped();
  pack.name = 'custom';
  pack.rules = [{
    id: 'CUS-001',
    title: 'Pipe | title',
    severity: 'minor',
    statement: 'line one\n## US-999: fake heading\nline | two',
    verify: { method: 'inspect', how: 'read it' },
  }];
  await writeProjectPack(project, 'custom', pack);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'custom'], project);
  assert.equal(res.code, 0, res.stderr);
  const after = await fs.readFile(file, 'utf8');
  const rows = after.split('\n').filter((l) => l.startsWith('| CUS-001 |'));
  assert.equal(rows.length, 1);
  assert.match(rows[0], /Pipe \\\| title/);
  assert.match(rows[0], /line one ## US-999: fake heading line \\\| two/);
  assert.equal(after.split('\n').filter((l) => /^##\s+US-/.test(l)).length, 2); // still only US-001/US-002
});

test('12: a begin marker without its end marker is refused and nothing is written', async (t) => {
  const project = await createProject(t);
  const corrupt = SPEC.replace('## US-001', `<!-- rlp-desk:rule-pack:begin name=finance version=1.0.0 sha256=${'0'.repeat(64)} -->\n\n## US-001`);
  const { file } = await writeSpec(project, 'demo', corrupt);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 1);
  assert.match(res.stderr, /begin marker without a matching end marker/);
  assert.equal(await fs.readFile(file, 'utf8'), corrupt);
});

test('13 (B-C2-02): apply refuses test-spec symlinks (to anything) and writes nothing', async (t) => {
  const project = await createProject(t);
  const { plans, file } = await writeSpec(project);
  const external = path.join(project, 'external-notes.md');
  await fs.writeFile(external, 'EXTERNAL');
  await fs.rm(file);
  await fs.symlink(external, file); // main test-spec is a symlink out of plans/
  const main = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.notEqual(main.code, 0);
  assert.match(main.stderr, /symlink/);
  assert.equal(await fs.readFile(external, 'utf8'), 'EXTERNAL');

  // a per-US file that is a symlink to ANOTHER file inside plans/ is refused as well
  await fs.rm(file);
  await fs.writeFile(file, SPEC, 'utf8');
  const inside = path.join(plans, 'other.md');
  await fs.writeFile(inside, 'INSIDE');
  await fs.symlink(inside, path.join(plans, 'test-spec-demo-US-001.md'));
  const perUs = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.notEqual(perUs.code, 0);
  assert.match(perUs.stderr, /symlink/);
  assert.equal(await fs.readFile(inside, 'utf8'), 'INSIDE');
  assert.equal(await fs.readFile(file, 'utf8'), SPEC, 'the regular main spec was not half-applied');
});

test('14 (B-C2-02): apply writes via temp+rename: keeps the file mode and leaves no temp file', async (t) => {
  const project = await createProject(t);
  const { plans, file } = await writeSpec(project);
  await fs.chmod(file, 0o600);
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  assert.equal((await fs.stat(file)).mode & 0o777, 0o600);
  assert.deepEqual((await fs.readdir(plans)).sort(), ['test-spec-demo.md']);
  assert.match(await fs.readFile(file, 'utf8'), /rlp-desk:rule-pack:begin/);
});

test('15 (R4-03): a test-spec that is a hard link to another file is replaced by the apply, the other file is untouched', async (t) => {
  const project = await createProject(t);
  const { file } = await writeSpec(project);
  const other = path.join(project, 'linked-elsewhere.md');
  await fs.link(file, other); // same inode as the test-spec
  const res = await runMain(['rule-pack', 'apply', 'demo', '--pack', 'finance'], project);
  assert.equal(res.code, 0, res.stderr);
  assert.equal(await fs.readFile(other, 'utf8'), SPEC, 'the other name for the old inode keeps the old content');
  assert.match(await fs.readFile(file, 'utf8'), /rlp-desk:rule-pack:begin/);
});
