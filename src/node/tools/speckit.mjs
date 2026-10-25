// D5 (TODO L60) — `speckit <spec.md>`: a deterministic test-spec DRAFT from a Spec Kit spec.md.
//
// Built against the REAL template captured from github/spec-kit v1.2.3
// (tests/fixtures/speckit/spec-template-v1.2.3.md; byte-identical to main at capture):
//   story heading   `### User Story N - Title (Priority: P#)`
//   scenarios       `N. **Given** ..., **When** ..., **Then** ...` under `**Acceptance Scenarios**:`
//   requirements    `- **FR-NNN**: ...` under `### Functional Requirements`
//   noise to skip   `<!-- ... -->` blocks; `[NEEDS CLARIFICATION: ...]` markers are surfaced, not dropped
//
// Safety properties (the draft is NOT a contract):
//   - stdout by default; `--out` writes exactly one path, never a name the splitter / gate-receipt
//     globs (`test-spec-<slug>.md`, `test-spec-<slug>-US-*.md`) could pick up, and never overwrites
//     a file that is not itself a previous speckit draft;
//   - line 1 is a banner naming the source and its sha256; every criterion's Method/Command is TODO;
//   - fail-closed: unrecognized structure in the stories / scenarios / requirements, or an unfilled
//     template (placeholders such as `[Brief Title]`), exits 1 with nothing written. Never guessed.
//   - a `Then` without a digit is flagged `needs_quantification` (brainstorm's scorecard still applies).
//
// Invoked as `node ~/.claude/ralph-desk/node/run.mjs speckit <spec.md> [--slug S] [--out F] [--json]`.

import crypto from 'node:crypto';
import { constants as fsConstants } from 'node:fs';
import fs from 'node:fs/promises';
import path from 'node:path';

export const SPECKIT_SCHEMA = 'rlp-desk.speckit/1';
const EXIT_USAGE = 64;
const BANNER_PREFIX = '<!-- DRAFT from Spec Kit ';
const MAX_PLACEHOLDERS_SHOWN = 8;

const STORY_RE = /^###\s+User Story\s+(\d+)\s+-\s+(.+?)\s+\(Priority:\s*(P\d+)\)\s*$/u;
const SCENARIO_RE = /^(\d+)\.\s+\*\*Given\*\*\s+(.+?),?\s+\*\*When\*\*\s+(.+?),?\s+\*\*Then\*\*\s+(.+?)\s*$/u;
const FR_RE = /^-\s+\*\*(FR-\d+)\*\*:\s*(.+?)\s*$/u;
// Upstream template boilerplate that many authors keep; known and harmless.
const BOILERPLATE_RE = /^\*Example of marking unclear requirements:\*$/u;
const CLARIFY_RE = /\[NEEDS CLARIFICATION:[^\]]*\]/gu;

const USAGE = [
  'Usage: node src/node/run.mjs speckit <spec.md> [--slug <slug>] [--out <file>] [--json]',
  '',
  '  Draft a test-spec skeleton from a Spec Kit spec.md (template v1.2.3 layout).',
  '  Default: the draft goes to stdout and nothing is written.',
  '  --out FILE    write the draft to FILE (suggested: .rlp-desk/plans/test-spec-<slug>.speckit-draft.md).',
  '                Refused: any test-spec-*.md name the splitter / gate-receipt would pick up, and any',
  '                existing file that is not a previous speckit draft.',
  '  --slug S      slug used in the draft header (validated like every other command).',
  '  --json        print the parsed summary (counts, needs_quantification, needs_clarification) instead.',
  '  Fail-closed: unrecognized structure or an unfilled template exits 1 with nothing written.',
].join('\n');

class UsageError extends Error {}

const sha256 = (text) => crypto.createHash('sha256').update(text).digest('hex');
const pad = (n) => String(n).padStart(3, '0');
const posixRel = (cwd, file) => path.relative(cwd, file).split(path.sep).join('/');

function sortedClone(value) {
  if (Array.isArray(value)) return value.map(sortedClone);
  if (value !== null && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((k) => [k, sortedClone(value[k])]));
  }
  return value;
}

// ---------------------------------------------------------------------- parse

// Replaces each <!-- ... --> block with the same number of newlines so line numbers survive.
function blankComments(text) {
  const blanked = text.replace(/<!--[\s\S]*?-->/gu, (m) => m.replace(/[^\n]/gu, ''));
  return { text: blanked, unterminated: blanked.includes('<!--') };
}

function placeholdersIn(text) {
  const cleaned = text
    .replace(CLARIFY_RE, '')
    .replace(/`[^`]*`/gu, '')
    .replace(/\[[^\]]*\]\([^)]*\)/gu, '')
    .replace(/\[[ xX]\]/gu, '');
  return cleaned.match(/\[[^\]\n]+\]/gu) ?? [];
}

const knownH2 = (heading) => {
  if (/^User Scenarios & Testing/u.test(heading)) return 'scenarios';
  if (/^Requirements/u.test(heading)) return 'requirements';
  if (/^Success Criteria/u.test(heading)) return 'success';
  if (/^Assumptions/u.test(heading)) return 'assumptions';
  return null;
};

// Pure. Never throws on content: structure problems and placeholders are returned as data.
export function parseSpecKit(rawText) {
  const normalized = rawText.replace(/\r\n?/gu, '\n');
  const { text, unterminated } = blankComments(normalized);
  const lines = text.split('\n');
  const result = {
    feature: null,
    stories: [],
    edgeCases: [],
    requirements: [],
    needsClarification: [],
    ignoredSections: [],
    notImported: [],
    problems: [],
    placeholders: [],
  };
  const problem = (line, message) => result.problems.push({ line, message });
  const checkPlaceholders = (line, value) => {
    for (const found of placeholdersIn(value)) result.placeholders.push({ line, text: found });
  };
  const noteNotImported = (name) => { if (!result.notImported.includes(name)) result.notImported.push(name); };
  if (unterminated) problem(0, 'unterminated <!-- comment');

  let section = null; // scenarios | requirements | success | assumptions | ignored
  let sub = null; // story | edge | fr | other
  let story = null;
  let inScenarioBlock = false;
  let heading = '';
  // A FR / edge-case bullet may be hard-wrapped: following non-blank lines (until a blank line, bullet or heading)
  // belong to it. The merged text is what gets placeholder- and marker-checked.
  let item = null;
  const flushItem = () => {
    if (item === null) return;
    checkPlaceholders(item.target.line, item.target.text);
    for (const marker of item.target.text.match(CLARIFY_RE) ?? []) {
      result.needsClarification.push({ line: item.target.line, where: item.where, text: marker });
    }
    item = null;
  };

  const finishStory = () => {
    if (story === null) return;
    if (story.scenarios.length === 0) problem(story.line, `User Story ${story.number} has no Acceptance Scenarios (need a "**Acceptance Scenarios**:" block of "N. **Given** ..., **When** ..., **Then** ..." lines)`);
    story = null;
  };

  lines.forEach((line, index) => {
    const lineNo = index + 1;
    let where = heading;
    let handledAsItem = false;
    const h1 = /^#\s+(.*?)\s*$/u.exec(line);
    if (h1 !== null) {
      flushItem();
      if (result.feature === null) {
        const title = /^Feature Specification:\s*(.+)$/u.exec(h1[1]);
        if (title === null) problem(lineNo, `first heading must be "# Feature Specification: <name>", got ${JSON.stringify(line)}`);
        else { result.feature = title[1]; checkPlaceholders(lineNo, title[1]); }
      }
      return;
    }
    const h2 = /^##\s+(.*?)\s*$/u.exec(line);
    if (h2 !== null) {
      flushItem();
      finishStory();
      sub = null;
      inScenarioBlock = false;
      heading = h2[1].replace(/\s*\*\(.*?\)\*\s*$/u, '');
      section = knownH2(heading);
      if (section === null) { section = 'ignored'; result.ignoredSections.push({ heading, line: lineNo }); }
      if (section === 'success') noteNotImported('Success Criteria');
      if (section === 'assumptions') noteNotImported('Assumptions');
      return;
    }
    const h3 = /^###\s+(.*?)\s*$/u.exec(line);
    if (h3 !== null) {
      flushItem();
      finishStory();
      inScenarioBlock = false;
      sub = 'other';
      const h3text = h3[1].replace(/\s*\*\(.*?\)\*\s*$/u, '');
      heading = h3text;
      if (section === 'scenarios') {
        const m = STORY_RE.exec(line);
        if (m !== null) {
          const number = Number(m[1]);
          if (result.stories.some((s) => s.number === number)) problem(lineNo, `duplicate User Story ${number}`);
          story = { number, id: `US-${pad(number)}`, title: m[2], priority: m[3], line: lineNo, independentTest: null, scenarios: [] };
          result.stories.push(story);
          checkPlaceholders(lineNo, m[2]);
          sub = 'story';
        } else if (/^Edge Cases$/u.test(h3text)) sub = 'edge';
        else if (/^User Story\b/u.test(h3text)) {
          problem(lineNo, `unrecognized story heading ${JSON.stringify(line)} (expected "### User Story N - <title> (Priority: P#)")`);
        } else problem(lineNo, `unrecognized section "### ${h3text}" inside "User Scenarios & Testing" (only "### User Story N - ..." and "### Edge Cases" are understood)`);
      } else if (section === 'requirements') {
        if (/^Functional Requirements$/u.test(h3text)) sub = 'fr';
        else if (/^Key Entities/u.test(h3text)) noteNotImported('Key Entities');
        else result.ignoredSections.push({ heading: h3text, line: lineNo });
      }
      return;
    }

    if (section === 'scenarios' && sub === 'story' && story !== null) {
      const trimmed = line.trim();
      if (trimmed === '---') inScenarioBlock = false;
      else if (/^\*\*Acceptance Scenarios\*\*:\s*$/u.test(trimmed)) inScenarioBlock = true;
      else if (/^\*\*[^*]+\*\*:/u.test(trimmed)) {
        inScenarioBlock = false;
        const it = /^\*\*Independent Test\*\*:\s*(.+)$/u.exec(trimmed);
        if (it !== null) story.independentTest = it[1];
      } else if (inScenarioBlock && trimmed !== '') {
        const m = SCENARIO_RE.exec(trimmed);
        if (m === null) problem(lineNo, `unrecognized scenario line ${JSON.stringify(trimmed)} (expected "N. **Given** ..., **When** ..., **Then** ...")`);
        else {
          const expected = story.scenarios.length + 1;
          if (Number(m[1]) !== expected) problem(lineNo, `scenario numbered ${m[1]}, expected ${expected} (numbering must be sequential from 1)`);
          const scenario = {
            ac: `AC${expected}`,
            line: lineNo,
            given: m[2],
            when: m[3],
            then: m[4],
            needs_quantification: !/\d/u.test(m[4]),
            fr_refs: [...new Set((trimmed.match(/\bFR-\d+\b/gu) ?? []))].sort(),
          };
          story.scenarios.push(scenario);
          for (const clause of [m[2], m[3], m[4]]) checkPlaceholders(lineNo, clause);
          where = `${story.id} ${scenario.ac}`;
        }
      }
      if (story !== null && where === heading) where = story.id;
    } else if ((section === 'scenarios' && sub === 'edge') || (section === 'requirements' && sub === 'fr')) {
      const isEdge = sub === 'edge';
      if (/^\s*-\s/u.test(line)) {
        flushItem();
        if (isEdge) {
          const bullet = /^\s*-\s+(.+?)\s*$/u.exec(line);
          const target = { line: lineNo, text: bullet === null ? '' : bullet[1] };
          result.edgeCases.push(target);
          item = { target, where: 'Edge Cases' };
        } else {
          const m = FR_RE.exec(line);
          if (m === null) problem(lineNo, `unrecognized requirement line ${JSON.stringify(line.trim())} (expected "- **FR-NNN**: ...")`);
          else {
            if (result.requirements.some((r) => r.id === m[1])) problem(lineNo, `duplicate ${m[1]}`);
            const target = { id: m[1], line: lineNo, text: m[2] };
            result.requirements.push(target);
            item = { target, where: m[1] };
          }
        }
        handledAsItem = true;
      } else if (line.trim() === '') {
        // Keep the item open: an INDENTED paragraph after a blank line still belongs to the bullet.
        if (item !== null) item.afterBlank = true;
      } else if (item !== null && (!item.afterBlank || /^\s/u.test(line))) {
        item.target.text = `${item.target.text} ${line.trim()}`;
        item.afterBlank = false;
        handledAsItem = true;
      } else {
        flushItem();
        if (!BOILERPLATE_RE.test(line.trim())) {
          problem(lineNo, `unrecognized line in ${isEdge ? 'Edge Cases' : 'Functional Requirements'}: ${JSON.stringify(line.trim())} (only bullets and indented continuation lines are understood; nothing is dropped silently)`);
        }
      }
    }

    if (section !== 'ignored' && !handledAsItem) {
      for (const marker of line.match(CLARIFY_RE) ?? []) {
        result.needsClarification.push({ line: lineNo, where: where || 'document', text: marker });
      }
    }
  });
  flushItem();
  finishStory();
  if (result.feature === null && result.problems.every((p) => !/first heading/u.test(p.message))) {
    problem(0, 'missing "# Feature Specification: <name>" heading');
  }
  if (result.stories.length === 0) problem(0, 'no user stories recognized (need "### User Story N - <title> (Priority: P#)" headings)');
  return result;
}

// ------------------------------------------------------------------- summary

function buildSummary(parsed, { relPath, hash, slug }) {
  const stories = parsed.stories.map((s) => ({
    id: s.id,
    number: s.number,
    title: s.title,
    priority: s.priority,
    line: s.line,
    independent_test: s.independentTest,
    scenarios: s.scenarios,
  }));
  return {
    schema: SPECKIT_SCHEMA,
    feature: parsed.feature,
    slug: slug ?? null,
    source: { path: relPath, sha256: hash },
    counts: {
      stories: stories.length,
      scenarios: stories.reduce((n, s) => n + s.scenarios.length, 0),
      edge_cases: parsed.edgeCases.length,
      functional_requirements: parsed.requirements.length,
    },
    stories,
    edge_cases: parsed.edgeCases,
    functional_requirements: parsed.requirements,
    needs_quantification: stories.flatMap((s) => s.scenarios.filter((x) => x.needs_quantification).map((x) => `${s.id} ${x.ac}`)),
    needs_clarification: parsed.needsClarification,
    ignored_sections: parsed.ignoredSections,
    not_imported: parsed.notImported,
  };
}

const cell = (text) => text.replace(/\|/gu, '\\|');

function renderDraft(summary) {
  const { source, slug } = summary;
  const slugText = slug ?? '<slug>';
  const out = [];
  out.push(`${BANNER_PREFIX}${source.path} sha256 ${source.sha256}; not sealed; still subject to the brainstorm scorecard -->`);
  out.push(`# Test Spec DRAFT: ${summary.feature}`);
  out.push('');
  out.push('> Generated by `speckit` (deterministic, no LLM). This is a skeleton, not a contract: replace every TODO, quantify every flagged Then,');
  out.push('> merge it into the test-spec that `init` wrote, delete this banner and the notes below, then let brainstorm seal it.');
  out.push(`> Suggested file name: \`.rlp-desk/plans/test-spec-${slugText}.speckit-draft.md\` (a name the splitter and gate-receipt do not match).`);
  out.push('');
  out.push('## Draft notes (delete before sealing)');
  out.push(`- Source: ${source.path} (sha256 ${source.sha256})`);
  const c = summary.counts;
  out.push(`- Counts: ${c.stories} stories, ${c.scenarios} scenarios, ${c.edge_cases} edge cases, ${c.functional_requirements} functional requirements`);
  out.push(`- needs_quantification (Then has no digit): ${summary.needs_quantification.length === 0 ? 'none' : summary.needs_quantification.join(', ')}`);
  if (summary.needs_clarification.length === 0) out.push('- needs_clarification: none');
  for (const m of summary.needs_clarification) out.push(`- needs_clarification: ${m.where} (line ${m.line}): ${m.text}`);
  out.push(`- Ignored sections: ${summary.ignored_sections.length === 0 ? 'none' : summary.ignored_sections.map((s) => `${s.heading} (line ${s.line})`).join(', ')}`);
  if (summary.not_imported.length > 0) out.push(`- Not imported: ${summary.not_imported.join(', ')}`);
  out.push('');
  if (summary.edge_cases.length > 0) {
    out.push('### Edge cases (Spec Kit; turn each into a negative or boundary test by hand)');
    for (const e of summary.edge_cases) out.push(`- ${e.text}`);
    out.push('');
  }
  if (summary.functional_requirements.length > 0) {
    out.push('### Functional requirements (Spec Kit; an AC row cites an FR only when its scenario text does)');
    for (const r of summary.functional_requirements) out.push(`- ${r.id}: ${r.text}`);
    out.push('');
  }
  for (const story of summary.stories) {
    out.push(`## ${story.id}: ${story.title}`);
    out.push(`Spec Kit priority: ${story.priority} (User Story ${story.number}, line ${story.line})`);
    if (story.independent_test !== null) out.push(`Independent Test (Spec Kit): ${story.independent_test}`);
    out.push('');
    out.push('| Criterion | Method | Command |');
    out.push('|-----------|--------|---------|');
    for (const s of story.scenarios) {
      const refs = s.fr_refs.length > 0 ? ` [${s.fr_refs.join(', ')}]` : '';
      const flag = s.needs_quantification ? ' [needs_quantification]' : '';
      out.push(`| ${story.id} ${s.ac}: ${cell(s.then)}${refs}${flag} | TODO | TODO |`);
    }
    out.push('');
    out.push('Scenario source (Spec Kit):');
    for (const s of story.scenarios) out.push(`- ${s.ac}: Given ${s.given}, When ${s.when}, Then ${s.then}`);
    out.push('');
    for (const s of story.scenarios) {
      const key = `${pad(story.number)}-${s.ac}`;
      out.push(`**T-${key}-happy** TODO: a normal input that satisfies ${s.ac}`);
      out.push(`**T-${key}-negative** TODO: an input or state that must NOT satisfy ${s.ac}`);
      out.push(`**T-${key}-boundary** TODO: the numeric or limit edge of ${s.ac}`);
    }
    out.push('');
  }
  return `${out.join('\n').replace(/\n+$/u, '')}\n`;
}

// --------------------------------------------------------------------- output

// The final path component is what the splitter / gate-receipt globs see, so it is checked
// case-insensitively (APFS and NTFS fold case: TEST-SPEC-demo.md IS test-spec-demo.md there).
function assertSealableFreeName(outPath) {
  const base = path.basename(outPath);
  const sealable = /^test-spec-.*-US-.*\.md$/iu.test(base)
    || (/^test-spec-.+\.md$/iu.test(base) && !/\.speckit-draft\.md$/iu.test(base));
  if (sealable) {
    throw new Error(`refusing to write ${base}: it is a sealable test-spec name (the splitter and gate-receipt glob test-spec-<slug>.md and test-spec-<slug>-US-*.md). Use <name>.speckit-draft.md`);
  }
}

// Opens WITHOUT following a symlink (a dangling link to .rlp-desk/plans/test-spec-<slug>.md would otherwise
// create a sealable file under an innocent name) and without truncating: the existing content is checked
// through the same descriptor before anything is overwritten.
async function writeDraft(outPath, draft) {
  assertSealableFreeName(outPath);
  const stat = await fs.lstat(outPath).catch((error) => (error.code === 'ENOENT' ? null : Promise.reject(error)));
  if (stat !== null && stat.isSymbolicLink()) {
    throw new Error(`refusing to write through a symlink: ${outPath}`);
  }
  await fs.mkdir(path.dirname(outPath), { recursive: true });
  const flags = fsConstants.O_RDWR | fsConstants.O_CREAT | (fsConstants.O_NOFOLLOW ?? 0);
  let handle;
  try {
    handle = await fs.open(outPath, flags, 0o644);
  } catch (error) {
    if (error.code === 'ELOOP') throw new Error(`refusing to write through a symlink: ${outPath}`);
    throw error;
  }
  try {
    const head = Buffer.alloc(BANNER_PREFIX.length);
    const { bytesRead } = await handle.read(head, 0, head.length, 0);
    const fileStat = await handle.stat();
    if (fileStat.size > 0 && (bytesRead < head.length || head.toString('utf8') !== BANNER_PREFIX)) {
      throw new Error(`refusing to overwrite ${outPath}: it exists and is not a previous speckit draft`);
    }
    await handle.truncate(0);
    await handle.write(draft, 0, 'utf8');
  } finally {
    await handle.close();
  }
}

function emit(deps, text) {
  deps.stdout.write(text.endsWith('\n') ? text : `${text}\n`);
}

function parseArgs(args) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < args.length; i += 1) {
    const token = args[i];
    if (token === '--help' || token === '-h') flags.help = true;
    else if (token === '--json') flags.json = true;
    else if (token === '--slug' || token === '--out') {
      const value = args[i + 1];
      if (value === undefined || value.startsWith('--')) throw new UsageError(`missing value for ${token}`);
      flags[token.slice(2)] = value;
      i += 1;
    } else if (token.startsWith('-')) throw new UsageError(`unknown speckit option: ${token}`);
    else positional.push(token);
  }
  return { flags, positional };
}

function formatProblems(file, parsed) {
  if (parsed.placeholders.length > 0) {
    const shown = parsed.placeholders.slice(0, MAX_PLACEHOLDERS_SHOWN)
      .map((p) => `line ${p.line} ${JSON.stringify(p.text)}`).join('; ');
    const more = parsed.placeholders.length > MAX_PLACEHOLDERS_SHOWN ? `; +${parsed.placeholders.length - MAX_PLACEHOLDERS_SHOWN} more` : '';
    return `speckit: ${file} looks like the unfilled Spec Kit template (${parsed.placeholders.length} placeholder(s): ${shown}${more}). Fill the spec in first; nothing was drafted.`;
  }
  const lines = parsed.problems.map((p) => (p.line > 0 ? `  line ${p.line}: ${p.message}` : `  ${p.message}`));
  return `speckit: cannot draft from ${file}: ${parsed.problems.length} unrecognized item(s); nothing was drafted\n${lines.join('\n')}`;
}

async function runSpeckit(args, deps) {
  const { flags, positional } = parseArgs(args);
  if (flags.help) { emit(deps, USAGE); return 0; }
  if (positional.length === 0) throw new UsageError('missing <spec.md> path');
  if (positional.length > 1) throw new UsageError(`unexpected argument: ${positional[1]}`);
  const slug = flags.slug === undefined ? null : deps.requireCanonicalSlug(flags.slug); // IMP-08: reject, never normalize

  const file = path.resolve(deps.cwd, positional[0]);
  let raw;
  try {
    raw = await fs.readFile(file, 'utf8');
  } catch (error) {
    deps.stderr.write(`speckit: cannot read ${positional[0]}: ${error.code ?? error.message}\n`);
    return 1;
  }
  const parsed = parseSpecKit(raw);
  if (parsed.placeholders.length > 0 || parsed.problems.length > 0) {
    deps.stderr.write(`${formatProblems(positional[0], parsed)}\n`);
    return 1;
  }
  const summary = buildSummary(parsed, { relPath: posixRel(deps.cwd, file), hash: sha256(raw), slug });
  const draft = renderDraft(summary);

  if (flags.out !== undefined) {
    const outPath = path.resolve(deps.cwd, flags.out);
    try {
      await writeDraft(outPath, draft);
    } catch (error) {
      if (!/^refusing to /u.test(error.message)) throw error;
      deps.stderr.write(`speckit: ${error.message}\n`);
      return 1;
    }
    if (!flags.json) {
      emit(deps, `wrote ${posixRel(deps.cwd, outPath)} (${summary.counts.stories} stories, ${summary.counts.scenarios} scenarios; not sealed)`);
    }
  }
  if (flags.json) emit(deps, JSON.stringify(sortedClone(summary), null, 2));
  else if (flags.out === undefined) deps.stdout.write(draft);
  return 0;
}

export async function runCommand(args, deps) {
  try {
    return await runSpeckit(args, deps);
  } catch (error) {
    if (!(error instanceof UsageError)) throw error;
    deps.stderr.write(`${error.message}\n${USAGE}\n`);
    return EXIT_USAGE;
  }
}
