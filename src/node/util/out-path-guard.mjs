// Shared --out guard for read/report commands (trend, mutation): the destination
// may never land inside ANY `.rlp-desk/plans` directory, because plans/ holds the
// sealed PRD and test-spec (the gate-receipt lane). Checked on:
//   - the lexical path and the real path (realpath of the deepest existing
//     ancestor, so a symlinked parent cannot smuggle the write in);
//   - a component-aware `.rlp-desk/plans` match (case-insensitive, so it also
//     covers a campaign root other than the current one, e.g. `../../.rlp-desk/plans`);
//   - the configured plans dir of every base dir given (cwd and --project-dir).
// A destination that is itself a symlink is refused (it could point into plans/).
//
// Check-then-write: the tool run between "validate --out" and "write --out" can take
// minutes, so the destination is NEVER written in place. writeFileSafely()/
// writeGuardedOut() re-run the policy immediately before the write and commit with
// temp-file + rename in the same directory: rename replaces a destination symlink
// instead of following it, the temp file is created O_EXCL|O_NOFOLLOW, and the
// parent directory identity (dev+ino of its realpath) must be unchanged.
// Remaining ceiling (documented, not defended): Node has no openat()/renameat(), so a
// directory component swapped between the last re-check and the rename() call (a window of
// sub-millisecond to a few milliseconds), by a process running as the same user, can still
// redirect the rename. A post-rename self-check narrows the damage: the destination must be
// our temp file (same dev+ino) and the parent identity unchanged, otherwise our file is
// unlinked (only if it is ours) and the write fails. A hard link to a sealed file is replaced
// (the link is broken), never written through.

import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import { constants as fsConstants } from 'node:fs';
import path from 'node:path';

import { resolveDeskRoot } from './desk-root.mjs';

export class OutPathError extends Error {}

async function realLocation(target) {
  const rest = [];
  let current = target;
  for (;;) {
    try {
      return path.join(await fs.realpath(current), ...rest.reverse());
    } catch (error) {
      if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
      const parent = path.dirname(current);
      if (parent === current) return target;
      rest.push(path.basename(current));
      current = parent;
    }
  }
}

const lower = (p) => p.split(path.sep).map((part) => part.toLowerCase());

function hasPlansComponents(p) {
  const parts = lower(p);
  return parts.some((part, i) => part === '.rlp-desk' && parts[i + 1] === 'plans');
}

export function isInsideDir(dir, file) {
  const rel = path.relative(dir.toLowerCase(), file.toLowerCase());
  return rel === '' || (rel !== '..' && !rel.startsWith(`..${path.sep}`) && !path.isAbsolute(rel));
}

// Returns the absolute destination, or throws OutPathError. `baseDir` resolves a
// relative `outArg`; every dir in `deskBases` has its desk's plans/ checked.
export async function resolveGuardedOutPath(outArg, { baseDir, deskBases, env }) {
  const dest = path.resolve(baseDir, outArg);
  try {
    if ((await fs.lstat(dest)).isSymbolicLink()) {
      throw new OutPathError(`--out ${JSON.stringify(outArg)} is a symlink; refusing to write through it`);
    }
  } catch (error) {
    if (error instanceof OutPathError) throw error;
    if (error.code !== 'ENOENT' && error.code !== 'ENOTDIR') throw error;
  }
  const real = await realLocation(dest);
  const planDirs = [];
  for (const base of new Set(deskBases)) {
    const plans = path.join(resolveDeskRoot(base, env ?? process.env), 'plans');
    planDirs.push(plans, await realLocation(plans));
  }
  const bad = [dest, real].some((p) => hasPlansComponents(p) || planDirs.some((dir) => isInsideDir(dir, p)));
  if (bad) {
    throw new OutPathError(`--out ${JSON.stringify(outArg)} resolves into a .rlp-desk/plans directory (the sealed PRD/test-spec lane); choose another path`);
  }
  return dest;
}

// Atomic, symlink-safe replace of `dest` (its parent directory must exist).
//   recheck(finalPath)  async policy hook, throws to refuse; runs after the temp file is
//                       written and the parent identity is confirmed, right before rename.
//   afterTempWrite()    test seam: runs after the temp file is written, before the checks.
//   afterRename()       test seam: runs right after the rename, before the self-check.
// An existing regular destination keeps its permission bits.
export async function writeFileSafely(dest, content, { recheck, afterTempWrite, afterRename } = {}) {
  const realDir = await fs.realpath(path.dirname(dest));
  const before = await fs.stat(realDir);
  const finalPath = path.join(realDir, path.basename(dest));
  const tmp = path.join(realDir, `.${path.basename(dest)}.${process.pid}.${crypto.randomBytes(6).toString('hex')}.tmp`);
  const flags = fsConstants.O_WRONLY | fsConstants.O_CREAT | fsConstants.O_EXCL | (fsConstants.O_NOFOLLOW ?? 0);
  // 0o666: the kernel applies the umask, so a new file gets the permissions any other new file would.
  let handle = await fs.open(tmp, flags, 0o666);
  try {
    let mode = null;
    try {
      const existing = await fs.lstat(finalPath);
      if (existing.isFile()) mode = existing.mode & 0o777;
    } catch { /* new file */ }
    await handle.writeFile(content, 'utf8');
    if (mode !== null) await handle.chmod(mode); // replacing: keep the existing permissions
    await handle.sync();
    const written = await handle.stat();
    await handle.close();
    handle = null;
    if (afterTempWrite) await afterTempWrite();
    const after = await fs.stat(await fs.realpath(path.dirname(dest)));
    if (after.dev !== before.dev || after.ino !== before.ino) {
      throw new OutPathError(`refusing to write ${JSON.stringify(dest)}: the parent directory changed while the file was being prepared`);
    }
    if (recheck) await recheck(finalPath);
    await fs.rename(tmp, finalPath);
    if (afterRename) await afterRename();
    // Post-rename self-check: the destination must be our file and the parent the one we prepared in.
    const landed = await fs.lstat(finalPath).catch(() => null);
    const parentNow = await fs.stat(await fs.realpath(path.dirname(dest)).catch(() => realDir)).catch(() => null);
    const ours = landed !== null && landed.isFile() && landed.dev === written.dev && landed.ino === written.ino;
    if (!ours || parentNow === null || parentNow.dev !== before.dev || parentNow.ino !== before.ino) {
      if (ours) await fs.unlink(finalPath).catch(() => {});
      throw new OutPathError(`refusing ${JSON.stringify(dest)}: the destination or its parent changed during the final rename${ours ? '; the written file was removed' : ''}`);
    }
  } catch (error) {
    if (handle) await handle.close().catch(() => {});
    await fs.rm(tmp, { force: true }).catch(() => {});
    throw error;
  }
}

// --out writer: validates, creates the parent, validates again against the real
// directory, then commits via writeFileSafely with a final re-validation.
export async function writeGuardedOut(outArg, content, ctx, { createParent = true, afterTempWrite } = {}) {
  const dest = await resolveGuardedOutPath(outArg, ctx);
  if (createParent) await fs.mkdir(path.dirname(dest), { recursive: true });
  await resolveGuardedOutPath(dest, ctx); // parent may have been swapped before mkdir/realpath
  await writeFileSafely(dest, content, { afterTempWrite, recheck: (finalPath) => resolveGuardedOutPath(finalPath, ctx) });
  return dest;
}
