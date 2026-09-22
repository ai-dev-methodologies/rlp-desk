import { shellQuote } from '../util/shell-quote.mjs';
import { ONE_MILLION_BETA, wantsOneMillionContext } from '../constants.mjs';

const CLAUDE_BIN = 'claude';
const CODEX_BIN = 'codex';
const CLAUDE_MODELS = new Set(['haiku', 'sonnet', 'opus', 'fable']);

// Codex model aliases (spark, GPT-5.6 family, GPT-6 astra) — single module-scope
// table shared by both the colon-bearing (`model:reasoning`) and bare
// (no-colon) branches of parseModelFlag, so a bare `--worker-model astra` and
// a colon-qualified `--worker-model astra:high` classify the same alias set.
// Map (not a plain object) so inherited keys like 'constructor' are never
// mistaken for aliases. Mirror of the zsh parse sites (parse_model_flag /
// _auto_detect_engine in the .zsh scripts).
const CODEX_MODEL_ALIASES = new Map([
  ['spark', 'gpt-5.3-codex-spark'],
  ['sol', 'gpt-5.6-sol'],
  ['terra', 'gpt-5.6-terra'],
  ['luna', 'gpt-5.6-luna'],
  ['astra', 'gpt-6-astra'],
]);

// Vendor-retired codex families (gpt-5.4 / gpt-5.4-mini 2026-08-31,
// gpt-5.3-codex-spark 2026-09-14, gpt-5.5 ChatGPT-login-only from 2026-10-14).
// Their ladder keys are gone, but the ids can still arrive from a user flag,
// a saved status.json, or a user override ladder at ~/.claude/rlp-desk-models.json
// — which returns arbitrary unvalidated strings. Remap on the way in, with one
// warning, rather than failing at the vendor with an opaque error.
//
// The REMAP REWRITES ONLY THE MODEL PART, never the level. That is what makes
// it safe to remap BEFORE vocabulary validation (run.mjs validateModelFlag):
// a malformed input stays malformed, so remapping can never launder a
// rejection into an acceptance. `gpt-5.5:` remaps to `gpt-5.6-sol:` and is
// still rejected for an empty level; `gpt-5.5:high;touch x` keeps its
// injection-shaped level and is still rejected. Conversely the level IS
// re-validated against the REPLACEMENT model, which matters concretely:
// `minimal` is rejected for gpt-6-astra alone, so `gpt-5.5:minimal` correctly
// becomes the accepted `gpt-5.6-sol:minimal`.
//
// Mirrored byte-for-byte (table and warning text) by _normalize_model_spec in
// lib_ralph_desk.zsh; a parity test pins the two together.
export const RETIRED_MODEL_REMAP = new Map([
  ['gpt-5.4', 'gpt-5.6-terra'],
  ['gpt-5.4-mini', 'gpt-5.6-luna'],
  ['gpt-5.5', 'gpt-5.6-sol'],
  ['gpt-5.3-codex-spark', 'gpt-5.6-luna'],
  ['spark', 'gpt-5.6-luna'],
]);

// Bare claude aliases carry no effort, so the level falls to the claude CLI's
// own default — a value this project has never confirmed. Pin the start
// explicitly instead. haiku is absent on purpose: it has no effort concept.
// fable resolves to the version-pinned id as well as a level, matching how
// every doc and the ladder itself refer to it (`claude-fable-5-1:max`, never
// the floating alias).
export const BARE_ALIAS_NORMALIZATION = new Map([
  ['sonnet', 'sonnet:medium'],
  ['opus', 'opus:medium'],
  ['fable', 'claude-fable-5-1:max'],
  ['claude-fable-5-1', 'claude-fable-5-1:max'],
]);

// Normalizes a `model` or `model:level` spec: retired families are remapped
// (level preserved) and bare claude aliases gain their explicit start level.
// Returns the normalized spec. Any remap emits exactly one warning through
// `warn` (default: stderr), so a user who pinned a retired id learns why the
// run is using a different model.
export function normalizeModelSpec(value, { warn = (message) => process.stderr.write(`${message}\n`) } = {}) {
  if (typeof value !== 'string' || value.length === 0) {
    return value;
  }

  const colonIndex = value.indexOf(':');
  const head = colonIndex === -1 ? value : value.slice(0, colonIndex);
  const tail = colonIndex === -1 ? '' : value.slice(colonIndex);

  const replacement = RETIRED_MODEL_REMAP.get(head);
  if (replacement !== undefined) {
    const normalized = `${replacement}${tail}`;
    warn(`[model-remap] WARNING: '${value}' is retired — using '${normalized}' instead. To keep the old id (API-key logins still serve it), pin it in ~/.claude/rlp-desk-models.json.`);
    return normalized;
  }

  if (colonIndex === -1) {
    return BARE_ALIAS_NORMALIZATION.get(value) ?? value;
  }

  return value;
}

// Single source of truth for "is this BARE (no-colon) name a codex model?":
// either a known short alias (the Map above), or the real codex id shape
// itself (gpt-*). Team-lead review follow-up: an earlier fix recognized
// only the five aliases as bare codex names, so the short alias worked
// (`--worker-model astra`) but the full canonical slug this whole wave
// exists to add (`--worker-model gpt-6-astra`, exactly as it appears in
// models.json and every doc table) still fell through to claude — the
// least guessable possible state (alias fixed, real id still broken). One
// function, one call site in parseModelFlag's bare branch below.
//
// The zsh equivalents (parse_model_flag in lib_ralph_desk.zsh,
// _auto_detect_engine in run_ralph_desk.zsh) do NOT call a shared function
// like this one — they duplicate a matching `gpt-*)` case arm each, on
// purpose. _auto_detect_engine's real call sites run before its script
// sources lib_ralph_desk.zsh, so a lib-defined helper called from inside it
// would fail with "command not found" at startup. This file has no such
// sourcing-order constraint, so centralizing here is correct; do not use
// this as a reason to "helpfully" centralize the zsh side too.
function isBareCodexModelName(value) {
  return CODEX_MODEL_ALIASES.has(value) || value.startsWith('gpt-');
}

// Single source of truth for "is this bare model name a claude model?":
// the short aliases (haiku/sonnet/opus/fable — `claude --help` documents
// `fable` as an alias for the latest model, same as opus/sonnet), the bare
// `claude`, OR any full versioned claude id (claude-opus-4-8, claude-fable-5,
// claude-fable-5-1, claude-opus-4-8[1m], ...). The startsWith('claude-')
// branch also covers the bracket+effort combo (claude-opus-4-8[1m] is the
// model part of claude-opus-4-8[1m]:high). Used by both isClaudeEngine
// (which splits the flag first) and parseModelFlag so the two never drift.
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

  // US-001 (failure-modes.md F1.19): `--disable hooks` removes the oh-my-codex
  // native-hook surface, whose UserPromptSubmit keyword-detector auto-activates
  // deep-interview from prose in the campaign's own worker prompt and then
  // PreToolUse-blocks every write tool. `--disable plugins` does not cover it.
  //
  // DEAD-CODE PARITY ONLY — do NOT cite this as live coverage. run.mjs
  // hard-errors `--mode agent` (ADR-001), and `--mode tmux` shells out to
  // run_ralph_desk.zsh, so buildCodexCmd is CLI-unreachable. The shipping
  // implementation is the zsh probe + `_codex_launch_with_hook_fallback`
  // chokepoint.
  //
  // Emitted UNCONDITIONALLY with no probe: CODEX_BIN here is a bare 'codex'
  // resolved from PATH inside the pane, while the zsh leader probes the
  // absolute path from `command -v codex` — a Node-side probe would therefore
  // interrogate a different binary than the one that runs.
  parts.push('--disable', 'plugins', '--disable', 'hooks', '--dangerously-bypass-approvals-and-sandbox');

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

    // Bare (no-colon) name: check isBareCodexModelName (known alias OR
    // gpt-* id shape) BEFORE defaulting to claude. Previously this branch
    // returned `engine: 'claude'` unconditionally, so `--worker-model astra`
    // was silently misclassified as claude, and a follow-up fix that only
    // checked the alias table left the real canonical id
    // (`--worker-model gpt-6-astra`) STILL misclassified — the least
    // guessable possible state (alias works, real id does not). Both cases
    // are now one predicate, one call site. `isClaudeEngine()` already got
    // the alias case right (it checks `isClaudeModelName` on the pre-colon
    // head regardless of whether a colon is present); this branch is now
    // consistent with it for every bare codex name, alias or real id. A
    // bare codex name carries no reasoning value — `reasoning` is left
    // undefined, and buildCodexCmd already treats that as "omit -c". Any
    // OTHER unrecognized bare name still defaults to claude (the documented
    // fallback, unchanged and still tested below).
    if (isBareCodexModelName(value)) {
      return {
        engine: 'codex',
        model: CODEX_MODEL_ALIASES.get(value) ?? value,
      };
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

  if (CODEX_MODEL_ALIASES.has(model)) {
    return {
      engine: 'codex',
      model: CODEX_MODEL_ALIASES.get(model),
      reasoning: level,
    };
  }

  return {
    engine: 'codex',
    model,
    reasoning: level,
  };
}
