// v5.7 §4.11.c — Leader-only cross-project campaign registry.
//
// Worker/Verifier/Flywheel/Guard prompts MUST NEVER reference this file. Only
// the Leader (slash-command-tier process) appends one line per campaign-state-change.
// /rlp-desk status (slug-less) reads this file and dereferences each project_root
// to read that project's local analytics. Append-only — no in-place edits, no
// compaction. Stale entries (project_root no longer exists) are tolerated by
// the status reader.
//
// Path: ~/.claude/ralph-desk/registry.jsonl
//
// CI lint (v5.7 §4.11.c guardrail): run
//   grep -rn 'registry\.jsonl' src/commands src/scripts src/node | grep -v Leader
// must return empty (only Leader-tier code references this path).

import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const REGISTRY_PATH = path.join(os.homedir(), '.claude', 'ralph-desk', 'registry.jsonl');

export function getRegistryPath() {
  return REGISTRY_PATH;
}

/**
 * Append a JSONL entry for a campaign state change. Idempotent on errors:
 * silently swallow filesystem failures (registry is best-effort observability,
 * not load-bearing). The Leader's `--add-dir "$HOME/.claude/ralph-desk"` permits
 * the write without TUI prompts.
 *
 * @param {Object} entry — fields documented inline.
 *   @param {string} entry.slug
 *   @param {string} entry.projectRoot
 *   @param {'running'|'complete'|'blocked'|'aborted'} entry.status
 *   @param {string} [entry.workerModel]
 *   @param {string} [entry.verifierModel]
 *   @param {string} [entry.note]
 */
export async function appendRegistryEntry(entry) {
  const line = JSON.stringify({
    ts: new Date().toISOString(),
    slug: entry.slug,
    project_root: entry.projectRoot,
    status: entry.status,
    ...(entry.workerModel ? { worker_model: entry.workerModel } : {}),
    ...(entry.verifierModel ? { verifier_model: entry.verifierModel } : {}),
    ...(entry.note ? { note: entry.note } : {}),
  }) + '\n';

  try {
    await fs.mkdir(path.dirname(REGISTRY_PATH), { recursive: true });
    await fs.appendFile(REGISTRY_PATH, line, 'utf8');
  } catch {
    // Registry is best-effort. A failure here must NOT abort the campaign.
    // The campaign's project-local analytics remain authoritative.
  }
}

/**
 * Read all registry entries. Each line is a JSON object; malformed lines are
 * skipped. Returns most recent state per slug (last-write-wins on slug+project).
 */
export async function readRegistry() {
  let raw;
  try {
    raw = await fs.readFile(REGISTRY_PATH, 'utf8');
  } catch {
    return [];
  }
  const entries = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      // Skip malformed lines; do not abort.
    }
  }
  return entries;
}

/**
 * Dereference each entry's project_root and check whether it still exists.
 * Used by /rlp-desk status to mark stale entries (worktree removed, etc.).
 */
export async function annotateStaleness(entries) {
  const annotated = [];
  for (const entry of entries) {
    let stale = false;
    try {
      const stat = await fs.stat(entry.project_root);
      if (!stat.isDirectory()) stale = true;
    } catch {
      stale = true;
    }
    annotated.push({ ...entry, stale });
  }
  return annotated;
}
