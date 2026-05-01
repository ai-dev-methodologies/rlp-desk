import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us005-campaign-initializer-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

function deskPath(rootDir, ...segments) {
  return path.join(rootDir, '.rlp-desk', ...segments);
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function readFile(targetPath) {
  return fs.readFile(targetPath, 'utf8');
}

async function writeFile(targetPath, content) {
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, content, 'utf8');
}

function prdWithUsSections(objective, sections) {
  return [
    '# PRD: test-campaign',
    '',
    '## Objective',
    objective,
    '',
    ...sections,
    '',
  ].join('\n');
}

test('US-005 AC5.1 happy: initCampaign creates the scaffold directories and base files', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  const result = await initCampaign('test-campaign', 'Ship the Node rewrite', {
    rootDir,
  });

  assert.equal(result.slug, 'test-campaign');
  for (const relativeDir of ['prompts', 'plans', 'memos', 'logs', 'context']) {
    const directoryPath = deskPath(rootDir, relativeDir);
    const stats = await fs.stat(directoryPath);
    assert.equal(stats.isDirectory(), true, `${relativeDir} should exist`);
  }

  for (const targetPath of [
    deskPath(rootDir, 'prompts', 'test-campaign.worker.prompt.md'),
    deskPath(rootDir, 'prompts', 'test-campaign.verifier.prompt.md'),
    deskPath(rootDir, 'context', 'test-campaign-latest.md'),
    deskPath(rootDir, 'memos', 'test-campaign-memory.md'),
    deskPath(rootDir, 'plans', 'prd-test-campaign.md'),
    deskPath(rootDir, 'plans', 'test-spec-test-campaign.md'),
    deskPath(rootDir, 'logs', 'test-campaign'),
  ]) {
    assert.equal(await exists(targetPath), true, `${targetPath} should exist`);
  }
});

test('US-005 AC5.1 boundary: initCampaign sanitizes special-character slugs and does not duplicate gitignore rules', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const gitignorePath = path.join(rootDir, '.gitignore');

  await writeFile(
    gitignorePath,
    ['# Existing rules', '# RLP Desk runtime artifacts', '.rlp-desk/', ''].join('\n'),
  );

  const result = await initCampaign('Test Campaign!@#', 'Ship the Node rewrite', {
    rootDir,
  });

  assert.equal(result.slug, 'test-campaign');
  assert.equal(
    await exists(deskPath(rootDir, 'prompts', 'test-campaign.worker.prompt.md')),
    true,
  );

  const gitignoreContent = await readFile(gitignorePath);
  assert.equal(gitignoreContent.match(/# RLP Desk runtime artifacts/g)?.length ?? 0, 1);
  assert.equal(gitignoreContent.match(/\.rlp-desk\//g)?.length ?? 0, 1);
  assert.equal(gitignoreContent.match(/\.claude\/ralph-desk\//g)?.length ?? 0, 0);
});

test('US-005 AC5.1 negative: initCampaign completes a partial scaffold instead of leaving missing files behind', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await fs.mkdir(deskPath(rootDir, 'prompts'), { recursive: true });
  await writeFile(
    deskPath(rootDir, 'prompts', 'test-campaign.worker.prompt.md'),
    'existing worker prompt\n',
  );

  await initCampaign('test-campaign', 'Ship the Node rewrite', {
    rootDir,
  });

  for (const targetPath of [
    deskPath(rootDir, 'prompts', 'test-campaign.verifier.prompt.md'),
    deskPath(rootDir, 'context', 'test-campaign-latest.md'),
    deskPath(rootDir, 'memos', 'test-campaign-memory.md'),
    deskPath(rootDir, 'plans', 'prd-test-campaign.md'),
    deskPath(rootDir, 'plans', 'test-spec-test-campaign.md'),
  ]) {
    assert.equal(await exists(targetPath), true, `${targetPath} should exist`);
  }
});

test('US-005 AC5.2 happy: initCampaign creates one per-US PRD file for each ## US-NNN section', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const objective = 'Ship the Node rewrite';

  await initCampaign('test-campaign', objective, {
    rootDir,
    prdContent: prdWithUsSections(objective, [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
      '## US-003: Third story\nGamma details.',
    ]),
  });

  for (const suffix of ['001', '002', '003']) {
    assert.equal(
      await exists(deskPath(rootDir, 'plans', `prd-test-campaign-US-${suffix}.md`)),
      true,
    );
  }
});

test('US-005 AC5.2 boundary: each split PRD keeps the objective header and only its own US section', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const objective = 'Ship the Node rewrite';

  await initCampaign('test-campaign', objective, {
    rootDir,
    prdContent: prdWithUsSections(objective, [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details only.',
      '## US-003: Third story\nGamma details.',
    ]),
  });

  const splitContent = await readFile(deskPath(rootDir, 'plans', 'prd-test-campaign-US-002.md'));
  assert.match(splitContent, /## Objective\nShip the Node rewrite/);
  assert.match(splitContent, /## US-002: Second story\nBeta details only\./);
  assert.doesNotMatch(splitContent, /US-001|Alpha details|US-003|Gamma details/);
});

test('US-005 AC5.2 negative: initCampaign does not create per-US PRDs when the PRD markers do not match ## US-NNN', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');
  const objective = 'Ship the Node rewrite';

  await initCampaign('test-campaign', objective, {
    rootDir,
    prdContent: [
      '# PRD: test-campaign',
      '',
      '## Objective',
      objective,
      '',
      '### US-001: Wrong marker',
      'Alpha details.',
      '',
      '### US-002: Wrong marker',
      'Beta details.',
      '',
    ].join('\n'),
  });

  assert.equal(
    await exists(deskPath(rootDir, 'plans', 'prd-test-campaign-US-001.md')),
    false,
  );
  assert.equal(
    await exists(deskPath(rootDir, 'plans', 'prd-test-campaign-US-002.md')),
    false,
  );
});

test('US-005 AC5.3 happy: initCampaign fresh mode recreates the PRD instead of preserving old content', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await initCampaign('test-campaign', 'Old objective', {
    rootDir,
    prdContent: prdWithUsSections('Old objective', ['## US-001: Old story\nOld content.']),
  });

  await writeFile(
    deskPath(rootDir, 'plans', 'prd-test-campaign.md'),
    prdWithUsSections('Old objective', ['## US-001: Old story\nPRESERVE-ME-NOT']),
  );

  await initCampaign('test-campaign', 'New objective', {
    rootDir,
    mode: 'fresh',
    prdContent: prdWithUsSections('New objective', ['## US-001: New story\nFresh content.']),
  });

  const prdContent = await readFile(deskPath(rootDir, 'plans', 'prd-test-campaign.md'));
  assert.match(prdContent, /## Objective\nNew objective/);
  assert.match(prdContent, /Fresh content\./);
  assert.doesNotMatch(prdContent, /PRESERVE-ME-NOT/);
});

test('US-005 AC5.3 boundary: initCampaign fresh mode removes stale per-US PRD files before recreating them', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await initCampaign('test-campaign', 'Old objective', {
    rootDir,
    prdContent: prdWithUsSections('Old objective', [
      '## US-001: First story\nAlpha details.',
      '## US-002: Second story\nBeta details.',
      '## US-003: Third story\nGamma details.',
    ]),
  });

  await initCampaign('test-campaign', 'New objective', {
    rootDir,
    mode: 'fresh',
    prdContent: prdWithUsSections('New objective', ['## US-001: Only story\nFresh content.']),
  });

  assert.equal(
    await exists(deskPath(rootDir, 'plans', 'prd-test-campaign-US-001.md')),
    true,
  );
  assert.equal(
    await exists(deskPath(rootDir, 'plans', 'prd-test-campaign-US-002.md')),
    false,
  );
  assert.equal(
    await exists(deskPath(rootDir, 'plans', 'prd-test-campaign-US-003.md')),
    false,
  );
});

test('US-005 AC5.3 negative: initCampaign fresh mode still creates a new PRD when no prior PRD exists', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await initCampaign('test-campaign', 'Fresh objective', {
    rootDir,
    mode: 'fresh',
  });

  const prdContent = await readFile(deskPath(rootDir, 'plans', 'prd-test-campaign.md'));
  assert.match(prdContent, /## Objective\nFresh objective/);
});

test('US-005 AC5.4 happy: initCampaign in agent mode does not require tmux', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await initCampaign('test-campaign', 'Ship the Node rewrite', {
    rootDir,
    mode: 'agent',
    tmuxEnv: '',
  });

  assert.equal(await exists(deskPath(rootDir, 'plans', 'prd-test-campaign.md')), true);
});

test('US-005 AC5.4 boundary: initCampaign in tmux mode proceeds when a tmux session marker is present', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await initCampaign('test-campaign', 'Ship the Node rewrite', {
    rootDir,
    mode: 'tmux',
    tmuxEnv: '/tmp/tmux-session,1234,0',
  });

  assert.equal(await exists(deskPath(rootDir, 'logs', 'test-campaign')), true);
});

test('US-005 AC5.4 negative: initCampaign rejects tmux mode without a tmux session and creates no scaffold', async (t) => {
  const rootDir = await createTempDir(t);
  const { initCampaign } = await import('../../src/node/init/campaign-initializer.mjs');

  await assert.rejects(
    initCampaign('test-campaign', 'Ship the Node rewrite', {
      rootDir,
      mode: 'tmux',
      tmuxEnv: '',
    }),
    /tmux required/,
  );

  assert.equal(await exists(deskPath(rootDir)), false);
});
