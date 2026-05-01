import test from 'node:test';
import assert from 'node:assert/strict';

// v0.13.1: defaultCreateSession must mirror zsh runner UX --
// inside attached tmux ($TMUX set) -> use current pane/session,
// outside tmux -> fall back to detached new-session.

test('defaultCreateSession in attached tmux uses display-message and current pane/session', async () => {
  const { defaultCreateSession } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const calls = [];
  const fakeExec = async (bin, args) => {
    calls.push([bin, ...args]);
    if (args[0] === 'display-message' && args.includes('#{pane_id}')) {
      return { stdout: '%17\n', stderr: '' };
    }
    if (args[0] === 'display-message' && args.includes('#{session_name}')) {
      return { stdout: 'user-session\n', stderr: '' };
    }
    throw new Error(`unexpected tmux call: ${args.join(' ')}`);
  };

  const result = await defaultCreateSession({
    sessionName: 'rlp-fallback-name',
    workingDir: '/tmp/proj',
    env: { TMUX: '/tmp/tmux-1000/default,123,0' },
    execFile: fakeExec,
  });

  assert.equal(result.sessionName, 'user-session');
  assert.equal(result.leaderPaneId, '%17');
  assert.equal(calls.length, 2);
  assert.ok(calls.every((c) => c[0] === 'tmux' && c[1] === 'display-message'));
  assert.ok(!calls.some((c) => c.includes('new-session')));
});

test('defaultCreateSession outside tmux falls back to detached new-session', async () => {
  const { defaultCreateSession } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const calls = [];
  const fakeExec = async (bin, args) => {
    calls.push([bin, ...args]);
    if (args[0] === 'new-session') {
      return { stdout: '%99\n', stderr: '' };
    }
    throw new Error(`unexpected tmux call: ${args.join(' ')}`);
  };

  const result = await defaultCreateSession({
    sessionName: 'rlp-detached',
    workingDir: '/tmp/proj',
    env: {},
    execFile: fakeExec,
  });

  assert.equal(result.sessionName, 'rlp-detached');
  assert.equal(result.leaderPaneId, '%99');
  assert.equal(calls.length, 1);
  assert.equal(calls[0][1], 'new-session');
  assert.ok(calls[0].includes('-d'));
  assert.ok(calls[0].includes('-s'));
  assert.ok(calls[0].includes('rlp-detached'));
});

test('defaultCreateSession empty TMUX env value falls back to detached', async () => {
  const { defaultCreateSession } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const fakeExec = async (bin, args) => {
    if (args[0] === 'new-session') return { stdout: '%2\n', stderr: '' };
    throw new Error('unexpected');
  };
  const result = await defaultCreateSession({
    sessionName: 'rlp-x',
    workingDir: '/tmp/x',
    env: { TMUX: '' },
    execFile: fakeExec,
  });
  assert.equal(result.leaderPaneId, '%2');
});

test('defaultCreateSession session_name fallback when display-message returns empty', async () => {
  const { defaultCreateSession } = await import('../../src/node/runner/campaign-main-loop.mjs');
  const fakeExec = async (_, args) => {
    if (args.includes('#{pane_id}')) return { stdout: '%5\n', stderr: '' };
    if (args.includes('#{session_name}')) return { stdout: '\n', stderr: '' };
    throw new Error('unexpected');
  };
  const result = await defaultCreateSession({
    sessionName: 'fallback-name',
    workingDir: '/tmp',
    env: { TMUX: 'x' },
    execFile: fakeExec,
  });
  assert.equal(result.sessionName, 'fallback-name');
  assert.equal(result.leaderPaneId, '%5');
});
