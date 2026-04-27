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
