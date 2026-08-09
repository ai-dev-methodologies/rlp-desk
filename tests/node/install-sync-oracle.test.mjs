// Install-sync oracle (scripts/verify-install-sync.js) + the repo-hygiene rule
// that keeps it honest.
//
// Regression context (2026-08-10): the previous oracle stripped the install
// banner with `grep -v` and diffed the remainder. `grep` treats any file
// containing a NUL byte as binary and prints nothing, so
// src/node/util/gate-receipt.mjs (which carried two raw NUL bytes) verified as
// an EMPTY body — a permanent false FAIL that invited someone to loosen the
// check and thereby mask real drift. These tests pin both halves of the fix:
// the oracle must be byte-exact (never text-parsing), and no source file may
// carry a raw NUL byte again.

import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const verifier = require(path.join(repoRoot, 'scripts', 'verify-install-sync.js'));
const manifest = require(path.join(repoRoot, 'scripts', 'install-manifest.js'));

const { expectedInstalledBytes, verifyOne, runVerification } = verifier;

function tempDir(t, prefix) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  t.after(() => {
    // Installed files are 0o444; unlock before removal or rmSync hits EACCES.
    try {
      execFileSync('chmod', ['-R', 'u+w', dir]);
    } catch {
      /* best effort */
    }
    fs.rmSync(dir, { recursive: true, force: true });
  });
  return dir;
}

// ---------------------------------------------------------------------------
// expectedInstalledBytes — exact inverse of postinstall's banner injection
// ---------------------------------------------------------------------------

test('oracle: markdown banner is prepended as an HTML comment', () => {
  const source = Buffer.from('# Title\n\nbody\n');
  const out = expectedInstalledBytes(source, 'src/governance.md');
  assert.match(out.subarray(0, 200).toString('utf8'), /^<!-- DO NOT EDIT — generated from src\/governance\.md\./);
  assert.ok(out.subarray(out.length - source.length).equals(source));
});

test('oracle: shebang scripts keep line 1 and take the banner on line 2', () => {
  const source = Buffer.from('#!/usr/bin/env zsh\nsetopt err_exit\n');
  const out = expectedInstalledBytes(source, 'src/scripts/run_ralph_desk.zsh');
  const lines = out.toString('utf8').split('\n');
  assert.equal(lines[0], '#!/usr/bin/env zsh');
  assert.match(lines[1], /^# DO NOT EDIT — generated from src\/scripts\/run_ralph_desk\.zsh\./);
  assert.equal(lines[2], 'setopt err_exit');
});

test('oracle: unknown extensions get no banner (chmod-only files)', () => {
  const source = Buffer.from('{"a":1}\n');
  const out = expectedInstalledBytes(source, 'src/node/data.json');
  assert.ok(out.equals(source));
});

test('oracle: NUL bytes survive byte-exactly (the grep false-FAIL regression)', () => {
  // A source file containing raw NUL is the exact input that made the old
  // grep-based oracle emit an empty body. Byte reconstruction must be immune.
  const source = Buffer.concat([
    Buffer.from('const k = `a'),
    Buffer.from([0x00]),
    Buffer.from('b'),
    Buffer.from([0x00]),
    Buffer.from('c`;\n'),
  ]);
  const out = expectedInstalledBytes(source, 'src/node/util/nul.mjs');
  assert.equal(out.filter((b) => b === 0x00).length, 2, 'NUL bytes must be preserved');
  assert.ok(out.subarray(out.length - source.length).equals(source));
});

// ---------------------------------------------------------------------------
// verifyOne — pass / drift / missing / banner tampering
// ---------------------------------------------------------------------------

function writePair(dir, relative, sourceBytes) {
  const sourcePath = path.join(dir, 'src-' + path.basename(relative));
  const targetPath = path.join(dir, 'installed-' + path.basename(relative));
  fs.writeFileSync(sourcePath, sourceBytes);
  fs.writeFileSync(targetPath, expectedInstalledBytes(sourceBytes, relative));
  fs.chmodSync(targetPath, 0o444);
  return { sourcePath, targetPath };
}

test('verifyOne: a correctly installed file reports no failures', (t) => {
  const dir = tempDir(t, 'rlp-oracle-ok-');
  const body = Buffer.concat([Buffer.from('x'), Buffer.from([0x00]), Buffer.from('y\n')]);
  const { sourcePath, targetPath } = writePair(dir, 'src/node/util/nul.mjs', body);
  const result = verifyOne(sourcePath, 'src/node/util/nul.mjs', targetPath, {});
  assert.deepEqual(result.failures, []);
});

test('verifyOne: a single flipped byte in the body is caught', (t) => {
  const dir = tempDir(t, 'rlp-oracle-drift-');
  const { sourcePath, targetPath } = writePair(dir, 'src/governance.md', Buffer.from('alpha\n'));
  fs.chmodSync(targetPath, 0o644);
  const tampered = fs.readFileSync(targetPath);
  tampered[tampered.length - 2] = 0x41; // 'a' -> 'A' in the body, same length
  fs.writeFileSync(targetPath, tampered);
  fs.chmodSync(targetPath, 0o444);
  const result = verifyOne(sourcePath, 'src/governance.md', targetPath, {});
  assert.equal(result.failures.length, 1);
  assert.match(result.failures[0], /^DRIFT/);
});

test('verifyOne: a missing or banner-stripped install is caught', (t) => {
  const dir = tempDir(t, 'rlp-oracle-banner-');
  const source = Buffer.from('alpha\n');
  const { sourcePath, targetPath } = writePair(dir, 'src/governance.md', source);

  fs.chmodSync(targetPath, 0o644);
  fs.writeFileSync(targetPath, source); // banner removed
  fs.chmodSync(targetPath, 0o444);
  assert.match(verifyOne(sourcePath, 'src/governance.md', targetPath, {}).failures[0], /^DRIFT/);

  fs.chmodSync(targetPath, 0o644);
  fs.rmSync(targetPath);
  assert.match(verifyOne(sourcePath, 'src/governance.md', targetPath, {}).failures[0], /^MISSING/);
});

test('verifyOne: chmod is a warning by default and a failure under --strict-chmod', (t) => {
  const dir = tempDir(t, 'rlp-oracle-chmod-');
  const { sourcePath, targetPath } = writePair(dir, 'src/governance.md', Buffer.from('alpha\n'));
  fs.chmodSync(targetPath, 0o644);

  const lenient = verifyOne(sourcePath, 'src/governance.md', targetPath, {});
  assert.deepEqual(lenient.failures, []);
  assert.equal(lenient.warnings.length, 1);

  const strict = verifyOne(sourcePath, 'src/governance.md', targetPath, { strictChmod: true });
  assert.equal(strict.failures.length, 1);
  assert.match(strict.failures[0], /^CHMOD/);
});

// ---------------------------------------------------------------------------
// End-to-end: real postinstall into a throwaway HOME, then verify
// ---------------------------------------------------------------------------

test('end-to-end: a real install of this repo verifies clean, and drift is caught', (t) => {
  const fakeHome = tempDir(t, 'rlp-oracle-home-');
  execFileSync(process.execPath, [path.join(repoRoot, 'scripts', 'postinstall.js')], {
    env: { ...process.env, HOME: fakeHome },
    stdio: 'pipe',
  });

  const options = { home: fakeHome, pkgDir: repoRoot, strictChmod: false };
  const clean = runVerification(options);
  assert.deepEqual(clean.failures, [], 'a freshly installed tree must verify clean');
  assert.ok(clean.checked > 40, `expected a substantial install set, got ${clean.checked}`);

  // The NUL-carrying module must be part of what was proven clean — this is
  // the file the old grep oracle could not read at all.
  const nodeDir = manifest.installLayout(fakeHome).nodeDir;
  const gateReceipt = path.join(nodeDir, 'util', 'gate-receipt.mjs');
  assert.ok(fs.existsSync(gateReceipt), 'gate-receipt.mjs must be installed');

  // Positive control: mutate one installed byte -> exactly one DRIFT.
  fs.chmodSync(gateReceipt, 0o644);
  fs.appendFileSync(gateReceipt, '\n');
  fs.chmodSync(gateReceipt, 0o444);
  const drifted = runVerification(options);
  assert.equal(drifted.failures.length, 1);
  assert.match(drifted.failures[0], /^DRIFT.*gate-receipt\.mjs/);

  // Orphan control: an installed file with no source counterpart is drift.
  fs.chmodSync(gateReceipt, 0o644);
  fs.writeFileSync(gateReceipt, fs.readFileSync(gateReceipt).subarray(0, -1));
  fs.chmodSync(gateReceipt, 0o444);
  const orphanPath = path.join(nodeDir, 'util', 'left-behind-from-old-version.mjs');
  fs.writeFileSync(orphanPath, '// stale\n');
  const orphaned = runVerification(options);
  assert.equal(orphaned.failures.length, 1);
  assert.match(orphaned.failures[0], /^ORPHAN.*left-behind-from-old-version\.mjs/);
});

// ---------------------------------------------------------------------------
// Repo hygiene: no raw NUL bytes in source
// ---------------------------------------------------------------------------

test('repo hygiene: no tracked source file contains a raw NUL byte', () => {
  // A raw NUL turns a text file into "binary" for grep, diff, and every
  // grep-backed code search — the definition line of a symbol in such a file
  // is invisible to `grep -n`. Use the `\0` escape in string literals instead.
  const roots = ['src', 'scripts', 'tests'];
  const offenders = [];

  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) continue;
      if (entry.isDirectory()) {
        if (entry.name === 'node_modules' || entry.name === 'fixtures') continue;
        walk(abs);
        continue;
      }
      if (!entry.isFile()) continue;
      if (!/\.(mjs|js|cjs|json|md|zsh|sh)$/.test(entry.name)) continue;
      if (fs.readFileSync(abs).includes(0x00)) {
        offenders.push(path.relative(repoRoot, abs));
      }
    }
  };

  for (const root of roots) {
    const abs = path.join(repoRoot, root);
    if (fs.existsSync(abs)) walk(abs);
  }
  assert.deepEqual(offenders, [], `raw NUL bytes found — use the \\0 escape instead: ${offenders.join(', ')}`);
});
