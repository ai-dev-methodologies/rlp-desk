#!/bin/zsh
# request-b ①b — confirmation mode must not be pinned to build by UNRELATED
# resident user dirt. derive_verification_mode's working-tree gate now excludes
# CAMPAIGN_PREEXISTING_DIRTY (the same comm -23 subtraction Bug#8 F-8 uses), so a
# resumed campaign in a repo carrying a user's uncommitted files can still confirm
# — while any NEW campaign-era tracked change still forces build, and the SHA
# anchor stays the anti-gaming guarantee.
#
#   (i)   resident-dirty tracked file IN preexisting + full coverage + SHA match → confirmation
#   (ii)  same + one NEW tracked dirty file NOT in preexisting                    → build
#   (iii) SHA anchor drift (HEAD moved since verify)                              → build regardless
#   (iv)  BOTH engines' verifier prompts under (i) carry the confirmation clause
#         (the shared injection actually fires — ①a was already-satisfied, no-op)
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$LIB" && -f "$RUN" ]] || { print -u2 "FAIL: scripts not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { print -u2 "FAIL: jq not installed"; exit 1; }
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
FIX="$TMP/repo"; mkdir -p "$FIX"
git -C "$FIX" init -q
git -C "$FIX" config user.email t@t.t; git -C "$FIX" config user.name t
print -r -- one > "$FIX/a.txt"; print -r -- one > "$FIX/b.txt"
git -C "$FIX" add a.txt b.txt; git -C "$FIX" commit -qm c1; SHA1=$(git -C "$FIX" rev-parse HEAD)
print -r -- two >> "$FIX/a.txt"; git -C "$FIX" commit -qam c2; SHA2=$(git -C "$FIX" rev-parse HEAD)
PRD="$TMP/prd.md"
printf '### US-001: First\n- AC1: x\n### US-002: Second\n- AC1: y\n' > "$PRD"
PH=$(git -C "$FIX" hash-object "$PRD")
L="$TMP/ledger.jsonl"
print -r -- "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA2\",\"prd\":\"$PH\"}"  > "$L"
print -r -- "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"$SHA2\",\"prd\":\"$PH\"}" >> "$L"

# Driver: derive_verification_mode with an explicit CAMPAIGN_PREEXISTING_DIRTY.
derive() { # $1=ledger $2=prd $3=root $4=preexisting-newline-list
  CAMPAIGN_PREEXISTING_DIRTY="$4" zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    derive_verification_mode "$1" "$2" "$3"
  ' _ "$1" "$2" "$3"
}
mode_of(){ derive "$1" "$2" "$3" "$4" | head -1 | cut -d'|' -f1; }

# (i) resident dirt (a.txt) that IS in the preexisting snapshot → confirmation.
git -C "$FIX" checkout -q -- a.txt 2>/dev/null || true
print -r -- dirty >> "$FIX/a.txt"          # resident user edit
[[ "$(mode_of "$L" "$PRD" "$FIX" $'a.txt')" == confirmation ]] \
  && ok "(i) resident-dirty tracked file in preexisting + coverage + SHA match → confirmation" \
  || no "(i) resident preexisting dirt should NOT pin build (got: $(derive "$L" "$PRD" "$FIX" $'a.txt'))"

# (ii) a NEW tracked dirty file (b.txt) NOT in the preexisting snapshot → build.
print -r -- dirty >> "$FIX/b.txt"          # campaign-era new dirt
[[ "$(mode_of "$L" "$PRD" "$FIX" $'a.txt')" == build ]] \
  && ok "(ii) a new tracked change outside preexisting → build" \
  || no "(ii) campaign-era dirt must force build (got: $(derive "$L" "$PRD" "$FIX" $'a.txt'))"
git -C "$FIX" checkout -q -- a.txt b.txt

# (iii) SHA anchor drift: ledger anchored at SHA1 while HEAD=SHA2 → build even
# with the dirty file excluded (the SHA anchor fires before the tree gate).
Ldrift="$TMP/ledger-drift.jsonl"
print -r -- "{\"us_id\":\"US-001\",\"iter\":1,\"commit\":\"$SHA1\",\"prd\":\"$PH\"}"  > "$Ldrift"
print -r -- "{\"us_id\":\"US-002\",\"iter\":2,\"commit\":\"$SHA1\",\"prd\":\"$PH\"}" >> "$Ldrift"
print -r -- dirty >> "$FIX/a.txt"
[[ "$(mode_of "$Ldrift" "$PRD" "$FIX" $'a.txt')" == build ]] \
  && ok "(iii) SHA anchor drift → build regardless of preexisting exclusion" \
  || no "(iii) SHA drift must be build (got: $(derive "$Ldrift" "$PRD" "$FIX" $'a.txt'))"
git -C "$FIX" checkout -q -- a.txt

# (iv) both engines' verifier prompts carry the confirmation clause under a
# confirmation-mode signal. Extract write_verifier_trigger, stub its deps, force
# confirmation, render for -codex and -claude, and grep both.
EX="$TMP/wvt.zsh"
awk '/^write_verifier_trigger\(\)/,/^}$/' "$RUN" > "$EX"
grep -q 'write_verifier_trigger' "$EX" || { no "(iv) could not extract write_verifier_trigger"; }
base="$TMP/base.md"; print -r -- "# Verifier base prompt (stub)" > "$base"
sig="$TMP/signal.json"; print -r -- '{"us_id":"US-001"}' > "$sig"
out=$(zsh --no-rcs -c '
  source "'"$LIB"'" 2>/dev/null
  log(){ :; }; log_debug(){ :; }; log_error(){ :; }
  derive_verification_mode(){ print -r -- "confirmation|forced for test"; }
  build_claude_cmd(){ print -r -- "claude --print"; }
  _emit_evidence_lock_contract(){ :; }
  VERIFIER_ENGINE=codex; VERIFIER_MODEL=sonnet; VERIFIER_EFFORT=""
  VERIFIER_CODEX_MODEL=gpt; VERIFIER_CODEX_REASONING=high; CODEX_BIN=codex
  VERIFY_MODE=per-us; AUTONOMOUS_MODE=0
  VERIFIED_LEDGER="'"$L"'"; PRD_FILE="'"$PRD"'"; ROOT="'"$FIX"'"
  VERIFIER_PROMPT_BASE="'"$base"'"; SIGNAL_FILE="'"$sig"'"
  DONE_CLAIM_FILE="'"$TMP"'/done.json"; VERIFY_MODE=per-us
  VERIFIER_HEARTBEAT="'"$TMP"'/hb"; ITER_WINDOW_START="2026-07-20T00:00:00Z"
  LOGS_DIR="'"$TMP"'/logs"; mkdir -p "$LOGS_DIR"
  source "'"$EX"'"
  write_verifier_trigger 5 codex sonnet -codex
  write_verifier_trigger 5 claude sonnet -claude
  print "CODEX:"; grep -c "CONFIRMATION CONTRACT" "$LOGS_DIR/iter-005.verifier-codex-prompt.md"
  print "CLAUDE:"; grep -c "CONFIRMATION CONTRACT" "$LOGS_DIR/iter-005.verifier-claude-prompt.md"
')
cx=$(print -r -- "$out" | awk "/^CODEX:/{getline; print}")
cl=$(print -r -- "$out" | awk "/^CLAUDE:/{getline; print}")
[[ "${cx:-0}" -ge 1 ]] && ok "(iv) codex verifier prompt carries the confirmation clause" \
  || no "(iv) codex prompt missing the confirmation clause (out: $out)"
[[ "${cl:-0}" -ge 1 ]] && ok "(iv) claude verifier prompt carries the confirmation clause (parity)" \
  || no "(iv) claude prompt missing the confirmation clause (out: $out)"

# Structural: the clause lives in the SHARED prompt block, before the engine
# branch — proving it is engine-agnostic (①a already-satisfied, not injected per-engine).
clause_line=$(grep -n 'CONFIRMATION CONTRACT' "$RUN" | head -1 | cut -d: -f1)
branch_line=$(awk '/^write_verifier_trigger\(\)/{f=1} f&&/if \[\[ "\$verifier_engine" = "codex" \]\]/{print NR; exit}' "$RUN")
[[ -n "$clause_line" && -n "$branch_line" && "$clause_line" -lt "$branch_line" ]] \
  && ok "structural: confirmation clause emitted in the shared block before the engine branch" \
  || no "structural: clause/engine-branch ordering unexpected (clause=$clause_line branch=$branch_line)"

# --- seal #3: main() ordering — the preexisting-dirty capture MUST precede the
# resume-finalize derive_verification_mode call, or the ①b exclusion is empty on
# the primary resumed-campaign path (the exact field case). Line-order assert on
# the real code.
# (IMP-09 updated the capture to the fail-closed _git_snapshot helper — match
# the assignment itself, not one specific git invocation form.)
cap_line=$(grep -n 'CAMPAIGN_PREEXISTING_DIRTY=\$(_git_snapshot\|^  CAMPAIGN_PREEXISTING_DIRTY=\$(git' "$RUN" | head -1 | cut -d: -f1)
resume_line=$(grep -n '_resume_derived=\$(derive_verification_mode' "$RUN" | head -1 | cut -d: -f1)
[[ -n "$cap_line" && -n "$resume_line" && "$cap_line" -lt "$resume_line" ]] \
  && ok "seal#3: CAMPAIGN_PREEXISTING_DIRTY captured (L$cap_line) BEFORE resume-finalize derive (L$resume_line)" \
  || no "seal#3: capture/resume ordering wrong (cap=$cap_line resume=$resume_line) — ①b dead on resume path"
# And exactly ONE assignment site remains (no duplicate capture drift).
[[ "$(grep -c 'CAMPAIGN_PREEXISTING_DIRTY=\$(_git_snapshot\|^  CAMPAIGN_PREEXISTING_DIRTY=\$(git' "$RUN")" == "1" ]] \
  && ok "seal#3: single capture site (no duplicate-assignment drift)" \
  || no "seal#3: unexpected number of capture sites"

# --- seal #2: BOTH claude launchers carry the lingering-process guard so a
# re-dispatch never pastes the shell command into an idle claude TUI chat.
for fn in launch_verifier_claude launch_worker_claude; do
  blk=$(awk "/^${fn}\(\)/,/^}/" "$RUN")
  print -r -- "$blk" | grep -q 'pane_current_command' \
    && print -r -- "$blk" | grep -q 'C-c' \
    && ok "seal#2: $fn has the lingering-process guard" \
    || no "seal#2: $fn missing the lingering-process guard"
done

print ""
print "PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
