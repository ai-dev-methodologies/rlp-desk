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
