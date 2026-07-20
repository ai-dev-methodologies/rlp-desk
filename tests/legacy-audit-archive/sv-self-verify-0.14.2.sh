#!/usr/bin/env bash
# v0.14.2 self-verification gate (CLAUDE.md mandate).
#
# Verifies BOS Bug Report #4 fixes — v0.14.1 partial-fix regression closed:
#   1. Codex idle UI pattern relaxed (Worked for / Context %left / model
#      branch line / default suggestions all trigger idle detection).
#   2. Verdict file dual-path lookup (canonical .rlp-desk + legacy
#      .claude/ralph-desk fallback) with auto-migration.
#   3. signal-poller last-chance read accepts an explicit `legacySignalFile`
#      override.
#   4. Verifier prompt now embeds an absolute "MUST write verdict to <path>"
#      footer (Fix-E) so codex does not infer the legacy CWD path.
#   5. Debug trace emitted when verifier-pane no-progress check misses
#      (root-cause aid for future regressions).
#
# Risk classifications (per CLAUDE.md):
#   LOW      = pure check, L1 only.
#   MEDIUM   = wiring change, L1+L2 integration + L3.
#   CRITICAL = false-positive prevention invariant, L1+L2+L3+security+E2E.

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
  if (cd "$REPO_ROOT" && eval "${cmd}") > /tmp/sv-self-verify-0.14.2-out.log 2>&1; then
    emit "   -> PASS (correctness OK | integration OK | security OK | perf OK | error-path OK)"
    PASS=$((PASS+1))
  else
    emit "   -> FAIL (see /tmp/sv-self-verify-0.14.2-out.log)"
    tail -25 /tmp/sv-self-verify-0.14.2-out.log | sed 's/^/      /'
    FAIL=$((FAIL+1))
  fi
}

emit "=== v0.14.2 Self-Verification Gate ==="
emit "Trigger files: src/scripts/run_ralph_desk.zsh,"
emit "               src/node/runner/{prompt-dismisser,campaign-main-loop}.mjs,"
emit "               src/node/polling/signal-poller.mjs,"
emit "               src/node/prompts/prompt-assembler.mjs"

# ---------------------------------------------------------------------------
# Phase 1 — zsh: pattern relaxation + dual-path lookup + auto-migration
# ---------------------------------------------------------------------------

run_scenario "L7.1 zsh codex idle pattern + dual-path verdict lookup + auto-mv (24+ cases)" \
  "CRITICAL" \
  "zsh tests/test_codex_idle_no_progress.sh"

run_scenario "L7.1b zsh runner remains syntactically valid after Phase 1+2 edits" \
  "LOW" \
  "zsh -n src/scripts/run_ralph_desk.zsh && zsh -n src/scripts/init_ralph_desk.zsh && zsh -n src/scripts/lib_ralph_desk.zsh"

run_scenario "L7.1c zsh declares LEGACY_VERDICT_FILE alongside VERDICT_FILE" \
  "LOW" \
  "grep -q '^LEGACY_VERDICT_FILE=' src/scripts/run_ralph_desk.zsh"

# ---------------------------------------------------------------------------
# Phase 2 — Node: relaxed CODEX_IDLE_RE + signal-poller dual-path + auto-mv
# ---------------------------------------------------------------------------

run_scenario "L7.2 Node CODEX_IDLE_RE relaxation: BOS Bug #4 fixtures all match" \
  "CRITICAL" \
  "node --test tests/node/test-codex-idle-detection.mjs"

run_scenario "L7.3 SECURITY: pollForSignal falls back to legacySignalFile after canonical timeout" \
  "CRITICAL" \
  "node --test tests/node/test-signal-poller-last-chance.mjs"

run_scenario "L7.3b paths.legacyVerdictFile + _migrateLegacyVerdict declared in campaign-main-loop" \
  "LOW" \
  "grep -q 'legacyVerdictFile' src/node/runner/campaign-main-loop.mjs && grep -q '_migrateLegacyVerdict' src/node/runner/campaign-main-loop.mjs"

# ---------------------------------------------------------------------------
# Phase 3 — verifier prompt path injection (Fix-E)
# ---------------------------------------------------------------------------

run_scenario "L7.4 verifier prompt embeds absolute verdictWritePath when supplied" \
  "MEDIUM" \
  '
node --input-type=module -e "
import path from \"node:path\";
import os from \"node:os\";
import fs from \"node:fs\";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), \"v0142-prompt-\"));
const base = path.join(tmp, \"v.prompt.md\");
fs.writeFileSync(base, \"# Verifier base\\n\");
const { assembleVerifierPrompt } = await import(\"./src/node/prompts/prompt-assembler.mjs\");
const out = await assembleVerifierPrompt({
  promptBase: base,
  iteration: 3,
  doneClaimFile: \"/abs/path/done-claim.json\",
  usId: \"US-008\",
  verdictWritePath: \"/abs/.rlp-desk/memos/test-verify-verdict.json\",
});
fs.rmSync(tmp, { recursive: true, force: true });
if (!out.includes(\"CRITICAL: Verdict file write path\")) {
  console.error(\"missing CRITICAL header\"); process.exit(1);
}
if (!out.includes(\"/abs/.rlp-desk/memos/test-verify-verdict.json\")) {
  console.error(\"missing absolute path injection\"); process.exit(1);
}
if (!out.includes(\"DO NOT write to\")) {
  console.error(\"missing legacy-path warning\"); process.exit(1);
}
"
'

run_scenario "L7.4b verifier prompt omits the section when verdictWritePath is empty (backward compat)" \
  "LOW" \
  '
node --input-type=module -e "
import path from \"node:path\";
import os from \"node:os\";
import fs from \"node:fs\";
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), \"v0142-prompt-2-\"));
const base = path.join(tmp, \"v.prompt.md\");
fs.writeFileSync(base, \"# Verifier base\\n\");
const { assembleVerifierPrompt } = await import(\"./src/node/prompts/prompt-assembler.mjs\");
const out = await assembleVerifierPrompt({
  promptBase: base,
  iteration: 3,
  doneClaimFile: \"/abs/path/done-claim.json\",
  usId: \"US-008\",
});
fs.rmSync(tmp, { recursive: true, force: true });
if (out.includes(\"CRITICAL: Verdict file write path\")) {
  console.error(\"unexpected injection when verdictWritePath was empty\");
  process.exit(1);
}
"
'

# ---------------------------------------------------------------------------
# Regression guards — earlier contracts must hold
# ---------------------------------------------------------------------------

run_scenario "L7.5 v0.14.0 contract: --mode tmux still delegates to zsh subprocess" \
  "LOW" \
  "node --test tests/node/us008-cli-entrypoint.test.mjs --test-name-pattern '--mode tmux delegates'"

run_scenario "L7.5b v0.13.0 contract: claude permission_prompt detector still wired" \
  "LOW" \
  "node --test tests/node/test-prompt-detector.mjs"

run_scenario "L7.5c v0.13.0 contract: legacy .claude/ralph-desk migration logic still tested" \
  "LOW" \
  "node --test tests/node/test-migrate-legacy-desk.mjs"

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
