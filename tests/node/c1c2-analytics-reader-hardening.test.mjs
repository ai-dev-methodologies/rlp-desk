import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { generateCampaignReport, generateSVReport } from '../../src/node/reporting/campaign-reporting.mjs';

// C-1 + C-2 (reaudit wave 1) — the shared readAnalytics() boundary in
// campaign-reporting.mjs is the ONLY reader for both generateCampaignReport
// and generateSVReport. These tests pin two regressions found there:
//
//   C-1: the zsh leader (production `--mode tmux` backend, see
//        write_campaign_jsonl in lib_ralph_desk.zsh) writes campaign.jsonl
//        rows shaped as claude_verdict/codex_verdict/duration_worker_s/
//        duration_verifier_s, not the Node-native verdict/duration fields.
//        Unmapped, every zsh row rendered as "undefined" verdict and
//        "undefineds" duration.
//   C-2: a single corrupt JSONL line used to throw out of readAnalytics
//        entirely, silently zeroing both reports (0 bytes of real data).

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'c1c2-analytics-reader-hardening');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function readText(filePath) {
  return fs.readFile(filePath, 'utf8');
}

// Byte-for-byte shape of a real zsh-leader campaign.jsonl row (see
// write_campaign_jsonl / lib_ralph_desk.zsh:2159) — field names copied
// verbatim, not paraphrased, so this fixture tracks the real producer.
function zshRow({
  iter, usId, claudeVerdict, durationWorkerS, durationVerifierS,
  consensusMode = 'off', codexVerdict = 'N/A',
}) {
  return {
    iter,
    us_id: usId,
    worker_model: 'sonnet',
    worker_engine: 'claude',
    verifier_engine: 'claude',
    claude_verdict: claudeVerdict,
    codex_verdict: codexVerdict,
    consensus_mode: consensusMode,
    consecutive_failures: 0,
    model_upgraded: 0,
    us_fail_history: {},
    duration_worker_s: durationWorkerS,
    duration_verifier_s: durationVerifierS,
    project_root: '/tmp/x',
    slug: 'zsh-shape',
    timestamp: '2026-04-12T00:00:00Z',
    lifecycle_metrics: null,
  };
}

async function setupCampaignReportFixture(t, slug) {
  const rootDir = await createTempDir(t);
  const deskRoot = path.join(rootDir, '.rlp-desk');
  await fs.mkdir(path.join(deskRoot, 'logs', slug, 'runtime'), { recursive: true });
  await fs.mkdir(path.join(deskRoot, 'plans'), { recursive: true });

  const prdFile = path.join(deskRoot, 'plans', `prd-${slug}.md`);
  const statusFile = path.join(deskRoot, 'logs', slug, 'runtime', 'status.json');
  const reportFile = path.join(deskRoot, 'logs', slug, 'campaign-report.md');
  const analyticsFile = path.join(deskRoot, 'logs', slug, 'campaign.jsonl');

  await fs.writeFile(prdFile, `# PRD: ${slug}\n\n## Objective\nShip it.\n`, 'utf8');
  await fs.writeFile(statusFile, JSON.stringify({
    slug, iteration: 2, max_iterations: 100, phase: 'complete',
    verified_us: ['US-001'], consecutive_failures: 0,
    started_at_utc: '2026-04-12T00:00:00.000Z',
  }, null, 2), 'utf8');

  return { rootDir, deskRoot, prdFile, statusFile, reportFile, analyticsFile };
}

async function setupSVReportFixture(t, slug) {
  const rootDir = await createTempDir(t);
  const logsDir = path.join(rootDir, 'logs', slug);
  const outputDir = path.join(rootDir, 'analytics', slug);
  await fs.mkdir(logsDir, { recursive: true });
  await fs.mkdir(outputDir, { recursive: true });

  const analyticsFile = path.join(logsDir, 'campaign.jsonl');
  const testSpecFile = path.join(rootDir, `test-spec-${slug}.md`);

  return { rootDir, logsDir, outputDir, analyticsFile, testSpecFile };
}

test('C-1: generateCampaignReport sums duration_worker_s + duration_verifier_s across all zsh rows and never renders "undefined"', async (t) => {
  const slug = 'c1-campaign-sum';
  const { prdFile, statusFile, reportFile, analyticsFile } = await setupCampaignReportFixture(t, slug);

  const rows = [
    zshRow({ iter: 1, usId: 'US-001', claudeVerdict: 'pass', durationWorkerS: 45, durationVerifierS: 12 }),
    zshRow({ iter: 2, usId: 'US-001', claudeVerdict: 'fail', durationWorkerS: 30, durationVerifierS: 15 }),
  ];
  await fs.writeFile(analyticsFile, rows.map((r) => JSON.stringify(r)).join('\n') + '\n', 'utf8');

  await generateCampaignReport({
    slug, reportFile, prdFile, statusFile, analyticsFile,
    now: new Date('2026-04-12T01:00:00Z'),
    gitDiffProvider: async () => '',
  });

  const report = await readText(reportFile);
  // (45+12) + (30+15) = 57 + 45 = 102
  assert.match(report, /Total duration: 102s/);
  assert.doesNotMatch(report, /undefined/);
});

test('C-1: generateSVReport renders the zsh verdict and per-row summed duration in the validation table', async (t) => {
  const slug = 'c1-sv';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const rows = [
    zshRow({ iter: 1, usId: 'US-001', claudeVerdict: 'pass', durationWorkerS: 45, durationVerifierS: 12 }),
    zshRow({ iter: 2, usId: 'US-002', claudeVerdict: 'fail', durationWorkerS: 30, durationVerifierS: 15 }),
  ];
  await fs.writeFile(analyticsFile, rows.map((r) => JSON.stringify(r)).join('\n') + '\n', 'utf8');

  const result = await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);

  assert.doesNotMatch(report, /undefined/, 'zsh-shaped rows must not render as undefined anywhere in the SV report');
  assert.match(report, /\| 1 \| US-001 \| pass \| sonnet \| 57s \|/, 'row 1 duration = 45 + 12 = 57');
  assert.match(report, /\| 2 \| US-002 \| fail \| sonnet \| 45s \|/, 'row 2 duration = 30 + 15 = 45');
  // Section 9 aggregate: 57 + 45 = 102, an absence-only check would also pass at 0s.
  assert.match(report, /Total duration: 102s/);
});

test('C-2: generateCampaignReport skips a corrupt analytics line, still renders the good rows, and surfaces the skip count', async (t) => {
  const slug = 'c2-campaign';
  const { prdFile, statusFile, reportFile, analyticsFile } = await setupCampaignReportFixture(t, slug);

  const goodRow1 = { iter: 1, us_id: 'US-001', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'pass', duration: 10, timestamp: '2026-04-12T00:00:00Z' };
  const corruptLine = '{"iter": 2, "us_id": "US-002", "verdict": "fail"'; // truncated — invalid JSON
  const goodRow2 = { iter: 3, us_id: 'US-003', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'fail', duration: 20, timestamp: '2026-04-12T00:00:10Z' };

  await fs.writeFile(
    analyticsFile,
    [JSON.stringify(goodRow1), corruptLine, JSON.stringify(goodRow2)].join('\n') + '\n',
    'utf8',
  );

  await generateCampaignReport({
    slug, reportFile, prdFile, statusFile, analyticsFile,
    now: new Date('2026-04-12T01:00:00Z'),
    gitDiffProvider: async () => '',
  });

  const report = await readText(reportFile);
  assert.match(report, /iter 1: US-001 -> pass/, 'good row before the corrupt line must still render');
  assert.match(report, /iter 3: US-003 -> fail/, 'good row after the corrupt line must still render');
  assert.match(report, /Total duration: 30s/, 'only the 2 good rows (10 + 20) count toward the total');
  assert.match(report, /1 malformed row\(s\) skipped/, 'the skip must be surfaced, not silent');
});

test('C-2: generateSVReport skips a corrupt analytics line, still renders the good rows, and surfaces the skip count', async (t) => {
  const slug = 'c2-sv';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const goodRow1 = { iter: 1, us_id: 'US-001', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'pass', duration: 10, timestamp: '2026-04-12T00:00:00Z' };
  const corruptLine = 'not even json';
  const goodRow2 = { iter: 2, us_id: 'US-002', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'fail', duration: 20, timestamp: '2026-04-12T00:00:10Z' };

  await fs.writeFile(
    analyticsFile,
    [JSON.stringify(goodRow1), corruptLine, JSON.stringify(goodRow2)].join('\n') + '\n',
    'utf8',
  );

  const result = await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);

  assert.match(report, /\| 1 \| US-001 \| pass \| sonnet \| 10s \|/);
  assert.match(report, /\| 2 \| US-002 \| fail \| sonnet \| 20s \|/);
  assert.match(report, /Total duration: 30s/, 'only the 2 good rows (10 + 20) count toward the total');
  assert.match(report, /1 malformed row\(s\) skipped/, 'the skip must be surfaced, not silent');
});

// --- Follow-up gaps from independent review (still C-1/C-2, same reader) ---

test('C-1: a real consensus split (consensus_mode != off, codex_verdict disagrees) renders both sides instead of picking one', async (t) => {
  const slug = 'c1-consensus-split';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const row = zshRow({
    iter: 1, usId: 'US-001', claudeVerdict: 'pass', durationWorkerS: 10, durationVerifierS: 5,
    consensusMode: 'all', codexVerdict: 'fail',
  });
  await fs.writeFile(analyticsFile, `${JSON.stringify(row)}\n`, 'utf8');

  const result = await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);

  assert.match(report, /\| 1 \| US-001 \| pass\/codex:fail \| sonnet \| 15s \|/, 'a real disagreement must surface both verdicts, not silently pick claude\'s side');
});

test('C-1: a real consensus split where codex AGREES with claude renders the single verdict, not a redundant pair', async (t) => {
  const slug = 'c1-consensus-agree';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const row = zshRow({
    iter: 1, usId: 'US-001', claudeVerdict: 'pass', durationWorkerS: 10, durationVerifierS: 5,
    consensusMode: 'all', codexVerdict: 'pass',
  });
  await fs.writeFile(analyticsFile, `${JSON.stringify(row)}\n`, 'utf8');

  const result = await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);

  assert.match(report, /\| 1 \| US-001 \| pass \| sonnet \| 15s \|/);
  assert.doesNotMatch(report, /pass\/codex:pass/);
});

test('C-2: a line that parses to JSON null is treated as malformed, not a TypeError crash', async (t) => {
  const slug = 'c2-null-line';
  const { prdFile, statusFile, reportFile, analyticsFile } = await setupCampaignReportFixture(t, slug);

  const goodRow = { iter: 1, us_id: 'US-001', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'pass', duration: 10, timestamp: '2026-04-12T00:00:00Z' };
  await fs.writeFile(analyticsFile, `${JSON.stringify(goodRow)}\nnull\n`, 'utf8');

  // Must not throw (readAnalytics used to hit `record.verdict` on `null`).
  await generateCampaignReport({
    slug, reportFile, prdFile, statusFile, analyticsFile,
    now: new Date('2026-04-12T01:00:00Z'),
    gitDiffProvider: async () => '',
  });

  const report = await readText(reportFile);
  assert.match(report, /iter 1: US-001 -> pass/, 'the good row must still render');
  assert.match(report, /Total duration: 10s/, 'the null row must not be counted as a 0-duration record');
  assert.match(report, /1 malformed row\(s\) skipped/, 'a null row must be counted as malformed, not silently dropped');
});

test('C-2: a line that parses to a bare JSON scalar is treated as malformed, not counted as a valid record', async (t) => {
  const slug = 'c2-scalar-line';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const goodRow = { iter: 1, us_id: 'US-001', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'pass', duration: 10, timestamp: '2026-04-12T00:00:00Z' };
  // "42", `"hello"`, and `true` are all valid JSON lines but useless rows.
  await fs.writeFile(analyticsFile, `${JSON.stringify(goodRow)}\n42\n"hello"\ntrue\n`, 'utf8');

  const result = await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const report = await readText(result.reportPath);
  const data = JSON.parse(await readText(path.join(outputDir, 'self-verification-data.json')));

  assert.match(report, /\| 1 \| US-001 \| pass \| sonnet \| 10s \|/, 'the one real row must still render');
  assert.doesNotMatch(report, /\| undefined \|/, 'a scalar row must never render as a table row of undefined fields');
  assert.equal(data.analytics_count, 1, 'scalar lines must not inflate the analytics record count');
  assert.match(report, /3 malformed row\(s\) skipped/, 'all 3 scalar lines must be counted as malformed');
});

test('C-2: when every analytics row is malformed, summarizeCost still renders (no throw) and surfaces the full skip count', async (t) => {
  const slug = 'c2-all-malformed';
  const { prdFile, statusFile, reportFile, analyticsFile } = await setupCampaignReportFixture(t, slug);

  await fs.writeFile(analyticsFile, 'not json\n{"truncated": \n42\n', 'utf8');

  // Must not throw — summarizeCost's records.length === 0 branch is the one
  // under test here.
  await generateCampaignReport({
    slug, reportFile, prdFile, statusFile, analyticsFile,
    now: new Date('2026-04-12T01:00:00Z'),
    gitDiffProvider: async () => '',
  });

  const report = await readText(reportFile);
  assert.match(report, /- No cost data available/);
  assert.match(report, /3 malformed row\(s\) skipped/);
});

test('C-2: malformed_count is exposed in the self-verification-data.json sidecar, not only the Markdown report', async (t) => {
  const slug = 'c2-sidecar';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);

  const goodRow = { iter: 1, us_id: 'US-001', worker_model: 'sonnet', worker_engine: 'claude', verdict: 'pass', duration: 10, timestamp: '2026-04-12T00:00:00Z' };
  await fs.writeFile(analyticsFile, `${JSON.stringify(goodRow)}\nnot json\n`, 'utf8');

  await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const data = JSON.parse(await readText(path.join(outputDir, 'self-verification-data.json')));

  assert.equal(data.malformed_count, 1, 'the sidecar JSON must expose the same skip count as the Markdown report');
  assert.equal(data.analytics_count, 1);
});

test('C-2: malformed_count is 0 (not absent) in the sidecar when campaign.jsonl does not exist at all', async (t) => {
  const slug = 'c2-no-analytics-file';
  const { logsDir, outputDir, analyticsFile, testSpecFile } = await setupSVReportFixture(t, slug);
  // Deliberately never write analyticsFile — this is the "no campaign.jsonl
  // yet" path, distinct from "campaign.jsonl exists but every row in it is
  // malformed" (covered by the "all-rows-malformed" test above).

  // Must not throw.
  await generateSVReport({ slug, logsDir, prdFile: undefined, testSpecFile, analyticsFile, outputDir });
  const data = JSON.parse(await readText(path.join(outputDir, 'self-verification-data.json')));

  assert.ok(
    Object.prototype.hasOwnProperty.call(data, 'malformed_count'),
    'malformed_count key must be present (JSON.stringify drops an undefined value entirely)',
  );
  assert.equal(data.malformed_count, 0, 'an absent campaign.jsonl is not itself a malformed row');
  assert.equal(data.analytics_count, 0);
});
