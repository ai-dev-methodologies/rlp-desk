import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { buildClaudeCmd, buildCodexCmd, parseModelFlag } from '../cli/command-builder.mjs';
import { shellQuote } from '../util/shell-quote.mjs';
import { ONE_MILLION_BETA, wantsOneMillionContext } from '../constants.mjs';
import { initCampaign } from '../init/campaign-initializer.mjs';
import { LEGACY_DESK_REL, resolveDeskRoot } from '../util/desk-root.mjs';
import { loadModelLadder } from '../model-ladder.mjs';
import {
  lockSentinelFile as defaultLockSentinelFile,
  stampAckField as defaultStampAckField,
  unlockSentinelFile,
  writeSentinelExclusive,
} from '../shared/fs.mjs';
import { normalizeVerdict } from '../shared/verdict-schema.mjs';
import { evaluateCommitOracle, findCommitClaim } from '../shared/commit-oracle.mjs';
import { lintDoneClaimTddSequence } from './done-claim-lint.mjs';
import { loadCampaignWaivers } from '../shared/waivers.mjs';
import {
  TimeoutError,
  WorkerExitedError,
  PromptBlockedError,
  pollForSignal as defaultPollForSignal,
} from '../polling/signal-poller.mjs';
import {
  assembleVerifierPrompt,
  assembleWorkerPrompt,
} from '../prompts/prompt-assembler.mjs';
import {
  appendCampaignAnalytics,
  generateCampaignReport,
  generateSVReport,
  prepareCampaignAnalytics,
} from '../reporting/campaign-reporting.mjs';
import { LifecycleMetricsCollector } from '../util/lifecycle-metrics.mjs';
import { makeDebugLogger } from '../util/debug-log.mjs';
import {
  createPane as defaultCreatePane,
  killPaneProcess as defaultKillPaneProcess,
  sendKeys as defaultSendKeys,
  sendRawKey as defaultSendRawKey,
  waitForProcessExit as defaultWaitForProcessExit,
} from '../tmux/pane-manager.mjs';

const execFileAsync = promisify(execFile);
const REQUIRED_SCAFFOLD_NAMES = ['workerPrompt', 'verifierPrompt', 'memoryFile', 'prdFile', 'testSpecFile'];
// US-001: single-sourced from src/node/models.json (see src/node/model-ladder.mjs).
// Loaded once at module import — mirrors the previous module-level constant.
const MODEL_UPGRADES = loadModelLadder();

// v0.14.2 Bug Report #4 Fix-D: codex occasionally lands the verdict at the
// pre-v0.13.0 `.claude/ralph-desk/memos/` path despite prompt instructions.
// signal-poller's `legacySignalFile` last-chance branch returns the parsed
// verdict in memory; these two helpers move the file into the canonical
// .rlp-desk/memos/ location AFTER the polling loop succeeds, so analytics
// archival + sentinel hygiene remain consistent.
export async function _verdictMigrationNeeded(paths) {
  if (!paths?.legacyVerdictFile || !paths?.verdictFile) return false;
  // Migration is only meaningful when the legacy file exists AND the
  // canonical file does not. If both exist, canonical wins (already
  // observed) and we leave legacy alone.
  let legacyExists = false;
  let canonicalExists = false;
  try { legacyExists = await exists(paths.legacyVerdictFile); } catch {}
  try { canonicalExists = await exists(paths.verdictFile); } catch {}
  return legacyExists && !canonicalExists;
}

export async function _migrateLegacyVerdict(paths) {
  if (!paths?.legacyVerdictFile || !paths?.verdictFile) return false;
  await fs.mkdir(path.dirname(paths.verdictFile), { recursive: true });
  await fs.rename(paths.legacyVerdictFile, paths.verdictFile);
  return true;
}

// v0.13.0: legacy .claude/ralph-desk/ guidance for run mode (no auto-mv).
export function detectLegacyDeskInRunMode(rootDir, env = process.env) {
  const legacyPath = path.join(rootDir, LEGACY_DESK_REL);
  if (!fsSync.existsSync(legacyPath)) {
    return null;
  }

  const newPath = resolveDeskRoot(rootDir, env);
  const newRel = path.relative(rootDir, newPath) || path.basename(newPath);
  const message =
    `Legacy ${LEGACY_DESK_REL}/ detected. Run mode does not auto-migrate to protect in-flight campaigns. ` +
    `Run: mv ${LEGACY_DESK_REL} ${newRel} then re-run.`;
  return { legacyPath, newPath, message };
}

export function buildPaths(rootDir, slug, env = process.env) {
  const deskRoot = resolveDeskRoot(rootDir, env);
  const campaignLogDir = path.join(deskRoot, 'logs', slug);

  return {
    deskRoot,
    promptsDir: path.join(deskRoot, 'prompts'),
    plansDir: path.join(deskRoot, 'plans'),
    memosDir: path.join(deskRoot, 'memos'),
    contextDir: path.join(deskRoot, 'context'),
    campaignLogDir,
    runtimeDir: path.join(campaignLogDir, 'runtime'),
    // fix/omx-state-isolation: campaign-scoped OMX_STATE_ROOT for every codex
    // launch this leader spawns. oh-my-codex hooks read project-local
    // .omx/state/ by default; without isolation, stale interactive-session
    // state (e.g. an unreleased input_lock) can block/wedge campaign codex
    // workers. --disable plugins does NOT cover hooks.json native hooks, so
    // env isolation is required. mkdir happens in ensureDirs alongside runtimeDir.
    omxStateDir: path.join(campaignLogDir, 'runtime', 'omx-state'),
    workerPrompt: path.join(deskRoot, 'prompts', `${slug}.worker.prompt.md`),
    verifierPrompt: path.join(deskRoot, 'prompts', `${slug}.verifier.prompt.md`),
    memoryFile: path.join(deskRoot, 'memos', `${slug}-memory.md`),
    doneClaimFile: path.join(deskRoot, 'memos', `${slug}-done-claim.json`),
    signalFile: path.join(deskRoot, 'memos', `${slug}-iter-signal.json`),
    verdictFile: path.join(deskRoot, 'memos', `${slug}-verify-verdict.json`),
    // v0.14.2 Bug Report #4 Fix-D: codex sometimes lands the verdict at the
    // pre-v0.13.0 legacy path. We track the absolute legacy location so the
    // signal-poller last-chance read can fall back to it before declaring
    // timeout. Always rooted at <project>/.claude/ralph-desk/memos/, even
    // when RLP_DESK_RUNTIME_DIR overrides the canonical deskRoot.
    legacyVerdictFile: path.join(rootDir, '.claude', 'ralph-desk', 'memos', `${slug}-verify-verdict.json`),
    blockedSentinel: path.join(deskRoot, 'memos', `${slug}-blocked.md`),
    completeSentinel: path.join(deskRoot, 'memos', `${slug}-complete.md`),
    contextFile: path.join(deskRoot, 'context', `${slug}-latest.md`),
    prdFile: path.join(deskRoot, 'plans', `prd-${slug}.md`),
    testSpecFile: path.join(deskRoot, 'plans', `test-spec-${slug}.md`),
    // US-002: first-class campaign-scope waiver file (leader-validated,
    // fail-closed, authorized out-of-band via RLP_WAIVERS_SHA256).
    waiversFile: path.join(deskRoot, 'plans', 'waivers.json'),
    analyticsFile: path.join(campaignLogDir, 'campaign.jsonl'),
    // v5.7 §4.11.b: project-local analytics so Worker/Verifier prompts that
    // reference this path stay inside cwd-tree (no `--add-dir` whitelist needed
    // for cross-cwd writes). Cross-project rollup uses ~/.claude/ralph-desk/registry.jsonl
    // (Leader-only, never appears in Worker prompts) — see §4.11.c.
    analyticsDir: path.join(deskRoot, 'analytics', slug),
    reportFile: path.join(campaignLogDir, 'campaign-report.md'),
    statusFile: path.join(campaignLogDir, 'runtime', 'status.json'),
    flywheelPromptFile: path.join(deskRoot, 'prompts', `${slug}.flywheel.prompt.md`),
    flywheelSignalFile: path.join(deskRoot, 'memos', `${slug}-flywheel-signal.json`),
    flywheelGuardPromptFile: path.join(deskRoot, 'prompts', `${slug}.flywheel-guard.prompt.md`),
    flywheelGuardVerdictFile: path.join(deskRoot, 'memos', `${slug}-flywheel-guard-verdict.json`),
    laneAuditFile: path.join(campaignLogDir, 'lane-audit.json'),
    // v0.15.4 PR-B4: structured debug.log. log_lifecycle_metric (zsh) and
    // LifecycleMetricsCollector (Node) both emit here when
    // lifecycle telemetry (always on since v0.22.4).
    debugLogFile: path.join(campaignLogDir, 'debug.log'),
};
}

// IMP-03: resolve the zsh leader's analytics location through its pointer file.
// The production zsh leader writes campaign.jsonl under
// `analytics/<slug>--<md5(ROOT):0:8>/` (an intra-machine hash the Node side
// intentionally does NOT reproduce — cross-platform hash parity is a non-goal)
// and records the resolved dir in the hash-free pointer
// `analytics/<slug>.current`. Readers resolve through the pointer; a missing
// pointer or a stale pointer (target dir gone) returns null so callers fall
// back to the legacy buildPaths locations — no worse than the pre-pointer
// behavior.
export async function resolveAnalyticsPointer(deskRoot, slug) {
  const pointerFile = path.join(deskRoot, 'analytics', `${slug}.current`);
  let target;
  try {
    target = (await fs.readFile(pointerFile, 'utf8')).trim();
  } catch {
    return null;
  }
  if (!target) return null;
  try {
    const stat = await fs.stat(target);
    if (!stat.isDirectory()) return null;
  } catch {
    return null;
  }
  return {
    analyticsDir: target,
    analyticsFile: path.join(target, 'campaign.jsonl'),
  };
}

// Bug #8 PR-B: default git working-tree probe. Inline (~20 LoC) — no new
// module per Architect/Critic codex iter 6 consensus. Tests inject a stub via
// run() option `checkWorkingTree`.
//   - returns { ok: false, error } when git rev-parse fails (not a repo, etc).
//   - returns { ok: true, dirty: bool, dirtyFiles[] } otherwise.
//   - dirtyFiles are raw `git status --porcelain` lines (caller truncates).
async function _defaultCheckWorkingTree(rootDir) {
  try {
    const { stdout: top } = await execFileAsync('git', ['-C', rootDir, 'rev-parse', '--show-toplevel']);
    const trimmed = top.trim();
    // macOS `/var` resolves to `/private/var`; symlinks elsewhere too. Compare
    // canonical realpaths via fs.realpath so the comparison does not fire on
    // symlink-equivalent paths.
    const [topCanon, rootCanon] = await Promise.all([
      fs.realpath(trimmed).catch(() => trimmed),
      fs.realpath(rootDir).catch(() => rootDir),
    ]);
    if (topCanon !== rootCanon) {
      // Worker is in a sub-tree, not the campaign root. Refuse to classify.
      return { ok: false, error: `git toplevel ${trimmed} != ${rootDir}` };
    }
  } catch (err) {
    return { ok: false, error: err?.message ?? String(err) };
  }
  try {
    const { stdout } = await execFileAsync('git', ['-C', rootDir, 'status', '--porcelain']);
    const lines = stdout.split('\n').filter(Boolean);
    return { ok: true, dirty: lines.length > 0, dirtyFiles: lines };
  } catch (err) {
    return { ok: false, error: err?.message ?? String(err) };
  }
}

// US-001: git helpers for the commit-integrity oracle. These do the I/O; the
// PURE predicate lives in ../shared/commit-oracle.mjs (Principle 6, kept I/O-free).
async function _gitHeadSha(rootDir) {
  try {
    const { stdout } = await execFileAsync('git', ['-C', rootDir, 'rev-parse', 'HEAD']);
    return stdout.trim();
  } catch {
    return '';
  }
}

async function _gitObjectExists(rootDir, rev) {
  try {
    await execFileAsync('git', ['-C', rootDir, 'cat-file', '-e', rev]);
    return true;
  } catch {
    return false;
  }
}

async function _gitIsAncestor(rootDir, ancestor, descendant) {
  try {
    await execFileAsync('git', ['-C', rootDir, 'merge-base', '--is-ancestor', ancestor, descendant]);
    return true;
  } catch {
    return false;
  }
}

// Mirrors the zsh _git_dirty_base: HEAD when the repo has commits, else git's
// empty-tree object so a staged-but-never-committed file is still listed.
async function _gitDirtyBase(rootDir) {
  try {
    await execFileAsync('git', ['-C', rootDir, 'rev-parse', '--verify', 'HEAD']);
    return 'HEAD';
  } catch {
    try {
      const { stdout } = await execFileAsync('git', ['-C', rootDir, 'hash-object', '-t', 'tree', '/dev/null']);
      return stdout.trim() || '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
    } catch {
      return '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
    }
  }
}

// TRACKED-only dirty files vs the dirty-base, minus the campaign-preexisting set.
// This is the oracle's OWN tracked-delta predicate (AC1.2) — deliberately NOT
// checkWorkingTree, which counts ALL `git status --porcelain` entries incl.
// untracked and would false-fail. Mirrors zsh _commit_oracle_tracked_dirty.
export async function _gitTrackedDirtyWorkerFiles(rootDir, preexistingDirty = []) {
  const base = await _gitDirtyBase(rootDir);
  // GIT-FC (IMP-09): do NOT swallow a git error into an empty (clean) list — a
  // failed diff must PROPAGATE (throw) so the caller forces a full verifier
  // round instead of the oracle corroborating a claim against a corrupt empty
  // dirty set. Mirrors zsh _commit_oracle_tracked_dirty's rc-2 contract.
  const { stdout } = await execFileAsync('git', ['-C', rootDir, 'diff', '--name-only', base]);
  const dirty = stdout.split('\n').filter(Boolean);
  const pre = new Set(preexistingDirty ?? []);
  return dirty.filter((file) => !pre.has(file));
}

// G3: does the claimed commit's tree equal its PARENT's (an empty commit)?
// Returns true | false | 'unknown'. Mirrors zsh _commit_oracle_empty_tree.
//
// The codex C3 split, which this function exists to hold: a parent that is
// EXPECTEDLY unavailable — a root commit, or a shallow clone whose parent is
// grafted away — is not a git failure. It yields 'unknown', and the predicate
// accepts. Every OTHER git failure (unresolvable sha, corrupt object, git binary
// error) THROWS, so the caller keeps the existing GIT-FC infra path (zsh rc 2):
// swallowing those into 'unknown' would let a broken repo silently corroborate a
// commit claim, which is the exact failure GIT-FC was built to prevent.
export async function _gitClaimedCommitEmptyTree(rootDir, sha) {
  let parent;
  try {
    const { stdout } = await execFileAsync(
      'git', ['-C', rootDir, 'rev-parse', '--verify', '--quiet', `${sha}^{commit}^`],
    );
    parent = stdout.trim();
  } catch (err) {
    // Parent lookup failed. LOW-6 (SV gate) — precise claim: this only
    // proves the CHILD commit object is readable (_gitObjectExists on $sha)
    // and that the parent FIELD is absent/unresolvable (rev-parse on $sha^
    // threw) — a genuine root commit or a shallow-clone graft. It does NOT
    // prove a parent OBJECT (if the field pointed to one) is intact:
    // rev-parse reads the child's parent pointer without dereferencing it,
    // so a present-but-corrupt parent object would ALSO make rev-parse
    // succeed, taking the `git diff --quiet parent sha` path below instead
    // — that call is where a corrupt/missing parent object actually
    // surfaces (throws, caught below, re-thrown as a genuine git error,
    // preserving the GIT-FC path). So this branch is reached only when the
    // parent FIELD itself is empty.
    if (await _gitObjectExists(rootDir, `${sha}^{commit}`)) {
      return 'unknown';
    }
    throw err;
  }
  if (!parent) {
    return 'unknown';
  }
  try {
    await execFileAsync('git', ['-C', rootDir, 'diff', '--quiet', parent, sha]);
    return true; // exit 0 → no tree delta → empty commit
  } catch (err) {
    if (err && err.code === 1) {
      return false; // exit 1 → real changes (git diff --quiet is --exit-code)
    }
    throw err; // exit >1 / spawn failure → genuine git error
  }
}

// US-001: default git-gathering wrapper around the pure commit-oracle predicate.
// Kept SEPARATE from evaluateCommitOracle (I/O-free). Tests inject a stub via
// run() option `checkCommitIntegrity`; the shared-fixture parity matrix drives the
// pure predicate directly (commit-oracle.mjs), matching the zsh helper (AC1.6).
export async function _defaultCheckCommitIntegrity(rootDir, { doneClaim, iterStartHead = '', preexistingDirty = [] } = {}) {
  const claim = findCommitClaim(doneClaim);
  if (!claim) {
    // No commit asserted → no-op, no git needed.
    return evaluateCommitOracle({ doneClaim });
  }
  const currentHead = await _gitHeadSha(rootDir);
  const claimedSha = typeof claim.commit_sha === 'string' ? claim.commit_sha.trim() : '';
  let claimedShaResolves = false;
  let claimedShaReachable = false;
  if (claimedSha) {
    claimedShaResolves = await _gitObjectExists(rootDir, `${claimedSha}^{commit}`);
    if (claimedShaResolves) {
      claimedShaReachable = await _gitIsAncestor(rootDir, claimedSha, 'HEAD');
    }
  }
  // GIT-FC (IMP-09): a git error gathering the tracked-dirty set is infra, not a
  // worker lie — surface it as a distinct infra result (matching zsh rc 2) so the
  // loop forces a full verifier round without counting it toward the oracle cap.
  // The pure evaluateCommitOracle never sees garbage facts (Purity principle 6).
  let trackedDirtyWorkerFiles;
  try {
    trackedDirtyWorkerFiles = await _gitTrackedDirtyWorkerFiles(rootDir, preexistingDirty);
  } catch (err) {
    return {
      asserted: true,
      ok: false,
      infra: true,
      reason: 'git_facts_unavailable',
      detail: `commit-oracle git snapshot failed (git error): ${String(err)}`,
      claimedSha,
    };
  }
  // G3: the empty-tree fact. Gathered HERE because the predicate is I/O-free —
  // without this the empty-commit rejection would ship as dead code that only
  // the pure-predicate tests ever reach. Probed only when the claimed sha
  // resolves: an unresolvable sha is already adjudicated as claimed_sha_absent
  // (a worker lie, NOT infra), so it must not be re-routed through this probe.
  let claimedCommitEmptyTree = 'unknown';
  if (claimedSha && claimedShaResolves) {
    try {
      claimedCommitEmptyTree = await _gitClaimedCommitEmptyTree(rootDir, claimedSha);
    } catch (err) {
      return {
        asserted: true,
        ok: false,
        infra: true,
        reason: 'git_facts_unavailable',
        detail: `commit-oracle git snapshot failed (git error): ${String(err)}`,
        claimedSha,
      };
    }
  }
  return evaluateCommitOracle({
    doneClaim,
    iterStartHead,
    currentHead,
    claimedShaResolves,
    claimedShaReachable,
    trackedDirtyWorkerFiles,
    claimedCommitEmptyTree,
  });
}

async function exists(targetPath) {
  try {
    await fs.access(targetPath);
    return true;
  } catch {
    return false;
  }
}

async function ensureScaffold(paths) {
  const missing = [];
  for (const key of REQUIRED_SCAFFOLD_NAMES) {
    if (!(await exists(paths[key]))) {
      missing.push(paths[key]);
    }
  }

  if (missing.length > 0) {
    throw new Error(`missing required scaffold: ${missing.join(', ')}`);
  }
}

async function ensureDirs(paths) {
  await fs.mkdir(paths.campaignLogDir, { recursive: true });
  await fs.mkdir(paths.runtimeDir, { recursive: true });
  await fs.mkdir(paths.omxStateDir, { recursive: true });
}

async function readJsonIfExists(targetPath) {
  if (!(await exists(targetPath))) {
    return null;
  }

  return JSON.parse(await fs.readFile(targetPath, 'utf8'));
}

async function writeJson(targetPath, value) {
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

async function readUsList(paths, slug) {
  const entries = await fs.readdir(paths.plansDir, { withFileTypes: true });
  const splitPrefix = `prd-${slug}-US-`;
  const splitFiles = entries
    .filter((entry) => entry.isFile() && entry.name.startsWith(splitPrefix) && entry.name.endsWith('.md'))
    .map((entry) => entry.name.match(/US-\d{3}/)?.[0])
    .filter(Boolean)
    .sort();

  if (splitFiles.length > 0) {
    return splitFiles;
  }

  const prdContent = await fs.readFile(paths.prdFile, 'utf8');
  return [...prdContent.matchAll(/^## (US-\d{3}):/gm)].map((match) => match[1]);
}

function getNextUs(usList, verifiedUs, currentUs) {
  if (currentUs && usList.includes(currentUs) && !verifiedUs.includes(currentUs)) {
    return currentUs;
  }

  return usList.find((usId) => !verifiedUs.includes(usId)) ?? 'ALL';
}

function toIso(now) {
  return new Date(now).toISOString();
}

function resolveNow(nowOverride) {
  if (typeof nowOverride === 'function') {
    return nowOverride();
  }

  return nowOverride ?? Date.now();
}

async function writeStatus(paths, status, onStatusChange, nowOverride) {
  const nextStatus = {
    ...status,
    updated_at_utc: toIso(resolveNow(nowOverride)),
  };
  await writeJson(paths.statusFile, nextStatus);
  if (typeof onStatusChange === 'function') {
    onStatusChange(nextStatus);
  }
}

function shQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

// fix/omx-state-isolation: omxStateDir is optional so non-campaign callers of
// this helper (if any emerge) keep the byte-identical unprefixed command —
// only the campaign dispatch sites below pass paths.omxStateDir.
// Exported for direct unit testing (compat path: no omxStateDir -> no prefix).
export function buildLaunchCommand(promptFile, modelFlag, omxStateDir) {
  const parsed = parseModelFlag(modelFlag);
  const promptExpr = `"$(cat ${shQuote(promptFile)})"`;

  if (parsed.engine === 'claude') {
    return `${buildClaudeCmd('tui', parsed.model, { effort: parsed.effort })} ${promptExpr}`;
  }

  const codexCmd = buildCodexCmd('tui', parsed.model, { reasoning: parsed.reasoning });
  const omxPrefix = omxStateDir ? `OMX_STATE_ROOT=${shQuote(omxStateDir)} ` : '';
  return `${omxPrefix}${codexCmd} ${promptExpr}`;
}

async function writePromptFile(targetPath, content) {
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, content, 'utf8');
}

// Exported for direct unit testing (US-003: verdict-schema contract test
// asserts buildFixContract absorbs all three producer shapes via the shared
// normalizer — see tests/node/test-verdict-schema-contract.test.mjs).
export function buildFixContract(verdict) {
  const issues = normalizeVerdict(verdict).issues.sort((left, right) => {
    const rank = { critical: 0, major: 1, minor: 2 };
    return (rank[left.severity] ?? 3) - (rank[right.severity] ?? 3);
  });

  const lines = ['# Fix Contract', ''];
  if (issues.length === 0) {
    lines.push('- No structured issues were provided. Re-check the failing scope and verifier evidence.');
  }

  for (const issue of issues) {
    lines.push(`- ${issue.label} [${issue.severity}]: ${issue.text}`);
    if (issue.fix_hint) {
      lines.push(`  fix_hint: ${issue.fix_hint}`);
    }
  }

  return `${lines.join('\n')}\n`;
}

// Layer 1.5 done-claim TDD-sequence lint fix contract (request-h). Mirrors the
// zsh `_pregate_register_fail_doneclaim_lint` shape: per-AC idx coordinates so
// the Worker fixes ONLY the done-claim execution_steps format, not the
// deliverable. Exported for direct unit testing (parity with the zsh writer).
export function buildDoneClaimLintFixContract(iteration, violations) {
  const lines = [
    `# Fix Contract (PRE-GATE FAILURE, iteration ${iteration})`,
    '',
    '## PRE-GATE FAILURE (done-claim format lint)',
    '- rule: build-mode done-claim must contain write_test → verify_red → implement → verify_green for EACH acceptance criterion, each step labeled with that AC id (comma lists OK; the bundle label "all" does NOT satisfy these 4 phases)',
    '- idx column order: [write_test, verify_red, implement, verify_green]; -1 = step missing for that AC; non-increasing = steps out of order',
    '- violations:',
  ];
  for (const violation of violations ?? []) {
    lines.push(`  - ${violation.ac}: idx=${JSON.stringify(violation.idx)}`);
  }
  lines.push('');
  lines.push('## Next Iteration Contract');
  lines.push(
    'Fix ONLY the done-claim execution_steps format for the ACs listed above (add the missing per-AC labeled steps / correct the order), then resubmit the done-claim. Do not re-implement the deliverable.',
  );
  return `${lines.join('\n')}\n`;
}

// Exported for direct unit testing (US-001: tests/node/models-ladder.test.mjs
// exercises the ""->'BLOCKED' ceiling normalization and the :low->:medium
// alignment against the real shipped MODEL_UPGRADES map).
export function nextWorkerModel(currentModel, consecutiveFailures) {
  if (consecutiveFailures < 3) {
    return currentModel;
  }

  const stage = Math.floor(consecutiveFailures / 3);
  let model = currentModel;

  for (let index = 0; index < stage; index += 1) {
    const next = MODEL_UPGRADES[model];
    if (!next || next === 'BLOCKED') {
      return 'BLOCKED';
    }
    model = next;
  }

  return model;
}

// Effort-aware task budget (2026-08-03 luna-first spec §6): slow reasoning
// efforts get a longer per-iteration budget. Worker polls only — verifier
// waits keep the base timeout.
export function effectiveIterTimeoutMs(baseMs, workerModel) {
  const model = workerModel ?? '';
  if (model.endsWith(':max')) return baseMs * 2;
  if (model.endsWith(':xhigh')) return Math.floor(baseMs * 1.5);
  return baseMs;
}

// Luna-first spec §2.5: environment/harness failures (incl. verifier
// safety-classifier refusals) and flaky failures never climb the ladder.
// Governance classifies failures per ISSUE, so the field legitimately appears
// top-level, inside issues[], inside reasoning[], or inside checks[] depending
// on the producer — all four placements must resolve (zsh parity:
// _verdict_failure_category in src/scripts/lib_ralph_desk.zsh). reasoning[] is
// the per-check array the verifier contract actually emits (see the Verdict
// JSON block in init_ralph_desk.zsh); checks[] is kept for other producers.
export function verdictFailureCategory(verdict) {
  if (!verdict || typeof verdict !== 'object') return '';
  if (typeof verdict.failure_category === 'string') return verdict.failure_category;
  for (const list of [verdict.issues, verdict.reasoning, verdict.checks]) {
    if (Array.isArray(list)) {
      const hit = list.find((item) => item && typeof item.failure_category === 'string');
      if (hit) return hit.failure_category;
    }
  }
  return '';
}

export function escalationEligible(verdict) {
  const cat = verdictFailureCategory(verdict);
  return cat !== 'environment' && cat !== 'flaky';
}

// Counter transition for ONE failed iteration, shared by the verifier-fail and
// oracle paths (identical rule at both) and exported so the ladder-arithmetic
// tests drive this implementation instead of a copy of it.
//
// Dual counter, mirroring the zsh leader:
//   consecutive_failures        — every failure; owns the circuit breaker and
//                                 BLOCKED-on-exhaustion (zsh CONSECUTIVE_FAILURES)
//   escalation_eligible_failures — eligible failures only; sole input to the
//                                 ladder rung arithmetic (zsh's
//                                 _SAME_US_FAIL_COUNT, which lives inside the
//                                 check_model_upgrade that the guard skips)
//
// Mutates `state` in place to match the surrounding loop's style. Returns
// whether this failure was escalation-eligible.
export function recordFailureCounters(state, verdict) {
  const eligible = escalationEligible(verdict);
  state.consecutive_failures = (state.consecutive_failures ?? 0) + 1;
  if (eligible) {
    state.escalation_eligible_failures = (state.escalation_eligible_failures ?? 0) + 1;
  }
  return eligible;
}

export async function defaultCreateSession({ sessionName, workingDir, env = process.env, execFile: execFileImpl } = {}) {
  const exec = execFileImpl ?? execFileAsync;
  // v0.13.1: when invoked from inside an attached tmux session, the user
  // expects worker/verifier/flywheel panes to split off the CURRENT pane in
  // the CURRENT window (mirrors zsh runner src/scripts/run_ralph_desk.zsh
  // L815-823). The detached `new-session` fallback below is preserved for
  // non-tmux invocation (CI, plain shells).
  if (env && env.TMUX) {
    const { stdout: paneOut } = await exec('tmux', [
      'display-message', '-p', '-F', '#{pane_id}',
    ]);
    const { stdout: sessOut } = await exec('tmux', [
      'display-message', '-p', '-F', '#{session_name}',
    ]);
    return {
      sessionName: sessOut.trim() || sessionName,
      leaderPaneId: paneOut.trim(),
    };
  }

  const { stdout } = await exec('tmux', [
    'new-session',
    '-d',
    '-P',
    '-F',
    '#{pane_id}',
    '-s',
    sessionName,
    '-c',
    workingDir,
  ]);

  return {
    sessionName,
    leaderPaneId: stdout.trim(),
  };
}

function deriveVerifierModel(usId, options) {
  return usId === 'ALL'
    ? (options.finalVerifierModel ?? 'opus')
    : (options.verifierModel ?? 'sonnet');
}

async function readCurrentState(paths, slug, options) {
  const status = (await readJsonIfExists(paths.statusFile)) ?? {};
  const startedAt = status.started_at_utc ?? toIso(resolveNow(options.now));
  return {
    slug,
    iteration: status.iteration ?? 1,
    max_iterations: status.max_iterations ?? options.maxIterations ?? 100,
    phase: status.phase ?? 'worker',
    worker_model: status.worker_model ?? options.workerModel ?? 'sonnet',
    verifier_model: status.verifier_model ?? options.verifierModel ?? 'sonnet',
    final_verifier_model: status.final_verifier_model ?? options.finalVerifierModel ?? 'opus',
    verified_us: status.verified_us ?? [],
    consecutive_failures: status.consecutive_failures ?? 0,
    // Luna-first spec §2.5 dual counter (zsh parity): consecutive_failures owns
    // the circuit breaker / BLOCKED-on-exhaustion and counts EVERY failure;
    // escalation_eligible_failures owns the ladder rung arithmetic and counts
    // only escalation-eligible failures, so environment/flaky failures never
    // advance the rung. Mirrors zsh's CONSECUTIVE_FAILURES vs the
    // _SAME_US_FAIL_COUNT that lives inside the skipped check_model_upgrade.
    // Backward compat for a status.json written BEFORE this field existed: fall
    // back to consecutive_failures, not 0. Every failure counted by such a file
    // was escalation-eligible under the old rule (that was the defect), so this
    // resumes an in-flight failure streak exactly as it behaved pre-upgrade —
    // US-006 AC6.3 ("resume preserves the failure streak so the next failure
    // upgrades immediately") depends on it. Defaulting to 0 would silently
    // swallow the streak across the upgrade boundary. A fresh campaign has no
    // status.json at all, so both fields are absent and this yields 0.
    escalation_eligible_failures:
      status.escalation_eligible_failures ?? status.consecutive_failures ?? 0,
    // US-021 R9 P2-I consecutive_blocks counter (governance §8). Tracks repeated
    // same-canonical-reason worker blocks; verify_fail uses consecutive_failures.
    consecutive_blocks: status.consecutive_blocks ?? 0,
    last_block_reason: status.last_block_reason ?? '',
    current_us: status.current_us ?? null,
    session_name: status.session_name ?? null,
    leader_pane_id: status.leader_pane_id ?? null,
    worker_pane_id: status.worker_pane_id ?? null,
    verifier_pane_id: status.verifier_pane_id ?? null,
    flywheel_guard_count: status.flywheel_guard_count ?? {},
    // US-001 AC1.3: durable per-iteration HEAD snapshot. Restored so a relaunch
    // that re-enters mid-iteration keeps the correct commit-oracle baseline.
    iter_start_head: status.iter_start_head ?? '',
    // Layer 1.5 done-claim format lint: per-US fail counter (governance §3a).
    // Mirrors the zsh leader's _pregate_bump semantics — keyed to the US, reset
    // on US change or a pass; NEVER drives the consecutive-failure circuit
    // breaker. Persisted like the sibling oracle-adjacent state above.
    pregate_lint_failures: status.pregate_lint_failures ?? 0,
    pregate_lint_us: status.pregate_lint_us ?? null,
    started_at_utc: startedAt,
  };
}

// PR-A (Bug #10): validate operator-written recovery artifacts. When the
// operator hand-rolls a `phase=verify` recovery (jq-patches status.json,
// writes iter-signal.json + done-claim.json by hand, deletes the blocked
// sentinel), the leader must NOT silently overwrite that work on relaunch.
// All five checks must pass for the leader to honor the recovery.
//
// Returns { ok: boolean, reason: string }. On any failure the caller falls
// through to the default behavior (worker dispatch) — defensive by design.
async function _validateOperatorRecoveryArtifacts({ paths, state }) {
  // 1. iter-signal.json + done-claim.json must both exist and parse.
  let signal;
  let doneClaim;
  try {
    signal = await readJsonIfExists(paths.signalFile);
  } catch (err) {
    return { ok: false, reason: `iter-signal.json parse error: ${err?.message ?? err}` };
  }
  if (!signal) return { ok: false, reason: 'iter-signal.json missing' };

  try {
    doneClaim = await readJsonIfExists(paths.doneClaimFile);
  } catch (err) {
    return { ok: false, reason: `done-claim.json parse error: ${err?.message ?? err}` };
  }
  if (!doneClaim) return { ok: false, reason: 'done-claim.json missing' };

  // 2. us_id must match status.current_us in BOTH artifacts.
  if (signal.us_id !== state.current_us) {
    return {
      ok: false,
      reason: `iter-signal.us_id (${signal.us_id}) != status.current_us (${state.current_us})`,
    };
  }
  if (doneClaim.us_id !== state.current_us) {
    return {
      ok: false,
      reason: `done-claim.us_id (${doneClaim.us_id}) != status.current_us (${state.current_us})`,
    };
  }

  // 3. iteration must match status.iteration in BOTH artifacts.
  if (signal.iteration !== state.iteration) {
    return {
      ok: false,
      reason: `iter-signal.iteration (${signal.iteration}) != status.iteration (${state.iteration})`,
    };
  }
  if (doneClaim.iteration !== state.iteration) {
    return {
      ok: false,
      reason: `done-claim.iteration (${doneClaim.iteration}) != status.iteration (${state.iteration})`,
    };
  }

  // 4. iter_signal_quality must be 'specific' (not generic / vague).
  if (signal.iter_signal_quality !== 'specific') {
    return {
      ok: false,
      reason: `iter-signal.iter_signal_quality (${signal.iter_signal_quality}) != 'specific'`,
    };
  }

  // 5. Both artifact mtimes must be NEWER than the most recent
  //    iter-NNN.worker-prompt.md mtime — guards against operator running
  //    `phase=verify` against stale artifacts from a much earlier iteration.
  const promptFile = path.join(
    paths.campaignLogDir,
    `iter-${String(state.iteration).padStart(3, '0')}.worker-prompt.md`,
  );
  let promptMtime = 0;
  try {
    const promptStat = await fs.stat(promptFile);
    promptMtime = promptStat.mtimeMs;
  } catch {
    // No worker-prompt.md for this iteration → check vacuously passes
    // (operator is recovering from a state that never even dispatched yet).
    promptMtime = 0;
  }
  if (promptMtime > 0) {
    let signalMtime = 0;
    let doneClaimMtime = 0;
    try {
      signalMtime = (await fs.stat(paths.signalFile)).mtimeMs;
      doneClaimMtime = (await fs.stat(paths.doneClaimFile)).mtimeMs;
    } catch (err) {
      return { ok: false, reason: `mtime stat failed: ${err?.message ?? err}` };
    }
    if (signalMtime <= promptMtime) {
      return {
        ok: false,
        reason: `iter-signal.json mtime (${signalMtime}) is not strictly newer than worker-prompt mtime (${promptMtime})`,
      };
    }
    if (doneClaimMtime <= promptMtime) {
      return {
        ok: false,
        reason: `done-claim.json mtime (${doneClaimMtime}) is not strictly newer than worker-prompt mtime (${promptMtime})`,
      };
    }
  }

  return { ok: true, reason: 'all five checks passed' };
}

// PR-E (Phase C1, stabilization): operator-cleared BLOCKED recovery.
// When operator manually deletes <slug>-blocked.md to recover (a documented
// flow), counters in status.json (consecutive_failures / consecutive_blocks)
// stay populated. Without this branch, leader relaunches with stale counters
// and may immediately re-BLOCK on the first failure even though operator's
// intent was a fresh start. Pair to PR-A (phase=verify recovery, Bug #10).
//
// 4-check validator. Returns { ok, reason }. On any failure, caller falls
// through to existing behavior — defensive default, never auto-recovers
// against ambiguous state.
//
// Check 4 reads <slug>-blocked.json sidecar (NOT status.json), because
// status.json never persists `last_block_reason` (blocked-write code path
// at L920-968 doesn't write that field). The sidecar DOES carry
// `recoverable: bool` per _classifyBlock contract — that's the canonical
// non-recoverable signal.
async function _validateBlockedRecovery({ paths, state }) {
  // Check 1: precondition
  if (state.phase !== 'blocked') {
    return { ok: false, reason: `state.phase is ${state.phase}, not 'blocked'` };
  }
  // Check 2: sentinel cleared by operator
  if (await exists(paths.blockedSentinel)) {
    return { ok: false, reason: 'blocked sentinel still present (operator did not clear)' };
  }
  // Check 3: counters non-zero (something to reset)
  const failures = state.consecutive_failures ?? 0;
  const blocks = state.consecutive_blocks ?? 0;
  if (failures === 0 && blocks === 0) {
    return { ok: false, reason: 'counters already zero, nothing to recover' };
  }
  // Check 4: sidecar safety check
  const sidecarPath = paths.blockedSentinel.replace(/\.md$/, '.json');
  let sidecar = null;
  try {
    sidecar = await readJsonIfExists(sidecarPath);
  } catch (err) {
    // Malformed sidecar — be defensive and fall through.
    return { ok: false, reason: `blocked.json sidecar parse error: ${err?.message ?? err}` };
  }
  if (sidecar && sidecar.recoverable === false) {
    return {
      ok: false,
      reason: `non-recoverable category ${sidecar.reason_category ?? 'unknown'} from sidecar (use clean to reset)`,
    };
  }
  return { ok: true, reason: 'sidecar absent or recoverable=true; recovery permitted' };
}

// PR-E helper: rename the recovered sidecar so operator can audit what was
// recovered from. Best-effort — failure here is non-fatal.
async function _archiveRecoveredSidecar(paths) {
  const sidecarPath = paths.blockedSentinel.replace(/\.md$/, '.json');
  if (!(await exists(sidecarPath))) return;
  const iso = new Date().toISOString().replace(/[:.]/g, '-');
  const archivePath = `${sidecarPath}.recovered-${iso}`;
  try {
    await fs.rename(sidecarPath, archivePath);
  } catch (err) {
    console.error(`[recovery] failed to archive sidecar: ${err?.message ?? err}`);
  }
}

// G1.g / C1: byte basis parity with the zsh leader's write_cost_log — same
// three artifacts (rendered worker prompt, done-claim, verdict), same ÷4
// estimate. zsh's `$(( bytes / 4 ))` is zsh integer arithmetic, which
// truncates toward zero for non-negative operands; Math.floor here is the
// Node-side equivalent so an identical byte total converts to an identical
// estimated_tokens value on both leaders (pin this rule on both sides — do
// not change one without the other). Best-effort per file: a missing/
// unreadable artifact contributes 0 bytes rather than throwing.
async function _iterationArtifactBytes(paths, iteration) {
  const promptFile = path.join(paths.campaignLogDir, `iter-${String(iteration).padStart(3, '0')}.worker-prompt.md`);
  const sizes = await Promise.all([promptFile, paths.doneClaimFile, paths.verdictFile].map(async (file) => {
    try {
      const stat = await fs.stat(file);
      return stat.size;
    } catch {
      return 0;
    }
  }));
  return sizes.reduce((sum, size) => sum + size, 0);
}

// C2 (batch-audit critic): appendIterationAnalytics is called from BOTH a
// real worker-dispatch outcome (pass/fail/blocked/oracle-fail — the current
// iteration's prompt/done-claim/verdict files are genuinely this
// iteration's) AND the loop-top lane-violation path (L1933), which fires
// BEFORE the current iteration's worker prompt exists — its
// paths.workerPrompt/doneClaimFile/verdictFile are stale, reused, or absent.
// Charging a synthetic lane_violation_warning row with a byte count read
// from the WRONG iteration's artifacts would corrupt the sol-equivalent sum.
// isWorkerDispatch=false rows get an explicit, non-throwing zero (0 is not
// 'missing' to appendCampaignAnalytics's strict undefined/null/'' check —
// see the zero-byte-iteration test) and token_source:'none' so
// summarizeCost can exclude them from token aggregation WITHOUT confusing
// them for the separate "legacy row missing the field entirely" case (see
// summarizeCost below).
export async function appendIterationAnalytics(paths, state, usId, verdict, options, lifecycleMetrics = null, isWorkerDispatch = true, durationSeconds = 0) {
  // v0.15.4 PR-B4: lifecycle_metrics field — null when flag unset (collector
  // returns null), object grouped by metric name when flag set. Test:
  // tests/node/test-campaign-jsonl-shape.mjs.
  const lifecycleSnapshot = lifecycleMetrics ? lifecycleMetrics.flush() : null;
  const estimatedTokens = isWorkerDispatch
    ? Math.floor((await _iterationArtifactBytes(paths, state.iteration)) / 4)
    : 0;
  await appendCampaignAnalytics(paths.analyticsFile, {
    iter: state.iteration,
    us_id: usId,
    worker_model: state.worker_model,
    worker_engine: parseModelFlag(state.worker_model).engine,
    verdict,
    duration: isWorkerDispatch ? durationSeconds : 0,
    timestamp: toIso(resolveNow(options.now)),
    lifecycle_metrics: lifecycleSnapshot,
    estimated_tokens: estimatedTokens,
    token_source: isWorkerDispatch ? 'estimated' : 'none',
  });
}

async function dispatchWorker({
  iteration,
  paths,
  slug,
  usList,
  state,
  sendKeys,
  workerPaneId,
  fixContractPath,
  honoredWaivers = [],
}) {
  const perUsPrdPath = path.join(paths.plansDir, `prd-${slug}-${state.current_us}.md`);
  const perUsTestSpecPath = path.join(paths.plansDir, `test-spec-${slug}-${state.current_us}.md`);
  const prompt = await assembleWorkerPrompt({
    promptBase: paths.workerPrompt,
    memoryFile: paths.memoryFile,
    iteration,
    verifyMode: 'per-us',
    usList,
    verifiedUs: state.verified_us,
    fullPrdPath: paths.prdFile,
    perUsPrdPath,
    fullTestSpecPath: paths.testSpecFile,
    perUsTestSpecPath,
    fixContractPath,
    honoredWaivers,
  });
  const promptFile = path.join(paths.campaignLogDir, `iter-${String(iteration).padStart(3, '0')}.worker-prompt.md`);

  await writePromptFile(promptFile, prompt);
  await sendKeys(workerPaneId, buildLaunchCommand(promptFile, state.worker_model, paths.omxStateDir));
}

async function dispatchVerifier({
  iteration,
  suffix,
  paths,
  state,
  usId,
  sendKeys,
  verifierPaneId,
  verifierModel,
  honoredWaivers = [],
  // Layer 1.5 done-claim format lint outcome line (governance §3a). No-op when empty.
  doneClaimLint = '',
}) {
  const prompt = await assembleVerifierPrompt({
    promptBase: paths.verifierPrompt,
    iteration,
    doneClaimFile: paths.doneClaimFile,
    verifyMode: 'per-us',
    usId,
    verifiedUs: state.verified_us,
    honoredWaivers,
    doneClaimLint,
    // v0.14.2 Fix-E: hand the absolute canonical verdict path to the
    // verifier prompt. assembleVerifierPrompt appends a "CRITICAL: write
    // verdict to <path>" footer so codex does not infer the legacy
    // .claude/ralph-desk/memos/ location from CWD.
    verdictWritePath: paths.verdictFile,
  });
  const fileName = suffix
    ? `${suffix}.verifier-prompt.md`
    : `iter-${String(iteration).padStart(3, '0')}.verifier-prompt.md`;
  const promptFile = path.join(paths.campaignLogDir, fileName);

  await writePromptFile(promptFile, prompt);
  await sendKeys(verifierPaneId, buildLaunchCommand(promptFile, verifierModel, paths.omxStateDir));
  return promptFile;
}

// P1-E Lane Enforcement (governance §7e). WARN-only by default; opt-in
// strict escalates lane violations to BLOCKED with downgraded action
// (recoverable=true, retry_after_fix). audit log file is initialized to
// `[]` so the file always exists, simplifying wrapper polling.
async function _initLaneAuditLog(paths) {
  await fs.mkdir(path.dirname(paths.laneAuditFile), { recursive: true });
  if (!(await exists(paths.laneAuditFile))) {
    await fs.writeFile(paths.laneAuditFile, '[]\n', 'utf8');
  }
}

// US-020 R8 P1-H Blocked exit hygiene (governance §1f, 5th channel).
// Worker must update memory.md (Blocking History) and latest.md (Known Issues)
// before signalling blocked. We compare mtimes against `now`; either file older
// than 5 minutes means the worker skipped the hygiene step. Returns true when violated.
async function _checkBlockedHygiene(paths, now = Date.now()) {
  const threshold = 5 * 60 * 1000; // 5 minutes
  const targets = [paths.memoryFile, paths.contextFile].filter(Boolean);
  for (const file of targets) {
    try {
      const stat = await fs.stat(file);
      if (now - stat.mtimeMs > threshold) {
        return true;
      }
    } catch {
      // Missing file counts as violated — worker had nothing to update.
      return true;
    }
  }
  return false;
}

async function _snapshotLaneMtimes(paths) {
  // PRD / test-spec are read-only artifacts the worker MUST NOT modify.
  // memos and context are leader-owned; worker writes them via signal
  // files only, never by direct edit.
  const targets = [paths.prdFile, paths.testSpecFile, paths.contextFile];
  const snapshot = {};
  for (const file of targets) {
    try {
      const stat = await fs.stat(file);
      snapshot[file] = stat.mtimeMs;
    } catch {
      snapshot[file] = null;
    }
  }
  return snapshot;
}

async function _checkLaneViolations(paths, snapshotBefore, snapshotAfter, state, options) {
  const violations = [];
  for (const [file, before] of Object.entries(snapshotBefore)) {
    const after = snapshotAfter[file];
    if (before !== null && after !== null && after !== before) {
      violations.push({
        file,
        mtime_before: before,
        mtime_after: after,
        iter: state.iteration ?? 0,
        lane_mode: options.laneStrict ? 'strict' : 'warn',
      });
    }
  }
  if (violations.length === 0) return null;
  // Append to audit log (best-effort).
  try {
    const existing = JSON.parse(await fs.readFile(paths.laneAuditFile, 'utf8'));
    await fs.writeFile(paths.laneAuditFile, `${JSON.stringify([...existing, ...violations], null, 2)}\n`, 'utf8');
  } catch {
    // log file corrupted or missing — re-initialize and write fresh entries.
    await fs.writeFile(paths.laneAuditFile, `${JSON.stringify(violations, null, 2)}\n`, 'utf8');
  }
  return violations;
}

// P1-D Cross-US dependency token list (governance §1f). Keep in sync with
// the zsh helper _classify_cross_us_or_metric in lib_ralph_desk.zsh.
const CROSS_US_TOKEN_RE = /depends on US-|blocking US-|awaits US-|post-iter US-|requires US-\d+|cross-US|US-\d+ 산출물|신규 US-|post-iter/i;

// v5.7 §4.25 — typed enum for _classifyBlock tags. Replaces ad-hoc string
// literals scattered across writeSentinel call sites. Typo-safe via Object.freeze.
export const BLOCK_TAGS = Object.freeze({
  // Verdict-driven (Verifier 'fail')
  VERIFIER: 'verifier',
  // Flywheel/Guard verdicts
  FLYWHEEL_INCONCLUSIVE: 'flywheel_inconclusive',
  FLYWHEEL_EXHAUSTED: 'flywheel_exhausted',
  // Model upgrade chain exhausted
  MODEL_UPGRADE: 'model_upgrade',
  // Worker/Verifier/Flywheel/Guard pane exited without artifacts (file-guarantee)
  WORKER_EXITED: 'worker_exited_without_artifacts',
  VERIFIER_EXITED: 'verifier_exited_without_artifacts',
  FINAL_VERIFIER_EXITED: 'final_verifier_exited_without_artifacts',
  FLYWHEEL_EXITED: 'flywheel_pane_exited_without_artifacts',
  GUARD_EXITED: 'guard_pane_exited_without_artifacts',
  // Auto-Enter unsafe (default-No prompt)
  PROMPT_BLOCKED: 'prompt_blocked',
  // v0.13.0: Claude Code self-modification permission prompt (cannot be
  // dismissed by --dangerously-skip-permissions). Surfaced separately so
  // wrappers know to switch worker engine, not retry.
  PERMISSION_PROMPT: 'permission_prompt',
  // Persistent timeout without exit (different from EXITED)
  WORKER_TIMEOUT: 'worker_timeout',
  VERIFIER_TIMEOUT: 'verifier_timeout',
  FINAL_VERIFIER_TIMEOUT: 'final_verifier_timeout',
  FLYWHEEL_TIMEOUT: 'flywheel_timeout',
  GUARD_TIMEOUT: 'guard_timeout',
  // Schema validator (P1)
  MALFORMED_ARTIFACT: 'malformed_artifact',
  // Backstop (run() try/finally)
  LEADER_EXITED_WITHOUT_TERMINAL_STATE: 'leader_exited_without_terminal_state',
  // Bug #8 (Plan v6 PR-B): refuse to synthesize verify signal when codex
  // worker exited without committing. Three new tags route through
  // _handlePollFailure with reasonOverride/categoryOverride.
  CODEX_EXIT_NO_DONE_CLAIM: 'codex_exit_no_done_claim',
  GIT_STATE_UNVERIFIABLE: 'git_state_unverifiable',
  WORKER_INCOMPLETE_UNCOMMITTED: 'worker_incomplete_uncommitted',
});

// P1-D Failure Taxonomy classifier. governance §1f locks the reason_category
// values + recoverable + suggested_action defaults per source. wrapper MUST
// branch on reason_category; failure_category is diagnostic only.
export function _classifyBlock(source, { verdict, state, slug } = {}) {
  let category;
  let recoverable;
  let action;
  let failureCategory = null;
  // request-d ③: operator-routing cause (infra|contract_gap|defect), distinct
  // from reason_category. Default infra (transient/environment — dispatch, pane
  // exit, timeout, git); defect for a malformed artifact; contract_gap is
  // reserved for "the PRD must change" blocks (request-d ① prevents these
  // upstream, so no current source emits it). Unclassified sources keep infra.
  let cause = 'infra';
  switch (source) {
    case BLOCK_TAGS.FLYWHEEL_INCONCLUSIVE:
    case BLOCK_TAGS.FLYWHEEL_EXHAUSTED:
      category = 'mission_abort';
      recoverable = false;
      action = 'terminal_alert';
      break;
    case BLOCK_TAGS.MODEL_UPGRADE:
      category = 'repeat_axis';
      recoverable = false;
      action = 'next_mission_chain';
      break;
    case BLOCK_TAGS.VERIFIER: {
      const text = `${verdict?.reason ?? ''} ${verdict?.summary ?? ''}`;
      category = CROSS_US_TOKEN_RE.test(text) ? 'cross_us_dep' : 'metric_failure';
      recoverable = true;
      action = 'retry_after_fix';
      failureCategory = verdict?.failure_category ?? null;
      break;
    }
    // v5.7 §4.22 §4.24 — pane-exit-without-artifacts variants. All
    // infra_failure, not recoverable (Worker/Verifier/Flywheel/Guard pane
    // process is gone; campaign cannot proceed). failure_category preserved
    // for telemetry.
    case BLOCK_TAGS.WORKER_EXITED:
    case BLOCK_TAGS.VERIFIER_EXITED:
    case BLOCK_TAGS.FINAL_VERIFIER_EXITED:
    case BLOCK_TAGS.FLYWHEEL_EXITED:
    case BLOCK_TAGS.GUARD_EXITED:
      category = 'infra_failure';
      recoverable = false;
      action = 'investigate_pane_logs';
      failureCategory = source;
      break;
    // v5.7 §4.17 — auto-Enter on default-No would CANCEL; refuse and BLOCK.
    case BLOCK_TAGS.PROMPT_BLOCKED:
      category = 'infra_failure';
      recoverable = false;
      action = 'manual_prompt_response';
      failureCategory = 'prompt_blocked';
      break;
    // v0.13.0: Claude Code self-modification gate — switch worker engine.
    case BLOCK_TAGS.PERMISSION_PROMPT:
      category = 'infra_failure';
      recoverable = false;
      action = 'switch_worker_to_codex_or_use_agent_mode';
      failureCategory = 'permission_prompt';
      break;
    // Persistent timeout (no exit detected) — different from EXITED.
    case BLOCK_TAGS.WORKER_TIMEOUT:
    case BLOCK_TAGS.VERIFIER_TIMEOUT:
    case BLOCK_TAGS.FINAL_VERIFIER_TIMEOUT:
    case BLOCK_TAGS.FLYWHEEL_TIMEOUT:
    case BLOCK_TAGS.GUARD_TIMEOUT:
      category = 'infra_failure';
      recoverable = false;
      action = 'increase_iter_timeout_or_investigate';
      failureCategory = source;
      break;
    // v5.7 §4.25 P1 — schema validator caught a malformed/incoherent artifact.
    // Recoverable: next iteration's Worker prompt can include the schema
    // error (P2 feedback loop closure) and try again.
    case BLOCK_TAGS.MALFORMED_ARTIFACT:
      category = 'contract_violation';
      recoverable = true;
      action = 'retry_with_schema_feedback';
      failureCategory = 'malformed_artifact';
      cause = 'defect'; // request-d ③: a malformed artifact is a defect, not infra
      break;
    // Backstop: run() exited without terminal sentinel.
    case BLOCK_TAGS.LEADER_EXITED_WITHOUT_TERMINAL_STATE:
      category = 'infra_failure';
      recoverable = false;
      action = 'investigate_leader_logs';
      failureCategory = 'leader_exited_without_terminal_state';
      break;
    // Bug #8 PR-B — codex worker exited but did not write done-claim. Refuse
    // to synthesize a verify signal; surface as infra_failure so wrapper does
    // not retry blindly.
    case BLOCK_TAGS.CODEX_EXIT_NO_DONE_CLAIM:
      category = 'infra_failure';
      recoverable = false;
      action = 'investigate_pane_logs';
      failureCategory = 'codex_exit_no_done_claim';
      break;
    // Bug #8 PR-B — git status could not be resolved (not a repo, git binary
    // missing, etc). Without git we cannot prove the working tree is clean,
    // so refuse to synthesize.
    case BLOCK_TAGS.GIT_STATE_UNVERIFIABLE:
      category = 'infra_failure';
      recoverable = false;
      action = 'investigate_git_state';
      failureCategory = 'git_state_unverifiable';
      break;
    // Bug #8 PR-B — worker said it was done (done-claim present) but the tree
    // is dirty. Recoverable: next iteration's worker can finish committing.
    case BLOCK_TAGS.WORKER_INCOMPLETE_UNCOMMITTED:
      category = 'metric_failure';
      recoverable = true;
      action = 'retry_after_fix';
      failureCategory = 'worker_incomplete_uncommitted';
      break;
    default:
      category = 'metric_failure';
      recoverable = false;
      action = 'terminal_alert';
  }
  return {
    reason_category: category,
    failure_category: failureCategory,
    cause, // request-d ③: infra|contract_gap|defect operator-routing field
    recoverable,
    suggested_action: action,
    iteration: state?.iteration ?? 0,
    slug,
  };
}

// v5.7 §4.25 — uniform poll-failure → BLOCKED handler, used by every
// `pollForSignal` call site (Worker, VerifierPerUS, VerifierFinal, Flywheel,
// Guard). Mirrors the canonical Worker pattern previously inlined at line
// ~1037-1110. Idempotent via writeSentinelExclusive (first-writer-wins).
//
// Returns the early-exit object the call site should `return` to its
// orchestrator. Callers MUST `return` it (not throw), so the run() loop
// terminates cleanly with phase=blocked.
async function _handlePollFailure(error, ctx) {
  const {
    paths,
    state,
    slug,
    options,
    role, // 'worker' | 'verifier' | 'final_verifier' | 'flywheel' | 'guard'
    usIdOverride,
    // Bug #8 PR-B: when the caller has already classified the failure (e.g.
    // codex done-claim/git gate), forward an explicit BLOCK_TAGS value as
    // categoryOverride and a reason string. Named `categoryOverride` per
    // Plan v6 PRD (it overrides the tag→reason_category mapping). Existing 5
    // callers omit both and the legacy error→tag mapping below runs unchanged.
    categoryOverride,
    reasonOverride,
  } = ctx;
  const usId = usIdOverride ?? state.current_us;

  if (categoryOverride) {
    state.phase = 'blocked';
    const classification = _classifyBlock(categoryOverride, { state, slug });
    const reasonText = reasonOverride ?? `${role} blocked: ${categoryOverride}`;
    await writeSentinel(paths.blockedSentinel, 'blocked', usId, reasonText, classification, paths);
    await writeStatus(paths, state, options.onStatusChange, options.now);
    await generateCampaignReport({
      slug,
      reportFile: paths.reportFile,
      prdFile: paths.prdFile,
      statusFile: paths.statusFile,
      analyticsFile: paths.analyticsFile,
      now: resolveNow(options.now),
      blockedReason: reasonText,
      blockedCategory: classification.reason_category,
    });
    return {
      status: 'blocked',
      usId,
      reason: reasonText,
      category: classification.reason_category,
      statusFile: paths.statusFile,
    };
  }

  let tag;
  let reason;
  if (error instanceof WorkerExitedError) {
    tag = ({
      worker: BLOCK_TAGS.WORKER_EXITED,
      verifier: BLOCK_TAGS.VERIFIER_EXITED,
      final_verifier: BLOCK_TAGS.FINAL_VERIFIER_EXITED,
      flywheel: BLOCK_TAGS.FLYWHEEL_EXITED,
      guard: BLOCK_TAGS.GUARD_EXITED,
    })[role] ?? BLOCK_TAGS.WORKER_EXITED;
    reason = `${error.reason ?? 'pane exited without artifacts'}: ${error.message}`;
  } else if (error instanceof PromptBlockedError) {
    // v0.13.0: error.category is set by signal-poller when Claude Code
    // self-modification prompt is detected. Distinct tag drives a different
    // failure_category + suggested_action than the default-No prompt path.
    if (error.category === 'permission_prompt') {
      tag = BLOCK_TAGS.PERMISSION_PROMPT;
      reason = `${error.reason ?? 'permission prompt'}: ${error.message}`;
    } else {
      tag = BLOCK_TAGS.PROMPT_BLOCKED;
      reason = `${error.reason ?? 'default-No prompt'}: ${error.message}`;
    }
  } else if (error instanceof MalformedArtifactError) {
    tag = BLOCK_TAGS.MALFORMED_ARTIFACT;
    reason = `Malformed artifact at ${error.field}: expected ${error.expected}, got ${error.got}`;
  } else if (error instanceof TimeoutError) {
    tag = ({
      worker: BLOCK_TAGS.WORKER_TIMEOUT,
      verifier: BLOCK_TAGS.VERIFIER_TIMEOUT,
      final_verifier: BLOCK_TAGS.FINAL_VERIFIER_TIMEOUT,
      flywheel: BLOCK_TAGS.FLYWHEEL_TIMEOUT,
      guard: BLOCK_TAGS.GUARD_TIMEOUT,
    })[role] ?? BLOCK_TAGS.WORKER_TIMEOUT;
    reason = `${role} pollForSignal timed out: ${error.message}`;
  } else {
    // Unknown error — treat as infra_failure so backstop doesn't have to
    // synthesize. Re-throw after writing so caller's outer try/finally
    // (run() backstop) sees something but doesn't double-write.
    tag = BLOCK_TAGS.LEADER_EXITED_WITHOUT_TERMINAL_STATE;
    reason = `Unexpected error in ${role} poll: ${error?.message ?? error}`;
  }

  state.phase = 'blocked';
  const classification = _classifyBlock(tag, { state, slug });
  await writeSentinel(paths.blockedSentinel, 'blocked', usId, reason, classification, paths);
  await writeStatus(paths, state, options.onStatusChange, options.now);
  await generateCampaignReport({
    slug,
    reportFile: paths.reportFile,
    prdFile: paths.prdFile,
    statusFile: paths.statusFile,
    analyticsFile: paths.analyticsFile,
    now: resolveNow(options.now),
    blockedReason: reason,
    blockedCategory: classification.reason_category,
  });

  return {
    status: 'blocked',
    usId,
    reason,
    category: classification.reason_category,
    statusFile: paths.statusFile,
  };
}

// v5.7 §4.25 P1 — schema validator. Throws MalformedArtifactError if the
// parsed artifact violates the contract. Caller catches via _handlePollFailure.
// Hooks AFTER pollForSignal returns parsed JSON, BEFORE state mutation.
//
// Validates:
//   - slug matches campaign slug (or absent — backwards compat)
//   - iteration is integer ≥ state.iteration_floor (worker may advance, never regress)
//   - signal_type matches read context ('signal' | 'verdict' | 'flywheel_signal' | 'flywheel_guard_verdict')
//     The signal_type field is OPTIONAL for backwards compat — existing artifacts
//     don't include it. Future writers should.
//   - us_id ∈ usList ∪ {'ALL'} (closed-set)
export class MalformedArtifactError extends Error {
  constructor(message, info = {}) {
    super(message);
    this.name = 'MalformedArtifactError';
    this.field = info.field ?? null;
    this.expected = info.expected ?? null;
    this.got = info.got ?? null;
    this.raw = info.raw ?? null;
  }
}

function validateArtifact(parsed, ctx) {
  const { expectedSlug, expectedSignalType, allowedUsIds } = ctx;
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    throw new MalformedArtifactError('Artifact is not a JSON object', {
      field: '<root>',
      expected: 'object',
      got: Array.isArray(parsed) ? 'array' : typeof parsed,
      raw: parsed,
    });
  }
  if (parsed.slug !== undefined && expectedSlug && parsed.slug !== expectedSlug) {
    throw new MalformedArtifactError('slug mismatch', {
      field: 'slug',
      expected: expectedSlug,
      got: parsed.slug,
      raw: parsed,
    });
  }
  if (parsed.iteration !== undefined) {
    if (!Number.isInteger(parsed.iteration)) {
      throw new MalformedArtifactError('iteration must be integer', {
        field: 'iteration',
        expected: 'integer',
        got: typeof parsed.iteration,
        raw: parsed,
      });
    }
    // v5.7 §4.25 P1 — iteration validation is STRUCTURAL ONLY (must be integer).
    // Originally proposed as a strict lower bound (worker can never regress
    // below state.iteration_floor), this caused false BLOCKs in real campaigns
    // because (a) workers may carry over a previous iteration value across
    // multiple iterations without updating the field, and (b) the leader's
    // state.iteration is authoritative regardless of what the worker writes.
    // The leader owns iteration tracking; the worker's value is informational
    // only. State-consistency enforcement is a higher-layer concern (analytics
    // post-mortem), not a contract-violation BLOCK trigger. We deliberately
    // accept any integer here; iterationFloor parameter is retained in ctx for
    // backwards compatibility with call sites but no longer gates this check.
  }
  if (parsed.signal_type !== undefined && expectedSignalType && parsed.signal_type !== expectedSignalType) {
    throw new MalformedArtifactError('signal_type mismatch', {
      field: 'signal_type',
      expected: expectedSignalType,
      got: parsed.signal_type,
      raw: parsed,
    });
  }
  if (parsed.us_id !== undefined && Array.isArray(allowedUsIds) && allowedUsIds.length > 0) {
    if (!allowedUsIds.includes(parsed.us_id)) {
      throw new MalformedArtifactError(
        `us_id ${parsed.us_id} not in allowed set [${allowedUsIds.join(', ')}]`,
        {
          field: 'us_id',
          expected: `one of [${allowedUsIds.join(', ')}]`,
          got: parsed.us_id,
          raw: parsed,
        },
      );
    }
  }
  return parsed;
}

async function writeSentinel(filePath, status, usId, reason, classification = null, paths = null) {
  // governance §1f BLOCKED Surfacing: BLOCKED is surfaced on FIVE channels —
  // sentinel (markdown + JSON sidecar), status, console (stderr), report,
  // and (US-020 R8 P1-H, 5th channel) memory.md/latest.md hygiene update.
  // Legacy 1-line parsers still work because line 1 is unchanged.
  //
  // v5.7 §4.24 — Write Order Contract REVERSED for first-writer-wins:
  //   1. markdown sentinel FIRST via writeSentinelExclusive (O_EXCL lock).
  //      Whoever wins this is the canonical writer for this campaign exit.
  //   2. JSON sidecar SECOND, only if we won the md write.
  // Invariant: md exists ⇒ JSON exists (within ≤50ms; watchers retry).
  // If two paths race to write blocked.md/complete.md, exactly ONE wins;
  // the loser sees `wrote=false, reason=already_exists` and returns silently
  // (the campaign is already classified). Cross-path category collisions
  // resolve by first-fired timestamp (existing return-on-first-error pattern).
  const lines = [`${status.toUpperCase()}: ${usId}`];
  if (reason) lines.push(`Reason: ${reason}`);
  if (classification?.reason_category) {
    lines.push(`Category: ${classification.reason_category}`);
  }
  const mdBody = `${lines.join('\n')}\n`;

  const result = await writeSentinelExclusive(filePath, mdBody);
  if (!result.wrote) {
    // Another path already wrote the sentinel for this campaign. Idempotent
    // no-op — we are NOT the canonical writer; do not overwrite the JSON
    // sidecar either or we'll desynchronize from the winning md.
    return result;
  }

  if (status === 'blocked' && classification) {
    const jsonPath = filePath.replace(/\.md$/, '.json');
    let hygieneViolated = false;
    if (paths) {
      try {
        hygieneViolated = await _checkBlockedHygiene(paths);
      } catch {
        hygieneViolated = false;
      }
    }
    const jsonBody = {
      schema_version: '2.0',
      slug: classification.slug ?? null,
      us_id: usId,
      blocked_at_iter: classification.iteration ?? 0,
      blocked_at_utc: new Date().toISOString(),
      reason_category: classification.reason_category,
      reason_detail: reason ?? null,
      failure_category: classification.failure_category ?? null,
      // request-d ③: operator-routing cause. Closed set (infra|contract_gap|
      // defect); default infra when a classification omits it (mirrors the zsh
      // write_blocked_sentinel default).
      cause: ['infra', 'contract_gap', 'defect'].includes(classification.cause)
        ? classification.cause
        : 'infra',
      recoverable: classification.recoverable ?? false,
      suggested_action: classification.suggested_action ?? 'terminal_alert',
      meta: { blocked_hygiene_violated: hygieneViolated },
    };
    await fs.writeFile(jsonPath, `${JSON.stringify(jsonBody, null, 2)}\n`, 'utf8');
  }

  return result;
}

// R3-2 (Node parity with zsh R3-1 @ run_ralph_desk.zsh:4074): clear any stale
// verdict BEFORE dispatching a verifier. pollForSignal returns the first valid
// JSON it reads with NO mtime/freshness gate (signal-poller.mjs:188-199 plus the
// last-chance re-read at :253-258), and the verdict file is left on disk after
// consumption — loop-top only unlockSentinelFile()s without unlinking, and
// reapProducer reaps the producer pane, not the file. Without this clear, the
// per-US runFinalSequentialVerify loop re-reads the PREVIOUS US's verdict for the
// next US (wrong pass/fail), and a finalize iteration that skips loop-top cleanup
// would accept a leftover verdict.
//
// Pass EVERY path the upcoming poll might read. The main-loop verifier poll also
// hands pollForSignal a `legacySignalFile: paths.legacyVerdictFile` fallback,
// which the poller reads with the SAME no-freshness-gate last-chance read
// (signal-poller.mjs:267-274) — so a stale legacy verdict would be accepted if
// the canonical one is slow. Clearing only the canonical path leaves that hole
// open (codex R3-2 review, HIGH). Hence the variadic signature: clear canonical
// AND legacy at both dispatch sites.
//
// Unlock-then-unlink mirrors the documented fs.mjs cleanup pattern (drop the
// 0o444 lock first so unlink can't EACCES on a lock-honoring FS). `force:true`
// makes a MISSING file a no-op (idempotent-cleanup contract). Any OTHER unlink
// failure (EPERM/EACCES/parent-dir perms) is deliberately NOT swallowed — a
// surviving stale verdict would be consumed by the next poll, so we fail loud
// rather than mis-verify (codex R3-2 review, MEDIUM). This is a deliberate,
// stricter divergence from zsh R3-1's silent `rm -f "$VERDICT_FILE" 2>/dev/null`.
export async function clearStaleVerdict(...verdictFiles) {
  for (const verdictFile of verdictFiles) {
    if (!verdictFile) continue;
    await unlockSentinelFile(verdictFile);
    await fs.rm(verdictFile, { force: true });
  }
}

async function runFinalSequentialVerify({
  paths,
  state,
  usList,
  sendKeys,
  verifierPaneId,
  pollForSignal,
  runIntegrationCheck,
  iterTimeoutMs,
  // Bug #7 Fix-Q/R: optional reaper. Passed from _runCampaignBody so each
  // per-US verdict kills the verifier TUI before the next per-US dispatch
  // reuses the same pane. No-op when undefined (legacy/test callers).
  reapProducer,
  // US-002: honored campaign waivers threaded from _runCampaignBody.
  honoredWaivers = [],
}) {
  const verifierModel = state.final_verifier_model;

  for (const usId of usList) {
    // R3-2: clear the prior US's verdict (canonical + legacy) so this US's poll
    // waits for ITS verdict.
    await clearStaleVerdict(paths.verdictFile, paths.legacyVerdictFile);
    await dispatchVerifier({
      iteration: state.iteration,
      suffix: `final-${usId}`,
      paths,
      state,
      usId,
      sendKeys,
      verifierPaneId,
      verifierModel,
      honoredWaivers,
    });

    const verdict = await pollForSignal(paths.verdictFile, {
      mode: parseModelFlag(verifierModel, 'verifier').engine,
      paneId: verifierPaneId,
      timeoutMs: iterTimeoutMs,
    });

    if (typeof reapProducer === 'function') {
      await reapProducer(verifierPaneId, paths.verdictFile, 'verify-verdict');
    }

    if (verdict.verdict !== 'pass') {
      return {
        status: 'continue',
        usId,
        verdict,
      };
    }
  }

  const integrationResult = await runIntegrationCheck();
  if (integrationResult.exitCode !== 0) {
    return {
      status: 'continue',
      usId: 'ALL',
      verdict: {
        verdict: 'fail',
        recommended_state_transition: 'continue',
        issues: [
          {
            criterion_id: 'AC-6.4',
            severity: 'major',
            summary: integrationResult.summary ?? 'integration verification failed',
          },
        ],
      },
    };
  }

  return {
    status: 'complete',
    usId: 'ALL',
  };
}

// v5.7 §4.11.a (refactored per code-review HIGH): single source-of-truth for
// the home rlp-desk dir and the autonomous claude command shape. Was duplicated
// across buildFlywheelTriggerCmd/buildGuardTriggerCmd byte-for-byte.
const HOME_DESK_DIR = path.join(os.homedir(), '.claude', 'ralph-desk');

function buildAutonomousClaudeCmd({ promptFile, model, rootDir, homeDeskDir = HOME_DESK_DIR }) {
  // v0.14.6: ANTHROPIC_BETA prefix injected only when the model id ends
  // with explicit '[1m]' suffix. opus / sonnet / claude-opus-4-7 (no
  // suffix) all run at the standard 200K context.
  const betaPrefix = wantsOneMillionContext(model)
    ? `ANTHROPIC_BETA=${shellQuote(ONE_MILLION_BETA)} `
    : '';
  // §4.11.a: --add-dir whitelist (home rlp-desk + campaign cwd) for true autonomy.
  const addDirParts = [];
  if (homeDeskDir) addDirParts.push(`--add-dir ${shellQuote(homeDeskDir)}`);
  if (rootDir) addDirParts.push(`--add-dir ${shellQuote(rootDir)}`);
  const addDir = addDirParts.length ? ' ' + addDirParts.join(' ') : '';
  return `cd ${JSON.stringify(rootDir)} && DISABLE_OMC=1 ${betaPrefix}claude --model ${shellQuote(model)} --no-mcp${addDir} -p "$(cat ${JSON.stringify(promptFile)})"`;
}

// Thin wrappers retained for call-site clarity + possible per-role customization.
function buildFlywheelTriggerCmd({ flywheelPromptFile, flywheelModel, rootDir, homeDeskDir }) {
  return buildAutonomousClaudeCmd({ promptFile: flywheelPromptFile, model: flywheelModel, rootDir, homeDeskDir });
}

function buildGuardTriggerCmd({ guardPromptFile, guardModel, rootDir, homeDeskDir }) {
  return buildAutonomousClaudeCmd({ promptFile: guardPromptFile, model: guardModel, rootDir, homeDeskDir });
}

async function dispatchFlywheel({ paths, sendKeys, flywheelPaneId, flywheelModel, rootDir }) {
  const triggerCmd = buildFlywheelTriggerCmd({
    flywheelPromptFile: paths.flywheelPromptFile,
    flywheelModel,
    rootDir,
  });
  await sendKeys(flywheelPaneId, triggerCmd);
}

async function dispatchGuard({ paths, sendKeys, guardPaneId, guardModel, rootDir }) {
  const triggerCmd = buildGuardTriggerCmd({
    guardPromptFile: paths.flywheelGuardPromptFile,
    guardModel,
    rootDir,
  });
  await sendKeys(guardPaneId, triggerCmd);
}

export function shouldRunFlywheel(flywheelMode, state) {
  if (flywheelMode === 'off') return false;
  if (flywheelMode === 'on-fail' && (state.consecutive_failures ?? 0) > 0) return true;
  return false;
}

export function shouldRunGuard(flywheelGuard, state, usId) {
  if (flywheelGuard !== 'on') return false;
  const count = (state.flywheel_guard_count ?? {})[usId] ?? 0;
  if (count >= 3) return false;
  return true;
}

// v0.14.0: production --mode tmux is routed to the zsh runner by
// src/node/run.mjs (see runTmuxViaZsh). The Node leader below owns the
// --mode agent (LLM-driven) flow. In-tree tests still exercise this path
// with `mode: 'tmux'` as a label while injecting fake
// createSession/sendKeys/pollForSignal — that is intentional and is NOT a
// regression of the routing contract.
export async function run(slug, options = {}) {
  const rootDir = path.resolve(options.rootDir ?? process.cwd());
  const env = options.env ?? process.env;

  // v0.13.0: refuse to run when legacy .claude/ralph-desk/ is present.
  // init mode auto-migrates; run mode protects in-flight campaigns and
  // surfaces a clear manual command to the operator.
  const legacy = detectLegacyDeskInRunMode(rootDir, env);
  if (legacy) {
    const err = new Error(legacy.message);
    err.code = 'LEGACY_DESK_DETECTED';
    throw err;
  }

  const paths = buildPaths(rootDir, slug, env);
  // v5.7 §4.24 §1g — runtime invariant: every terminal exit of run() MUST
  // leave exactly one sentinel on disk (blocked.md XOR complete.md). The
  // try/finally below is the last-resort backstop that writes a synthetic
  // BLOCKED if the body throws or returns without a terminal sentinel.
  // Idempotent via writeSentinelExclusive — a real BLOCKED already in place
  // is not overwritten.
  let runResult;
  let runThrew;
  try {
    runResult = await _runCampaignBody(slug, options, paths, rootDir);
    return runResult;
  } catch (error) {
    runThrew = error;
    throw error;
  } finally {
    await _ensureTerminalSentinel({
      paths,
      slug,
      result: runResult,
      threwError: runThrew,
    });
  }
}

async function _ensureTerminalSentinel({ paths, slug, result, threwError }) {
  // 'continue' is paused, not terminal. Real terminal: 'blocked' or 'complete'.
  // If neither sentinel exists at exit, leader exited unexpectedly. Write
  // synthetic BLOCKED `infra_failure/leader_exited_without_terminal_state`.
  if (result && result.status === 'continue') {
    return;
  }
  let blockedExists = false;
  let completeExists = false;
  try { blockedExists = await exists(paths.blockedSentinel); } catch {}
  try { completeExists = await exists(paths.completeSentinel); } catch {}
  if (blockedExists || completeExists) {
    return;
  }
  const reason = threwError
    ? `Leader exited unexpectedly (no terminal sentinel): ${threwError?.message ?? threwError}`
    : 'Leader exited without writing terminal sentinel';
  const classification = {
    slug,
    iteration: 0,
    reason_category: 'infra_failure',
    failure_category: 'leader_exited_without_terminal_state',
    recoverable: false,
    suggested_action: 'investigate_leader_logs',
  };
  try {
    await writeSentinel(
      paths.blockedSentinel,
      'blocked',
      'ALL',
      reason,
      classification,
      paths,
    );
  } catch (sentinelError) {
    // Best-effort. If even the backstop write fails, log to stderr so the
    // operator has SOME signal. Do NOT swallow the original error.
    console.error('[run] failed to write backstop BLOCKED sentinel:', sentinelError);
  }
}

async function _runCampaignBody(slug, options, paths, rootDir) {
  const sendKeys = options.sendKeys ?? defaultSendKeys;
  const createPane = options.createPane ?? defaultCreatePane;
  const createSession = options.createSession ?? defaultCreateSession;
  const pollForSignal = options.pollForSignal ?? defaultPollForSignal;
  // Bug #7 Fix-Q/R: post-sentinel reaper. Producer (claude/codex TUI) must be
  // interrupted the moment leader has consumed the sentinel; otherwise the
  // pane lingers in idle prompt and self-reviews for ~2min. lockSentinel
  // freezes the file mtime as defense-in-depth. All four are injectable so
  // existing tests with fake sendKeys keep working (us006 createTmuxFakes).
  const sendRawKey = options.sendRawKey ?? defaultSendRawKey;
  const waitForProcessExit = options.waitForProcessExit ?? defaultWaitForProcessExit;
  const killPaneProcess = options.killPaneProcess ?? defaultKillPaneProcess;
  const lockSentinel = options.lockSentinelFile ?? defaultLockSentinelFile;
  const stampAckField = options.stampAckField ?? defaultStampAckField;
  // v0.15.4 PR-B4: lifecycle observability collector. Tests inject
  // options.lifecycleMetrics for shape-contract verification; production
  // path constructs from process.env (always on since v0.22.4).
  const debugLogger = makeDebugLogger(paths.debugLogFile);
  const lifecycleMetrics = options.lifecycleMetrics ?? new LifecycleMetricsCollector({
    env: options.env ?? process.env,
    debugLog: (cat, fields) => debugLogger(cat, fields),
  });
  const reapProducer = async (paneId, sentinelFile, sentinelType = null) => {
    if (!paneId) return;
    // v0.15.4 PR-B4: pane_eof_to_cleanup_ms = wallclock from kill-start to
    // process-exit-confirmed (killPaneProcess + waitForProcessExit settle,
    // below — reapMs is computed AFTER both, not right after killPaneProcess
    // returns). pane_reap_latency_ms tracks the SAME window when the
    // trigger was a sentinel observation (i.e. sentinelType set) — not a
    // distinct window. codex round 3 R3-4: aligned with the corrected
    // README.md / lifecycle-metrics.mjs header wording (both previously
    // said "killPaneProcess return", which undersold this window too).
    const reapStart = Date.now();
    await killPaneProcess(paneId, {
      sendRawKey,
      waitForExit: waitForProcessExit,
      log: (msg) => console.error(msg),
    });
    // PR-0b-narrow AC-H1: after killPaneProcess, wait for the producing
    // process to actually exit before continuing. waitForProcessExit returns
    // when pane_current_command resolves to a shell (zsh/bash/sh). Wrapped
    // in try/catch — failure here is non-fatal but emits a log entry.
    try {
      await waitForProcessExit(paneId, { timeoutMs: 5000 });
    } catch (err) {
      console.error(`[handshake] waitForProcessExit failed on ${paneId} (${err?.message ?? err}); continuing`);
    }
    const reapMs = Date.now() - reapStart;
    lifecycleMetrics.record('pane_eof_to_cleanup_ms', reapMs, { pane_id: paneId });
    if (sentinelType) {
      lifecycleMetrics.record('pane_reap_latency_ms', reapMs, {
        pane_id: paneId,
        sentinel_type: sentinelType,
      });
    }
    if (sentinelFile) {
      // v0.15.4 audit H3 fix: markLockStart BEFORE lockSentinel so the
      // sentinel_lock_to_unlock_ms metric covers the full lock duration
      // including chmod 0o444 execution time. Previous code recorded
      // post-chmod timestamp — sub-ms skew but semantically inverted.
      // v0.15.4 PR-B4: open lock-to-unlock pair tracking. markUnlock fires
      // at unlockSentinelFile call sites or end-of-iter for never-unlocked.
      lifecycleMetrics.markLockStart(path.basename(sentinelFile));
      await lockSentinel(sentinelFile, { log: (msg) => console.error(msg) });
      // PR-0b-narrow AC-H2: stamp the leader_ack audit field. Best-effort,
      // does not block subsequent dispatch.
      await stampAckField(sentinelFile, {
        acked_by: 'leader',
        acked_at: new Date(resolveNow(options.now)).toISOString(),
        ack_pane_state: 'shell',
      }, { log: (msg) => console.error(msg) });
    }
  };
  // Bug #8 PR-B: working-tree probe injected (or default execFile git).
  // Returns { ok: boolean, dirty?: boolean, dirtyFiles?: string[], error?: string }.
  const checkWorkingTree = options.checkWorkingTree ?? _defaultCheckWorkingTree;
  // US-001: commit-integrity oracle probe (injected or default execFile git).
  // Returns { asserted, ok, reason, detail, claimedSha }.
  const checkCommitIntegrity = options.checkCommitIntegrity ?? _defaultCheckCommitIntegrity;
  const runIntegrationCheck = options.runIntegrationCheck ?? (async () => ({ exitCode: 0, summary: 'integration skipped' }));
  const maxIterations = options.maxIterations ?? 100;
  // v5.7 §4.19: campaign-level pollForSignal timeout (Node leader fix).
  // The CLI parses --iter-timeout but never forwarded it to pollForSignal,
  // so every campaign hit the 5s signal-poller default and exited
  // immediately. Default 600s (10 min) per CLI documentation; convert to ms.
  const iterTimeoutMs = ((options.iterTimeout ?? 600) * 1000);

  await ensureDirs(paths);
  await ensureScaffold(paths);
  await prepareCampaignAnalytics({
    analyticsFile: paths.analyticsFile,
    statusFile: paths.statusFile,
  });
  // P1-E Lane Enforcement: initialize audit log to `[]` so the file always
  // exists. Wrappers can then poll/tail without ENOENT special-cases.
  await _initLaneAuditLog(paths);

  if (await exists(paths.blockedSentinel)) {
    throw new Error(`Campaign ${slug} is blocked. Run clean first.`);
  }

  const state = await readCurrentState(paths, slug, options);
  const usList = await readUsList(paths, slug);

  if (usList.length === 0) {
    // D-5 (dogfood): both leaders parse only H2 `## US-NNN:`. A common mistake is
    // authoring `### US-NNN` (H3+), which yields zero stories. Surface an actionable
    // hint instead of a bare "not found" (the zsh leader silently degrades here;
    // Node fail-closes — the safer behavior, now recoverable via `clean`).
    let hint = '';
    try {
      const prdRaw = await fs.readFile(paths.prdFile, 'utf8');
      if (/^#{3,}\s+US-\d{3}\b/m.test(prdRaw)) {
        hint = ' — found US-NNN heading(s) at level ### or deeper; US headings must be H2 ("## US-NNN:")';
      }
    } catch { /* best-effort hint */ }
    throw new Error(`No user stories found for ${slug}${hint}`);
  }

  if (!state.current_us) {
    state.current_us = getNextUs(usList, state.verified_us, null);
  }

  // US-002 (AC2.5, AC2.6): load + validate campaign-scope waivers once at
  // campaign entry. FAIL CLOSED — honored only with an immutable, sha256-pinned
  // baseline artifact whose findings[] carries the finding_id, and only when the
  // out-of-band RLP_WAIVERS_SHA256 authorizes the file. Rejections are surfaced
  // loudly (symmetric with honored-id citation); only honored waivers are
  // injected into both prompts. The zsh production leader mirrors this in
  // load_campaign_waivers.
  const waiverEnv = options.env ?? process.env;
  const waiverResult = loadCampaignWaivers({
    waiversPath: paths.waiversFile,
    rootDir,
    runningSlug: slug,
    expectedSha256: waiverEnv.RLP_WAIVERS_SHA256 || null,
  });
  const honoredWaivers = waiverResult.honored;
  for (const rej of waiverResult.rejected) {
    console.error(`[waiver] REJECTED id=${rej.id ?? '(file)'} reason=${rej.reason} — ${rej.detail}`);
  }
  if (honoredWaivers.length > 0) {
    console.error(`[waiver] honored ${honoredWaivers.length} waiver(s): ${honoredWaivers.map((w) => w.id).join(', ')}`);
  }

  if (!state.session_name || !state.leader_pane_id) {
    const session = await createSession({
      sessionName: options.sessionName ?? `rlp-${slug}`,
      workingDir: rootDir,
      env: options.env ?? process.env,
    });
    state.session_name = session.sessionName;
    state.leader_pane_id = session.leaderPaneId;
    state.flywheel_pane_id = await createPane({
      targetPaneId: session.leaderPaneId,
      layout: 'horizontal',
    });
    state.worker_pane_id = await createPane({
      targetPaneId: session.leaderPaneId,
      layout: 'horizontal',
    });
    state.verifier_pane_id = await createPane({
      targetPaneId: session.leaderPaneId,
      layout: 'vertical',
    });
  }

  let fixContractPath = null;

  // US-001: campaign-preexisting tracked-dirty snapshot, captured ONCE before the
  // loop (mirrors zsh CAMPAIGN_PREEXISTING_DIRTY at run_ralph_desk.zsh). The
  // commit oracle excludes these so an operator's pre-existing uncommitted work is
  // never counted against a Worker's commit claim. Re-captured each process (not
  // persisted) — same behavior + D-25 caveat as the zsh snapshot.
  // GIT-FC (IMP-09) scope note: _gitTrackedDirtyWorkerFiles now THROWS on a git
  // error (the ORACLE path in _defaultCheckCommitIntegrity relies on that to emit
  // an infra result). This t0 CAPTURE keeps its prior lenient behavior (empty on
  // error) — fail-closing the Node capture site is IMP-05's durable-t0 work, not
  // IMP-09's oracle scope; over-tightening it here would half-implement IMP-05.
  const campaignPreexistingDirty = await _gitTrackedDirtyWorkerFiles(rootDir, []).catch(() => []);

  // PR-A (Bug #10): operator-recovery hygiene. If the operator hand-rolled a
  // `phase=verify` recovery (jq-patches status.json, writes manual artifacts,
  // deletes the blocked sentinel), the leader MUST honor that work instead of
  // resetting to phase=worker on relaunch. The validator runs five checks
  // (see _validateOperatorRecoveryArtifacts); on full pass, _skipNextWorkerDispatch
  // is set as a one-shot flag consumed at the worker dispatch call site below.
  // On any failure the leader logs the reason and falls through to default
  // behavior.
  if (state.phase === 'verify' && state.iteration > 0) {
    const validation = await _validateOperatorRecoveryArtifacts({ paths, state });
    if (validation.ok) {
      console.error(
        `[recovery] Resuming verify phase — operator manual recovery detected (us=${state.current_us} iter=${state.iteration}): ${validation.reason}`,
      );
      state._skipNextWorkerDispatch = true;
    } else {
      console.error(
        `[recovery] phase=verify ignored, falling through to worker dispatch: ${validation.reason}`,
      );
    }
  }

  // PR-E (Phase C1, stabilization): operator-cleared BLOCKED recovery.
  // Pair to PR-A above. PR-E runs AFTER PR-A so phase=verify takes precedence
  // when both apply (defensive ordering: never auto-recover phase=blocked if
  // the operator's actual intent was phase=verify hygiene). Does NOT use
  // _skipNextWorkerDispatch — counters reset is enough; worker dispatches
  // normally on the next iteration with a clean state.
  if (state.phase === 'blocked' && !state._skipNextWorkerDispatch) {
    const validation = await _validateBlockedRecovery({ paths, state });
    if (validation.ok) {
      const previousReason = state.last_block_reason ?? '';
      console.error(
        `[recovery] Operator-cleared BLOCKED detected (was: ${previousReason || 'unrecorded'}). Resetting counters and resuming as worker. iter=${state.iteration} us_id=${state.current_us}: ${validation.reason}`,
      );
      state.phase = 'worker';
      state.consecutive_failures = 0;
      state.escalation_eligible_failures = 0;
      state.consecutive_blocks = 0;
      state.last_block_reason = '';
      // Archive sidecar (rename, not delete) so operator can audit the
      // recovered-from state. Best-effort.
      await _archiveRecoveredSidecar(paths);
    } else {
      console.error(
        `[recovery] phase=blocked ignored, falling through to existing behavior: ${validation.reason}`,
      );
    }
  }

  // P1-E Lane Enforcement: snapshot lane mtimes before each iteration,
  // compare at the top of the next iteration. Drift on read-only artifacts
  // (PRD, test-spec, context) emits a lane_violation_warning event + audit
  // log entry. governance §7e. Strict mode escalation hook is wired below
  // (sentinel BLOCKED with infra_failure + recoverable=true downgrade).
  let _laneSnapshot = await _snapshotLaneMtimes(paths);

  while (state.iteration <= maxIterations) {
    // Bug #7 Fix-R defensive unlock: a 0o444 sentinel left from the previous
    // iteration must not block the next producer's atomic-rename write.
    // Idempotent: missing-file calls are no-ops.
    await unlockSentinelFile(paths.signalFile);
    lifecycleMetrics.markUnlock(path.basename(paths.signalFile), { iter: state.iteration });
    await unlockSentinelFile(paths.verdictFile);
    lifecycleMetrics.markUnlock(path.basename(paths.verdictFile), { iter: state.iteration });
    // Audit drift from the prior iteration before doing anything new.
    const _laneSnapshotAfter = await _snapshotLaneMtimes(paths);
    const _laneViolations = await _checkLaneViolations(paths, _laneSnapshot, _laneSnapshotAfter, state, options);
    if (_laneViolations) {
      for (const v of _laneViolations) {
        // C2: this fires at the loop TOP, before this iteration's worker
        // prompt/done-claim/verdict exist — not a real worker dispatch, so
        // it must not carry a byte-based token estimate (see the guard
        // comment on appendIterationAnalytics above).
        await appendIterationAnalytics(paths, state, state.current_us ?? 'ALL', 'lane_violation_warning', { ...options, lane_violation: v }, lifecycleMetrics, false);
      }
      if (options.laneStrict) {
        // Strict mode: escalate to BLOCKED with downgrade
        // (recoverable=true, retry_after_fix). governance §7e justifies
        // the downgrade — the mtime audit is best-effort and should not
        // terminally kill a campaign.
        state.phase = 'blocked';
        const laneReason = `lane_violation: ${_laneViolations.length} read-only artifact(s) modified during prior iteration`;
        const laneClassification = {
          reason_category: 'infra_failure',
          failure_category: null,
          recoverable: true,
          suggested_action: 'retry_after_fix',
          iteration: state.iteration,
          slug,
        };
        await writeSentinel(paths.blockedSentinel, 'blocked', state.current_us ?? 'ALL', laneReason, laneClassification, paths);
        await writeStatus(paths, state, options.onStatusChange, options.now);
        return {
          status: 'blocked',
          usId: state.current_us ?? 'ALL',
          reason: laneReason,
          category: 'infra_failure',
          statusFile: paths.statusFile,
        };
      }
    }
    _laneSnapshot = _laneSnapshotAfter;

    state.current_us = getNextUs(usList, state.verified_us, state.current_us);
    if (state.current_us === 'ALL') {
      let finalResult;
      try {
        finalResult = await runFinalSequentialVerify({
          paths,
          state,
          usList,
          sendKeys,
          verifierPaneId: state.verifier_pane_id,
          pollForSignal,
          runIntegrationCheck,
          iterTimeoutMs,
          reapProducer,
          honoredWaivers,
        });
      } catch (error) {
        // v5.7 §4.25 — uniform poll-failure handling for final verifier.
        return _handlePollFailure(error, {
          paths, state, slug, options,
          role: 'final_verifier',
          usIdOverride: 'ALL',
        });
      }

      if (finalResult.status === 'complete') {
        state.phase = 'complete';
        await writeSentinel(paths.completeSentinel, 'complete', 'ALL');
        await writeStatus(paths, state, options.onStatusChange, options.now);
        let svSummary;
        if (options.withSelfVerification) {
          try {
            const sv = await generateSVReport({
              slug,
              logsDir: path.dirname(paths.reportFile),
              prdFile: paths.prdFile,
              testSpecFile: paths.testSpecFile,
              analyticsFile: paths.analyticsFile,
              outputDir: paths.analyticsDir,
            });
            svSummary = sv.summary;
          } catch (err) {
            svSummary = `SV report generation failed: ${err.message}`;
          }
        }
        await generateCampaignReport({
          slug,
          reportFile: paths.reportFile,
          prdFile: paths.prdFile,
          statusFile: paths.statusFile,
          analyticsFile: paths.analyticsFile,
          now: resolveNow(options.now),
          svSummary,
        });
        return {
          status: 'complete',
          usId: 'ALL',
          statusFile: paths.statusFile,
        };
      }

      state.phase = 'worker';
      state.current_us = finalResult.usId;
      fixContractPath = path.join(paths.campaignLogDir, `iter-${String(state.iteration).padStart(3, '0')}.fix-contract.md`);
      await writePromptFile(fixContractPath, buildFixContract(finalResult.verdict));
      await writeStatus(paths, state, options.onStatusChange, options.now);
      return {
        status: 'continue',
        usId: finalResult.usId,
        statusFile: paths.statusFile,
      };
    }

    // Flywheel direction review (runs BEFORE Worker)
    if (shouldRunFlywheel(options.flywheel ?? 'off', state)) {
      state.phase = 'flywheel';
      await writeStatus(paths, state, options.onStatusChange, options.now);

      await dispatchFlywheel({
        paths,
        sendKeys,
        flywheelPaneId: state.flywheel_pane_id ?? state.verifier_pane_id,
        flywheelModel: options.flywheelModel ?? 'opus',
        rootDir,
      });

      let flywheelSignal;
      try {
        flywheelSignal = await pollForSignal(paths.flywheelSignalFile, {
          mode: 'claude',
          paneId: state.flywheel_pane_id ?? state.verifier_pane_id,
          timeoutMs: iterTimeoutMs,
        });
        validateArtifact(flywheelSignal, {
          expectedSlug: slug,
          iterationFloor: state.iteration,
          expectedSignalType: 'flywheel_signal',
          allowedUsIds: [...usList, 'ALL'],
        });
      } catch (error) {
        return _handlePollFailure(error, {
          paths, state, slug, options,
          role: 'flywheel',
        });
      }

      // Bug #7 Fix-Q/R: reap flywheel pane before consuming the signal.
      await reapProducer(state.flywheel_pane_id ?? state.verifier_pane_id, paths.flywheelSignalFile, 'flywheel-signal');

      state.last_flywheel_decision = flywheelSignal.decision;
      // P0-A multi-mission orchestration: optionally captured from flywheel signal.
      // null when the flywheel did not suggest a next mission. Consumer wrappers
      // poll status.next_mission_candidate to chain missions without code edits.
      // See docs/rlp-desk/multi-mission-orchestration.md.
      state.next_mission_candidate = flywheelSignal.next_mission_candidate ?? null;
      // Bug #7 Fix-R cleanup: unlock before unlink so 0o444 doesn't block.
      await unlockSentinelFile(paths.flywheelSignalFile);
      await fs.unlink(paths.flywheelSignalFile).catch(() => {});

      // Flywheel Guard (independent validation of flywheel decision)
      if (shouldRunGuard(options.flywheelGuard ?? 'off', state, state.current_us)) {
        state.phase = 'guard';
        await writeStatus(paths, state, options.onStatusChange, options.now);

        const guardPaneId = state.flywheel_pane_id ?? state.verifier_pane_id;
        const guardModel = options.flywheelGuardModel ?? 'opus';

        await dispatchGuard({ paths, sendKeys, guardPaneId, guardModel, rootDir });

        let guardVerdict;
        try {
          guardVerdict = await pollForSignal(paths.flywheelGuardVerdictFile, {
            mode: 'claude',
            paneId: guardPaneId,
            timeoutMs: iterTimeoutMs,
          });
          validateArtifact(guardVerdict, {
            expectedSlug: slug,
            iterationFloor: state.iteration,
            expectedSignalType: 'flywheel_guard_verdict',
            allowedUsIds: [...usList, 'ALL'],
          });
        } catch (error) {
          return _handlePollFailure(error, {
            paths, state, slug, options,
            role: 'guard',
          });
        }

        // Bug #7 Fix-Q/R: reap guard pane before mutating state.
        await reapProducer(guardPaneId, paths.flywheelGuardVerdictFile, 'flywheel-guard-verdict');

        if (!state.flywheel_guard_count[state.current_us]) {
          state.flywheel_guard_count[state.current_us] = 0;
        }
        state.flywheel_guard_count[state.current_us] += 1;

        await unlockSentinelFile(paths.flywheelGuardVerdictFile);
        await fs.unlink(paths.flywheelGuardVerdictFile).catch(() => {});

        if (guardVerdict.verdict === 'inconclusive') {
          state.phase = 'blocked';
          const guardReason = 'flywheel-guard-escalate-inconclusive';
          await writeSentinel(paths.blockedSentinel, 'blocked', state.current_us, guardReason, _classifyBlock('flywheel_inconclusive', { state, slug }), paths);
          await writeStatus(paths, state, options.onStatusChange, options.now);
          // governance §1f three-channel: sentinel + report + return value all
          // carry the same blocked reason. SV is intentionally not generated
          // here because the guard fires before the iteration runs to
          // completion; the campaign report uses the default SV message.
          await generateCampaignReport({
            slug,
            reportFile: paths.reportFile,
            prdFile: paths.prdFile,
            statusFile: paths.statusFile,
            analyticsFile: paths.analyticsFile,
            now: resolveNow(options.now),
            blockedReason: guardReason,
            blockedCategory: 'mission_abort',
          });
          return {
            status: 'blocked',
            usId: state.current_us,
            reason: guardReason,
            category: 'mission_abort',
            guardIssues: guardVerdict.issues,
            statusFile: paths.statusFile,
          };
        }

        if (guardVerdict.verdict === 'fail') {
          if (state.flywheel_guard_count[state.current_us] >= 3) {
            state.phase = 'blocked';
            const exhaustReason = 'flywheel-guard-retries-exhausted';
            await writeSentinel(paths.blockedSentinel, 'blocked', state.current_us, exhaustReason, _classifyBlock('flywheel_exhausted', { state, slug }), paths);
            await writeStatus(paths, state, options.onStatusChange, options.now);
            // governance §1f three-channel: see comment above.
            await generateCampaignReport({
              slug,
              reportFile: paths.reportFile,
              prdFile: paths.prdFile,
              statusFile: paths.statusFile,
              analyticsFile: paths.analyticsFile,
              now: resolveNow(options.now),
              blockedReason: exhaustReason,
              blockedCategory: 'mission_abort',
            });
            return {
              status: 'blocked',
              usId: state.current_us,
              reason: exhaustReason,
              category: 'mission_abort',
              guardIssues: guardVerdict.issues,
              statusFile: paths.statusFile,
            };
          }
          // Retry: skip Worker, continue to next iteration (flywheel will re-run)
          state.phase = 'worker';
          await writeStatus(paths, state, options.onStatusChange, options.now);
          state.iteration += 1;
          continue;
        }

        // verdict === 'pass'
        if (guardVerdict.analysis_only) {
          state.phase = 'worker';
          await writeStatus(paths, state, options.onStatusChange, options.now);
          state.iteration += 1;
          continue;
        }
      }

      // Reset guard count on pass (flywheel direction accepted)
      if (state.flywheel_guard_count[state.current_us]) {
        state.flywheel_guard_count[state.current_us] = 0;
      }
    }

    // PR-A (Bug #10): one-shot guard. When the operator's `phase=verify`
    // recovery was honored at campaign entry, skip both the phase reset and
    // the worker dispatch — the operator already wrote a valid iter-signal.json
    // and done-claim.json, so pollForSignal below will pick them up immediately
    // and the loop continues into the verifier phase. The flag is cleared
    // after consumption so subsequent iterations dispatch the worker normally.
    let iterationStartMs;
    let iterationDurationSeconds = 0;
    if (state._skipNextWorkerDispatch) {
      state._skipNextWorkerDispatch = false;
      iterationStartMs = Date.now();
      console.error(
        `[recovery] Skipping worker dispatch for iter=${state.iteration} (honoring operator manual recovery)`,
      );
      // Persist phase=verify so a subsequent crash-and-relaunch sees the same
      // contract. writeStatus is intentionally called BEFORE pollForSignal so
      // the on-disk state matches what we are about to do.
      state.phase = 'verify';
      await writeStatus(paths, state, options.onStatusChange, options.now);
    } else {
      state.phase = 'worker';
      // US-001 AC1.3: per-iteration HEAD snapshot, captured ONLY when a worker is
      // dispatched (recovery/finalize iterations reuse the restored snapshot,
      // mirroring the zsh leader). '' on a fresh repo — the oracle treats the
      // first commit as an advance. Persisted by the writeStatus below.
      state.iter_start_head = await _gitHeadSha(rootDir);
      await writeStatus(paths, state, options.onStatusChange, options.now);
      iterationStartMs = Date.now();
      await dispatchWorker({
        iteration: state.iteration,
        paths,
        slug,
        usList,
        state,
        sendKeys,
        workerPaneId: state.worker_pane_id,
        fixContractPath,
        honoredWaivers,
      });
    }

    let signal;
    try {
      signal = await pollForSignal(paths.signalFile, {
        mode: parseModelFlag(state.worker_model).engine,
        paneId: state.worker_pane_id,
        timeoutMs: effectiveIterTimeoutMs(iterTimeoutMs, state.worker_model),
      });
      validateArtifact(signal, {
        expectedSlug: slug,
        iterationFloor: state.iteration,
        expectedSignalType: 'signal',
        allowedUsIds: [...usList, 'ALL'],
      });
    } catch (error) {
      if (error instanceof TimeoutError && parseModelFlag(state.worker_model).engine === 'codex') {
        // Bug #8 PR-B 4-way gate: refuse to synthesize verify signal when
        // codex worker exited without committing real work.
        //   1. done-claim absent          → BLOCKED infra_failure
        //   2. git unverifiable           → BLOCKED infra_failure
        //   3. done-claim + dirty tree    → BLOCKED metric_failure
        //   4. done-claim + clean tree    → synthesize verify (legacy path)
        const doneClaimExists = await exists(paths.doneClaimFile);
        if (!doneClaimExists) {
          return _handlePollFailure(error, {
            paths, state, slug, options,
            role: 'worker',
            categoryOverride: BLOCK_TAGS.CODEX_EXIT_NO_DONE_CLAIM,
            reasonOverride:
              'codex worker exited (timeout) without writing done-claim; refusing to synthesize verify signal',
          });
        }
        const tree = await checkWorkingTree(rootDir);
        if (!tree.ok) {
          return _handlePollFailure(error, {
            paths, state, slug, options,
            role: 'worker',
            categoryOverride: BLOCK_TAGS.GIT_STATE_UNVERIFIABLE,
            reasonOverride:
              `git status unverifiable (${tree.error ?? 'unknown'}); refusing to synthesize verify signal`,
          });
        }
        if (tree.dirty) {
          const sample = (tree.dirtyFiles ?? []).slice(0, 5).join(', ');
          return _handlePollFailure(error, {
            paths, state, slug, options,
            role: 'worker',
            categoryOverride: BLOCK_TAGS.WORKER_INCOMPLETE_UNCOMMITTED,
            reasonOverride:
              `worker_incomplete_uncommitted: done-claim present but tree dirty (${sample || 'no file list'})`,
          });
        }
        // Clean tree — preserve the legacy synthesize behaviour.
        signal = {
          iteration: state.iteration,
          status: 'verify',
          us_id: state.current_us,
          summary: 'auto-generated after codex exit fallback',
        };
      } else {
        // v5.7 §4.25 — uniform handling for WorkerExitedError, PromptBlockedError,
        // MalformedArtifactError, TimeoutError, and unknown errors.
        return _handlePollFailure(error, {
          paths, state, slug, options,
          role: 'worker',
        });
      }
    }

    // v0.15.4 PR-B4: iter_signal_write_to_read_ms = wallclock from worker FS
    // write to leader poll resolve. Sentinel mtime is the producer-side anchor;
    // Date.now() is the leader-side anchor. Best-effort stat — if the file
    // already lacks read perms (race vs prior lock), fall back to skip.
    try {
      const sigStat = fsSync.statSync(paths.signalFile);
      lifecycleMetrics.record('iter_signal_write_to_read_ms', Date.now() - sigStat.mtimeMs, {
        iter: state.iteration,
        us_id: state.current_us,
      });
    } catch { /* fail-open: skip on stat error */ }
    // Bug #7 Fix-Q/R: reap the worker pane the instant we accept the signal so
    // claude/codex cannot self-review and rewrite iter-signal.json. Runs even
    // for the codex-fallback synthesized signal (no-op on a dead pane).
    await reapProducer(state.worker_pane_id, paths.signalFile, 'iter-signal');
    // v0.15.4 PR-B2-FIX: same worker pass produced done-claim. The pane is
    // already reaped above; lock done-claim so the iter-NNN-done-claim archive
    // and any post-iter Bug #8 gate read a snapshot the worker can no longer
    // revise. Symmetric with the zsh lock-on-iter-signal contract at
    // run_ralph_desk.zsh:3197. Best-effort: missing-file is fail-open.
    //
    // IMP-10 (closes v0.15.4 audit H2): done-claim is still never
    // unlockSentinelFile'd on the happy path (only signalFile + verdictFile
    // receive iter-start unlockSentinelFile at L1552-1555), but its
    // per-iteration close-out (immediately BEFORE appendIterationAnalytics,
    // in both the 'pass' and 'fail' verdict branches below — MUST precede it
    // since that call flushes the collector; a markUnlock placed after the
    // flush is silently orphaned on a COMPLETE-exit iteration) now calls
    // markUnlock with `{ ctx: 'archival' }` — mirroring the zsh leader's
    // archive_iter_artifacts unlock site — so the metric emits a
    // lock->close-out duration instead of never firing.
    lifecycleMetrics.markLockStart(path.basename(paths.doneClaimFile));
    await lockSentinel(paths.doneClaimFile, { log: (msg) => console.error(msg) });

    // US-001: leader-side done-claim commit-integrity oracle. Runs on the shared
    // post-done-claim-lock path (covers the normal, codex-fallback synth, and
    // operator-recovery signals — all converge here) BEFORE any verifier dispatch.
    // Fires ONLY when the done-claim asserts a successful commit; a no-commit
    // claim (verify_existing/confirmation) or a corroborated claim is a silent
    // no-op. On mismatch it routes to the fix loop (Principle 4) with a
    // machine-generated fix contract via the US-003 normalizer — NOT a verifier
    // finding. (zsh parity note: the zsh production leader uses a distinct ORACLE
    // counter + force-verifier-at-cap because it has the two-layer pre-gate to
    // defer to; the Node oracle has no pre-gate, so it drives the existing
    // consecutive-failure CB directly — same predicate, same "CB owns terminal
    // escalation" intent.)
    {
      const oracleDoneClaim = await readJsonIfExists(paths.doneClaimFile);
      const oracleResult = await checkCommitIntegrity(rootDir, {
        doneClaim: oracleDoneClaim,
        iterStartHead: state.iter_start_head ?? '',
        preexistingDirty: campaignPreexistingDirty,
      });
      if (oracleResult.infra === true) {
        // GIT-FC (IMP-09): a git error is infra, not a worker lie — an error can
        // never corroborate a commit claim. Force a full verifier round (fall
        // through) WITHOUT bumping consecutive_failures and never BLOCK from here.
        console.error(
          `[GIT-FC] commit-integrity oracle could not read git facts (${oracleResult.reason}) — forcing a full verifier round (no failure bump)`,
        );
      } else if (oracleResult.asserted && !oracleResult.ok) {
        const oracleUsId = signal.us_id ?? state.current_us;
        console.error(
          `[oracle] commit-integrity FAILED (${oracleResult.reason}) — skipping verification, redispatching Worker`,
        );
        // G3: branch the contract. Telling a worker that fabricated an EMPTY
        // commit to "actually create the commit" would instruct it to fabricate
        // another one; the fix is to drop it. Parity with the zsh
        // _oracle_register_fail Next Iteration Contract branch.
        const oracleFixHint = String(oracleResult.reason ?? '').includes('empty_commit_on_confirmation_claim')
          ? 'Drop the empty commit (git reset --soft HEAD^ — its tree is identical to its parent, so nothing is lost) and do NOT create another commit to compensate. If this iteration produced no file changes, do not claim a commit step at all: report the verification result without a commit assertion. Scope Lock: only the empty commit and the done-claim commit assertion are in scope.'
          : 'Actually create the commit (git add + git commit) so HEAD advances and the tracked tree is clean, and record the resulting commit SHA in your done-claim commit step (commit_sha). Scope Lock: only changes that make the commit real are in scope.';
        const oracleVerdict = {
          verdict: 'fail',
          summary: `Leader commit-integrity oracle: ${oracleResult.reason}`,
          issues: [{
            id: 'COMMIT-INTEGRITY',
            severity: 'critical',
            description: oracleResult.detail,
            fix_hint: oracleFixHint,
          }],
        };
        // Luna-first spec §2.5 (same dual counter as the verifier-fail path
        // below): an environment/flaky-classified oracle verdict must neither
        // climb the ladder nor advance the rung arithmetic.
        const oracleLadderEligible = recordFailureCounters(state, oracleVerdict);
        iterationDurationSeconds = Math.max(0, Math.floor((Date.now() - iterationStartMs) / 1000));
        await appendIterationAnalytics(paths, state, oracleUsId, 'fail', options, lifecycleMetrics, true, iterationDurationSeconds);
        // BLOCKED-on-exhaustion stays on consecutive_failures (unchanged).
        const oracleUpgradedModel = nextWorkerModel(options.workerModel ?? state.worker_model, state.consecutive_failures);
        if (oracleUpgradedModel === 'BLOCKED') {
          state.phase = 'blocked';
          const oracleBlockReason = `commit-integrity-oracle-exhausted (${oracleResult.reason}, consecutive_failures=${state.consecutive_failures})`;
          await writeSentinel(paths.blockedSentinel, 'blocked', oracleUsId, oracleBlockReason, _classifyBlock('model_upgrade', { state, slug }), paths);
          await writeStatus(paths, state, options.onStatusChange, options.now);
          await generateCampaignReport({
            slug,
            reportFile: paths.reportFile,
            prdFile: paths.prdFile,
            statusFile: paths.statusFile,
            analyticsFile: paths.analyticsFile,
            now: resolveNow(options.now),
            blockedReason: oracleBlockReason,
            blockedCategory: 'repeat_axis',
          });
          return { status: 'blocked', usId: oracleUsId, reason: oracleBlockReason, category: 'repeat_axis', statusFile: paths.statusFile };
        }
        if (oracleLadderEligible) {
          // Rung walked from the ELIGIBLE counter — see the verifier-fail path.
          const oracleLadderModel = nextWorkerModel(
            options.workerModel ?? state.worker_model,
            state.escalation_eligible_failures,
          );
          if (oracleLadderModel !== 'BLOCKED') {
            state.worker_model = oracleLadderModel;
          }
        } else {
          await debugLogger('DECIDE', {
            iter: state.iteration,
            phase: 'model_select',
            model_upgrade: false,
            reason: `failure_category_${verdictFailureCategory(oracleVerdict)}`,
          });
        }
        state.current_us = oracleUsId;
        fixContractPath = path.join(paths.campaignLogDir, `iter-${String(state.iteration).padStart(3, '0')}.fix-contract.md`);
        await writePromptFile(fixContractPath, buildFixContract(oracleVerdict));
        state.phase = 'worker';
        await writeStatus(paths, state, options.onStatusChange, options.now);
        state.iteration += 1;
        continue;
      }
    }

    // Layer 1.5 (request-h): done-claim TDD-sequence lint. Deterministic per-AC
    // write_test→verify_red→implement→verify_green label/order check of the
    // done-claim, AFTER the commit-integrity oracle and BEFORE the LLM verifier
    // is dispatched (governance §3a Layer 1.5). A pure-format defect is bounced
    // back to the Worker with per-AC idx coordinates instead of burning a full
    // LLM cross-verification round. Node parity with the zsh leader's
    // run_pregate_doneclaim_lint. The lint has its OWN per-US fail counter
    // (shared PREGATE_FAIL_CAP semantics, default 3) and NEVER touches
    // consecutive_failures — pre-gates do not drive the circuit breaker
    // (governance §1f / the zsh _pregate_bump design). The outcome line is
    // injected into the verifier prompt so the Worker Process Audit does not
    // re-litigate a format the leader already machine-verified.
    let pregateLintLine = '';
    {
      const lintUsId = signal.us_id ?? state.current_us;
      const lintEnv = options.env ?? process.env;
      const capParsed = Number.parseInt(lintEnv.PREGATE_FAIL_CAP, 10);
      const lintCap = capParsed > 0 ? capParsed : 3;
      const lintDoneClaim = await readJsonIfExists(paths.doneClaimFile);
      const lintResult = lintDoneClaimTddSequence(lintDoneClaim, { env: lintEnv });
      if (lintResult.status === 'fail') {
        // Reset the per-US streak when the in-flight US changes (mirror _pregate_bump).
        if (state.pregate_lint_us !== lintUsId) {
          state.pregate_lint_failures = 0;
          state.pregate_lint_us = lintUsId;
        }
        state.pregate_lint_failures += 1;
        if (state.pregate_lint_failures < lintCap) {
          // Under cap: short-circuit — skip verification, redispatch the Worker
          // with a coordinate-bearing fix contract. Does NOT bump consecutive_failures.
          const violationsJson = JSON.stringify(lintResult.violations);
          console.error(
            `[pregate] done-claim format lint FAILED (${violationsJson}) — skipping verification, redispatching Worker (pregate lint fail ${state.pregate_lint_failures}/${lintCap})`,
          );
          fixContractPath = path.join(
            paths.campaignLogDir,
            `iter-${String(state.iteration).padStart(3, '0')}.fix-contract.md`,
          );
          await writePromptFile(
            fixContractPath,
            buildDoneClaimLintFixContract(state.iteration, lintResult.violations),
          );
          state.current_us = lintUsId;
          state.phase = 'worker';
          await writeStatus(paths, state, options.onStatusChange, options.now);
          state.iteration += 1;
          continue;
        }
        // At/over cap: do NOT short-circuit. Force one full LLM verifier round,
        // carrying the FAIL summary for prompt injection. Reset the streak.
        state.pregate_lint_failures = 0;
        state.pregate_lint_us = null;
        console.error(
          `[pregate] done-claim format lint failed ${lintCap}× for ${lintUsId ?? 'ALL'} — forcing full LLM verifier round (lint FAIL passed to verifier)`,
        );
        pregateLintLine = `Done-Claim Format Lint: FAIL (fail cap reached) — violations: ${JSON.stringify(lintResult.violations)}`;
      } else {
        // pass/skip → proceed; reset the streak and inject the outcome.
        state.pregate_lint_failures = 0;
        state.pregate_lint_us = null;
        if (lintResult.status === 'pass') {
          pregateLintLine = 'Done-Claim Format Lint: PASS — the leader machine-verified the per-AC TDD step sequence/labels in execution_steps. Do NOT fail the Worker Process Audit on step sequence/label format grounds; audit substance only (evidence freshness, exit codes, timestamps, command truthfulness).';
        } else {
          pregateLintLine = `Done-Claim Format Lint: SKIPPED (${lintResult.reason ?? 'unknown'})`;
        }
      }
    }

    // US-019 R7 P1-G: verify_partial malformed downgrade.
    // verify_partial requires verified_acs[] to be a non-empty array. Otherwise the verifier
    // has nothing to evaluate and we must treat the signal as broken contract → blocked.
    if (signal && signal.status === 'verify_partial') {
      const acs = Array.isArray(signal.verified_acs) ? signal.verified_acs : null;
      if (!acs || acs.length === 0) {
        const malformedUs = signal.us_id ?? state.current_us;
        const malformedClassification = {
          reason_category: 'mission_abort',
          recoverable: true,
          suggested_action: 'retry_after_fix',
          failure_category: 'spec',
        };
        await writeSentinel(paths.blockedSentinel, 'blocked', malformedUs, 'verify_partial_malformed', malformedClassification, paths);
        return { status: 'blocked', usId: malformedUs, reason: 'verify_partial_malformed', category: 'mission_abort' };
      }
    }

    const usId = signal.us_id ?? state.current_us;
    const verifierModel = deriveVerifierModel(usId, options);
    state.phase = 'verifier';
    state.verifier_model = options.verifierModel ?? 'sonnet';
    state.final_verifier_model = options.finalVerifierModel ?? 'opus';
    await writeStatus(paths, state, options.onStatusChange, options.now);
    // R3-2: clear any stale verdict (prior iteration / skipped loop-top cleanup)
    // before launch so the poll below waits for THIS verifier's fresh verdict.
    // Clear BOTH canonical and legacy — the poll below passes legacyVerdictFile
    // as a no-freshness-gate fallback.
    await clearStaleVerdict(paths.verdictFile, paths.legacyVerdictFile);
    await dispatchVerifier({
      iteration: state.iteration,
      paths,
      state,
      usId,
      sendKeys,
      verifierPaneId: state.verifier_pane_id,
      verifierModel,
      honoredWaivers,
      doneClaimLint: pregateLintLine,
    });

    let verdict;
    try {
      verdict = await pollForSignal(paths.verdictFile, {
        mode: parseModelFlag(verifierModel, 'verifier').engine,
        paneId: state.verifier_pane_id,
        timeoutMs: iterTimeoutMs,
        // v0.14.2 Fix-D: codex sometimes writes the verdict at the legacy
        // .claude/ralph-desk/memos/ path. signal-poller's last-chance read
        // tries this fallback before timing out.
        legacySignalFile: paths.legacyVerdictFile,
      });
      // v0.14.2 Fix-D continued: if the verdict came from the legacy path,
      // migrate it into the canonical location so the rest of the pipeline
      // (analytics archival, sentinels, status) sees a single canonical
      // file. Best-effort — any rename failure is logged but does not
      // re-throw because we already have the parsed verdict in memory.
      if (await _verdictMigrationNeeded(paths)) {
        await _migrateLegacyVerdict(paths).catch((migrateErr) => {
          console.error('[v0.14.2] legacy verdict migration failed:', migrateErr?.message ?? migrateErr);
        });
      }
      validateArtifact(verdict, {
        expectedSlug: slug,
        iterationFloor: state.iteration,
        expectedSignalType: 'verdict',
        allowedUsIds: [...usList, 'ALL'],
      });
    } catch (error) {
      return _handlePollFailure(error, {
        paths, state, slug, options,
        role: 'verifier',
        usIdOverride: usId,
      });
    }

    iterationDurationSeconds = Math.max(0, Math.floor((Date.now() - iterationStartMs) / 1000));

    // v0.15.4 PR-B4: verdict_write_to_read_ms parallel to iter_signal metric.
    try {
      const verdStat = fsSync.statSync(paths.verdictFile);
      lifecycleMetrics.record('verdict_write_to_read_ms', Date.now() - verdStat.mtimeMs, {
        iter: state.iteration,
        us_id: state.current_us,
      });
    } catch { /* fail-open */ }
    // Bug #7 Fix-Q/R: reap verifier pane immediately after accepting the
    // verdict — without this the codex/claude TUI keeps running for ~2min and
    // can rewrite verify-verdict.json (mtime drift observed in 19th launch).
    await reapProducer(state.verifier_pane_id, paths.verdictFile, 'verify-verdict');

    if (verdict.verdict === 'pass') {
      state.consecutive_failures = 0;
      state.escalation_eligible_failures = 0;
      if (!state.verified_us.includes(usId)) {
        state.verified_us.push(usId);
      }
      state.current_us = getNextUs(usList, state.verified_us, null);
      fixContractPath = null;
      // IMP-10: per-iteration close-out for the done-claim lock marked above
      // (mirrors zsh's unconditional archive_iter_artifacts call) — covers
      // both the "more US remain" and "all US verified" continue paths. MUST
      // fire BEFORE appendIterationAnalytics, which calls
      // lifecycleMetrics.flush() internally — a markUnlock call placed after
      // the flush is orphaned in the collector's buffer and silently lost on
      // a COMPLETE-exit iteration (no later flush to catch it).
      lifecycleMetrics.markUnlock(path.basename(paths.doneClaimFile), { ctx: 'archival', iter: state.iteration });
      await appendIterationAnalytics(paths, state, usId, 'pass', options, lifecycleMetrics, true, iterationDurationSeconds);
      await writeStatus(paths, state, options.onStatusChange, options.now);

      if (state.verified_us.length === usList.length) {
        continue;
      }

      state.iteration += 1;
      continue;
    }

    if (verdict.verdict === 'blocked') {
      state.phase = 'blocked';
      const blockedReason = verdict.reason || verdict.summary || 'verifier-blocked';
      const blockedClassification = _classifyBlock('verifier', { verdict, state, slug });
      await writeSentinel(paths.blockedSentinel, 'blocked', usId, blockedReason, blockedClassification, paths);
      await appendIterationAnalytics(paths, state, usId, 'blocked', options, lifecycleMetrics, true, iterationDurationSeconds);
      await writeStatus(paths, state, options.onStatusChange, options.now);
      let svSummary;
      if (options.withSelfVerification) {
        try {
          const sv = await generateSVReport({
            slug,
            logsDir: path.dirname(paths.reportFile),
            prdFile: paths.prdFile,
            testSpecFile: paths.testSpecFile,
            analyticsFile: paths.analyticsFile,
            outputDir: paths.analyticsDir,
          });
          svSummary = sv.summary;
        } catch (err) {
          svSummary = `SV report generation failed: ${err.message}`;
        }
      }
      await generateCampaignReport({
        slug,
        reportFile: paths.reportFile,
        prdFile: paths.prdFile,
        statusFile: paths.statusFile,
        analyticsFile: paths.analyticsFile,
        now: resolveNow(options.now),
        svSummary,
        blockedReason,
        blockedCategory: blockedClassification.reason_category,
      });
      return {
        status: 'blocked',
        usId,
        reason: blockedReason,
        category: blockedClassification.reason_category,
        statusFile: paths.statusFile,
      };
    }

    // Luna-first spec §2.5 dual counter (zsh parity). consecutive_failures
    // counts EVERY failure and owns the circuit breaker / BLOCKED-on-exhaustion;
    // escalation_eligible_failures counts only escalation-eligible failures and
    // is the sole input to the ladder rung arithmetic. Without the second
    // counter, environment failures still advance `stage = floor(n/3)` and a
    // later genuine failure climbs a rung it did not earn (or skips one
    // entirely) — governance §4 says environment/flaky "never counts toward
    // model escalation".
    const ladderEligible = recordFailureCounters(state, verdict);
    // IMP-10: per-iteration close-out for the done-claim lock marked above
    // (mirrors zsh's unconditional archive_iter_artifacts call). MUST fire
    // BEFORE appendIterationAnalytics — see the 'pass' branch comment above
    // for why (flush-ordering; a post-flush markUnlock is silently lost on a
    // terminal iteration).
    lifecycleMetrics.markUnlock(path.basename(paths.doneClaimFile), { ctx: 'archival', iter: state.iteration });
    await appendIterationAnalytics(paths, state, usId, 'fail', options, lifecycleMetrics, true, iterationDurationSeconds);
    // Terminal escalation is unchanged: still computed from consecutive_failures
    // so a run of environment failures still exhausts the ladder and BLOCKs,
    // exactly as the zsh CB threshold does. Only the ASSIGNED model comes from
    // the eligible-failure walk below.
    const upgradedModel = nextWorkerModel(options.workerModel ?? state.worker_model, state.consecutive_failures);
    if (upgradedModel === 'BLOCKED') {
      state.phase = 'blocked';
      const upgradeReason = `model-upgrade-exhausted (worker_model=${state.worker_model}, consecutive_failures=${state.consecutive_failures})`;
      await writeSentinel(paths.blockedSentinel, 'blocked', usId, upgradeReason, _classifyBlock('model_upgrade', { state, slug }), paths);
      await writeStatus(paths, state, options.onStatusChange, options.now);
      let svSummary;
      if (options.withSelfVerification) {
        try {
          const sv = await generateSVReport({
            slug,
            logsDir: path.dirname(paths.reportFile),
            prdFile: paths.prdFile,
            testSpecFile: paths.testSpecFile,
            analyticsFile: paths.analyticsFile,
            outputDir: paths.analyticsDir,
          });
          svSummary = sv.summary;
        } catch (err) {
          svSummary = `SV report generation failed: ${err.message}`;
        }
      }
      await generateCampaignReport({
        slug,
        reportFile: paths.reportFile,
        prdFile: paths.prdFile,
        statusFile: paths.statusFile,
        analyticsFile: paths.analyticsFile,
        now: resolveNow(options.now),
        svSummary,
        blockedReason: upgradeReason,
        blockedCategory: 'repeat_axis',
      });
      return {
        status: 'blocked',
        usId,
        reason: upgradeReason,
        category: 'repeat_axis',
        statusFile: paths.statusFile,
      };
    }

    if (ladderEligible) {
      // Rung walked from the ELIGIBLE counter, so prior environment/flaky
      // failures contribute nothing. eligible <= consecutive, and the rung walk
      // is monotone in the counter, so this can only be 'BLOCKED' if the check
      // above already returned — the guard is belt-and-braces against ever
      // assigning the sentinel string as a model.
      const ladderModel = nextWorkerModel(
        options.workerModel ?? state.worker_model,
        state.escalation_eligible_failures,
      );
      if (ladderModel !== 'BLOCKED') {
        state.worker_model = ladderModel;
      }
    } else {
      await debugLogger('DECIDE', {
        iter: state.iteration,
        phase: 'model_select',
        model_upgrade: false,
        reason: `failure_category_${verdictFailureCategory(verdict)}`,
      });
    }
    state.current_us = usId;
    fixContractPath = path.join(paths.campaignLogDir, `iter-${String(state.iteration).padStart(3, '0')}.fix-contract.md`);
    await writePromptFile(fixContractPath, buildFixContract(verdict));
    state.phase = 'worker';
    await writeStatus(paths, state, options.onStatusChange, options.now);
    state.iteration += 1;
  }

  return {
    status: 'continue',
    usId: state.current_us,
    statusFile: paths.statusFile,
  };
}

export async function initAndRun(slug, objective, options = {}) {
  await initCampaign(slug, objective, options);
  return run(slug, options);
}
