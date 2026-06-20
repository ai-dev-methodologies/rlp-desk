#!/bin/zsh
# ============================================================================
# assemble-base.zsh — INV-7 deterministic main()-stripped base generator.
#
# Regenerates a main()-stripped copy of src/scripts/run_ralph_desk.zsh at gate
# time (NEVER a checked-in snapshot — the untracked src/scripts/.run_src_verify.zsh
# is a drift hazard with a machine-pinned LIB_DIR and must NOT be relied on).
#
# The ONLY two permitted edits vs run_ralph_desk.zsh:
#   1. line `LIB_DIR="$(cd "$(dirname "$0")" && pwd)"` → absolute computed LIB_DIR
#      (so `source "$LIB_DIR/lib_ralph_desk.zsh"` resolves when sourced, not exec'd)
#   2. delete the final `main "$@"` line (we drive the REAL functions ourselves,
#      we do NOT launch a campaign)
#
# After generation it ASSERTS the diff is EXACTLY those two edits; any third diff
# line aborts (a refactor moved something — fail closed, do not run cells on a
# silently-drifted base).
#
# Usage:  assemble-base.zsh <out_path>
# Prints the resolved out_path on success; exit!=0 on drift.
# ============================================================================
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_ROOT="${SCRIPT_DIR:h:h}"                       # tests/sv-nxm-matrix → repo root
SRC="$REPO_ROOT/src/scripts/run_ralph_desk.zsh"
LIB_DIR_ABS="$REPO_ROOT/src/scripts"

OUT="${1:?usage: assemble-base.zsh <out_path>}"

[[ -f "$SRC" ]] || { print -u2 "assemble-base: source not found: $SRC"; exit 1; }
[[ -f "$LIB_DIR_ABS/lib_ralph_desk.zsh" ]] || { print -u2 "assemble-base: lib not found"; exit 1; }

# Edit 1: pin LIB_DIR to the real absolute scripts dir (so source resolves).
# Edit 2: drop the trailing `main "$@"` so sourcing does NOT start a campaign.
sed \
  -e "s#^LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"#LIB_DIR=\"$LIB_DIR_ABS\"#" \
  -e '/^main "\$@"$/d' \
  "$SRC" > "$OUT"

# --- INV-7 byte-identity assertion: diff must be EXACTLY the two known edits ---
# diff output for our two single-line edits = one changed line (LIB_DIR, a '<'/'>'
# pair) + one deleted line (main "$@", a single '<'). Any extra content line ('<'
# or '>') means an unexpected divergence → abort.
diff_out="$(diff "$SRC" "$OUT" || true)"
unexpected="$(print -r -- "$diff_out" \
  | grep -E '^[<>]' \
  | grep -vE '^< LIB_DIR="\$\(cd ' \
  | grep -vE "^> LIB_DIR=\"$LIB_DIR_ABS\"\$" \
  | grep -vE '^< main "\$@"$' || true)"

if [[ -n "$unexpected" ]]; then
  print -u2 "assemble-base: INV-7 VIOLATION — base differs from run_ralph_desk.zsh beyond the 2 known edits:"
  print -u2 -- "$unexpected"
  rm -f "$OUT"
  exit 3
fi

# Sanity: stripped base must NOT contain a top-level `main "$@"` and MUST keep the launch fns
grep -qE '^main "\$@"$' "$OUT" && { print -u2 "assemble-base: main not stripped"; rm -f "$OUT"; exit 4; }
for fn in launch_worker_codex launch_worker_claude launch_verifier_codex launch_verifier_claude create_session; do
  grep -qE "^${fn}\(\)" "$OUT" || { print -u2 "assemble-base: missing $fn in base"; rm -f "$OUT"; exit 5; }
done

print -r -- "$OUT"
