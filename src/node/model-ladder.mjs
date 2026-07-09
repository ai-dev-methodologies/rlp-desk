// US-001: single-sourced Worker model-upgrade ladder loader (Node side).
//
// Shipped defaults live at src/node/models.json (same file the zsh loader in
// lib_ralph_desk.zsh reads via jq). Optional user override lives OUTSIDE the
// 0444 postinstall-managed tree at
// ${RLP_DESK_MODELS_FILE:-$HOME/.claude/rlp-desk-models.json}.
//
// Precedence: override -> shipped -> emergency inline (identical 3-entry
// ladder to the zsh side, cross-checked by tests/node/models-ladder.test.mjs
// and the zsh equivalence case in tests/test_us011_worker_model_upgrade.sh).
// Malformed/unreadable JSON at any layer falls through to the next layer;
// never throws. Exactly one warning is emitted per call.
//
// The JSON schema uses "" for ceiling; this loader normalizes "" -> 'BLOCKED'
// so existing callers (nextWorkerModel's `!next || next === 'BLOCKED'` check)
// keep working unchanged.

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const CEILING_SENTINEL = 'BLOCKED';

// Identical to the zsh emergency ladder (lib_ralph_desk.zsh get_next_model
// fallback branch): haiku -> sonnet -> opus -> ceiling.
export const EMERGENCY_LADDER = Object.freeze({
  haiku: 'sonnet',
  sonnet: 'opus',
  opus: CEILING_SENTINEL,
});

// Every upgrades value must be a string (empty string = ceiling). A
// non-string value (number, boolean, null, object, array) throws so the
// caller treats the WHOLE file as malformed and falls through to the next
// layer, rather than silently resolving to junk (e.g. get_next_model
// returning the string "123" for a JSON number).
function normalizeUpgrades(upgrades) {
  const normalized = {};
  for (const [key, value] of Object.entries(upgrades)) {
    if (typeof value !== 'string') {
      throw new Error(`upgrades['${key}'] must be a string, got ${typeof value}`);
    }
    normalized[key] = value === '' ? CEILING_SENTINEL : value;
  }
  return normalized;
}

// Throws on any parse/shape problem — callers treat that as "malformed".
function readJsonLadderFile(file) {
  const raw = fs.readFileSync(file, 'utf8');
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed.upgrades !== 'object' || parsed.upgrades === null || Array.isArray(parsed.upgrades)) {
    throw new Error(`'${file}' missing an 'upgrades' object`);
  }
  return normalizeUpgrades(parsed.upgrades);
}

// models.json is a sibling of this file in both the source checkout
// (src/node/model-ladder.mjs + src/node/models.json) and the installed tree
// (postinstall's copyNodeRuntime copies src/node/** recursively, preserving
// the sibling relationship).
export function defaultShippedModelsFile() {
  return path.join(path.dirname(fileURLToPath(import.meta.url)), 'models.json');
}

export function defaultOverrideModelsFile() {
  return process.env.RLP_DESK_MODELS_FILE || path.join(os.homedir(), '.claude', 'rlp-desk-models.json');
}

/**
 * @param {Object} [options]
 * @param {string} [options.overrideFile] — user override path (defaults to
 *   RLP_DESK_MODELS_FILE or ~/.claude/rlp-desk-models.json).
 * @param {string} [options.shippedFile] — shipped defaults path (defaults to
 *   models.json next to this module).
 * @param {(message: string) => void} [options.warn] — warning sink.
 * @returns {Record<string, string>} model -> next-model-or-'BLOCKED' map.
 */
export function loadModelLadder({
  overrideFile = defaultOverrideModelsFile(),
  shippedFile = defaultShippedModelsFile(),
  warn = (message) => console.error(`[model-ladder] ${message}`),
} = {}) {
  let warned = false;
  const warnOnce = (message) => {
    if (warned) return;
    warned = true;
    warn(message);
  };

  if (overrideFile && fs.existsSync(overrideFile)) {
    try {
      return readJsonLadderFile(overrideFile);
    } catch (err) {
      warnOnce(`override file '${overrideFile}' unreadable or malformed (${err.message}); falling through`);
    }
  }

  if (shippedFile && fs.existsSync(shippedFile)) {
    try {
      return readJsonLadderFile(shippedFile);
    } catch (err) {
      warnOnce(`shipped defaults '${shippedFile}' unreadable or malformed (${err.message}); falling through`);
    }
  } else {
    warnOnce(`shipped defaults not found at '${shippedFile}'; falling through`);
  }

  warnOnce('using emergency inline model ladder (haiku, sonnet, opus only)');
  return { ...EMERGENCY_LADDER };
}
