#!/usr/bin/env zsh
# vision-adopt §1b (3-doc consistency lint), §4 (IL-2¾ 검증형 verification-type),
# §5 (init CLI version stamp). zsh side.
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
INIT="$REPO/src/scripts/init_ralph_desk.zsh"
GOV="$REPO/src/governance.md"
CMD="$REPO/src/commands/rlp-desk.md"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); print "  PASS: $1"; }
fail() { FAIL=$((FAIL+1)); print "  FAIL: $1"; }

print "=== vision-adopt §1b/§4/§5 (zsh) ==="
print

source "$LIB" 2>/dev/null
log() { :; }; log_error() { :; }; log_warn() { :; }; log_debug() { :; }

# ===========================================================================
# §1b: 3-doc consistency lint (PRD ↔ test-spec ↔ per-US split)
# ===========================================================================
TMP=$(mktemp -d "${TMPDIR:-/tmp}/rlp-vadopt-XXXX"); trap "rm -rf '$TMP'" EXIT
P="$TMP/plans"; mkdir -p "$P"

_build_consistent() {
  rm -f "$P"/*.md(N) 2>/dev/null
  printf '### US-001: First\n- AC1: a\n- AC2: b\n### US-002: Second\n- AC1: c\n' > "$P/prd-demo.md"
  split_prd_by_us "$P/prd-demo.md" demo >/dev/null 2>&1
  printf '## US-001: First\n- verify AC1\n- verify AC2\n## US-002: Second\n- verify AC1\n' > "$P/test-spec-demo.md"
}

# (a) Consistent set → strict rc=0, clean stdout, no stderr violations.
_build_consistent
out=$(_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo strict 2>"$TMP/err"; echo "rc=$?")
if [[ "$out" == "rc=0" && ! -s "$TMP/err" ]]; then
  pass "§1b-a: consistent 3-doc set passes strict (rc=0, no stdout leak, no stderr)"
else
  fail "§1b-a: out='$out' stderr='$(cat "$TMP/err")'"
fi

# (b) Orphan per-US split → violation + strict rc=1.
_build_consistent
touch "$P/prd-demo-US-099.md"
_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo strict 2>"$TMP/err"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "orphan split: prd-demo-US-099.md" "$TMP/err"; then
  pass "§1b-b: orphan per-US split file is rejected"
else
  fail "§1b-b: rc=$rc stderr='$(cat "$TMP/err")'"
fi

# (c) Test-spec references an AC the PRD does not declare (on a STRUCTURED list
# line) → ADVISORY only, NOT a strict REJECT (MEDIUM-2: never hard-block init on a
# human-authored test-spec parse). rc stays 0; the advisory is emitted.
_build_consistent
printf '## US-002: Second\n- verify AC9\n' >> "$P/test-spec-demo.md"
_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo strict 2>"$TMP/err"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "ADVISORY: test-spec references US-002/AC9 but PRD US-002 has no" "$TMP/err"; then
  pass "§1b-c: test-spec AC id not in PRD is ADVISORY (not a strict REJECT)"
else
  fail "§1b-c: rc=$rc stderr='$(cat "$TMP/err")'"
fi

# (c2) An AC id mentioned in FREE PROSE (not a list/table line) under a US heading
# must NOT trigger even the advisory — scoped extraction ignores prose.
_build_consistent
printf '## US-002: Second\nThis behaves unlike US-1 and reuses the AC9 idea in passing.\n' >> "$P/test-spec-demo.md"
_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo strict 2>"$TMP/err"; rc=$?
if [[ "$rc" -eq 0 ]] && ! grep -q "AC9" "$TMP/err"; then
  pass "§1b-c2: cross-US AC id in free prose → no REJECT, no advisory (scoped to structured lines)"
else
  fail "§1b-c2: rc=$rc stderr='$(cat "$TMP/err")'"
fi

# (d) Per-US AC-count drift between PRD monolithic and per-US split file.
_build_consistent
printf '### US-001: First\n- AC1: a\n' > "$P/prd-demo-US-001.md"   # split now has 1 AC, PRD has 2
_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo strict 2>"$TMP/err"; rc=$?
if [[ "$rc" -eq 1 ]] && grep -q "AC-count drift for US-001: PRD=2 split=1" "$TMP/err"; then
  pass "§1b-d: per-US AC-count drift (PRD vs split) is rejected"
else
  fail "§1b-d: rc=$rc stderr='$(cat "$TMP/err")'"
fi

# (e) WARN mode never returns non-zero (mirrors gate-receipt WARN-loud).
_build_consistent
touch "$P/prd-demo-US-099.md"
_lint_3doc_consistency "$P/prd-demo.md" "$P/test-spec-demo.md" "$P" demo warn 2>"$TMP/err"; rc=$?
if [[ "$rc" -eq 0 ]] && grep -q "WARN — PRD/test-spec/split inconsistency" "$TMP/err"; then
  pass "§1b-e: warn mode is WARN-loud + proceed (rc=0)"
else
  fail "§1b-e: rc=$rc stderr='$(cat "$TMP/err")'"
fi

# (f) No US structure → no-op (never a false reject on an unstructured PRD).
rm -f "$P"/*.md(N) 2>/dev/null
printf 'freeform PRD with no US headings\n' > "$P/prd-demo.md"
_lint_3doc_consistency "$P/prd-demo.md" "" "$P" demo strict 2>"$TMP/err"; rc=$?
[[ "$rc" -eq 0 && ! -s "$TMP/err" ]] && pass "§1b-f: unstructured PRD is a no-op" \
  || fail "§1b-f: rc=$rc stderr='$(cat "$TMP/err")'"

# (g) init wires §1b as a REJECT (source-level assert) + run wires it as WARN.
grep -q '_lint_3doc_consistency .* strict' "$INIT" \
  && pass "§1b-g: init invokes the lint in strict/REJECT mode" \
  || fail "§1b-g: init strict wiring missing"
grep -q '_lint_3doc_consistency .* warn' "$REPO/src/scripts/run_ralph_desk.zsh" \
  && pass "§1b-h: run invokes the lint in warn mode" \
  || fail "§1b-h: run warn wiring missing"

# ===========================================================================
# §1a HIGH-1: schema-1.0 receipt backward-compat (zsh side)
# ===========================================================================
if command -v jq >/dev/null 2>&1; then
  rm -f "$P"/*.md(N) "$P"/gate-receipt-*.json(N) 2>/dev/null
  printf 'prd\n' > "$P/prd-legacy.md"
  printf 'ts\n' > "$P/test-spec-legacy.md"
  LEG=$(_compute_prd_only_hash "$P" legacy)
  print -r -- "{\"schema_version\":\"1.0\",\"slug\":\"legacy\",\"prd_sha256\":\"$LEG\",\"prd_files\":[\"prd-legacy.md\"],\"scorecard\":\"PASS:1\",\"passed_at\":\"2026-01-01T00:00:00Z\"}" > "$P/gate-receipt-legacy.json"

  st=$(verify_gate_receipt "$P" legacy)
  LEGLOG="$TMP/cr-legacy.jsonl"
  append_contract_revisions "$P" legacy "$LEGLOG"
  n=$([[ -f "$LEGLOG" ]] && wc -l < "$LEGLOG" | tr -d ' ' || echo 0)
  [[ "$st" == "ok" && "$n" -eq 0 ]] \
    && pass "§1a-HIGH1-a: 1.0 receipt + untouched PRD+test-spec → ok, no record" \
    || fail "§1a-HIGH1-a: verify=$st records=$n"

  # Editing ONLY the test-spec must NOT mismatch a 1.0 receipt.
  printf 'ts EDITED\n' > "$P/test-spec-legacy.md"
  st2=$(verify_gate_receipt "$P" legacy)
  [[ "$st2" == "ok" ]] && pass "§1a-HIGH1-b: 1.0 receipt + test-spec-only edit → still ok (PRD-only basis)" \
    || fail "§1a-HIGH1-b: verify=$st2"

  # A real PRD edit is still detected.
  printf 'prd EDITED\n' > "$P/prd-legacy.md"
  st3=$(verify_gate_receipt "$P" legacy)
  append_contract_revisions "$P" legacy "$LEGLOG"
  n3=$(wc -l < "$LEGLOG" | tr -d ' ')
  [[ "$st3" == "mismatch" && "$n3" -eq 1 ]] \
    && pass "§1a-HIGH1-c: 1.0 receipt + real PRD edit → mismatch + 1 record" \
    || fail "§1a-HIGH1-c: verify=$st3 records=$n3"
else
  print "  SKIP: §1a-HIGH1 (jq unavailable)"
fi

# ===========================================================================
# §4: IL-2¾ third work-type 검증형 (verification-type)
# ===========================================================================
grep -q '검증형' "$GOV" && pass "§4-a: governance IL-2¾ adds 검증형" || fail "§4-a: 검증형 missing in governance"
grep -q 'verify_existing' "$GOV" && grep -q 'verification-type' "$GOV" \
  && pass "§4-b: governance auto-assigns the verify_existing alternative gate for 검증형" \
  || fail "§4-b: verify_existing auto-assignment missing"
grep -q '검증형' "$CMD" && pass "§4-c: brainstorm step (rlp-desk.md) classifies 검증형" || fail "§4-c: 검증형 missing in rlp-desk.md"
# G3: the verification-type gate also states the NO-COMMIT expectation — a
# verification pass that changed no files must not manufacture an empty commit.
grep -q 'A verification-type US expects NO commit' "$GOV" \
  && pass "§4-d: governance states a verification-type US expects no commit" \
  || fail "§4-d: no-commit expectation missing from IL-2¾ §2"
grep -q 'empty_commit_on_confirmation_claim' "$GOV" \
  && pass "§4-e: governance names the empty-commit oracle reason (§1f½ inverse)" \
  || fail "§4-e: empty_commit_on_confirmation_claim missing from governance"

# ===========================================================================
# §5: init CLI version stamp
# ===========================================================================
# not-installed fallback present in the source (structural).
grep -q 'not installed' "$INIT" && pass "§5-a: init records absent tools as 'not installed'" || fail "§5-a: not-installed fallback missing"
# non-blocking: the stamp function returns 0 on every branch (no exit/blocking).
grep -q 'write_init_env_stamp' "$INIT" && pass "§5-b: init calls write_init_env_stamp" || fail "§5-b: stamp call missing"

# Behavioral: a real init writes init-env.json with cli_versions.{codex,claude}.
if command -v jq >/dev/null 2>&1; then
  IT=$(mktemp -d "${TMPDIR:-/tmp}/rlp-vadopt-init-XXXX")
  ROOT="$IT" zsh "$INIT" demo "obj" >/dev/null 2>&1
  STAMP="$IT/.rlp-desk/logs/demo/init-env.json"
  if [[ -f "$STAMP" ]]; then
    has_codex=$(jq -r 'has("cli_versions") and (.cli_versions|has("codex"))' "$STAMP" 2>/dev/null)
    has_claude=$(jq -r '.cli_versions|has("claude")' "$STAMP" 2>/dev/null)
    [[ "$has_codex" == "true" && "$has_claude" == "true" ]] \
      && pass "§5-c: init writes init-env.json with cli_versions.{codex,claude}" \
      || fail "§5-c: init-env.json missing cli_versions keys"
  else
    fail "§5-c: init-env.json not written"
  fi
  rm -rf "$IT"

  # (d) REGRESSION (SV gate): a PRESENT-but-FAILING codex (nonzero exit) must NOT
  # abort init under `set -euo pipefail`; it is recorded as "unknown" and init
  # completes rc=0. Mirrors the SV worker's PATH-stub harness.
  ST=$(mktemp -d "${TMPDIR:-/tmp}/rlp-vadopt-stub-XXXX")
  mkdir -p "$ST/bin" "$ST/root"
  cat > "$ST/bin/codex" <<'STUB'
#!/bin/sh
echo "GARBAGE not a version" >&2
echo "more garbage on stdout"
exit 17
STUB
  chmod +x "$ST/bin/codex"
  # Real codex/claude live under /opt/homebrew/bin; a PATH of stub:/usr/bin:/bin
  # makes `codex` resolve to the failing stub and `claude` genuinely absent.
  out=$(PATH="$ST/bin:/usr/bin:/bin" ROOT="$ST/root" zsh "$INIT" stubdemo "obj" 2>&1); rc=$?
  STUBSTAMP="$ST/root/.rlp-desk/logs/stubdemo/init-env.json"
  if [[ "$rc" -eq 0 && -f "$STUBSTAMP" ]]; then
    cv=$(jq -r '.cli_versions.codex' "$STUBSTAMP" 2>/dev/null)
    [[ "$cv" == "unknown" ]] \
      && pass "§5-d: present-but-failing codex (exit 17) → init rc=0 + codex='unknown' (set -e safe)" \
      || fail "§5-d: codex field='$cv' (expected 'unknown')"
  else
    fail "§5-d: init aborted or stamp missing (rc=$rc, stamp=$([[ -f $STUBSTAMP ]] && echo yes || echo no)) tail='$(print -r -- "$out" | tail -5)'"
  fi
  rm -rf "$ST"
else
  print "  SKIP: §5-c/§5-d behavioral (jq unavailable)"
fi

print
print "=== RESULTS: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
