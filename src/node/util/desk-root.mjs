import path from 'node:path';

export const DEFAULT_DESK_REL = '.rlp-desk';
export const LEGACY_DESK_REL = path.join('.claude', 'ralph-desk');

export function resolveDeskRoot(rootDir, env = process.env) {
  const override = (env && typeof env.RLP_DESK_RUNTIME_DIR === 'string') ? env.RLP_DESK_RUNTIME_DIR : '';
  const trimmed = override.trim();

  if (!trimmed) {
    return path.join(rootDir, DEFAULT_DESK_REL);
  }

  if (path.isAbsolute(trimmed)) {
    throw new Error('RLP_DESK_RUNTIME_DIR must be relative to project root, not absolute');
  }

  const segments = trimmed.split(/[\\/]/);
  if (segments.includes('..')) {
    throw new Error('RLP_DESK_RUNTIME_DIR must not contain parent traversal (..)');
  }

  return path.join(rootDir, trimmed);
}
