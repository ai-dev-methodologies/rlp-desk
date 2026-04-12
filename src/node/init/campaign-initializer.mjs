import fs from 'node:fs/promises';
import path from 'node:path';

const GITIGNORE_MARKER = '# RLP Desk runtime artifacts';
const GITIGNORE_RULE = '.claude/ralph-desk/';

export async function initCampaign(slug, objective, options = {}) {
  const normalizedSlug = normalizeSlug(slug);
  const normalizedObjective = objective?.trim() || 'TBD - fill in the objective';
  const mode = options.mode ?? 'agent';
  const rootDir = path.resolve(options.rootDir ?? process.cwd());
  const tmuxEnv = options.tmuxEnv ?? process.env.TMUX ?? '';
  const deskRoot = path.join(rootDir, '.claude', 'ralph-desk');

  if (mode === 'tmux' && !tmuxEnv) {
    throw new Error('tmux required');
  }

  if (mode === 'fresh') {
    await fs.rm(deskRoot, { recursive: true, force: true });
  }

  const paths = buildPaths(rootDir, normalizedSlug);
  await ensureDirectories(paths);
  await ensureGitignore(rootDir);

  await writeIfMissing(paths.workerPrompt, buildWorkerPrompt(normalizedSlug, normalizedObjective));
  await writeIfMissing(paths.verifierPrompt, buildVerifierPrompt(normalizedSlug));
  await writeIfMissing(paths.contextFile, buildContext(normalizedSlug));
  await writeIfMissing(paths.memoryFile, buildMemory(normalizedSlug, normalizedObjective));

  const prdContent = options.prdContent ?? buildPrd(normalizedSlug, normalizedObjective);
  await fs.writeFile(paths.prdFile, prdContent, 'utf8');
  await writeIfMissing(paths.testSpecFile, buildTestSpec(normalizedSlug));
  await splitPrdByUs(paths.plansDir, normalizedSlug, prdContent, normalizedObjective);

  return {
    slug: normalizedSlug,
    paths,
  };
}

export const init = initCampaign;

function normalizeSlug(value) {
  const slug = (value ?? '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');

  if (!slug) {
    throw new Error('slug is required');
  }

  return slug;
}

function buildPaths(rootDir, slug) {
  const deskRoot = path.join(rootDir, '.claude', 'ralph-desk');
  const promptsDir = path.join(deskRoot, 'prompts');
  const plansDir = path.join(deskRoot, 'plans');
  const memosDir = path.join(deskRoot, 'memos');
  const logsDir = path.join(deskRoot, 'logs');
  const contextDir = path.join(deskRoot, 'context');

  return {
    deskRoot,
    promptsDir,
    plansDir,
    memosDir,
    logsDir,
    contextDir,
    workerPrompt: path.join(promptsDir, `${slug}.worker.prompt.md`),
    verifierPrompt: path.join(promptsDir, `${slug}.verifier.prompt.md`),
    contextFile: path.join(contextDir, `${slug}-latest.md`),
    memoryFile: path.join(memosDir, `${slug}-memory.md`),
    prdFile: path.join(plansDir, `prd-${slug}.md`),
    testSpecFile: path.join(plansDir, `test-spec-${slug}.md`),
    campaignLogDir: path.join(logsDir, slug),
  };
}

async function ensureDirectories(paths) {
  await Promise.all(
    [
      paths.promptsDir,
      paths.plansDir,
      paths.memosDir,
      paths.logsDir,
      paths.contextDir,
      paths.campaignLogDir,
    ].map((directory) => fs.mkdir(directory, { recursive: true })),
  );
}

async function ensureGitignore(rootDir) {
  const gitignorePath = path.join(rootDir, '.gitignore');
  let content = '';

  try {
    content = await fs.readFile(gitignorePath, 'utf8');
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
  }

  if (content.includes(GITIGNORE_MARKER) && content.includes(GITIGNORE_RULE)) {
    return;
  }

  const prefix = content.length > 0 && !content.endsWith('\n') ? '\n' : '';
  const block = `${prefix}${GITIGNORE_MARKER}\n${GITIGNORE_RULE}\n`;
  await fs.writeFile(gitignorePath, `${content}${block}`, 'utf8');
}

async function writeIfMissing(targetPath, content) {
  try {
    await fs.access(targetPath);
  } catch (error) {
    if (error.code !== 'ENOENT') {
      throw error;
    }
    await fs.writeFile(targetPath, content, 'utf8');
  }
}

function buildWorkerPrompt(slug, objective) {
  return `Execute the plan for ${slug}.\n\n## Objective\n${objective}\n`;
}

function buildVerifierPrompt(slug) {
  return `Independent verifier for Ralph Desk: ${slug}\n`;
}

function buildContext(slug) {
  return `# ${slug} - Latest Context\n`;
}

function buildMemory(slug, objective) {
  return `# ${slug} - Campaign Memory\n\n## Stop Status\ncontinue\n\n## Objective\n${objective}\n`;
}

function buildPrd(slug, objective) {
  return `# PRD: ${slug}\n\n## Objective\n${objective}\n`;
}

function buildTestSpec(slug) {
  return `# Test Specification: ${slug}\n`;
}

async function splitPrdByUs(plansDir, slug, prdContent, fallbackObjective) {
  const matches = extractUsSections(prdContent);
  const objectiveBlock = extractObjectiveBlock(prdContent, fallbackObjective);

  await removeExistingSplitFiles(plansDir, slug);

  await Promise.all(
    matches.map((section) => {
      const usId = section.match(/^## (US-\d{3}):/m)?.[1];
      if (!usId) {
        return Promise.resolve();
      }

      const content = `# PRD: ${slug}\n\n${objectiveBlock}\n\n${section}\n`;
      return fs.writeFile(path.join(plansDir, `prd-${slug}-${usId}.md`), content, 'utf8');
    }),
  );
}

async function removeExistingSplitFiles(plansDir, slug) {
  const entries = await fs.readdir(plansDir, { withFileTypes: true });
  const prefix = `prd-${slug}-US-`;

  await Promise.all(
    entries
      .filter((entry) => entry.isFile() && entry.name.startsWith(prefix) && entry.name.endsWith('.md'))
      .map((entry) => fs.rm(path.join(plansDir, entry.name), { force: true })),
  );
}

function extractObjectiveBlock(prdContent, fallbackObjective) {
  const lines = prdContent.split(/\r?\n/);
  const collected = [];
  let collecting = false;

  for (const line of lines) {
    if (/^## Objective\s*$/.test(line)) {
      collecting = true;
      collected.push('## Objective');
      continue;
    }

    if (collecting && /^## US-\d{3}:/.test(line)) {
      break;
    }

    if (collecting) {
      collected.push(line);
    }
  }

  const content = collected.join('\n').trim();
  if (content) {
    return content;
  }

  return `## Objective\n${fallbackObjective}`;
}

function extractUsSections(prdContent) {
  const lines = prdContent.split(/\r?\n/);
  const sections = [];
  let current = [];

  for (const line of lines) {
    if (/^## US-\d{3}:/.test(line)) {
      if (current.length > 0) {
        sections.push(current.join('\n').trim());
      }
      current = [line];
      continue;
    }

    if (current.length > 0) {
      current.push(line);
    }
  }

  if (current.length > 0) {
    sections.push(current.join('\n').trim());
  }

  return sections;
}
