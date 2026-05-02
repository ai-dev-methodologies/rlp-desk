import fs from 'node:fs/promises';
import fsSync from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { buildClaudeCmd, buildCodexCmd, parseModelFlag } from '../cli/command-builder.mjs';
import { shellQuote } from '../util/shell-quote.mjs';
import { OPUS_1M_BETA, isOpusModel } from '../constants.mjs';
import { initCampaign } from '../init/campaign-initializer.mjs';
import { LEGACY_DESK_REL, resolveDeskRoot } from '../util/desk-root.mjs';
import { writeSentinelExclusive } from '../shared/fs.mjs';
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
import {
  createPane as defaultCreatePane,
  sendKeys as defaultSendKeys,
} from '../tmux/pane-manager.mjs';

const execFileAsync = promisify(execFile);
const REQUIRED_SCAFFOLD_NAMES = ['workerPrompt', 'verifierPrompt', 'memoryFile', 'prdFile', 'testSpecFile'];
const MODEL_UPGRADES = {
  'gpt-5.5:medium': 'gpt-5.5:high',
  'gpt-5.5:high': 'gpt-5.5:xhigh',
  'gpt-5.5:xhigh': 'BLOCKED',
  'gpt-5.3-codex-spark:medium': 'gpt-5.3-codex-spark:high',
  'gpt-5.3-codex-spark:high': 'gpt-5.3-codex-spark:xhigh',
  'gpt-5.3-codex-spark:xhigh': 'BLOCKED',
};

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

function buildPaths(rootDir, slug, env = process.env) {
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
    workerPrompt: path.join(deskRoot, 'prompts', `${slug}.worker.prompt.md`),
    verifierPrompt: path.join(deskRoot, 'prompts', `${slug}.verifier.prompt.md`),
    memoryFile: path.join(deskRoot, 'memos', `${slug}-memory.md`),
    doneClaimFile: path.join(deskRoot, 'memos', `${slug}-done-claim.json`),
    signalFile: path.join(deskRoot, 'memos', `${slug}-iter-signal.json`),
    verdictFile: path.join(deskRoot, 'memos', `${slug}-verify-verdict.json`),
    blockedSentinel: path.join(deskRoot, 'memos', `${slug}-blocked.md`),
    completeSentinel: path.join(deskRoot, 'memos', `${slug}-complete.md`),
    contextFile: path.join(deskRoot, 'context', `${slug}-latest.md`),
    prdFile: path.join(deskRoot, 'plans', `prd-${slug}.md`),
    testSpecFile: path.join(deskRoot, 'plans', `test-spec-${slug}.md`),
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
};
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

function buildLaunchCommand(promptFile, modelFlag) {
  const parsed = parseModelFlag(modelFlag);
  const promptExpr = `"$(cat ${shQuote(promptFile)})"`;

  if (parsed.engine === 'claude') {
    return `${buildClaudeCmd('tui', parsed.model, { effort: parsed.effort })} ${promptExpr}`;
  }

  return `${buildCodexCmd('tui', parsed.model, { reasoning: parsed.reasoning })} ${promptExpr}`;
}

async function writePromptFile(targetPath, content) {
  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  await fs.writeFile(targetPath, content, 'utf8');
}

function buildFixContract(verdict) {
  const issues = [...(verdict.issues ?? [])].sort((left, right) => {
    const rank = { critical: 0, major: 1, minor: 2 };
    return (rank[left.severity] ?? 3) - (rank[right.severity] ?? 3);
  });

  const lines = ['# Fix Contract', ''];
  if (issues.length === 0) {
    lines.push('- No structured issues were provided. Re-check the failing scope and verifier evidence.');
  }

  for (const issue of issues) {
    lines.push(`- ${issue.criterion_id ?? 'unknown'} [${issue.severity ?? 'major'}]: ${issue.summary ?? 'unspecified issue'}`);
    if (issue.fix_hint) {
      lines.push(`  fix_hint: ${issue.fix_hint}`);
    }
  }

  return `${lines.join('\n')}\n`;
}

function nextWorkerModel(currentModel, consecutiveFailures) {
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
    started_at_utc: startedAt,
  };
}

async function appendIterationAnalytics(paths, state, usId, verdict, options) {
  await appendCampaignAnalytics(paths.analyticsFile, {
    iter: state.iteration,
    us_id: usId,
    worker_model: state.worker_model,
    worker_engine: parseModelFlag(state.worker_model).engine,
    verdict,
    duration: 0,
    timestamp: toIso(resolveNow(options.now)),
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
  });
  const promptFile = path.join(paths.campaignLogDir, `iter-${String(iteration).padStart(3, '0')}.worker-prompt.md`);

  await writePromptFile(promptFile, prompt);
  await sendKeys(workerPaneId, buildLaunchCommand(promptFile, state.worker_model));
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
}) {
  const prompt = await assembleVerifierPrompt({
    promptBase: paths.verifierPrompt,
    iteration,
    doneClaimFile: paths.doneClaimFile,
    verifyMode: 'per-us',
    usId,
    verifiedUs: state.verified_us,
  });
  const fileName = suffix
    ? `${suffix}.verifier-prompt.md`
    : `iter-${String(iteration).padStart(3, '0')}.verifier-prompt.md`;
  const promptFile = path.join(paths.campaignLogDir, fileName);

  await writePromptFile(promptFile, prompt);
  await sendKeys(verifierPaneId, buildLaunchCommand(promptFile, verifierModel));
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
});

// P1-D Failure Taxonomy classifier. governance §1f locks the reason_category
// values + recoverable + suggested_action defaults per source. wrapper MUST
// branch on reason_category; failure_category is diagnostic only.
function _classifyBlock(source, { verdict, state, slug } = {}) {
  let category;
  let recoverable;
  let action;
  let failureCategory = null;
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
      break;
    // Backstop: run() exited without terminal sentinel.
    case BLOCK_TAGS.LEADER_EXITED_WITHOUT_TERMINAL_STATE:
      category = 'infra_failure';
      recoverable = false;
      action = 'investigate_leader_logs';
      failureCategory = 'leader_exited_without_terminal_state';
      break;
    default:
      category = 'metric_failure';
      recoverable = false;
      action = 'terminal_alert';
  }
  return {
    reason_category: category,
    failure_category: failureCategory,
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
  } = ctx;
  const usId = usIdOverride ?? state.current_us;

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
      recoverable: classification.recoverable ?? false,
      suggested_action: classification.suggested_action ?? 'terminal_alert',
      meta: { blocked_hygiene_violated: hygieneViolated },
    };
    await fs.writeFile(jsonPath, `${JSON.stringify(jsonBody, null, 2)}\n`, 'utf8');
  }

  return result;
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
}) {
  const verifierModel = state.final_verifier_model;

  for (const usId of usList) {
    await dispatchVerifier({
      iteration: state.iteration,
      suffix: `final-${usId}`,
      paths,
      state,
      usId,
      sendKeys,
      verifierPaneId,
      verifierModel,
    });

    const verdict = await pollForSignal(paths.verdictFile, {
      mode: parseModelFlag(verifierModel, 'verifier').engine,
      paneId: verifierPaneId,
      timeoutMs: iterTimeoutMs,
    });

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
  // §4.9: ANTHROPIC_BETA prefix for Opus 1M context.
  const betaPrefix = isOpusModel(model)
    ? `ANTHROPIC_BETA=${shellQuote(OPUS_1M_BETA)} `
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
    throw new Error(`No user stories found for ${slug}`);
  }

  if (!state.current_us) {
    state.current_us = getNextUs(usList, state.verified_us, null);
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

  // P1-E Lane Enforcement: snapshot lane mtimes before each iteration,
  // compare at the top of the next iteration. Drift on read-only artifacts
  // (PRD, test-spec, context) emits a lane_violation_warning event + audit
  // log entry. governance §7e. Strict mode escalation hook is wired below
  // (sentinel BLOCKED with infra_failure + recoverable=true downgrade).
  let _laneSnapshot = await _snapshotLaneMtimes(paths);

  while (state.iteration <= maxIterations) {
    // Audit drift from the prior iteration before doing anything new.
    const _laneSnapshotAfter = await _snapshotLaneMtimes(paths);
    const _laneViolations = await _checkLaneViolations(paths, _laneSnapshot, _laneSnapshotAfter, state, options);
    if (_laneViolations) {
      for (const v of _laneViolations) {
        await appendIterationAnalytics(paths, state, state.current_us ?? 'ALL', 'lane_violation_warning', { ...options, lane_violation: v });
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

      state.last_flywheel_decision = flywheelSignal.decision;
      // P0-A multi-mission orchestration: optionally captured from flywheel signal.
      // null when the flywheel did not suggest a next mission. Consumer wrappers
      // poll status.next_mission_candidate to chain missions without code edits.
      // See docs/multi-mission-orchestration.md.
      state.next_mission_candidate = flywheelSignal.next_mission_candidate ?? null;
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

        if (!state.flywheel_guard_count[state.current_us]) {
          state.flywheel_guard_count[state.current_us] = 0;
        }
        state.flywheel_guard_count[state.current_us] += 1;

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

    state.phase = 'worker';
    await writeStatus(paths, state, options.onStatusChange, options.now);
    await dispatchWorker({
      iteration: state.iteration,
      paths,
      slug,
      usList,
      state,
      sendKeys,
      workerPaneId: state.worker_pane_id,
      fixContractPath,
    });

    let signal;
    try {
      signal = await pollForSignal(paths.signalFile, {
        mode: parseModelFlag(state.worker_model).engine,
        paneId: state.worker_pane_id,
        timeoutMs: iterTimeoutMs,
      });
      validateArtifact(signal, {
        expectedSlug: slug,
        iterationFloor: state.iteration,
        expectedSignalType: 'signal',
        allowedUsIds: [...usList, 'ALL'],
      });
    } catch (error) {
      if (error instanceof TimeoutError && parseModelFlag(state.worker_model).engine === 'codex') {
        // v5.7 — codex CLI exits cleanly after writing signal; if pollForSignal
        // timed out for codex, synthesize a verify signal so the loop continues.
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
    await dispatchVerifier({
      iteration: state.iteration,
      paths,
      state,
      usId,
      sendKeys,
      verifierPaneId: state.verifier_pane_id,
      verifierModel,
    });

    let verdict;
    try {
      verdict = await pollForSignal(paths.verdictFile, {
        mode: parseModelFlag(verifierModel, 'verifier').engine,
        paneId: state.verifier_pane_id,
        timeoutMs: iterTimeoutMs,
      });
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

    if (verdict.verdict === 'pass') {
      state.consecutive_failures = 0;
      if (!state.verified_us.includes(usId)) {
        state.verified_us.push(usId);
      }
      state.current_us = getNextUs(usList, state.verified_us, null);
      fixContractPath = null;
      await appendIterationAnalytics(paths, state, usId, 'pass', options);
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
      await appendIterationAnalytics(paths, state, usId, 'blocked', options);
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

    state.consecutive_failures += 1;
    await appendIterationAnalytics(paths, state, usId, 'fail', options);
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

    state.worker_model = upgradedModel;
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
