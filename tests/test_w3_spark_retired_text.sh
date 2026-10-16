#!/usr/bin/env zsh
# W3 J-08: `spark` / `gpt-5.3-codex-spark` is a RETIRED alias — _normalize_model_spec
# remaps it to gpt-6-luna with a "[model-remap] WARNING". Shipped text must not present
# spark as a distinct model: no spark preset / recommendation, no "100k context" or
# "100k output limit" claim, no "small tasks only" steering.
#   S1  the run-preset menu init prints (codex present) mentions no spark at all.
#   S2  prose scan (rlp-desk.md, init_ralph_desk.zsh, model-upgrade-table.md, README.md,
#       docs/rlp-desk/*.md top level): no spark+100k claim, no bare `spark:<effort>` value,
#       no spark-preset wording. Retired-id LADDER rows (`gpt-5.3-codex-spark:<effort>`,
#       model-upgrade-table.md, kept deliberately under dated retirement notes) are exempt.
#   S3  every bare-`spark` mention in rlp-desk.md / README.md says it is retired/remapped.
#   S4  same scan as S2 over src/governance.md (separate id so a governance-only gap is visible).
# docs/rlp-desk/{plans,internal,blueprints}/ are dated historical design records, not scanned.
set -uo pipefail
REPO="${0:A:h:h}"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

print -r -- "== S1: the generated run-preset menu has no spark =="
mkdir -p "$TMP/bin" "$TMP/proj"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/codex"; chmod +x "$TMP/bin/codex"
out=$( cd "$TMP/proj" && git init -q && PATH="$TMP/bin:$PATH" ROOT="$TMP/proj" zsh "$INIT" slugx "obj" 2>&1 ); rc=$?
if (( rc == 0 )) && [[ "$out" == *"Recommended: cross-engine"* ]]; then
  if print -r -- "$out" | grep -qi 'spark'; then no "S1 init output still mentions spark: $(print -r -- "$out" | grep -i spark | head -3 | tr '\n' '|')"
  else ok "S1 codex-present preset menu + options reference mention no spark"; fi
else no "S1 init rc=$rc or the codex-present menu was not printed (harness problem)"; fi

# scan_file <file>: prints one "file:line: text" per violation
scan_file() {
  local f="$1"
  grep -n -i 'spark' "$f" | grep -i -E '100 ?k|100,000' | sed "s|^|${f}:100k-claim:|"
  grep -n -E '(^|[^-[:alnum:]])spark[:= ](low|medium|high|xhigh|max)|--worker-model[ =]spark' "$f" | grep -v -i 'retired' | sed "s|^|${f}:spark-value:|"
  grep -n -i -E 'spark[^.]{0,20}preset|preset[^.]{0,20}spark|small tasks only' "$f" | sed "s|^|${f}:spark-preset:|"
}
scan() { local f; for f in "$@"; do [[ -f "$f" ]] && scan_file "$f"; done; }

print -r -- "== S2: no stale spark preset / 100k claim in shipped prose =="
files=( "$REPO/src/commands/rlp-desk.md" "$INIT" "$REPO/src/model-upgrade-table.md" "$REPO/README.md" "$REPO"/docs/rlp-desk/*.md(N) )
hits=$(scan "${files[@]}")
if [[ -z "$hits" ]]; then ok "S2 no spark 100k claim, bare spark:<effort> value or spark preset wording in ${#files} files"
else no "S2 stale spark text:"$'\n'"$(print -r -- "$hits" | cut -c1-200 | sed 's/^/      /')"; fi

print -r -- "== S3: bare spark mentions are marked retired/remapped =="
bad=$(grep -n -i -w 'spark' "$REPO/src/commands/rlp-desk.md" "$REPO/README.md" | grep -v -i -E 'retired|remap')
if [[ -z "$bad" ]]; then ok "S3 every bare spark mention in rlp-desk.md and README.md says retired/remap"
else no "S3 unqualified spark mention:"$'\n'"$(print -r -- "$bad" | cut -c1-200 | sed 's/^/      /')"; fi

print -r -- "== S4: governance.md =="
ghits=$(scan "$REPO/src/governance.md")
if [[ -z "$ghits" ]]; then ok "S4 governance.md has no stale spark text"
else no "S4 governance.md stale spark text:"$'\n'"$(print -r -- "$ghits" | cut -c1-200 | sed 's/^/      /')"; fi

print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
