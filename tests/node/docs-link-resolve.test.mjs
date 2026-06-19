import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// COMP-3 regression guard: shipped files referenced docs/multi-mission-orchestration.md
// while the doc actually ships at docs/rlp-desk/multi-mission-orchestration.md, making
// the link dead on every fresh install. This deterministic lint scans the known shipped
// files for any `docs/...md` reference and asserts each resolves to a real file from the
// repo root. Scope is intentionally limited to these files (not a whole-repo scan) to
// keep the check focused and flake-free.

const testFile = fileURLToPath(import.meta.url);
const repoRoot = path.resolve(path.dirname(testFile), '..', '..');

// Files that embed user-facing docs links and ship to fresh installs.
const SHIPPED_FILES = [
  'src/governance.md',
  'src/scripts/init_ralph_desk.zsh',
  'src/node/runner/campaign-main-loop.mjs',
  'docs/rlp-desk/protocol-reference.md',
];

// Matches a `docs/.../<name>.md` reference in prose, code comments, or backticks.
// Lazy body + `.md` terminator stops cleanly before trailing punctuation (e.g. ".md.").
const DOCS_LINK_RE = /\bdocs\/[A-Za-z0-9._/-]+?\.md\b/g;

for (const relFile of SHIPPED_FILES) {
  test(`docs links resolve in ${relFile}`, () => {
    const absFile = path.join(repoRoot, relFile);
    const content = fs.readFileSync(absFile, 'utf8');
    const links = [...content.matchAll(DOCS_LINK_RE)].map((m) => m[0]);

    for (const link of links) {
      const resolved = path.join(repoRoot, link);
      assert.ok(
        fs.existsSync(resolved),
        `${relFile} references "${link}" which does not resolve to an existing file ` +
          `(expected at ${path.relative(repoRoot, resolved)})`,
      );
    }
  });
}
