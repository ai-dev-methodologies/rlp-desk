#!/usr/bin/env bash
# Test suite: init_ralph_desk.zsh data-safety regressions (reaudit wave 1)
#
# A-6: `sed -i '' "s|{DESK}|$DESK|g; s|{SLUG}|$SLUG|g" "$F"` is BSD/macOS-only.
#      On GNU sed (Ubuntu CI) this exits 2 and `set -euo pipefail` aborts init
#      right after the heredoc already wrote the prompt file, so the
#      `[[ ! -f "$F" ]]` idempotency guard silently skips the block on re-run
#      and {DESK}/{SLUG} placeholders remain forever while init exits 0.
#      DESK/SLUG were also interpolated unescaped into the sed replacement, so
#      a `|` or `&` in the project path corrupts the substitution.
#
# A-7: `--mode fresh` decided "scaffold vs authored" PRD with a single regex
#      (`^### US-[0-9]+:` excluding `[Title]`) that missed the dash heading
#      form (`### US-001 - Title`) lib_ralph_desk.zsh's _extract_prd_us_list
#      officially accepts, and missed an authored body sitting under an
#      untouched placeholder heading. The misclassified-as-scaffold branch
#      then did a bare `rm` with no backup, and .rlp-desk/ is gitignored, so
#      the loss was permanent.
#
# Cases:
#   (a) GNU-sed rejection simulation: init still fully renders both prompt
#       files and does not abort, under a sed stub that fails the exact
#       broken `-i ''` invocation the way GNU sed does.
#   (b) A ROOT path containing `&` and `|` renders correctly, uncorrupted.
#   (c) --mode fresh on a dash-form authored PRD heading preserves it.
#   (d) --mode fresh on a PRD with an untouched placeholder heading but an
#       authored body elsewhere preserves it.
#   (e) --mode fresh on a byte-exact scaffold PRD regenerates it, but the
#       original is versioned (recoverable), never bare-deleted.
#   (f) same as (e), for the scaffold test-spec (same bare-`rm` class found
#       in the same fresh-mode block, fixed the same way).
#   (g) a never-edited scaffold PRD created with objective X, re-run
#       `--mode fresh` with a DIFFERENT objective Y, must still be
#       classified as scaffold (regenerated with the new objective, old one
#       versioned) — not misclassified as authored just because the
#       Objective line changed underneath it.
#   (h) an authored PRD (a real edit unrelated to the objective) must stay
#       Preserved even when --mode fresh is also given a different
#       objective — the objective mask must not paper over a real edit.
#
# split_prd_by_us() (SV-gate finding, reaudit wave 1 follow-up): the per-US
# split boundary regex was colon-only 3-hash (`^### US-[0-9]+:`), so a
# dash-form heading (`### US-001 - Title`) produced ZERO split files even
# though the loose upstream US-count check saw >=1 US. The resulting `ls`
# glob (no `(N)` null-glob qualifier) then errored NOMATCH under
# `set -euo pipefail`, aborting init AFTER the fresh-mode block had already
# version_file'd the old test-spec away but BEFORE the new one was written
# — leaving test-spec-$SLUG.md missing entirely. Separately, the same awk
# call passed the plans directory via `-v dir=...`, and POSIX awk -v applies
# C-style backslash-escape processing to its value, so a project root path
# containing a literal backslash silently corrupted the split target path.
#   (i) a dash-form PRD heading + --mode fresh: exit 0, the per-US split
#       file exists, and test-spec is present (the split boundary regex now
#       accepts both forms, matching lib_ralph_desk.zsh's
#       _extract_prd_us_list).
#   (j) a PRD heading matching NEITHER accepted form: init exits 0 and
#       gracefully falls back to full-PRD injection (a WARNING, not an
#       ERROR) — see the follow-up note below for why this changed from an
#       earlier revision of this test.
#   (k) a ROOT path containing a literal backslash: init exits 0 and the
#       per-US split file lands in the correct, uncorrupted directory
#       (ENVIRON instead of awk -v for the path).
#
# split_test_spec_by_us() + loose-gate/strict-splitter consistency (SV-gate
# review follow-up, HIGH): the sibling function had the identical bug class
# — missing (N) on two globs, colon-only strict regex vs. a loose
# `grep -c "^## US-"` gate, and it additionally orphaned a
# test-spec-$SLUG-header.tmp.$PID file in plans/ when the NOMATCH crash hit
# between writing that header tmp file and its `rm -f`. Fixed the same way
# (shared regex, array count, ENVIRON), and the header capture was moved
# from a tmp file into a shell variable so there is no file to orphan on
# any exit path. Both functions' loose gates use the EXACT SAME regex text
# as their own strict splitter, so gate and splitter can never disagree
# within one function — which is also why case (j) above changed from
# asserting a loud ERROR to asserting the graceful WARNING fallback: with
# gate == splitter, "gate saw >=1 but splitter found 0" is no longer
# reachable via a heading-form mismatch (only via duplicate US ids).
#   (l) a dash-form test-spec heading + a plain re-run: exit 0, the per-US
#       split file exists, no test-spec-*-header.tmp.* orphan is left in
#       plans/, the split file contains exactly one ## US-NNN heading (the
#       header-extraction awk's boundary regex is shared with the splitter
#       — a colon-only header regex would dump the WHOLE test-spec into
#       every split file's header instead of stopping at the real
#       boundary), the header prefix equals the source's pre-first-heading
#       bytes exactly, and init's output is byte-identical to
#       lib_ralph_desk.zsh's split_test_spec_by_us for the same fixture.
#   (m) a 2-hash-only PRD heading (## US-001 - Title): MUST NOT split — see
#       the "correction" note below. PRD story headings are 3-hash only by
#       contract (tests/test_us001_prd_splitting.sh AC1-L3-neg); a 2-hash
#       line is the test-spec section level, not a PRD story heading.
#
# split_prd_by_us / split_test_spec_by_us — SV-gate review round 3:
#   - awk's `close(out)` followed by a LATER `print > out` on the SAME
#     filename reopens it in TRUNCATE mode (verified directly: two
#     `print > f` blocks separated by `close(f)` leave only the second
#     block). A PRD appendix/TOC line reusing an earlier us_id (e.g. a
#     later "### US-001 rationale" section, still 3-hash) used to silently
#     wipe the real ### US-001 body written earlier. Fixed the mechanism (a
#     seen[] map: `>` truncate only the first time a us_id's target file is
#     written, `>>` append every time after), not the regex, in both
#     split_prd_by_us and split_test_spec_by_us.
#   - the header-capture rewrite in split_test_spec_by_us (variable instead
#     of a tmp file, to remove the orphan-file risk) used `$(...)` command
#     substitution, which unconditionally strips ALL trailing newlines —
#     silently eating the blank line that normally separates the header
#     from the first heading. Verified via a direct byte-diff against
#     lib_ralph_desk.zsh's tmp-file-based equivalent for the same fixture:
#     a genuine byte-level gap, not cosmetic. Fixed by capturing through a
#     NUL-delimited `read` (which does not strip trailing newlines) and
#     writing back with `printf '%s'` (which adds none), reproducing the
#     exact source bytes — confirmed byte-identical to lib's output on the
#     same fixture after the fix.
#   (n) a PRD with a genuine ### US-001: body PLUS a later, unrelated
#       ### US-001 rationale appendix line (same us_id, different heading
#       form — still 3-hash, per the correction below) reusing the split
#       target: the US-001 split file must retain the original body (not
#       truncated) with the appendix text appended after it, in that order
#       — and, for the unchanged common case (a single colon-form heading,
#       no repeats), init's split output must stay byte-identical to
#       `git show HEAD:` init's output, proving this fix does not perturb
#       the pre-existing, already-correct case.
#
# CORRECTION (team lead, post-review): an earlier revision of this fix
# widened the PRD gate/splitter to `#{2,3}` (2-or-3 hash) to mirror
# lib_ralph_desk.zsh's _extract_prd_us_list, breaking the committed
# contract in tests/test_us001_prd_splitting.sh AC1-L3-neg (a 2-hash-only
# PRD went from 0 split files to 2). Reverted to 3-hash-only for the PRD
# gate and splitter — the real dash-form fix was always the separator
# alternation (colon/dash/space/end-of-line), never the hash count. Case
# (m) is inverted accordingly (2-hash PRD heading must NOT split), and
# cases (n)/(q)'s "reused heading" fixtures moved from a 2-hash
# "## US-001 rationale" line (which no longer matches the PRD boundary at
# all under the 3-hash-only contract) to a 3-hash "### US-001 rationale"
# line, so they still genuinely exercise the seen[]/append and
# partial-mismatch-WARNING mechanisms instead of silently degenerating
# into ordinary contiguous body-line accumulation.
# case (k) also now authors a `## US-001: Title` test-spec heading before
# the backslash-path run, so split_test_spec_by_us's own ENVIRON fix is
# exercised too, not just split_prd_by_us's (the scaffold test-spec has no
# US heading by default, so the original case (k) never reached that awk).
# case (l) also gained L-7: a colon-form test-spec split, byte-compared
# against `git show HEAD:` init — split files feed the gate-receipt hash
# set, so this must be genuinely byte-identical (mirrors N-5's PRD version).
#
# SV-gate judge finding (mutant escape): case (a)'s sed stub targets the
# OLD `sed -i ''` invocation the code no longer emits, so it never fires —
# removing _render_prompt_placeholders' self-heal entirely went uncaught.
#   (o) a sed -i.bak HARD failure (creates the .bak, truncates the target,
#       exits 1 — the real 3-arg invocation shape, not the old 2-arg form):
#       init exits non-zero, the half-written prompt is deleted, no .bak is
#       left, and a re-run with real sed regenerates it cleanly.
#   (p) a sed -i.bak that exits 0 WITHOUT substituting (a silent no-op):
#       the leftover-{DESK}/{SLUG} guard fires the same way — non-zero,
#       file deleted, re-run self-heals.
#   (q) a partial split (1 well-formed heading + 1 reused-id heading, same
#       fixture as case n): a WARNING naming the marker-vs-file count
#       mismatch, exit 0 (not a failure), and the reused-id content still
#       present in the split file (the WARNING is informational, not a sign
#       of data loss — see split_prd_by_us's WARNING branch).

set -u

INIT="${INIT:-src/scripts/init_ralph_desk.zsh}"
INIT_ABS="$(cd "$(dirname "$INIT")" && pwd)/$(basename "$INIT")"
# LIB_ABS is deliberately NOT derived from INIT_ABS's directory: INIT can be
# overridden to a scratch copy elsewhere (e.g. a /tmp mutation-testing
# snapshot) that has no sibling lib_ralph_desk.zsh. Anchor on this test
# file's own location instead, which always sits in the real repo's tests/.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_ABS="$REPO_ROOT/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

echo "=== init_ralph_desk.zsh data-safety: A-6 (sed portability) + A-7 (PRD authored detection) + split_prd_by_us ==="
echo "Target: $INIT_ABS"
echo ""

# ── Helpers ──────────────────────────────────────────────────────────────

first_run_init() {
  # Plain first-run init (no --mode): creates the full .rlp-desk skeleton,
  # including the real scaffold PRD, prompts, and test-spec. Optional 3rd
  # arg is the objective positional (omit for init's own "TBD..." default).
  local root="$1" slug="$2" objective="${3:-}"
  mkdir -p "$root"
  if [[ -n "$objective" ]]; then
    ROOT="$root" zsh "$INIT_ABS" "$slug" "$objective" >/dev/null 2>"$WORKDIR/last-first-run-stderr.log"
  else
    ROOT="$root" zsh "$INIT_ABS" "$slug" >/dev/null 2>"$WORKDIR/last-first-run-stderr.log"
  fi
}

fresh_run_init() {
  # Second run with --mode fresh against an already-scaffolded root.
  # Optional 3rd arg is the objective positional.
  local root="$1" slug="$2" objective="${3:-}"
  if [[ -n "$objective" ]]; then
    ROOT="$root" zsh "$INIT_ABS" "$slug" "$objective" --mode fresh
  else
    ROOT="$root" zsh "$INIT_ABS" "$slug" --mode fresh
  fi
}

tail_lines() {
  # tail_lines <text> <n> — collapse to one line for a compact FAIL message.
  printf '%s\n' "$1" | tail -n "$2" | tr '\n' '|'
}

extract_fn() {
  # extract_fn <file> <fn_name> — pull one top-level function's body out of
  # a zsh script via brace-matching, for standalone execution (mirrors
  # tests/test_us006_init_presets.sh's FN_BODY extraction).
  local file="$1" fn="$2"
  awk -v fn="$fn" '
    $0 ~ "^" fn "\\(\\) \\{" { in_fn=1; depth=0 }
    in_fn {
      for (i=1; i<=length($0); i++) {
        c = substr($0, i, 1)
        if (c == "{") depth++
        else if (c == "}") {
          depth--
          if (depth == 0) { print; in_fn=0; next }
        }
      }
      print
    }
  ' "$file"
}

build_forced_failure_init() {
  # Injects an env-var-gated forced failure at the top of split_prd_by_us
  # and split_test_spec_by_us, into a scratch copy of $INIT_ABS (built
  # once, cached in $WORKDIR). Both functions' own internal ERROR/count==0
  # branches are, by design, unreachable through real PRD/test-spec content
  # now that each function's loose gate and strict splitter share the
  # identical regex (grep -c matching >=1 line guarantees the awk creates
  # >=1 distinct file) — the SV-gate verifier's own finding was that this
  # left the call-site guards (self-heal / symmetric failure handling)
  # untested except via a forced/mutated failure. This lets cases (r)/(s)
  # exercise those call sites directly without needing to fabricate
  # content that can't actually occur, using awk (already a hard
  # dependency of this whole codebase) rather than a new tool dependency.
  local dst="$WORKDIR/init-forced-failure.zsh"
  if [[ ! -f "$dst" ]]; then
    awk '
      /^split_prd_by_us\(\) \{/ {
        print
        print "  [[ -n \"${FORCE_SPLIT_PRD_FAIL:-}\" ]] && { echo \"  ERROR: forced split_prd_by_us failure (test injection)\" >&2; return 1; }"
        next
      }
      /^split_test_spec_by_us\(\) \{/ {
        print
        print "  [[ -n \"${FORCE_SPLIT_TS_FAIL:-}\" ]] && { echo \"  ERROR: forced split_test_spec_by_us failure (test injection)\" >&2; return 1; }"
        next
      }
      { print }
    ' "$INIT_ABS" > "$dst"
  fi
  printf '%s' "$dst"
}

# ── (a) GNU-sed rejection simulation ────────────────────────────────────
echo "--- (a) GNU-sed rejection simulation ---"

test_a_gnu_sed_rejection() {
  local root="$WORKDIR/case-a" slug="case-a-slug"
  local bindir="$WORKDIR/case-a-bin"
  mkdir -p "$bindir"
  # Simulates GNU sed's fatal rejection of the BSD-only `-i ''` (empty
  # backup-suffix as a SEPARATE argument) invocation form specifically —
  # every other invocation delegates to the real system sed so the rest of
  # init behaves normally.
  cat > "$bindir/sed" <<'STUB'
#!/bin/sh
if [ "$1" = "-i" ] && [ "$2" = "" ]; then
  echo "sed: -e expression #1, char 0: no previous regular expression" >&2
  exit 2
fi
exec /usr/bin/sed "$@"
STUB
  chmod +x "$bindir/sed"

  local out rc
  out="$(PATH="$bindir:$PATH" ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "A-1: init exited $rc under a GNU-sed-rejecting stub (should exit 0; tail: $(tail_lines "$out" 6))"
  else
    pass "A-1: init exits 0 under a GNU-sed-rejecting stub"
  fi

  local fw="$root/.rlp-desk/prompts/$slug.flywheel.prompt.md"
  if [[ -f "$fw" ]] && ! grep -qE '\{DESK\}|\{SLUG\}' "$fw"; then
    pass "A-2: flywheel prompt fully rendered, no {DESK}/{SLUG} placeholders left"
  else
    fail "A-2: flywheel prompt missing or has unrendered placeholders: $fw"
  fi

  local guard="$root/.rlp-desk/prompts/$slug.flywheel-guard.prompt.md"
  if [[ -f "$guard" ]] && ! grep -qE '\{DESK\}|\{SLUG\}' "$guard"; then
    pass "A-3: flywheel-guard prompt fully rendered, no {DESK}/{SLUG} placeholders left"
  else
    fail "A-3: flywheel-guard prompt missing or has unrendered placeholders: $guard"
  fi
}
test_a_gnu_sed_rejection

# ── (b) ROOT path containing & and | ────────────────────────────────────
echo "--- (b) path containing & and | renders correctly ---"

test_b_special_chars_in_path() {
  local root="$WORKDIR/case-b & pipe | dir" slug="case-b-slug"
  mkdir -p "$root"

  local out rc
  out="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "B-1: init exited $rc for a ROOT path containing & and | (tail: $(tail_lines "$out" 6))"
    return
  fi
  pass "B-1: init exits 0 for a ROOT path containing & and |"

  local fw="$root/.rlp-desk/prompts/$slug.flywheel.prompt.md"
  if [[ ! -f "$fw" ]]; then
    fail "B-2: flywheel prompt not created for special-char ROOT: $fw"
    return
  fi
  if grep -qE '\{DESK\}|\{SLUG\}' "$fw"; then
    fail "B-3: {DESK}/{SLUG} placeholder left unrendered when ROOT contains & and |"
  else
    pass "B-3: placeholders fully rendered despite & and | in ROOT path"
  fi
  if grep -qF "$root/.rlp-desk" "$fw"; then
    pass "B-4: rendered DESK path in prompt matches the real path literally (no corruption)"
  else
    fail "B-4: rendered DESK path does not literally match the real path (corrupted substitution)"
  fi
}
test_b_special_chars_in_path

# ── (c) dash-form authored PRD heading preserved ────────────────────────
echo "--- (c) --mode fresh preserves a dash-form authored PRD heading ---"

test_c_dash_form_authored_preserved() {
  local root="$WORKDIR/case-c" slug="case-c-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "C-setup: first-run did not create $prd"; return; }

  # Authored: dash-form heading with a real title (the form
  # _extract_prd_us_list officially accepts alongside the colon form).
  sed -i.bak 's/^### US-001: \[Title\]$/### US-001 - Real Feature Title/' "$prd" && rm -f "$prd.bak"
  local snapshot="$WORKDIR/case-c-snapshot.md"
  cp "$prd" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" 2>&1)"

  if cmp -s "$prd" "$snapshot"; then
    pass "C-1: dash-form authored PRD is byte-unchanged after --mode fresh"
  else
    fail "C-1: dash-form authored PRD was modified/replaced by --mode fresh"
  fi
  if echo "$out" | grep -qF "Preserved: prd-$slug.md"; then
    pass "C-2: init reports PRD Preserved (not Deleted/Reset) for a dash-form heading"
  else
    fail "C-2: init did not report Preserved for a dash-form heading (tail: $(tail_lines "$out" 8))"
  fi
  if [[ ! -f "$root/.rlp-desk/plans/prd-$slug-v1.md" ]]; then
    pass "C-3: no versioned backup created (an authored PRD is preserved in place, untouched)"
  else
    fail "C-3: unexpected versioned backup created for a preserved authored PRD"
  fi
}
test_c_dash_form_authored_preserved

# ── (d) authored body under an untouched placeholder heading preserved ──
echo "--- (d) --mode fresh preserves an authored body under a placeholder heading ---"

test_d_placeholder_heading_authored_body_preserved() {
  local root="$WORKDIR/case-d" slug="case-d-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "D-setup: first-run did not create $prd"; return; }

  # Heading stays the literal scaffold placeholder; a real edit lands
  # elsewhere in the file (a section the old heading-only regex never looked at).
  sed -i.bak 's/^## Technical Constraints$/## Technical Constraints\n- Must support both BSD and GNU sed across the CI matrix./' "$prd" && rm -f "$prd.bak"
  grep -q '^### US-001: \[Title\]$' "$prd" || { fail "D-setup: fixture heading is not the placeholder as expected"; return; }
  local snapshot="$WORKDIR/case-d-snapshot.md"
  cp "$prd" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" 2>&1)"

  if cmp -s "$prd" "$snapshot"; then
    pass "D-1: authored-body PRD (placeholder heading) is byte-unchanged after --mode fresh"
  else
    fail "D-1: authored-body PRD with a placeholder heading was modified/replaced"
  fi
  if echo "$out" | grep -qF "Preserved: prd-$slug.md"; then
    pass "D-2: init reports PRD Preserved for an authored body under a placeholder heading"
  else
    fail "D-2: init did not report Preserved (tail: $(tail_lines "$out" 8))"
  fi
}
test_d_placeholder_heading_authored_body_preserved

# ── (e) byte-exact scaffold PRD is versioned, never bare-deleted ────────
echo "--- (e) --mode fresh regenerates a scaffold PRD but versions the original ---"

test_e_scaffold_versioned_not_deleted() {
  local root="$WORKDIR/case-e" slug="case-e-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "E-setup: first-run did not create $prd"; return; }
  local snapshot="$WORKDIR/case-e-snapshot.md"
  cp "$prd" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  local backup="$root/.rlp-desk/plans/prd-$slug-v1.md"

  if [[ -f "$prd" ]]; then
    pass "E-1: prd-$slug.md exists after fresh (scaffold regenerated)"
  else
    fail "E-1: prd-$slug.md missing after fresh (scaffold was not regenerated)"
  fi
  if [[ -f "$backup" ]]; then
    pass "E-2: versioned backup prd-$slug-v1.md exists (original scaffold recoverable, not rm'd)"
  else
    fail "E-2: no versioned backup created — original scaffold content lost with no recovery copy"
  fi
  if [[ -f "$backup" ]] && cmp -s "$backup" "$snapshot"; then
    pass "E-3: versioned backup content is byte-identical to the pre-fresh scaffold"
  else
    fail "E-3: versioned backup content differs from the original scaffold"
  fi
  if echo "$out" | grep -qF "Reset:     prd-$slug.md"; then
    pass "E-4: init reports Reset (not a bare Deleted) for the scaffold PRD"
  else
    fail "E-4: init did not report the expected Reset message (tail: $(tail_lines "$out" 8))"
  fi
}
test_e_scaffold_versioned_not_deleted

# ── (f) byte-exact scaffold test-spec is versioned, never bare-deleted ──
echo "--- (f) --mode fresh regenerates a scaffold test-spec but versions the original ---"

test_f_scaffold_testspec_versioned_not_deleted() {
  local root="$WORKDIR/case-f" slug="case-f-slug"
  first_run_init "$root" "$slug"
  local ts="$root/.rlp-desk/plans/test-spec-$slug.md"
  [[ -f "$ts" ]] || { fail "F-setup: first-run did not create $ts"; return; }
  local snapshot="$WORKDIR/case-f-snapshot.md"
  cp "$ts" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  local backup="$root/.rlp-desk/plans/test-spec-$slug-v1.md"

  if [[ -f "$ts" ]]; then
    pass "F-1: test-spec-$slug.md exists after fresh (scaffold regenerated)"
  else
    fail "F-1: test-spec-$slug.md missing after fresh (scaffold was not regenerated)"
  fi
  if [[ -f "$backup" ]]; then
    pass "F-2: versioned backup test-spec-$slug-v1.md exists (original scaffold recoverable, not rm'd)"
  else
    fail "F-2: no versioned backup created — original scaffold content lost with no recovery copy"
  fi
  if [[ -f "$backup" ]] && cmp -s "$backup" "$snapshot"; then
    pass "F-3: versioned backup content is byte-identical to the pre-fresh scaffold"
  else
    fail "F-3: versioned backup content differs from the original scaffold"
  fi
  if echo "$out" | grep -qF "Reset:     test-spec-$slug.md"; then
    pass "F-4: init reports Reset (not a bare Deleted) for the scaffold test-spec"
  else
    fail "F-4: init did not report the expected Reset message (tail: $(tail_lines "$out" 8))"
  fi
}
test_f_scaffold_testspec_versioned_not_deleted

# ── (g) objective drift on an untouched scaffold must not misclassify ───
echo "--- (g) --mode fresh regenerates a scaffold PRD despite an objective change ---"

test_g_objective_drift_scaffold_not_misclassified() {
  local root="$WORKDIR/case-g" slug="case-g-slug"
  first_run_init "$root" "$slug" "Original objective X"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "G-setup: first-run did not create $prd"; return; }
  grep -qF "Original objective X" "$prd" || { fail "G-setup: fixture does not contain the seeded objective"; return; }
  local snapshot="$WORKDIR/case-g-snapshot.md"
  cp "$prd" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" "Different objective Y" 2>&1)"
  local backup="$root/.rlp-desk/plans/prd-$slug-v1.md"

  if [[ -f "$prd" ]] && grep -qF "Different objective Y" "$prd"; then
    pass "G-1: prd-$slug.md regenerated with the new objective Y"
  else
    fail "G-1: prd-$slug.md was not regenerated with the new objective (still shows old objective, or missing)"
  fi
  if [[ -f "$backup" ]] && cmp -s "$backup" "$snapshot"; then
    pass "G-2: versioned backup prd-$slug-v1.md exists and preserves the original objective X"
  else
    fail "G-2: no versioned backup, or backup content differs from original scaffold — objective X lost"
  fi
  if echo "$out" | grep -qF "Reset:     prd-$slug.md"; then
    pass "G-3: init reports Reset (scaffold, not misclassified as authored) despite the objective change"
  else
    fail "G-3: init did not report the expected Reset message (tail: $(tail_lines "$out" 8))"
  fi
  if echo "$out" | grep -qF "Preserved: prd-$slug.md"; then
    fail "G-4: init incorrectly reported Preserved for an untouched scaffold that only differs by objective"
  else
    pass "G-4: init did not misclassify the objective-only-changed scaffold as Preserved"
  fi
}
test_g_objective_drift_scaffold_not_misclassified

# ── (h) objective drift on an authored PRD must still preserve it ───────
echo "--- (h) --mode fresh preserves an authored PRD even with a changed objective ---"

test_h_objective_drift_authored_still_preserved() {
  local root="$WORKDIR/case-h" slug="case-h-slug"
  first_run_init "$root" "$slug" "Original objective X"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "H-setup: first-run did not create $prd"; return; }

  # Authored: a real edit unrelated to the objective (same shape as case d
  # — heading stays the untouched placeholder).
  sed -i.bak 's/^## Technical Constraints$/## Technical Constraints\n- Must run unattended, no owner prompts mid-campaign./' "$prd" && rm -f "$prd.bak"
  local snapshot="$WORKDIR/case-h-snapshot.md"
  cp "$prd" "$snapshot"

  local out
  out="$(fresh_run_init "$root" "$slug" "Different objective Y" 2>&1)"

  if cmp -s "$prd" "$snapshot"; then
    pass "H-1: authored PRD is byte-unchanged after --mode fresh with a changed objective"
  else
    fail "H-1: authored PRD was modified/replaced despite being authored (objective change alone should not matter)"
  fi
  if echo "$out" | grep -qF "Preserved: prd-$slug.md"; then
    pass "H-2: init reports PRD Preserved despite the objective change (the real edit still wins)"
  else
    fail "H-2: init did not report Preserved (tail: $(tail_lines "$out" 8))"
  fi
  if [[ ! -f "$root/.rlp-desk/plans/prd-$slug-v1.md" ]]; then
    pass "H-3: no versioned backup created (authored PRD preserved in place, untouched)"
  else
    fail "H-3: unexpected versioned backup created for a preserved authored PRD"
  fi
}
test_h_objective_drift_authored_still_preserved

# ── (i) dash-form PRD heading splits correctly under --mode fresh ───────
echo "--- (i) --mode fresh on a dash-form PRD: split succeeds, test-spec present ---"

test_i_dash_form_split_succeeds() {
  local root="$WORKDIR/case-i" slug="case-i-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "I-setup: first-run did not create $prd"; return; }
  sed -i.bak 's/^### US-001: \[Title\]$/### US-001 - Real Dash Title/' "$prd" && rm -f "$prd.bak"

  local out rc
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "I-1: init exited $rc for a dash-form PRD heading (tail: $(tail_lines "$out" 8))"
    return
  fi
  pass "I-1: init exits 0 for a dash-form PRD heading"

  if [[ -f "$root/.rlp-desk/plans/prd-$slug-US-001.md" ]]; then
    pass "I-2: per-US split file exists for the dash-form heading"
  else
    fail "I-2: per-US split file missing for the dash-form heading"
  fi
  if [[ -f "$root/.rlp-desk/plans/test-spec-$slug.md" ]]; then
    pass "I-3: test-spec-$slug.md is present after the successful split"
  else
    fail "I-3: test-spec-$slug.md is missing after --mode fresh on a dash-form PRD"
  fi
}
test_i_dash_form_split_succeeds

# ── (j) malformed heading falls back gracefully, test-spec unaffected ───
echo "--- (j) PRD heading matching neither form: graceful fallback, not a crash ---"

test_j_malformed_heading_graceful_fallback() {
  local root="$WORKDIR/case-j" slug="case-j-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "J-setup: first-run did not create $prd"; return; }
  # A heading matching NEITHER accepted form (digits running straight into
  # the title, no separator at all) now correctly fails the WIDENED loose
  # gate too — loose and strict share the identical regex (see
  # split_prd_by_us) — so this takes the pre-existing graceful "no US
  # markers, fall back to full PRD injection" branch: exit 0, a WARNING
  # (not an ERROR), and the PRD content still reaches the Worker in full
  # via the fallback rather than a per-US split.
  sed -i.bak 's/^### US-001: \[Title\]$/### US-001Malformed/' "$prd" && rm -f "$prd.bak"

  local out rc
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    pass "J-1: init exits 0 on a PRD heading matching neither accepted form (graceful fallback)"
  else
    fail "J-1: init exited $rc instead of gracefully falling back (tail: $(tail_lines "$out" 8))"
  fi
  if echo "$out" | grep -qF "WARNING: No US markers"; then
    pass "J-2: init prints the graceful fallback WARNING (loose gate agrees with the splitter — no loud ERROR)"
  else
    fail "J-2: no fallback WARNING in output (tail: $(tail_lines "$out" 8))"
  fi
  if [[ -f "$root/.rlp-desk/plans/test-spec-$slug.md" ]]; then
    pass "J-3: test-spec-$slug.md is present (the graceful fallback path never touches it)"
  else
    fail "J-3: test-spec-$slug.md is missing after the fallback path"
  fi
}
test_j_malformed_heading_graceful_fallback

# ── (k) backslash in ROOT path: split lands in the right directory ──────
echo "--- (k) ROOT path containing a backslash: split target not corrupted ---"

test_k_backslash_in_root_path() {
  local root="$WORKDIR"'/case-k-proj\with\backslash' slug="case-k-slug"
  mkdir -p "$root"

  # First run: create the scaffold (PRD + test-spec) at the backslash path.
  local out0
  out0="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  if [[ $? -ne 0 ]]; then
    fail "K-1: init exited nonzero on the scaffold run at a backslash-containing ROOT (tail: $(tail_lines "$out0" 6))"
    return
  fi

  # Author a test-spec heading so the SECOND run's split_test_spec_by_us
  # awk is also exercised at this backslash path, not just
  # split_prd_by_us's — the scaffold test-spec has no ## US- heading by
  # default, so without this the original case (k) never reached that awk.
  local ts="$root/.rlp-desk/plans/test-spec-$slug.md"
  cat >> "$ts" <<'HEADING_EOF'

## US-001: Backslash Path Section
Some content here.
HEADING_EOF

  local out rc
  out="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "K-1: init exited $rc for a ROOT path containing a backslash (tail: $(tail_lines "$out" 6))"
    return
  fi
  pass "K-1: init exits 0 for a ROOT path containing a backslash"

  local split_file="$root/.rlp-desk/plans/prd-$slug-US-001.md"
  if [[ -f "$split_file" ]]; then
    pass "K-2: per-US PRD split file lands in the correct (uncorrupted) directory"
  else
    fail "K-2: per-US PRD split file missing or landed in the wrong directory (backslash-corrupted path?)"
  fi

  local ts_split_file="$root/.rlp-desk/plans/test-spec-$slug-US-001.md"
  if [[ -f "$ts_split_file" ]]; then
    pass "K-3: per-US test-spec split file also lands correctly at a backslash-containing path"
  else
    fail "K-3: per-US test-spec split file missing at a backslash-containing path (split_test_spec_by_us's own ENVIRON not exercised or broken)"
  fi
}
test_k_backslash_in_root_path

# ── (l) dash-form test-spec heading: split succeeds, no header-tmp orphan ─
echo "--- (l) dash-form test-spec heading: split succeeds, no header tmp orphan ---"

test_l_dash_form_testspec_split_no_orphan() {
  local root="$WORKDIR/case-l" slug="case-l-slug"
  first_run_init "$root" "$slug"
  local ts="$root/.rlp-desk/plans/test-spec-$slug.md"
  [[ -f "$ts" ]] || { fail "L-setup: first-run did not create $ts"; return; }
  cat >> "$ts" <<'HEADING_EOF'

## US-001 - Dash Form Section
Some content here.
HEADING_EOF

  local out rc
  # Plain re-run (no --mode): split_test_spec_by_us runs unconditionally
  # after the Test Spec write block regardless of mode.
  out="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "L-1: init exited $rc for a dash-form test-spec heading (tail: $(tail_lines "$out" 8))"
    return
  fi
  pass "L-1: init exits 0 for a dash-form test-spec heading"

  local ts_split="$root/.rlp-desk/plans/test-spec-$slug-US-001.md"
  if [[ -f "$ts_split" ]]; then
    pass "L-2: per-US test-spec split file exists for the dash-form heading"
  else
    fail "L-2: per-US test-spec split file missing for the dash-form heading"
  fi
  # bash (not zsh) runs this test file, so use nullglob rather than the
  # zsh-only (N) qualifier for an unmatched-glob-safe empty array.
  local -a orphans
  shopt -s nullglob
  orphans=("$root/.rlp-desk/plans/"test-spec-*-header.tmp.*)
  shopt -u nullglob
  if [[ ${#orphans[@]} -eq 0 ]]; then
    pass "L-3: no test-spec-*-header.tmp.* orphan left in plans/"
  else
    fail "L-3: orphaned header tmp file(s) found: ${orphans[*]}"
  fi

  if [[ -f "$ts_split" ]]; then
    local heading_count
    heading_count=$(grep -cE '^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)' "$ts_split")
    if [[ "$heading_count" -eq 1 ]]; then
      pass "L-4: US-001 split file contains exactly one ## US-NNN heading (header-extraction awk stopped at the real boundary, didn't dump the whole test-spec)"
    else
      fail "L-4: US-001 split file contains $heading_count ## US-NNN headings (expected exactly 1)"
    fi

    local expected_header actual_header
    expected_header=$(awk '/^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)/{exit} {print}' "$ts")
    actual_header=$(awk '/^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)/{exit} {print}' "$ts_split")
    if [[ "$expected_header" == "$actual_header" ]]; then
      pass "L-5: split file's header prefix equals the source test-spec's pre-first-heading bytes exactly"
    else
      fail "L-5: split file's header prefix does not match the source test-spec's pre-first-heading content"
    fi
  fi

  # init vs lib byte parity: same dash-form test-spec fixture, both
  # split_test_spec_by_us implementations, byte-compare the output.
  local fixture_ts="$WORKDIR/l-parity-fixture.md"
  cat > "$fixture_ts" <<'FIXTURE_EOF'
# Test Specification: parity-slug

## Verification Commands
Some header content.

## US-001 - Dash Form Section
Some content here.
FIXTURE_EOF

  local init_fn lib_fn
  init_fn="$(extract_fn "$INIT_ABS" "split_test_spec_by_us")"
  lib_fn="$(extract_fn "$LIB_ABS" "split_test_spec_by_us")"
  if [[ -z "$init_fn" || -z "$lib_fn" ]]; then
    fail "L-6: could not extract split_test_spec_by_us from init and/or lib (init found=$( [[ -n "$init_fn" ]] && echo yes || echo no ), lib found=$( [[ -n "$lib_fn" ]] && echo yes || echo no ))"
    return
  fi

  local init_dir="$WORKDIR/l-parity-init" lib_dir="$WORKDIR/l-parity-lib"
  mkdir -p "$init_dir" "$lib_dir"
  cp "$fixture_ts" "$init_dir/test-spec-parity-slug.md"
  cp "$fixture_ts" "$lib_dir/test-spec-parity-slug.md"

  # lib's split_test_spec_by_us may reference shared top-level ERE constants
  # (e.g. RLP_US_HEADING_ERE_TESTSPEC) rather than an inline regex literal —
  # extract_fn only pulls the function BODY, so those definitions must be
  # captured and prepended separately or the extracted function runs with
  # an unset (empty-string) pattern, which matches every line. Grepping for
  # any `RLP_US_HEADING_ERE_*=` assignment keeps this robust to lib
  # inlining the regex again later (the grep then simply finds nothing).
  local lib_constants
  lib_constants="$(grep -E '^RLP_US_HEADING_ERE_[A-Z_]+=' "$LIB_ABS" 2>/dev/null)"

  local init_script="$WORKDIR/l-parity-init.zsh" lib_script="$WORKDIR/l-parity-lib.zsh"
  { printf '%s\n' "$init_fn"; printf '\nsplit_test_spec_by_us "%s" "parity-slug"\n' "$init_dir/test-spec-parity-slug.md"; } > "$init_script"
  { [[ -n "$lib_constants" ]] && printf '%s\n' "$lib_constants"; printf '%s\n' "$lib_fn"; printf '\nsplit_test_spec_by_us "%s" "parity-slug"\n' "$lib_dir/test-spec-parity-slug.md"; } > "$lib_script"

  zsh "$init_script" >/dev/null 2>&1
  zsh "$lib_script" >/dev/null 2>&1

  local init_out="$init_dir/test-spec-parity-slug-US-001.md" lib_out="$lib_dir/test-spec-parity-slug-US-001.md"
  if [[ -f "$init_out" && -f "$lib_out" ]] && cmp -s "$init_out" "$lib_out"; then
    pass "L-6: init and lib split_test_spec_by_us produce byte-identical output for the same dash-form test-spec"
  else
    fail "L-6: init and lib split_test_spec_by_us output differs (init exists=$( [[ -f "$init_out" ]] && echo yes || echo no ), lib exists=$( [[ -f "$lib_out" ]] && echo yes || echo no ))"
  fi

  # Byte-compare the previously-accepted colon-form case against
  # `git show HEAD:` init — split files feed the gate-receipt hash set
  # (lib_ralph_desk.zsh's compute_prd_content_hash / src/node/util/
  # gate-receipt.mjs), so this must be genuinely byte-identical, not just
  # "logically equivalent." Mirrors N-5's PRD version below.
  local head_init_ts="$WORKDIR/init-head-l7.zsh"
  if ! git show HEAD:src/scripts/init_ralph_desk.zsh > "$head_init_ts" 2>/dev/null; then
    fail "L-7: could not read git HEAD's init_ralph_desk.zsh for the byte-parity check"
    return
  fi
  local root7_fixed="$WORKDIR/case-l7-fixed" root7_head="$WORKDIR/case-l7-head"
  first_run_init "$root7_fixed" "case-l7-slug"
  mkdir -p "$root7_head"
  ROOT="$root7_head" zsh "$head_init_ts" "case-l7-slug" >/dev/null 2>&1
  for d in "$root7_fixed" "$root7_head"; do
    cat >> "$d/.rlp-desk/plans/test-spec-case-l7-slug.md" <<'HEADING_EOF'

## US-001: Colon Form Section
Some content here.
HEADING_EOF
  done
  ROOT="$root7_fixed" zsh "$INIT_ABS" "case-l7-slug" >/dev/null 2>&1
  ROOT="$root7_head" zsh "$head_init_ts" "case-l7-slug" >/dev/null 2>&1
  local ts7_fixed="$root7_fixed/.rlp-desk/plans/test-spec-case-l7-slug-US-001.md"
  local ts7_head="$root7_head/.rlp-desk/plans/test-spec-case-l7-slug-US-001.md"
  if [[ -f "$ts7_fixed" && -f "$ts7_head" ]] && cmp -s "$ts7_fixed" "$ts7_head"; then
    pass "L-7: colon-form test-spec split output is byte-identical to git-HEAD init (gate-receipt hash safe)"
  else
    fail "L-7: colon-form test-spec split output differs from git-HEAD init (fixed exists=$( [[ -f "$ts7_fixed" ]] && echo yes || echo no ), head exists=$( [[ -f "$ts7_head" ]] && echo yes || echo no ))"
  fi
}
test_l_dash_form_testspec_split_no_orphan

# ── (m) 2-hash-only PRD heading: MUST NOT split (3-hash contract) ───────
echo "--- (m) 2-hash-only PRD heading: zero split files, graceful fallback (3-hash PRD contract) ---"

test_m_two_hash_prd_heading_rejected() {
  local root="$WORKDIR/case-m" slug="case-m-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "M-setup: first-run did not create $prd"; return; }
  # Correction (team lead, post-review): a 2-hash PRD heading is the
  # TEST-SPEC section level, not a PRD story heading — an earlier revision
  # of this test asserted the opposite (2-hash PRD headings should split),
  # which broke the committed contract in
  # tests/test_us001_prd_splitting.sh AC1-L3-neg (a 2-hash `## US-NNN:`
  # PRD must produce ZERO split files). Inverted to match that contract:
  # the correct behavior is the graceful "no US markers" fallback, exit 0,
  # NOT a split.
  sed -i.bak 's/^### US-001: \[Title\]$/## US-001 - Two Hash Title/' "$prd" && rm -f "$prd.bak"

  local out rc
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "M-1: init exited $rc for a 2-hash PRD heading (expected 0 with graceful fallback) (tail: $(tail_lines "$out" 8))"
    return
  fi
  pass "M-1: init exits 0 for a 2-hash PRD heading"

  if [[ ! -f "$root/.rlp-desk/plans/prd-$slug-US-001.md" ]]; then
    pass "M-2: no per-US split file created for the 2-hash heading (PRD story level is 3-hash only)"
  else
    fail "M-2: a per-US split file was created for a 2-hash PRD heading (violates the AC1-L3-neg contract)"
  fi
  if echo "$out" | grep -qF "WARNING: No US markers"; then
    pass "M-3: init takes the graceful no-markers fallback for a 2-hash PRD heading"
  else
    fail "M-3: init did not fall back gracefully for a 2-hash PRD heading (tail: $(tail_lines "$out" 8))"
  fi
}
test_m_two_hash_prd_heading_rejected

# ── (n) repeated US heading appends instead of truncating ───────────────
echo "--- (n) repeated US heading (appendix/TOC) appends instead of truncating ---"

test_n_repeated_heading_appends_not_truncates() {
  local root="$WORKDIR/case-n" slug="case-n-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "N-setup: first-run did not create $prd"; return; }
  # Append a SECOND line elsewhere in the file that also matches the US
  # heading boundary regex for the SAME us_id (an appendix/TOC-style
  # mention) — still 3-hash (a 2-hash mention is the test-spec level and
  # does not match the PRD boundary at all, per the 3-hash-only contract),
  # but a different separator (space, not colon) reusing "001".
  cat >> "$prd" <<'HEADING_EOF'

### US-001 rationale
Appendix note about US-001, added after the real section.
HEADING_EOF

  local out rc
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "N-1: init exited $rc for a PRD with a repeated US-001 heading (tail: $(tail_lines "$out" 8))"
    return
  fi
  pass "N-1: init exits 0 for a PRD with a repeated US-001 heading"

  local split_file="$root/.rlp-desk/plans/prd-$slug-US-001.md"
  if [[ -f "$split_file" ]] && grep -qF '### US-001: [Title]' "$split_file"; then
    pass "N-2: US-001 split file retains the ORIGINAL section body (not truncated by the appendix mention)"
  else
    fail "N-2: US-001 split file lost its original body (truncated by the later appendix heading)"
  fi
  if [[ -f "$split_file" ]] && grep -qF 'Appendix note about US-001' "$split_file"; then
    pass "N-3: US-001 split file also contains the appendix text (appended, not dropped)"
  else
    fail "N-3: US-001 split file is missing the appendix text"
  fi
  if [[ -f "$split_file" ]]; then
    local body_line appendix_line
    body_line=$(grep -n '### US-001: \[Title\]' "$split_file" | head -1 | cut -d: -f1)
    appendix_line=$(grep -n 'Appendix note about US-001' "$split_file" | head -1 | cut -d: -f1)
    if [[ -n "$body_line" && -n "$appendix_line" && "$body_line" -lt "$appendix_line" ]]; then
      pass "N-4: original body appears BEFORE the appendix text (correct order, not reordered)"
    else
      fail "N-4: original body / appendix text are missing or out of order"
    fi
  fi

  # Byte-compare against `git show HEAD:` init for the plain, single
  # colon-form heading case — the fix must not perturb the pre-existing,
  # already-correct common case, only the newly-reachable duplicate-heading
  # truncation bug.
  local head_init="$WORKDIR/init-head-n5.zsh"
  if ! git show HEAD:src/scripts/init_ralph_desk.zsh > "$head_init" 2>/dev/null; then
    fail "N-5: could not read git HEAD's init_ralph_desk.zsh for the byte-parity check"
    return
  fi
  local root_fixed="$WORKDIR/case-n5-fixed" root_head="$WORKDIR/case-n5-head"
  first_run_init "$root_fixed" "case-n5-slug"
  mkdir -p "$root_head"
  ROOT="$root_head" zsh "$head_init" "case-n5-slug" >/dev/null 2>&1
  local split_fixed="$root_fixed/.rlp-desk/plans/prd-case-n5-slug-US-001.md"
  local split_head="$root_head/.rlp-desk/plans/prd-case-n5-slug-US-001.md"
  if [[ -f "$split_fixed" && -f "$split_head" ]] && cmp -s "$split_fixed" "$split_head"; then
    pass "N-5: single colon-form heading split output is byte-identical to git-HEAD init (fix doesn't perturb the existing common case)"
  else
    fail "N-5: colon-form split output differs from git-HEAD init (fixed exists=$( [[ -f "$split_fixed" ]] && echo yes || echo no ), head exists=$( [[ -f "$split_head" ]] && echo yes || echo no ))"
  fi
}
test_n_repeated_heading_appends_not_truncates

# ── (o) sed -i.bak hard failure: self-heal deletes, re-run succeeds ─────
echo "--- (o) sed -i.bak hard failure (truncated target + exit 1): self-heal deletes, re-run succeeds ---"

test_o_sed_hard_failure_self_heals() {
  local root="$WORKDIR/case-o" slug="case-o-slug"
  local bindir="$WORKDIR/case-o-bin"
  mkdir -p "$bindir"
  # SV-gate judge finding: case (a)'s stub targets the OLD `sed -i ''`
  # invocation form, which the code no longer emits, so it never fires and
  # the self-heal in _render_prompt_placeholders went untested — removing
  # it entirely was not caught. This stub targets the REAL current
  # invocation instead: simulates a hard sed -i.bak failure by creating the
  # .bak copy (as real sed does before editing) then truncating the target
  # and exiting 1. Scoped to the exact 3-arg `-i.bak script file` shape
  # _render_prompt_placeholders uses — the .gitignore edit elsewhere passes
  # -E too (4 args), so it is untouched by this stub.
  cat > "$bindir/sed" <<'STUB'
#!/bin/sh
if [ "$1" = "-i.bak" ] && [ "$#" -eq 3 ]; then
  file="$3"
  cp "$file" "$file.bak"
  : > "$file"
  exit 1
fi
exec /usr/bin/sed "$@"
STUB
  chmod +x "$bindir/sed"

  local out rc
  out="$(PATH="$bindir:$PATH" ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    pass "O-1: init exits non-zero on a hard sed -i.bak failure"
  else
    fail "O-1: init exited 0 despite a hard sed failure (expected non-zero)"
  fi

  local fw="$root/.rlp-desk/prompts/$slug.flywheel.prompt.md"
  if [[ ! -f "$fw" ]]; then
    pass "O-2: the half-written/truncated flywheel prompt was deleted (self-heal)"
  else
    fail "O-2: half-written flywheel prompt was NOT deleted after the sed failure: $fw"
  fi
  if [[ ! -f "$fw.bak" ]]; then
    pass "O-3: no leftover .bak file after the self-heal"
  else
    fail "O-3: leftover .bak file found: $fw.bak"
  fi

  local out2 rc2
  out2="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc2=$?
  if [[ $rc2 -eq 0 ]] && [[ -f "$fw" ]] && ! grep -qE '\{DESK\}|\{SLUG\}' "$fw"; then
    pass "O-4: re-run with real sed self-heals — exits 0, prompt regenerated, no placeholders"
  else
    fail "O-4: re-run with real sed did not self-heal (rc=$rc2, tail: $(tail_lines "$out2" 6))"
  fi
}
test_o_sed_hard_failure_self_heals

# ── (p) sed silently no-ops: leftover-placeholder guard fires ───────────
echo "--- (p) sed -i.bak silently no-ops (exit 0, no substitution): leftover-placeholder guard fires ---"

test_p_sed_silent_noop_self_heals() {
  local root="$WORKDIR/case-p" slug="case-p-slug"
  local bindir="$WORKDIR/case-p-bin"
  mkdir -p "$bindir"
  # Simulates sed exiting 0 while performing NO substitution at all (e.g. a
  # broken sed build silently matching nothing) — same 3-arg targeting as
  # case (o)'s stub. Exercises the SECOND self-heal branch in
  # _render_prompt_placeholders (the post-success leftover-{DESK}/{SLUG}
  # grep), not the sed-exit-code branch (o) exercises.
  cat > "$bindir/sed" <<'STUB'
#!/bin/sh
if [ "$1" = "-i.bak" ] && [ "$#" -eq 3 ]; then
  file="$3"
  cp "$file" "$file.bak"
  exit 0
fi
exec /usr/bin/sed "$@"
STUB
  chmod +x "$bindir/sed"

  local out rc
  out="$(PATH="$bindir:$PATH" ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    pass "P-1: init exits non-zero when sed silently no-ops (leftover-placeholder guard fires)"
  else
    fail "P-1: init exited 0 despite sed leaving {DESK}/{SLUG} placeholders unrendered"
  fi

  local fw="$root/.rlp-desk/prompts/$slug.flywheel.prompt.md"
  if [[ ! -f "$fw" ]]; then
    pass "P-2: the still-placeholdered flywheel prompt was deleted (self-heal)"
  else
    fail "P-2: flywheel prompt with unrendered placeholders was NOT deleted: $fw"
  fi
  if [[ ! -f "$fw.bak" ]]; then
    pass "P-3: no leftover .bak file after the self-heal"
  else
    fail "P-3: leftover .bak file found: $fw.bak"
  fi

  local out2 rc2
  out2="$(ROOT="$root" zsh "$INIT_ABS" "$slug" 2>&1)"
  rc2=$?
  if [[ $rc2 -eq 0 ]] && [[ -f "$fw" ]] && ! grep -qE '\{DESK\}|\{SLUG\}' "$fw"; then
    pass "P-4: re-run with real sed self-heals — exits 0, prompt regenerated, no placeholders"
  else
    fail "P-4: re-run with real sed did not self-heal (rc=$rc2, tail: $(tail_lines "$out2" 6))"
  fi
}
test_p_sed_silent_noop_self_heals

# ── (q) partial split (duplicate US id): WARNING, not a failure ─────────
echo "--- (q) partial split (duplicate US id): WARNING, not a failure ---"

test_q_partial_split_warns_not_fails() {
  local root="$WORKDIR/case-q" slug="case-q-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  [[ -f "$prd" ]] || { fail "Q-setup: first-run did not create $prd"; return; }
  # 1 good heading (the scaffold's own ### US-001: [Title]) + 1 reused-id
  # heading (still 3-hash, per the PRD contract — matches the boundary
  # regex, so the loose gate counts it, but it writes to the SAME target
  # file, not a new one — same fixture shape as case n) — 2 markers, 1
  # distinct split file.
  cat >> "$prd" <<'HEADING_EOF'

### US-001 rationale
Appendix note about US-001.
HEADING_EOF

  local out rc
  out="$(fresh_run_init "$root" "$slug" 2>&1)"
  rc=$?

  if [[ $rc -eq 0 ]]; then
    pass "Q-1: init exits 0 for a partial split (duplicate US id) — WARNING, not a failure"
  else
    fail "Q-1: init exited $rc for a partial split (expected 0 with a WARNING) (tail: $(tail_lines "$out" 8))"
  fi
  if echo "$out" | grep -qF "WARNING: PRD has 2 US-looking marker(s) but only 1"; then
    pass "Q-2: init prints a WARNING naming the marker-vs-file count mismatch"
  else
    fail "Q-2: no count-mismatch WARNING in output (tail: $(tail_lines "$out" 8))"
  fi
  local split_file="$root/.rlp-desk/plans/prd-$slug-US-001.md"
  if [[ -f "$split_file" ]] && grep -qF 'Appendix note about US-001' "$split_file"; then
    pass "Q-3: the reused-id heading's content is still preserved in the split file (not silently dropped)"
  else
    fail "Q-3: appendix content missing from the split file despite the WARNING (would be lossy, not just noisy)"
  fi
}
test_q_partial_split_warns_not_fails

# ── (r) forced split_prd_by_us failure: call-site restore fires ─────────
echo "--- (r) forced split_prd_by_us failure: call-site restore fires ---"

test_r_forced_prd_split_failure_self_heals() {
  local root="$WORKDIR/case-r" slug="case-r-slug"
  local forced_init
  forced_init="$(build_forced_failure_init)"
  ROOT="$root" zsh "$forced_init" "$slug" "obj" >/dev/null 2>&1

  local out rc
  out="$(FORCE_SPLIT_PRD_FAIL=1 ROOT="$root" zsh "$forced_init" "$slug" "obj" --mode fresh 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    pass "R-1: init exits non-zero on a forced split_prd_by_us failure"
  else
    fail "R-1: init exited 0 despite a forced split_prd_by_us failure"
  fi
  if echo "$out" | grep -qF "forced split_prd_by_us failure"; then
    pass "R-2: the forced-failure message from split_prd_by_us surfaces in the output"
  else
    fail "R-2: forced-failure message missing (tail: $(tail_lines "$out" 8))"
  fi
  if [[ -f "$root/.rlp-desk/plans/test-spec-$slug.md" ]]; then
    pass "R-3: test-spec-$slug.md is present (the call-site restore fires under a forced failure, even though split_prd_by_us's own count==0 branch is unreachable through real content now)"
  else
    fail "R-3: test-spec-$slug.md is missing after the forced PRD split failure (restore did not fire)"
  fi
}
test_r_forced_prd_split_failure_self_heals

# ── (s) forced split_test_spec_by_us failure: symmetric guard fires ─────
echo "--- (s) forced split_test_spec_by_us failure: symmetric guard fires ---"

test_s_forced_testspec_split_failure_guarded() {
  local root="$WORKDIR/case-s" slug="case-s-slug"
  local forced_init
  forced_init="$(build_forced_failure_init)"
  ROOT="$root" zsh "$forced_init" "$slug" "obj" >/dev/null 2>&1

  local out rc
  out="$(FORCE_SPLIT_TS_FAIL=1 ROOT="$root" zsh "$forced_init" "$slug" "obj" --mode fresh 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    pass "S-1: init exits non-zero on a forced split_test_spec_by_us failure (symmetric with the PRD side)"
  else
    fail "S-1: init exited 0 despite a forced split_test_spec_by_us failure"
  fi
  if echo "$out" | grep -qF "forced split_test_spec_by_us failure"; then
    pass "S-2: the forced-failure message from split_test_spec_by_us surfaces"
  else
    fail "S-2: forced-failure message missing (tail: $(tail_lines "$out" 8))"
  fi
  if echo "$out" | grep -qF "ERROR: split_test_spec_by_us failed"; then
    pass "S-3: the call site's own explicit ERROR wrapper fires (previously an unguarded bare statement)"
  else
    fail "S-3: call-site ERROR wrapper did not fire (tail: $(tail_lines "$out" 8))"
  fi
}
test_s_forced_testspec_split_failure_guarded

# ── (t) --reset-plans: versioned wipe of authored PRD + test-spec ───────
echo "--- (t) --reset-plans: authored PRD/test-spec wiped, versioned backup kept ---"

test_t_reset_plans_versions_authored_content() {
  local root="$WORKDIR/case-t" slug="case-t-slug"
  first_run_init "$root" "$slug"
  local prd="$root/.rlp-desk/plans/prd-$slug.md"
  local ts="$root/.rlp-desk/plans/test-spec-$slug.md"
  [[ -f "$prd" && -f "$ts" ]] || { fail "T-setup: first-run did not create $prd and/or $ts"; return; }
  # Author BOTH — --reset-plans is checked at the top of each branch
  # (before the authored-preserve check), so it must override authored
  # status too: this is the flag's whole purpose (force-reset regardless
  # of authorship), unlike --mode fresh alone, which preserves authored
  # content. Confirmed by reading the source first: RESET_PLANS routes
  # through version_file (not a bare rm) in both branches — same
  # backup-before-wipe contract as the scaffold-detection branches, so the
  # assertion here is "wiped + versioned," not "wiped with no recovery."
  sed -i.bak 's/^### US-001: \[Title\]$/### US-001 - Really Authored Title/' "$prd" && rm -f "$prd.bak"
  printf '\nAUTHORED_TESTSPEC_MARKER\n' >> "$ts"

  local out rc
  out="$(ROOT="$root" zsh "$INIT_ABS" "$slug" "obj" --mode fresh --reset-plans 2>&1)"
  rc=$?

  if [[ $rc -ne 0 ]]; then
    fail "T-1: init exited $rc for --reset-plans (tail: $(tail_lines "$out" 8))"
    return
  fi
  pass "T-1: init exits 0 for --mode fresh --reset-plans"

  if ! grep -qF "Really Authored Title" "$prd" 2>/dev/null; then
    pass "T-2: --reset-plans wipes the authored PRD despite it being authored (overrides preserve)"
  else
    fail "T-2: authored PRD content survived --reset-plans (expected an unconditional wipe)"
  fi
  if [[ -f "$root/.rlp-desk/plans/prd-$slug-v1.md" ]] && grep -qF "Really Authored Title" "$root/.rlp-desk/plans/prd-$slug-v1.md"; then
    pass "T-3: the authored PRD content is recoverable in the versioned backup (wipe, not destroy)"
  else
    fail "T-3: no versioned backup preserves the authored PRD content — --reset-plans would be destructive with no recovery"
  fi
  if ! grep -qF "AUTHORED_TESTSPEC_MARKER" "$ts" 2>/dev/null; then
    pass "T-4: --reset-plans wipes the authored test-spec despite it being authored"
  else
    fail "T-4: authored test-spec content survived --reset-plans"
  fi
  if [[ -f "$root/.rlp-desk/plans/test-spec-$slug-v1.md" ]] && grep -qF "AUTHORED_TESTSPEC_MARKER" "$root/.rlp-desk/plans/test-spec-$slug-v1.md"; then
    pass "T-5: the authored test-spec content is recoverable in the versioned backup"
  else
    fail "T-5: no versioned backup preserves the authored test-spec content"
  fi
  if echo "$out" | grep -qF "Reset:     prd-$slug.md (--reset-plans:" && echo "$out" | grep -qF "Reset:     test-spec-$slug.md (--reset-plans:"; then
    pass "T-6: init reports the --reset-plans-specific Reset message for both files"
  else
    fail "T-6: expected --reset-plans Reset messages not found (tail: $(tail_lines "$out" 8))"
  fi
}
test_t_reset_plans_versions_authored_content

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

(( FAIL > 0 )) && exit 1
exit 0
