// v5.7 §4.6 — 4-category structured debug log (telemetry parity with zsh).
//
// zsh runner emits 67 lines tagged [GOV] / [DECIDE] / [OPTION] / [FLOW] to
// debug.log; Node leader had zero. This helper provides the structured
// emission API. Call sites are ported incrementally — every new code path
// SHOULD use debugLog() instead of console/manual writes.
//
// Categories (governance §1f traceability):
// - GOV   : governance enforcement (IL, CB triggers, scope locks, verdicts)
// - DECIDE: leader decisions (model selection, fix contracts, escalation)
// - OPTION: configuration snapshot at loop start
// - FLOW  : execution progress (worker/verifier dispatch, signal reads, transitions)

import fs from 'node:fs/promises';
import path from 'node:path';

const VALID_CATEGORIES = new Set(['GOV', 'DECIDE', 'OPTION', 'FLOW']);

/**
 * Append a structured log line to debug.log. Format mirrors zsh log_debug:
 *   [YYYY-MM-DD HH:MM:SS] [CATEGORY] key=value key=value ...
 *
 * @param {Object} args
 * @param {string} args.debugLogPath — absolute path to debug.log
 * @param {'GOV'|'DECIDE'|'OPTION'|'FLOW'} args.category
 * @param {Object<string,string|number|boolean>} args.fields — flat key/value
 *   pairs, serialized as `key=value`. Avoid nested objects; pre-stringify.
 * @returns {Promise<void>} — resolves even on filesystem errors (best-effort).
 */
export async function debugLog({ debugLogPath, category, fields }) {
  if (!debugLogPath || !VALID_CATEGORIES.has(category)) return;
  const ts = new Date().toISOString().replace('T', ' ').slice(0, 19);
  const flat = Object.entries(fields ?? {})
    .map(([k, v]) => `${k}=${formatValue(v)}`)
    .join(' ');
  const line = `[${ts}] [${category}] ${flat}\n`;
  try {
    await fs.mkdir(path.dirname(debugLogPath), { recursive: true });
    await fs.appendFile(debugLogPath, line, 'utf8');
  } catch {
    // Best-effort: never abort the campaign for a debug log write failure.
  }
}

function formatValue(v) {
  if (v === null || v === undefined) return 'null';
  if (typeof v === 'string' && /[\s=]/.test(v)) return JSON.stringify(v);
  return String(v);
}

/**
 * Convenience: bind debugLogPath so callers get a per-campaign logger.
 */
export function makeDebugLogger(debugLogPath) {
  return (category, fields) => debugLog({ debugLogPath, category, fields });
}
