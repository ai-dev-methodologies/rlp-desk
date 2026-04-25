import path from 'node:path';
import { fileURLToPath } from 'node:url';

import { initCampaign } from './init/campaign-initializer.mjs';
import { readStatus } from './reporting/campaign-reporting.mjs';
import { run as runCampaignMain } from './runner/campaign-main-loop.mjs';

const RUN_DEFAULTS = {
  mode: 'agent',
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
    '  run <slug> [options]         Run loop (agent=LLM leader, tmux=shell leader)',
    '  status <slug>                Show loop status',
    '  logs <slug> [N]              Show iteration log (not implemented in the Node rewrite yet)',
    '  clean <slug> [--kill-session] Reset for re-run (not implemented in the Node rewrite yet)',
    '  resume <slug>                Resume loop (not implemented in the Node rewrite yet)',
    '',
    'Run Options:',
    '  --mode agent|tmux',
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
  await deps.initCampaign(slug, objective, { rootDir: deps.cwd });
  write(deps.stdout, `Initialized ${slug} in ${path.join(deps.cwd, '.claude', 'ralph-desk')}`);
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
      case 'brainstorm':
      case 'logs':
      case 'clean':
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
