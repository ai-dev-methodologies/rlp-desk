// D4 (TODO L58-59) - mutation tool wrappers + score collection.
//
// `mutation detect` tells the Leader (brainstorm) which mutation tools are really
// usable in the project; `mutation run` runs ONE of them over a scoped target and
// prints a single, tool-independent verdict document (schema rlp-desk.mutation/1)
// that the Verifier cites at Checkpoint 2 for CRITICAL US (governance 1c1/2).
// The wrapper never installs anything, never uses npx, and writes nothing except
// an optional --out file (refused inside <deskRoot>/plans, the PRD/test-spec lane).
//
// Every parser was built against a REAL capture in tests/fixtures/mutation/
// (Stryker 10.1.1, mutmut 3.8.0, go-mutesting 0.0.0-20261002081621-9ce5f731e321;
// facts in .omc/artifacts/backlog-2026-10-25/w2-fixtures.md).
//
// Status vocabulary -> uniform totals {killed, survived, timeout, no_coverage,
// ignored, errors, unknown}. "unknown" is anything the table below does not name:
// it is never killed, it stays in the score denominator, and it raises a warning.
//
//   Stryker (report.json files[f].mutants[].status; OBSERVED: Killed, Survived;
//   the rest follow Stryker's MutantStatus vocabulary and are covered by a
//   DERIVED fixture in the tests)
//     Killed -> killed            Survived -> survived       Timeout -> timeout
//     NoCoverage -> no_coverage   Ignored -> ignored
//     CompileError, RuntimeError -> errors (Stryker itself leaves these out of its score)
//     Pending (run interrupted) and anything else -> unknown
//
//   mutmut 3.x (`export-cicd-stats` keys; OBSERVED all keys; 0 values for the rare ones)
//     killed -> killed   survived -> survived   timeout -> timeout
//     no_tests -> no_coverage      skipped -> ignored
//     segfault -> errors           (the mutant crashed the test process: no test verdict)
//     suspicious -> unknown        (mutmut: neither a clean kill nor a survivor; not trusted)
//     check_was_interrupted_by_user -> unknown + status error "interrupted"
//   mutmut `results --all true` row text (OBSERVED: killed, survived, no tests, timeout)
//     killed, survived, timeout as above; "no tests" -> no_coverage; "skipped" -> ignored;
//     "segfault" -> errors; every other string (e.g. "suspicious", "not checked") -> unknown
//
//   go-mutesting (report.json stats; OBSERVED: killedCount, escapedCount; PASS in stdout
//   means the mutant was killed, FAIL means it escaped)
//     killedCount -> killed   escapedCount -> survived   timeOutCount -> timeout
//     notCoveredCount -> no_coverage   skippedCount -> ignored   errorCount -> errors
//     totalMutantsCount minus the sum of the above -> unknown
//
// Score = 100 * (killed + timeout) / (killed + timeout + survived + no_coverage + unknown),
// recomputed here from the totals (never the tool's headline number). ignored and errors
// are excluded and reported. Denominator 0 is "no_mutants" (exit 2), never a pass.
// The threshold is compared on the exact ratio, not on the 2-decimal display value.
//
// Exit codes: 0 score >= --min-score, 1 below, 2 cannot judge (tool absent / error /
// timeout / unparseable / no mutants), 64 usage. Governance maps 2 to FAIL
// MUT-GATE-UNMET: a configured gate that cannot run is not a pass.
//
// Invoked as `node ~/.claude/ralph-desk/node/run.mjs mutation <detect|run> ...`.

import fs from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';

import { OutPathError, resolveGuardedOutPath, writeGuardedOut } from '../util/out-path-guard.mjs';

export const MUTATION_SCHEMA = 'rlp-desk.mutation/1';
export const DETECT_SCHEMA = 'rlp-desk.mutation-detect/1';
const TOOLS = ['go-mutesting', 'mutmut', 'stryker']; // sorted: detect output order
const EXIT_USAGE = 64;
const DEFAULT_MIN_SCORE = 60; // project default of the test-spec template
const DEFAULT_TIMEOUT_S = 900;
const SURVIVOR_CAP = 20;
const OUTPUT_CAP_BYTES = 32 * 1024 * 1024;
const DEFAULT_KILL_GRACE_MS = 5000;
const STRYKER_REPORT_REL = path.join('reports', 'mutation', 'mutation.json');
const MUTMUT_STATS_REL = path.join('mutants', 'mutmut-cicd-stats.json');
const GO_REPORT_NAME = 'report.json';

const USAGE = [
  'Usage: node src/node/run.mjs mutation <detect|run> [options]',
  '',
  '  detect [--project-dir DIR] [--json] [--print-snippet]',
  '      List mutation tools (go-mutesting, mutmut, stryker): present or tool_absent.',
  '      Exit 0 if any is present, 2 if none. Run it in brainstorm BEFORE the test-spec',
  '      "Tool:" line names a tool; --print-snippet prints the paste-ready lines.',
  '',
  '  run --tool <go-mutesting|mutmut|stryker> --target <path-or-glob> [--min-score N]',
  '      [--timeout SECONDS] [--project-dir DIR] [--out FILE] [--json] [-- <extra tool args>]',
  '      Run one tool over --target (required; never the whole repo by default) and score it.',
  `      --min-score defaults to ${DEFAULT_MIN_SCORE}, --timeout to ${DEFAULT_TIMEOUT_S} s. Prints one document`,
  `      (schema ${MUTATION_SCHEMA}) with --json, else a summary whose first line is the`,
  '      evidence string: mutation:<tool> score=<n> min=<m> total=<t> ignored=<i>.',
  '      Passthrough after -- is restricted (exit 64 otherwise): options that change the scope, report',
  '      or kill decision are refused; allowed: stryker --disableBail --concurrency/-c --maxConcurrentTestRunners',
  '      --maxTestRunnerReuse --logLevel --fileLogLevel --allowConsoleColors --cleanTempDir --coverageAnalysis;',
  '      mutmut --max-children; go-mutesting --verbose --debug.',
  '',
  'Exit codes: 0 score >= min | 1 score below min | 2 cannot judge (tool absent, error,',
  '            timeout, unparseable, no mutants; governance: FAIL MUT-GATE-UNMET) | 64 usage.',
].join('\n');

class UsageError extends Error {}

export class ParseError extends Error {
  constructor(message) {
    super(`unparseable: ${message}`);
    this.name = 'ParseError';
  }
}

// --------------------------------------------------------------------- score

const round2 = (x) => Math.round(x * 100) / 100;

export function computeScore(totals) {
  const numerator = totals.killed + totals.timeout;
  const denominator = numerator + totals.survived + totals.no_coverage + totals.unknown;
  return {
    numerator,
    denominator,
    score: denominator === 0 ? null : round2((100 * numerator) / denominator),
    meets: (min) => denominator > 0 && 100 * numerator >= min * denominator,
  };
}

function makeTotals(parts, declaredTotal, warnings, label) {
  const totals = {
    killed: 0, survived: 0, timeout: 0, no_coverage: 0, ignored: 0, errors: 0, unknown: 0, total: 0,
    ...parts,
  };
  const accounted = totals.killed + totals.survived + totals.timeout + totals.no_coverage
    + totals.ignored + totals.errors + totals.unknown;
  if (declaredTotal === undefined || declaredTotal === accounted) {
    totals.total = accounted;
  } else if (declaredTotal > accounted) {
    const gap = declaredTotal - accounted;
    totals.unknown += gap;
    totals.total = declaredTotal;
    warnings.push(`${label}: total ${declaredTotal} exceeds the ${accounted} mutants its statuses account for; ${gap} counted as unknown`);
  } else {
    totals.total = accounted;
    warnings.push(`${label}: total ${declaredTotal} is below the ${accounted} mutants its statuses account for; using ${accounted}`);
  }
  return totals;
}

function compareNullable(a, b) {
  if (a === b) return 0;
  if (a === null || a === undefined) return 1;
  if (b === null || b === undefined) return -1;
  return a < b ? -1 : 1;
}

function sortSurvivors(list) {
  return [...list].sort((a, b) => compareNullable(a.file, b.file)
    || compareNullable(a.line, b.line)
    || compareNullable(a.mutator, b.mutator)
    || compareNullable(a.id, b.id));
}

function parseJsonObject(input, what) {
  let value = input;
  if (typeof input === 'string') {
    try { value = JSON.parse(input); } catch (error) { throw new ParseError(`${what} is not valid JSON (${error.message})`); }
  }
  if (value === null || typeof value !== 'object' || Array.isArray(value)) {
    throw new ParseError(`${what} is not a JSON object`);
  }
  return value;
}

const isCount = (v) => Number.isInteger(v) && v >= 0;

// ------------------------------------------------------------------- Stryker

const STRYKER_STATUS = {
  Killed: 'killed',
  Survived: 'survived',
  Timeout: 'timeout',
  NoCoverage: 'no_coverage',
  Ignored: 'ignored',
  CompileError: 'errors',
  RuntimeError: 'errors',
};
const STRYKER_UNDETECTED = new Set(['Survived', 'NoCoverage']);

export function parseStrykerReport(input) {
  const report = parseJsonObject(input, 'Stryker report');
  if (report.files === null || typeof report.files !== 'object' || Array.isArray(report.files)) {
    throw new ParseError('Stryker report has no "files" object');
  }
  const warnings = [];
  const parts = {};
  const unknownStatuses = new Map();
  const survivors = [];
  const mutatedFiles = [];
  for (const file of Object.keys(report.files).sort()) {
    const mutants = report.files[file]?.mutants;
    if (!Array.isArray(mutants)) throw new ParseError(`Stryker report file ${JSON.stringify(file)} has no "mutants" array`);
    if (mutants.length > 0) mutatedFiles.push(file);
    for (const mutant of mutants) {
      const status = mutant?.status;
      if (typeof status !== 'string') throw new ParseError(`a mutant in ${JSON.stringify(file)} has no status`);
      const bucket = STRYKER_STATUS[status];
      if (bucket === undefined) {
        parts.unknown = (parts.unknown ?? 0) + 1;
        unknownStatuses.set(status, (unknownStatuses.get(status) ?? 0) + 1);
      } else {
        parts[bucket] = (parts[bucket] ?? 0) + 1;
      }
      if (STRYKER_UNDETECTED.has(status)) {
        const line = mutant.location?.start?.line;
        survivors.push({
          file,
          line: Number.isInteger(line) ? line : null,
          mutator: typeof mutant.mutatorName === 'string' ? mutant.mutatorName : null,
          id: mutant.id === undefined ? null : String(mutant.id),
        });
      }
    }
  }
  for (const [status, count] of [...unknownStatuses].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    warnings.push(`Stryker status ${JSON.stringify(status)} (${count} mutant${count === 1 ? '' : 's'}) is not recognised: counted as unknown, not killed`);
  }
  const schemaVersion = report.schemaVersion;
  if (typeof schemaVersion === 'string' && !schemaVersion.startsWith('1.')) {
    warnings.push(`Stryker report schemaVersion ${JSON.stringify(schemaVersion)} is not 1.x; parsed as 1.x`);
  }
  const version = report.framework?.version;
  return {
    totals: makeTotals(parts, undefined, warnings, 'stryker'),
    survivors: sortSurvivors(survivors),
    toolVersion: typeof version === 'string' ? version : null,
    files: mutatedFiles,
    warnings,
  };
}

// ---- --target scope check (Stryker): every file the report mutated must be inside --target.
// --target uses Stryker --mutate syntax: comma-separated globs (** * ? {a,b}), "!" negations
// (ignored: they only remove files), a ":l:c-l:c" mutation range suffix. A pattern without
// glob characters also matches everything below it as a directory prefix (superset on
// purpose: this is an integrity check, not Stryker's file selection).
function splitTopLevel(text) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === '{') depth += 1;
    else if (text[i] === '}') depth = Math.max(0, depth - 1);
    else if (text[i] === ',' && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
  }
  parts.push(text.slice(start));
  return parts;
}

const escapeRe = (c) => c.replace(/[.+^${}()|[\]\\*?]/gu, '\\$&');

function matchingClose(text, open, openChar, closeChar) {
  let depth = 0;
  for (let i = open; i < text.length; i += 1) {
    if (text[i] === '\\') { i += 1; continue; }
    if (text[i] === openChar) depth += 1;
    else if (text[i] === closeChar) { depth -= 1; if (depth === 0) return i; }
  }
  return -1;
}

function splitAt(text, sep) {
  const parts = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < text.length; i += 1) {
    if (text[i] === '\\') i += 1;
    else if (text[i] === '{' || text[i] === '(') depth += 1;
    else if (text[i] === '}' || text[i] === ')') depth = Math.max(0, depth - 1);
    else if (text[i] === sep && depth === 0) { parts.push(text.slice(start, i)); start = i + 1; }
  }
  parts.push(text.slice(start));
  return parts;
}

// Glob -> regex source. Supported: ** * ? [abc] [a-z] [!a], {a,b}, extglobs @(a|b) ?(a) +(a|b) *(a),
// backslash escapes. !(a|b) is approximated by "any text in the segment" (a deliberate superset).
function globSource(glob) {
  let out = '';
  for (let i = 0; i < glob.length; i += 1) {
    const c = glob[i];
    if (c === '\\' && i + 1 < glob.length) { i += 1; out += escapeRe(glob[i]); continue; }
    if ('@?+*!'.includes(c) && glob[i + 1] === '(') {
      const end = matchingClose(glob, i + 1, '(', ')');
      if (end !== -1) {
        const alts = splitAt(glob.slice(i + 2, end), '|').map(globSource).join('|');
        out += c === '!' ? '[^/]*' : `(?:${alts})${{ '@': '', '?': '?', '+': '+', '*': '*' }[c]}`;
        i = end;
        continue;
      }
    }
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i += 1;
        if (glob[i + 1] === '/') { i += 1; out += '(?:.*/)?'; } else out += '.*';
      } else out += '[^/]*';
    } else if (c === '?') out += '[^/]';
    else if (c === '[') {
      const end = glob.indexOf(']', i + 2);
      if (end === -1) out += '\\[';
      else {
        let body = glob.slice(i + 1, end).replace(/\\/gu, '\\\\');
        if (body[0] === '!' || body[0] === '^') body = `^${body.slice(1)}`;
        out += `[${body}]`;
        i = end;
      }
    } else if (c === '{') {
      const end = matchingClose(glob, i, '{', '}');
      const alts = end === -1 ? [] : splitAt(glob.slice(i + 1, end), ',');
      if (alts.length > 1) { out += `(?:${alts.map(globSource).join('|')})`; i = end; } else out += '\\{';
    } else out += escapeRe(c);
  }
  return out;
}

function strykerGlobToRegExp(glob) {
  try { return new RegExp(`^${globSource(glob)}$`, 'u'); } catch { return null; }
}

export function filesOutsideTarget(files, target, projectDir) {
  const matchers = splitTopLevel(target).map((raw) => raw.trim()).filter((p) => p !== '' && !p.startsWith('!')).map((raw) => {
    let p = raw.replace(/:\d+(?::\d+)?-\d+(?::\d+)?$/u, '');
    // an absolute pattern is compared project-relative (outside the project it matches nothing)
    if (path.isAbsolute(p)) {
      const rel = path.relative(projectDir, p).split(path.sep).join('/');
      p = rel === '..' || rel.startsWith('../') ? '\u0000outside-project' : rel;
    }
    p = p.replace(/^\.\//u, '').replace(/\/+$/u, '');
    if (!/[*?{[]|[@+!]\(/u.test(p)) return (file) => file === p || file.startsWith(`${p}/`);
    const re = strykerGlobToRegExp(p);
    return re === null ? (file) => file === p : (file) => re.test(file);
  });
  return files.filter((file) => {
    const rel = path.isAbsolute(file) ? path.relative(projectDir, file) : file;
    const norm = rel.split(path.sep).join('/').replace(/^\.\//u, '');
    return !matchers.some((match) => match(norm));
  });
}

// -------------------------------------------------------------------- mutmut

export function parseMutmutCicdStats(input) {
  const stats = parseJsonObject(input, 'mutmut cicd stats');
  for (const key of ['killed', 'survived', 'total']) {
    if (!isCount(stats[key])) throw new ParseError(`mutmut cicd stats lack a non-negative integer "${key}"`);
  }
  const optional = (key) => {
    if (stats[key] === undefined) return 0;
    if (!isCount(stats[key])) throw new ParseError(`mutmut cicd stats "${key}" is not a non-negative integer`);
    return stats[key];
  };
  const interrupted = optional('check_was_interrupted_by_user');
  const suspicious = optional('suspicious');
  const warnings = [];
  if (suspicious > 0) {
    warnings.push(`mutmut reported ${suspicious} suspicious mutant${suspicious === 1 ? '' : 's'}: counted as unknown, not killed`);
  }
  const totals = makeTotals({
    killed: stats.killed,
    survived: stats.survived,
    timeout: optional('timeout'),
    no_coverage: optional('no_tests'),
    ignored: optional('skipped'),
    errors: optional('segfault'),
    unknown: suspicious + interrupted,
  }, stats.total, warnings, 'mutmut');
  return { totals, interrupted, warnings };
}

export function parseMutmutResults(text) {
  const rows = [];
  let skipped = 0;
  for (const line of String(text).split(/\r?\n/u)) {
    if (line.trim() === '') continue;
    const m = /^\s+(\S+): (.+?)\s*$/u.exec(line);
    if (m) rows.push({ id: m[1], status: m[2] });
    else skipped += 1;
  }
  Object.defineProperty(rows, 'skippedLines', { value: skipped, enumerable: false });
  return rows;
}

const MUTMUT_ROW_STATUS = {
  killed: 'killed',
  survived: 'survived',
  timeout: 'timeout',
  'no tests': 'no_coverage',
  skipped: 'ignored',
  segfault: 'errors',
};
const MUTMUT_UNDETECTED = new Set(['survived', 'no tests']);

export function totalsFromMutmutRows(rows) {
  const parts = {};
  const warnings = [];
  const seenUnknown = new Map();
  for (const row of rows) {
    const bucket = MUTMUT_ROW_STATUS[row.status];
    if (bucket === undefined) {
      parts.unknown = (parts.unknown ?? 0) + 1;
      seenUnknown.set(row.status, (seenUnknown.get(row.status) ?? 0) + 1);
    } else {
      parts[bucket] = (parts[bucket] ?? 0) + 1;
    }
  }
  for (const [status, count] of [...seenUnknown].sort((a, b) => (a[0] < b[0] ? -1 : 1))) {
    warnings.push(`mutmut status ${JSON.stringify(status)} (${count} mutant${count === 1 ? '' : 's'}) is not recognised: counted as unknown, not killed`);
  }
  return { totals: makeTotals(parts, undefined, warnings, 'mutmut'), warnings };
}

// `--target` for mutmut 3.x is a mutant-name glob (it has no path argument):
// "pkg/mod.py" -> "pkg.mod.*", "pkg" -> "pkg.*", a value with glob characters or a
// full mutant id is passed through.
export function mutmutGlob(target) {
  let t = target.trim();
  if (t === '' || t === '.' || t === './') return '*';
  if (t.includes('/') || t.endsWith('.py')) {
    t = t.replace(/^\.\//u, '').replace(/\/+$/u, '').replace(/\.py$/u, '').replace(/\/__init__$/u, '').replace(/\//gu, '.');
    return t === '' ? '*' : `${t}.*`;
  }
  if (/[*?[]/u.test(t) || t.includes('__mutmut_')) return t;
  return `${t}.*`;
}

// fnmatch subset (what mutmut filters with): * and ? only; ceiling: [seq] is literal.
function globToRegExp(glob) {
  const body = glob.replace(/[.+^${}()|[\]\\]/gu, '\\$&').replace(/\*/gu, '.*').replace(/\?/gu, '.');
  return new RegExp(`^${body}$`, 'u');
}

// -------------------------------------------------------------- go-mutesting

export function parseGoMutestingReport(input) {
  const report = parseJsonObject(input, 'go-mutesting report');
  const stats = report.stats;
  if (stats === null || typeof stats !== 'object') throw new ParseError('go-mutesting report has no "stats" object');
  for (const key of ['totalMutantsCount', 'killedCount', 'escapedCount']) {
    if (!isCount(stats[key])) throw new ParseError(`go-mutesting stats lack a non-negative integer "${key}"`);
  }
  const optional = (key) => {
    if (stats[key] === undefined) return 0;
    if (!isCount(stats[key])) throw new ParseError(`go-mutesting stats "${key}" is not a non-negative integer`);
    return stats[key];
  };
  const warnings = [];
  const totals = makeTotals({
    killed: stats.killedCount,
    survived: stats.escapedCount,
    timeout: optional('timeOutCount'),
    no_coverage: optional('notCoveredCount'),
    ignored: optional('skippedCount'),
    errors: optional('errorCount'),
  }, stats.totalMutantsCount, warnings, 'go-mutesting');
  const escaped = Array.isArray(report.escaped) ? report.escaped : [];
  if (escaped.length !== stats.escapedCount) {
    warnings.push(`go-mutesting: stats.escapedCount is ${stats.escapedCount} but escaped[] lists ${escaped.length}`);
  }
  const survivors = escaped.map((entry) => {
    const m = entry?.mutator ?? {};
    return {
      file: typeof m.originalFilePath === 'string' ? m.originalFilePath : null,
      line: Number.isInteger(m.originalStartLine) ? m.originalStartLine : null,
      mutator: typeof m.mutatorName === 'string' ? m.mutatorName : null,
      id: null,
    };
  });
  return { totals, survivors: sortSurvivors(survivors), toolVersion: null, warnings };
}

// ---------------------------------------------------------- binary resolution

async function isExecutable(file) {
  try {
    const st = await fs.stat(file);
    if (!st.isFile()) return false;
    await fs.access(file, fsConstants.X_OK);
    return true;
  } catch {
    return false;
  }
}

async function firstExecutable(candidates) {
  for (const candidate of candidates) {
    if (await isExecutable(candidate)) return candidate;
  }
  return null;
}

function pathCandidates(name, env) {
  return String(env.PATH ?? '').split(path.delimiter).filter(Boolean).map((dir) => path.join(dir, name));
}

function localCandidates(tool, projectDir, env) {
  if (tool === 'stryker') return [path.join(projectDir, 'node_modules', '.bin', 'stryker')];
  if (tool === 'mutmut') return [path.join(projectDir, '.venv', 'bin', 'mutmut')];
  const out = [];
  if (env.GOBIN) out.push(path.join(env.GOBIN, 'go-mutesting'));
  const gopaths = env.GOPATH ? String(env.GOPATH).split(path.delimiter).filter(Boolean)
    : (env.HOME ? [path.join(env.HOME, 'go')] : []);
  for (const gopath of gopaths) out.push(path.join(gopath, 'bin', 'go-mutesting'));
  return out;
}

async function resolveBinary(tool, projectDir, env) {
  const found = await firstExecutable([...localCandidates(tool, projectDir, env), ...pathCandidates(tool, env)]);
  if (found === null) return { binary: null, display: null };
  const rel = path.relative(projectDir, found);
  const display = rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel : found;
  return { binary: found, display };
}

async function readTextIfExists(file) {
  try { return await fs.readFile(file, 'utf8'); } catch { return null; }
}

// ------------------------------------------------------------------- detect

async function declaredIn(tool, projectDir) {
  if (tool === 'stryker') {
    const text = await readTextIfExists(path.join(projectDir, 'package.json'));
    if (text === null) return { declared: false, where: 'package.json' };
    try {
      const pkg = JSON.parse(text);
      const has = ['dependencies', 'devDependencies', 'optionalDependencies']
        .some((k) => pkg?.[k] && typeof pkg[k] === 'object' && '@stryker-mutator/core' in pkg[k]);
      return { declared: has, where: 'package.json' };
    } catch {
      return { declared: false, where: 'package.json (unreadable)' };
    }
  }
  if (tool === 'mutmut') {
    let names = ['pyproject.toml', 'setup.cfg'];
    try {
      const entries = await fs.readdir(projectDir);
      names = names.concat(entries.filter((n) => /^requirements.*\.txt$/u.test(n)).sort());
    } catch { /* unreadable dir: only the fixed names */ }
    for (const name of names) {
      const text = await readTextIfExists(path.join(projectDir, name));
      if (text !== null && /(^|[^\w-])mutmut($|[^\w-])/mu.test(text)) return { declared: true, where: name };
    }
    return { declared: false, where: 'pyproject.toml/setup.cfg/requirements*.txt' };
  }
  const hasMod = (await readTextIfExists(path.join(projectDir, 'go.mod'))) !== null;
  return { declared: hasMod, where: 'go.mod' };
}

function snippetFor(tool) {
  return [
    `- Tool: ${tool}`,
    `- Target: >= ${DEFAULT_MIN_SCORE}% mutation score on core business logic (project default; override in PRD if justified)`,
    '- Command:',
    '```bash',
    `node ~/.claude/ralph-desk/node/run.mjs mutation run --tool ${tool} --target "<core business logic files>" --min-score ${DEFAULT_MIN_SCORE} --json`,
    '```',
  ].join('\n');
}

async function runDetect(args, deps) {
  const opts = parseOptions(args, { bool: ['--json', '--print-snippet'], value: ['--project-dir'] });
  if (opts.help) { emit(deps, USAGE); return 0; }
  if (opts.positional.length > 0) throw new UsageError(`unexpected argument: ${opts.positional[0]}`);
  const projectDir = path.resolve(deps.cwd, opts.flags['project-dir'] ?? '.');
  const env = deps.env ?? process.env;
  const candidates = [];
  for (const tool of TOOLS) {
    const { declared, where } = await declaredIn(tool, projectDir);
    const { binary, display } = await resolveBinary(tool, projectDir, env);
    const present = binary !== null && (tool !== 'go-mutesting' || declared);
    const evidence = tool === 'go-mutesting'
      ? `${declared ? 'go.mod present' : 'go.mod missing'}; ${binary ? `binary ${display}` : 'binary not found'}`
      : `${declared ? `declared in ${where}` : `not declared in ${where}`}; ${binary ? `binary ${display}` : 'binary not found'}`;
    const candidate = { tool, status: present ? 'present' : 'tool_absent', binary: display, evidence };
    if (opts.flags['print-snippet'] && present) candidate.snippet = snippetFor(tool);
    candidates.push(candidate);
  }
  const anyPresent = candidates.some((c) => c.status === 'present');
  if (opts.flags.json) {
    emit(deps, JSON.stringify({ schema: DETECT_SCHEMA, candidates }, null, 2));
  } else if (opts.flags['print-snippet']) {
    const snippets = candidates.filter((c) => c.snippet).map((c) => c.snippet);
    emit(deps, snippets.length > 0 ? snippets.join('\n\n')
      : 'no mutation tool is present: leave the test-spec "Tool:" line as N/A with owner approval (do not name a tool that cannot run)');
  } else {
    emit(deps, candidates.map((c) => `${c.tool.padEnd(13)} ${c.status.padEnd(11)} ${c.evidence}`).join('\n'));
  }
  return anyPresent ? 0 : 2;
}

// ------------------------------------------------------------- process seam

// Default exec seam: spawn without a shell in its own process group, capture
// stdout/stderr (capped), and on timeout SIGTERM then SIGKILL the whole group so
// the tool's worker processes die with it. Tests inject nothing here: they use
// real stub executables.
function spawnCapture({ command, args, cwd, env, timeoutMs, killGraceMs }) {
  return new Promise((resolve) => {
    let child;
    try {
      child = spawn(command, args, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    } catch (error) {
      resolve({ code: null, signal: null, stdout: '', stderr: '', timedOut: false, truncated: false, spawnError: error.message });
      return;
    }
    const chunks = { out: [], err: [] };
    const bytes = { out: 0, err: 0 };
    let truncated = false;
    const collect = (kind) => (chunk) => {
      if (bytes[kind] + chunk.length > OUTPUT_CAP_BYTES) { truncated = true; return; }
      bytes[kind] += chunk.length;
      chunks[kind].push(chunk);
    };
    child.stdout.on('data', collect('out'));
    child.stderr.on('data', collect('err'));
    let timedOut = false;
    let settled = false;
    const timers = [];
    const killGroup = (signal) => {
      try { process.kill(-child.pid, signal); } catch { /* group already gone */ }
    };
    const finish = (code, signal, spawnError) => {
      if (settled) return;
      settled = true;
      timers.forEach(clearTimeout);
      resolve({
        code, signal, timedOut, truncated, spawnError,
        stdout: Buffer.concat(chunks.out).toString('utf8'),
        stderr: Buffer.concat(chunks.err).toString('utf8'),
      });
    };
    child.on('error', (error) => finish(null, null, error.message));
    child.on('close', (code, signal) => finish(code, signal));
    child.on('exit', (code, signal) => {
      // A grandchild holding the pipes open must not wedge us after the tool exits.
      timers.push(setTimeout(() => finish(code, signal), 2000));
    });
    timers.push(setTimeout(() => {
      timedOut = true;
      killGroup('SIGTERM');
      timers.push(setTimeout(() => {
        killGroup('SIGKILL');
        timers.push(setTimeout(() => finish(null, 'SIGKILL'), 1000));
      }, killGraceMs));
    }, timeoutMs));
  });
}

function outputTail(res) {
  const clean = (s) => s.replace(/\u001b\[[0-9;?]*[A-Za-z]/gu, '').split(/[\r\n]+/u).map((l) => l.trim()).filter(Boolean);
  const lines = [...clean(res.stdout ?? ''), ...clean(res.stderr ?? '')].slice(-6);
  return lines.join(' | ').slice(0, 600);
}

async function statOrNull(file) {
  try {
    const st = await fs.stat(file);
    return { mtimeMs: st.mtimeMs, size: st.size };
  } catch {
    return null;
  }
}

const isFresh = (before, after) => after !== null && (before === null || before.mtimeMs !== after.mtimeMs || before.size !== after.size);

// ------------------------------------------------------------------ run core

// Each runner returns { status, reason, detail, parsed?, warnings }.
function failure(status, reason, detail = null, extra = {}) {
  return { status, reason, detail, parsed: null, warnings: [], ...extra };
}

function stepFailure(res, label) {
  if (res.spawnError) return failure('error', 'spawn_failed', `${label}: ${res.spawnError}`);
  if (res.timedOut) return failure('timeout', 'timeout', `${label} exceeded the time limit`);
  if (res.truncated) return failure('error', 'output_truncated', `${label}: output exceeded ${OUTPUT_CAP_BYTES} bytes`);
  return null;
}

// B-C3-02: Stryker writes the report with a plain writeFile, which follows symlinks. Neither the report
// file nor reports/ or reports/mutation may be a symlink (nor the file a non-regular entry), before the
// run (it would write through into e.g. plans/) and after it (it would be read through).
// R4-03: a hard link (nlink > 1) shares its inode with another name, so writing the report in place would
// truncate that other file as well; refused like a symlink.
async function unsafeReportPath(projectDir, rel = STRYKER_REPORT_REL) {
  let current = projectDir;
  const parts = rel.split(path.sep);
  for (let i = 0; i < parts.length; i += 1) {
    current = path.join(current, parts[i]);
    const st = await fs.lstat(current).catch(() => null);
    if (st === null) return null; // nothing deeper exists yet
    const last = i === parts.length - 1;
    if (st.isSymbolicLink()) return `${path.relative(projectDir, current)} is a symlink`;
    if (last ? !st.isFile() : !st.isDirectory()) return `${path.relative(projectDir, current)} is not a ${last ? 'regular file' : 'directory'}`;
    if (last && st.nlink > 1) return `${path.relative(projectDir, current)} is a hard link (${st.nlink} names for one file)`;
  }
  return null;
}

async function runStryker(ctx) {
  const reportPath = path.join(ctx.projectDir, STRYKER_REPORT_REL);
  const unsafeBefore = await unsafeReportPath(ctx.projectDir);
  if (unsafeBefore) return failure('error', 'report_path_unsafe', `${unsafeBefore}; stryker would write its report through it (remove it, then re-run)`);
  const before = await statOrNull(reportPath);
  const res = await ctx.exec(ctx.binary, ['run', '--reporters', 'json', '--mutate', ctx.target, ...ctx.extra]);
  const bad = stepFailure(res, 'stryker');
  if (bad) return bad;
  const unsafeAfter = await unsafeReportPath(ctx.projectDir);
  if (unsafeAfter) return failure('error', 'report_path_unsafe', `${unsafeAfter} after the run; the report is not read`);
  const after = await statOrNull(reportPath);
  if (!isFresh(before, after)) {
    return res.code !== 0
      ? failure('error', 'tool_failed', `stryker exited ${res.code} without writing ${STRYKER_REPORT_REL}: ${outputTail(res)}`)
      : failure('error', 'report_missing', `stryker did not write a fresh ${STRYKER_REPORT_REL} (a custom jsonReporter.fileName is not supported)`);
  }
  const text = await readTextIfExists(reportPath);
  let parsed;
  try { parsed = parseStrykerReport(text ?? ''); } catch (error) {
    if (error instanceof ParseError) return failure('error', 'unparseable', error.message);
    throw error;
  }
  const outside = filesOutsideTarget(parsed.files, ctx.target, ctx.projectDir);
  if (outside.length > 0) {
    return failure('error', 'scope_mismatch', `the report mutated ${outside.length} file${outside.length === 1 ? '' : 's'} outside --target ${JSON.stringify(ctx.target)}: ${outside.slice(0, 5).join(', ')}`);
  }
  const warnings = [...parsed.warnings];
  if (res.code !== 0) warnings.push(`stryker exited ${res.code}; scored from the complete report it wrote`);
  return { status: 'ok', reason: null, detail: null, parsed, warnings };
}

async function runMutmut(ctx) {
  const glob = mutmutGlob(ctx.target);
  const runRes = await ctx.exec(ctx.binary, ['run', glob, ...ctx.extra]);
  let bad = stepFailure(runRes, 'mutmut run');
  if (bad) return bad;
  if (runRes.code !== 0) return failure('error', 'tool_failed', `mutmut run exited ${runRes.code}: ${outputTail(runRes)}`);

  const resultsRes = await ctx.exec(ctx.binary, ['results', '--all', 'true']);
  bad = stepFailure(resultsRes, 'mutmut results');
  if (bad) return bad;
  if (resultsRes.code !== 0) return failure('error', 'tool_failed', `mutmut results exited ${resultsRes.code}: ${outputTail(resultsRes)}`);
  const rows = parseMutmutResults(resultsRes.stdout);

  const unsafeStats = await unsafeReportPath(ctx.projectDir, MUTMUT_STATS_REL);
  if (unsafeStats) return failure('error', 'report_path_unsafe', `${unsafeStats}; mutmut export-cicd-stats would write through it (remove it, then re-run)`);
  const statsBefore = await statOrNull(path.join(ctx.projectDir, MUTMUT_STATS_REL));
  const exportRes = await ctx.exec(ctx.binary, ['export-cicd-stats']);
  bad = stepFailure(exportRes, 'mutmut export-cicd-stats');
  if (bad) return bad;
  if (exportRes.code !== 0) return failure('error', 'tool_failed', `mutmut export-cicd-stats exited ${exportRes.code}: ${outputTail(exportRes)}`);
  let statsPath = path.join(ctx.projectDir, MUTMUT_STATS_REL);
  const named = /Saved CI\/CD stats to (\S+)/u.exec(exportRes.stdout);
  if (named) {
    const candidate = path.resolve(ctx.projectDir, named[1]);
    const rel = path.relative(ctx.projectDir, candidate);
    if (rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel)) statsPath = candidate;
  }
  const statsBeforeNamed = statsPath === path.join(ctx.projectDir, MUTMUT_STATS_REL) ? statsBefore : null;
  const unsafeStatsAfter = await unsafeReportPath(ctx.projectDir, path.relative(ctx.projectDir, statsPath));
  if (unsafeStatsAfter) return failure('error', 'report_path_unsafe', `${unsafeStatsAfter} after export-cicd-stats; the stats are not read`);
  if (!isFresh(statsBeforeNamed, await statOrNull(statsPath))) {
    return failure('error', 'report_missing', `mutmut export-cicd-stats did not write a fresh ${path.relative(ctx.projectDir, statsPath)}`);
  }

  let cicd;
  try { cicd = parseMutmutCicdStats((await readTextIfExists(statsPath)) ?? ''); } catch (error) {
    if (error instanceof ParseError) return failure('error', 'unparseable', error.message);
    throw error;
  }
  const interruptedMessage = 'mutmut reports mutants whose check was interrupted by the user; the run is incomplete';
  if (cicd.interrupted > 0) return failure('error', 'interrupted', interruptedMessage);
  // Fail closed (B-C1-03): a results line that does not parse, or results that do not
  // cover exactly the mutants export-cicd-stats counts, is never read as "narrower target".
  if (rows.skippedLines > 0) {
    return failure('error', 'unparseable', `unparseable: mutmut results has ${rows.skippedLines} line${rows.skippedLines === 1 ? '' : 's'} that are not "<mutant>: <status>" rows`);
  }
  if (rows.length !== cicd.totals.total) {
    return failure('error', 'unparseable', `unparseable: mutmut results lists ${rows.length} mutants but export-cicd-stats counts ${cicd.totals.total}`);
  }
  const matcher = globToRegExp(glob);
  const matched = rows.filter((row) => matcher.test(row.id));
  const warnings = [...cicd.warnings];
  if (matched.some((row) => /interrupted/u.test(row.status))) return failure('error', 'interrupted', interruptedMessage);

  let totals;
  if (matched.length === rows.length) {
    totals = cicd.totals;
    const fromRows = totalsFromMutmutRows(matched).totals;
    if (JSON.stringify(fromRows) !== JSON.stringify(cicd.totals)) {
      warnings.push('mutmut: per-mutant results disagree with export-cicd-stats; using export-cicd-stats');
    }
  } else {
    const fromRows = totalsFromMutmutRows(matched);
    totals = fromRows.totals;
    warnings.length = 0;
    warnings.push(...fromRows.warnings);
    warnings.push(`mutmut: the target is narrower than mutants/ (it covers ${matched.length} of the ${rows.length} mutants; export-cicd-stats is project-wide); scored from the ${matched.length} matching results rows`);
  }
  const survivors = sortSurvivors(matched
    .filter((row) => MUTMUT_UNDETECTED.has(row.status))
    .map((row) => ({ file: null, line: null, mutator: null, id: row.id })));
  return { status: 'ok', reason: null, detail: null, parsed: { totals, survivors, toolVersion: null, warnings: [] }, warnings };
}

async function runGoMutesting(ctx) {
  const reportPath = path.join(ctx.projectDir, GO_REPORT_NAME);
  // go-mutesting writes report.json into its cwd. If one already exists it is the
  // user's file: refuse instead of overwriting it or deleting it afterwards.
  // lstat, not stat: a dangling symlink counts as "exists" (the tool would write through it).
  if (await fs.lstat(reportPath).then(() => true, () => false)) {
    return failure('error', 'report_json_exists', `${GO_REPORT_NAME} already exists in the project directory (any entry, including a symlink); go-mutesting would overwrite it (move or delete it, then re-run)`);
  }
  let res;
  let text = null;
  try {
    res = await ctx.exec(ctx.binary, [ctx.target, ...ctx.extra]);
    // Only a regular file the tool wrote is read; a symlink planted during the run is not followed.
    const made = await fs.lstat(reportPath).catch(() => null);
    text = made?.isFile() ? await readTextIfExists(reportPath) : null;
  } finally {
    await fs.rm(reportPath, { force: true });
  }
  const bad = stepFailure(res, 'go-mutesting');
  if (bad) return bad;
  if (text === null) {
    return res.code !== 0
      ? failure('error', 'tool_failed', `go-mutesting exited ${res.code} without writing ${GO_REPORT_NAME}: ${outputTail(res)}`)
      : failure('error', 'report_missing', `go-mutesting did not write ${GO_REPORT_NAME}: ${outputTail(res)}`);
  }
  let parsed;
  try { parsed = parseGoMutestingReport(text); } catch (error) {
    if (error instanceof ParseError) return failure('error', 'unparseable', error.message);
    throw error;
  }
  const warnings = [...parsed.warnings];
  if (res.code !== 0) warnings.push(`go-mutesting exited ${res.code}; scored from the report it wrote`);
  return { status: 'ok', reason: null, detail: null, parsed, warnings };
}

// ---- passthrough (`-- <extra tool args>`) policy. The wrapper owns scope (--target), the report
// and the threshold; an extra argument that changes any of them would let the score be attributed
// to a different scope than --target. All three tools use a closed allow-list. Stryker 10.1.1: only
// --disableBail, --concurrency/-c, --maxConcurrentTestRunners, --maxTestRunnerReuse, --logLevel,
// --fileLogLevel, --allowConsoleColors, --cleanTempDir, --coverageAnalysis (classified against the installed
// `stryker run --help`; every other option changes mutant selection (--mutate, --files, --ignorePatterns,
// --ignoreStatic, --testFiles), the kill decision (--timeoutMS, --timeoutFactor, --dryRunTimeoutMinutes count
// slow mutants as killed; --checkers marks mutants CompileError), the runner/build (--testRunner,
// --commandRunner.*, --buildCommand, --plugins, --appendPlugins, --inPlace), incremental reuse
// (--incremental, --incrementalFile, --force), the report (--reporters, --dashboard.*, thresholds) or the
// temp dir (--tempDirName). mutmut: --max-children only. go-mutesting: --verbose, --debug only
// (--exec-timeout turns slow mutants into timeouts, which score as kills; --test-recursive changes the kill basis).
const STRYKER_FLAGS = new Set(['--disableBail']);
const STRYKER_VALUE = {
  '--concurrency': /^[1-9]\d*%?$/u,
  '--maxConcurrentTestRunners': /^[1-9]\d*$/u,
  '--maxTestRunnerReuse': /^\d+$/u,
  '--logLevel': /^(fatal|error|warn|info|debug|trace|off)$/u,
  '--fileLogLevel': /^(fatal|error|warn|info|debug|trace|off)$/u,
  '--allowConsoleColors': /^(true|false)$/u,
  '--cleanTempDir': /^(true|false|always)$/u,
  '--coverageAnalysis': /^(perTest|all|off)$/u,
};

function passthroughError(tool, token, why) {
  return new UsageError(`passthrough argument ${JSON.stringify(token)} is not allowed for ${tool}: ${why}`);
}

// Returns the index after the value of an option that needs one.
function takeValue(tool, args, i, token) {
  if (args[i + 1] === undefined || args[i + 1].startsWith('-')) throw passthroughError(tool, token, 'it needs a value');
  return i + 2;
}

function takeInteger(tool, args, i, token, name) {
  if (token.includes('=')) {
    if (!new RegExp(`^${name}=\\d+$`, 'u').test(token)) throw passthroughError(tool, token, 'needs an integer');
    return i + 1;
  }
  if (!/^\d+$/u.test(args[i + 1] ?? '')) throw passthroughError(tool, token, 'needs an integer');
  return i + 2;
}

export function validatePassthrough(tool, args) {
  let i = 0;
  while (i < args.length) {
    const token = args[i];
    const name = token.startsWith('--') ? token.split('=')[0] : token;
    const attached = token.startsWith('--') && token.includes('=');
    if (tool === 'stryker') {
      const rule = STRYKER_VALUE[name] ?? (token === '-c' ? STRYKER_VALUE['--concurrency'] : undefined);
      if (STRYKER_FLAGS.has(name) && !attached) i += 1;
      else if (rule !== undefined) {
        const value = attached ? token.slice(name.length + 1) : args[i + 1];
        if (value === undefined || !rule.test(value)) throw passthroughError(tool, token, `needs a value matching ${rule}`);
        i += attached ? 1 : 2;
      } else {
        throw passthroughError(tool, token, 'not in the allowed set (--disableBail, --concurrency/-c, --maxConcurrentTestRunners, --maxTestRunnerReuse, --logLevel, --fileLogLevel, --allowConsoleColors, --cleanTempDir, --coverageAnalysis); options that change scope, kill decision, runner, plugins, incremental reuse or report are refused, and so are positional arguments (config files: Stryker discovers stryker.config.* in the project)');
      }
    } else if (tool === 'mutmut') {
      if (name !== '--max-children') throw passthroughError(tool, token, 'only --max-children N may be passed through (mutant names and paths would change the scope)');
      i = takeInteger(tool, args, i, token, '--max-children');
    } else if (['--verbose', '--debug'].includes(token)) i += 1;
    else {
      throw passthroughError(tool, token, 'only --verbose and --debug may be passed through (targets, --match, --disable, --blacklist, --exec, --config, --exec-timeout, --test-recursive would change what is mutated or how a kill is decided)');
    }
  }
}

const RUNNERS = { stryker: runStryker, mutmut: runMutmut, 'go-mutesting': runGoMutesting };

function buildDocument(opts, outcome) {
  const doc = {
    schema: MUTATION_SCHEMA,
    tool: opts.tool,
    tool_version: outcome.parsed?.toolVersion ?? null,
    status: outcome.status,
    reason: outcome.reason,
    detail: outcome.detail,
    target: opts.target,
    min_score: opts.minScore,
    totals: null,
    score: null,
    meets_target: false,
    survivors: [],
    survivors_total: 0,
    warnings: outcome.warnings,
  };
  if (outcome.status === 'ok') {
    const { totals, survivors } = outcome.parsed;
    const scored = computeScore(totals);
    doc.totals = totals;
    doc.survivors = survivors.slice(0, SURVIVOR_CAP);
    doc.survivors_total = survivors.length;
    if (totals.ignored > 0) {
      doc.warnings.push(`${totals.ignored} mutant${totals.ignored === 1 ? '' : 's'} ignored (excluded from the score): suppression needs a PRD justification, otherwise FAIL MUT-SUPPRESSED (governance 1c1/2)`);
    }
    if (scored.score === null) {
      doc.status = 'error';
      doc.reason = 'no_mutants';
      doc.detail = 'no scoreable mutants (killed + timeout + survived + no_coverage + unknown is 0)';
    } else {
      doc.score = scored.score;
      doc.meets_target = scored.meets(opts.minScore);
    }
  }
  return doc;
}

function renderHuman(doc) {
  const lines = [];
  if (doc.status === 'ok') {
    lines.push(`mutation:${doc.tool} score=${doc.score} min=${doc.min_score} total=${doc.totals.total} ignored=${doc.totals.ignored}`);
    lines.push(`meets_target=${doc.meets_target}`);
  } else {
    lines.push(`mutation:${doc.tool} status=${doc.status}${doc.reason ? ` reason=${doc.reason}` : ''}`);
    if (doc.detail) lines.push(`detail: ${doc.detail}`);
  }
  if (doc.totals) {
    const t = doc.totals;
    lines.push(`totals: killed=${t.killed} survived=${t.survived} timeout=${t.timeout} no_coverage=${t.no_coverage} ignored=${t.ignored} errors=${t.errors} unknown=${t.unknown} total=${t.total}`);
  }
  if (doc.survivors.length > 0) {
    lines.push(`survivors (${doc.survivors.length} of ${doc.survivors_total}):`);
    for (const s of doc.survivors) {
      lines.push(`  ${s.file ?? '-'}${s.line === null ? '' : `:${s.line}`} ${s.mutator ?? ''} ${s.id ?? ''}`.trimEnd());
    }
  }
  for (const w of doc.warnings) lines.push(`warning: ${w}`);
  return lines.join('\n');
}

function exitCodeFor(doc) {
  if (doc.status !== 'ok') return 2;
  return doc.meets_target ? 0 : 1;
}

async function runRun(args, deps) {
  const split = args.indexOf('--');
  const own = split === -1 ? args : args.slice(0, split);
  const extra = split === -1 ? [] : args.slice(split + 1);
  const parsed = parseOptions(own, { bool: ['--json'], value: ['--tool', '--target', '--min-score', '--timeout', '--project-dir', '--out'] });
  if (parsed.help) { emit(deps, USAGE); return 0; }
  if (parsed.positional.length > 0) throw new UsageError(`unexpected argument: ${parsed.positional[0]}`);
  const f = parsed.flags;
  if (f.tool === undefined || !TOOLS.includes(f.tool)) {
    throw new UsageError(`--tool is required and must be one of: ${TOOLS.join(', ')}`);
  }
  if (f.target === undefined || f.target.trim() === '') throw new UsageError('--target is required (scope the run to the US\'s core business logic files)');
  if (f.target.startsWith('-')) throw new UsageError(`--target must not start with "-": ${JSON.stringify(f.target)}`);
  validatePassthrough(f.tool, extra);
  let minScore = DEFAULT_MIN_SCORE;
  if (f['min-score'] !== undefined) {
    minScore = f['min-score'].trim() === '' ? Number.NaN : Number(f['min-score']);
    if (!Number.isFinite(minScore) || minScore < 0 || minScore > 100) {
      throw new UsageError(`--min-score must be a number from 0 to 100, got ${JSON.stringify(f['min-score'])}`);
    }
  }
  let timeoutS = DEFAULT_TIMEOUT_S;
  if (f.timeout !== undefined) {
    timeoutS = f.timeout.trim() === '' ? Number.NaN : Number(f.timeout);
    if (!Number.isFinite(timeoutS) || timeoutS <= 0) {
      throw new UsageError(`--timeout must be a positive number of seconds, got ${JSON.stringify(f.timeout)}`);
    }
  }

  const projectDir = path.resolve(deps.cwd, f['project-dir'] ?? '.');
  const env = deps.env ?? process.env;
  const outCtx = { baseDir: projectDir, deskBases: [deps.cwd, projectDir], env };
  if (f.out !== undefined) {
    try {
      // Checked up front (fast failure, before anything runs); re-checked when writing.
      await resolveGuardedOutPath(f.out, outCtx);
    } catch (error) {
      if (error instanceof OutPathError) throw new UsageError(error.message);
      throw error;
    }
  }

  const opts = { tool: f.tool, target: f.target, minScore };
  const { binary } = await resolveBinary(f.tool, projectDir, env);
  let outcome;
  if (binary === null) {
    outcome = failure('tool_absent', 'tool_absent', `${f.tool} was not found in the project (node_modules/.bin, .venv/bin, GOBIN/GOPATH) or on PATH; nothing was run`);
  } else {
    const deadline = Date.now() + timeoutS * 1000;
    const exec = deps.exec ?? spawnCapture;
    const ctx = {
      projectDir,
      binary,
      target: f.target,
      extra,
      exec: (command, cmdArgs) => exec({
        command, args: cmdArgs, cwd: projectDir, env,
        timeoutMs: Math.max(1, deadline - Date.now()),
        killGraceMs: deps.killGraceMs ?? DEFAULT_KILL_GRACE_MS,
      }),
    };
    outcome = await RUNNERS[f.tool](ctx);
  }
  const doc = buildDocument(opts, outcome);
  let outError = null;
  if (f.out !== undefined) {
    try {
      await writeGuardedOut(f.out, `${JSON.stringify(doc, null, 2)}\n`, outCtx);
    } catch (error) {
      outError = error;
      doc.warnings.push(`--out write failed: ${error.message}`);
    }
  }
  emit(deps, f.json ? `${JSON.stringify(doc, null, 2)}\n` : renderHuman(doc));
  if (outError) {
    deps.stderr.write(`mutation: cannot write --out ${JSON.stringify(f.out)}: ${outError.message}\n`);
    return 2; // the requested artifact does not exist: cannot be cited, so not a pass/score-fail
  }
  return exitCodeFor(doc);
}

// ----------------------------------------------------------------- plumbing

function emit(deps, text) {
  deps.stdout.write(text.endsWith('\n') ? text : `${text}\n`);
}

function parseOptions(args, spec) {
  const out = { positional: [], flags: {}, help: false };
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--help' || token === '-h') out.help = true;
    else if (spec.bool?.includes(token)) out.flags[token.slice(2)] = true;
    else if (spec.value?.includes(token)) {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      out.flags[token.slice(2)] = value;
      i += 1;
    } else if (token.startsWith('-')) throw new UsageError(`unknown mutation option: ${token}`);
    else out.positional.push(token);
  }
  return out;
}

export async function runCommand(args, deps) {
  const [sub, ...rest] = args;
  try {
    if (sub === undefined || sub === '--help' || sub === '-h') {
      emit(deps, USAGE);
      return 0;
    }
    if (sub === 'detect') return await runDetect(rest, deps);
    if (sub === 'run') return await runRun(rest, deps);
    throw new UsageError(`unknown mutation subcommand: ${sub}`);
  } catch (error) {
    if (error instanceof UsageError) {
      deps.stderr.write(`${error.message}\n${USAGE}\n`);
      return EXIT_USAGE;
    }
    // Anything unexpected is "cannot judge" (2), never 1: exit 1 means "score below target".
    deps.stderr.write(`mutation: internal error: ${error?.message ?? error}\n`);
    if (sub === 'run' && rest.includes('--json')) {
      emit(deps, JSON.stringify(buildDocument(internalErrorOpts(rest), failure('error', 'internal_error', String(error?.message ?? error))), null, 2));
    }
    return 2;
  }
}

// Best-effort echo of --tool/--target/--min-score for the internal_error document.
function internalErrorOpts(args) {
  const end = args.indexOf('--');
  const own = end === -1 ? args : args.slice(0, end);
  const valueOf = (flag) => { const i = own.indexOf(flag); return i === -1 ? undefined : own[i + 1]; };
  const min = Number(valueOf('--min-score'));
  return { tool: valueOf('--tool') ?? null, target: valueOf('--target') ?? null, minScore: Number.isFinite(min) ? min : DEFAULT_MIN_SCORE };
}
