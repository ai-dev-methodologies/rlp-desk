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
