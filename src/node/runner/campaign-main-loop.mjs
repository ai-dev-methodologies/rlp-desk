import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

import { buildClaudeCmd, buildCodexCmd, parseModelFlag } from '../cli/command-builder.mjs';
import { initCampaign } from '../init/campaign-initializer.mjs';
import { TimeoutError, pollForSignal as defaultPollForSignal } from '../polling/signal-poller.mjs';
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
const CLAUDE_MODELS = new Set(['haiku', 'sonnet', 'opus']);
const MODEL_UPGRADES = {
  'gpt-5.4:medium': 'gpt-5.4:high',
  'gpt-5.4:high': 'gpt-5.4:xhigh',
  'gpt-5.4:xhigh': 'BLOCKED',
  'gpt-5.3-codex-spark:medium': 'gpt-5.3-codex-spark:high',
  'gpt-5.3-codex-spark:high': 'gpt-5.3-codex-spark:xhigh',
  'gpt-5.3-codex-spark:xhigh': 'BLOCKED',
};

function buildPaths(rootDir, slug) {
  const deskRoot = path.join(rootDir, '.claude', 'ralph-desk');
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
    analyticsDir: path.join(os.homedir(), '.claude', 'ralph-desk', 'analytics', slug),
    reportFile: path.join(campaignLogDir, 'campaign-report.md'),
    statusFile: path.join(campaignLogDir, 'runtime', 'status.json'),
    flywheelPromptFile: path.join(deskRoot, 'prompts', `${slug}.flywheel.prompt.md`),
    flywheelSignalFile: path.join(deskRoot, 'memos', `${slug}-flywheel-signal.json`),
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

async function defaultCreateSession({ sessionName, workingDir }) {
  const { stdout } = await execFileAsync('tmux', [
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
    current_us: status.current_us ?? null,
    session_name: status.session_name ?? null,
    leader_pane_id: status.leader_pane_id ?? null,
    worker_pane_id: status.worker_pane_id ?? null,
    verifier_pane_id: status.verifier_pane_id ?? null,
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

async function writeSentinel(filePath, status, usId) {
  const content = `${status.toUpperCase()}: ${usId}\n`;
  await fs.writeFile(filePath, content, 'utf8');
}

async function runFinalSequentialVerify({
  paths,
  state,
  usList,
  sendKeys,
  verifierPaneId,
  pollForSignal,
  runIntegrationCheck,
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

function buildFlywheelTriggerCmd({ flywheelPromptFile, flywheelModel, rootDir }) {
  return `cd ${JSON.stringify(rootDir)} && DISABLE_OMC=1 claude --model ${flywheelModel} --no-mcp -p "$(cat ${JSON.stringify(flywheelPromptFile)})"`;
}

async function dispatchFlywheel({ paths, sendKeys, flywheelPaneId, flywheelModel, rootDir }) {
  const triggerCmd = buildFlywheelTriggerCmd({
    flywheelPromptFile: paths.flywheelPromptFile,
    flywheelModel,
    rootDir,
  });
  await sendKeys(flywheelPaneId, triggerCmd);
}

export function shouldRunFlywheel(flywheelMode, state) {
  if (flywheelMode === 'off') return false;
  if (flywheelMode === 'on-fail' && (state.consecutive_failures ?? 0) > 0) return true;
  return false;
}

export async function run(slug, options = {}) {
  const rootDir = path.resolve(options.rootDir ?? process.cwd());
  const paths = buildPaths(rootDir, slug);
  const sendKeys = options.sendKeys ?? defaultSendKeys;
  const createPane = options.createPane ?? defaultCreatePane;
  const createSession = options.createSession ?? defaultCreateSession;
  const pollForSignal = options.pollForSignal ?? defaultPollForSignal;
  const runIntegrationCheck = options.runIntegrationCheck ?? (async () => ({ exitCode: 0, summary: 'integration skipped' }));
  const maxIterations = options.maxIterations ?? 100;

  await ensureDirs(paths);
  await ensureScaffold(paths);
  await prepareCampaignAnalytics({
    analyticsFile: paths.analyticsFile,
    statusFile: paths.statusFile,
  });

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
    });
    state.session_name = session.sessionName;
    state.leader_pane_id = session.leaderPaneId;
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

  while (state.iteration <= maxIterations) {
    state.current_us = getNextUs(usList, state.verified_us, state.current_us);
    if (state.current_us === 'ALL') {
      const finalResult = await runFinalSequentialVerify({
        paths,
        state,
        usList,
        sendKeys,
        verifierPaneId: state.verifier_pane_id,
        pollForSignal,
        runIntegrationCheck,
      });

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

      const flywheelSignal = await pollForSignal(paths.flywheelSignalFile, {
        mode: 'claude',
        paneId: state.flywheel_pane_id ?? state.verifier_pane_id,
      });

      state.last_flywheel_decision = flywheelSignal.decision;
      // Campaign memory already updated by flywheel agent
      // Clean signal file for next iteration
      await fs.unlink(paths.flywheelSignalFile).catch(() => {});
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
      });
    } catch (error) {
      if (error instanceof TimeoutError && parseModelFlag(state.worker_model).engine === 'codex') {
        signal = {
          iteration: state.iteration,
          status: 'verify',
          us_id: state.current_us,
          summary: 'auto-generated after codex exit fallback',
        };
      } else {
        throw error;
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

    const verdict = await pollForSignal(paths.verdictFile, {
      mode: parseModelFlag(verifierModel, 'verifier').engine,
      paneId: state.verifier_pane_id,
    });

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
      await writeSentinel(paths.blockedSentinel, 'blocked', usId);
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
      });
      return {
        status: 'blocked',
        usId,
        statusFile: paths.statusFile,
      };
    }

    state.consecutive_failures += 1;
    await appendIterationAnalytics(paths, state, usId, 'fail', options);
    const upgradedModel = nextWorkerModel(options.workerModel ?? state.worker_model, state.consecutive_failures);
    if (upgradedModel === 'BLOCKED') {
      state.phase = 'blocked';
      await writeSentinel(paths.blockedSentinel, 'blocked', usId);
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
        status: 'blocked',
        usId,
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
