#!/usr/bin/env zsh
# request-l (v0.22.20) — Leader launch-contract docs + canonical layout enforcement.
#
# STRUCTURAL asserts only (the behavioral width/geometry unit tests live in
# test_pane_session_pinning.sh). Verifies:
#   §1 docs — README carries BOTH canonical diagrams (3-pane human-operator +
#            4-pane AI-operator) and the dual-launch-path prose; governance carries
#            the canonical-layout contract subsection with both forms + enforcement;
#            the --mode tmux help line is present in rlp-desk.md AND the zsh runner.
#   §2 knobs — RLP_LEADER_MIN_WIDTH + RLP_LEADER_SPLIT_WIDTH defined with defaults
#            and validated via the D-19 numeric-knob guard.
set -uo pipefail
unset TMUX

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
README="$ROOT_DIR/README.md"
GOV="$ROOT_DIR/src/governance.md"
CMD="$ROOT_DIR/src/commands/rlp-desk.md"
for f in "$RUN" "$README" "$GOV" "$CMD"; do
  [[ -f "$f" ]] || { print -u2 "FAIL: missing $f"; exit 1; }
done

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }
has(){ grep -qF -- "$2" "$1"; }
hasE(){ grep -qE -- "$2" "$1"; }

# --- §1 README: dual launch paths + BOTH canonical diagrams --------------------
has "$README" 'Launch paths (both canonical)' \
  && ok "README documents both launch paths" || no "README missing dual-launch-path prose"
has "$README" '$TMUX_PANE' \
  && ok "README names the inside-tmux \$TMUX_PANE anchor" || no "README missing \$TMUX_PANE anchor note"
hasE "$README" 'start tmux first' \
  && ok "README documents outside-tmux fail-fast" || no "README missing outside-tmux fail-fast"
has "$README" '3-pane layout' \
  && ok "README carries the human-operator 3-pane diagram" || no "README missing 3-pane (human-operator) diagram"
has "$README" '4-pane layout' \
  && ok "README carries the AI-operator 4-pane diagram" || no "README missing 4-pane (AI-operator) diagram"
# The 4-pane diagram must show a distinct, always-visible Leader pane.
hasE "$README" 'Leader pane .* always visible|always visible at a readable width|stays visible at a readable width' \
  && ok "README states the Leader stays visible at a readable width" || no "README missing leader-always-visible decision"
has "$README" 'pane-creation' \
  && ok "README notes the Leader is a pane-creation anchor" || no "README missing pane-creation anchor note"

# --- §1 governance: canonical-layout contract subsection -----------------------
has "$GOV" 'Canonical layout contract' \
  && ok "governance has the canonical-layout contract subsection" || no "governance missing canonical-layout contract"
has "$GOV" 'Human operator (3-pane)' \
  && ok "governance carries the human-operator 3-pane form" || no "governance missing 3-pane form"
has "$GOV" 'AI operator (4-pane)' \
  && ok "governance carries the AI-operator 4-pane form" || no "governance missing 4-pane form"
hasE "$GOV" 'blocked|Geometry enforcement' \
  && ok "governance states the geometry enforcement semantics (block on drift)" || no "governance missing enforcement semantics"
has "$GOV" 'Silent drift is forbidden' \
  && ok "governance forbids silent drift" || no "governance missing silent-drift prohibition"

# --- §1 help lines: rlp-desk.md AND zsh runner ---------------------------------
has "$CMD" 'keeps the canonical layout' \
  && ok "rlp-desk.md --mode tmux help line states the layout contract" || no "rlp-desk.md missing --mode tmux layout help line"
has "$RUN" 'Canonical layout (--mode tmux)' \
  && ok "zsh runner usage text states the layout contract" || no "zsh runner missing canonical-layout usage note"

# --- §2 knobs: defined with defaults + D-19 validated --------------------------
hasE "$RUN" 'RLP_LEADER_MIN_WIDTH=.\$\{RLP_LEADER_MIN_WIDTH:-30\}' \
  && ok "RLP_LEADER_MIN_WIDTH defaults to 30" || no "RLP_LEADER_MIN_WIDTH default missing/changed"
hasE "$RUN" 'RLP_LEADER_SPLIT_WIDTH=.\$\{RLP_LEADER_SPLIT_WIDTH:-110\}' \
  && ok "RLP_LEADER_SPLIT_WIDTH defaults to 110" || no "RLP_LEADER_SPLIT_WIDTH default missing/changed"
hasE "$RUN" '_validate_int_knob RLP_LEADER_MIN_WIDTH ' \
  && ok "RLP_LEADER_MIN_WIDTH D-19 validated" || no "RLP_LEADER_MIN_WIDTH not D-19 validated"
hasE "$RUN" '_validate_int_knob RLP_LEADER_SPLIT_WIDTH ' \
  && ok "RLP_LEADER_SPLIT_WIDTH D-19 validated" || no "RLP_LEADER_SPLIT_WIDTH not D-19 validated"
hasE "$RUN" '_validate_int_knob RLP_SHELL_READY_TIMEOUT_S ' \
  && ok "RLP_SHELL_READY_TIMEOUT_S retrofitted through D-19" || no "RLP_SHELL_READY_TIMEOUT_S not D-19 validated"

# --- G4: degrade-floor knob defined + validated + documented -------------------
hasE "$RUN" 'RLP_LEADER_DEGRADE_FLOOR=.\$\{RLP_LEADER_DEGRADE_FLOOR:-60\}' \
  && ok "RLP_LEADER_DEGRADE_FLOOR defaults to 60" || no "RLP_LEADER_DEGRADE_FLOOR default missing/changed"
hasE "$RUN" '_validate_int_knob RLP_LEADER_DEGRADE_FLOOR ' \
  && ok "RLP_LEADER_DEGRADE_FLOOR D-19 validated" || no "RLP_LEADER_DEGRADE_FLOOR not D-19 validated"
has "$RUN" 'RLP_LEADER_DEGRADE_FLOOR' \
  && ok "RLP_LEADER_DEGRADE_FLOOR documented in the header block" || no "RLP_LEADER_DEGRADE_FLOOR missing from header block"
! grep -qF 'a too-narrow pane makes the split fail' "$GOV" \
  && ok "governance no longer asserts the split-fails rationale" || no "governance still asserts the split-fails rationale"
has "$GOV" 'target/floor two-knob model' \
  && ok "governance describes the target/floor two-knob model" || no "governance missing target/floor two-knob model description"

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 ))
