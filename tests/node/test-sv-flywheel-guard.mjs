import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

async function setupTestProject(slug) {
  const rootDir = await fs.mkdtemp(path.join(os.tmpdir(), 'sv-fg-'));
  const desk = path.join(rootDir, '.claude', 'ralph-desk');
  await fs.mkdir(path.join(desk, 'prompts'), { recursive: true });
  await fs.mkdir(path.join(desk, 'memos'), { recursive: true });
  await fs.mkdir(path.join(desk, 'plans'), { recursive: true });
  await fs.mkdir(path.join(desk, 'context'), { recursive: true });

  await fs.writeFile(path.join(desk, 'prompts', `${slug}.worker.prompt.md`), '# Worker');
  await fs.writeFile(path.join(desk, 'prompts', `${slug}.verifier.prompt.md`), '# Verifier');
  await fs.writeFile(path.join(desk, 'prompts', `${slug}.flywheel.prompt.md`), '# Flywheel');
  await fs.writeFile(path.join(desk, 'prompts', `${slug}.flywheel-guard.prompt.md`), '# Guard');
  await fs.writeFile(path.join(desk, 'memos', `${slug}-memory.md`), '# Memory\n## Stop Status\ncontinue');
  await fs.writeFile(path.join(desk, 'plans', `prd-${slug}.md`), '# PRD\n## US-001: Test Story\n### AC\n- AC1: test');
  await fs.writeFile(path.join(desk, 'plans', `test-spec-${slug}.md`), '# Test Spec');

  return rootDir;
}

function createMockOptions(rootDir, pollResponses, overrides = {}) {
  let pollCallIndex = 0;
  const sendKeysCalls = [];
  const statusHistory = [];

  return {
    rootDir,
    workerModel: 'sonnet',
    verifierModel: 'sonnet',
    finalVerifierModel: 'opus',
    maxIterations: 5,
    now: () => Date.now(),
    sendKeys: async (paneId, cmd) => { sendKeysCalls.push({ paneId, cmd }); },
    createPane: async () => `%${Math.floor(Math.random() * 1000)}`,
    createSession: async ({ sessionName }) => ({
      sessionName,
      leaderPaneId: '%0',
    }),
    pollForSignal: async (filePath) => {
      const response = pollResponses[pollCallIndex];
      pollCallIndex += 1;
      if (!response) throw new Error(`Unexpected poll #${pollCallIndex} for ${filePath}`);
      return response;
    },
    runIntegrationCheck: async () => ({ exitCode: 0, summary: 'ok' }),
    onStatusChange: (s) => { statusHistory.push({ ...s }); },
    _sendKeysCalls: sendKeysCalls,
    _statusHistory: statusHistory,
    ...overrides,
  };
}

// ===== SV-1: LOW — flywheel-guard off, flywheel runs without guard =====
test('SV-1 LOW: --flywheel-guard off → flywheel runs, no guard dispatched', async () => {
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const slug = 'sv1-gd-off';
  const rootDir = await setupTestProject(slug);

  // Poll sequence:
  // iter1: flywheel → worker → per-US verifier pass → ALL final verifier pass
  const pollResponses = [
    // 1: flywheel signal
    { iteration: 1, decision: 'hold', summary: 'keep current approach', contract_updated: true },
    // 2: worker signal (per-US)
    { iteration: 1, status: 'verify', us_id: 'US-001', summary: 'done' },
    // 3: per-US verifier verdict (pass)
    { verdict: 'pass', issues: [] },
    // 4: final sequential verifier verdict for US-001 (inside runFinalSequentialVerify)
    { verdict: 'pass', issues: [] },
  ];

  const opts = createMockOptions(rootDir, pollResponses, {
    flywheel: 'on-fail',
    flywheelGuard: 'off',  // Guard OFF
    workerModel: 'sonnet',
  });

  // Set consecutive_failures > 0 to trigger flywheel
  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    iteration: 1,
    consecutive_failures: 1,
    current_us: 'US-001',
    phase: 'worker',
  }));

  const result = await run(slug, opts);

  // Verify: flywheel dispatched (sendKeys has flywheel cmd) but NO guard dispatch
  const flywheelCmds = opts._sendKeysCalls.filter(c => c.cmd.includes('flywheel'));
  const guardCmds = opts._sendKeysCalls.filter(c => c.cmd.includes('guard'));
  assert.ok(flywheelCmds.length > 0, 'flywheel was dispatched');
  assert.equal(guardCmds.length, 0, 'guard was NOT dispatched when off');
  assert.equal(result.status, 'complete');

  await fs.rm(rootDir, { recursive: true, force: true });
});

// ===== SV-2: MEDIUM-1 — Guard catches look-ahead bias (Check 1 FAIL) =====
test('SV-2 MEDIUM-1: guard catches look-ahead bias → flywheel retries → corrected', async () => {
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const slug = 'sv2-lookahead';
  const rootDir = await setupTestProject(slug);

  // Poll sequence:
  // iter1: flywheel → guard FAIL → retry (continue to iter2)
  // iter2: flywheel → guard PASS → worker → verifier PASS → ALL → final PASS
  const pollResponses = [
    // iter1: flywheel signal
    { iteration: 1, decision: 'pivot', summary: 'use peak_pct segments' },
    // iter1: guard verdict — FAIL (look-ahead bias)
    { verdict: 'fail', issues: [{ check: 'look-ahead-bias', status: 'fail', detail: 'peak_pct is post-hoc' }], analysis_only: false, recommendation: 'retry-flywheel' },
    // iter2: flywheel signal (corrected)
    { iteration: 2, decision: 'hold', summary: 'use entry-time segments only' },
    // iter2: guard verdict — PASS
    { verdict: 'pass', issues: [], analysis_only: false, recommendation: 'proceed' },
    // iter2: worker signal
    { iteration: 2, status: 'verify', us_id: 'US-001', summary: 'done' },
    // iter2: per-US verifier verdict (pass)
    { verdict: 'pass', issues: [] },
    // final sequential verifier verdict for US-001
    { verdict: 'pass', issues: [] },
  ];

  const opts = createMockOptions(rootDir, pollResponses, {
    flywheel: 'on-fail',
    flywheelGuard: 'on',
  });

  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    iteration: 1,
    consecutive_failures: 1,
    current_us: 'US-001',
    phase: 'worker',
  }));

  const result = await run(slug, opts);

  // Verify: guard was dispatched, flywheel retried, eventually completed
  const guardCmds = opts._sendKeysCalls.filter(c => c.cmd.includes('guard'));
  assert.ok(guardCmds.length >= 2, 'guard dispatched at least twice (fail + pass)');
  assert.equal(result.status, 'complete');

  // Verify phases included 'guard'
  const guardPhases = opts._statusHistory.filter(s => s.phase === 'guard');
  assert.ok(guardPhases.length >= 1, 'guard phase was recorded');

  await fs.rm(rootDir, { recursive: true, force: true });
});

// ===== SV-3: MEDIUM-2 — Guard catches metric mismatch (Check 2 FAIL) =====
test('SV-3 MEDIUM-2: guard catches metric mismatch → escalation (blocked)', async () => {
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const slug = 'sv3-metric';
  const rootDir = await setupTestProject(slug);

  // Guard returns inconclusive on metric mismatch (requires PRD update → escalate)
  const pollResponses = [
    // flywheel signal
    { iteration: 1, decision: 'hold', summary: 'optimize by median gap' },
    // guard verdict — inconclusive (metric mismatch needs user decision)
    { verdict: 'inconclusive', issues: [{ check: 'metric-alignment', status: 'inconclusive', detail: 'PRD says mean PnL but flywheel uses median gap' }], analysis_only: false, recommendation: 'escalate-to-user' },
  ];

  const opts = createMockOptions(rootDir, pollResponses, {
    flywheel: 'on-fail',
    flywheelGuard: 'on',
  });

  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    iteration: 1,
    consecutive_failures: 1,
    current_us: 'US-001',
    phase: 'worker',
  }));

  const result = await run(slug, opts);

  assert.equal(result.status, 'blocked');
  assert.equal(result.reason, 'flywheel-guard-escalate-inconclusive');
  assert.ok(result.guardIssues.length > 0, 'guard issues included in result');
  assert.equal(result.guardIssues[0].check, 'metric-alignment');

  await fs.rm(rootDir, { recursive: true, force: true });
});

// ===== SV-4: MEDIUM-3 — Guard catches repeat pattern (Check 4 FAIL) =====
test('SV-4 MEDIUM-3: guard catches repeat pattern → flywheel retries with different approach', async () => {
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const slug = 'sv4-repeat';
  const rootDir = await setupTestProject(slug);

  const pollResponses = [
    // iter1: flywheel (repeats rejected direction)
    { iteration: 1, decision: 'pivot', summary: 'try peak segmentation again' },
    // iter1: guard FAIL (repeat pattern)
    { verdict: 'fail', issues: [{ check: 'repeat-pattern', status: 'fail', detail: 'same direction as rejected in iter-3' }], analysis_only: false, recommendation: 'retry-flywheel' },
    // iter2: flywheel (different approach)
    { iteration: 2, decision: 'reduce', summary: 'simplify to global best only' },
    // iter2: guard PASS
    { verdict: 'pass', issues: [], analysis_only: false, recommendation: 'proceed' },
    // iter2: worker signal
    { iteration: 2, status: 'verify', us_id: 'US-001', summary: 'done' },
    // iter2: per-US verifier pass
    { verdict: 'pass', issues: [] },
    // final sequential verifier verdict for US-001
    { verdict: 'pass', issues: [] },
  ];

  const opts = createMockOptions(rootDir, pollResponses, {
    flywheel: 'on-fail',
    flywheelGuard: 'on',
  });

  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    iteration: 1,
    consecutive_failures: 1,
    current_us: 'US-001',
    phase: 'worker',
  }));

  const result = await run(slug, opts);

  assert.equal(result.status, 'complete');
  // Verify guard caught repeat and flywheel retried
  const guardPhases = opts._statusHistory.filter(s => s.phase === 'guard');
  assert.ok(guardPhases.length >= 1, 'guard phase recorded');

  await fs.rm(rootDir, { recursive: true, force: true });
});

// ===== SV-5: CRITICAL — Guard fails 2x → BLOCKED with escalation =====
test('SV-5 CRITICAL: guard fails 3x → BLOCKED with retries-exhausted reason', async () => {
  const { run } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const slug = 'sv5-exhausted';
  const rootDir = await setupTestProject(slug);

  // 3 flywheel+guard cycles, all guard FAIL
  const pollResponses = [
    // iter1: flywheel → guard FAIL
    { iteration: 1, decision: 'pivot', summary: 'try approach A' },
    { verdict: 'fail', issues: [{ check: 'look-ahead-bias', status: 'fail', detail: 'uses future data' }], analysis_only: false, recommendation: 'retry-flywheel' },
    // iter2: flywheel → guard FAIL
    { iteration: 2, decision: 'pivot', summary: 'try approach B' },
    { verdict: 'fail', issues: [{ check: 'deployability', status: 'fail', detail: 'requires infra not in PRD' }], analysis_only: false, recommendation: 'retry-flywheel' },
    // iter3: flywheel → guard FAIL (3rd time = exhausted)
    { iteration: 3, decision: 'pivot', summary: 'try approach C' },
    { verdict: 'fail', issues: [{ check: 'metric-alignment', status: 'fail', detail: 'wrong metric' }], analysis_only: false, recommendation: 'retry-flywheel' },
  ];

  const opts = createMockOptions(rootDir, pollResponses, {
    flywheel: 'on-fail',
    flywheelGuard: 'on',
  });

  const statusFile = path.join(rootDir, '.claude', 'ralph-desk', 'logs', slug, 'runtime', 'status.json');
  await fs.mkdir(path.dirname(statusFile), { recursive: true });
  await fs.writeFile(statusFile, JSON.stringify({
    iteration: 1,
    consecutive_failures: 1,
    current_us: 'US-001',
    phase: 'worker',
  }));

  const result = await run(slug, opts);

  assert.equal(result.status, 'blocked');
  assert.equal(result.reason, 'flywheel-guard-retries-exhausted');
  assert.ok(result.guardIssues, 'guard issues present in result');
  assert.ok(result.guardIssues.length > 0, 'at least one guard issue');

  // Verify blocked sentinel was written
  const blockedFile = path.join(rootDir, '.claude', 'ralph-desk', 'memos', `${slug}-blocked.md`);
  const blockedContent = await fs.readFile(blockedFile, 'utf8');
  assert.match(blockedContent, /BLOCKED/);

  await fs.rm(rootDir, { recursive: true, force: true });
});
