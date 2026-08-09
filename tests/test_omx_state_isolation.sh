#!/usr/bin/env zsh
# ============================================================================
# fix/omx-state-isolation (incident 2026-08-09) — every codex session a
# CAMPAIGN launches must run with OMX_STATE_ROOT pointed at a campaign-scoped
# scratch dir, isolating it from the operator's interactive omx state.
#
# Background: oh-my-codex hooks read project-local .omx/state/ by default.
# Stale interactive-session state (an unreleased input_lock, a huge
# pre-existing .omx/state/sessions/ tree) can block/wedge campaign codex
# workers that share that path with the operator's own Claude Code session.
# --disable plugins (already present at every codex launch) does NOT cover
# hooks.json native hooks — env isolation via OMX_STATE_ROOT is required.
#
# This pins the wiring against the source (mirrors the count-pinned style of
# tests/test_codex_update_dialog_hardening.sh's _CODEX_NO_UPDATE_FLAG census)
# so a future refactor cannot silently drop the isolation on a new/edited
# codex launch site.
# ============================================================================
set -uo pipefail
unset TMUX 2>/dev/null || true

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
SPEC="$ROOT_DIR/src/commands/rlp-desk.md"
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }
[[ -f "$SPEC" ]] || { print -u2 "FAIL: $SPEC not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

# ---------------------------------------------------------------------------
# (a) OMX_STATE_DIR is defined once (derived from RUNTIME_DIR) and mkdir -p'd
#     in main() before any codex launch can occur.
# ---------------------------------------------------------------------------
_def_sites=$(grep -c '^OMX_STATE_DIR="\$RUNTIME_DIR/omx-state"' "$RUN")
{ [[ "$_def_sites" == 1 ]] } \
  && ok "(a) OMX_STATE_DIR defined exactly once, derived from RUNTIME_DIR ($_def_sites)" \
  || no "(a) expected exactly 1 OMX_STATE_DIR definition, got $_def_sites"

grep -qE 'mkdir -p "\$LOGS_DIR" "\$RUNTIME_DIR" "\$OMX_STATE_DIR"' "$RUN" \
  && ok "(a) main() mkdir -p's OMX_STATE_DIR alongside LOGS_DIR/RUNTIME_DIR" \
  || no "(a) OMX_STATE_DIR is not mkdir -p'd alongside LOGS_DIR/RUNTIME_DIR"

# ---------------------------------------------------------------------------
# (b) ROOT: every codex launch assembly site (all 8 — same census as the
#     update-dialog hardening test) prefixes the command with
#     OMX_STATE_ROOT='$OMX_STATE_DIR'.
# ---------------------------------------------------------------------------
_assembly_sites=$(grep -c '\${CODEX_BIN:-codex}' "$RUN")
_omx_sites=$(grep -c "OMX_STATE_ROOT='\$OMX_STATE_DIR' \${CODEX_BIN:-codex}" "$RUN")
{ [[ "$_assembly_sites" == 8 && "$_omx_sites" == 8 ]] } \
  && ok "(b) all 8 codex launch assembly sites carry OMX_STATE_ROOT='\$OMX_STATE_DIR' (sites=$_assembly_sites omx=$_omx_sites)" \
  || no "(b) launch-site/OMX_STATE_ROOT count mismatch (assembly=$_assembly_sites omx=$_omx_sites, expected 8/8)"

# ---------------------------------------------------------------------------
# (c) Native leader spec (rlp-desk.md) codex invocation templates carry the
#     same OMX_STATE_ROOT prefix. Checked as literal `Bash(...)` code-fence
#     templates only (the executable ones) — NOT the high-level mode-summary
#     bullet (:310) or the generic ASCII architecture diagram (:~920), which
#     the isolation task explicitly leaves generic.
# ---------------------------------------------------------------------------
_spec_fenced_templates=$(grep -cE '^Bash\("OMX_STATE_ROOT=.*codex exec' "$SPEC")
{ [[ "$_spec_fenced_templates" == 2 ]] } \
  && ok "(c) both fenced Bash(...) codex exec templates (worker + verifier) carry OMX_STATE_ROOT ($_spec_fenced_templates)" \
  || no "(c) expected 2 fenced codex exec templates carrying OMX_STATE_ROOT, got $_spec_fenced_templates"

_spec_prose_mentions=$(grep -cE 'Bash\("OMX_STATE_ROOT=.*codex exec' "$SPEC")
{ [[ "$_spec_prose_mentions" -ge 4 ]] } \
  && ok "(c) at least 4 rlp-desk.md mentions (2 prose + 2 fenced) carry the OMX_STATE_ROOT-prefixed codex exec form ($_spec_prose_mentions)" \
  || no "(c) expected >=4 OMX_STATE_ROOT-prefixed codex exec mentions in rlp-desk.md, got $_spec_prose_mentions"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
