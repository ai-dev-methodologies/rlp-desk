import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { resolveAnalyticsPointer } from '../../src/node/runner/campaign-main-loop.mjs';
import { main } from '../../src/node/run.mjs';

// IMP-03 — the SV post-pass must read the campaign.jsonl the zsh leader
// actually wrote.
//
// The production zsh leader writes analytics under
// `$DESK/analytics/<slug>--<md5(ROOT):0:8>/` (run_ralph_desk.zsh) while the
// Node SV post-pass historically used buildPaths' un-hashed
// `analytics/<slug>` + `logs/<slug>/campaign.jsonl` — so readAnalytics
// returned [] and `--with-self-verification` silently produced an
// analytics-blind report. The zsh leader now writes a hash-free POINTER file
// `analytics/<slug>.current` containing the resolved dir; the reader resolves
// through it with a legacy fallback (absent pointer → old paths, no worse
// than before). Cross-platform hash parity is a NON-goal — the pointer makes
// the reader hash-agnostic (plan rev3, architect A2).

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'imp03-sv-pointer');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function seedHashedAnalytics(deskRoot, slug) {
  const hashedDir = path.join(deskRoot, 'analytics', `${slug}--deadbeef`);
  await fs.mkdir(hashedDir, { recursive: true });
  const records = [
    { iter: 1, us_id: 'US-001', claude_verdict: 'pass', slug },
    { iter: 2, us_id: 'ALL', claude_verdict: 'pass', slug },
  ];
  await fs.writeFile(
    path.join(hashedDir, 'campaign.jsonl'),
    records.map((r) => JSON.stringify(r)).join('\n') + '\n',
  );
  await fs.writeFile(path.join(deskRoot, 'analytics', `${slug}.current`), `${hashedDir}\n`);
  return hashedDir;
}

test('IMP-03: resolveAnalyticsPointer resolves a present pointer to the hashed dir', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = path.join(rootDir, '.rlp-desk');
  const slug = 'imp03-unit';
  const hashedDir = await seedHashedAnalytics(deskRoot, slug);

  const resolved = await resolveAnalyticsPointer(deskRoot, slug);
  assert.ok(resolved, 'pointer must resolve');
  assert.equal(resolved.analyticsDir, hashedDir);
  assert.equal(resolved.analyticsFile, path.join(hashedDir, 'campaign.jsonl'));
});

test('IMP-03: resolveAnalyticsPointer returns null when pointer is absent (legacy fallback)', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = path.join(rootDir, '.rlp-desk');
  await fs.mkdir(path.join(deskRoot, 'analytics'), { recursive: true });

  assert.equal(await resolveAnalyticsPointer(deskRoot, 'no-pointer'), null);
});

test('IMP-03: resolveAnalyticsPointer returns null when the pointed dir is gone (stale pointer)', async (t) => {
  const rootDir = await createTempDir(t);
  const deskRoot = path.join(rootDir, '.rlp-desk');
  const slug = 'imp03-stale';
  await fs.mkdir(path.join(deskRoot, 'analytics'), { recursive: true });
  await fs.writeFile(
    path.join(deskRoot, 'analytics', `${slug}.current`),
    path.join(deskRoot, 'analytics', `${slug}--gone`) + '\n',
  );

  assert.equal(await resolveAnalyticsPointer(deskRoot, slug), null);
});

test('IMP-03: tmux SV post-pass reads the pointer-resolved campaign.jsonl (analytics_count 2, report in hashed dir)', async (t) => {
  const rootDir = await createTempDir(t);
  const slug = 'imp03-wire';
  const deskRoot = path.join(rootDir, '.rlp-desk');
  await fs.mkdir(path.join(deskRoot, 'logs', slug), { recursive: true });
  const hashedDir = await seedHashedAnalytics(deskRoot, slug);

  let stdoutText = '';
  const code = await main(
    ['run', slug, '--mode', 'tmux', '--with-self-verification'],
    {
      cwd: rootDir,
      stdout: { write: (s) => { stdoutText += s; } },
      stderr: { write: () => {} },
      spawnZsh: async () => 0,
      zshRunnerPath: () => '/fake/run_ralph_desk.zsh',
      fileExists: () => true,
    },
  );
  assert.equal(code, 0, stdoutText);
  assert.match(stdoutText, /Self-verification report/);

  // Decisive: the SV data must land in the POINTER-resolved (hashed) dir and
  // must have SEEN the 2 zsh-written analytics records — not the empty
  // un-hashed legacy location.
  const data = JSON.parse(
    await fs.readFile(path.join(hashedDir, 'self-verification-data.json'), 'utf8'),
  );
  assert.equal(data.analytics_count, 2, 'SV must read the zsh-written campaign.jsonl');
});
