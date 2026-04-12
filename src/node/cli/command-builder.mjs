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

  const parts = [
    'DISABLE_OMC=1',
    CLAUDE_BIN,
    '--model',
    model,
    '--mcp-config',
    '\'{"mcpServers":{}}\'',
    '--strict-mcp-config',
    '--dangerously-skip-permissions',
  ];

  if (options.effort !== undefined && options.effort !== '') {
    parts.push('--effort', options.effort);
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
