import { shellQuote } from '../util/shell-quote.mjs';
import { ONE_MILLION_BETA, wantsOneMillionContext } from '../constants.mjs';

const CLAUDE_BIN = 'claude';
const CODEX_BIN = 'codex';
const CLAUDE_MODELS = new Set(['haiku', 'sonnet', 'opus']);

// Single source of truth for "is this bare model name a claude model?":
// the short aliases (haiku/sonnet/opus), the bare `claude`, OR any full
// versioned claude id (claude-opus-4-8, claude-fable-5, claude-opus-4-8[1m],
// ...). The startsWith('claude-') branch also covers the bracket+effort combo
// (claude-opus-4-8[1m] is the model part of claude-opus-4-8[1m]:high). Used by
// both isClaudeEngine (which splits the flag first) and parseModelFlag so the
// two never drift.
function isClaudeModelName(model) {
  if (typeof model !== 'string' || model.length === 0) {
    return false;
  }

  return model === 'claude' || CLAUDE_MODELS.has(model) || model.startsWith('claude-');
}

// v0.13.0: surface engine classification for tmux+claude warning + observability.
export function isClaudeEngine(modelFlag) {
  if (typeof modelFlag !== 'string' || modelFlag.length === 0) {
    return false;
  }

  const head = modelFlag.split(':', 1)[0];
  return isClaudeModelName(head);
}

function assertTuiMode(mode, builderName) {
  if (mode !== 'tui') {
    throw new Error(`${builderName} unknown mode '${mode}'`);
  }
}

export function buildClaudeCmd(mode, model, options = {}) {
  assertTuiMode(mode, 'buildClaudeCmd');

  // v0.14.6: 1M context is opt-in only via the explicit '[1m]' suffix.
  // opus / sonnet / claude-opus-4-7 (no suffix) all run at the standard
  // 200K context. Adding '[1m]' on either opus or sonnet model id injects
  // the ANTHROPIC_BETA header and attempts the 1M window — sonnet[1m] still
  // requires Anthropic "Extra usage" entitlement at the API layer.
  const parts = ['DISABLE_OMC=1'];
  if (wantsOneMillionContext(model)) {
    parts.push(`ANTHROPIC_BETA=${shellQuote(ONE_MILLION_BETA)}`);
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

  // GAP-2 (audit): shell-quote model + reasoning for parity with buildClaudeCmd.
  // The command string is delivered to a shell (tmux send-keys), so unquoted
  // operator-supplied values were a shell-injection / arg-splitting hazard.
  const parts = [
    CODEX_BIN,
    '-m',
    shellQuote(model),
  ];

  if (options.reasoning !== undefined) {
    parts.push('-c', shellQuote(`model_reasoning_effort="${options.reasoning}"`));
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

  if (isClaudeModelName(model)) {
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

  // GPT-5.6 family aliases (codex 0.144) — mirror of the zsh parse sites.
  // Map (not a plain object) so inherited keys like 'constructor' are never
  // mistaken for aliases.
  const GPT56_ALIASES = new Map([
    ['sol', 'gpt-5.6-sol'],
    ['terra', 'gpt-5.6-terra'],
    ['luna', 'gpt-5.6-luna'],
  ]);
  if (GPT56_ALIASES.has(model)) {
    return {
      engine: 'codex',
      model: GPT56_ALIASES.get(model),
      reasoning: level,
    };
  }

  return {
    engine: 'codex',
    model,
    reasoning: level,
  };
}
