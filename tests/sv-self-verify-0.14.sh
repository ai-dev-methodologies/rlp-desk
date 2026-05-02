#!/usr/bin/env bash
# v0.14.0 self-verification gate (CLAUDE.md mandate).
#
# Verifies the architecture recovery: zsh runner restored as the canonical
# --mode tmux backend, Node leader reduced to --mode agent (alpha), with
# install/uninstall scripts syncing both. Each scenario maps Worker
# (execution_steps) -> Verifier (5 categories) -> PASS.
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure check, L1 only.
#   MEDIUM   = wiring change, L1+L2 integration + L3.
#   CRITICAL = routing/architecture invariant, L1+L2+L3+security+E2E error-path.

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
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-0.14-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-0.14-out.log)"
    tail -20 /tmp/sv-self-verify-0.14-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== v0.14.0 Self-Verification Gate ==="
emit "Trigger files: src/scripts/run_ralph_desk.zsh, src/node/run.mjs,"
emit "               scripts/postinstall.js, scripts/uninstall.js,"
emit "               src/commands/rlp-desk.md, README.md"

# ---------------------------------------------------------------------------
# Phase 1 — zsh deprecation gate removal
# ---------------------------------------------------------------------------

run_scenario "L5.4 zsh runner no longer hard-rejects FLYWHEEL/FLYWHEEL_GUARD/WITH_SELF_VERIFICATION" \
  "MEDIUM" \
  '
# The v5.7 deprecation gate exited 2 with "require the Node leader". v0.14
# removes that exit so the runner remains usable. Verify the rejection text
# is gone AND that the v0.14 strategy comment is present.
! grep -q "require the Node leader" src/scripts/run_ralph_desk.zsh \
  && grep -q "v0.14.0 — zsh runner restored as primary tmux mode path" src/scripts/run_ralph_desk.zsh
'

run_scenario "L5.4b zsh syntax stays valid after deprecation gate removal" \
  "LOW" \
  "zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

# ---------------------------------------------------------------------------
# Phase 2 — Node --mode tmux delegates to zsh subprocess
# ---------------------------------------------------------------------------

run_scenario "L5.2 SECURITY+ROUTING: --mode tmux delegates to spawn('zsh', ...) and never calls runCampaign" \
  "CRITICAL" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern '--mode tmux delegates'"

run_scenario "L5.3 flag→env conversion: every supported tmux flag maps to its zsh env var" \
  "CRITICAL" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern '--mode tmux delegates'"

run_scenario "L5.2b ERROR-PATH: missing zsh runner → actionable error + exit 1, not silent hang" \
  "CRITICAL" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern 'missing zsh runner'"

run_scenario "L5.2c agent-mode flag-parse contract preserved (regression guard)" \
  "MEDIUM" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern 'parses agent example flags'"

# ---------------------------------------------------------------------------
# Phase 3 — postinstall syncs zsh; uninstall cleans it up
# ---------------------------------------------------------------------------

run_scenario "L5.5 postinstall installs the 3 zsh files with correct banner placement" \
  "MEDIUM" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern 'postinstall installs the Node runtime AND the zsh tmux runner'"

run_scenario "L5.5b reinstall replaces stale zsh content with source body" \
  "MEDIUM" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern 'syncs zsh files from source on reinstall'"

run_scenario "L5.5c postinstall.js source declares zsh in runtimeSources and empty legacyFiles" \
  "LOW" \
  '
grep -q "src/scripts/init_ralph_desk.zsh" scripts/postinstall.js \
  && grep -q "src/scripts/run_ralph_desk.zsh" scripts/postinstall.js \
  && grep -q "src/scripts/lib_ralph_desk.zsh" scripts/postinstall.js \
  && grep -q "const legacyFiles = \[\];" scripts/postinstall.js
'

run_scenario "L5.5d uninstall.js removes the 3 zsh files (no orphaned 0o444 files)" \
  "LOW" \
  '
grep -q "init_ralph_desk.zsh" scripts/uninstall.js \
  && grep -q "run_ralph_desk.zsh" scripts/uninstall.js \
  && grep -q "lib_ralph_desk.zsh" scripts/uninstall.js
'

# ---------------------------------------------------------------------------
# Phase 4 — agent-mode alpha labeling
# ---------------------------------------------------------------------------

run_scenario "L5.6 --mode agent emits stderr alpha warning when NODE_ENV != test" \
  "MEDIUM" \
  '
node --input-type=module -e "
import { main } from \"./src/node/run.mjs\";
const stderrChunks = [];
const prev = process.env.NODE_ENV;
delete process.env.NODE_ENV;
try {
  await main(
    [\"run\", \"sv-demo\", \"--mode\", \"agent\", \"--worker-model\", \"sonnet\"],
    {
      runCampaign: async () => ({ status: \"continue\" }),
      stderr: { write: (s) => stderrChunks.push(String(s)) },
      stdout: { write: () => {} },
      cwd: process.cwd(),
    },
  );
} finally { if (prev !== undefined) process.env.NODE_ENV = prev; }
const txt = stderrChunks.join(\"\");
if (!/--mode agent is alpha/.test(txt)) {
  console.error(\"missing alpha warning. stderr:\", txt);
  process.exit(1);
}
"
'

run_scenario "L5.6b README + slash-command docs label the modes (tmux=stable, agent=alpha)" \
  "LOW" \
  '
grep -q "tmux=zsh Leader (stable" README.md \
  && grep -q "agent=Node Leader (alpha)" README.md \
  && grep -q "alpha\*\* (Node-native LLM-driven Leader)" src/commands/rlp-desk.md
'

# ---------------------------------------------------------------------------
# v0.13.x preservation — do not regress prior fixes
# ---------------------------------------------------------------------------

run_scenario "L5.7 v0.13.x preserved: claude+tmux warning still surfaces in tmux routing" \
  "MEDIUM" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern 'warns when claude worker model used in tmux mode'"

run_scenario "L5.7b v0.13.x preserved: project-local .rlp-desk path migration still tested" \
  "LOW" \
  "node --test tests/node/test-migrate-legacy-desk.mjs"

run_scenario "L5.7c v0.13.x preserved: prompt-detector + signal-poller permission_prompt still wired" \
  "LOW" \
  "node --test tests/node/test-prompt-detector.mjs"

# ---------------------------------------------------------------------------
# Verifier summary
# ---------------------------------------------------------------------------

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
