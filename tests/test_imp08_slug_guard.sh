#!/usr/bin/env zsh
# IMP-08 — zsh leader slug hard-reject guard (init + run entrypoints).
#
# SLUG is interpolated raw into $DESK/logs/$SLUG / mkdir / rm / analytics
# paths, so a traversal/separator/uppercase slug must be rejected BEFORE any
# filesystem op. The guard `^[a-z0-9][a-z0-9-]*$` is a superset of the Node
# normalizeSlug alphabet, so no valid slug breaks; it blocks `.`/`/`/`..`/
# uppercase/spaces. This test drives the two entrypoints with bad + good slugs
# and asserts the exit code and that no logs dir was created for a bad slug.
set -uo pipefail
REPO="${0:A:h:h}"
RUN="$REPO/src/scripts/run_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

# run_ralph_desk.zsh reads SLUG from $LOOP_NAME; guard is near the top (before
# any mkdir). We only need to reach that guard, so run in a throwaway ROOT and
# assert the exit code + no traversal dir created.
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT

# --- run leader: bad slug rejected (exit 2), no dir escape ---
outside="$sandbox/OUTSIDE"; mkdir -p "$outside"
( cd "$sandbox" && LOOP_NAME='../../OUTSIDE' ROOT="$sandbox/proj" \
    zsh "$RUN" >/dev/null 2>&1 )
rc=$?
[[ $rc -eq 2 ]] && ok "run: LOOP_NAME='../../OUTSIDE' → exit 2 (rejected)" || no "run: expected exit 2, got $rc"
[[ -d "$outside" && ! -e "$sandbox/proj/.rlp-desk/logs/../../OUTSIDE" ]] && ok "run: no traversal path created" || no "run: traversal path may have been created"

# uppercase (non-traversal) also rejected
( cd "$sandbox" && LOOP_NAME='My_App' ROOT="$sandbox/proj2" zsh "$RUN" >/dev/null 2>&1 )
[[ $? -eq 2 ]] && ok "run: LOOP_NAME='My_App' → exit 2 (non-canonical rejected)" || no "run: uppercase slug not rejected"

# --- init: bad slug rejected before scaffolding ---
( cd "$sandbox" && ROOT="$sandbox/initproj" zsh "$INIT" '../x' >/dev/null 2>&1 )
rc_i=$?
[[ $rc_i -eq 2 ]] && ok "init: '../x' → exit 2 (rejected)" || no "init: expected exit 2, got $rc_i"
[[ ! -d "$sandbox/initproj/.rlp-desk/logs" ]] && ok "init: no scaffold created for bad slug" || no "init: scaffold created despite bad slug"

# --- good slug passes the guard (reaches later logic; exit code is NOT 2-for-guard).
#     We can't fully run a campaign, but the guard must not fire: assert the run
#     leader does NOT exit 2 with the guard's specific message for a valid slug.
guard_msg=$( ( cd "$sandbox" && LOOP_NAME='my-feature-1' ROOT="$sandbox/good" \
    timeout 5 zsh "$RUN" 2>&1 ) | grep -c 'invalid slug: my-feature-1' )
[[ "$guard_msg" -eq 0 ]] && ok "run: valid slug 'my-feature-1' passes the guard (no 'invalid slug' error)" || no "run: valid slug wrongly rejected"

print ""
if (( FAIL == 0 )); then print "imp08-slug-guard: $PASS/$((PASS+FAIL)) PASS"; else print "imp08-slug-guard: $PASS pass, $FAIL FAIL"; fi
exit $(( FAIL > 0 ))
