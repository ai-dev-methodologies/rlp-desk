#!/bin/zsh
# ============================================================================
# US-002B (Option D) — cross-mode leader registry (advisory) + F-8 downgrade
#
# CAMPAIGN_PREEXISTING_DIRTY ∪ ITER_PREEXISTING_DIRTY (US-002A) narrows F-8's
# blast radius to a single worker window; it cannot close the case where a
# FOREIGN leader (a `--mode native` campaign, which takes no runner lock) edits
# the tree DURING that window. Option D closes it: every leader registers a
# per-PID advisory entry under $DESK/logs/.rlp-desk-leaders-$ROOT_HASH.d/, and
# F-8 DOWNGRADES from auto-commit to the existing _bug8_record_carryover path
# when ≥1 LIVE foreign entry exists on the same toplevel.
#
# The registry is ADVISORY, never exclusive: registration must never fail a
# campaign, and it must NOT reuse RUNNER_LOCKFILE_PATH (that lock is exclusive
# and would make a busy root hard-fail).
#
# Cases (architect's 4-case contract — a single positive case would be vacuous,
# since a hardcoded `return 0` would pass it):
#   1 positive        live foreign entry   → carryover, NO leader-recovery commit
#   2 negative control no entry            → F-8 still auto-commits (non-vacuity)
#   3 stale PID       dead entry           → pruned, F-8 auto-commits
#   4 self-exclusion  own $$ entry         → F-8 auto-commits, own entry kept
#   5 fail-closed     unreadable registry  → carryover (AC7g; skipped as root)
# plus registry mechanics (AC7a/AC7c), call-site structure (AC7b/AC7c) and the
# native-leader + docs contracts (AC7b/AC7h).
# ============================================================================
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
CMD="$ROOT_DIR/src/commands/rlp-desk.md"
GOV="$ROOT_DIR/src/governance.md"
FMODES="$ROOT_DIR/docs/rlp-desk/failure-modes.md"
for f in "$RUN" "$LIB" "$CMD" "$GOV" "$FMODES"; do
  [[ -f "$f" ]] || { print -u2 "FAIL: missing $f"; exit 1; }
done
command -v git >/dev/null 2>&1 || { print -u2 "FAIL: git not installed"; exit 1; }
command -v jq  >/dev/null 2>&1 || { print -u2 "FAIL: jq not installed"; exit 1; }

PASS=0; FAIL=0; SKIP=0
ok(){ PASS=$((PASS+1)); print -P "  %F{green}PASS%f $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 -P "  %F{red}FAIL%f $1"; }
skip(){ SKIP=$((SKIP+1)); print -P "  %F{yellow}SKIP%f $1"; }

TMP=$(mktemp -d); EXTRACT=$(mktemp -d)
trap 'rm -rf "$TMP" "$EXTRACT"' EXIT

# --- Extract the REAL implementation (never a mirror) -----------------------
# Gate 3 + the F-8 branch come from run_ralph_desk.zsh; the registry helpers and
# atomic_write come from lib_ralph_desk.zsh.
{
  awk '/^_bug8_autocommit\(\)/,/^}$/'           "$RUN"
  awk '/^_bug8_carryover_file\(\)/{print}'      "$RUN"
  awk '/^_bug8_record_carryover\(\)/,/^}$/'     "$RUN"
  awk '/^_bug8_check_synth_allowed\(\)/,/^}$/'  "$RUN"
  awk '/^_git_dirty_base\(\)/,/^}$/'            "$LIB"
  awk '/^_git_snapshot\(\)/,/^}$/'              "$LIB"
  awk '/^atomic_write\(\)/,/^}$/'               "$LIB"
  awk '/^_leader_registry_dir\(\)/,/^}$/'       "$LIB"
  awk '/^register_leader\(\)/,/^}$/'            "$LIB"
  awk '/^unregister_leader\(\)/,/^}$/'          "$LIB"
  awk '/^_leader_registry_foreign_live\(\)/,/^}$/' "$LIB"
} > "$EXTRACT/h.zsh"
for fn in _bug8_check_synth_allowed _git_dirty_base atomic_write \
          _leader_registry_dir register_leader unregister_leader \
          _leader_registry_foreign_live; do
  grep -q "^$fn()" "$EXTRACT/h.zsh" \
    || { print -u2 "FAIL: $fn not extracted — is it defined at column 0 in run/lib?"; exit 1; }
done

# Collaborator stubs.
GATE_LOG=""; BLOCKED=""
log(){       GATE_LOG+="$*"$'\n'; }
log_error(){ GATE_LOG+="ERR $*"$'\n'; }
log_debug(){ GATE_LOG+="DBG $*"$'\n'; }
write_blocked_sentinel(){ BLOCKED="$1"; }
_emit_a4_fallback_audit(){ :; }
_lifecycle_clear_lock_mark(){ :; }   # atomic_write's tail hook
source "$EXTRACT/h.zsh"

mkrepo() { # $1 = dir — a.txt/b.txt committed, tree clean
  local r="$1"; mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  print -r -- a1 > "$r/a.txt"; print -r -- b1 > "$r/b.txt"
  git -C "$r" add -A; git -C "$r" commit -qm base
}

GATE_N=0
CARRY=""
run_gate() { # $1=repo  $2=DESK  — drives the REAL Gate 3 / F-8 branch
  GATE_N=$((GATE_N+1))
  ROOT="$1"
  DESK="$2"
  ROOT_HASH="testhash"
  SLUG="reg-test"
  CAMPAIGN_PREEXISTING_DIRTY=""
  ITER_PREEXISTING_DIRTY=""
  LOGS_DIR="$TMP/gate-logs-$GATE_N"; mkdir -p "$LOGS_DIR"   # outside the repo on purpose
  DONE_CLAIM_FILE="$LOGS_DIR/done-claim.json"
  print -r -- '{"us_id":"US-001"}' > "$DONE_CLAIM_FILE"
  BUG8_CARRYOVER_FILE="$LOGS_DIR/carry.txt"
  CARRY="$BUG8_CARRYOVER_FILE"
  CURRENT_US="US-001"
  GATE_LOG=""; BLOCKED=""
  _bug8_check_synth_allowed 1 "US-001" "test"
}
recovery_commits() { git -C "$1" log --oneline | grep -c 'leader-recovery' ; }
regdir() { print -r -- "$1/logs/.rlp-desk-leaders-testhash.d" ; }

print -P "%F{cyan}US-002B — Option D leader registry + F-8 downgrade%f"

# ===========================================================================
# Case 1 (AC7e positive) — a LIVE foreign entry downgrades F-8 to carryover.
# ===========================================================================
R1="$TMP/c1"; mkrepo "$R1"
D1="$TMP/desk1"; mkdir -p "$(regdir "$D1")"
sleep 300 & FOREIGN_PID=$!            # a real live PID, no second campaign needed
printf '{"schema_version":"1.0","pid":%s,"mode":"native","slug":"other","root":"%s","started_at":"2026-08-10T00:00:00Z"}\n' \
  "$FOREIGN_PID" "$R1" > "$(regdir "$D1")/$FOREIGN_PID.json"
print -r -- "worker work" >> "$R1/b.txt"
HEAD1=$(git -C "$R1" rev-parse HEAD)
run_gate "$R1" "$D1"; rc1=$?
(( rc1 == 0 )) && ok "1(AC7e): downgrade is graceful — gate still allows synthesis (rc 0, no BLOCK)" \
  || no "1(AC7e): expected rc 0, got $rc1 (BLOCKED='$BLOCKED')"
[[ "$(git -C "$R1" rev-parse HEAD)" == "$HEAD1" ]] \
  && ok "1(AC7e): NO commit created while a live foreign leader is registered" \
  || no "1(AC7e): F-8 committed anyway ($(git -C "$R1" show --stat HEAD | tail -3 | tr '\n' ' '))"
(( $(recovery_commits "$R1") == 0 )) \
  && ok "1(AC7e): git log gained no leader-recovery commit" \
  || no "1(AC7e): a leader-recovery commit exists"
[[ -f "$CARRY" ]] && grep -q 'b.txt' "$CARRY" \
  && ok "1(AC7e): worker files routed to _bug8_record_carryover" \
  || no "1(AC7e): carryover record missing/empty ($CARRY)"
[[ -z "$(git -C "$R1" diff --name-only --cached HEAD)" ]] \
  && ok "1(AC7e): nothing staged — the downgrade happens BEFORE any git add" \
  || no "1(AC7e): index has staged content"
git -C "$R1" diff --name-only HEAD | grep -qx 'b.txt' \
  && ok "1(AC7e): the worker's edit is preserved uncommitted for the next fix contract" \
  || no "1(AC7e): the worker's edit disappeared"
print -r -- "$GATE_LOG" | grep -q "pid=$FOREIGN_PID" \
  && print -r -- "$GATE_LOG" | grep -q 'mode=native' \
  && print -r -- "$GATE_LOG" | grep -q 'slug=other' \
  && ok "1(AC7e): logs WHICH foreign leader caused it (mode + slug + pid)" \
  || no "1(AC7e): foreign-leader identity not logged (log: $(print -r -- "$GATE_LOG" | tr '\n' '|'))"
kill "$FOREIGN_PID" 2>/dev/null; wait "$FOREIGN_PID" 2>/dev/null

# ===========================================================================
# Case 2 (NEGATIVE CONTROL — proves non-vacuity) — no registry entry at all →
# F-8 auto-commits exactly as before. A hardcoded downgrade fails here, and so
# does silently disabling F-8.
# ===========================================================================
R2="$TMP/c2"; mkrepo "$R2"
D2="$TMP/desk2"; mkdir -p "$D2/logs"      # DESK exists, registry dir does not
print -r -- "worker work" >> "$R2/b.txt"
run_gate "$R2" "$D2"; rc2=$?
(( rc2 == 0 )) && ok "2(control): gate allows synthesis (rc 0)" \
  || no "2(control): expected rc 0, got $rc2 (BLOCKED='$BLOCKED')"
(( $(recovery_commits "$R2") == 1 )) \
  && ok "2(control): NO registry entry → F-8 auto-commits exactly one leader-recovery commit" \
  || no "2(control): expected 1 leader-recovery commit, got $(recovery_commits "$R2") — F-8 is broken or hardcoded to downgrade"
git -C "$R2" show --pretty=format: --name-only HEAD | grep -qx 'b.txt' \
  && ok "2(control): the Worker's file is in the recovery commit" \
  || no "2(control): recovery commit does not contain b.txt"
[[ ! -s "$CARRY" ]] \
  && ok "2(control): no carryover recorded on the auto-commit path" \
  || no "2(control): a carryover was recorded despite a successful auto-commit"

# Case 2b — the registry DIRECTORY exists but is empty (a fully-cleaned root).
R2B="$TMP/c2b"; mkrepo "$R2B"
D2B="$TMP/desk2b"; mkdir -p "$(regdir "$D2B")"
print -r -- "worker work" >> "$R2B/b.txt"
run_gate "$R2B" "$D2B" >/dev/null 2>&1
(( $(recovery_commits "$R2B") == 1 )) \
  && ok "2b(control): empty registry dir → still auto-commits (an empty dir is not a foreign leader)" \
  || no "2b(control): empty registry dir suppressed the auto-commit"

# ===========================================================================
# Case 3 (AC7d) — a STALE entry (dead PID) is pruned by the reader and does NOT
# downgrade. The native leader is an LLM and is the least reliable party at
# running its own cleanup, so reader-side pruning is load-bearing: without it a
# dead native entry would downgrade F-8 forever.
# ===========================================================================
R3="$TMP/c3"; mkrepo "$R3"
D3="$TMP/desk3"; mkdir -p "$(regdir "$D3")"
sleep 300 & DEAD_PID=$!
kill "$DEAD_PID" 2>/dev/null; wait "$DEAD_PID" 2>/dev/null      # PID now dead, file stays
STALE="$(regdir "$D3")/$DEAD_PID.json"
printf '{"schema_version":"1.0","pid":%s,"mode":"native","slug":"ghost","root":"%s","started_at":"2026-08-10T00:00:00Z"}\n' \
  "$DEAD_PID" "$R3" > "$STALE"
print -r -- "worker work" >> "$R3/b.txt"
run_gate "$R3" "$D3"; rc3=$?
(( rc3 == 0 )) && ok "3(AC7d): gate allows synthesis (rc 0)" || no "3(AC7d): expected rc 0, got $rc3"
(( $(recovery_commits "$R3") == 1 )) \
  && ok "3(AC7d): stale (dead-PID) entry does NOT downgrade — F-8 auto-commits" \
  || no "3(AC7d): a dead entry downgraded F-8 (got $(recovery_commits "$R3") recovery commits) — liveness is not PID-checked"
[[ ! -e "$STALE" ]] \
  && ok "3(AC7d): the stale entry was UNLINKED in the same read pass (reader-side prune)" \
  || no "3(AC7d): stale entry survived the read — a dead native leader would downgrade F-8 forever"

# ===========================================================================
# Case 4 (AC7f) — the leader's OWN entry must never downgrade its own F-8.
# ===========================================================================
R4="$TMP/c4"; mkrepo "$R4"
D4="$TMP/desk4"; mkdir -p "$(regdir "$D4")"
SELF="$(regdir "$D4")/$$.json"
printf '{"schema_version":"1.0","pid":%s,"mode":"tmux","slug":"reg-test","root":"%s","started_at":"2026-08-10T00:00:00Z"}\n' \
  "$$" "$R4" > "$SELF"
print -r -- "worker work" >> "$R4/b.txt"
run_gate "$R4" "$D4"; rc4=$?
(( rc4 == 0 )) && ok "4(AC7f): gate allows synthesis (rc 0)" || no "4(AC7f): expected rc 0, got $rc4"
(( $(recovery_commits "$R4") == 1 )) \
  && ok "4(AC7f): own \$\$ entry is excluded — F-8 auto-commits (no permanent self-downgrade)" \
  || no "4(AC7f): the leader downgraded on its OWN registration — self-exclusion missing"
[[ -e "$SELF" ]] \
  && ok "4(AC7f): the leader's own live entry is not pruned by its own read" \
  || no "4(AC7f): the reader deleted its own live entry"

# Case 4b — own entry AND a live foreign entry: self-exclusion must not mask the
# foreign one.
R4B="$TMP/c4b"; mkrepo "$R4B"
D4B="$TMP/desk4b"; mkdir -p "$(regdir "$D4B")"
printf '{"schema_version":"1.0","pid":%s,"mode":"tmux","slug":"reg-test","root":"%s","started_at":"2026-08-10T00:00:00Z"}\n' \
  "$$" "$R4B" > "$(regdir "$D4B")/$$.json"
sleep 300 & FOREIGN2=$!
printf '{"schema_version":"1.0","pid":%s,"mode":"native","slug":"other","root":"%s","started_at":"2026-08-10T00:00:00Z"}\n' \
  "$FOREIGN2" "$R4B" > "$(regdir "$D4B")/$FOREIGN2.json"
print -r -- "worker work" >> "$R4B/b.txt"
run_gate "$R4B" "$D4B" >/dev/null 2>&1
(( $(recovery_commits "$R4B") == 0 )) \
  && ok "4b(AC7f): self-exclusion skips only \$\$ — a coexisting live foreign entry still downgrades" \
  || no "4b(AC7f): self-exclusion swallowed the foreign entry too"
kill "$FOREIGN2" 2>/dev/null; wait "$FOREIGN2" 2>/dev/null

# ===========================================================================
# Case 5 (AC7g) — unreadable registry dir → FAIL-CLOSED to carryover. Mirrors
# the GIT-FC idiom in Gate 3: an IO error must not read as "no foreign leaders".
# ===========================================================================
if [[ "$(id -u)" == "0" ]]; then
  skip "5(AC7g): running as root — chmod 000 is not enforced; fail-closed read not exercised"
else
  R5="$TMP/c5"; mkrepo "$R5"
  D5="$TMP/desk5"; RD5="$(regdir "$D5")"; mkdir -p "$RD5"
  chmod 000 "$RD5"
  print -r -- "worker work" >> "$R5/b.txt"
  run_gate "$R5" "$D5"; rc5=$?
  chmod 755 "$RD5"
  (( rc5 == 0 )) && ok "5(AC7g): fail-closed read is graceful (rc 0, no BLOCK)" \
    || no "5(AC7g): expected rc 0, got $rc5 (BLOCKED='$BLOCKED')"
  (( $(recovery_commits "$R5") == 0 )) \
    && ok "5(AC7g): unreadable registry → carryover, NOT auto-commit (fail-closed)" \
    || no "5(AC7g): an unreadable registry read as 'no foreign leaders' (fail-OPEN)"
  [[ -s "$CARRY" ]] \
    && ok "5(AC7g): carryover recorded on the fail-closed path" \
    || no "5(AC7g): no carryover recorded"
fi

# ===========================================================================
# Registry mechanics (AC7a / AC7c)
# ===========================================================================
print -P "%F{cyan}registry mechanics%f"

RM="$TMP/mech"; DM="$TMP/deskm"
ROOT="$RM"; DESK="$DM"; ROOT_HASH="testhash"; SLUG="mech-slug"
mkdir -p "$RM"
register_leader "tmux"; rcR=$?
ENTRY="$(regdir "$DM")/$$.json"
(( rcR == 0 )) && ok "M1(AC7a): register_leader returns 0 (advisory — never fails a campaign)" \
  || no "M1(AC7a): register_leader returned $rcR"
[[ -f "$ENTRY" ]] && ok "M2(AC7a): entry written at \$DESK/logs/.rlp-desk-leaders-\$ROOT_HASH.d/<pid>.json" \
  || no "M2(AC7a): entry not at the contracted path ($ENTRY)"
if [[ -f "$ENTRY" ]]; then
  jq -e . "$ENTRY" >/dev/null 2>&1 && ok "M3(AC7a): entry is valid JSON" || no "M3(AC7a): entry is not valid JSON"
  [[ "$(jq -r '.schema_version' "$ENTRY" 2>/dev/null)" == "1.0" ]] \
    && ok "M4(AC7a): schema_version 1.0 present" || no "M4(AC7a): schema_version missing/wrong"
  [[ "$(jq -r '.pid' "$ENTRY" 2>/dev/null)" == "$$" ]] \
    && ok "M5(AC7a): pid recorded" || no "M5(AC7a): pid wrong"
  [[ "$(jq -r '.mode' "$ENTRY" 2>/dev/null)" == "tmux" ]] \
    && ok "M6(AC7a): mode recorded" || no "M6(AC7a): mode wrong"
  [[ "$(jq -r '.slug' "$ENTRY" 2>/dev/null)" == "mech-slug" ]] \
    && ok "M7(AC7a): slug recorded" || no "M7(AC7a): slug wrong"
  [[ "$(jq -r '.root' "$ENTRY" 2>/dev/null)" == "$RM" ]] \
    && ok "M8(AC7a): root recorded (sanity check against a relocated checkout)" || no "M8(AC7a): root wrong"
  [[ -n "$(jq -r '.started_at // empty' "$ENTRY" 2>/dev/null)" ]] \
    && ok "M9(AC7a): started_at recorded" || no "M9(AC7a): started_at missing"
fi
# atomic_write leaves no .tmp residue (truncation safety — a torn entry would
# be unparseable, and an unparseable entry is treated fail-closed).
[[ -z "$(print -l "$(regdir "$DM")"/*.tmp.*(N))" ]] \
  && ok "M10(AC7a): no .tmp residue — the write went through atomic_write" \
  || no "M10(AC7a): a tmp file was left behind in the registry dir"
# Re-registering over our own pre-existing (by definition stale) entry must work:
# set -C would refuse here, which is exactly why the spec mandates atomic_write.
register_leader "tmux"; rcR2=$?
(( rcR2 == 0 )) && [[ -f "$ENTRY" ]] \
  && ok "M11(AC7a): re-registering over an existing <pid>.json succeeds (plain overwrite, not set -C)" \
  || no "M11(AC7a): re-registration failed — noclobber semantics leaked in"
unregister_leader; rcU=$?
(( rcU == 0 )) && [[ ! -e "$ENTRY" ]] \
  && ok "M12(AC7c): unregister_leader removes its own entry (best-effort, rc 0)" \
  || no "M12(AC7c): own entry not removed (rc=$rcU)"
# Advisory: registration must not fail (or exit) when the registry dir cannot be
# created — a campaign is never blocked by the registry.
DESK="/proc/nonexistent-rlp-desk-$$"
register_leader "tmux"; rcR3=$?
(( rcR3 == 0 )) && ok "M13(AC7a): unwritable registry path → logged and ignored, still rc 0 (advisory)" \
  || no "M13(AC7a): registration hard-failed on an unwritable path (rc=$rcR3)"
unregister_leader >/dev/null 2>&1
DESK="$DM"

# ===========================================================================
# Structural contracts
# ===========================================================================
print -P "%F{cyan}structural contracts%f"

# AC7a — never reuse the exclusive runner lock.
regblk=$(awk '/^_leader_registry_dir\(\)/,/^}$/' "$LIB")
print -r -- "$regblk" | grep -q 'RUNNER_LOCKFILE_PATH' \
  && no "S1(AC7a): the registry path is derived from RUNNER_LOCKFILE_PATH (exclusive lock reuse)" \
  || ok "S1(AC7a): registry path does not reuse RUNNER_LOCKFILE_PATH"
print -r -- "$regblk" | grep -q 'rlp-desk-leaders-' \
  && ok "S1b(AC7a): registry dir is the contracted .rlp-desk-leaders-\$ROOT_HASH.d" \
  || no "S1b(AC7a): registry dir name does not match the contract"
awk '/^register_leader\(\)/,/^}$/' "$LIB" | grep -q 'atomic_write' \
  && ok "S2(AC7a): register_leader writes via atomic_write (truncation safety)" \
  || no "S2(AC7a): register_leader does not use atomic_write"
# Code lines only — the function's comment block explains why set -C is banned.
awk '/^register_leader\(\)/,/^}$/' "$LIB" | grep -v '^[[:space:]]*#' | grep -q 'set -C' \
  && no "S2b(AC7a): register_leader uses set -C (banned — would refuse a stale own-PID file)" \
  || ok "S2b(AC7a): no set -C in register_leader"
awk '/^_leader_registry_foreign_live\(\)/,/^}$/' "$LIB" | grep -q 'kill -0' \
  && ok "S3(AC7d): liveness is kill -0 at read time" || no "S3(AC7d): no kill -0 liveness check"
awk '/^_leader_registry_foreign_live\(\)/,/^}$/' "$LIB" | grep -qiE 'ttl|mtime|age' \
  && no "S3b(AC7d): an age/TTL heuristic crept in (staleness must be PID-based only)" \
  || ok "S3b(AC7d): no TTL/age heuristic — PID-based staleness only"

# AC7b/AC7c — zsh leader call sites.
grep -q 'register_leader "tmux"' "$RUN" \
  && ok "S4(AC7b): the zsh leader registers itself at startup" \
  || no "S4(AC7b): no register_leader call in run_ralph_desk.zsh"
awk '/^cleanup\(\)/,/^}$/' "$RUN" | grep -q 'unregister_leader' \
  && ok "S5(AC7c): the zsh leader deregisters in cleanup()" \
  || no "S5(AC7c): no unregister_leader call in cleanup()"

# AC7e — the downgrade sits immediately before _bug8_autocommit, so the read
# window is microseconds rather than the whole comm/log sequence, and D-20's
# "already committed" no-op still wins ahead of it.
f8blk=$(awk '/local -a _bug8_add=/,/bug8=autocommit_failed_continue/' "$RUN")
print -r -- "$f8blk" | grep -q '_leader_registry_foreign_live' \
  && ok "S6(AC7e): the registry read is inside the F-8 auto-commit branch" \
  || no "S6(AC7e): the registry read is not in the F-8 branch"
dg_line=$(grep -n '_leader_registry_foreign_live' "$RUN" | head -1 | cut -d: -f1)
ac_line=$(grep -n '_bug8_autocommit "\$ROOT"' "$RUN" | head -1 | cut -d: -f1)
d20_line=$(grep -n 'git -C "\$ROOT" diff --quiet HEAD -- "\${_bug8_add\[@\]}"' "$RUN" | head -1 | cut -d: -f1)
[[ -n "$dg_line" && -n "$ac_line" && -n "$d20_line" ]] && (( d20_line < dg_line && dg_line < ac_line )) \
  && ok "S7(AC7e): read order is D-20 no-op (L$d20_line) → registry (L$dg_line) → auto-commit (L$ac_line)" \
  || no "S7(AC7e): wrong ordering (d20=$d20_line registry=$dg_line autocommit=$ac_line)"

# AC7b — native leader instructions (SV-gated surface).
grep -q 'rlp-desk-leaders-' "$CMD" \
  && ok "S8(AC7b): rlp-desk.md instructs the native leader to register at the identical path" \
  || no "S8(AC7b): no registry path in rlp-desk.md"
# The JSON in rlp-desk.md lives inside a Bash("…") string, so its quotes are
# backslash-escaped — match schema_version and its value, not a literal `"1.0"`.
grep -qE 'schema_version[\\": ]+1\.0' "$CMD" \
  && ok "S9(AC7b): rlp-desk.md pins the identical schema (schema_version 1.0)" \
  || no "S9(AC7b): rlp-desk.md does not pin schema_version 1.0"
grep -qiE 'advisory' "$CMD" \
  && ok "S10(AC7b): rlp-desk.md states the registry is advisory" \
  || no "S10(AC7b): rlp-desk.md does not state the advisory contract"
# awk-side window (no `head`): under pipefail a SIGPIPE'd awk would fail the
# pipeline even on a successful grep match.
awk '/rlp-desk-leaders-/{found=1} found{print; if (++n >= 20) exit}' "$CMD" \
  | grep -qiE 'never (exit|fail)|must not (exit|fail)|non-fatal' \
  && ok "S11(AC7b): rlp-desk.md forbids failing/exiting on a busy namespace" \
  || no "S11(AC7b): rlp-desk.md does not forbid hard-failing on a busy namespace"
grep -qiE 'deregister|unregister|remove .*<pid>\.json' "$CMD" \
  && ok "S12(AC7c): rlp-desk.md instructs deregistration at loop end" \
  || no "S12(AC7c): no deregistration instruction in rlp-desk.md"
grep -q 'rlp-desk-leaders-' "$GOV" \
  && ok "S13(AC7b): governance.md carries the registry contract" \
  || no "S13(AC7b): governance.md has no registry contract"

# AC7h — documented path-agreement caveat.
grep -q 'RLP_DESK_RUNTIME_DIR' "$FMODES" \
  && ok "S14(AC7h): failure-modes.md documents the RLP_DESK_RUNTIME_DIR caveat" \
  || no "S14(AC7h): RLP_DESK_RUNTIME_DIR caveat missing from failure-modes.md"
grep -qiE 'no-op|no op' "$FMODES" \
  && ok "S15(AC7h): failure-modes.md states the mismatch makes Option D a silent no-op" \
  || no "S15(AC7h): the silent-no-op consequence is not documented"

print ""
print "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
(( FAIL == 0 )) || exit 1
