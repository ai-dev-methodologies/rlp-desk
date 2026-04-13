import fs from 'node:fs/promises';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileAsync = promisify(execFile);
const REQUIRED_ANALYTICS_FIELDS = [
  'iter',
  'us_id',
  'worker_model',
  'worker_engine',
  'verdict',
  'duration',
  'timestamp',
];

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

function asDate(value) {
  if (value instanceof Date) {
    return value;
  }

  return value ? new Date(value) : new Date();
}

function formatElapsedSeconds(from, to) {
  const elapsedMs = Math.max(0, asDate(to).getTime() - asDate(from).getTime());
  return `${Math.floor(elapsedMs / 1000)}s`;
}

function analyticsVersionPath(targetPath, version) {
  return targetPath.replace(/\.jsonl$/u, `-v${version}.jsonl`);
}

function reportVersionPath(targetPath, version) {
  return targetPath.replace(/\.md$/u, `-v${version}.md`);
}

async function versionFile(targetPath, nextPathForVersion) {
  if (!(await exists(targetPath))) {
    return null;
  }

  let version = 1;
  while (await exists(nextPathForVersion(targetPath, version))) {
    version += 1;
  }

  const versionedPath = nextPathForVersion(targetPath, version);
  await fs.rename(targetPath, versionedPath);
  return versionedPath;
}

async function readJsonIfExists(targetPath) {
  if (!(await exists(targetPath))) {
    return null;
  }

  return JSON.parse(await fs.readFile(targetPath, 'utf8'));
}

async function readAnalytics(analyticsFile) {
  if (!(await exists(analyticsFile))) {
    return [];
  }

  const content = await fs.readFile(analyticsFile, 'utf8');
  return content
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function extractObjective(prdContent) {
  const match = prdContent.match(/^## Objective\s*([\s\S]*?)(?:^## |\s*$)/m);
  return match?.[1]?.trim() ?? '(PRD objective not found)';
}

function extractUsList(prdContent) {
  return [...prdContent.matchAll(/^## (US-\d{3}):/gm)].map((match) => match[1]);
}

function summarizeUsStatus(usList, status) {
  const verified = new Set(status.verified_us ?? []);
  return usList.length === 0
    ? ['- None']
    : usList.map((usId) => `- ${usId}: ${verified.has(usId) ? 'verified' : 'pending'}`);
}

function summarizeVerificationResults(records) {
  return records.length === 0
    ? ['- None']
    : records.map((record) => `- iter ${record.iter}: ${record.us_id} -> ${record.verdict}`);
}

async function summarizeIssues(reportDir) {
  const entries = await fs.readdir(reportDir, { withFileTypes: true }).catch(() => []);
  const fixContracts = entries
    .filter((entry) => entry.isFile() && /^iter-\d+\.fix-contract\.md$/u.test(entry.name))
    .map((entry) => `- ${entry.name}`)
    .sort();

  return fixContracts.length > 0 ? fixContracts : ['- None'];
}

function summarizeCost(records) {
  if (records.length === 0) {
    return ['- No cost data available', '- Total duration: 0s'];
  }

  const totalDuration = records.reduce((sum, record) => sum + Number(record.duration ?? 0), 0);
  return [
    `- Iteration records: ${records.length}`,
    `- Total duration: ${totalDuration}s`,
  ];
}

async function defaultGitDiffProvider({ cwd }) {
  try {
    const { stdout } = await execFileAsync('git', ['diff', '--stat', 'HEAD'], { cwd });
    return stdout.trim();
  } catch {
    return '(git diff unavailable)';
  }
}

export async function prepareCampaignAnalytics({ analyticsFile, statusFile }) {
  await fs.mkdir(path.dirname(analyticsFile), { recursive: true });
  if (!(await exists(analyticsFile))) {
    return null;
  }

  if (await exists(statusFile)) {
    return null;
  }

  return versionFile(analyticsFile, analyticsVersionPath);
}

export async function appendCampaignAnalytics(analyticsFile, record) {
  for (const field of REQUIRED_ANALYTICS_FIELDS) {
    if (record[field] === undefined || record[field] === null || record[field] === '') {
      throw new Error(`analytics record is missing required field: ${field}`);
    }
  }

  await fs.mkdir(path.dirname(analyticsFile), { recursive: true });
  await fs.appendFile(analyticsFile, `${JSON.stringify(record)}\n`, 'utf8');
}

export async function generateCampaignReport({
  slug,
  reportFile,
  prdFile,
  statusFile,
  analyticsFile,
  now = new Date(),
  gitDiffProvider = defaultGitDiffProvider,
  svSummary = 'N/A — --with-self-verification not enabled',
}) {
  await fs.mkdir(path.dirname(reportFile), { recursive: true });
  await versionFile(reportFile, reportVersionPath);

  const prdContent = (await fs.readFile(prdFile, 'utf8').catch(() => ''));
  const status = (await readJsonIfExists(statusFile)) ?? {
    slug,
    iteration: 0,
    max_iterations: 100,
    phase: 'idle',
    verified_us: [],
    consecutive_failures: 0,
  };
  const records = await readAnalytics(analyticsFile);
  const usList = extractUsList(prdContent);
  const issues = await summarizeIssues(path.dirname(reportFile));
  const filesChanged = await gitDiffProvider({ cwd: path.dirname(path.dirname(path.dirname(reportFile))) });
  const terminalState = String(status.phase ?? 'timeout').toUpperCase();
  const elapsed = status.started_at_utc
    ? formatElapsedSeconds(status.started_at_utc, now)
    : '0s';

  const lines = [
    `# Campaign Report: ${slug}`,
    '',
    `Generated: ${asDate(now).toISOString()} | Status: ${terminalState} | Iterations: ${status.iteration ?? 0}`,
    '',
    '## Objective',
    extractObjective(prdContent),
    '',
    '## Execution Summary',
    `- Terminal state: ${terminalState}`,
    `- Iterations run: ${status.iteration ?? 0}`,
    `- Elapsed: ${elapsed}`,
    '',
    '## US Status',
    ...summarizeUsStatus(usList, status),
    '',
    '## Verification Results',
    ...summarizeVerificationResults(records),
    '',
    '## Issues Encountered',
    ...issues,
    '',
    '## Cost & Performance',
    ...summarizeCost(records),
    '',
    '## SV Summary',
    svSummary,
    '',
    '## Files Changed',
    '```',
    filesChanged || '(no changes)',
    '```',
    'Note: Files Changed may include pre-existing uncommitted changes if the campaign started in a dirty worktree.',
    '',
  ];

  await fs.writeFile(reportFile, `${lines.join('\n')}\n`, 'utf8');
}

function svReportVersionPath(targetPath, version) {
  return targetPath.replace(/\.md$/u, `-v${version}.md`);
}

async function collectIterFiles(logsDir, pattern) {
  const entries = await fs.readdir(logsDir, { withFileTypes: true }).catch(() => []);
  return entries
    .filter((entry) => entry.isFile() && pattern.test(entry.name))
    .map((entry) => entry.name)
    .sort();
}

function computeWorkerQuality(doneClaims) {
  if (doneClaims.length === 0) {
    return { planPercent: 0, tddPercent: 0, redConfirmPercent: 0, total: 0 };
  }

  let withPlan = 0;
  let withTdd = 0;
  let withRedConfirm = 0;

  for (const claim of doneClaims) {
    const steps = claim.execution_steps ?? [];
    const stepNames = steps.map((s) => s.step);

    if (stepNames.includes('plan')) {
      withPlan += 1;
    }

    const writeIdx = stepNames.indexOf('write_test');
    const implIdx = stepNames.indexOf('implement');
    if (writeIdx !== -1 && implIdx !== -1 && writeIdx < implIdx) {
      withTdd += 1;
    }

    const redStep = steps.find((s) => s.step === 'verify_red');
    if (redStep && redStep.exit_code === 1) {
      withRedConfirm += 1;
    }
  }

  const pct = (n) => Math.round((n / doneClaims.length) * 100);

  return {
    planPercent: pct(withPlan),
    tddPercent: pct(withTdd),
    redConfirmPercent: pct(withRedConfirm),
    total: doneClaims.length,
  };
}

function computeVerifierQuality(verdicts) {
  if (verdicts.length === 0) {
    return { reasoningPercent: 0, independentPercent: 0, total: 0 };
  }

  const REQUIRED_CATEGORIES = ['il1_compliance', 'layer_enforcement', 'test_sufficiency', 'anti_gaming', 'worker_process_audit'];
  let withComplete = 0;
  let withIndependent = 0;

  for (const v of verdicts) {
    const reasoning = v.reasoning ?? {};
    const present = REQUIRED_CATEGORIES.filter((cat) => reasoning[cat]);
    if (present.length === REQUIRED_CATEGORIES.length) {
      withComplete += 1;
    }
    if (present.length > 0) {
      withIndependent += 1;
    }
  }

  const pct = (n) => Math.round((n / verdicts.length) * 100);

  return {
    reasoningPercent: pct(withComplete),
    independentPercent: pct(withIndependent),
    total: verdicts.length,
  };
}

function buildAcLifecycle(doneClaims, verdicts) {
  const lifecycle = {};

  for (const claim of doneClaims) {
    const usId = claim.us_id ?? 'unknown';
    const iter = claim.iteration ?? 0;
    if (!lifecycle[usId]) {
      lifecycle[usId] = { firstClaimed: iter, firstVerified: null, reopenCount: 0, finalStatus: 'pending' };
    }
    if (iter < lifecycle[usId].firstClaimed) {
      lifecycle[usId].firstClaimed = iter;
    }
  }

  for (const v of verdicts) {
    const usId = v.us_id ?? 'unknown';
    const iter = v.iteration ?? 0;
    if (!lifecycle[usId]) {
      lifecycle[usId] = { firstClaimed: iter, firstVerified: null, reopenCount: 0, finalStatus: 'pending' };
    }
    if (v.verdict === 'pass' && lifecycle[usId].firstVerified === null) {
      lifecycle[usId].firstVerified = iter;
      lifecycle[usId].finalStatus = 'verified';
    } else if (v.verdict === 'fail' && lifecycle[usId].firstVerified !== null) {
      lifecycle[usId].reopenCount += 1;
      lifecycle[usId].finalStatus = 'pending';
    }
  }

  return lifecycle;
}

function extractPatterns(doneClaims, verdicts) {
  const strengths = [];
  const weaknesses = [];
  const passCount = verdicts.filter((v) => v.verdict === 'pass').length;
  const failCount = verdicts.filter((v) => v.verdict === 'fail').length;

  if (passCount > 0 && failCount === 0) {
    strengths.push('All iterations passed on first attempt.');
  } else if (passCount > failCount) {
    strengths.push(`${passCount} of ${verdicts.length} iterations passed.`);
  }

  if (failCount > 0) {
    weaknesses.push(`${failCount} of ${verdicts.length} iterations failed verification.`);
  }

  const wq = computeWorkerQuality(doneClaims);
  if (wq.tddPercent === 100 && wq.total > 0) {
    strengths.push('TDD compliance at 100%.');
  } else if (wq.tddPercent < 80 && wq.total > 0) {
    weaknesses.push(`TDD compliance at ${wq.tddPercent}% — below 80% threshold.`);
  }

  if (strengths.length === 0) {
    strengths.push('No notable strengths detected from available data.');
  }
  if (weaknesses.length === 0) {
    weaknesses.push('No notable weaknesses detected from available data.');
  }

  return { strengths, weaknesses };
}

function buildRecommendations(doneClaims, verdicts, analytics) {
  const recs = { brainstorm: [], prd: [], testSpec: [] };
  const wq = computeWorkerQuality(doneClaims);

  if (wq.tddPercent < 80 && wq.total > 0) {
    recs.brainstorm.push('Recommend stricter TDD enforcement in worker prompts.');
  }

  const usFailCounts = {};
  for (const v of verdicts) {
    if (v.verdict === 'fail') {
      usFailCounts[v.us_id] = (usFailCounts[v.us_id] ?? 0) + 1;
    }
  }
  for (const [usId, count] of Object.entries(usFailCounts)) {
    if (count >= 2) {
      recs.prd.push(`${usId} failed ${count} times — consider splitting into smaller ACs.`);
    }
  }

  const models = new Set(analytics.map((r) => r.worker_model));
  if (models.size > 1) {
    recs.testSpec.push(`Model upgrade occurred (${[...models].join(' -> ')}). Note which model handled what.`);
  }

  if (recs.brainstorm.length === 0) {
    recs.brainstorm.push('No brainstorm recommendations.');
  }
  if (recs.prd.length === 0) {
    recs.prd.push('No PRD recommendations.');
  }
  if (recs.testSpec.length === 0) {
    recs.testSpec.push('No test-spec recommendations.');
  }

  return recs;
}

export async function generateSVReport({
  slug,
  logsDir,
  prdFile: _prdFile,
  testSpecFile,
  analyticsFile,
  outputDir,
}) {
  void _prdFile; // reserved for future use (PRD pattern extraction)
  await fs.mkdir(outputDir, { recursive: true });

  // Collect iteration files
  const claimFiles = await collectIterFiles(logsDir, /^iter-\d+-done-claim\.json$/u);
  const verdictFiles = await collectIterFiles(logsDir, /^iter-\d+-verify-verdict\.json$/u);

  const doneClaims = [];
  for (const file of claimFiles) {
    const data = await readJsonIfExists(path.join(logsDir, file));
    if (data) {
      doneClaims.push(data);
    }
  }

  const verdicts = [];
  for (const file of verdictFiles) {
    const data = await readJsonIfExists(path.join(logsDir, file));
    if (data) {
      verdicts.push(data);
    }
  }

  const analytics = await readAnalytics(analyticsFile);

  // Compute metrics
  const workerQuality = computeWorkerQuality(doneClaims);
  const verifierQuality = computeVerifierQuality(verdicts);
  const acLifecycle = buildAcLifecycle(doneClaims, verdicts);
  const patterns = extractPatterns(doneClaims, verdicts);
  const recommendations = buildRecommendations(doneClaims, verdicts, analytics);

  // Read test-spec for context
  const testSpecContent = await fs.readFile(testSpecFile, 'utf8').catch(() => '');
  const totalIterations = doneClaims.length;
  const dataQuality = totalIterations > 0 ? 100 : 0;

  // Section 1: Automated Validation Summary
  const validationRows = analytics.length > 0
    ? analytics.map((r) => `| ${r.iter} | ${r.us_id} | ${r.verdict} | ${r.worker_model} | ${r.duration}s |`)
    : ['| - | - | - | - | - |'];

  // Section 2: Failure Deep Dive
  const failedVerdicts = verdicts.filter((v) => v.verdict === 'fail');
  const failureLines = failedVerdicts.length > 0
    ? failedVerdicts.map((v) => {
      const issues = (v.issues ?? []).map((i) => `  - ${i.criterion_id ?? 'unknown'} [${i.severity ?? 'major'}]: ${i.summary ?? 'unspecified'}`).join('\n');
      return `### Iteration ${v.iteration ?? '?'} — ${v.us_id ?? 'unknown'}\n${issues || '  - No structured issues.'}`;
    })
    : ['No failed iterations.'];

  // Section 3: Worker Process Quality
  const wqLines = totalIterations > 0
    ? [
      `- Total iterations analyzed: ${workerQuality.total}`,
      `- Planning step: ${workerQuality.planPercent}%`,
      `- TDD compliance: ${workerQuality.tddPercent}%`,
      `- RED confirmation: ${workerQuality.redConfirmPercent}%`,
    ]
    : ['- No iteration data available.'];

  // Section 4: Verifier Judgment Quality
  const vqLines = verdicts.length > 0
    ? [
      `- Total verdicts analyzed: ${verifierQuality.total}`,
      `- Reasoning completeness: ${verifierQuality.reasoningPercent}%`,
      `- Independent verification: ${verifierQuality.independentPercent}%`,
    ]
    : ['- No verdict data available.'];

  // Section 5: AC Lifecycle
  const lifecycleEntries = Object.entries(acLifecycle);
  const acLines = lifecycleEntries.length > 0
    ? lifecycleEntries.map(([usId, lc]) =>
      `| ${usId} | ${lc.firstClaimed} | ${lc.firstVerified ?? '-'} | ${lc.reopenCount} | ${lc.finalStatus} |`)
    : ['| - | - | - | - | - |'];

  // Section 6: Test-Spec Adherence
  const specLines = testSpecContent
    ? [`Test spec present (${testSpecContent.split('\n').length} lines).`]
    : ['No test spec found.'];

  // Section 9: Cost & Performance
  const costLines = analytics.length > 0
    ? [
      `- Iteration records: ${analytics.length}`,
      `- Total duration: ${analytics.reduce((sum, r) => sum + Number(r.duration ?? 0), 0)}s`,
    ]
    : ['- No cost data available.'];

  // Build report
  const now = new Date().toISOString();
  const lines = [
    `# Campaign Self-Verification Report: ${slug}`,
    `Report Version: 1 | Generated: ${now} | Campaign: ${slug}`,
    `Data Quality: ${dataQuality}% iterations complete`,
    '',
    '## 1. Automated Validation Summary',
    '| Iter | US | Verdict | Model | Duration |',
    '|------|-----|---------|-------|----------|',
    ...validationRows,
    '',
    '## 2. Failure Deep Dive',
    ...failureLines,
    '',
    '## 3. Worker Process Quality',
    ...wqLines,
    '',
    '## 4. Verifier Judgment Quality',
    ...vqLines,
    '',
    '## 5. AC Lifecycle',
    '| US | First Claimed | First Verified | Reopen Count | Final Status |',
    '|-----|--------------|----------------|--------------|--------------|',
    ...acLines,
    '',
    '## 6. Test-Spec Adherence',
    ...specLines,
    '',
    '## 7. Patterns: Strengths & Weaknesses',
    '### Strengths',
    ...patterns.strengths.map((s) => `- ${s}`),
    '### Weaknesses',
    ...patterns.weaknesses.map((w) => `- ${w}`),
    '',
    '## 8. Recommendations for Next Cycle',
    '### Brainstorm',
    ...recommendations.brainstorm.map((r) => `- ${r}`),
    '### PRD',
    ...recommendations.prd.map((r) => `- ${r}`),
    '### Test-Spec',
    ...recommendations.testSpec.map((r) => `- ${r}`),
    '',
    '## 9. Cost & Performance',
    ...costLines,
    '',
    '## 10. Blind Spots',
    '- Token counts are not available in tmux mode (estimated from file sizes).',
    '- Source code inspection findings are excluded unless marked [source-inspection].',
    '- Worker internal reasoning beyond execution_steps is not captured.',
    '',
  ];

  // Version existing report
  const reportPath = path.join(outputDir, 'self-verification-report.md');
  const versionedPath = await versionFile(reportPath, svReportVersionPath);
  const version = versionedPath ? Number(versionedPath.match(/-v(\d+)\.md$/)?.[1] ?? 0) + 1 : 1;

  await fs.writeFile(reportPath, `${lines.join('\n')}\n`, 'utf8');

  // Write structured data
  const dataPath = path.join(outputDir, 'self-verification-data.json');
  await fs.writeFile(dataPath, `${JSON.stringify({
    slug,
    generated: now,
    worker_quality: workerQuality,
    verifier_quality: verifierQuality,
    ac_lifecycle: acLifecycle,
    patterns,
    recommendations,
    analytics_count: analytics.length,
  }, null, 2)}\n`, 'utf8');

  // Build summary for campaign report
  const passCount = verdicts.filter((v) => v.verdict === 'pass').length;
  const failCount = verdicts.filter((v) => v.verdict === 'fail').length;
  const summary = totalIterations > 0
    ? `SV report: ${totalIterations} iterations analyzed. TDD compliance: ${workerQuality.tddPercent}%. Pass/Fail: ${passCount}/${failCount}. Report: ${reportPath}`
    : `SV report generated with no iteration data. Report: ${reportPath}`;

  return { reportPath, version, summary };
}

export async function readStatus(slug, options = {}) {
  const rootDir = path.resolve(options.rootDir ?? process.cwd());
  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');

  if (!(await exists(statusFile))) {
    return `No active campaign for ${slug}.`;
  }

  let status;
  try {
    status = JSON.parse(await fs.readFile(statusFile, 'utf8'));
  } catch {
    return `Campaign: ${slug}\nstatus.json is corrupt.`;
  }

  const updatedAt = status.updated_at_utc ?? status.started_at_utc ?? asDate(options.now).toISOString();
  const elapsed = formatElapsedSeconds(updatedAt, options.now ?? new Date());
  const verifiedUs = (status.verified_us ?? []).join(', ') || 'none';

  return [
    `Campaign: ${slug}`,
    `Iteration: ${status.iteration ?? 0} / ${status.max_iterations ?? 100}`,
    `Phase: ${status.phase ?? 'unknown'}`,
    `Worker Model: ${status.worker_model ?? 'unknown'} | Verifier: ${status.verifier_model ?? 'unknown'} (per-US) / ${status.final_verifier_model ?? 'unknown'} (final)`,
    `Verified US: ${verifiedUs}`,
    `Consecutive Failures: ${status.consecutive_failures ?? 0}`,
    `Updated: ${updatedAt} (elapsed: ${elapsed})`,
  ].join('\n');
}
