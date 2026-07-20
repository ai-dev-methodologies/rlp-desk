// US-003 verdict-schema normalizer — producer-schema contract test.
//
// Three producer shapes emit AC-verdict JSON with different field names for
// the same concepts (see src/node/shared/verdict-schema.mjs header). This
// test feeds each REAL shape (captured as a golden fixture from its emit
// site) through:
//   (a) the Node normalizer directly,
//   (b) generateSVReport (production SV post-pass) + buildAcLifecycle,
//   (c) buildFixContract (Node oracle fix-contract path),
//   (d) the exact jq fallback chain extracted live from run_ralph_desk.zsh
//       (production fix-contract path) — for shared-fixture parity (P1-5).
//
// If a producer shape and the normalizer/jq chain drift, this test fails.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

import {
  normalizeIssue,
  normalizeVerdict,
  normalizeVerdictString,
  normalizeTransitionString,
} from '../../src/node/shared/verdict-schema.mjs';
import { buildFixContract } from '../../src/node/runner/campaign-main-loop.mjs';
import { generateSVReport } from '../../src/node/reporting/campaign-reporting.mjs';

const execFileAsync = promisify(execFile);
const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');
const fixturesDir = path.join(repoRoot, 'tests', 'fixtures', 'verdict-schema');

async function loadFixture(name) {
  const content = await fs.readFile(path.join(fixturesDir, `${name}.json`), 'utf8');
  return JSON.parse(content);
}

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'verdict-schema-contract-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function setupSVTest(t) {
  const rootDir = await createTempDir(t);
  const slug = 'verdict-schema-contract';
  const logsDir = path.join(rootDir, 'logs', slug);
  const outputDir = path.join(rootDir, 'analytics', slug);
  await fs.mkdir(logsDir, { recursive: true });
  await fs.mkdir(outputDir, { recursive: true });

  const prdFile = path.join(rootDir, `prd-${slug}.md`);
  await fs.writeFile(prdFile, '# PRD: verdict-schema-contract\n\n## Objective\nContract test.\n', 'utf8');
  const testSpecFile = path.join(rootDir, `test-spec-${slug}.md`);
  await fs.writeFile(testSpecFile, '# Test Spec\n', 'utf8');
  const analyticsFile = path.join(logsDir, 'campaign.jsonl');

  return { rootDir, slug, logsDir, outputDir, prdFile, testSpecFile, analyticsFile };
}

async function writeDoneClaim(logsDir, iteration, claim) {
  const padded = String(iteration).padStart(3, '0');
  await fs.writeFile(
    path.join(logsDir, `iter-${padded}-done-claim.json`),
    JSON.stringify(claim, null, 2),
    'utf8',
  );
}

async function writeVerdictFile(logsDir, iteration, verdict) {
  const padded = String(iteration).padStart(3, '0');
  await fs.writeFile(
    path.join(logsDir, `iter-${padded}-verify-verdict.json`),
    JSON.stringify(verdict, null, 2),
    'utf8',
  );
}

// Extracts the fix-contract jq filter live from run_ralph_desk.zsh — NOT a
// hand-copied literal — so a future change to the production filter is
// picked up automatically and any drift from the normalizer surfaces as a
// failing assertion below (P1-5 shared-fixture parity, AC3.4).
async function extractZshJqFilter() {
  const zshPath = path.join(repoRoot, 'src', 'scripts', 'run_ralph_desk.zsh');
  const content = await fs.readFile(zshPath, 'utf8');
  const matches = [...content.matchAll(/jq -r '(\.issues\[\]\? \| "- \[.*?)' "/g)].map((m) => m[1]);
  assert.ok(matches.length >= 3, `expected >=3 fix-contract jq filter sites in run_ralph_desk.zsh, found ${matches.length}`);
  const [first, ...rest] = matches;
  for (const filter of rest) {
    assert.equal(filter, first, 'all fix-contract jq filter sites must be identical (single fallback chain, no per-site drift)');
  }
  return first;
}

async function runZshJqFilter(filter, fixturePath) {
  const { stdout } = await execFileAsync('jq', ['-r', filter, fixturePath]);
  return stdout.trim().split('\n').filter(Boolean);
}

function parseJqLine(line) {
  // "- [severity] label: text (hint: ...)" or without the hint suffix.
  const match = line.match(/^- \[([^\]]+)\] ([^:]+): (.+?)(?: \(hint: .+\))?$/);
  assert.ok(match, `unexpected jq output line shape: ${line}`);
  const [, severity, label, text] = match;
  return { severity, label, text };
}

const FIXTURES = [
  {
    name: 'verifier-verdict',
    // init_ralph_desk.zsh:852-874 template: issues[].id / .description.
    expectedLabel: 'AC-1.2',
    expectedTextIncludes: 'Rate limiter middleware not wired',
  },
  {
    name: 'sequential-final-failure',
    // run_ralph_desk.zsh:4595 (zsh production): issues[].criterion / .description.
    expectedLabel: 'US-003',
    expectedTextIncludes: 'Failed during sequential final verification',
  },
  {
    name: 'integration-failure',
    // campaign-main-loop.mjs (Node oracle): issues[].criterion_id / .summary.
    expectedLabel: 'AC-6.4',
    expectedTextIncludes: 'integration verification failed',
  },
];

// AC3.1: the normalizer maps the UNION of all three producer shapes — no
// literal "?" label or "no description" text when the source carries the
// value in ANY of the three shapes.
test('AC3.1: normalizeIssue resolves real label + text for all three producer shapes', async () => {
  for (const { name, expectedLabel, expectedTextIncludes } of FIXTURES) {
    const fixture = await loadFixture(name);
    const [issue] = fixture.issues;
    const normalized = normalizeIssue(issue);
    assert.equal(normalized.label, expectedLabel, `${name}: label`);
    assert.notEqual(normalized.label, '?', `${name}: label must not be the absent-fallback "?"`);
    assert.match(normalized.text, new RegExp(expectedTextIncludes), `${name}: text`);
    assert.notEqual(normalized.text, 'no description', `${name}: text must not be the absent-fallback string`);
  }
});

// AC3.1 + AC3.3: buildFixContract (Node oracle path) consumes the same
// normalizer — no "unknown"/"unspecified issue" placeholder when the source
// carries a label/text in any shape.
test('AC3.1/AC3.3: buildFixContract renders real label + text for all three producer shapes', async () => {
  for (const { name, expectedLabel, expectedTextIncludes } of FIXTURES) {
    const fixture = await loadFixture(name);
    const contract = buildFixContract(fixture);
    assert.match(contract, new RegExp(`- ${expectedLabel.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')} \\[`), `${name}: fix contract should cite the real label`);
    assert.match(contract, new RegExp(expectedTextIncludes), `${name}: fix contract should cite the real text`);
    assert.doesNotMatch(contract, /\bunknown\b \[/, `${name}: fix contract must not render the "unknown" label placeholder`);
    assert.doesNotMatch(contract, /unspecified issue/, `${name}: fix contract must not render the "unspecified issue" text placeholder`);
  }
});

// AC3.3 + AC3.4: the zsh fix-contract jq fallback chain (extracted live from
// run_ralph_desk.zsh) resolves the identical label + text as the Node
// normalizer for every producer shape — shared-fixture parity.
test('AC3.3/AC3.4: zsh jq fallback chain matches the Node normalizer for all three producer shapes', async () => {
  const filter = await extractZshJqFilter();

  for (const { name } of FIXTURES) {
    const fixturePath = path.join(fixturesDir, `${name}.json`);
    const fixture = await loadFixture(name);
    const [expectedIssue] = fixture.issues.map(normalizeIssue);

    const lines = await runZshJqFilter(filter, fixturePath);
    assert.equal(lines.length, 1, `${name}: expected exactly one issue line from jq`);
    const { label, text } = parseJqLine(lines[0]);

    assert.equal(label, expectedIssue.label, `${name}: jq label must match normalizer label`);
    assert.equal(text, expectedIssue.text, `${name}: jq text must match normalizer text`);
  }
});

// AC3.2: reasoning-completeness and AC-lifecycle reflect real categories/US
// ids from the fixtures — no false 0%, no "unknown" AC bucket, when paired
// with the done-claim for the same iteration (the sequential-final-failure
// and integration-failure verdict shapes carry no us_id in source; the
// worker's done-claim for that same iteration is the union's remaining
// signal for that AC bucket).
test('AC3.2: generateSVReport shows real reasoning-completeness and AC buckets for all three producer shapes', async (t) => {
  for (const { name } of FIXTURES) {
    const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
    const fixture = await loadFixture(name);
    const usId = fixture.us_id ?? 'US-099';

    await writeDoneClaim(logsDir, 1, {
      iteration: 1,
      us_id: usId,
      status: 'verify',
      summary: `done claim for ${usId}`,
      execution_steps: [],
    });
    await writeVerdictFile(logsDir, 1, { ...fixture, iteration: 1 });

    const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });
    const report = await fs.readFile(result.reportPath, 'utf8');

    // AC-lifecycle: the real US id must appear as a bucket, never "unknown".
    assert.match(report, new RegExp(`\\| ${usId} \\|`), `${name}: AC lifecycle should bucket under the real US id`);
    assert.doesNotMatch(report, /\| unknown \|/, `${name}: AC lifecycle must not fall back to an "unknown" bucket`);

    // Failure Deep Dive: real label/text, not "unknown"/"unspecified".
    assert.doesNotMatch(report, /unknown \[.*\]: unspecified/, `${name}: Failure Deep Dive must not render unknown/unspecified`);
  }
});

// AC3.2 (verifier-verdict fixture specifically): the full 5-category
// reasoning array must compute 100% reasoning completeness — this is the
// exact false-0%-despite-rich-source-JSON bug from the PRD post-mortem.
test('AC3.2: reasoning-completeness is 100% for the verifier-verdict fixture (not a false 0%)', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const fixture = await loadFixture('verifier-verdict');

  await writeDoneClaim(logsDir, 1, {
    iteration: 1,
    us_id: fixture.us_id,
    status: 'verify',
    summary: 'done claim',
    execution_steps: [],
  });
  await writeVerdictFile(logsDir, 1, { ...fixture, iteration: 1 });

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });
  const report = await fs.readFile(result.reportPath, 'utf8');

  assert.match(report, /Reasoning completeness: 100%/, 'all 5 required categories are present in the fixture reasoning array');
});

// IMP-01: verdict/transition STRING normalizer + zsh↔Node parity.
const zshLibPath = path.join(repoRoot, 'src', 'scripts', 'lib_ralph_desk.zsh');

async function loadVerdictStringCases() {
  const content = await fs.readFile(
    path.join(fixturesDir, 'verdict-string-cases.json'),
    'utf8',
  );
  return JSON.parse(content);
}

function normalizeStringForField(raw, field) {
  return field === 'transition'
    ? normalizeTransitionString(raw)
    : normalizeVerdictString(raw);
}

// Shell the REAL zsh helper (same invocation form the zsh test uses) and strip
// the single trailing newline `print -r --` adds, so comparison is byte-for-byte
// against the Node return value.
async function runZshNormalize(raw, field) {
  const script = `source ${JSON.stringify(zshLibPath)} 2>/dev/null; log(){ :; }; log_debug(){ :; }; log_error(){ :; }; _normalize_verdict "$1" "$2"`;
  const { stdout } = await execFileAsync('zsh', ['--no-rcs', '-c', script, '_', raw, field]);
  return stdout.endsWith('\n') ? stdout.slice(0, -1) : stdout;
}

// IMP-01 (1): the Node string normalizer produces the expected canonical value
// for every shared fixture case (case/trim/separator/synonym/guard/unknown).
test('IMP-01: normalizeVerdictString/normalizeTransitionString match every shared fixture case', async () => {
  const cases = await loadVerdictStringCases();
  for (const { raw, field, expected } of cases) {
    assert.equal(
      normalizeStringForField(raw, field),
      expected,
      `[${field}] ${JSON.stringify(raw)} should normalize to ${JSON.stringify(expected)}`,
    );
  }
});

// IMP-01 (2): shared-fixture parity — the zsh helper output === the Node output
// byte-for-byte for every case (the synonym tables must not drift).
test('IMP-01: zsh _normalize_verdict matches the Node normalizer byte-for-byte', async () => {
  const cases = await loadVerdictStringCases();
  for (const { raw, field } of cases) {
    const zshOut = await runZshNormalize(raw, field);
    const nodeOut = normalizeStringForField(raw, field);
    assert.equal(
      zshOut,
      nodeOut,
      `[${field}] ${JSON.stringify(raw)}: zsh ${JSON.stringify(zshOut)} !== node ${JSON.stringify(nodeOut)}`,
    );
  }
});

// IMP-01 (3): normalizeVerdict wires the string rule into the verdict +
// recommended_state_transition fields (case/synonym variants canonicalized).
test('IMP-01: normalizeVerdict canonicalizes the verdict + transition strings', async () => {
  const fixture = await loadFixture('verifier-verdict');
  const normalized = normalizeVerdict({
    ...fixture,
    verdict: 'PASS',
    recommended_state_transition: 'Done',
  });
  assert.equal(normalized.verdict, 'pass');
  assert.equal(normalized.recommended_state_transition, 'complete');
});

// IMP-06: normalizeVerdict must be idempotent so hoisting normalization to the
// reporting ingestion boundary is safe against a stray second application
// (partial revert, a re-introduced per-item call). Double application must
// deep-equal single application for every producer shape — including the issue
// label/text, which pre-hardening collapsed to "?"/"no description".
test('IMP-06: normalizeVerdict is idempotent (double application deep-equals single)', async () => {
  for (const { name } of FIXTURES) {
    const fixture = await loadFixture(name);
    const once = normalizeVerdict(fixture);
    const twice = normalizeVerdict(once);
    assert.deepEqual(twice, once, `${name}: normalizeVerdict must be idempotent`);
  }
  // Variant strings + raw issue shape also round-trip unchanged on re-application.
  const v = normalizeVerdict({
    verdict: 'PASS',
    recommended_state_transition: 'Done',
    issues: [{ id: 'AC-1', description: 'x' }],
  });
  assert.deepEqual(normalizeVerdict(v), v, 'variant verdict + issues idempotent');
});

// AC3.1: normalizeVerdict is tolerant of the legacy object-keyed reasoning
// shape ({ il1_compliance: "...", ... }) in addition to the array shape.
test('AC3.1: normalizeVerdict tolerates the legacy object-keyed reasoning shape', () => {
  const legacy = normalizeVerdict({
    verdict: 'pass',
    reasoning: {
      il1_compliance: 'Tests pass.',
      layer_enforcement: 'L1 + L3 executed.',
      test_sufficiency: 'Adequate coverage.',
      anti_gaming: 'No signs.',
      worker_process_audit: 'TDD followed.',
    },
  });

  assert.equal(legacy.reasoning.length, 5);
  assert.ok(legacy.reasoning.every((entry) => typeof entry.check === 'string' && entry.basis), 'every legacy entry normalizes to {check, basis}');
});
