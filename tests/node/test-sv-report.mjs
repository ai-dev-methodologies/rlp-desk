import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'sv-report-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}


async function readJson(filePath) {
  return JSON.parse(await fs.readFile(filePath, 'utf8'));
}

async function readText(filePath) {
  return fs.readFile(filePath, 'utf8');
}

function makeDoneClaim({ iteration, usId, steps }) {
  return {
    iteration,
    us_id: usId,
    status: 'verify',
    summary: `done claim for ${usId}`,
    execution_steps: steps ?? [],
  };
}

function makeVerdict({ iteration, usId, verdict, reasoning }) {
  return {
    iteration,
    us_id: usId,
    verdict: verdict ?? 'pass',
    recommended_state_transition: verdict === 'pass' ? 'continue' : 'continue',
    reasoning: reasoning ?? {},
    issues: verdict === 'fail' ? [{ criterion_id: 'AC-1.1', severity: 'major', summary: 'test failure' }] : [],
  };
}

async function writeDoneClaim(logsDir, iteration, claim) {
  const padded = String(iteration).padStart(3, '0');
  await fs.writeFile(
    path.join(logsDir, `iter-${padded}-done-claim.json`),
    JSON.stringify(claim, null, 2),
    'utf8',
  );
}

async function writeVerdict(logsDir, iteration, verdict) {
  const padded = String(iteration).padStart(3, '0');
  await fs.writeFile(
    path.join(logsDir, `iter-${padded}-verify-verdict.json`),
    JSON.stringify(verdict, null, 2),
    'utf8',
  );
}

async function writeAnalyticsLine(analyticsFile, record) {
  await fs.appendFile(analyticsFile, `${JSON.stringify(record)}\n`, 'utf8');
}

async function setupSVTest(t, options = {}) {
  const rootDir = await createTempDir(t);
  const slug = options.slug ?? 'test-sv';
  const logsDir = path.join(rootDir, 'logs', slug);
  const outputDir = path.join(rootDir, 'analytics', slug);
  const plansDir = path.join(rootDir, 'plans');
  await fs.mkdir(logsDir, { recursive: true });
  await fs.mkdir(outputDir, { recursive: true });
  await fs.mkdir(plansDir, { recursive: true });

  const prdFile = path.join(plansDir, `prd-${slug}.md`);
  await fs.writeFile(prdFile, '# PRD: test-sv\n\n## Objective\nTest SV report.\n\n## US-001: First story\nAC-1.1: something\n', 'utf8');

  const testSpecFile = path.join(plansDir, `test-spec-${slug}.md`);
  await fs.writeFile(testSpecFile, '# Test Spec\n\n## L1: Unit\n- check something\n\n## L3: E2E\n- verify end to end\n', 'utf8');

  const analyticsFile = path.join(logsDir, 'campaign.jsonl');

  return { rootDir, slug, logsDir, outputDir, prdFile, testSpecFile, analyticsFile };
}

// T1: generateSVReport produces 10-section report from done-claims + verdicts
test('T1: generateSVReport produces 10-section report from done-claims and verdicts', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const claim1 = makeDoneClaim({
    iteration: 1,
    usId: 'US-001',
    steps: [
      { step: 'plan', ac_id: 'AC-1.1', command: 'n/a', exit_code: 0 },
      { step: 'write_test', ac_id: 'AC-1.1', command: 'echo test', exit_code: 0 },
      { step: 'verify_red', ac_id: 'AC-1.1', command: 'npm test', exit_code: 1 },
      { step: 'implement', ac_id: 'AC-1.1', command: 'edit file', exit_code: 0 },
      { step: 'verify_green', ac_id: 'AC-1.1', command: 'npm test', exit_code: 0 },
    ],
  });
  await writeDoneClaim(logsDir, 1, claim1);

  const verdict1 = makeVerdict({
    iteration: 1,
    usId: 'US-001',
    verdict: 'pass',
    reasoning: {
      il1_compliance: 'Tests pass.',
      layer_enforcement: 'L1 + L3 executed.',
      test_sufficiency: 'Adequate coverage.',
      anti_gaming: 'No signs.',
      worker_process_audit: 'TDD followed.',
    },
  });
  await writeVerdict(logsDir, 1, verdict1);

  await writeAnalyticsLine(analyticsFile, {
    iter: 1, us_id: 'US-001', worker_model: 'gpt-5.4:medium',
    worker_engine: 'codex', verdict: 'pass', duration: 120, timestamp: '2026-04-12T00:02:00Z',
  });

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });

  const report = await readText(result.reportPath);
  assert.match(report, /## 1\. Automated Validation Summary/);
  assert.match(report, /## 2\. Failure Deep Dive/);
  assert.match(report, /## 3\. Worker Process Quality/);
  assert.match(report, /## 4\. Verifier Judgment Quality/);
  assert.match(report, /## 5\. AC Lifecycle/);
  assert.match(report, /## 6\. Test-Spec Adherence/);
  assert.match(report, /## 7\. Patterns: Strengths & Weaknesses/);
  assert.match(report, /## 8\. Recommendations for Next Cycle/);
  assert.match(report, /## 9\. Cost & Performance/);
  assert.match(report, /## 10\. Blind Spots/);
});

// T2: generateSVReport handles empty logsDir gracefully
test('T2: generateSVReport handles empty logsDir gracefully', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });

  const report = await readText(result.reportPath);
  const sectionCount = (report.match(/^## \d+\./gm) ?? []).length;
  assert.equal(sectionCount, 10, 'should have 10 numbered sections');
  assert.match(report, /no data|no iteration|none/i);
});

// T3: Worker Process Quality section accuracy
test('T3: Worker Process Quality section shows correct planning step percentage', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  // 3 done-claims: 2 with plan step, 1 without
  await writeDoneClaim(logsDir, 1, makeDoneClaim({
    iteration: 1, usId: 'US-001',
    steps: [
      { step: 'plan', ac_id: 'AC-1.1', command: 'n/a', exit_code: 0 },
      { step: 'implement', ac_id: 'AC-1.1', command: 'edit', exit_code: 0 },
    ],
  }));
  await writeDoneClaim(logsDir, 2, makeDoneClaim({
    iteration: 2, usId: 'US-001',
    steps: [
      { step: 'plan', ac_id: 'AC-1.1', command: 'n/a', exit_code: 0 },
      { step: 'implement', ac_id: 'AC-1.1', command: 'edit', exit_code: 0 },
    ],
  }));
  await writeDoneClaim(logsDir, 3, makeDoneClaim({
    iteration: 3, usId: 'US-001',
    steps: [
      { step: 'implement', ac_id: 'AC-1.1', command: 'edit', exit_code: 0 },
    ],
  }));

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);
  assert.match(report, /Planning step: 67%/);
});

// T4: TDD compliance tracking
test('T4: TDD compliance shows 100% when all iterations have write_test before implement', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  for (let i = 1; i <= 3; i++) {
    await writeDoneClaim(logsDir, i, makeDoneClaim({
      iteration: i, usId: 'US-001',
      steps: [
        { step: 'write_test', ac_id: 'AC-1.1', command: 'echo test', exit_code: 0 },
        { step: 'verify_red', ac_id: 'AC-1.1', command: 'npm test', exit_code: 1 },
        { step: 'implement', ac_id: 'AC-1.1', command: 'edit', exit_code: 0 },
        { step: 'verify_green', ac_id: 'AC-1.1', command: 'npm test', exit_code: 0 },
      ],
    }));
  }

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);
  assert.match(report, /TDD compliance: 100%/);
});

// T5: Versioned output — second call creates -v1.md
test('T5: second generateSVReport call versions the previous report to -v1.md', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });
  await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });

  const versioned = path.join(outputDir, 'self-verification-report-v1.md');
  const stat = await fs.stat(versioned);
  assert.ok(stat.isFile(), 'versioned report -v1.md should exist');
});

// T6: self-verification-data.json structure
test('T6: self-verification-data.json has expected structure', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  await writeDoneClaim(logsDir, 1, makeDoneClaim({
    iteration: 1, usId: 'US-001',
    steps: [{ step: 'implement', ac_id: 'AC-1.1', command: 'edit', exit_code: 0 }],
  }));
  await writeVerdict(logsDir, 1, makeVerdict({ iteration: 1, usId: 'US-001', verdict: 'pass' }));

  await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });

  const data = await readJson(path.join(outputDir, 'self-verification-data.json'));
  assert.ok(data.worker_quality, 'should have worker_quality');
  assert.ok(data.verifier_quality, 'should have verifier_quality');
  assert.ok(data.ac_lifecycle, 'should have ac_lifecycle');
  assert.ok(data.patterns, 'should have patterns');
});

// T7: Summary string returned for svSummary parameter
test('T7: return value has reportPath, version, and summary', async (t) => {
  const { slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir } = await setupSVTest(t);
  const { generateSVReport } = await import('../../src/node/reporting/campaign-reporting.mjs');

  const result = await generateSVReport({ slug, logsDir, prdFile, testSpecFile, analyticsFile, outputDir });

  assert.ok(result.reportPath, 'should have reportPath');
  assert.equal(typeof result.version, 'number', 'version should be a number');
  assert.ok(typeof result.summary === 'string' && result.summary.length > 0, 'summary should be a non-empty string');
});

// T8: rlp-desk.md brainstorm step 0 has expanded SV feedback
test('T8: rlp-desk.md brainstorm step 0 has expanded SV feedback instructions', async () => {
  const rlpDeskPath = path.join(repoRoot, 'src', 'commands', 'rlp-desk.md');
  const content = await readText(rlpDeskPath);

  assert.match(content, /Scan.*analytics/i, 'should reference scanning analytics directory');
  assert.match(content, /No prior campaign data/i, 'should have fallback for no prior data');
  assert.match(content, /self-verification-report\.md/, 'should reference report filename');
});
