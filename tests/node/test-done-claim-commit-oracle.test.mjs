import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { evaluateCommitOracle, findCommitClaim } from '../../src/node/shared/commit-oracle.mjs';
import {
  _defaultCheckCommitIntegrity,
  _gitTrackedDirtyWorkerFiles,
} from '../../src/node/runner/campaign-main-loop.mjs';

// US-001 — leader-side done-claim commit-integrity oracle.
// Part A: the PURE predicate (evaluateCommitOracle) against the shared
//         parity matrix (tests/fixtures/commit-oracle/matrix.json) — the SAME
//         matrix tests/test_commit_oracle.sh drives through the zsh helper (AC1.6).
// Part B: the git-gathering wrapper (_defaultCheckCommitIntegrity) against REAL
//         temp git repos — proves the untracked/preexisting exclusion and the
//         per-iteration-snapshot behavior end-to-end.

const __filename = fileURLToPath(import.meta.url);
const projectRoot = path.resolve(path.dirname(__filename), '..', '..');
const matrix = JSON.parse(
  fsSync.readFileSync(path.join(projectRoot, 'tests/fixtures/commit-oracle/matrix.json'), 'utf8'),
);

const SHA = { head: 'b'.repeat(40), unreachable: 'c'.repeat(40), bogus: 'd'.repeat(40) };

// Translate an abstract matrix recipe into the pure predicate's injected facts.
function recipeToFacts(sc) {
  if (!sc.commitStep) {
    // A done-claim that asserts no successful commit → oracle no-op.
    return { doneClaim: { execution_steps: [{ step: 'test', exit_code: 0 }] } };
  }
  const step = { step: 'commit', exit_code: 0 };
  if (sc.commitSha !== 'absent') {
    step.commit_sha = SHA[sc.commitSha];
  }
  const doneClaim = { execution_steps: [step] };

  let iterStartHead = 'a'.repeat(40);
  let currentHead = 'b'.repeat(40);
  if (sc.advance === 'first-commit') {
    iterStartHead = '';
    currentHead = 'b'.repeat(40);
  } else if (sc.advance === 'prior-only-lie' || sc.advance === 'none') {
    // HEAD did NOT advance THIS iteration (snapshot == current).
    iterStartHead = 'b'.repeat(40);
    currentHead = 'b'.repeat(40);
  }

  const claimedShaResolves = sc.commitSha === 'head' || sc.commitSha === 'unreachable';
  const claimedShaReachable = sc.commitSha === 'head';
  const trackedDirtyWorkerFiles = sc.dirty === 'tracked' ? ['src/foo.js'] : [];
  return { doneClaim, iterStartHead, currentHead, claimedShaResolves, claimedShaReachable, trackedDirtyWorkerFiles };
}

test('US-001 Part A: pure predicate matches the shared parity matrix', () => {
  for (const sc of matrix.scenarios) {
    // GIT-FC (IMP-09): gitError rows exercise the I/O wrapper's infra path (rc 2
    // / infra:true), not the pure predicate — asserted in the GIT-FC block below.
    if (sc.gitError) continue;
    const facts = recipeToFacts(sc);
    const result = evaluateCommitOracle(facts);
    assert.equal(result.asserted, sc.expectAsserted, `${sc.name}: asserted`);
    assert.equal(result.ok, sc.expectOk, `${sc.name}: ok (reason=${result.reason})`);
    if (!sc.expectOk) {
      assert.ok(result.reason, `${sc.name}: a rejecting verdict must name a reason`);
      assert.ok(result.detail, `${sc.name}: a rejecting verdict must carry detail`);
    }
  }
});

test('US-001 Part A: findCommitClaim ignores non-commit and non-zero-exit steps', () => {
  assert.equal(findCommitClaim(null), null);
  assert.equal(findCommitClaim({ execution_steps: [{ step: 'test', exit_code: 0 }] }), null);
  assert.equal(findCommitClaim({ execution_steps: [{ step: 'commit', exit_code: 1 }] }), null);
  const ok = findCommitClaim({ execution_steps: [{ step: 'commit', exit_code: 0, commit_sha: 'abc' }] });
  assert.equal(ok.commit_sha, 'abc');
  // string "0" tolerated (workers may serialize exit_code either way).
  assert.ok(findCommitClaim({ execution_steps: [{ step: 'commit', exit_code: '0' }] }));
});

// --- Part B: real git repo integration -------------------------------------

function git(repo, args) {
  return execFileSync('git', ['-C', repo, ...args], { encoding: 'utf8' }).trim();
}

async function makeRepo(name) {
  const base = await fs.mkdtemp(path.join(os.tmpdir(), `commit-oracle-${name}-`));
  git(base, ['init', '-q']);
  git(base, ['config', 'user.email', 'test@example.com']);
  git(base, ['config', 'user.name', 'test']);
  git(base, ['config', 'commit.gpgsign', 'false']);
  return base;
}

function commitFile(repo, file, content, message) {
  fsSync.writeFileSync(path.join(repo, file), content);
  git(repo, ['add', file]);
  git(repo, ['commit', '-q', '-m', message]);
  return git(repo, ['rev-parse', 'HEAD']);
}

function doneClaimWithCommit(sha) {
  const step = { step: 'commit', exit_code: 0 };
  if (sha !== undefined) step.commit_sha = sha;
  return { execution_steps: [step] };
}

test('US-001 Part B: real commit reachable from advanced HEAD → accept', async () => {
  const repo = await makeRepo('accept');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const workerSha = commitFile(repo, 'b.txt', 'v1', 'worker commit');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(workerSha),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.asserted, true);
  assert.equal(result.ok, true, result.reason ?? '');
});

test('US-001 Part B: bogus claimed SHA on advanced HEAD → reject (claimed_sha_absent)', async () => {
  const repo = await makeRepo('bogus');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  commitFile(repo, 'b.txt', 'v1', 'worker commit');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit('d'.repeat(40)),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.asserted, true);
  assert.equal(result.ok, false);
  assert.match(result.reason, /claimed_sha_absent/);
});

test('US-001 Part B: HEAD advanced but a tracked file left dirty → reject (tracked_tree_dirty)', async () => {
  const repo = await makeRepo('dirty');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const workerSha = commitFile(repo, 'b.txt', 'v1', 'worker commit');
  // Worker committed b.txt but left a tracked file a.txt modified.
  fsSync.writeFileSync(path.join(repo, 'a.txt'), 'v2-uncommitted');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(workerSha),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.ok, false);
  assert.match(result.reason, /tracked_tree_dirty/);
});

test('US-001 Part B: untracked-only cruft after a real commit → accept', async () => {
  const repo = await makeRepo('untracked');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const workerSha = commitFile(repo, 'b.txt', 'v1', 'worker commit');
  fsSync.writeFileSync(path.join(repo, 'scratch.log'), 'noise'); // untracked
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(workerSha),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.ok, true, result.reason ?? '');
});

test('US-001 Part B: preexisting-dirty tracked file excluded → accept', async () => {
  const repo = await makeRepo('preexisting');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  // Operator's pre-existing uncommitted edit to a tracked file, captured before
  // the worker runs (mirrors the campaign-preexisting-dirty snapshot).
  fsSync.writeFileSync(path.join(repo, 'a.txt'), 'operator-wip');
  const preexisting = await _gitTrackedDirtyWorkerFiles(repo, []);
  assert.deepEqual(preexisting, ['a.txt']);
  const workerSha = commitFile(repo, 'b.txt', 'v1', 'worker commit');
  // a.txt is STILL dirty, but it predates the campaign → must be excluded.
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(workerSha),
    iterStartHead: base,
    preexistingDirty: preexisting,
  });
  assert.equal(result.ok, true, result.reason ?? '');
});

test('US-001 Part B: prior-iter advance + lie this iter → reject (per-iteration snapshot)', async () => {
  const repo = await makeRepo('prior-lie');
  commitFile(repo, 'a.txt', 'v1', 'baseline');
  const priorSha = commitFile(repo, 'b.txt', 'v1', 'prior-iter commit');
  // THIS iteration starts at priorSha and makes NO new commit, yet the done-claim
  // asserts a commit pointing at the (real, reachable) prior commit. The campaign
  // baseline would show HEAD advanced and false-accept; the per-iteration snapshot
  // (iterStartHead == current HEAD) correctly rejects.
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(priorSha),
    iterStartHead: priorSha,
    preexistingDirty: [],
  });
  assert.equal(result.ok, false);
  assert.match(result.reason, /head_not_advanced/);
});

test('US-001 Part B: no commit step in done-claim → no-op (asserted=false)', async () => {
  const repo = await makeRepo('noop');
  commitFile(repo, 'a.txt', 'v1', 'baseline');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: { execution_steps: [{ step: 'test', exit_code: 0 }] },
    iterStartHead: 'anything',
    preexistingDirty: [],
  });
  assert.equal(result.asserted, false);
  assert.equal(result.ok, true);
});

test('US-001 Part B: commit-claim without commit_sha, HEAD advanced → accept (transition rule)', async () => {
  const repo = await makeRepo('nosha-advance');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  commitFile(repo, 'b.txt', 'v1', 'worker commit');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(undefined), // no commit_sha
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.asserted, true);
  assert.equal(result.ok, true, result.reason ?? '');
});

test('US-001 Part B: commit-claim without commit_sha, HEAD did NOT advance → reject', async () => {
  const repo = await makeRepo('nosha-noadvance');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: doneClaimWithCommit(undefined),
    iterStartHead: base, // HEAD == snapshot, no new commit
    preexistingDirty: [],
  });
  assert.equal(result.ok, false);
  assert.match(result.reason, /no_sha_no_advance/);
});

// --- Part C: GIT-FC (IMP-09) fail-closed git-snapshot errors ----------------

async function makeNonRepoDir(name) {
  // A real dir that is NOT a git repo → every git command here errors.
  return fs.mkdtemp(path.join(os.tmpdir(), `commit-oracle-nonrepo-${name}-`));
}

// Case 7: the swallow is deleted — a git error now REJECTS (throws) instead of
// silently returning an empty (clean) list.
test('US-001 GIT-FC: _gitTrackedDirtyWorkerFiles rejects on a git error (no silent empty)', async () => {
  const nonRepo = await makeNonRepoDir('dirty');
  await assert.rejects(() => _gitTrackedDirtyWorkerFiles(nonRepo, []));
});

// Case 8: _defaultCheckCommitIntegrity surfaces the git error as an infra result
// (asserted, not-ok, infra:true, git_facts_unavailable) — only when a commit IS
// asserted (the pure predicate never sees garbage facts).
test('US-001 GIT-FC: _defaultCheckCommitIntegrity → infra result on a git error when a commit is asserted', async () => {
  const nonRepo = await makeNonRepoDir('check');
  const result = await _defaultCheckCommitIntegrity(nonRepo, {
    doneClaim: doneClaimWithCommit('deadbeefdeadbeefdeadbeefdeadbeefdeadbeef'),
    iterStartHead: 'a'.repeat(40),
    preexistingDirty: [],
  });
  assert.equal(result.asserted, true);
  assert.equal(result.ok, false);
  assert.equal(result.infra, true, 'a git error must be flagged infra, not a worker lie');
  assert.equal(result.reason, 'git_facts_unavailable');
});

// Case 9: no commit asserted + broken git → still the no-op result (infra only
// matters when a commit is asserted; the no-claim early return needs no git).
test('US-001 GIT-FC: no commit claim + broken git → no-op (asserted=false), never infra', async () => {
  const nonRepo = await makeNonRepoDir('noclaim');
  const result = await _defaultCheckCommitIntegrity(nonRepo, {
    doneClaim: { execution_steps: [{ step: 'test', exit_code: 0 }] },
    preexistingDirty: [],
  });
  assert.equal(result.asserted, false);
  assert.equal(result.ok, true);
  assert.notEqual(result.infra, true);
});

// Case 10: shared-fixture PARITY row — the git-error scenario in matrix.json
// pins that Node reason === zsh ORACLE_REASON === expectReason, and Node
// infra:true ↔ zsh rc 2 (asserted in tests/test_commit_oracle.sh).
test('US-001 GIT-FC: matrix git-error row parity (Node reason === zsh reason)', async () => {
  const scenario = matrix.scenarios.find((sc) => sc.gitError === true);
  assert.ok(scenario, 'matrix must carry a gitError parity row');
  assert.equal(scenario.expectReason, 'git_facts_unavailable');

  const nonRepo = await makeNonRepoDir('parity');
  const result = await _defaultCheckCommitIntegrity(nonRepo, {
    doneClaim: doneClaimWithCommit(SHA.head),
    iterStartHead: 'a'.repeat(40),
    preexistingDirty: [],
  });
  assert.equal(result.asserted, scenario.expectAsserted);
  assert.equal(result.ok, scenario.expectOk);
  assert.equal(result.infra, true);
  assert.equal(result.reason, scenario.expectReason);
});
