import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';

import { LEGACY_DESK_REL, resolveDeskRoot } from '../util/desk-root.mjs';

const GITIGNORE_MARKER = '# RLP Desk runtime artifacts';
const GITIGNORE_RULE = '.rlp-desk/';
const LEGACY_GITIGNORE_RULE = '.claude/ralph-desk/';
const MIGRATION_LOCK_FILE = '.rlp-desk-migration.lock';
const STALE_LOCK_MS = 5 * 60 * 1000;

export function migrateLegacyDesk(rootDir, env = process.env) {
  const legacyPath = path.join(rootDir, LEGACY_DESK_REL);
  const newPath = resolveDeskRoot(rootDir, env);
  const lockPath = path.join(rootDir, MIGRATION_LOCK_FILE);

  // Pre-lock cheap check: skip the lock entirely when there is nothing to do.
  // Re-check the same conditions inside the lock — a competing process may
  // have moved or created files between this check and the lock acquisition.
  if (!fsSync.existsSync(legacyPath)) {
    return { action: 'noop', reason: fsSync.existsSync(newPath) ? 'new-only' : 'neither-exists' };
  }

  let lockFd;
  try {
    lockFd = fsSync.openSync(lockPath, 'wx');
  } catch (error) {
    if (error.code === 'EEXIST') {
      try {
        const stats = fsSync.statSync(lockPath);
        const age = Date.now() - stats.mtimeMs;
        if (age > STALE_LOCK_MS) {
          fsSync.unlinkSync(lockPath);
          lockFd = fsSync.openSync(lockPath, 'wx');
        } else {
          throw new Error(`Migration already in progress (lock at ${lockPath}, age ${Math.round(age / 1000)}s)`);
        }
      } catch (statError) {
        if (statError.code === 'ENOENT') {
          lockFd = fsSync.openSync(lockPath, 'wx');
        } else {
          throw statError;
        }
      }
    } else {
      throw error;
    }
  }

  try {
    fsSync.writeSync(lockFd, String(process.pid));

    // Re-check inside the lock — another process may have already migrated
    // while we were waiting for the lock.
    const legacyExistsLocked = fsSync.existsSync(legacyPath);
    const newExistsLocked = fsSync.existsSync(newPath);

    if (!legacyExistsLocked) {
      return { action: 'noop', reason: newExistsLocked ? 'new-only' : 'neither-exists' };
    }

    if (newExistsLocked) {
      throw new Error(
        `Migration aborted: both directories exist. Remove one before re-run. legacy=${legacyPath}, new=${newPath}`,
      );
    }

    fsSync.mkdirSync(path.dirname(newPath), { recursive: true });
    fsSync.renameSync(legacyPath, newPath);
    return { action: 'migrated', from: legacyPath, to: newPath };
  } finally {
    try { fsSync.closeSync(lockFd); } catch (_) { /* noop */ }
    try { fsSync.unlinkSync(lockPath); } catch (_) { /* noop */ }
  }
}

export async function initCampaign(slug, objective, options = {}) {
  const normalizedSlug = normalizeSlug(slug);
  const normalizedObjective = objective?.trim() || 'TBD - fill in the objective';
  const mode = options.mode ?? 'agent';
  const rootDir = path.resolve(options.rootDir ?? process.cwd());
  const tmuxEnv = options.tmuxEnv ?? process.env.TMUX ?? '';
  const env = options.env ?? process.env;

  if (mode === 'tmux' && !tmuxEnv) {
    throw new Error('tmux required');
  }

  migrateLegacyDesk(rootDir, env);

  const deskRoot = resolveDeskRoot(rootDir, env);

  if (mode === 'fresh') {
    await fs.rm(deskRoot, { recursive: true, force: true });
  }

  const paths = buildPaths(rootDir, normalizedSlug, env);
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

function buildPaths(rootDir, slug, env = process.env) {
  const deskRoot = resolveDeskRoot(rootDir, env);
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

  let updated = content;
  let changed = false;

  // v0.13.0: drop the legacy .claude/ralph-desk/ rule if present.
  if (updated.includes(LEGACY_GITIGNORE_RULE)) {
    const legacyLineRegex = new RegExp(
      `^${LEGACY_GITIGNORE_RULE.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\r?\\n`,
      'gm',
    );
    updated = updated.replace(legacyLineRegex, '');
    changed = true;
  }

  if (!(updated.includes(GITIGNORE_MARKER) && updated.includes(GITIGNORE_RULE))) {
    const prefix = updated.length > 0 && !updated.endsWith('\n') ? '\n' : '';
    updated = `${updated}${prefix}${GITIGNORE_MARKER}\n${GITIGNORE_RULE}\n`;
    changed = true;
  }

  if (changed) {
    await fs.writeFile(gitignorePath, updated, 'utf8');
  }
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
