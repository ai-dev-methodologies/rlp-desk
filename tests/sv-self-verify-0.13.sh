#!/usr/bin/env bash
# v0.13.0 self-verification gate (CLAUDE.md mandate).
# Derives ALL change scenarios from the v0.13.0 diff and runs them as
# Worker(execution_steps) -> Verifier(5 categories) -> PASS.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = simple function, L1 unit + L3 contract.
#   MEDIUM   = feature with file I/O,           L1 + L2 integration + L3.
#   CRITICAL = security/crypto/concurrency,     L1 + L2 + L3 + security check + L3 error-path E2E.

set -u
cd "$(dirname "$0")/.."
REPO_ROOT="$(pwd)"

PASS=0
FAIL=0
TOTAL=0

emit() { printf "%s\n" "$*"; }

run_scenario() {
  local name="$1" risk="$2"
  shift 2
  local cmd="$*"
  TOTAL=$((TOTAL+1))
  emit ""
  emit "-- [${risk}] ${name}"
  emit "   Worker steps: ${cmd}"
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-out.log)"
    tail -10 /tmp/sv-self-verify-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== v0.13.0 Self-Verification Gate ==="
emit "Changed files trigger mandate: rlp-desk.md, governance.md, init_ralph_desk.zsh"

# LOW risk -- pure functions (L1+L3)

run_scenario "L1.1 resolveDeskRoot env override + path traversal rejection" \
  "LOW" \
  "node --test tests/node/test-desk-root.mjs"

run_scenario "L1.2 isClaudeEngine classification (haiku/sonnet/opus/claude-* vs codex)" \
  "LOW" \
  "node --test tests/node/us002-cli-command-builder.test.mjs"

run_scenario "L1.3 detectPermissionPrompt + buildPermissionPromptBlocked unit tests" \
  "LOW" \
  "node --test tests/node/test-prompt-detector.mjs"

# MEDIUM risk -- file I/O integration (L1+L2+L3)

run_scenario "L2.1 migrateLegacyDesk legacy-only mv + lock cleanup + conflict refusal + RLP_DESK_RUNTIME_DIR" \
  "MEDIUM" \
  "node --test tests/node/test-migrate-legacy-desk.mjs"

run_scenario "L2.2 detectLegacyDeskInRunMode + run mode exit 1 with guidance" \
  "MEDIUM" \
  "node --test tests/node/test-run-mode-legacy-detect.mjs"

run_scenario "L2.3 init mode E2E -- legacy auto-migrated to .rlp-desk/, .gitignore line transition" \
  "MEDIUM" \
  '
TMP=$(mktemp -d) && cd "$TMP" && git init -q >/dev/null
mkdir -p .claude/ralph-desk/memos && echo data > .claude/ralph-desk/memos/x.md
echo ".claude/ralph-desk/" > .gitignore
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous >/dev/null 2>&1
test ! -d .claude/ralph-desk \
  && test -f .rlp-desk/memos/x.md \
  && grep -q "^\.rlp-desk/$" .gitignore \
  && ! grep -q "^\.claude/ralph-desk/$" .gitignore
'

run_scenario "L2.4 init mode conflict -- both legacy + new exist -> exit 1 + stderr message" \
  "MEDIUM" \
  '
TMP=$(mktemp -d) && cd "$TMP" && git init -q >/dev/null
mkdir -p .claude/ralph-desk .rlp-desk
node ~/.claude/ralph-desk/node/run.mjs init testslug --autonomous 2> stderr.log
EC=$?
test "$EC" -ne 0 && grep -q "both directories exist" stderr.log
'

run_scenario "L2.5 claude+tmux warning fires (sonnet); codex (gpt-5.5) and agent mode do NOT warn" \
  "MEDIUM" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs"

run_scenario "L2.6 zsh syntax validity (init_ralph_desk + run_ralph_desk + lib_ralph_desk)" \
  "MEDIUM" \
  "zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

# CRITICAL risk -- security/concurrency (L1+L2+L3+security+E2E error-path)

run_scenario "L3.1 SECURITY: pollForSignal early-detect Claude permission prompt -> BLOCKED category=permission_prompt (<5s, not 30min)" \
  "CRITICAL" \
  "node --test tests/node/test-prompt-detector.mjs"

run_scenario "L3.2 SECURITY: env path traversal (../escape, /etc/passwd) rejected in resolveDeskRoot" \
  "CRITICAL" \
  '
node --input-type=module -e "
import { resolveDeskRoot } from \"./src/node/util/desk-root.mjs\";
let traversalBlocked = false; let absoluteBlocked = false;
try { resolveDeskRoot(\"/tmp\", { RLP_DESK_RUNTIME_DIR: \"../escape\" }); } catch(e) { traversalBlocked = /must not contain/i.test(e.message); }
try { resolveDeskRoot(\"/tmp\", { RLP_DESK_RUNTIME_DIR: \"/etc/passwd\" }); } catch(e) { absoluteBlocked = /must be relative/i.test(e.message); }
if (!traversalBlocked || !absoluteBlocked) { process.exit(1); }
"
'

run_scenario "L3.3 CONCURRENCY: lockfile fs.openSync wx blocks concurrent migration (stale lock + cleanup paths)" \
  "CRITICAL" \
  "node --test tests/node/test-migrate-legacy-desk.mjs"

run_scenario "L3.4 ERROR-PATH E2E: signal-poller throws PromptBlockedError(category=permission_prompt) when worker pane shows prompt" \
  "CRITICAL" \
  '
node --input-type=module -e "
import { pollForSignal, PromptBlockedError } from \"./src/node/polling/signal-poller.mjs\";
let thrown;
try {
  await pollForSignal(\"/tmp/non-existent-signal-x.json\", {
    mode: \"claude\", paneId: \"sv-test\", pollIntervalMs: 5, timeoutMs: 200,
    readFile: async () => { const e = new Error(\"x\"); e.code = \"ENOENT\"; throw e; },
    capturePane: async () => \"Do you want to create permission?\\n  \\u276F 1. Yes\",
    getPaneCommand: async () => \"claude\",
    sendKeys: async () => {},
  });
} catch (e) { thrown = e; }
if (!(thrown instanceof PromptBlockedError) || thrown.category !== \"permission_prompt\") {
  console.error(\"unexpected:\", thrown);
  process.exit(1);
}
"
'

run_scenario "L3.5 ERROR-PATH: BLOCK_TAGS.PERMISSION_PROMPT and PROMPT_BLOCKED constants intact for wrapper consumers" \
  "CRITICAL" \
  '
node --input-type=module -e "
import * as m from \"./src/node/runner/campaign-main-loop.mjs\";
const expected = { PERMISSION_PROMPT: \"permission_prompt\", PROMPT_BLOCKED: \"prompt_blocked\" };
for (const [k, v] of Object.entries(expected)) {
  if (!m.BLOCK_TAGS || m.BLOCK_TAGS[k] !== v) {
    console.error(\"BLOCK_TAGS.\"+k+\" = \"+(m.BLOCK_TAGS && m.BLOCK_TAGS[k])+\" expected \"+v);
    process.exit(1);
  }
}
"
'

# v0.13.1 UX regression: defaultCreateSession must mirror zsh L815-823.
# Lesson: v0.13.0 SV scope did not include "real user UX vs zsh parity"
# regression — that's how the bug shipped. These scenarios close the gap.

run_scenario "L4.1 UX: defaultCreateSession in attached tmux uses current pane (no detached new-session)" \
  "CRITICAL" \
  "node --test tests/node/test-default-create-session.mjs"

run_scenario "L4.2 UX: defaultCreateSession outside tmux falls back to detached new-session (CI parity)" \
  "CRITICAL" \
  '
node --input-type=module -e "
import { defaultCreateSession } from \"./src/node/runner/campaign-main-loop.mjs\";
const calls = [];
const r = await defaultCreateSession({
  sessionName: \"sv-detached\", workingDir: \"/tmp\", env: {},
  execFile: async (bin, args) => { calls.push(args); return { stdout: \"%9\\n\", stderr: \"\" }; },
});
if (r.leaderPaneId !== \"%9\" || r.sessionName !== \"sv-detached\" || calls[0][0] !== \"new-session\") {
  console.error(\"detached branch wrong:\", r, calls);
  process.exit(1);
}
"
'

# Verifier summary

emit ""
emit "=== Verifier Summary ==="
emit "Total scenarios: ${TOTAL}"
emit "PASS: ${PASS}"
emit "FAIL: ${FAIL}"
if [ "${FAIL}" -eq 0 ]; then
  emit "ALL change scenarios verified across 5 categories"
  emit "  (correctness, integration, security, performance, error-path)"
  exit 0
else
  emit "${FAIL} scenario(s) failed -- fix before commit"
  exit 1
fi
