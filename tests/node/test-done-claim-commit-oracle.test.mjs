import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { evaluateCommitOracle, findCommitClaim } from '../../src/node/shared/commit-oracle.mjs';
import { isBuildClaim } from '../../src/node/shared/done-claim-kind.mjs';
import {
  _defaultCheckCommitIntegrity,
  _gitTrackedDirtyWorkerFiles,
  _gitClaimedCommitEmptyTree,
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

// claimKind → the non-commit step that decides isBuildClaim (G3): a build claim
// carries write_test, a confirmation/verification claim carries verify_existing.
function leadStep(sc) {
  return (sc.claimKind ?? 'build') === 'build'
    ? { step: 'write_test', exit_code: 0 }
    : { step: 'verify_existing', exit_code: 0 };
}

// commitTreeDelta → the tri-state claimedCommitEmptyTree fact (G3).
const TREE_DELTA_FACT = { empty: true, nonempty: false, root: 'unknown' };

// Translate an abstract matrix recipe into the pure predicate's injected facts.
function recipeToFacts(sc) {
  if (!sc.commitStep) {
    // A done-claim that asserts no successful commit → oracle no-op.
    return { doneClaim: { execution_steps: [leadStep(sc), { step: 'test', exit_code: 0 }] } };
  }
  const step = { step: 'commit', exit_code: 0 };
  if (sc.commitSha !== 'absent') {
    step.commit_sha = SHA[sc.commitSha];
  }
  const doneClaim = { execution_steps: [leadStep(sc), step] };
  const claimedCommitEmptyTree = TREE_DELTA_FACT[sc.commitTreeDelta ?? 'nonempty'];

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
  return {
    doneClaim, iterStartHead, currentHead, claimedShaResolves, claimedShaReachable,
    trackedDirtyWorkerFiles, claimedCommitEmptyTree,
  };
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
    if (sc.expectReason) {
      // Cross-leader reason-string parity: tests/test_commit_oracle.sh asserts
      // the SAME expectReason against the zsh predicate.
      assert.equal(result.reason, sc.expectReason, `${sc.name}: reason string`);
    }
  }
});

test('US-001 G3: isBuildClaim lives in shared/ and classifies on the write_test step', () => {
  assert.equal(isBuildClaim({ execution_steps: [{ step: 'write_test', exit_code: 0 }] }), true);
  assert.equal(isBuildClaim({ execution_steps: [{ step: 'verify_existing', exit_code: 0 }] }), false);
  // A refactor/doc claim is build WORK but carries no write_test step → classified
  // confirmation. Intended: the classifier bounds the blast radius, it does not
  // claim to identify verification work (matrix row
  // no-write-test-but-build-work-empty-commit-reject).
  assert.equal(isBuildClaim({ execution_steps: [{ step: 'implement', exit_code: 0 }] }), false);
  assert.equal(isBuildClaim(null), false);
  assert.equal(isBuildClaim({}), false);
  assert.equal(isBuildClaim({ execution_steps: 'nope' }), false);
});

test('US-001 G3: empty-tree predicate fires only on a non-build claim with an empty commit', () => {
  const base = {
    iterStartHead: 'a'.repeat(40),
    currentHead: 'b'.repeat(40),
    claimedShaResolves: true,
    claimedShaReachable: true,
    trackedDirtyWorkerFiles: [],
  };
  const confirmation = [{ step: 'verify_existing', exit_code: 0 }, { step: 'commit', exit_code: 0, commit_sha: SHA.head }];
  const build = [{ step: 'write_test', exit_code: 0 }, { step: 'commit', exit_code: 0, commit_sha: SHA.head }];

  const rejected = evaluateCommitOracle({ ...base, doneClaim: { execution_steps: confirmation }, claimedCommitEmptyTree: true });
  assert.equal(rejected.ok, false);
  assert.equal(rejected.reason, 'empty_commit_on_confirmation_claim');

  // unknown (root commit / shallow clone) → accept, never a reject.
  assert.equal(
    evaluateCommitOracle({ ...base, doneClaim: { execution_steps: confirmation }, claimedCommitEmptyTree: 'unknown' }).ok,
    true,
  );
  // false (real tree delta) → accept.
  assert.equal(
    evaluateCommitOracle({ ...base, doneClaim: { execution_steps: confirmation }, claimedCommitEmptyTree: false }).ok,
    true,
  );
  // A claim carrying write_test is untouched in this release (AC3).
  assert.equal(
    evaluateCommitOracle({ ...base, doneClaim: { execution_steps: build }, claimedCommitEmptyTree: true }).ok,
    true,
  );
  // Composes with the other independent checks rather than replacing them.
  const combined = evaluateCommitOracle({
    ...base,
    doneClaim: { execution_steps: confirmation },
    claimedCommitEmptyTree: true,
    trackedDirtyWorkerFiles: ['src/foo.js'],
  });
  assert.match(combined.reason, /empty_commit_on_confirmation_claim/);
  assert.match(combined.reason, /tracked_tree_dirty/);
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

// --- Part B2 (G3): empty-commit anti-fabrication against real git ------------

function emptyCommit(repo, message) {
  git(repo, ['commit', '-q', '--allow-empty', '-m', message]);
  return git(repo, ['rev-parse', 'HEAD']);
}

function confirmationClaim(sha) {
  // No write_test step → isBuildClaim false (confirmation/verification shape).
  return {
    execution_steps: [
      { step: 'verify_existing', exit_code: 0 },
      { step: 'commit', exit_code: 0, commit_sha: sha },
    ],
  };
}

// G3.d FACT-GATHERING PIN: the wrapper must actually compute
// claimedCommitEmptyTree. The pure predicate is I/O-free, so if the wrapper
// stops gathering the fact this rejection silently disappears in production
// while the pure-predicate tests stay green — which is exactly the dead-code
// failure mode this test exists to catch.
test('US-001 G3 Part B: confirmation claim + EMPTY commit → reject (wrapper gathers the fact)', async () => {
  const repo = await makeRepo('g3-empty');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const emptySha = emptyCommit(repo, 'iter 4 verification pass');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: confirmationClaim(emptySha),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.asserted, true);
  assert.equal(result.ok, false, 'an empty commit records no work — it must not corroborate the claim');
  assert.equal(result.reason, 'empty_commit_on_confirmation_claim');
  assert.notEqual(result.infra, true, 'a fabricated empty commit is a worker lie, not infra');
});

test('US-001 G3 Part B: confirmation claim + REAL commit → accept', async () => {
  const repo = await makeRepo('g3-real');
  const base = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const realSha = commitFile(repo, 'b.txt', 'v1', 'real work');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: confirmationClaim(realSha),
    iterStartHead: base,
    preexistingDirty: [],
  });
  assert.equal(result.ok, true, result.reason ?? '');
});

test('US-001 G3 Part B: empty ROOT commit → unknown → accept (never infra)', async () => {
  const repo = await makeRepo('g3-root');
  const rootSha = emptyCommit(repo, 'root');
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: confirmationClaim(rootSha),
    iterStartHead: '', // repo had no commits at iteration start
    preexistingDirty: [],
  });
  assert.equal(result.ok, true, result.reason ?? '');
  assert.notEqual(result.infra, true, 'a parentless commit is an expected boundary, not a git failure');
});

// --- Part B3 (G3 / codex C3): parent-unavailable vs genuine git failure ------
// The split matters: swallowing EVERY git error into `unknown` would erase the
// GIT-FC rc-2 path the oracle depends on to never corroborate a claim from a
// broken repo. Expected parent-unavailable (root / shallow) → unknown → accept;
// anything else → throw → the existing infra result.

test('US-001 G3 C3: probe returns true/false against a healthy repo', async () => {
  const repo = await makeRepo('g3-probe');
  commitFile(repo, 'a.txt', 'v1', 'baseline');
  const emptySha = emptyCommit(repo, 'empty');
  assert.equal(await _gitClaimedCommitEmptyTree(repo, emptySha), true);
  const realSha = commitFile(repo, 'b.txt', 'v1', 'real');
  assert.equal(await _gitClaimedCommitEmptyTree(repo, realSha), false);
});

test('US-001 G3 C3 (expected class): root commit → unknown', async () => {
  const repo = await makeRepo('g3-probe-root');
  const rootSha = commitFile(repo, 'a.txt', 'v1', 'root');
  assert.equal(await _gitClaimedCommitEmptyTree(repo, rootSha), 'unknown');
});

test('US-001 G3 C3 (expected class): shallow clone tip → unknown, and the oracle accepts', async () => {
  const origin = await makeRepo('g3-origin');
  commitFile(origin, 'a.txt', 'v1', 'baseline');
  commitFile(origin, 'b.txt', 'v1', 'second');
  const shallowParent = await fs.mkdtemp(path.join(os.tmpdir(), 'commit-oracle-g3-shallow-'));
  const shallow = path.join(shallowParent, 'clone');
  execFileSync('git', ['clone', '-q', '--depth', '1', `file://${origin}`, shallow], { encoding: 'utf8' });
  git(shallow, ['config', 'user.email', 'test@example.com']);
  git(shallow, ['config', 'user.name', 'test']);
  const tip = git(shallow, ['rev-parse', 'HEAD']);
  // Sanity: this really is a shallow tip (its parent is grafted away).
  assert.throws(() => git(shallow, ['rev-parse', '--verify', `${tip}^`]));

  assert.equal(await _gitClaimedCommitEmptyTree(shallow, tip), 'unknown');
  const result = await _defaultCheckCommitIntegrity(shallow, {
    doneClaim: confirmationClaim(tip),
    iterStartHead: '',
    preexistingDirty: [],
  });
  assert.equal(result.ok, true, result.reason ?? '');
  assert.notEqual(result.infra, true);
});

test('US-001 G3 C3 (genuine-failure class): unresolvable sha / non-repo → throw, not unknown', async () => {
  const repo = await makeRepo('g3-probe-bad');
  commitFile(repo, 'a.txt', 'v1', 'baseline');
  commitFile(repo, 'b.txt', 'v1', 'second');
  await assert.rejects(
    () => _gitClaimedCommitEmptyTree(repo, 'd'.repeat(40)),
    'an unresolvable sha is a git failure, not an expected parent-unavailable case',
  );
  const nonRepo = await makeNonRepoDir('g3-probe');
  await assert.rejects(() => _gitClaimedCommitEmptyTree(nonRepo, 'd'.repeat(40)));
});

test('US-001 G3 C3 (genuine-failure class): corrupt parent → probe throws → GIT-FC infra result', async () => {
  const repo = await makeRepo('g3-corrupt');
  const parentSha = commitFile(repo, 'a.txt', 'v1', 'baseline');
  const headSha = commitFile(repo, 'b.txt', 'v1', 'second');
  // Corrupt the PARENT's tree object: the parent commit still resolves (so this
  // is not the root/shallow shape) but diffing against it errors.
  const parentTree = git(repo, ['rev-parse', `${parentSha}^{tree}`]);
  const loose = path.join(repo, '.git', 'objects', parentTree.slice(0, 2), parentTree.slice(2));
  assert.ok(fsSync.existsSync(loose), 'fixture precondition: parent tree is a loose object');
  fsSync.unlinkSync(loose);

  await assert.rejects(() => _gitClaimedCommitEmptyTree(repo, headSha));
  const result = await _defaultCheckCommitIntegrity(repo, {
    doneClaim: confirmationClaim(headSha),
    iterStartHead: parentSha,
    preexistingDirty: [],
  });
  assert.equal(result.infra, true, 'a genuine git failure must keep the GIT-FC infra path');
  assert.equal(result.reason, 'git_facts_unavailable');
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
