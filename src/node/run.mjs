import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { initCampaign } from './init/campaign-initializer.mjs';
import { readStatus, generateSVReport } from './reporting/campaign-reporting.mjs';
import {
  run as runCampaignMain,
  detectLegacyDeskInRunMode,
  buildPaths,
} from './runner/campaign-main-loop.mjs';
import { isClaudeEngine } from './cli/command-builder.mjs';

const RUN_DEFAULTS = {
  // ARCH Wave D (ADR-001 §3): the Node-CLI default mode flips from the deprecated
  // 'agent' (Node-leader alpha) to 'tmux' (the canonical production leader) at the
  // same step that makes --mode agent hard-error. A bare `run <slug>` now delegates
  // to the zsh runner, not the deprecated Node leader.
  mode: 'tmux',
  workerModel: 'haiku',
  verifierModel: 'sonnet',
  finalVerifierModel: 'opus',
  consensusMode: 'off',
  consensusModel: 'gpt-5.5:medium',
  finalConsensusModel: 'gpt-5.5:high',
  verifyMode: 'per-us',
  cbThreshold: 6,
  maxIterations: 100,
  iterTimeout: 600,
  debug: false,
  lockWorkerModel: false,
  autonomous: false,
  withSelfVerification: false,
  laneStrict: false,
  testDensityStrict: false,
  flywheel: 'off',
  flywheelModel: 'opus',
  flywheelGuard: 'off',
  flywheelGuardModel: 'opus',
};

function write(stream, value) {
  stream.write(value.endsWith('\n') ? value : `${value}\n`);
}

function buildHelpText() {
  return [
    'Usage:',
    '  node src/node/run.mjs <command> [args] [options]',
    '',
    'Commands:',
    '  brainstorm <description>     Plan before init (not implemented in the Node rewrite yet)',
    '  init <slug> [objective]      Create project scaffold',
    '  run <slug> [options]         Run loop (tmux=zsh leader [production, default], agent=hard-errors per ADR-001, native=slash-only error)',
    '  status <slug>                Show loop status',
    '  logs <slug> [N]              Show iteration log (not implemented in the Node rewrite yet)',
    '  clean <slug> [--kill-session] Reset for re-run (removes sentinels + runtime/; preserves PRD/prompts/memory)',
    '  resume <slug>                Resume loop (not implemented in the Node rewrite yet)',
    '',
    'Run Options:',
    '  --mode tmux|agent|native       (CLI: tmux=production [default], agent=hard-errors (ADR-001), native=errors with redirect to slash command)',
    '  --worker-model MODEL',
    '  --lock-worker-model',
    '  --verifier-model MODEL',
    '  --final-verifier-model MODEL',
    '  --consensus off|all|final-only',
    '  --consensus-model MODEL',
    '  --final-consensus-model MODEL',
    '  --verify-mode per-us|batch',
    '  --cb-threshold N',
    '  --max-iter N',
    '  --iter-timeout N',
    '  --debug',
    '  --autonomous',
    '  --lane-strict',
    '  --test-density-strict',
    '  --with-self-verification',
    '  --flywheel off|on-fail',
    '  --flywheel-model MODEL',
    '  --flywheel-guard off|on',
    '  --flywheel-guard-model MODEL',
    '  --help',
  ].join('\n');
}

function consumeValue(args, index, flag) {
  const value = args[index + 1];
  if (!value || value.startsWith('--')) {
    throw new Error(`missing value for ${flag}`);
  }
  return value;
}

function parseInteger(value, flag) {
  const parsed = Number.parseInt(value, 10);
  if (!Number.isInteger(parsed) || parsed < 0) {
    throw new Error(`${flag} must be a non-negative integer`);
  }
  return parsed;
}

function parseRunOptions(args, cwd) {
  const options = {
    rootDir: cwd,
    ...RUN_DEFAULTS,
  };

  for (let index = 0; index < args.length; index += 1) {
    const token = args[index];
    switch (token) {
      case '--mode':
        options.mode = consumeValue(args, index, token);
        index += 1;
        break;
      case '--worker-model':
        options.workerModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--lock-worker-model':
        options.lockWorkerModel = true;
        break;
      case '--verifier-model':
        options.verifierModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--final-verifier-model':
        options.finalVerifierModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--consensus':
        options.consensusMode = consumeValue(args, index, token);
        index += 1;
        break;
      case '--consensus-model':
        options.consensusModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--final-consensus-model':
        options.finalConsensusModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--verify-mode':
        options.verifyMode = consumeValue(args, index, token);
        index += 1;
        break;
      case '--cb-threshold':
        options.cbThreshold = parseInteger(consumeValue(args, index, token), token);
        index += 1;
        break;
      case '--max-iter':
        options.maxIterations = parseInteger(consumeValue(args, index, token), token);
        index += 1;
        break;
      case '--iter-timeout':
        options.iterTimeout = parseInteger(consumeValue(args, index, token), token);
        index += 1;
        break;
      case '--debug':
        options.debug = true;
        break;
      case '--autonomous':
        options.autonomous = true;
        break;
      case '--lane-strict':
        // P1-E lane enforcement opt-in. Default WARN. governance §7¾.
        options.laneStrict = true;
        break;
      case '--test-density-strict':
        // US-018 R6 P1-F test density enforcement opt-in. Default WARN. governance §7f.
        options.testDensityStrict = true;
        break;
      case '--with-self-verification':
        options.withSelfVerification = true;
        break;
      case '--flywheel':
        options.flywheel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--flywheel-model':
        options.flywheelModel = consumeValue(args, index, token);
        index += 1;
        break;
      case '--flywheel-guard':
        options.flywheelGuard = consumeValue(args, index, token);
        index += 1;
        break;
      case '--flywheel-guard-model':
        options.flywheelGuardModel = consumeValue(args, index, token);
        index += 1;
        break;
      default:
        throw new Error(`unknown option: ${token}`);
    }
  }

  return options;
}

async function runInit(args, deps) {
  if (args.length === 0 || args[0] === '--help') {
    write(deps.stdout, 'Usage: node src/node/run.mjs init <slug> [objective]');
    return 0;
  }

  const slug = args[0];
  const objective = args.slice(1).join(' ').trim() || 'TBD - fill in the objective';
  const result = await deps.initCampaign(slug, objective, { rootDir: deps.cwd });
  const deskRoot = result?.paths?.deskRoot ?? path.join(deps.cwd, '.rlp-desk');
  write(deps.stdout, `Initialized ${slug} in ${deskRoot}`);
  return 0;
}

async function runStatusCommand(args, deps) {
  if (args.length === 0 || args[0] === '--help') {
    write(deps.stdout, 'Usage: node src/node/run.mjs status <slug>');
    return 0;
  }

  write(deps.stdout, await deps.readStatus(args[0], { rootDir: deps.cwd }));
  return 0;
}

// D-6 (dogfood): real `clean` for the Node leader. Previously "not implemented",
// which left a blocked campaign with NO recovery path (a transient parse error
// wrote a blocked sentinel that bricked re-runs). Removes the transient/terminal
// state (sentinels, signal/claim/verdict, runtime/) while PRESERVING the durable
// inputs (PRD, test-spec, prompts, context, memory) and the campaign report.
async function runCleanCommand(args, deps) {
  if (args.length === 0 || args[0] === '--help') {
    write(deps.stdout, 'Usage: node src/node/run.mjs clean <slug> [--kill-session]');
    return 0;
  }
  const slug = args[0];
  const killSession = args.includes('--kill-session');
  const paths = buildPaths(deps.cwd, slug);

  // --kill-session: read the session name from runtime/session-config.json
  // BEFORE removing runtime, then best-effort tmux teardown.
  if (killSession) {
    try {
      const cfgPath = path.join(paths.runtimeDir, 'session-config.json');
      if (deps.fileExists(cfgPath)) {
        const cfg = JSON.parse(fs.readFileSync(cfgPath, 'utf8'));
        if (cfg && cfg.session_name) {
          spawnSync('tmux', ['kill-session', '-t', cfg.session_name], { stdio: 'ignore' });
        }
      }
    } catch { /* best-effort */ }
  }

  const transient = [
    paths.blockedSentinel,
    paths.blockedSentinel.replace(/\.md$/, '.json'),
    paths.completeSentinel,
    paths.completeSentinel.replace(/\.md$/, '.json'),
    paths.signalFile,
    paths.doneClaimFile,
    paths.verdictFile,
    paths.flywheelSignalFile,
    paths.flywheelGuardVerdictFile,
  ];
  let removed = 0;
  for (const target of transient) {
    try {
      if (fs.existsSync(target)) {
        // Sentinels may be chmod 0o444 (write-lock); relax before unlink.
        try { fs.chmodSync(target, 0o644); } catch { /* ignore */ }
        fs.rmSync(target, { force: true });
        removed += 1;
      }
    } catch { /* best-effort per-file */ }
  }
  try {
    if (fs.existsSync(paths.runtimeDir)) {
      fs.rmSync(paths.runtimeDir, { recursive: true, force: true });
      removed += 1;
    }
  } catch { /* best-effort */ }

  write(
    deps.stdout,
    `Cleaned ${slug}: removed ${removed} transient artifact(s) (sentinels, signal/claim/verdict, runtime/`
      + `${killSession ? ', tmux session' : ''}). Preserved PRD, test-spec, prompts, context, memory, reports.`,
  );
  return 0;
}

// v0.14.0: Default location of the zsh runner installed by postinstall.js
// (Phase 3 of the v0.14.0 plan re-enables this sync). Overridable via
// RLP_DESK_ZSH_RUNNER for development checkouts that point to src/scripts.
function defaultZshRunnerPath() {
  return (
    process.env.RLP_DESK_ZSH_RUNNER
    || path.join(os.homedir(), '.claude', 'ralph-desk', 'run_ralph_desk.zsh')
  );
}

// v0.14.0: convert parsed CLI options to env vars consumed by run_ralph_desk.zsh.
// Names mirror the variables declared in src/scripts/run_ralph_desk.zsh
// (LOOP_NAME, ROOT, WORKER_MODEL, VERIFIER_MODEL, FINAL_VERIFIER_MODEL,
// MAX_ITER, ITER_TIMEOUT, CB_THRESHOLD, VERIFY_MODE, CONSENSUS_MODE,
// CONSENSUS_MODEL, FINAL_CONSENSUS_MODEL, LOCK_WORKER_MODEL, AUTONOMOUS_MODE,
// LANE_MODE, TEST_DENSITY_MODE).
function buildZshEnv(slug, options, parentEnv) {
  return {
    ...parentEnv,
    LOOP_NAME: slug,
    ROOT: options.rootDir,
    WORKER_MODEL: options.workerModel,
    VERIFIER_MODEL: options.verifierModel,
    FINAL_VERIFIER_MODEL: options.finalVerifierModel,
    MAX_ITER: String(options.maxIterations),
    ITER_TIMEOUT: String(options.iterTimeout),
    CB_THRESHOLD: String(options.cbThreshold),
    VERIFY_MODE: options.verifyMode,
    CONSENSUS_MODE: options.consensusMode,
    CONSENSUS_MODEL: options.consensusModel,
    FINAL_CONSENSUS_MODEL: options.finalConsensusModel,
    LOCK_WORKER_MODEL: options.lockWorkerModel ? '1' : '0',
    AUTONOMOUS_MODE: options.autonomous ? '1' : '0',
    LANE_MODE: options.laneStrict ? 'strict' : 'warn',
    TEST_DENSITY_MODE: options.testDensityStrict ? 'strict' : 'warn',
    // ARCH Wave C-SV: forwarded for traceability only. The zsh leader keeps its
    // $TMUX early-return (no in-pane `claude --print`); the SV report itself is
    // produced by the Node post-pass in runTmuxViaZsh after the zsh child exits.
    WITH_SELF_VERIFICATION: options.withSelfVerification ? '1' : '0',
  };
}

// v0.14.0: default tmux-mode delegate. Spawns the zsh runner inheriting stdio
// so the operator sees pane orchestration in real time. Resolves with the
// child exit code (or 1 on spawn error) to keep the caller deterministic.
function defaultSpawnZsh(zshPath, env, cwd) {
  return new Promise((resolve) => {
    const child = spawn('zsh', [zshPath], { env, stdio: 'inherit', cwd });
    child.on('error', (err) => {
      process.stderr.write(`failed to spawn zsh runner: ${err.message}\n`);
      resolve(1);
    });
    child.on('exit', (code, signal) => {
      if (signal) {
        resolve(128 + (typeof signal === 'string' ? 0 : signal));
        return;
      }
      resolve(typeof code === 'number' ? code : 0);
    });
  });
}

async function runTmuxViaZsh(slug, options, deps) {
  // v0.13.0 legacy detection still applies — the zsh runner shares the same
  // .rlp-desk/ contract, so a stray .claude/ralph-desk/ left over from an
  // older campaign must be migrated by the operator before we hand off.
  const legacy = detectLegacyDeskInRunMode(options.rootDir, process.env);
  if (legacy) {
    write(deps.stderr, legacy.message);
    return 1;
  }

  const zshPath = (deps.zshRunnerPath ?? defaultZshRunnerPath)();
  if (!deps.fileExists(zshPath)) {
    write(
      deps.stderr,
      `ERROR: zsh runner not found at ${zshPath}. Run \`npm install rlp-desk\` (or set RLP_DESK_ZSH_RUNNER) to sync.`,
    );
    return 1;
  }

  // Surface flags the zsh runner cannot honor. ARCH Wave C: --with-self-verification
  // IS now honored in tmux mode via a post-zsh-return pass (see below) — only the
  // flywheel flags remain unsupported here. Warn loudly instead of silent no-op.
  const unsupported = [];
  if (options.flywheel !== 'off') unsupported.push('--flywheel');
  if (options.flywheelGuard !== 'off') unsupported.push('--flywheel-guard');
  if (unsupported.length > 0) {
    write(
      deps.stderr,
      `WARNING: ${unsupported.join(', ')} not honored in --mode tmux (zsh runner). Flywheel is deprecated (ADR-001) and unimplemented in the canonical leader.`,
    );
  }

  const env = buildZshEnv(slug, options, process.env);
  const spawnZsh = deps.spawnZsh ?? defaultSpawnZsh;
  const exitCode = await spawnZsh(zshPath, env, options.rootDir);

  // ARCH Wave C-SV: home self-verification onto --mode tmux. The zsh runner cannot
  // produce the SV report itself (`claude --print` hangs without a TTY in a tmux
  // pane — that is why lib_ralph_desk.zsh keeps its $TMUX early-return). Instead we
  // run the Node PURE-FS generateSVReport as a post-pass AFTER the zsh child exits:
  // real stdout, no pane, no TTY → no hang. It reads the campaign's on-disk
  // iter-*-done-claim/verify-verdict artifacts the zsh leader already wrote.
  if (options.withSelfVerification) {
    try {
      const paths = buildPaths(options.rootDir, slug);
      const sv = await generateSVReport({
        slug,
        logsDir: paths.campaignLogDir,
        prdFile: paths.prdFile,
        testSpecFile: paths.testSpecFile,
        analyticsFile: paths.analyticsFile,
        outputDir: paths.analyticsDir,
      });
      write(deps.stdout, `\nSelf-verification report (tmux post-pass): ${sv.summary ?? 'generated'}`);
    } catch (err) {
      write(deps.stderr, `WARNING: self-verification post-pass failed: ${err.message}`);
    }
  }

  return exitCode;
}

async function runRunCommand(args, deps) {
  if (args.length === 0) {
    throw new Error('run requires a slug');
  }

  if (args[0] === '--help') {
    write(deps.stdout, buildHelpText());
    return 0;
  }

  const slug = args[0];
  const options = parseRunOptions(args.slice(1), deps.cwd);

  // v0.13.0: warn when Claude worker runs in tmux mode. Claude Code's
  // hardcoded sensitive policy used to hang sentinel writes inside
  // <project>/.claude/. After v0.13.0, sentinels live in
  // <project>/.rlp-desk/, but if the user pinned RLP_DESK_RUNTIME_DIR
  // back inside .claude/, the hang can return — surface the warning so
  // they can switch to gpt-5.5:* or --mode agent quickly.
  if (
    !process.env.RLP_DESK_QUIET_WARNINGS
    && process.env.NODE_ENV !== 'test'
    && options.mode === 'tmux'
    && isClaudeEngine(options.workerModel)
  ) {
    write(
      deps.stderr,
      'WARNING: Claude worker in tmux mode may hang on .claude/ sentinel writes.',
    );
    write(
      deps.stderr,
      'After v0.13.0, sentinels live in <project>/.rlp-desk/ which avoids this.',
    );
    write(
      deps.stderr,
      'If hang persists, switch to --worker-model gpt-5.5:high (codex).',
    );
  }

  // v0.14.0: --mode tmux delegates to the zsh runner. Node leader keeps
  // ownership of --mode agent only (LLM-driven orchestration).
  if (options.mode === 'tmux') {
    return runTmuxViaZsh(slug, options, deps);
  }

  // P1.b (native-agent-revert plan v7): --mode native is slash-command-only.
  // The Node CLI does not implement Native Agent() — that path lives in
  // src/commands/rlp-desk.md and runs in a Claude Code session. Surface a
  // hard error here so direct CLI invocation does not silently fall through
  // to the deprecated Node-leader path.
  if (options.mode === 'native') {
    write(
      deps.stderr,
      'ERROR: --mode native is slash-command-only. The Node CLI does not implement it.',
    );
    write(
      deps.stderr,
      'Use `/rlp-desk run <slug> --mode native` from a Claude Code session,',
    );
    write(
      deps.stderr,
      'or use `--mode tmux` (production) for direct CLI invocation. `--mode agent` hard-errors (ADR-001).',
    );
    return 2;
  }

  // ARCH Wave D (ADR-001 §3): --mode agent (Node-leader direct-CLI alpha) HARD-ERRORS
  // as of this release. It is the dated breaking change the deprecation banner
  // announced — direct CLI invocation now exits 2 with a redirect to the canonical
  // production leader (--mode tmux) or the slash-command Native Agent() path
  // (--mode native). This is UNRELATED to the slash command's legacy `--mode agent`
  // → native redirect (different code, different leader). The `src/node/**` engine
  // modules (run()/runCampaign) are RETAINED — they remain the engine the Native
  // Agent() path and the test suite build on; only this direct-CLI dispatch entry
  // hard-errors. Mirror the --mode native slash-only exit-2 pattern above.
  if (options.mode === 'agent') {
    write(
      deps.stderr,
      'ERROR: --mode agent (Node-leader direct-CLI alpha) is no longer supported (ADR-001).',
    );
    write(
      deps.stderr,
      'For production tmux orchestration, use `--mode tmux` (the canonical leader).',
    );
    write(
      deps.stderr,
      'For Claude Code Native Agent() campaigns, use `/rlp-desk run <slug> --mode native` from a Claude Code session.',
    );
    write(
      deps.stderr,
      'The src/node/** engine modules are retained; only the direct-CLI --mode agent entry point was removed.',
    );
    return 2;
  }

  const result = await deps.runCampaign(slug, options);
  // governance §1f BLOCKED Surfacing: surface the blocked reason on stderr so
  // the operator (or wrapper script) does not have to grep memo files.
  if (result && result.status === 'blocked') {
    // P1-D 4-channel surfacing: include category so wrappers can see
    // reason_category alongside the textual reason without parsing JSON.
    const reason = result.reason ? ` — ${result.reason}` : '';
    const cat = result.category ? `, category=${result.category}` : '';
    write(deps.stderr, `Campaign BLOCKED for ${slug} (US=${result.usId}${cat})${reason}`);
    return 2;
  }
  write(deps.stdout, `Campaign started for ${slug}`);
  return 0;
}

export async function main(argv = process.argv.slice(2), overrides = {}) {
  const deps = {
    cwd: overrides.cwd ?? process.cwd(),
    stdout: overrides.stdout ?? process.stdout,
    stderr: overrides.stderr ?? process.stderr,
    initCampaign: overrides.initCampaign ?? initCampaign,
    readStatus: overrides.readStatus ?? readStatus,
    runCampaign: overrides.runCampaign ?? runCampaignMain,
    // v0.14.0: --mode tmux delegate. Tests inject `spawnZsh` to assert the
    // env mapping without actually fork+exec'ing zsh. `fileExists` and
    // `zshRunnerPath` are similarly injectable so a test can pretend the
    // installed runner is or isn't present.
    spawnZsh: overrides.spawnZsh,
    zshRunnerPath: overrides.zshRunnerPath,
    fileExists: overrides.fileExists ?? ((p) => fs.existsSync(p)),
  };

  try {
    if (argv.length === 0 || argv[0] === '--help' || argv[0] === '-h') {
      write(deps.stdout, buildHelpText());
      return 0;
    }

    const [command, ...rest] = argv;
    switch (command) {
      case 'init':
        return await runInit(rest, deps);
      case 'run':
        return await runRunCommand(rest, deps);
      case 'status':
        return await runStatusCommand(rest, deps);
      case 'clean':
        return await runCleanCommand(rest, deps);
      case 'brainstorm':
      case 'logs':
      case 'resume':
        throw new Error(`${command} is not implemented in the Node rewrite yet`);
      default:
        throw new Error(`unknown command: ${command}. Run with --help to see available commands.`);
    }
  } catch (error) {
    write(deps.stderr, error.message);
    return 1;
  }
}

if (process.argv[1] && path.basename(process.argv[1]) === path.basename(fileURLToPath(import.meta.url))) {
  const exitCode = await main();
  process.exitCode = exitCode;
}
