import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

async function createTempDir(t) {
  const tempRoot = path.join(repoRoot, '.tmp', 'us004-prompt-assembler-tests');
  await fs.mkdir(tempRoot, { recursive: true });
  const directory = await fs.mkdtemp(path.join(tempRoot, 'case-'));
  t.after(async () => {
    await fs.rm(directory, { recursive: true, force: true });
  });
  return directory;
}

async function writeFile(filePath, content) {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await fs.writeFile(filePath, content, 'utf8');
}

async function buildWorkerFixtures(t, options = {}) {
  const tempDir = await createTempDir(t);
  const promptBase = path.join(tempDir, 'prompts', 'node-rewrite.worker.prompt.md');
  const memoryFile = path.join(tempDir, 'memos', 'node-rewrite-memory.md');
  const fullPrdPath = path.join(tempDir, 'plans', 'prd-node-rewrite.md');
  const perUsPrdPath = path.join(tempDir, 'plans', 'prd-node-rewrite-US-004.md');
  const testSpecPath = path.join(tempDir, 'plans', 'test-spec-node-rewrite.md');
  const perUsTestSpecPath = path.join(tempDir, 'plans', 'test-spec-node-rewrite-US-004.md');
  const conflictLogPath = path.join(tempDir, 'logs', 'conflict-log.jsonl');
  const fixContractPath = path.join(tempDir, 'logs', 'iter-002.fix-contract.md');

  await writeFile(
    promptBase,
    options.promptBaseContent ??
      [
        'Execute the plan for node-rewrite.',
        '',
        'PRD: ' + fullPrdPath,
        'Test Spec: ' + testSpecPath,
      ].join('\n'),
  );

  await writeFile(
    memoryFile,
    options.memoryContent ??
      [
        '# node-rewrite - Campaign Memory',
        '',
        '## Stop Status',
        'verify',
        '',
        '## Next Iteration Contract',
        'Verifier should check US-003 only.',
        '',
        '## Tail',
        'ignored',
      ].join('\n'),
  );

  await writeFile(fullPrdPath, '# full prd\n');
  await writeFile(testSpecPath, '# full test spec\n');

  if (options.includePerUsPrd !== false) {
    await writeFile(perUsPrdPath, '# us004 prd\n');
  }

  if (options.includePerUsTestSpec !== false) {
    await writeFile(perUsTestSpecPath, '# us004 test spec\n');
  }

  if (options.fixContractContent) {
    await writeFile(fixContractPath, options.fixContractContent);
  }

  return {
    promptBase,
    memoryFile,
    fullPrdPath,
    perUsPrdPath,
    testSpecPath,
    perUsTestSpecPath,
    conflictLogPath,
    fixContractPath,
    tempDir,
  };
}

async function buildVerifierFixtures(t, options = {}) {
  const tempDir = await createTempDir(t);
  const promptBase = path.join(tempDir, 'prompts', 'node-rewrite.verifier.prompt.md');
  const doneClaimFile = path.join(tempDir, 'memos', 'node-rewrite-done-claim.json');
  const conflictLogPath = path.join(tempDir, 'logs', 'conflict-log.jsonl');

  await writeFile(
    promptBase,
    options.promptBaseContent ?? 'Independent verifier for Ralph Desk: node-rewrite\n',
  );
  await writeFile(doneClaimFile, '{"us_id":"US-004"}\n');

  return {
    promptBase,
    doneClaimFile,
    conflictLogPath,
  };
}

test('US-004 AC4.1 happy: assembleWorkerPrompt appends iteration context, fix contract, and per-US scope lock', async (t) => {
  const fixtures = await buildWorkerFixtures(t, {
    fixContractContent: '- Fix the verifier issue\n',
  });
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004', 'US-005'],
    verifiedUs: ['US-001', 'US-002', 'US-003'],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    fixContractPath: fixtures.fixContractPath,
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, /^Execute the plan for node-rewrite\./);
  assert.match(prompt, /## Iteration Context/);
  assert.match(prompt, /- \*\*Iteration\*\*: 3/);
  assert.match(prompt, /- \*\*Memory Stop Status\*\*: verify/);
  assert.match(prompt, /## IMPORTANT: Fix Contract from Verifier \(iteration 2\)/);
  assert.match(prompt, /- Fix the verifier issue/);
  assert.match(prompt, /## PER-US SCOPE LOCK \(this iteration\) — OVERRIDES memory contract/);
  assert.match(prompt, /\*\*US-004\*\* is the next unverified story/);
  assert.match(prompt, /You MUST implement ONLY \*\*US-004\*\* in this iteration\./);
  assert.match(prompt, new RegExp(perUsTestSpecEscape(fixtures.perUsTestSpecPath)));
});

test('US-004 AC4.1 boundary: assembleWorkerPrompt keeps the base prompt verbatim when memory is empty and per-US PRD is missing', async (t) => {
  const fixtures = await buildWorkerFixtures(t, {
    memoryContent: '',
    includePerUsPrd: false,
    includePerUsTestSpec: false,
  });
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004'],
    verifiedUs: [],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, new RegExp(escapeForRegExp('PRD: ' + fixtures.fullPrdPath)));
  assert.doesNotMatch(prompt, new RegExp(escapeForRegExp(fixtures.perUsPrdPath)));
  assert.match(prompt, /- \*\*Memory Stop Status\*\*: unknown/);
  assert.match(prompt, /- \*\*Next Iteration Contract\*\*: Start from the beginning/);
  assert.doesNotMatch(prompt, /Fix Contract from Verifier/);
});

test('US-004 AC4.1 negative: assembleWorkerPrompt emits the final verification section when all user stories are already verified', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004'],
    verifiedUs: ['US-004'],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, /## FINAL VERIFICATION ITERATION/);
  assert.match(prompt, /All individual US have been verified: US-004/);
  assert.doesNotMatch(prompt, /## PER-US SCOPE LOCK/);
});

test('US-004 AC4.2 happy: assembleWorkerPrompt includes the autonomous mode section when enabled', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004'],
    verifiedUs: [],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    autonomousMode: true,
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, /## AUTONOMOUS MODE/);
  assert.match(prompt, /\*\*Resolution priority\*\*: PRD > test-spec > context > memory/);
  assert.match(prompt, new RegExp(escapeForRegExp(fixtures.conflictLogPath)));
  assert.match(
    prompt,
    /\{"iteration":N,"us_id":"US-NNN","source_a":"prd","source_b":"test-spec","conflict":"description","resolution":"followed PRD"\}/,
  );
});

test('US-004 AC4.2 boundary: assembleWorkerPrompt uses the provided conflict log path in autonomous mode', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const customConflictLogPath = path.join(fixtures.tempDir, 'custom', 'worker-conflicts.jsonl');
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004'],
    verifiedUs: [],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    autonomousMode: true,
    conflictLogPath: customConflictLogPath,
  });

  assert.match(prompt, new RegExp(escapeForRegExp(customConflictLogPath)));
});

test('US-004 AC4.2 negative: assembleWorkerPrompt omits the autonomous mode section when disabled', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleWorkerPrompt({
    promptBase: fixtures.promptBase,
    memoryFile: fixtures.memoryFile,
    iteration: 3,
    verifyMode: 'per-us',
    usList: ['US-004'],
    verifiedUs: [],
    fullPrdPath: fixtures.fullPrdPath,
    perUsPrdPath: fixtures.perUsPrdPath,
    fullTestSpecPath: fixtures.testSpecPath,
    perUsTestSpecPath: fixtures.perUsTestSpecPath,
    autonomousMode: false,
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.doesNotMatch(prompt, /## AUTONOMOUS MODE/);
});

test('US-004 AC4.3 happy: assembleVerifierPrompt scopes verification to a single user story and notes previously verified stories', async (t) => {
  const fixtures = await buildVerifierFixtures(t);
  const { assembleVerifierPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleVerifierPrompt({
    promptBase: fixtures.promptBase,
    iteration: 3,
    doneClaimFile: fixtures.doneClaimFile,
    verifyMode: 'per-us',
    usId: 'US-002',
    verifiedUs: ['US-001'],
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, /^Independent verifier for Ralph Desk: node-rewrite/);
  assert.match(prompt, /## Verification Context/);
  assert.match(prompt, /- \*\*Scope\*\*: Verify ONLY the acceptance criteria for \*\*US-002\*\*/);
  assert.match(prompt, /- \*\*Previously verified US\*\*: US-001/);
  assert.match(prompt, /Skip re-verifying the above US/);
});

test('US-004 AC4.3 boundary: assembleVerifierPrompt emits the full verify scope when usId is ALL', async (t) => {
  const fixtures = await buildVerifierFixtures(t);
  const { assembleVerifierPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleVerifierPrompt({
    promptBase: fixtures.promptBase,
    iteration: 3,
    doneClaimFile: fixtures.doneClaimFile,
    verifyMode: 'per-us',
    usId: 'ALL',
    verifiedUs: ['US-001', 'US-002'],
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.match(prompt, /- \*\*Scope\*\*: FULL VERIFY — check ALL acceptance criteria from the PRD/);
  assert.match(prompt, /- \*\*Previously verified US\*\*: US-001,US-002/);
});

test('US-004 AC4.3 negative: assembleVerifierPrompt omits previously verified guidance when none was provided', async (t) => {
  const fixtures = await buildVerifierFixtures(t);
  const { assembleVerifierPrompt } = await import('../../src/node/prompts/prompt-assembler.mjs');

  const prompt = await assembleVerifierPrompt({
    promptBase: fixtures.promptBase,
    iteration: 3,
    doneClaimFile: fixtures.doneClaimFile,
    verifyMode: 'per-us',
    usId: 'US-002',
    verifiedUs: [],
    conflictLogPath: fixtures.conflictLogPath,
  });

  assert.doesNotMatch(prompt, /Previously verified US/);
  assert.doesNotMatch(prompt, /Skip re-verifying/);
});

test('US-004 AC4.4 happy: assembleWorkerPrompt throws FileNotFoundError when the worker prompt base file does not exist', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt, FileNotFoundError } = await import(
    '../../src/node/prompts/prompt-assembler.mjs'
  );
  await fs.rm(fixtures.promptBase, { force: true });

  await assert.rejects(
    () =>
      assembleWorkerPrompt({
        promptBase: fixtures.promptBase,
        memoryFile: fixtures.memoryFile,
        iteration: 3,
        verifyMode: 'per-us',
        usList: ['US-004'],
        verifiedUs: [],
        fullPrdPath: fixtures.fullPrdPath,
        perUsPrdPath: fixtures.perUsPrdPath,
        fullTestSpecPath: fixtures.testSpecPath,
        perUsTestSpecPath: fixtures.perUsTestSpecPath,
        conflictLogPath: fixtures.conflictLogPath,
      }),
    (error) => error instanceof FileNotFoundError && error.path === fixtures.promptBase,
  );
});

test('US-004 AC4.4 boundary: FileNotFoundError includes the missing worker prompt base path in the message', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt, FileNotFoundError } = await import(
    '../../src/node/prompts/prompt-assembler.mjs'
  );
  await fs.rm(fixtures.promptBase, { force: true });

  await assert.rejects(
    () =>
      assembleWorkerPrompt({
        promptBase: fixtures.promptBase,
        memoryFile: fixtures.memoryFile,
        iteration: 3,
        verifyMode: 'per-us',
        usList: ['US-004'],
        verifiedUs: [],
        fullPrdPath: fixtures.fullPrdPath,
        perUsPrdPath: fixtures.perUsPrdPath,
        fullTestSpecPath: fixtures.testSpecPath,
        perUsTestSpecPath: fixtures.perUsTestSpecPath,
        conflictLogPath: fixtures.conflictLogPath,
      }),
    (error) =>
      error instanceof FileNotFoundError &&
      error.message.includes(fixtures.promptBase) &&
      error.message.includes('Worker prompt base file not found'),
  );
});

test('US-004 AC4.4 negative: assembleWorkerPrompt throws FileNotFoundError before reading other inputs when the worker prompt base file is missing', async (t) => {
  const fixtures = await buildWorkerFixtures(t);
  const { assembleWorkerPrompt, FileNotFoundError } = await import(
    '../../src/node/prompts/prompt-assembler.mjs'
  );
  await fs.rm(fixtures.promptBase, { force: true });
  await fs.rm(fixtures.memoryFile, { force: true });

  await assert.rejects(
    () =>
      assembleWorkerPrompt({
        promptBase: fixtures.promptBase,
        memoryFile: fixtures.memoryFile,
        iteration: 3,
        verifyMode: 'per-us',
        usList: ['US-004'],
        verifiedUs: [],
        fullPrdPath: fixtures.fullPrdPath,
        perUsPrdPath: fixtures.perUsPrdPath,
        fullTestSpecPath: fixtures.testSpecPath,
        perUsTestSpecPath: fixtures.perUsTestSpecPath,
        conflictLogPath: fixtures.conflictLogPath,
      }),
    (error) => error instanceof FileNotFoundError && !error.message.includes(fixtures.memoryFile),
  );
});

function escapeForRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

function perUsTestSpecEscape(value) {
  return escapeForRegExp('`' + value + '`');
}
