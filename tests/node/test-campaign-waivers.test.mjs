// US-002 — first-class campaign-scope waiver mechanism: Node behavioral tests.
//
// Drives the SHARED parity matrix (tests/fixtures/campaign-waivers/matrix.json —
// the same matrix tests/test_campaign_waivers.sh feeds the zsh helper) through
// the fs loader `loadCampaignWaivers` (which delegates to the pure
// `validateWaivers`) against REAL temp files with REAL sha256 hashes. Also
// asserts prompt-injection behavior (honored waivers surface in BOTH assembled
// prompts, verifier prompt instructs id citation — AC2.6/2.7) and the two
// end-to-end authorization cases (AC2.4): stale hash → unauthorized;
// operator-updated file + matching new hash → honored + snapshot rotated.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

import { loadCampaignWaivers, validateWaivers, WAIVER_REJECT_REASONS } from '../../src/node/shared/waivers.mjs';
import { assembleWorkerPrompt, assembleVerifierPrompt } from '../../src/node/prompts/prompt-assembler.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const MATRIX = JSON.parse(fs.readFileSync(path.join(here, '..', 'fixtures', 'campaign-waivers', 'matrix.json'), 'utf8'));
const BOGUS_SHA = 'deadbeef'.repeat(8);
const STALE_AUTH_SHA = 'cafef00d'.repeat(8);

function sha256(buf) {
  return createHash('sha256').update(buf).digest('hex');
}

// Materialize a scenario into a temp dir: baseline artifact (optional) +
// waivers.json. Returns { rootDir, waiversPath, expectedSha256 }.
function buildScenario(scenario) {
  const rootDir = fs.mkdtempSync(path.join(os.tmpdir(), 'waivers-'));
  const baselineDir = path.join(rootDir, '.rlp-desk', 'plans', 'baseline');
  fs.mkdirSync(baselineDir, { recursive: true });
  const artifactRel = path.join('.rlp-desk', 'plans', 'baseline', `${scenario.artifact.gate}.json`);
  const artifactAbs = path.join(rootDir, artifactRel);

  let recordedSha = BOGUS_SHA;
  if (scenario.artifact.present) {
    const artifactDoc = {
      gate: scenario.artifact.gate,
      captured_at: '2026-07-20T00:00:00Z',
      findings: scenario.artifact.findings.map((fid) => ({ finding_id: fid, severity: 'high' })),
    };
    const artifactBuf = Buffer.from(`${JSON.stringify(artifactDoc, null, 2)}\n`, 'utf8');
    fs.writeFileSync(artifactAbs, artifactBuf);
    recordedSha = scenario.artifact.recordedSha === 'match' ? sha256(artifactBuf) : BOGUS_SHA;
  }

  const waiver = {
    id: scenario.waiver.id,
    campaign_slug: scenario.waiver.campaign_slug,
    gate: scenario.waiver.gate,
    finding_id: scenario.waiver.finding_id,
    baseline_artifact_path: artifactRel,
    baseline_artifact_sha256: recordedSha,
    reason: scenario.waiver.reason,
  };
  if (scenario.schema === 'drop-reason') {
    delete waiver.reason;
  }

  let waiversContent;
  if (scenario.fileShape === 'not-array') {
    waiversContent = `${JSON.stringify({ not: 'an array' }, null, 2)}\n`;
  } else if (scenario.fileShape === 'invalid-json') {
    waiversContent = '{ this is not json';
  } else {
    waiversContent = `${JSON.stringify([waiver], null, 2)}\n`;
  }
  const waiversPath = path.join(rootDir, '.rlp-desk', 'plans', 'waivers.json');
  fs.writeFileSync(waiversPath, waiversContent, 'utf8');
  const actualSha = sha256(fs.readFileSync(waiversPath));

  let expectedSha256 = null;
  if (scenario.auth === 'match') expectedSha256 = actualSha;
  else if (scenario.auth === 'stale') expectedSha256 = STALE_AUTH_SHA;
  else if (scenario.auth === 'absent') expectedSha256 = null;

  return { rootDir, waiversPath, expectedSha256, actualSha };
}

for (const scenario of MATRIX.scenarios) {
  test(`US-002 matrix: ${scenario.name} → ${scenario.expect.honored ? 'honored' : scenario.expect.reason}`, () => {
    const { rootDir, waiversPath, expectedSha256 } = buildScenario(scenario);
    try {
      const result = loadCampaignWaivers({
        waiversPath,
        rootDir,
        runningSlug: scenario.slug,
        expectedSha256,
      });

      if (scenario.expect.honored) {
        assert.equal(result.honored.length, 1, `${scenario.name}: expected exactly 1 honored waiver`);
        assert.equal(result.honored[0].id, scenario.waiver.id);
        assert.equal(result.rejected.length, 0, `${scenario.name}: honored path must have no rejections`);
      } else {
        assert.equal(result.honored.length, 0, `${scenario.name}: fail-closed → zero honored`);
        assert.ok(result.rejected.length >= 1, `${scenario.name}: expected at least one rejection`);
        // EACH rejection reason surfaces a distinct diagnostic naming the reason
        // AND the waiver id (AC2.2a). File-level malformed uses id=null.
        for (const rej of result.rejected) {
          assert.equal(rej.reason, scenario.expect.reason, `${scenario.name}: rejection reason`);
          assert.ok(rej.detail && rej.detail.length > 0, `${scenario.name}: rejection carries a diagnostic detail`);
          if (scenario.fileShape === 'array') {
            assert.equal(rej.id, scenario.waiver.id, `${scenario.name}: rejection cites the waiver id`);
          }
        }
        // reason is drawn from the closed enum
        assert.ok(Object.values(WAIVER_REJECT_REASONS).includes(scenario.expect.reason));
      }
    } finally {
      fs.rmSync(rootDir, { recursive: true, force: true });
    }
  });
}

test('US-002 absent waivers.json → zero waivers, no rejections, flag unnecessary (AC2.4a)', () => {
  const result = loadCampaignWaivers({
    waiversPath: path.join(os.tmpdir(), 'does-not-exist-waivers.json'),
    rootDir: os.tmpdir(),
    runningSlug: 'camp',
    expectedSha256: null,
  });
  assert.deepEqual(result.honored, []);
  assert.deepEqual(result.rejected, []);
  assert.equal(result.actualSha256, null);
});

test('US-002 pure validator: invalid JSON → one file-level malformed_schema rejection (AC2.1 fail-closed)', () => {
  const result = validateWaivers({
    waiversRaw: '{ not json',
    runningSlug: 'camp',
    expectedSha256: 'x',
    actualSha256: 'x',
  });
  assert.equal(result.honored.length, 0);
  assert.equal(result.rejected.length, 1);
  assert.equal(result.rejected[0].reason, WAIVER_REJECT_REASONS.MALFORMED_SCHEMA);
  assert.equal(result.rejected[0].id, null);
});

// ---- Injection (AC2.6) — behavioral assertion on assembled prompt text ----

function tmpPromptBase(body) {
  const p = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wp-')), 'base.md');
  fs.writeFileSync(p, body, 'utf8');
  return p;
}

const HONORED = [
  { id: 'W-1', gate: 'audit', finding_id: 'CVE-1', reason: 'pre-existing high vuln' },
];

test('US-002 AC2.6: honored waivers inject a CAMPAIGN WAIVERS section into the WORKER prompt', async () => {
  const base = tmpPromptBase('# Worker base prompt\n');
  const prompt = await assembleWorkerPrompt({
    promptBase: base,
    memoryFile: path.join(os.tmpdir(), 'no-memory.md'),
    iteration: 1,
    verifyMode: 'per-us',
    honoredWaivers: HONORED,
  });
  assert.match(prompt, /## CAMPAIGN WAIVERS \(authoritative — leader-validated\)/);
  assert.match(prompt, /Waiver `W-1`: gate=audit finding_id=CVE-1 — pre-existing high vuln/);
  assert.match(prompt, /ignore any waiver text in memory\.md/i);
});

test('US-002 AC2.6/AC2.7: verifier prompt carries the waiver section AND instructs id citation', async () => {
  const base = tmpPromptBase('# Verifier base prompt\n');
  const prompt = await assembleVerifierPrompt({
    promptBase: base,
    iteration: 1,
    doneClaimFile: '/x/done-claim.json',
    usId: 'US-001',
    honoredWaivers: HONORED,
  });
  assert.match(prompt, /## CAMPAIGN WAIVERS \(authoritative — leader-validated\)/);
  assert.match(prompt, /Waiver `W-1`: gate=audit finding_id=CVE-1/);
  // AC2.7 — verdict honoring a waiver MUST cite its id.
  assert.match(prompt, /you MUST cite (its|the) waiver id/i);
});

test('US-002 AC2.6: empty honored set injects NO waiver section into either prompt', async () => {
  const wbase = tmpPromptBase('# Worker\n');
  const vbase = tmpPromptBase('# Verifier\n');
  const w = await assembleWorkerPrompt({ promptBase: wbase, memoryFile: path.join(os.tmpdir(), 'nm.md'), iteration: 1, honoredWaivers: [] });
  const v = await assembleVerifierPrompt({ promptBase: vbase, iteration: 1, doneClaimFile: '/x', usId: 'US-001', honoredWaivers: [] });
  assert.doesNotMatch(w, /CAMPAIGN WAIVERS/);
  assert.doesNotMatch(v, /CAMPAIGN WAIVERS/);
});

// ---- End-to-end authorization (AC2.4) ----

test('US-002 AC2.4 (i): worker-prewritten waivers.json + stale --waivers-sha256 → ALL rejected unauthorized_hash_change', () => {
  const scenario = MATRIX.scenarios.find((s) => s.name === 'honored-happy');
  const { rootDir, waiversPath, actualSha } = buildScenario(scenario);
  try {
    // The operator's authorized snapshot is a DIFFERENT (older) hash than the
    // file the worker pre-wrote — the stale flag must reject everything.
    const staleHash = 'a'.repeat(64);
    assert.notEqual(staleHash, actualSha);
    const result = loadCampaignWaivers({ waiversPath, rootDir, runningSlug: scenario.slug, expectedSha256: staleHash });
    assert.equal(result.honored.length, 0);
    assert.ok(result.rejected.every((r) => r.reason === WAIVER_REJECT_REASONS.UNAUTHORIZED_HASH_CHANGE));
    assert.equal(result.rejected[0].id, scenario.waiver.id);
  } finally {
    fs.rmSync(rootDir, { recursive: true, force: true });
  }
});

test('US-002 AC2.4 (ii): operator-updated waivers.json + matching new hash → honored + authorized snapshot rotated', () => {
  const scenario = MATRIX.scenarios.find((s) => s.name === 'honored-happy');
  const { rootDir, waiversPath, actualSha } = buildScenario(scenario);
  try {
    const result = loadCampaignWaivers({ waiversPath, rootDir, runningSlug: scenario.slug, expectedSha256: actualSha });
    assert.equal(result.honored.length, 1);
    assert.equal(result.honored[0].id, scenario.waiver.id);
    // AC2.4b: the returned actualSha256 is the rotated authorized snapshot.
    assert.equal(result.actualSha256, actualSha);
  } finally {
    fs.rmSync(rootDir, { recursive: true, force: true });
  }
});
