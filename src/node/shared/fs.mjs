import fs from 'node:fs/promises';
import path from 'node:path';

import { ensureProjectPath } from './paths.mjs';

export async function writeFileAtomic(targetPath, content) {
  const normalizedTargetPath = ensureProjectPath(targetPath);
  const targetDirectory = path.dirname(normalizedTargetPath);
  const tmpPath = path.join(
    targetDirectory,
    `.${path.basename(normalizedTargetPath)}.${process.pid}.${Date.now()}.tmp`,
  );

  await fs.mkdir(targetDirectory, { recursive: true });

  try {
    await fs.writeFile(tmpPath, content);
    await fs.rename(tmpPath, normalizedTargetPath);
  } catch (error) {
    await fs.rm(tmpPath, { force: true });
    throw error;
  }
}

// v5.7 §4.24 — first-writer-wins sentinel write (BLOCKED/COMPLETE).
// Distinct from `writeFileAtomic` (last-writer-wins via rename): sentinels
// must NOT be overwritten once any path has classified the campaign outcome.
// Multiple race-prone error paths in `runCampaign()` (worker exit, verifier
// timeout, malformed signal, leader crash backstop) can fire concurrently;
// O_EXCL guarantees exactly one writes.
//
// IMPORTANT: this primitive intentionally does NOT call `ensureProjectPath`.
// Sentinels are written under the CAMPAIGN root (e.g. `/tmp/user-project/.
// claude/ralph-desk/memos/`), which is independent of the rlp-desk source
// repo. Path validation is the caller's responsibility (run() resolves
// rootDir from options.rootDir or process.cwd()).
//
// Returns:
//   { wrote: true } — this caller wrote the sentinel
//   { wrote: false, reason: 'already_exists' } — another path already wrote
//   throws on filesystem errors other than EEXIST
export async function writeSentinelExclusive(targetPath, content) {
  const resolvedPath = path.resolve(targetPath);
  const targetDirectory = path.dirname(resolvedPath);
  await fs.mkdir(targetDirectory, { recursive: true });
  let handle;
  try {
    handle = await fs.open(resolvedPath, 'wx');
  } catch (error) {
    if (error && error.code === 'EEXIST') {
      return { wrote: false, reason: 'already_exists' };
    }
    throw error;
  }
  try {
    await handle.writeFile(content);
  } finally {
    await handle.close();
  }
  return { wrote: true };
}

// Bug #7 Fix-R: best-effort chmod 0o444 to freeze a sentinel file once the
// leader has accepted it. Mirror of scripts/postinstall.js tryLockFile (L104).
// Some filesystems silently ignore chmod (WSL1/NTFS, tmpfs); we log once and
// continue. Q (process kill) is the primary defense; R is defense-in-depth.
let _sentinelLockWarningEmitted = false;
export async function lockSentinelFile(filePath, { log = (msg) => console.error(msg) } = {}) {
  try {
    await fs.chmod(filePath, 0o444);
  } catch (err) {
    if (err && err.code === 'ENOENT') {
      // File missing is not an error — sentinel may have been consumed and
      // unlinked by a concurrent path. Idempotent no-op.
      return;
    }
    if (!_sentinelLockWarningEmitted) {
      log(`[bug7] chmod 0444 on ${filePath} failed (${err?.code ?? 'unknown'}); post-sentinel write-protection unavailable on this FS.`);
      _sentinelLockWarningEmitted = true;
    }
  }
}

// Pair to lockSentinelFile. Called before fs.unlink in iter-cleanup paths so
// subsequent atomic-rename writes never see EACCES on the destination mode.
// Idempotent — missing file or already-writable is fine.
export async function unlockSentinelFile(filePath) {
  try {
    await fs.chmod(filePath, 0o644);
  } catch {
    // best-effort; cleanup proceeds regardless.
  }
}

// PR-0b-narrow (Plan v6) — stamp leader handshake ack onto an already-locked
// sentinel. Best-effort, audit-only: the contract is "if we can write, do; if
// not, swallow". Callers must NOT depend on the ack landing for hard ordering
// semantics (use waitForProcessExit + the chmod 0o444 lock for that). The
// resulting `content.leader_ack` is auxiliary metadata so post-mortem audits
// can prove which Leader iteration consumed which sentinel.
//
// Sequence (mirrored in src/scripts/lib_ralph_desk.zsh::_stamp_ack_field):
//   1. chmod 0o644 (so we can write — sentinel was locked by lockSentinelFile)
//   2. JSON.parse
//   3. merge ack as content.leader_ack
//   4. atomic write
//   5. chmod 0o444 (re-lock)
//
// All steps wrapped in try/catch; any failure is silently dropped. Failure
// modes that we deliberately swallow:
//   - File missing (sentinel was unlinked by a concurrent path).
//   - Malformed JSON (race with a partial-write window — Bug #7 already gates
//     this on the read side, but stampAckField may still observe it during
//     transitional iterations).
//   - chmod ENOTSUP / WSL1 / NTFS (recorded in Bug #7 fixes).
export async function stampAckField(filePath, ack, { log = (msg) => console.error(msg) } = {}) {
  try {
    await fs.chmod(filePath, 0o644);
  } catch (err) {
    if (err && err.code === 'ENOENT') return; // sentinel gone — nothing to stamp
    // chmod failure is non-fatal — try the write anyway in case the FS already allows it
  }
  let content;
  try {
    const raw = await fs.readFile(filePath, 'utf8');
    content = JSON.parse(raw);
  } catch (err) {
    log(`[stamp-ack] read/parse failed for ${filePath} (${err?.code ?? err?.message ?? 'unknown'}); ack dropped (audit-only)`);
    // Re-lock if possible — best-effort.
    try { await fs.chmod(filePath, 0o444); } catch {}
    return;
  }
  if (!content || typeof content !== 'object') {
    try { await fs.chmod(filePath, 0o444); } catch {}
    return;
  }
  content.leader_ack = ack;
  try {
    await fs.writeFile(filePath, `${JSON.stringify(content, null, 2)}\n`, 'utf8');
  } catch (err) {
    log(`[stamp-ack] write failed for ${filePath} (${err?.code ?? err?.message ?? 'unknown'}); ack dropped`);
  }
  try { await fs.chmod(filePath, 0o444); } catch {}
}
