// D-27: `run.mjs init` delegates to init_ralph_desk.zsh (symmetric with run's
// --mode tmux → run_ralph_desk.zsh delegation). The previous node initCampaign
// path baked a 1-line PLACEHOLDER verifier prompt, so a CLI init→run polled
// forever for a verdict the prompt never told the verifier to write. These tests
// pin the delegation: the zsh init runner is invoked with the right
// slug/objective mapping, option-looking objective words are preserved (codex
// P2), ROOT is pinned to deps.cwd (codex P2), missing runner is a loud error,
// and --help / exit-code passthrough behave.
import test from 'node:test';
import assert from 'node:assert/strict';

const FAKE_INIT = '/fake/.claude/ralph-desk/init_ralph_desk.zsh';

async function runInitMain(argv, { exists = true, initRc = 0, cwd = '/tmp/d27-workdir' } = {}) {
  const { main } = await import('../../src/node/run.mjs');
  const out = { data: '', write(v) { this.data += v; } };
  const err = { data: '', write(v) { this.data += v; } };
  let captured = null;
  const code = await main(argv, {
    cwd,
    stdout: out,
    stderr: err,
    zshInitPath: () => FAKE_INIT,
    fileExists: (p) => exists && p === FAKE_INIT,
    spawnZshInit: (initPath, initArgs, env, spawnCwd) => {
      captured = { initPath, initArgs, env, cwd: spawnCwd };
      return initRc;
    },
  });
  return { code, out: out.data, err: err.data, captured };
}

test('D-27: init delegates to the zsh init runner with [slug, objective]', async () => {
  const { code, captured } = await runInitMain(['init', 'f6mini', 'minimal task model']);
  assert.equal(code, 0);
  assert.ok(captured, 'spawnZshInit must be invoked');
  assert.equal(captured.initPath, FAKE_INIT);
  assert.deepEqual(captured.initArgs, ['f6mini', 'minimal task model']);
  assert.equal(captured.cwd, '/tmp/d27-workdir');
});

test('D-27: multi-word objective without quotes is joined into one arg', async () => {
  const { captured } = await runInitMain(['init', 'slug', 'a', 'b', 'c']);
  // The zsh `*) OBJECTIVE="$1"` case keeps only the LAST positional, so the
  // objective must arrive as a single joined arg, not three words.
  assert.deepEqual(captured.initArgs, ['slug', 'a b c']);
});

test('D-27 (codex P2): option-looking objective words are PRESERVED, not split into flags', async () => {
  // A single joined objective string never exactly matches a --flag token, so the
  // zsh catch-all keeps the whole prose instead of mis-reading `--help` as a flag.
  const a = await runInitMain(['init', 'slug', 'support', '--help', 'output']);
  assert.deepEqual(a.captured.initArgs, ['slug', 'support --help output']);
  // Even an init-known flag word in prose stays in the objective (not consumed).
  const b = await runInitMain(['init', 'slug', 'use', '--mode', 'flag']);
  assert.deepEqual(b.captured.initArgs, ['slug', 'use --mode flag']);
});

test('D-27 (codex P2): ROOT is pinned to deps.cwd, overriding any ambient $ROOT', async () => {
  const { captured } = await runInitMain(['init', 'slug', 'obj'], { cwd: '/tmp/real-cwd' });
  assert.equal(captured.env.ROOT, '/tmp/real-cwd');
  assert.equal(captured.cwd, '/tmp/real-cwd');
});

test('D-27 (codex P2): invalid RLP_DESK_RUNTIME_DIR override is rejected before delegating', async () => {
  const saved = process.env.RLP_DESK_RUNTIME_DIR;
  for (const bad of ['/abs/outside', '../escape']) {
    process.env.RLP_DESK_RUNTIME_DIR = bad;
    try {
      const { code, captured } = await runInitMain(['init', 'slug', 'obj']);
      assert.equal(code, 1, `"${bad}" must be rejected`);
      assert.equal(captured, null, 'must not spawn with an out-of-tree runtime dir');
    } finally {
      if (saved === undefined) delete process.env.RLP_DESK_RUNTIME_DIR;
      else process.env.RLP_DESK_RUNTIME_DIR = saved;
    }
  }
});

test('D-27 (codex P2): a path-traversal slug is normalized before delegating', async () => {
  // init_ralph_desk.zsh interpolates $SLUG into paths with no validation, so a
  // raw `../../outside` must be sanitized first to stay inside the .rlp-desk tree.
  const { captured } = await runInitMain(['init', '../../outside', 'obj']);
  assert.equal(captured.initArgs[0], 'outside');
  assert.ok(!captured.initArgs[0].includes('/'), 'no path separators survive');
  assert.ok(!captured.initArgs[0].includes('..'), 'no .. survives');
});

test('D-27 (codex P2): slug with spaces/caps is normalized to a safe kebab slug', async () => {
  const { captured } = await runInitMain(['init', 'My Cool Slug', 'obj']);
  assert.equal(captured.initArgs[0], 'my-cool-slug');
});

test('D-27 (codex P3): objective starting with an exact init flag is rejected, not silently corrupted', async () => {
  for (const obj of ['--mode=fresh', '--verify-mode', '--mode improve']) {
    const { code, err, captured } = await runInitMain(['init', 'slug', ...obj.split(' ')]);
    assert.equal(code, 1, `"${obj}" must be rejected`);
    assert.equal(captured, null, 'must not spawn on a flag-shaped objective');
    assert.match(err, /init flag token/);
  }
});

test('D-27 (codex P3): a flag-looking word MID-objective is preserved (not rejected)', async () => {
  const { code, captured } = await runInitMain(['init', 'slug', 'use', '--mode', 'carefully']);
  assert.equal(code, 0);
  assert.deepEqual(captured.initArgs, ['slug', 'use --mode carefully']);
});

test('D-27: no objective → only the slug (no empty objective arg)', async () => {
  const { captured } = await runInitMain(['init', 'slug']);
  assert.deepEqual(captured.initArgs, ['slug']);
});

test('D-27: blank/whitespace objective → only the slug', async () => {
  const { captured } = await runInitMain(['init', 'slug', '   ']);
  assert.deepEqual(captured.initArgs, ['slug']);
});

test('D-27: missing init runner → exit 1 + actionable error (no spawn)', async () => {
  const { code, err, captured } = await runInitMain(['init', 'slug'], { exists: false });
  assert.equal(code, 1);
  assert.equal(captured, null, 'must not spawn when runner is absent');
  assert.match(err, /zsh init runner not found/);
  assert.match(err, /RLP_DESK_ZSH_INIT_RUNNER/);
});

test('D-27: exit code from the zsh init runner is propagated', async () => {
  const { code } = await runInitMain(['init', 'slug', 'obj'], { initRc: 3 });
  assert.equal(code, 3);
});

test('D-27: init --help prints usage and does NOT spawn', async () => {
  const { code, out, captured } = await runInitMain(['init', '--help']);
  assert.equal(code, 0);
  assert.equal(captured, null);
  assert.match(out, /Usage: node src\/node\/run\.mjs init <slug>/);
});
