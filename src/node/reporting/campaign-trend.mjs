// D1 (TODO L32) — cross-campaign trend analysis.
//
// A read-only reader over `campaign.jsonl` / `campaign-v{N}.jsonl`: both leaders
// rotate the previous run's file to `campaign-v{N}.jsonl` when a new run starts
// (zsh run_ralph_desk.zsh; Node versionFile in campaign-reporting.mjs), so the
// numbered files plus the un-numbered one are the only complete cross-run history
// in structured form. Rows are normalized by campaign-reporting.mjs readAnalytics()
// (zsh claude_verdict/codex_verdict/duration_*_s and Node verdict/duration).
//
// Deterministic: no LLM, no generation timestamps, no writes except an explicit
// --out file. Invoked as `node ~/.claude/ralph-desk/node/run.mjs trend ...`.

import fs from 'node:fs/promises';
import path from 'node:path';

import { readAnalytics } from './campaign-reporting.mjs';
import { resolveDeskRoot } from '../util/desk-root.mjs';
import { OutPathError, resolveGuardedOutPath, writeGuardedOut } from '../util/out-path-guard.mjs';
import { resolveAnalyticsPointer } from '../runner/campaign-main-loop.mjs';

export const TREND_SCHEMA = 'rlp-desk.trend/1';
const EXIT_USAGE = 64;
const ALL_US = 'ALL';

// Fixed direction table (documented in the markdown output). A delta of 0 is
// always `unchanged`; otherwise the sign is judged against this table.
const DIRECTION_BETTER = Object.freeze({
  iterations: 'lower',
  first_pass_rate: 'higher',
  fail: 'lower',
  duration_total_s: 'lower',
  model_upgrades: 'lower',
  us_passed: 'higher',
});

const USAGE = [
  'Usage: node src/node/run.mjs trend [<slug>] [--json] [--last N] [--out <file>] [--dir <analytics-dir>]',
  '',
  '  Run-over-run metrics from campaign.jsonl / campaign-v{N}.jsonl (read-only).',
  '  <slug>        runs of that slug, oldest -> newest (--last N keeps the newest N).',
  '  (no slug)     one summary row per slug under <deskRoot>/analytics/.',
  '  --dir DIR     use this analytics directory instead of discovery.',
  '  --out FILE    also write the rendered output to FILE (the only write).',
  '  --json        machine-readable output (schema rlp-desk.trend/1).',
].join('\n');

function round4(value) {
  return Math.round(value * 10000) / 10000;
}

function verdictClass(verdict) {
  if (verdict === 'pass') return 'pass';
  if (verdict === 'fail') return 'fail';
  // deriveZshVerdict surfaces a consensus disagreement as `<claude>/codex:<codex>`.
  if (typeof verdict === 'string' && verdict.includes('/codex:')) return 'split';
  return 'other';
}

export function computeRunMetrics(label, records) {
  const verdicts = { pass: 0, fail: 0, split: 0, other: 0 };
  const iterations = new Set();
  const models = new Set();
  const firstVerdictByUs = new Map();
  const lastVerdictByUs = new Map();
  const usIds = new Set();
  let durationTotal = 0;
  let modelChanges = 0;
  let previousModel = null;

  for (const row of records) {
    verdicts[verdictClass(row.verdict)] += 1;
    if (row.iter !== undefined && row.iter !== null) iterations.add(String(row.iter));
    const duration = Number(row.duration);
    if (Number.isFinite(duration)) durationTotal += duration;

    if (typeof row.worker_model === 'string' && row.worker_model !== '') {
      models.add(row.worker_model);
      if (previousModel !== null && previousModel !== row.worker_model) modelChanges += 1;
      previousModel = row.worker_model;
    }

    const usId = typeof row.us_id === 'string' ? row.us_id : '';
    if (usId !== '' && usId !== ALL_US) {
      usIds.add(usId);
      if (row.verdict !== undefined) {
        if (!firstVerdictByUs.has(usId)) firstVerdictByUs.set(usId, row.verdict);
        lastVerdictByUs.set(usId, row.verdict);
      }
    }
  }

  const usTotal = usIds.size;
  const usPassed = [...lastVerdictByUs.values()].filter((v) => verdictClass(v) === 'pass').length;
  const firstPass = [...firstVerdictByUs.values()].filter((v) => verdictClass(v) === 'pass').length;
  const timestamps = records.map((r) => r.timestamp).filter((ts) => typeof ts === 'string' && ts !== '');

  return {
    label,
    rows: records.length,
    iterations: iterations.size,
    us_total: usTotal,
    us_passed: usPassed,
    first_pass_rate: usTotal === 0 ? null : round4(firstPass / usTotal),
    verdicts,
    // Count of worker_model transitions between consecutive rows. The zsh rows'
    // `model_upgraded` field is a sticky 0/1 flag (stays 1 on every row after an
    // upgrade), so summing it would count rows, not upgrades; the Node rows do
    // not carry it at all.
    model_upgrades: modelChanges,
    worker_models: [...models].sort(),
    duration_total_s: durationTotal,
    first_ts: timestamps.length > 0 ? timestamps[0] : null,
    last_ts: timestamps.length > 0 ? timestamps[timestamps.length - 1] : null,
    malformed: records.malformedCount ?? 0,
  };
}

function direction(key, delta) {
  if (delta === null) return 'n/a';
  if (delta === 0) return 'unchanged';
  const better = DIRECTION_BETTER[key];
  const improved = better === 'lower' ? delta < 0 : delta > 0;
  return improved ? 'improved' : 'regressed';
}

function diffRuns(from, to) {
  const rate = from.first_pass_rate === null || to.first_pass_rate === null
    ? null
    : round4(to.first_pass_rate - from.first_pass_rate);
  const delta = {
    from: from.label,
    to: to.label,
    iterations: to.iterations - from.iterations,
    first_pass_rate: rate,
    fail: to.verdicts.fail - from.verdicts.fail,
    duration_total_s: to.duration_total_s - from.duration_total_s,
    model_upgrades: to.model_upgrades - from.model_upgrades,
    us_passed: to.us_passed - from.us_passed,
  };
  delta.verdicts = {
    iterations: direction('iterations', delta.iterations),
    first_pass_rate: direction('first_pass_rate', delta.first_pass_rate),
    fail: direction('fail', delta.fail),
    duration_total_s: direction('duration_total_s', delta.duration_total_s),
    model_upgrades: direction('model_upgrades', delta.model_upgrades),
    us_passed: direction('us_passed', delta.us_passed),
  };
  return delta;
}

// `runs` are already-computed run metrics (computeRunMetrics output), oldest first.
export function buildTrend({ slug, analyticsDir, runs }) {
  const deltas = [];
  for (let i = 1; i < runs.length; i += 1) deltas.push(diffRuns(runs[i - 1], runs[i]));
  const warnings = runs
    .filter((run) => run.malformed > 0)
    .map((run) => `${run.label}: ${run.malformed} malformed row(s) skipped`);
  if (runs.length < 2) warnings.push('need >= 2 runs for deltas');
  return {
    schema: TREND_SCHEMA,
    slug,
    analytics_dir: analyticsDir,
    runs,
    deltas,
    first_vs_last: runs.length >= 2 ? diffRuns(runs[0], runs[runs.length - 1]) : null,
    warnings,
  };
}

// campaign-v1.jsonl .. campaign-vN.jsonl (numeric order) then campaign.jsonl (newest).
export async function loadRuns(analyticsDir) {
  let names;
  try {
    names = await fs.readdir(analyticsDir);
  } catch {
    return [];
  }
  const numbered = names
    .map((name) => ({ name, match: /^campaign-v(\d+)\.jsonl$/u.exec(name) }))
    .filter((entry) => entry.match)
    .map((entry) => ({ label: `v${Number(entry.match[1])}`, n: Number(entry.match[1]), file: path.join(analyticsDir, entry.name) }))
    .sort((a, b) => a.n - b.n);
  const files = [...numbered];
  if (names.includes('campaign.jsonl')) {
    files.push({ label: 'current', n: Infinity, file: path.join(analyticsDir, 'campaign.jsonl') });
  }
  const runs = [];
  for (const entry of files) {
    runs.push(computeRunMetrics(entry.label, await readAnalytics(entry.file)));
  }
  return runs;
}

async function isDirectory(target) {
  try {
    return (await fs.stat(target)).isDirectory();
  } catch {
    return false;
  }
}

// Discovery order: pointer `<slug>.current`; else `analytics/<slug>`; else exactly
// one `analytics/<slug>--*`. Several `<slug>--*` and no pointer is ambiguous.
async function resolveSlugDir(deskRoot, slug) {
  const pointed = await resolveAnalyticsPointer(deskRoot, slug);
  if (pointed) return pointed.analyticsDir;
  const analyticsRoot = path.join(deskRoot, 'analytics');
  const plain = path.join(analyticsRoot, slug);
  if (await isDirectory(plain)) return plain;
  let names = [];
  try {
    names = await fs.readdir(analyticsRoot);
  } catch {
    names = [];
  }
  const candidates = names.filter((name) => name.startsWith(`${slug}--`)).sort();
  const dirs = [];
  for (const name of candidates) {
    if (await isDirectory(path.join(analyticsRoot, name))) dirs.push(name);
  }
  if (dirs.length === 1) return path.join(analyticsRoot, dirs[0]);
  if (dirs.length > 1) {
    throw new Error(
      `ambiguous analytics for slug ${JSON.stringify(slug)}: ${dirs.join(', ')} — no ${slug}.current pointer; pass --dir <analytics-dir> to choose`,
    );
  }
  throw new Error(`no analytics found for slug ${JSON.stringify(slug)} under ${analyticsRoot}`);
}

async function discoverSlugs(deskRoot) {
  const analyticsRoot = path.join(deskRoot, 'analytics');
  let entries;
  try {
    entries = await fs.readdir(analyticsRoot, { withFileTypes: true });
  } catch {
    return [];
  }
  const slugs = new Set();
  for (const entry of entries) {
    if (entry.isFile() && entry.name.endsWith('.current')) {
      slugs.add(entry.name.slice(0, -'.current'.length));
    } else if (entry.isDirectory()) {
      const hashed = /^(.+)--[0-9a-f]{8}$/u.exec(entry.name);
      slugs.add(hashed ? hashed[1] : entry.name);
    }
  }
  return [...slugs].sort();
}

function displayDir(cwd, dir) {
  const rel = path.relative(cwd, dir);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel : dir;
}

function cell(value) {
  return value === null || value === undefined ? '-' : String(value);
}

function signed(value) {
  if (value === null) return '-';
  return value > 0 ? `+${value}` : String(value);
}

function countDirections(delta) {
  const counts = { improved: 0, regressed: 0, unchanged: 0 };
  for (const verdict of Object.values(delta.verdicts)) {
    if (verdict in counts) counts[verdict] += 1;
  }
  return counts;
}

function describeDelta(delta) {
  const c = countDirections(delta);
  return `${delta.from} -> ${delta.to}: ${c.improved} improved, ${c.regressed} regressed, ${c.unchanged} unchanged`;
}

export function renderTrendMarkdown(trend) {
  const lines = [`# Trend: ${trend.slug}`, '', `Analytics: ${trend.analytics_dir}`, ''];
  lines.push('| Run | Rows | Iterations | US passed | First-pass rate | Pass | Fail | Split | Other | Duration (s) | Model upgrades | Malformed |');
  lines.push('|-----|------|------------|-----------|-----------------|------|------|-------|-------|--------------|----------------|-----------|');
  for (const run of trend.runs) {
    lines.push(
      `| ${run.label} | ${run.rows} | ${run.iterations} | ${run.us_passed}/${run.us_total} | ${cell(run.first_pass_rate)} | `
      + `${run.verdicts.pass} | ${run.verdicts.fail} | ${run.verdicts.split} | ${run.verdicts.other} | `
      + `${run.duration_total_s} | ${run.model_upgrades} | ${run.malformed} |`,
    );
  }
  lines.push('');
  if (trend.deltas.length > 0) {
    lines.push('## Deltas', '');
    lines.push('| From -> To | Iterations | First-pass rate | Fail | Duration (s) | Model upgrades | US passed |');
    lines.push('|------------|------------|-----------------|------|--------------|----------------|-----------|');
    for (const d of trend.deltas) {
      const v = d.verdicts;
      lines.push(
        `| ${d.from} -> ${d.to} | ${signed(d.iterations)} (${v.iterations}) | ${signed(d.first_pass_rate)} (${v.first_pass_rate}) | `
        + `${signed(d.fail)} (${v.fail}) | ${signed(d.duration_total_s)} (${v.duration_total_s}) | `
        + `${signed(d.model_upgrades)} (${v.model_upgrades}) | ${signed(d.us_passed)} (${v.us_passed}) |`,
      );
    }
    lines.push('');
  }
  lines.push('## Reading', '');
  lines.push('Direction rules: lower is better for iterations, fail, duration_total_s, model_upgrades; higher is better for first_pass_rate, us_passed; no change is unchanged.');
  if (trend.deltas.length > 0) {
    lines.push(`Newest vs previous (${describeDelta(trend.deltas[trend.deltas.length - 1])}).`);
    lines.push(`First vs last (${describeDelta(trend.first_vs_last)}).`);
  } else {
    lines.push('Need >= 2 runs for deltas.');
  }
  if (trend.warnings.length > 0) {
    lines.push('', '## Warnings', '');
    for (const warning of trend.warnings) lines.push(`- ${warning}`);
  }
  return `${lines.join('\n')}\n`;
}

function renderSummaryMarkdown(summary) {
  const lines = ['# Trend summary', '', '| Slug | Runs | Newest vs previous |', '|------|------|--------------------|'];
  for (const row of summary.slugs) {
    lines.push(`| ${row.slug} | ${row.run_count} | ${row.newest_vs_previous ? describeDelta(row.newest_vs_previous) : '-'} |`);
  }
  if (summary.warnings.length > 0) {
    lines.push('', '## Warnings', '');
    for (const warning of summary.warnings) lines.push(`- ${warning}`);
  }
  return `${lines.join('\n')}\n`;
}

function parseArgs(args) {
  const opts = { slug: null, json: false, last: null, out: null, dir: null, help: false };
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    const takeValue = () => {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      i += 1;
      return value;
    };
    if (token === '--help' || token === '-h') opts.help = true;
    else if (token === '--json') opts.json = true;
    else if (token === '--last') {
      const raw = takeValue();
      if (!/^[1-9]\d*$/u.test(raw)) throw new UsageError(`--last requires a positive integer, got ${JSON.stringify(raw)}`);
      opts.last = Number(raw);
    } else if (token === '--out') opts.out = takeValue();
    else if (token === '--dir') opts.dir = takeValue();
    else if (token.startsWith('-')) throw new UsageError(`unknown trend option: ${token}`);
    else if (opts.slug === null) opts.slug = token;
    else throw new UsageError(`unexpected extra argument: ${token}`);
  }
  return opts;
}

class UsageError extends Error {}

function emit(deps, text) {
  deps.stdout.write(text);
}

async function summarizeSlug(slug, dir, cwd) {
  const runs = await loadRuns(dir);
  return {
    slug,
    analytics_dir: displayDir(cwd, dir),
    run_count: runs.length,
    newest_vs_previous: runs.length >= 2 ? diffRuns(runs[runs.length - 2], runs[runs.length - 1]) : null,
  };
}

async function buildSummary(deps, opts, deskRoot) {
  const warnings = [];
  const slugs = [];
  if (opts.dir) {
    const dir = path.resolve(deps.cwd, opts.dir);
    const name = path.basename(dir).replace(/--[0-9a-f]{8}$/u, '');
    const row = await summarizeSlug(name, dir, deps.cwd);
    // An explicitly named directory with nothing in it is an error, like slug/discovery mode.
    if (row.run_count === 0) throw new Error(`no campaign*.jsonl files in ${displayDir(deps.cwd, dir)}`);
    slugs.push(row);
  } else {
    for (const slug of await discoverSlugs(deskRoot)) {
      try {
        const row = await summarizeSlug(slug, await resolveSlugDir(deskRoot, slug), deps.cwd);
        if (row.run_count === 0) warnings.push(`${slug}: no campaign*.jsonl files`);
        else slugs.push(row);
      } catch (error) {
        warnings.push(`${slug}: ${error.message}`);
      }
    }
  }
  if (slugs.length === 0) {
    throw new Error(`no analytics found under ${path.join(deskRoot, 'analytics')}${warnings.length ? ` (${warnings.join('; ')})` : ''}`);
  }
  return { schema: TREND_SCHEMA, slugs, warnings };
}

async function buildSlugTrend(deps, opts, deskRoot) {
  const slug = deps.requireCanonicalSlug(opts.slug); // IMP-08: reject, never normalize
  const dir = opts.dir ? path.resolve(deps.cwd, opts.dir) : await resolveSlugDir(deskRoot, slug);
  let runs = await loadRuns(dir);
  if (runs.length === 0) throw new Error(`no campaign*.jsonl files in ${displayDir(deps.cwd, dir)}`);
  if (opts.last !== null) runs = runs.slice(-opts.last);
  return buildTrend({ slug, analyticsDir: displayDir(deps.cwd, dir), runs });
}

export async function runCommand(args, deps) {
  let opts;
  try {
    opts = parseArgs(args);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    deps.stderr.write(`${error.message}\n${USAGE}\n`);
    return EXIT_USAGE;
  }
  if (opts.help) {
    emit(deps, `${USAGE}\n`);
    return 0;
  }

  // --out is validated before any work: it may never reach a .rlp-desk/plans (sealed test-spec lane).
  const outCtx = { baseDir: deps.cwd, deskBases: [deps.cwd], env: deps.env ?? process.env };
  if (opts.out) {
    try {
      await resolveGuardedOutPath(opts.out, outCtx);
    } catch (error) {
      if (!(error instanceof OutPathError)) throw error;
      deps.stderr.write(`${error.message}\n`);
      return EXIT_USAGE;
    }
  }

  const deskRoot = resolveDeskRoot(deps.cwd, deps.env ?? process.env);
  const isSummary = opts.slug === null;
  const result = isSummary
    ? await buildSummary(deps, opts, deskRoot)
    : await buildSlugTrend(deps, opts, deskRoot);

  let text;
  if (opts.json) text = `${JSON.stringify(result, null, 2)}\n`;
  else text = isSummary ? renderSummaryMarkdown(result) : renderTrendMarkdown(result);

  // Re-validated and committed via temp+rename, so a destination swapped to a symlink during the work above is never followed.
  if (opts.out) await writeGuardedOut(opts.out, text, outCtx, { createParent: false });
  emit(deps, text);
  return 0;
}
