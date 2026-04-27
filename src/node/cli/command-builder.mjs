import { shellQuote } from '../util/shell-quote.mjs';
import { OPUS_1M_BETA, isOpusModel } from '../constants.mjs';

const CLAUDE_BIN = 'claude';
const CODEX_BIN = 'codex';
const CLAUDE_MODELS = new Set(['haiku', 'sonnet', 'opus']);

function assertTuiMode(mode, builderName) {
  if (mode !== 'tui') {
    throw new Error(`${builderName} unknown mode '${mode}'`);
  }
}

export function buildClaudeCmd(mode, model, options = {}) {
  assertTuiMode(mode, 'buildClaudeCmd');

  // v5.7 §4.9: auto-enable 1M-token context for Opus models. Long campaigns
  // no longer silently truncate at 200K. Header is benign for non-Opus calls
  // but we omit it there to keep the cmdline tidy.
  const parts = ['DISABLE_OMC=1'];
  if (isOpusModel(model)) {
    parts.push(`ANTHROPIC_BETA=${shellQuote(OPUS_1M_BETA)}`);
  }
  parts.push(
    CLAUDE_BIN,
    '--model',
    shellQuote(model),
    '--mcp-config',
    '\'{"mcpServers":{}}\'',
    '--strict-mcp-config',
    '--dangerously-skip-permissions',
  );

  // v5.7 §4.11.a: explicit --add-dir whitelist. With --dangerously-skip-permissions
  // alone, claude CLI still surfaces TUI prompts for cwd-adjacent paths in some
  // versions. Add the home rlp-desk tree (where Leader writes registry.jsonl
  // and reads governance docs) plus the campaign cwd, so Worker has full
  // authorized access without prompts.
  if (options.addDirs && Array.isArray(options.addDirs)) {
    for (const dir of options.addDirs) {
      if (dir) parts.push('--add-dir', shellQuote(dir));
    }
  }

  if (options.effort !== undefined && options.effort !== '') {
    parts.push('--effort', shellQuote(options.effort));
  }

  return parts.join(' ');
}

export function buildCodexCmd(mode, model, options = {}) {
  assertTuiMode(mode, 'buildCodexCmd');

  const parts = [
    CODEX_BIN,
    '-m',
    model,
  ];

  if (options.reasoning !== undefined) {
    parts.push('-c', `model_reasoning_effort="${options.reasoning}"`);
  }

  parts.push('--disable', 'plugins', '--dangerously-bypass-approvals-and-sandbox');

  return parts.join(' ');
}

export function parseModelFlag(value, role = 'worker') {
  const colonCount = [...value].filter((character) => character === ':').length;

  if (colonCount > 1) {
    throw new Error(
      `invalid format for --${role}-model '${value}'. Use 'model:effort' (claude) or 'model:reasoning' (codex).`,
    );
  }

  if (colonCount === 0) {
    if (!value) {
      throw new Error(`--${role}-model model is required`);
    }

    return {
      engine: 'claude',
      model: value,
    };
  }

  const [model, level] = value.split(':');
  if (!model) {
    throw new Error(`--${role}-model model is required`);
  }

  if (CLAUDE_MODELS.has(model)) {
    return {
      engine: 'claude',
      model,
      effort: level,
    };
  }

  if (model === 'spark') {
    return {
      engine: 'codex',
      model: 'gpt-5.3-codex-spark',
      reasoning: level,
    };
  }

  return {
    engine: 'codex',
    model,
    reasoning: level,
  };
}
