// D2 (TODO L44-46) — domain rule packs.
//
// A pack is DATA (JSON, schema `rlp-desk.rule-pack/1`), never code: it holds
// rules and per-rule "how to verify" guidance, no commands. `rule-pack apply`
// renders it as a marked block in the global header of the campaign's test-spec
// (before the first `## US-` heading, so it survives the per-US split), where it
// gains test-spec authority and is covered by the gate-receipt seal. Applying is
// manual and idempotent; nothing in the leader reads packs.
//
// Lookup (first hit wins): <deskRoot>/rule-packs/<name>.pack.json (project), then
// src/node/rule-packs/<name>.pack.json (shipped). Names are validated before any
// path is built, so a name can never traverse out of those two directories.
//
// Invoked as `node ~/.claude/ralph-desk/node/run.mjs rule-pack <list|validate|apply> ...`.

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolveDeskRoot } from '../util/desk-root.mjs';
import { gateReceiptPath, listTestSpecFiles } from '../util/gate-receipt.mjs';
import { writeFileSafely } from '../util/out-path-guard.mjs';

export const PACK_SCHEMA = 'rlp-desk.rule-pack/1';
export const NAME_PATTERN = /^[a-z][a-z0-9-]{1,31}$/u;
const ID_PATTERN = /^[A-Z]{2,6}-[0-9]{3}$/u;
const SEMVER_PATTERN = /^\d+\.\d+\.\d+$/u;
const SEVERITIES = ['critical', 'major', 'minor'];
const METHODS = ['test', 'inspect'];
const RISKS = ['LOW', 'MEDIUM', 'HIGH', 'CRITICAL'];
const MARKER = 'rlp-desk:rule-pack:';
// Same boundary the zsh splitter uses (split_test_spec_by_us), so the block lands
// where the split copies the "global header" from.
const US_HEADING_PATTERN = /^##\s+US-[0-9]+(?:[\s:-]|$)/u;
const SHIPPED_DIR = fileURLToPath(new URL('../rule-packs/', import.meta.url));
const EXIT_USAGE = 64;

const USAGE = [
  'Usage: node src/node/run.mjs rule-pack <list|validate|apply> [options]',
  '',
  '  list [--json]                        packs found (project .rlp-desk/rule-packs/ overrides shipped)',
  '  validate <name|file.pack.json>       check a pack against the schema (exit 1 lists every error)',
  '  apply <slug> --pack <name> [--json]  render the pack into plans/test-spec-<slug>.md and every',
  '                                       plans/test-spec-<slug>-US-*.md (idempotent). Order in brainstorm:',
  '                                       init -> rule-pack apply -> gate-receipt',
].join('\n');

class UsageError extends Error {}

const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');

// ---------------------------------------------------------------- validation

function collectStrings(value, where, out) {
  if (typeof value === 'string') out.push([where, value]);
  else if (Array.isArray(value)) value.forEach((item, i) => collectStrings(item, `${where}[${i}]`, out));
  else if (value && typeof value === 'object') {
    for (const [key, item] of Object.entries(value)) {
      out.push([`${where}.${key} (key)`, key]);
      collectStrings(item, where === '' ? key : `${where}.${key}`, out);
    }
  }
}

const isNonEmptyString = (v) => typeof v === 'string' && v.trim() !== '';

// Returns an array of error strings (empty = valid). `expectedName` is set when
// the pack was found by name: the file name and the `name` field must agree.
export function validatePack(pack, { expectedName } = {}) {
  const errors = [];
  if (pack === null || typeof pack !== 'object' || Array.isArray(pack)) {
    return ['pack must be a JSON object'];
  }
  if (pack.schema !== PACK_SCHEMA) errors.push(`schema must be "${PACK_SCHEMA}"`);
  if (typeof pack.name !== 'string' || !NAME_PATTERN.test(pack.name)) {
    errors.push(`name must match ${NAME_PATTERN.source}`);
  } else if (expectedName !== undefined && pack.name !== expectedName) {
    errors.push(`name "${pack.name}" does not match the pack file name "${expectedName}"`);
  }
  if (typeof pack.version !== 'string' || !SEMVER_PATTERN.test(pack.version)) {
    errors.push('version must be semver (MAJOR.MINOR.PATCH)');
  }
  if (!isNonEmptyString(pack.description)) errors.push('description must be a non-empty string');

  if (pack.recommended_for !== undefined) {
    const risk = pack.recommended_for?.risk;
    const okShape = pack.recommended_for !== null && typeof pack.recommended_for === 'object' && !Array.isArray(pack.recommended_for);
    const okRisk = risk === undefined || (Array.isArray(risk) && risk.every((r) => RISKS.includes(r)));
    if (!okShape || !okRisk) errors.push(`recommended_for.risk must be an array of ${RISKS.join('|')}`);
  }

  if (!Array.isArray(pack.rules) || pack.rules.length === 0) {
    errors.push('rules must be a non-empty array');
  } else {
    const seen = new Set();
    pack.rules.forEach((rule, i) => {
      const at = `rules[${i}]`;
      if (rule === null || typeof rule !== 'object' || Array.isArray(rule)) {
        errors.push(`${at} must be an object`);
        return;
      }
      if (typeof rule.id !== 'string' || !ID_PATTERN.test(rule.id)) {
        errors.push(`${at}.id must match ${ID_PATTERN.source}`);
      } else if (seen.has(rule.id)) {
        errors.push(`duplicate rule id ${rule.id}`);
      } else {
        seen.add(rule.id);
      }
      if (!isNonEmptyString(rule.title)) errors.push(`${at}.title must be a non-empty string`);
      if (!SEVERITIES.includes(rule.severity)) errors.push(`${at}.severity must be one of ${SEVERITIES.join('|')}`);
      if (!isNonEmptyString(rule.statement)) errors.push(`${at}.statement must be a non-empty string`);
      if (!METHODS.includes(rule.verify?.method)) errors.push(`${at}.verify.method must be one of ${METHODS.join('|')}`);
      if (!isNonEmptyString(rule.verify?.how)) errors.push(`${at}.verify.how must be a non-empty string`);
    });
  }

  // Marker injection: no value (or key) may contain the block-marker prefix.
  const strings = [];
  collectStrings(pack, '', strings);
  for (const [where, text] of strings) {
    if (text.includes(MARKER)) errors.push(`${where} contains reserved marker "${MARKER}"`);
  }
  return errors;
}

// ----------------------------------------------------------------- rendering

// One table cell: single line, pipes escaped, so rule text can never break the
// row or open a new line (a `## US-` heading cannot be smuggled into the block).
const cellText = (text) => String(text).replace(/\s+/gu, ' ').trim().replace(/\|/gu, '\\|');

export function renderBlock(pack) {
  const body = [
    `## Domain Rule Pack: ${pack.name} (v${pack.version})`,
    `Guidance: ${cellText(pack.description)}`,
  ];
  if (pack.recommended_for?.risk?.length) {
    body.push(`Recommended for risk: ${pack.recommended_for.risk.join(', ')}.`);
  }
  body.push(
    'Each rule is an additional acceptance criterion for every in-scope US. Verifier: a `critical` rule that is violated, or has no cited evidence (file:line, test name, or command output), is a FAIL; cite the rule ID in `issues[].id`. Rules never relax universal governance.',
    '| ID | Severity | Rule | How verified |',
    '|----|----------|------|--------------|',
  );
  for (const rule of pack.rules) {
    body.push(
      `| ${rule.id} | ${rule.severity} | **${cellText(rule.title)}**: ${cellText(rule.statement)} | ${rule.verify.method}: ${cellText(rule.verify.how)} |`,
    );
  }
  const begin = `<!-- ${MARKER}begin name=${pack.name} version=${pack.version} sha256=${sha256(body.join('\n'))} -->`;
  const end = `<!-- ${MARKER}end name=${pack.name} -->`;
  return { lines: [begin, ...body, end], body: body.join('\n') };
}

// Pure text transform: replace this pack's block in place, else insert it before
// the first `## US-` heading, else append. Throws on a corrupt block.
export function applyBlock(content, pack) {
  const { lines: blockLines } = renderBlock(pack);
  const beginRe = new RegExp(`^<!-- ${MARKER}begin name=${pack.name}( .*)? -->$`, 'u');
  const endRe = new RegExp(`^<!-- ${MARKER}end name=${pack.name} -->$`, 'u');
  const lines = content.split('\n');
  const begins = lines.flatMap((line, i) => (beginRe.test(line) ? [i] : []));
  if (begins.length > 1) throw new Error(`more than one "${pack.name}" rule-pack block`);

  if (begins.length === 1) {
    const b = begins[0];
    const e = lines.findIndex((line, i) => i > b && endRe.test(line));
    if (e < 0) throw new Error(`"${pack.name}" rule-pack begin marker without a matching end marker`);
    const next = [...lines.slice(0, b), ...blockLines, ...lines.slice(e + 1)].join('\n');
    return { content: next, action: next === content ? 'unchanged' : 'replaced' };
  }

  const us = lines.findIndex((line) => US_HEADING_PATTERN.test(line));
  if (us >= 0) {
    const next = [...lines.slice(0, us), ...blockLines, '', ...lines.slice(us)].join('\n');
    return { content: next, action: 'inserted' };
  }
  const base = content === '' || content.endsWith('\n') ? content : `${content}\n`;
  const gap = base === '' || base.endsWith('\n\n') ? '' : '\n';
  return { content: `${base}${gap}${blockLines.join('\n')}\n`, action: 'appended' };
}

// ------------------------------------------------------------------- lookup

function packDirs(deskRoot) {
  return [
    { source: 'project', dir: path.join(deskRoot, 'rule-packs') },
    { source: 'shipped', dir: SHIPPED_DIR },
  ];
}

async function readPackFile(file) {
  let text;
  try {
    text = await fs.readFile(file, 'utf8');
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
  try {
    return { pack: JSON.parse(text), parseError: null };
  } catch (error) {
    return { pack: null, parseError: `invalid JSON: ${error.message}` };
  }
}

function assertPackName(name) {
  if (typeof name !== 'string' || !NAME_PATTERN.test(name)) {
    throw new Error(`invalid pack name: ${JSON.stringify(name)} — must match ${NAME_PATTERN.source}`);
  }
  return name;
}

// First hit wins; an invalid project pack is an error, never a silent fallthrough
// to the shipped pack of the same name.
async function resolvePack(name, deskRoot) {
  assertPackName(name);
  for (const { source, dir } of packDirs(deskRoot)) {
    const file = path.join(dir, `${name}.pack.json`);
    const loaded = await readPackFile(file);
    if (loaded === null) continue;
    const errors = loaded.parseError ? [loaded.parseError] : validatePack(loaded.pack, { expectedName: name });
    return { name, source, file, pack: loaded.pack, errors };
  }
  throw new Error(`pack not found: ${name} (looked in ${path.join(deskRoot, 'rule-packs')} and the shipped packs)`);
}

// ----------------------------------------------------------------- commands

function displayPath(cwd, file) {
  const rel = path.relative(cwd, file);
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel) ? rel : file;
}

function emit(deps, text) {
  deps.stdout.write(text.endsWith('\n') ? text : `${text}\n`);
}

function parseFlags(args, spec) {
  const out = { positional: [], flags: {} };
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--help' || token === '-h') out.flags.help = true;
    else if (spec.bool?.includes(token)) out.flags[token.slice(2)] = true;
    else if (spec.value?.includes(token)) {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      out.flags[token.slice(2)] = value;
      i += 1;
    } else if (token.startsWith('-')) throw new UsageError(`unknown rule-pack option: ${token}`);
    else out.positional.push(token);
  }
  return out;
}

async function runList(args, deps) {
  const { flags, positional } = parseFlags(args, { bool: ['--json'] });
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length > 0) throw new UsageError(`unexpected argument: ${positional[0]}`);
  const deskRoot = resolveDeskRoot(deps.cwd, deps.env ?? process.env);
  const rows = new Map();
  for (const { source, dir } of packDirs(deskRoot)) {
    let names = [];
    try {
      names = await fs.readdir(dir);
    } catch {
      names = [];
    }
    for (const fileName of names.sort()) {
      const match = /^(.+)\.pack\.json$/u.exec(fileName);
      if (!match || !NAME_PATTERN.test(match[1]) || rows.has(match[1])) continue;
      const loaded = await readPackFile(path.join(dir, fileName));
      const errors = loaded.parseError ? [loaded.parseError] : validatePack(loaded.pack, { expectedName: match[1] });
      rows.set(match[1], {
        name: match[1],
        version: typeof loaded.pack?.version === 'string' ? loaded.pack.version : null,
        source,
        rules: Array.isArray(loaded.pack?.rules) ? loaded.pack.rules.length : null,
        valid: errors.length === 0,
      });
    }
  }
  const packs = [...rows.values()].sort((a, b) => (a.name < b.name ? -1 : 1));
  if (flags.json) {
    emit(deps, JSON.stringify({ schema: 'rlp-desk.rule-pack-list/1', packs }, null, 2));
    return 0;
  }
  const table = [['NAME', 'VERSION', 'SOURCE', 'RULES'], ...packs.map((p) => [p.name + (p.valid ? '' : ' (invalid)'), p.version ?? '?', p.source, String(p.rules ?? '?')])];
  const widths = table[0].map((_, col) => Math.max(...table.map((row) => row[col].length)));
  emit(deps, table.map((row) => row.map((c, col) => c.padEnd(widths[col])).join('  ').trimEnd()).join('\n'));
  return 0;
}

async function runValidate(args, deps) {
  const { flags, positional } = parseFlags(args, {});
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length !== 1) throw new UsageError('validate requires exactly one <name|file.pack.json>');
  const target = positional[0];
  let loaded;
  let errors;
  if (target.endsWith('.json')) {
    const file = path.resolve(deps.cwd, target);
    loaded = await readPackFile(file);
    if (loaded === null) throw new Error(`cannot read ${displayPath(deps.cwd, file)}`);
    errors = loaded.parseError ? [loaded.parseError] : validatePack(loaded.pack);
  } else {
    const resolved = await resolvePack(target, resolveDeskRoot(deps.cwd, deps.env ?? process.env));
    loaded = { pack: resolved.pack };
    errors = resolved.errors;
  }
  if (errors.length > 0) {
    deps.stderr.write(`${errors.map((e) => `error: ${e}`).join('\n')}\n`);
    return 1;
  }
  emit(deps, `OK ${loaded.pack.name} ${loaded.pack.version} (${loaded.pack.rules.length} rules)`);
  return 0;
}

// B-C2-02: a test-spec the apply may touch is a regular file directly inside the slug's plans dir.
// Symlinks (even to another file in plans/) and anything resolving outside are refused, because the
// block would otherwise land in a file the campaign does not own.
async function assertPlainSpecFile(file, realPlans, cwd) {
  const shown = displayPath(cwd, file);
  const st = await fs.lstat(file);
  if (st.isSymbolicLink()) throw new Error(`${shown} is a symlink; refusing to apply a rule pack through it`);
  if (!st.isFile()) throw new Error(`${shown} is not a regular file`);
  const real = await fs.realpath(file);
  if (path.dirname(real) !== realPlans) throw new Error(`${shown} resolves outside the plans directory (${real}); refusing to write it`);
}

async function runApply(args, deps) {
  const { flags, positional } = parseFlags(args, { bool: ['--json'], value: ['--pack'] });
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length !== 1) throw new UsageError('apply requires exactly one <slug>');
  if (flags.pack === undefined) throw new UsageError('apply requires --pack <name>');

  const slug = deps.requireCanonicalSlug(positional[0]); // IMP-08: reject, never normalize
  assertPackName(flags.pack);
  const deskRoot = resolveDeskRoot(deps.cwd, deps.env ?? process.env);
  const resolved = await resolvePack(flags.pack, deskRoot);
  if (resolved.errors.length > 0) {
    deps.stderr.write(`${resolved.errors.map((e) => `error: ${e}`).join('\n')}\n`);
    return 1;
  }

  const plansDir = path.join(deskRoot, 'plans');
  const mainSpec = path.join(plansDir, `test-spec-${slug}.md`);
  if (!existsSync(mainSpec)) {
    throw new Error(`test-spec not found: ${displayPath(deps.cwd, mainSpec)} — run init first`);
  }

  // Compute every result before writing anything, so a corrupt block in one file
  // cannot leave the set half-applied.
  const results = [];
  const realPlans = await fs.realpath(plansDir);
  for (const file of listTestSpecFiles(plansDir, slug)) {
    await assertPlainSpecFile(file, realPlans, deps.cwd);
    const original = await fs.readFile(file, 'utf8');
    let applied;
    try {
      applied = applyBlock(original, resolved.pack);
    } catch (error) {
      throw new Error(`${displayPath(deps.cwd, file)}: ${error.message}`);
    }
    results.push({ file, ...applied });
  }
  for (const result of results) {
    if (result.action === 'unchanged') continue;
    // temp+rename in the same directory, re-validated right before the rename (B-C2-02)
    await writeFileSafely(result.file, result.content, {
      recheck: (finalPath) => assertPlainSpecFile(finalPath, realPlans, deps.cwd),
    });
  }

  const warnings = [];
  const changed = results.some((r) => r.action !== 'unchanged');
  if (changed && existsSync(gateReceiptPath(plansDir, slug))) {
    warnings.push(`${displayPath(deps.cwd, gateReceiptPath(plansDir, slug))} exists and the sealed test-spec content just changed — re-run gate-receipt ${slug} to re-seal`);
  }
  for (const warning of warnings) deps.stderr.write(`WARNING: ${warning}\n`);

  if (flags.json) {
    emit(deps, JSON.stringify({
      schema: 'rlp-desk.rule-pack-apply/1',
      slug,
      pack: resolved.pack.name,
      version: resolved.pack.version,
      source: resolved.source,
      files: results.map((r) => ({ file: path.basename(r.file), action: r.action })),
      warnings,
    }, null, 2));
  } else {
    const lines = results.map((r) => `${r.action} ${displayPath(deps.cwd, r.file)}`);
    lines.push(`pack ${resolved.pack.name} v${resolved.pack.version} (${resolved.source})`);
    emit(deps, lines.join('\n'));
  }
  return 0;
}

export async function runCommand(args, deps) {
  const [sub, ...rest] = args;
  try {
    if (sub === undefined || sub === '--help' || sub === '-h') {
      emit(deps, USAGE);
      return 0;
    }
    if (sub === 'list') return await runList(rest, deps);
    if (sub === 'validate') return await runValidate(rest, deps);
    if (sub === 'apply') return await runApply(rest, deps);
    throw new UsageError(`unknown rule-pack subcommand: ${sub}`);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    deps.stderr.write(`${error.message}\n${USAGE}\n`);
    return EXIT_USAGE;
  }
}
