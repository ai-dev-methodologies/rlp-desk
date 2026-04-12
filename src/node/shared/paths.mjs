import path from 'node:path';
import { fileURLToPath } from 'node:url';

const currentFile = fileURLToPath(import.meta.url);
const currentDir = path.dirname(currentFile);

export const projectRoot = path.resolve(currentDir, '..', '..', '..');

export function ensureProjectPath(targetPath) {
  const normalizedPath = path.resolve(targetPath);

  if (
    normalizedPath !== projectRoot &&
    !normalizedPath.startsWith(`${projectRoot}${path.sep}`)
  ) {
    throw new Error(`Path is outside the project root: ${targetPath}`);
  }

  return normalizedPath;
}

export function resolveProjectPath(...segments) {
  if (segments.length === 0) {
    return projectRoot;
  }

  return ensureProjectPath(path.resolve(projectRoot, ...segments));
}
