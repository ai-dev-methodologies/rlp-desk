#!/bin/zsh
set -euo pipefail

# =============================================================================
# Ralph Desk Project Initializer for Claude Code
#
# User-level tool: ~/.claude/ralph-desk/init_ralph_desk.zsh
# Creates project-local scaffold in: .rlp-desk/ (v0.13.0+; auto-migrates from
# legacy .claude/ralph-desk/ to avoid Claude Code's hardcoded sensitive-file
# policy that hung worker sentinel writes).
#
# Usage:
#   ~/.claude/ralph-desk/init_ralph_desk.zsh <slug> [objective] [--mode fresh|improve]
# =============================================================================

SLUG="${1:?Usage: $0 <slug> [objective] [--mode fresh|improve] [--reset-plans] [--verify-mode per-us|batch] [--server-cmd CMD] [--server-port PORT] [--server-health URL]}"
# IMP-08: fail-fast slug guard. SLUG is interpolated raw into filesystem paths
# ($DESK/logs/$SLUG, mkdir, rm), so a `../..`/separator/uppercase slug could
# escape the .rlp-desk tree. This regex is a superset of the Node normalizeSlug
# output (lowercase [a-z0-9-], no leading/trailing/collapsed `-`), so no valid
# slug is rejected; it blocks `.`, `/`, `..`, uppercase, and spaces BEFORE any
# mkdir/rm. Mirrors the Node reject-guard (run.mjs requireCanonicalSlug).
[[ "$SLUG" =~ '^[a-z0-9][a-z0-9-]*$' ]] || { print -u2 "ERROR: invalid slug: $SLUG (must be lowercase [a-z0-9-], no path separators)"; exit 2; }
MODE=""
OBJECTIVE="TBD - fill in the objective"
SERVER_CMD=""
SERVER_PORT=""
SERVER_HEALTH=""
# --verify-mode is parsed here so the PRD cross-US lint matches the mode the
# user actually plans to run with. Falls back to the VERIFY_MODE env var (which
# the wrapper may already export) and finally to the per-us default.
VERIFY_MODE_ARG=""
# v0.22.3 US-002: --mode fresh preserves AUTHORED plans by default; this flag
# restores the wipe (with a versioned backup first — destructive path always
# leaves a recovery copy).
RESET_PLANS=0

# Parse remaining arguments
shift
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:?--mode requires an argument: fresh|improve}"
      shift 2
      ;;
    --mode=*)
      MODE="${1#--mode=}"
      shift
      ;;
    --reset-plans)
      RESET_PLANS=1
      shift
      ;;
    --verify-mode)
      VERIFY_MODE_ARG="${2:?--verify-mode requires an argument: per-us|batch}"
      shift 2
      ;;
    --verify-mode=*)
      VERIFY_MODE_ARG="${1#--verify-mode=}"
      shift
      ;;
    --server-cmd)
      SERVER_CMD="${2:?--server-cmd requires a command}"
      shift 2
      ;;
    --server-cmd=*)
      SERVER_CMD="${1#--server-cmd=}"
      shift
      ;;
    --server-port)
      SERVER_PORT="${2:?--server-port requires a port number}"
      shift 2
      ;;
    --server-port=*)
      SERVER_PORT="${1#--server-port=}"
      shift
      ;;
    --server-health)
      SERVER_HEALTH="${2:?--server-health requires a URL}"
      shift 2
      ;;
    --server-health=*)
      SERVER_HEALTH="${1#--server-health=}"
      shift
      ;;
    *)
      OBJECTIVE="$1"
      shift
      ;;
  esac
done

ROOT="${ROOT:-$PWD}"
# v0.13.0: project-local runtime moved out of .claude/ to avoid Claude Code's
# hardcoded sensitive policy that hung worker sentinel writes. Honor
# RLP_DESK_RUNTIME_DIR env override so future platform changes can be dodged
# without a release.
DESK="$ROOT/${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"
RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"

# v0.13.0: legacy .claude/ralph-desk/ auto-migration on init.
LEGACY_DESK="$ROOT/.claude/ralph-desk"
if [[ -d "$LEGACY_DESK" ]]; then
  if [[ -d "$DESK" ]]; then
    echo "ERROR: both directories exist (legacy=$LEGACY_DESK, new=$DESK)." >&2
    echo "Remove one before re-running init." >&2
    exit 1
  fi
  echo "[v0.13.0] migrating $LEGACY_DESK -> $DESK"
  mkdir -p "$(dirname "$DESK")"
  mv "$LEGACY_DESK" "$DESK"
fi

# --- Re-execution versioning helpers ---
# Handles ONLY debug.log and campaign-report.md versioning.
# SV reports use their own -NNN auto-increment pattern and are NOT handled here.

detect_next_version() {
  local file_path="$1"
  local dir base ext n=1
  dir="$(dirname "$file_path")"
  base="$(basename "$file_path")"
  if [[ "$base" == *.* ]]; then
    ext=".${base##*.}"
    base="${base%.*}"
  else
    ext=""
  fi
  while [[ -f "$dir/${base}-v${n}${ext}" ]]; do
    (( n++ ))
  done
  echo "$n"
}

# A-6 fix (reaudit wave 1): `sed -i '' "script" file` (a bare empty-string
# backup-suffix argument) is BSD/macOS-only. On GNU sed (Ubuntu CI) the
# empty '' is consumed as the sed script itself (not the suffix), and the
# real script is then read as a second script argument that GNU's `-i`
# option-parsing rejects — sed exits 2, and `set -euo pipefail` aborts init
# right after the heredoc has already written the prompt file, so the
# `[[ ! -f "$F" ]]` idempotency guard skips the block forever on re-run
# while placeholders like {DESK}/{SLUG} stay unexpanded and init exits 0.
# `sed -i.bak ... && rm -f "$file.bak"` (already used elsewhere in this file
# for the .gitignore edit) is the portable form: the suffix is attached
# directly to -i with no space, which both BSD and GNU sed parse the same way.
_sed_escape_repl() {
  # Escape characters special to sed's replacement side (backslash, the `|`
  # delimiter used at both call sites, and `&` which means "whole match") so
  # a DESK/SLUG value containing one of them substitutes literally instead
  # of corrupting or truncating the sed script. Done with zsh's own pattern
  # substitution (not sed -e) to sidestep any BSD/GNU disagreement over
  # backslash handling inside bracket expressions. Order matters: backslash
  # must be escaped first, or the backslashes this function inserts for `|`
  # and `&` would themselves get re-escaped by the following passes.
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//|/\\|}"
  s="${s//&/\\&}"
  printf '%s' "$s"
}

# Renders the {DESK}/{SLUG} placeholders left by a prompt-template heredoc,
# portably, and self-heals on any failure: a partial or failed substitution
# deletes the file instead of leaving it half-rendered, so the caller's
# `[[ ! -f "$F" ]]` idempotency guard regenerates it correctly on next run.
_render_prompt_placeholders() {
  local f="$1"
  local desk_esc slug_esc
  desk_esc="$(_sed_escape_repl "$DESK")"
  slug_esc="$(_sed_escape_repl "$SLUG")"
  if ! sed -i.bak "s|{DESK}|$desk_esc|g; s|{SLUG}|$slug_esc|g" "$f"; then
    rm -f "$f" "$f.bak"
    echo "  ERROR: sed substitution failed on $f — removed so init regenerates it on next run" >&2
    return 1
  fi
  rm -f "$f.bak"
  if grep -qE '\{DESK\}|\{SLUG\}' "$f" 2>/dev/null; then
    rm -f "$f"
    echo "  ERROR: {DESK}/{SLUG} placeholder left unexpanded in $f — removed so init regenerates it on next run" >&2
    return 1
  fi
  return 0
}

# A-7 fix (reaudit wave 1): the pristine PRD template, emitted by a function
# so the fresh-mode authored detector can compare the WHOLE file against
# exactly what the scaffold would generate — no marker heuristics. Mirrors
# _emit_testspec_template below. $SLUG/$OBJECTIVE are the only variables the
# scaffold interpolates, so both the writer (PRD generation, further below)
# and the detector call this same function to stay byte-for-byte in sync.
_emit_prd_template() {
  local SLUG="$1"
  local OBJECTIVE="$2"
  cat <<EOF
# PRD: $SLUG

## Objective
$OBJECTIVE

## 위임 규칙 (Delegated Decisions) — REQUIRED
<!--
  request-d ①-a: a campaign runs with ZERO owner/user interaction. Every
  decision the loop could meet at runtime MUST be pre-decided here at plan time.
  A PRD that leaves a runtime decision to "ask the owner" is NOT complete — the
  brainstorm 무인-완주 (unattended-completion) gate REJECTS it.
  Fill each rule below with the concrete policy the worker follows without asking.
  Delete a line only if you can prove the campaign can never meet that decision.
-->
- **신규 표면/산출물 등록 관례** (new surfaces/artifacts): [e.g. "register every new file under src/ in MANIFEST.txt; no owner sign-off needed"]
- **원장·레지스트리 갱신 규칙** (ledger/registry updates): [e.g. "append to registry.json in sorted order; regenerate the derived index in the same commit"]
- **fixture·합성데이터 처분** (fixtures / synthetic data): [e.g. "generate deterministic fixtures under tests/fixtures/; commit them; never call external services"]
- **알려진 baseline 처분** (known baselines): [e.g. "rebaseline provenance fingerprints in-place when the source changed intentionally; document the delta in memory.md"]
- (add any other decision class this campaign will meet — the goal is: the worker never needs an owner mid-run)

## User Stories

### US-001: [Title]
- **Priority**: P0
- **Size**: S|M|L
- **Type**: code|visual|content|integration|infra
- **Risk**: LOW|MEDIUM|HIGH|CRITICAL (governance §1c)
- **Depends on**: []
- **Acceptance Criteria** (Given/When/Then — domain language only):
  - AC1:
    - Given: [precondition in domain language]
    - When: [action in domain language]
    - Then: [expected outcome with quantitative criteria]
  - AC2:
    - Given: [precondition]
    - When: [action]
    - Then: [expected outcome with quantitative criteria]
- **Boundary Cases**: [edge cases — empty input, max values, error conditions, concurrent access]
- **Verification Layers**: [Fill per Risk level — LOW: L1+L3, MEDIUM: L1+L2(if ext deps)+L3, HIGH: L1+L2+L3+L4, CRITICAL: L1+L2+L3+L4+mutation (governance §1c)]
- **Status**: not started

## Non-Goals
## Technical Constraints
## Done When
- All acceptance criteria pass with quantitative evidence
- All boundary cases covered
- All required verification layers executed (no TODO remaining)
- Independent verifier confirms via Evidence Gate (governance §1b)
EOF
}

# A-7 fix (reaudit wave 1, review follow-up): the byte-exact diff below
# compares against _emit_prd_template rendered with the CURRENT $OBJECTIVE —
# but a never-edited scaffold created with objective X, re-run via
# `--mode fresh` with a different objective Y (the common flow:
# `init <slug>` first with no objective, then
# `init <slug> "<real objective>" --mode fresh`), would then differ from the
# live-rendered template on the Objective line ALONE and get misclassified
# as "authored" — preserving the stale objective while memory.md moves on to
# the new one. Mask the Objective section (the span from the `## Objective`
# heading up to, but not including, the next `##` heading — content, not
# just the OBJECTIVE var, in case it spans multiple lines) to a fixed token
# in BOTH sides before diffing, so an objective-only edit still counts as
# "unauthored scaffold" (safe: still gets a versioned backup, never a bare
# delete) while ANY other edit still counts as authored (safe: preserved).
_normalize_prd_objective() {
  awk '
    /^## Objective$/ { print; print "<OBJECTIVE-MASKED-FOR-COMPARISON>"; in_obj=1; next }
    in_obj && /^##/ { in_obj=0 }
    in_obj { next }
    { print }
  '
}

# v0.22.3 US-002: per-file authored-plan detection. Fail-open toward
# PRESERVE (misclassification is non-destructive: --reset-plans backs up
# before any wipe, and a preserved template is merely regenerated content).
# A-7 fix (reaudit wave 1): previously used a single regex
# (^### US-[0-9]+: excluding [Title]) that did not match the dash heading
# form _extract_prd_us_list officially accepts (### US-001 - Title), and
# also missed an authored body sitting under an untouched placeholder
# heading. Byte-exact diff against the live scaffold (same technique as
# _testspec_is_authored) catches ANY edit, matching lib_ralph_desk.zsh's
# broader heading acceptance and removing the false-negative class entirely.
# Both sides are run through _normalize_prd_objective first (see above) so
# an objective-only drift does not itself trigger a false "authored" verdict.
_prd_is_authored() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  ! diff -q <(_emit_prd_template "$SLUG" "$OBJECTIVE" | _normalize_prd_objective) \
            <(_normalize_prd_objective < "$f") >/dev/null 2>&1
}
# v0.22.3 (final-review P1-3): the pristine test-spec template, emitted by a
# function so the fresh-mode authored detector can compare the WHOLE file
# against exactly what the scaffold would generate — no marker heuristics.
_emit_testspec_template() {
  local SLUG="$1"
  cat <<EOF
# Test Specification: $SLUG

## Iron Law Reference
> IL-3: NO PASS WITH TODO IN ANY REQUIRED VERIFICATION LAYER
> IL-4: NO PASS WITHOUT TEST COUNT >= AC COUNT x 3

---

## Verification Commands
### Build
\`\`\`bash
# TODO
\`\`\`
### Test
\`\`\`bash
# TODO
\`\`\`
### Lint
\`\`\`bash
# TODO
\`\`\`

---

## Verification Context (fill BEFORE implementation)

### Target Behavior
What behavior does this project change or introduce?
- TODO

### Impacted Tests
Existing tests that may break due to this change:
- TODO (acceptable at init; Worker fills during first iteration)

### Required New Tests
Tests that MUST be written (minimum 3 per AC: happy + negative + boundary):
- TODO

### Forbidden Shortcuts (see Worker prompt for full list)
- Do not mock external services when L2 integration test is required
- Do not delete or weaken existing assertions to make tests pass
- Do not add test-specific logic (if __name__ == '__test__' patterns)
- Do not skip boundary cases listed in the PRD
- Do not claim "code inspection" as verification — run the actual command
- Do not say "too simple to test" — simple code breaks
- Do not say "I'll test after" — tests passing immediately prove nothing
- Do not say "already manually tested" — ad-hoc is not systematic
- Do not say "partial check is enough" — partial proves nothing
- Do not say "I'm confident" — confidence is not evidence
- Do not say "existing code has no tests" — you are improving it, add tests
- Do not write code before tests — delete it and start with tests

### Pass/Fail Evidence Format
- Command output with exit code 0
- Quantitative result matching expected value
- Screenshot comparison (for visual tasks)

---

## Verification Layers (ALL required sections — TODO in required layer = Verifier FAIL)

### L1: Unit Test (REQUIRED)
\`\`\`bash
# TODO — unit test command (e.g., pytest, jest, go test)
\`\`\`

### L2: Integration (required if external services exist, otherwise "N/A — reason")
\`\`\`bash
# TODO — integration test command, or write: N/A — no external services (pure computation/transformation)
\`\`\`

### L3: E2E Simulation (REQUIRED)
Known input → full pipeline → quantitative output comparison.
Must cover ALL AC types: happy path + boundary + error path.
- **Happy path input**: TODO (specific test data)
- **Happy path expected output**: TODO (quantitative value)
- **Happy path command**:
\`\`\`bash
# TODO — E2E happy path command
\`\`\`
- **Error path input**: TODO (invalid/boundary input that triggers error)
- **Error path expected**: TODO (error type + non-zero exit code)
- **Error path command**:
\`\`\`bash
# TODO — E2E error path command (expected exit ≠ 0)
\`\`\`

### L4: Deploy Verification (required if deploying, otherwise "N/A — reason")
\`\`\`bash
# TODO — deploy verification command, or write: N/A — no deployment (library/tool, local-only change)
\`\`\`

---

## Mutation Testing Gate (CRITICAL risk only)
- Required: only for CRITICAL risk classification (governance §1c)
- Tool: TODO (e.g., mutmut, Stryker, go-mutesting) or "N/A — not CRITICAL risk"
- Target: >= 60% mutation score on core business logic (project default; override in PRD if justified)
- Scope: core business logic files (not config/tests/docs)
- Command:
\`\`\`bash
# TODO — mutation testing command, or write: N/A — not CRITICAL risk
\`\`\`

---

## Test Quality Checklist (Verifier checks these)
- [ ] Tests verify behavior, not implementation details
- [ ] Each test has meaningful assertions (not just "no error thrown")
- [ ] Boundary cases covered (empty, max, zero, null, concurrent)
- [ ] No tautological tests (expected value copied from implementation)
- [ ] Mock usage limited to external boundaries only
- [ ] No test-specific logic in production code
- [ ] Each AC has >= 3 tests (happy + negative + boundary) per IL-4

## Traceability Matrix (Worker fills during implementation)

| US | AC | Test File :: Function | Layer | Evidence | Status |
|----|----|----------------------|-------|----------|--------|
| US-001 | AC1 | TODO | L1 | TODO | pending |

---

## Code Quality Gates (defaults — override in PRD with justification)
- **Code duplication**: <= 3% (project-appropriate tool, e.g., jscpd, pylint, sonar)
- **Mock ratio**: mock-based assertions <= 30% of total assertions
- **Cyclomatic complexity**: <= 10 per function
- **Function length**: <= 50 lines per function
- **File length**: <= 800 lines per file

---

## Reproducibility Gate
- [ ] Lock file exists and committed (package-lock.json, poetry.lock, go.sum, etc.) or "N/A — no external dependencies"
- [ ] Clean install succeeds (npm ci, pip install, etc.) or "N/A — no external dependencies"
- [ ] Security scan passes (or known vulnerabilities documented and acknowledged in PRD) or "N/A — no dependencies"
- [ ] Environment variables documented (.env.example or equivalent) or "N/A — no env vars"

---

## Criteria → Verification Mapping

| US | AC | Layer | Method | Command | Expected Output | Pass Criteria |
|----|----|-------|--------|---------|-----------------|---------------|
| US-001 | AC1 | L1 | TODO | TODO | TODO | TODO |
EOF
}

_testspec_is_authored() {
  local f="$1"
  [[ -f "$f" ]] || return 1
  # final-review P1-3: authored = ANY byte differs from the pristine scaffold
  # for this slug (marker heuristics deleted specs whose only edits were
  # ADDITIONS next to intact placeholders). Exact comparison, fail-open
  # toward preserve: identical to the template -> regenerate; anything
  # else -> the operator touched it, keep it.
  ! diff -q <(_emit_testspec_template "$SLUG") "$f" >/dev/null 2>&1
}

version_file() {
  local file_path="$1"
  if [[ -f "$file_path" ]]; then
    local n dir base ext
    n="$(detect_next_version "$file_path")"
    dir="$(dirname "$file_path")"
    base="$(basename "$file_path")"
    if [[ "$base" == *.* ]]; then
      ext=".${base##*.}"
      base="${base%.*}"
    else
      ext=""
    fi
    mv "$file_path" "$dir/${base}-v${n}${ext}"
    echo "  Versioned: $(basename "$file_path") → ${base}-v${n}${ext}"
  fi
  # Non-existent files silently skipped (no error)
}

# --- PRD/test-spec per-US splitting helpers ---

split_prd_by_us() {
  local prd_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$prd_file")"

  [[ -f "$prd_file" ]] || return 0

  # reaudit wave 1 (SV-gate finding, follow-up) + correction: the loose gate
  # uses the EXACT SAME regex (grep -E) as the strict boundary pattern
  # below, so gate and splitter can never disagree. PRD story headings are
  # 3-hash ONLY by committed contract — see
  # tests/test_us001_prd_splitting.sh AC1-L3-neg: a PRD whose headings are
  # `## US-001: Title` (2-hash) MUST produce ZERO split files, because
  # `### US-NNN` is the PRD story level and `## US-NNN` is the TEST-SPEC
  # section level (split_test_spec_by_us below) — a 2-hash line inside a
  # PRD is not a story heading. An earlier revision of this fix briefly
  # widened this to `#{2,3}` (2-or-3 hash) to mirror
  # lib_ralph_desk.zsh's _extract_prd_us_list, which broke that contract
  # (AC1-L3-neg went from 0 to 2 split files) — reverted. Note
  # _extract_prd_us_list is DELIBERATELY more permissive than this
  # splitter: it feeds the US-022 stale-signal quarantine scope check,
  # where treating a 2-hash mention as "in scope" is the safer
  # (non-destructive) direction, unlike splitting, which creates new
  # per-US files an operator did not ask for. The real fix for the
  # dash-form bug this round addressed is the separator alternation
  # (colon/dash/space/end-of-line), not the hash count — kept below.
  local us_count
  us_count=$(grep -cE '^###[[:space:]]+US-[0-9]+([[:space:]:-]|$)' "$prd_file" 2>/dev/null) || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    echo "  WARNING: No US markers (### US-NNN:) found in PRD — falling back to full PRD injection" >&2
    # Clean up any stale per-US split files from previous runs to prevent stale artifacts
    local stale_count=0
    for stale in "$plans_dir"/prd-"$slug"-US-*.md(N); do
      rm "$stale"; stale_count=$(( stale_count + 1 ))
    done
    [[ $stale_count -gt 0 ]] && echo "  Cleaned $stale_count stale prd per-US file(s)"
    return 0
  fi

  # reaudit wave 1 (SV-gate finding, MEDIUM+CRITICAL-scenario) + correction:
  # - boundary regex accepts colon/dash/space/end-of-line after `US-NNN` —
  #   was colon-only, which produced ZERO split files for a dash-form
  #   heading (### US-001 - Title) even though us_count (the loose grep
  #   above) correctly saw >=1 US. STILL 3-HASH ONLY, by contract — see the
  #   loose-gate comment above (tests/test_us001_prd_splitting.sh
  #   AC1-L3-neg): a 2-hash `## US-NNN` line is the test-spec section level
  #   (split_test_spec_by_us below), not a PRD story heading, and must
  #   never be split here even though it matches lib_ralph_desk.zsh's
  #   _extract_prd_us_list (deliberately `#{2,3}` there — see the loose-gate
  #   comment for why that function's broader acceptance is correct for its
  #   own purpose and not a precedent for this one). init does not source
  #   lib_ralph_desk.zsh (stays standalone by design), so the regex text is
  #   duplicated here rather than the function; keep the two in sync by hand.
  # - plans_dir goes through ENVIRON, not -v: POSIX awk -v applies C-style
  #   backslash-escape processing to its value, so a project root path
  #   containing a literal backslash silently corrupts the split target path
  #   (verified: `awk -v dir='a\with\backslash'` prints `awithackslash`;
  #   ENVIRON performs no such processing).
  # - reaudit wave 1 (SV-gate review, MEDIUM, follow-up): `close(out)` then a
  #   later `print > out` on the SAME filename REOPENS it in TRUNCATE mode
  #   (verified: two `print > f` blocks separated by `close(f)` leave only
  #   the second block's content). A PRD appendix/TOC line reusing an
  #   earlier us_id (e.g. "### US-001 rationale", still 3-hash — a 2-hash
  #   mention does not match this boundary at all, per the contract above)
  #   used to silently wipe the real ### US-001 body written earlier. Fixed
  #   the mechanism, not the regex: track which target files have been
  #   opened this run (seen[]) — `>` (truncate) only the first time a given
  #   us_id is written, `>>` (append) every time after, so a repeated
  #   heading for the SAME us_id accumulates instead of destroying prior
  #   content, while normal contiguous body lines between two DIFFERENT
  #   headings behave exactly as before (this is the observably-identical
  #   case verified byte-exact against git HEAD's split output — see test
  #   case n).
  PLANS_DIR="$plans_dir" awk -v slug="$slug" '
    /^###[[:space:]]+US-[0-9]+([[:space:]:-]|$)/ {
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = ENVIRON["PLANS_DIR"] "/prd-" slug "-" us_id ".md"
    }
    out != "" {
      if (out in seen) { print >> out } else { print > out; seen[out] = 1 }
    }
  ' "$prd_file"

  # Count via a zsh array, not `ls glob(N) | wc -l`: with (N) nullglob and
  # zero matches, the glob token vanishes entirely, so `ls` would receive NO
  # argument at all and fall back to listing the current directory instead
  # of reporting zero files — silently corrupting the precondition check
  # below with an unrelated file count. An array assignment has no such
  # pitfall: zero matches is simply an empty array.
  local -a split_files
  split_files=("$plans_dir"/prd-"$slug"-US-*.md(N))
  local count=${#split_files}
  # Loud, non-destructive precondition: the loose grep above saw >=1
  # US-looking marker, but if the split above still produced ZERO files,
  # fail clearly instead of silently proceeding with an empty per-US split
  # set (which would starve the Worker of any US-scoped context), or, as
  # the unguarded `ls` glob used to do without the `(N)` qualifier above,
  # crashing on a NOMATCH error under `set -e`. Now that the loose gate
  # above and this boundary regex are the identical pattern, they can only
  # disagree via a hand-edit drift between the two copies (duplicated, not
  # shared, since this file stays standalone — see the comment above) or
  # duplicate US ids in the PRD; this check is kept as a defensive
  # invariant for both. The caller (split_prd_by_us "$DESK/plans/prd-..."
  # further below) restores test-spec on this failure, since this call
  # sits between the PRD write and the Test Spec write and a fresh-mode
  # run may have already version_file'd the old test-spec away by this
  # point.
  if [[ "$count" -eq 0 ]]; then
    echo "  ERROR: PRD has $us_count US-looking marker(s) but none matched a" >&2
    echo "         recognized heading form (### US-NNN: or ### US-NNN - Title," >&2
    echo "         exactly 3 leading #). Fix the PRD heading(s) and re-run init." >&2
    return 1
  elif [[ "$count" -lt "$us_count" ]]; then
    # Partial mismatch (SV-gate review, follow-up): more markers matched
    # than distinct split files resulted — a later heading reused an
    # earlier US id (the case (n) appendix/TOC scenario: two headings,
    # same us_id, so the seen[]/append fix above correctly preserves BOTH
    # bodies in one file rather than truncating, but that still collapses
    # 2 markers into 1 file). Not an error — content is never lost — but
    # worth flagging so an unintended duplicate heading doesn't go unnoticed.
    echo "  WARNING: PRD has $us_count US-looking marker(s) but only $count" >&2
    echo "           distinct per-US file(s) resulted — likely a duplicate or" >&2
    echo "           reused US id. Content from every matching heading is" >&2
    echo "           preserved (appended, not lost); check for an unintended" >&2
    echo "           duplicate heading if this count was not expected." >&2
  fi
  echo "  Split PRD: $count per-US files"
}

split_test_spec_by_us() {
  local ts_file="$1"
  local slug="$2"
  local plans_dir
  plans_dir="$(dirname "$ts_file")"

  [[ -f "$ts_file" ]] || return 0

  # reaudit wave 1 (SV-gate finding, HIGH, follow-up to split_prd_by_us —
  # identical bug class): loose gate now uses the EXACT SAME regex as the
  # strict boundary pattern below (same fix, same rationale as
  # split_prd_by_us above — "make the loose gate use the same regex in both
  # functions so gate and splitter can never disagree"). Test-spec headings
  # are 2-hash only — matches lib_ralph_desk.zsh's _lint_3doc_consistency
  # advisory scan of the test-spec (`^##[[:space:]]+US-[0-9]+`) — so this
  # widens colon-vs-dash acceptance only, not the hash count.
  local us_count
  us_count=$(grep -cE '^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)' "$ts_file" 2>/dev/null) || us_count=0
  if [[ "$us_count" -eq 0 ]]; then
    echo "  WARNING: No US section markers (## US-NNN:) in test-spec — skipping split" >&2
    # Clean up any stale per-US test-spec files from previous runs
    for stale in "$plans_dir"/test-spec-"$slug"-US-*.md(N); do
      rm "$stale"
    done
    return 0
  fi

  # Extract global header (everything before the first ## US- section, e.g.
  # Verification Commands) into a VARIABLE, not a tmp file on disk. A tmp
  # file here (test-spec-$slug-header.tmp.$$) previously risked being
  # orphaned in plans/ if anything between its creation and its `rm -f`
  # below aborted the script — exactly what the unguarded NOMATCH crash
  # this whole fix addresses used to do. Capturing into a variable removes
  # the class of risk entirely: there is no file to leak on any exit path.
  # Captured via a NUL-terminated `read`, not `header_content=$(awk ...)`:
  # plain `$(...)` command substitution unconditionally strips ALL trailing
  # newlines, which silently ate the blank line that normally separates the
  # header from the first heading — a real byte-level difference from
  # lib_ralph_desk.zsh's tmp-file-based `cat header_tmp split_file`, not
  # just cosmetic (verified: byte-diffed the two outputs for the same
  # fixture — the blank line was missing). The NUL-delimited `read` and the
  # `printf '%s'` below preserve the captured bytes exactly, so init and lib
  # produce byte-identical split output (see test case l's parity check).
  local header_content
  IFS= read -r -d '' header_content < <(awk '/^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)/{exit} {print}' "$ts_file"; printf '\0') || true

  # Same ENVIRON fix as split_prd_by_us: POSIX awk -v applies C-style
  # backslash-escape processing to its value, corrupting a plans_dir
  # containing a literal backslash. Same seen[]/append fix as split_prd_by_us
  # too: `close(out)` then a later `print > out` on the same filename
  # reopens it in TRUNCATE mode, so a repeated ## US-001 mention later in
  # the test-spec would wipe the real section's body.
  PLANS_DIR="$plans_dir" awk -v slug="$slug" '
    /^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)/ {
      match($0, /US-[0-9]+/)
      us_id = substr($0, RSTART, RLENGTH)
      out = ENVIRON["PLANS_DIR"] "/test-spec-" slug "-" us_id ".md"
    }
    out != "" {
      if (out in seen) { print >> out } else { print > out; seen[out] = 1 }
    }
  ' "$ts_file"

  # Count via a zsh array, not `ls glob(N) | wc -l` — see split_prd_by_us
  # above for why: with (N) nullglob and zero matches, the glob vanishes
  # entirely and `ls` falls back to listing the current directory.
  local -a split_files
  split_files=("$plans_dir"/test-spec-"$slug"-US-*.md(N))

  # Prepend the captured header to each split file. printf '%s' (not
  # `print -r --`, which appends its own trailing newline) writes exactly
  # the bytes captured above — no added or dropped newline at the boundary.
  for split_file in "${split_files[@]}"; do
    local tmp="${split_file}.tmp.$$"
    { printf '%s' "$header_content"; cat "$split_file"; } > "$tmp" && mv "$tmp" "$split_file"
  done

  local count=${#split_files}
  # Loud, non-destructive precondition — same rationale as split_prd_by_us:
  # kept as a defensive invariant now that gate and splitter share the
  # identical regex (see split_prd_by_us for the remaining disagreement
  # cases this still guards against).
  if [[ "$count" -eq 0 ]]; then
    echo "  ERROR: test-spec has $us_count US-looking marker(s) but none matched a" >&2
    echo "         recognized heading form (## US-NNN: or ## US-NNN - Title)." >&2
    echo "         Fix the test-spec heading(s) and re-run init." >&2
    return 1
  elif [[ "$count" -lt "$us_count" ]]; then
    # Partial mismatch — same rationale as split_prd_by_us: a later heading
    # reused an earlier US id, so the seen[]/append fix above correctly
    # preserves both bodies in one file rather than truncating, but that
    # still collapses multiple markers into fewer distinct files. Not an
    # error — content is never lost — but worth flagging.
    echo "  WARNING: test-spec has $us_count US-looking marker(s) but only $count" >&2
    echo "           distinct per-US file(s) resulted — likely a duplicate or" >&2
    echo "           reused US id. Content from every matching heading is" >&2
    echo "           preserved (appended, not lost); check for an unintended" >&2
    echo "           duplicate heading if this count was not expected." >&2
  fi
  echo "  Split test-spec: $count per-US files (with global header)"
}

# --- Run command presets ---
# Detects codex CLI availability and shows appropriate run command presets.
# AC1: codex installed → cross-engine preset first, spark Pro, claude-only, basic
# AC2: codex not installed → tmux + claude-only first, install recommendation
# AC3: full options reference with defaults always shown
print_run_presets() {
  local slug="$1"
  local codex_available=0
  command -v codex &>/dev/null && codex_available=1

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Available run commands (copy the one you want):"
  echo ""
  if [[ $codex_available -eq 1 ]]; then
    echo "# Recommended: cross-engine + final-consensus, luna-first (cheapest capable tier; ladder auto-escalates on failure):"
    echo "/rlp-desk run $slug --mode tmux --worker-model gpt-5.6-luna:high --consensus final-only --debug"
    echo ""
    echo "# Small tasks only (single-file, AC <= 4, simple logic — spark 100k context limit):"
    echo "/rlp-desk run $slug --mode tmux --worker-model spark:high --consensus final-only --debug"
    echo ""
    echo "# Critical (full consensus on every verify):"
    echo "/rlp-desk run $slug --mode tmux --worker-model gpt-5.6-sol:high --consensus all --debug"
    echo ""
    echo "# Claude-only:"
    echo "/rlp-desk run $slug --debug"
  else
    echo "# Recommended: tmux mode + claude-only (real-time visibility):"
    echo "/rlp-desk run $slug --mode tmux --debug"
    echo ""
    echo "# Agent mode:"
    echo "/rlp-desk run $slug --debug"
    echo ""
    echo "# Install codex for cost savings + cross-engine blind-spot coverage:"
    echo "npm install -g @openai/codex"
  fi
  echo ""
  echo "# Full options reference:"
  echo "#   --mode agent|tmux                      (default: agent)"
  echo "#   --worker-model MODEL                   haiku|sonnet|opus|fable or gpt-5.6-sol:high|luna:high|spark:high|astra:high (default: haiku)"
  echo "#   --lock-worker-model                    disable auto model upgrade"
  echo "#   --verifier-model MODEL                 per-US verifier (default: sonnet)"
  echo "#   --final-verifier-model MODEL           final ALL verifier (default: claude-fable-5-1)"
  echo "#   --consensus off|all|final-only         cross-engine consensus (default: off)"
  echo "#   --consensus-model MODEL                per-US cross-verifier (default: gpt-5.6-terra:high)"
  echo "#   --final-consensus-model MODEL          final cross-verifier (default: gpt-6-astra:xhigh)"
  echo "#   --verify-mode per-us|batch             (default: per-us)"
  echo "#   --cb-threshold N                       (default: 6)"
  echo "#   --max-iter N                           (default: 100)"
  echo "#   --iter-timeout N                       tmux only (default: 600)"
  echo "#   --debug                                debug logging"
  echo "#   --with-self-verification               post-campaign SV report"
  echo "#   --flywheel off|on-fail                 direction review on fail (default: off)"
  echo "#   --flywheel-model MODEL                 flywheel reviewer model (default: opus)"
  echo "#   --flywheel-guard off|on                  guard validates flywheel decisions (default: off)"
  echo "#   --flywheel-guard-model MODEL             guard reviewer model (default: opus)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# --- vision-adopt §5: init CLI version stamp ---
# Record the worker/verifier CLI versions at campaign init as a diagnostic
# breadcrumb for CLI-release incidents (the codex 0.145.0 update-dialog class).
# Best-effort and NON-BLOCKING: a missing tool is recorded as "not installed",
# a capture failure as "unknown"; nothing here can fail init. NO version
# pinning/enforcement — this is a breadcrumb, not a gate.
write_init_env_stamp() {
  local slug="$1"
  local out_dir="$DESK/logs/$slug"
  mkdir -p "$out_dir" 2>/dev/null || return 0
  local stamp_file="$out_dir/init-env.json"
  local codex_v claude_v now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  # Capture each CLI's version AND exit status. This runs under `set -euo
  # pipefail` (line 2), so a PRESENT-but-FAILING CLI (nonzero exit — e.g. the
  # 0.145.0-class breakage this stamp exists to diagnose) MUST NOT abort init.
  # The `--version` call sits in an `if` condition (set -e is suppressed there),
  # and the first-line/CR-strip runs in a SEPARATE substitution over a variable
  # so no pipeline exit code can propagate. absent → "not installed"; present
  # but nonzero exit OR empty output → "unknown".
  local _raw
  if command -v codex >/dev/null 2>&1; then
    if _raw=$(codex --version 2>/dev/null); then
      codex_v=$(printf '%s\n' "$_raw" | head -1 | tr -d '\r')
      [[ -n "$codex_v" ]] || codex_v="unknown"
    else
      codex_v="unknown"
    fi
  else
    codex_v="not installed"
  fi
  if command -v claude >/dev/null 2>&1; then
    if _raw=$(claude --version 2>/dev/null); then
      claude_v=$(printf '%s\n' "$_raw" | head -1 | tr -d '\r')
      [[ -n "$claude_v" ]] || claude_v="unknown"
    else
      claude_v="unknown"
    fi
  else
    claude_v="not installed"
  fi
  if command -v jq >/dev/null 2>&1; then
    jq -n --arg ts "$now" --arg slug "$slug" --arg codex "$codex_v" --arg claude "$claude_v" \
      '{stamped_at_utc:$ts, slug:$slug, cli_versions:{codex:$codex, claude:$claude}}' \
      > "$stamp_file" 2>/dev/null || return 0
  else
    # jq-free fallback (versions are simple ASCII from --version; escape quotes).
    codex_v="${codex_v//\"/\\\"}"; claude_v="${claude_v//\"/\\\"}"
    printf '{"stamped_at_utc":"%s","slug":"%s","cli_versions":{"codex":"%s","claude":"%s"}}\n' \
      "$now" "$slug" "$codex_v" "$claude_v" > "$stamp_file" 2>/dev/null || return 0
  fi
  echo "  CLI env stamp: codex=$codex_v claude=$claude_v → $stamp_file"
  return 0
}

echo "Initializing Ralph Desk: $SLUG"
echo "  Root: $ROOT"
echo "  Desk: $DESK"
[[ -n "$MODE" ]] && echo "  Mode: $MODE"
echo ""

mkdir -p "$DESK/prompts" "$DESK/context" "$DESK/memos" "$DESK/plans" "$DESK/logs/$SLUG"

# --- Re-execution lifecycle (--mode handling) ---
PRD_FILE="$DESK/plans/prd-$SLUG.md"
LOGS_DIR="$DESK/logs/$SLUG"

# No-PRD fallback: --mode provided but no PRD exists yet → treat as first-run.
# Print a note so the user knows the requested mode was ignored, reset MODE so
# the re-execution lifecycle below is skipped, and let the rest of the script
# scaffold a fresh PRD template alongside the other prompt/test-spec files.
if [[ -n "$MODE" ]] && [[ ! -f "$PRD_FILE" ]]; then
  echo "Note: --mode $MODE provided but no PRD found at $PRD_FILE — treating as first-run."
  MODE=""
fi

if [[ -n "$MODE" ]]; then
  echo "Re-execution mode: --mode $MODE"
  echo ""

  DELETED_COUNT=0
  ARCHIVED_COUNT=0

  # request-m ②: on a fresh/improve re-execution, EVIDENCE artifacts (per-iteration
  # iter-* snapshots, the runtime memos, and the verified ledger) are RELOCATED
  # into logs/<slug>/runs/superseded-<ts>/ instead of deleted — a later PRD-revision
  # `ledger-seed --evidence` must be able to recover a past pass verdict. Live paths
  # are still emptied ("fresh campaign starts clean"), but the bytes survive in runs/.
  local _arch_ts _arch_dir
  _arch_ts=$(date +%Y%m%d-%H%M%S)
  _arch_dir="$LOGS_DIR/runs/superseded-$_arch_ts"
  # request-m ② (collision-proof): a same-second prior archive (another leader/init
  # start in this wall-clock second) must NOT be overwritten — disambiguate
  # deterministically (-2, -3, …) instead of reusing/merging its dir.
  if [[ -d "$_arch_dir" && -n "$(ls -A "$_arch_dir" 2>/dev/null)" ]]; then
    local _an=2
    while [[ -e "$LOGS_DIR/runs/superseded-$_arch_ts-$_an" ]]; do (( _an++ )); done
    _arch_dir="$LOGS_DIR/runs/superseded-$_arch_ts-$_an"
  fi
  _arch_mv() {  # relocate one file into the archive dir (never deletes); dynamic scope reads $_arch_dir
    [[ -f "$1" ]] || return 1
    mkdir -p "$_arch_dir" 2>/dev/null || return 1
    mv -f "$1" "$_arch_dir/" 2>/dev/null
  }

  # Version debug.log and campaign-report.md (NOT self-verification-report — uses -NNN)
  version_file "$LOGS_DIR/debug.log"
  version_file "$LOGS_DIR/campaign-report.md"

  # Archive iter-* artifacts (per-iteration done-claims, verdicts, iter-signals,
  # prompt logs, results) — relocated, never deleted (request-m ②).
  for f in "$LOGS_DIR"/iter-*(N); do
    _arch_mv "$f" && (( ++ARCHIVED_COUNT ))
  done

  # US-022 R10 P2-J: quarantine cross-mission stale iter-signal.json before
  # the normal reset deletes it. Cleanup (.sisyphus/quarantine/) preserves the
  # foreign signal so the operator can recover it; only signals whose us_id is
  # absent from the current PRD are quarantined.
  local _r10_signal="$DESK/memos/$SLUG-iter-signal.json"
  local _r10_prd="$DESK/plans/prd-$SLUG.md"
  if [[ -f "$_r10_signal" ]]; then
    _quarantine_stale_signal "$_r10_signal" "$_r10_prd" "$DESK" 2>/dev/null || true
  fi

  # Archive the runtime memos + the verified ledger (request-m ②: relocate, don't
  # delete). The verified ledger is RUNTIME state (v0.22.3 early-review P1-2):
  # leaving it LIVE across a fresh re-execution would let the new campaign inherit
  # the old one's credit and derive confirmation mode without doing any work — so
  # the LIVE path must be emptied. But the ledger is the campaign's progress record
  # and each verdict is its receipt, so the bytes are preserved in runs/ rather
  # than destroyed. It is 0444 between appends; `mv` renames the inode (needs only
  # parent-dir write), so the lock does not block relocation.
  _arch_mv "$DESK/memos/$SLUG-verified.jsonl" && (( ++ARCHIVED_COUNT ))
  for f in \
    "$DESK/memos/$SLUG-done-claim.json" \
    "$DESK/memos/$SLUG-iter-signal.json" \
    "$DESK/memos/$SLUG-verify-verdict.json" \
    "$DESK/memos/$SLUG-complete.md" \
    "$DESK/memos/$SLUG-blocked.md" \
    "$DESK/memos/$SLUG-flywheel-signal.json" \
    "$DESK/memos/$SLUG-flywheel-review.md" \
    "$DESK/memos/$SLUG-flywheel-guard-verdict.json"; do
    _arch_mv "$f" && (( ++ARCHIVED_COUNT ))
  done

  # Delete status.json, baseline.log, cost-log.jsonl
  for f in "$LOGS_DIR/runtime/status.json" "$LOGS_DIR/status.json" "$LOGS_DIR/baseline.log" "$LOGS_DIR/cost-log.jsonl"; do
    [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
  done

  # Prompt templates always regenerate. The test-spec is a PLAN asset
  # (v0.22.3 US-002): fresh deletes it only when it is still the scaffold
  # template, or when --reset-plans explicitly asks for the wipe (with a
  # versioned backup first). improve preserves it in-place as before.
  for f in \
    "$DESK/prompts/$SLUG.worker.prompt.md" \
    "$DESK/prompts/$SLUG.verifier.prompt.md" \
    "$DESK/prompts/$SLUG.flywheel.prompt.md" \
    "$DESK/prompts/$SLUG.flywheel-guard.prompt.md"; do
    [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
  done
  # A-7-class fix (reaudit wave 1 follow-up): the scaffold branch used a bare
  # `rm` with no backup, same as the PRD branch (see above) — and the same
  # risk, since .rlp-desk/ is gitignored so a misclassification was permanent.
  # Route it through version_file for the same reason: a false "not authored"
  # verdict is recoverable, never destructive.
  local _ts_file="$DESK/plans/test-spec-$SLUG.md"
  if [[ "$MODE" == "fresh" && -f "$_ts_file" ]]; then
    if (( RESET_PLANS )); then
      version_file "$_ts_file"; (( ++DELETED_COUNT ))
      echo "  Reset:     test-spec-$SLUG.md (--reset-plans: backed up, regenerating)"
    elif _testspec_is_authored "$_ts_file"; then
      echo "  Preserved: test-spec-$SLUG.md (authored — use --reset-plans to wipe)"
    else
      version_file "$_ts_file"; (( ++DELETED_COUNT ))
      echo "  Reset:     test-spec-$SLUG.md (scaffold template — backed up, regenerating)"
    fi
  fi

  # Reset memory and context to fresh templates (rm here; scaffold below regenerates them)
  rm -f "$DESK/memos/$SLUG-memory.md" "$DESK/context/$SLUG-latest.md"

  # PRD handling (v0.22.3 US-002): --mode fresh preserves an AUTHORED PRD
  # (byte-exact diff against the live scaffold — see _prd_is_authored); only
  # scaffold templates are touched. --reset-plans restores the wipe with a
  # versioned backup first. --mode improve preserves the PRD in-place as before.
  # A-7 fix (reaudit wave 1): the scaffold branch used a bare `rm` with no
  # backup, and `.rlp-desk/` is gitignored — a misclassification meant
  # permanent, unrecoverable loss. Route it through version_file (same
  # backup-before-touch helper the --reset-plans branch already uses) so a
  # false "not authored" verdict is recoverable, never destructive.
  if [[ "$MODE" == "fresh" && -f "$PRD_FILE" ]]; then
    if (( RESET_PLANS )); then
      version_file "$PRD_FILE"; (( ++DELETED_COUNT ))
      echo "  Reset:     prd-$SLUG.md (--reset-plans: backed up, regenerating)"
    elif _prd_is_authored "$PRD_FILE"; then
      echo "  Preserved: prd-$SLUG.md (authored — use --reset-plans to wipe)"
    else
      version_file "$PRD_FILE"; (( ++DELETED_COUNT ))
      echo "  Reset:     prd-$SLUG.md (scaffold template — backed up, regenerating)"
    fi
  fi
  # Stale per-US splits never survive fresh: they are derived artifacts and
  # are regenerated below from whichever PRD/test-spec survives. A split from
  # a PREVIOUS PRD (e.g. a US id the new plan no longer has) must not leak
  # into the new campaign.
  if [[ "$MODE" == "fresh" ]]; then
    for f in "$DESK/plans/prd-$SLUG-US-"*.md(N) "$DESK/plans/test-spec-$SLUG-US-"*.md(N); do
      [[ -f "$f" ]] && { rm "$f"; (( ++DELETED_COUNT )); }
    done
  fi

  # Re-execution summary
  echo "  Re-execution summary:"
  if [[ "$MODE" == "improve" ]]; then
    echo "  Preserved: prd-$SLUG.md (--mode improve: PRD kept in-place)"
  fi
  echo "  Deleted:   $DELETED_COUNT runtime artifacts"
  (( ARCHIVED_COUNT > 0 )) && echo "  Archived:  $ARCHIVED_COUNT evidence artifact(s) → runs/${_arch_dir:t}/ (preserved, never deleted)"
  echo "  Reset:     memory.md + context.md (regenerating from templates)"
  echo ""
fi

# --- Worker Prompt ---
F="$DESK/prompts/$SLUG.worker.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
Execute the plan for $SLUG.

## Coding Principles (applies to ALL work in this iteration)

1. Think Before Coding
   Don't assume. Don't hide confusion. Surface tradeoffs.
   - State assumptions explicitly. If uncertain, signal blocked with your options
     listed — do not guess.
   - If multiple interpretations exist, present them in blocked signal — do not
     pick silently.
   - If a simpler approach exists, note it in your plan.
   - If something important is unclear, stop and name what is confusing.

2. Simplicity First
   Minimum code that solves the problem. Nothing speculative.
   - No features beyond what was asked.
   - No abstractions for single-use code.
   - No configurability that was not specified.
   - No defensive handling for implausible scenarios unless the context requires it.
   - If 200 lines could be 50, rewrite it.
   Ask: "Would a strong senior engineer call this overcomplicated?" If yes, simplify.

3. Surgical Changes
   Touch only what you must. Clean up only your own mess.
   - Do not improve adjacent code, comments, or formatting unless required by the task.
   - Do not refactor unrelated code.
   - Match the local style unless there is a compelling reason not to.
   - If unrelated dead code is noticed, mention it in done-claim — do not delete it.
   - Remove imports, variables, or functions that YOUR changes made unused.
   - Do not remove pre-existing dead code.
   Test: every changed line should trace directly to the contract.

4. Goal-Driven Execution
   Define success criteria. Loop until verified.
   These principles are enforced by the TDD Mandate and Planning step below.
   If success criteria for any AC are unclear, signal blocked.

## Planning (before writing any code)
After reading all files, BEFORE writing any test or code:
1. List the specific files you will create or modify
2. For each AC in the contract, state your approach in 1 sentence
3. Identify ordering constraints (which AC depends on which)
4. Record as first execution_step: {"step": "plan", "ac_id": "all", "command": null, "exit_code": null, "summary": "Plan: [files], [approach], [order]"}
Keep planning lightweight — 1-2 sentences per AC, not a detailed analysis.
If the plan reveals the contract is unclear or infeasible, signal "blocked" immediately.

## Before you start
Read these files in order:
1. Campaign Memory: $DESK/memos/$SLUG-memory.md → Next Iteration Contract is your mission
2. PRD: $DESK/plans/prd-$SLUG.md → acceptance criteria
3. Test Spec: $DESK/plans/test-spec-$SLUG.md → verification methods
4. Latest Context: $DESK/context/$SLUG-latest.md → current state

## TDD MANDATE (hard constraint — violation = automatic FAIL)
> Write failing tests FIRST → confirm RED (exit_code=1) → implement minimum code → confirm GREEN.
> Every NEW AC requires: write_test → verify_red → implement → verify_green in execution_steps.
> No exceptions. Verifier rejects missing RED evidence. For already-passing ACs, use verify_existing.

## SCOPE LOCK (hard constraint — violation causes verification failure)
- You MUST only implement the work described in the "Next Iteration Contract" from campaign memory.
- If the contract says "implement US-001 only", do ONLY that. Do NOT touch other stories.
- If the contract says "implement all remaining stories", you may do all of them.
- Do NOT go beyond the contracted scope, even if you can see more work in the PRD.
- No file creation or modification outside the project root.
- Do not modify this prompt file or any PRD/test-spec files.
- **Lane discipline (governance §7e)**: PRD, test-spec, and campaign memory
  are leader/owner artifacts. Worker MUST NOT edit them directly. Drift on
  these files triggers a \`lane_violation_warning\` event in default mode, or
  a sentinel BLOCKED with \`infra_failure\` + \`recoverable=true\` in \`--lane-strict\` mode.

## Forbidden Shortcuts (Verifier will check these)
- Do not mock external services when L2 integration test is required by test-spec.
- Do not delete or weaken existing assertions to make tests pass.
- Do not skip boundary cases listed in the PRD.
- Do not write code before tests — if you did, delete it and start with tests.
- **NEVER modify rlp-desk infrastructure files** (~/.claude/ralph-desk/*, ~/.claude/commands/rlp-desk.md). If you discover a bug in rlp-desk itself, report it in done-claim.json with {"status": "blocked", "reason": "rlp-desk bug: <description>"} and signal blocked. Do NOT attempt to fix rlp-desk — it is the orchestration tool, not your project code.
- **NEVER modify Claude Code settings** (~/.claude/settings.json, .claude/settings.local.json, or any settings files). Do NOT add permissions, change models, or alter configuration. If a permission prompt blocks you, report it as blocked — do NOT try to edit settings to bypass it.

## When Stuck (do NOT guess-and-fix)
> 1. STOP and READ the error. Trace the call stack. Identify the root cause before touching code.
> 2. Write a minimal test that reproduces the failure, then fix the root cause only.
> 3. If 3+ fixes fail on the same issue, signal "blocked" with your diagnosis.

## Iteration rules
- Use fresh context only; do NOT depend on prior chat history.
- Execute exactly the work specified in the Next Iteration Contract.
- Refresh context file with the current frontier.
- Rewrite campaign memory in full.
- When rewriting campaign memory, PRESERVE the Key Decisions and Patterns Discovered sections from prior iterations — append new entries, do not erase existing ones.
- Write evidence artifacts.
- **After writing tests, update test-spec Criteria Mapping with actual test file paths and function names** (replace placeholder -k filters).
- Ensure **each AC has >= 3 tests** (happy + negative + boundary). Do not just meet the total count — distribute evenly per AC.
- **Commit all changes when the iteration produced changes** (include iteration number and story ID in commit message). On a verification/confirmation pass (verify_existing — you confirmed existing behavior and changed no files), do **NOT** commit: an empty commit (git commit --allow-empty, or any commit whose tree equals its parent's) records no work and is an IL-1 evidence breach. Claim a commit step in done-claim.json ONLY when a real commit landed, and record its SHA as commit_sha.

MANDATORY: When done with this iteration, write the following signal file:
- Path: $DESK/memos/$SLUG-iter-signal.json
- Format: {"iteration": N, "status": "continue|verify|verify_partial|blocked", "us_id": "US-NNN or null", "summary": "what was done", "timestamp": "ISO"}
- Status values:
  - "continue" = current action done but more work remains (no verify needed yet)
  - "verify" = current US complete + done-claim written → Verifier checks this US
  - "verify_partial" = subset of ACs verified in this iteration. Required fields: "verified_acs": ["AC1","AC2"], "deferred_acs": ["AC3"], "defer_reason": "<why deferred>". Verifier evaluates only verified_acs; deferred_acs queue for next iter.
  - "blocked" = autonomous blocker

## Signal rules (per-US verification)
- After completing EACH user story → signal "verify" with "us_id" set to the story you just finished (e.g., "US-001").
- The Verifier will check ONLY that story's acceptance criteria.
- After ALL stories individually pass verification → signal "verify" with "us_id": "ALL" for a final full verify of all AC.
- Do NOT signal "continue" when a US is done — always signal "verify" per US.
- Signal "continue" ONLY when you have more work to do within the same US (e.g., a multi-step task).

## Step N+1 (MANDATORY — US-017 R5 P0-D)
After done-claim.json, you MUST also write iter-signal.json with SPECIFIC summary including verified ACs and key evidence paths (e.g., "US-001: AC1+AC2 verified via tests/test_us001_ac1.py:test_happy_path; AC3 implementation in src/foo.py:42").
The auto-generated A4 fallback summary ("auto-generated by A4 fallback (done-claim without signal)") is a debugging context loss and triggers verifier-side WARN with meta.iter_signal_quality='auto_generated'. Per-mission A4 fallback ratio < 10% is required (governance §1f).

## Blocked exit hygiene (MANDATORY — US-020 R8 P1-H)
On blocked exit (status=blocked), BEFORE writing iter-signal.json you MUST:
1. Append to memory.md § Blocking History an entry: \`{iter, us, reason, suggested_repair}\`. The next iteration must be able to read why the previous one blocked without re-running the worker.
2. Update latest.md § Known Issues with the same context so the Frontier section reflects the blocker.
The runner verifies memory.md and latest.md mtimes against the sentinel write time. If either file is older than 5 minutes when the sentinel is written, the JSON sidecar's \`meta.blocked_hygiene_violated=true\` flag is set automatically and an analytics event is emitted (governance §1f, 5th channel).

## Done Claim Format
When writing done-claim JSON, ALWAYS include execution_steps — what you did, in what order, with evidence:
\`\`\`json
{
  "us_id": "US-NNN",
  "claims": ["AC1: ...", "AC2: ..."],
  "execution_steps": [
    {"step": "write_test", "ac_id": "AC1", "command": null, "summary": "wrote tests/test_add.py with 3 tests"},
    {"step": "verify_red", "ac_id": "AC1", "command": "pytest tests/...", "exit_code": 1, "ts": "2026-01-01T00:00:00Z", "summary": "RED: test fails as expected"},
    {"step": "implement", "ac_id": "AC1", "command": null, "summary": "created add() function"},
    {"step": "verify_green", "ac_id": "AC1", "command": "pytest tests/...", "exit_code": 0, "ts": "2026-01-01T00:00:00Z", "summary": "GREEN: 3 passed"},
    {"step": "verify_e2e", "ac_id": "AC1", "command": "python -c '...'", "exit_code": 0, "ts": "2026-01-01T00:00:01Z", "summary": "E2E output matches expected"},
    {"step": "commit", "ac_id": "AC1", "command": "git commit ...", "exit_code": 0, "summary": "committed abc1234"}
  ]
}
\`\`\`
This is NOT optional. Every done-claim must include the steps you took and the evidence for each.
execution_steps MUST be a JSON array of objects (not a dict with string keys). Each object MUST have: "step", "ac_id", "command", "exit_code", "summary". Every verification step (verify_red/verify_green/verify_e2e/verify_existing/verify) MUST also carry "ts" — the ISO-8601 UTC time the command was run (forensic evidence-age record; in confirmation mode freshness is judged on the VERIFIER's own reruns, not on these timestamps).

### Build-work evidence format (machine-linted — governance §3a Layer 1.5)
For BUILD work (any claim that includes a \`write_test\` step), EACH acceptance criterion you touched MUST have its own labeled \`write_test → verify_red → implement → verify_green\` steps, IN THAT ORDER, in execution_steps:
- Label each step's \`ac_id\` with the AC it belongs to. A comma list is fine when one step genuinely covers several ACs ("AC1,AC2").
- The bundle label \`ac_id: "all"\` does NOT count toward any AC's four phases — if AC3's implement step is only labeled \`all\`, AC3 is treated as MISSING its implement step.
- The leader machine-lints this the instant you submit the done-claim, BEFORE the verifier runs. A malformed claim is bounced straight back to you with per-AC coordinates: \`idx=[write_test, verify_red, implement, verify_green]\` where \`-1\` = that phase's step is missing for the AC and a non-monotonic list = steps recorded out of order. Fix ONLY the execution_steps format it names (add the missing per-AC labeled steps / correct the order) and resubmit — do NOT re-implement the deliverable.
- Confirmation/replay claims (no \`write_test\` step — e.g. \`verify_existing\`) are exempt from this lint.

## Stop behavior
- Single US achieved → write done-claim JSON to $DESK/memos/$SLUG-done-claim.json with the specific US, signal verify, exit
- All US achieved → write done-claim JSON with all US, signal verify with us_id "ALL", exit
- Autonomous blocker → write to $DESK/memos/$SLUG-blocked.md, exit
- Otherwise → set stop=continue, define next iteration contract in memory, exit

## Objective
$OBJECTIVE
EOF

  # Inject operational context if server options provided
  if [[ -n "$SERVER_CMD" || -n "$SERVER_PORT" ]]; then
    cat >> "$F" <<OPCTX

## Operational Context
$([ -n "$SERVER_CMD" ] && echo "- **Server Start Command**: \`$SERVER_CMD\`")
$([ -n "$SERVER_PORT" ] && echo "- **Server Port**: $SERVER_PORT")
$([ -n "$SERVER_HEALTH" ] && echo "- **Health Check URL**: $SERVER_HEALTH")

### Operational Rules (always apply when server context is present)
- After modifying server/application code, restart the server$([ -n "$SERVER_CMD" ] && echo ": \`$SERVER_CMD\`")
- Before signaling done, verify the server responds$([ -n "$SERVER_HEALTH" ] && echo ": \`curl -sf $SERVER_HEALTH\`" || [ -n "$SERVER_PORT" ] && echo ": \`curl -sf http://localhost:$SERVER_PORT/\`")
- Do NOT modify dependency files (package.json, requirements.txt, etc.) unless the AC explicitly requires it
- Do NOT run package install commands (npm install, pip install, etc.) unless the AC explicitly requires it
OPCTX
  fi

  echo "  + $F"
else echo "  · $F"; fi

# --- Verifier Prompt ---
F="$DESK/prompts/$SLUG.verifier.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
Independent verifier for Ralph Desk: $SLUG

## Verification Principles

1. Think Before Judging
   Don't assume. Don't default to PASS or FAIL without evidence.
   - State your assumptions about what PASS looks like for each AC before
     checking evidence.
   - If evidence is ambiguous or incomplete, say what is unclear and why —
     do not default to either verdict.
   - If multiple interpretations of an AC exist, flag it as a spec issue.

2. Goal-Driven Verification
   Define the specific evidence required for PASS before you start checking.
   - For each AC, state: "PASS requires [specific evidence]."
   - Verify against that criteria, not against a general impression of code quality.
   - If success criteria are unclear, note it in reasoning — do not invent criteria.

## Iron Law (ABSOLUTE — no exceptions)
> NO COMPLETION CLAIMS WITHOUT FRESH VERIFICATION EVIDENCE
> "should pass", "probably works", "seems to" = automatic FAIL

## Evidence Gate (MANDATORY before any verdict)
1. IDENTIFY: What command proves this claim?
2. RUN: Execute the FULL command (fresh, complete)
3. READ: Full output, check exit code, count failures
4. VERIFY: Does output confirm the claim?
5. ONLY THEN: Issue verdict

Required reads:
- PRD: $DESK/plans/prd-$SLUG.md
- Test Spec: $DESK/plans/test-spec-$SLUG.md
- Campaign Memory: $DESK/memos/$SLUG-memory.md (orientation only — not source of truth)
- Latest Context: $DESK/context/$SLUG-latest.md
- Done Claim: $DESK/memos/$SLUG-done-claim.json
- Iteration Signal: $DESK/memos/$SLUG-iter-signal.json (check us_id field)

## Verification Scope
Check the iter-signal.json "us_id" field:
- If us_id is a specific story (e.g., "US-001"): verify ONLY that story's acceptance criteria from the PRD.
- If us_id is "ALL": verify ALL acceptance criteria from the PRD (final full verify).
- If us_id is absent or null: verify all criteria in the done-claim (legacy/batch mode).

## Verification Process
1. Read PRD acceptance criteria (scoped to us_id if present)
2. Read done claim
3. Identify scope: run \`git diff --name-only\` to find changed files, then read those files + related imports only
4. **Scope Lock check**: (a) Read the Next Iteration Contract from campaign memory to identify the contracted US. (b) Run \`git diff --name-only\` to list all changed files. (c) For each changed file, verify it is plausibly related to the contracted US's acceptance criteria. (d) Flag files that appear unrelated. (e) Shared infrastructure (types, configs, common utilities) and dependency files are permitted if the AC implies them.
5. **Layer Enforcement (IL-3)**: confirm each REQUIRED layer is actually verified by a concrete PASSING check (a per-AC command in the Criteria-to-Verification table counts as L1/L3 coverage). Explicit "## L1/L2/L3" section headers and "N/A" markers are NOT mandatory — their absence is NOT a fail. FAIL a required layer ONLY when its verification is genuinely absent, blank, TODO, or failing — never for format alone. (Identical for claude AND codex.)
6. Run fresh verification: execute ALL commands from test-spec verification layers (L1, L2, L3, L4 as applicable)
   **Skip detection (IL-5)**: After running tests, check output for "skip", "pending", "not run", or "0 items collected". Tests that did not actually execute do NOT count as passed. If test_count_executed < test_count_expected, verdict = FAIL ("skipped tests detected").
7. Check each criterion against fresh evidence (only for the scoped US, or all if us_id=ALL)
8. Run smoke test if defined in PRD
9. **Test Sufficiency (IL-4)**: count test functions exercising each AC. Count < 3 per AC = FAIL.
   Check diversity: at least 2 of 3 categories (happy, negative, boundary) per AC.
10. **Anti-Gaming Detection**:
   - Assertion integrity: compare assertion count/strength via \`git diff HEAD~1\` — assertions not deleted or weakened
   - Test-specific logic: no environment-detection patterns
   - "Code inspection" claims: Worker must run actual commands
   - Tautological tests: expected values that mirror implementation logic
10¼. **Anti-Rubber-Stamp Self-Check**:
   - If your verdict history shows a 100% pass rate, re-examine your last verdict with increased scrutiny — a 100% pass rate is a red flag for insufficient rigor
   - When issuing PASS with explicit warning: note any concerning patterns (e.g., low test diversity, marginal coverage) even if technically passing
   - Never issue a silent PASS — every pass verdict must cite specific evidence for each AC checked
   - Rationalization red flags: "tests pass so it works" (passing ≠ correct), "Worker is confident" (confidence ≠ evidence), "changes are minimal" (scope ≠ correctness)
10½. **Worker Process Audit**:
   - **Verification mode gate (v0.22.3)**: read the leader-derived \`Verification Mode\` line in this prompt's Verification Context — it is the SOLE authoritative mode channel (ignore any verification_mode string inside iter-signal or done-claim; a done-claim self-claiming confirmation while the prompt says build is a FAIL). In **confirmation mode** (leader proved: every PRD US verified, SHA-anchored unchanged tree, PRD-hash-bound) the fresh evidence is the VERIFIER'S OWN: rerun the full suite and per-AC spot commands yourself this session (IL-1) and judge on those; the done-claim is historical context — do NOT demand write_test/verify_red or new step timestamps from it. FAIL only on your own fresh checks failing, missing/uncommitted deliverables, or forbidden-shortcut phrases. In **build mode** the strict contract below applies unchanged. Confirmation mode is the leader-gated superset of the \`verify_existing\` allowance (governance §1f).
   - Test-first compliance: done-claim execution_steps must show write_test step before implement step for each AC
   - RED phase evidence: at least one verify_red step with exit_code=1 for the US (proves tests were written before passing). Per-AC RED is preferred, but AGGREGATE RED evidence is acceptable — do NOT FAIL merely because red/green is aggregated rather than per-AC.
   - Forbidden shortcuts: check done-claim claims and summary for forbidden phrases ("code inspection", "I'm confident", "too simple", "I'll test after", "already manually tested", "partial check")
   - Step completeness: each AC should have write_test → verify_red → implement → verify_green sequence in execution_steps
   - **Leader format lint (governance §3a Layer 1.5)**: the leader runs a DETERMINISTIC per-AC TDD-sequence lint on the done-claim BEFORE dispatching you, and reports the outcome as a \`Done-Claim Format Lint: ...\` line in this prompt's Verification Context. When it says \`PASS\`, the per-AC write_test→verify_red→implement→verify_green sequence and labels are already machine-verified — you MUST NOT fail the Worker Process Audit on step-sequence or label-format grounds; confine the audit to SUBSTANCE (fresh evidence plausibility, exit codes, timestamps, command truthfulness). A malformed sequence would have been bounced back to the Worker before reaching you, so a claim in your hands has either passed the lint, been skipped (confirmation/replay, opt-out, or no jq), or hit the fail cap (the line then carries the violations for your awareness — still audit substance, not re-derive the format verdict).
   - Planning Step presence: done-claim execution_steps should include a \`plan\` step as the first entry. If missing, record in reasoning as {"check": "Planning Step", "decision": "info", "basis": "plan step present/absent"} — informational only (does not affect pass/fail verdict)
10¾. **FORMAT is not a PASS-blocker, but SUBSTANCE always is (F-17→F-18, identical for claude AND codex)**: when the acceptance criteria are met and their FRESH checks are green (per the Evidence Gate), record pure-FORMAT observations — missing layer-section headers, a missing N/A marker, RED evidence aggregated rather than per-AC — as warnings in reasoning, NOT as a FAIL. The iter-signal.json only identifies WHICH US to verify; its author (Worker vs leader-synthesized) does not change the verdict. But deliverable COMPLETENESS is NOT a format concern — if an AC's work is absent, uncommitted/untracked, or never actually exercised, that is a FAIL. The real correctness gates (Evidence Gate, Test Sufficiency IL-4, Skip detection IL-5, Anti-Gaming) stay strict regardless.
11. **Reproducibility check**: verify lock file committed, clean install succeeds, security scan passes, env vars documented (per test-spec Reproducibility Gate). Skip if test-spec says "N/A."
12. Write verdict JSON to: $DESK/memos/$SLUG-verify-verdict.json
    **CRITICAL: You MUST write the verdict as a FILE (not stdout/echo/cat). The Leader polls this file path — terminal output is lost. Evidence strings: include key metrics and exit codes only, do NOT quote full command output or logs verbatim.**

Verdict JSON:
{
  "verdict": "pass|fail|request_info",
  "us_id": "US-NNN or ALL (matches the scope you verified)",
  "verified_at_utc": "ISO timestamp",
  "summary": "...",
  "failure_category": "spec|implementation|integration|flaky|environment (fail verdicts only — omit or null on pass)",
  "per_us_results": {"US-001": "pass|fail|not_started", "US-002": "pass|fail|not_started"},
  "criteria_results": [{"criterion":"...","met":true/false,"evidence":"..."}],
  "missing_evidence": [],
  "issues": [{"id":"...","severity":"critical|major|minor","description":"...","fix_hint":"(suggestion, non-authoritative)"}],
  "reasoning": [
    {"check": "IL-1 Evidence Gate", "decision": "pass|fail", "basis": "what command was run, what output confirmed the decision"},
    {"check": "Layer Enforcement", "decision": "pass|fail", "basis": "which layers checked, any TODO found"},
    {"check": "Test Sufficiency", "decision": "pass|fail", "basis": "test count per AC, category coverage"},
    {"check": "Anti-Gaming", "decision": "pass|fail", "basis": "what was checked, any suspicious patterns"},
    {"check": "Worker Process Audit", "decision": "pass|fail", "basis": "build mode: test-first followed, verify_red present, steps complete / confirmation mode (leader prompt line): fresh timestamped GREEN evidence, no verify_red required; no forbidden shortcuts either way"}
  ],
  "layer_status": {"L1":"pass|fail|todo|na","L2":"pass|fail|todo|na","L3":"pass|fail|todo|na","L4":"pass|fail|todo|na"},
  "test_quality": {"test_count":0,"ac_count":0,"sufficiency":"pass|fail","anti_patterns_found":[]},
  "recommended_state_transition": "complete|continue|blocked",
  "next_iteration_contract": "...",
  "evidence_paths": []
}

Rules:
- Do NOT trust the worker's claim. Verify with fresh evidence.
- If uncertain, verdict = request_info (describe your specific question in summary so Leader can decide).
- **On a fail verdict, set \`failure_category\` to the DOMINANT root cause** — the one that explains the failure, not every contributing factor. \`spec\` = AC ambiguous/contradictory/untestable; \`implementation\` = code logic error, missing case, wrong algorithm; \`integration\` = pieces work individually but their interaction fails; \`flaky\` = non-deterministic or timing-dependent; \`environment\` = harness/tooling/capacity failure or a verifier safety-classifier refusal, i.e. NEVER a code defect. The Leader routes on this field: \`environment\` and \`flaky\` retry the SAME model (it recovers the environment instead), every other category may escalate it.
- Campaign Memory is for orientation only — do NOT use it as source of truth for AC verification.
- Deterministic checks (type hints, linting, security) delegate to test-spec tools; focus on AC verification + semantic review + smoke test.
- Do NOT modify code or write sentinel files.
- If Worker claims "inspection" or "review" for an AC that requires an automated command, verdict = FAIL.
- **US-017 R5 P0-D**: Inspect iter-signal.json's "summary" field. If it matches the auto-generated A4 fallback pattern (e.g., contains "auto-generated by A4 fallback" or "auto-generated after codex exit"), set meta.iter_signal_quality='auto_generated' in the verdict to flag the debugging context loss. Otherwise meta.iter_signal_quality='specific'.
- **US-019 R7 P1-G**: If signal status=verify_partial, evaluate ONLY verified_acs. Treat deferred_acs as out-of-scope (not fail). If verified_acs is empty/missing, the signal is malformed — do not pass; the runner will downgrade to blocked with reason='verify_partial_malformed'.
- **ALWAYS include per_us_results** in verdict JSON — map each US to "pass", "fail", or "not_started". This is required for partial progress tracking in both batch and per-us modes.
EOF

  # Inject operational verification if server options provided
  if [[ -n "$SERVER_CMD" || -n "$SERVER_PORT" ]]; then
    cat >> "$F" <<OPVER

## Operational Verification (server context present)
- Before verifying ACs, check that the server is running$([ -n "$SERVER_PORT" ] && echo " on port $SERVER_PORT")$([ -n "$SERVER_HEALTH" ] && echo ": \`curl -sf $SERVER_HEALTH\`")
- If the server is not running, verdict = FAIL with issue: "server not running on expected port"
- If Worker modified server code but did not restart the server, verdict = FAIL with issue: "server not restarted after code change"
OPVER
  fi

  echo "  + $F"
else echo "  · $F"; fi

# --- Flywheel Prompt ---
F="$DESK/prompts/$SLUG.flywheel.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<'FLYWHEEL_EOF'
# Flywheel Direction Review

You are an independent direction reviewer with fresh context. After a Worker iteration failed verification, you decide whether the current approach should continue, pivot, or change scope.

## Context Files
Read these in order:
1. Campaign Memory: {DESK}/memos/{SLUG}-memory.md — especially Next Iteration Contract, Key Decisions, Rejected Directions
2. PRD: {DESK}/plans/prd-{SLUG}.md — acceptance criteria
3. Done Claim: {DESK}/memos/{SLUG}-done-claim.json — what Worker actually did
4. Verify Verdict: {DESK}/memos/{SLUG}-verify-verdict.json — why Verifier failed it
5. Latest Context: {DESK}/context/{SLUG}-latest.md — current state

## CEO Cognitive Patterns (apply throughout your review)
1. First-principles — ignore convention, start from the problem itself
2. 10x check — can 2x effort yield 10x better result?
3. Inversion — what must be true for this approach to fail?
4. Simplicity bias — prefer simple over complex solutions
5. User-back — reason backwards from end-user experience
6. Time-value — does this direction change save 3+ iterations?
7. Sunk cost immunity — ignore what was already invested
8. Blast radius — assess impact scope of direction change
9. Reversibility — prefer easily reversible decisions
10. Evidence > opinion — judge only by this iteration's actual results
11. Proxy skepticism — is the optimization metric the right proxy for the real goal?
12. Classification — hard-to-reverse + large-magnitude changes need stronger evidence

## Review Process

### Step 0A: Premise Challenge
List every assumption the current approach depends on.
For each assumption, state whether THIS iteration's evidence supports or contradicts it.
- Supported: "Assumption X — SUPPORTED: [evidence from done-claim/verdict]"
- Contradicted: "Assumption X — BROKEN: [evidence]. This means [implication]."
If any premise is broken, PIVOT or REDUCE is likely the right call.

### Step 0B: Existing Code Leverage
- Did the Worker miss reusable code that already exists in the project?
- Would a different approach align better with existing patterns?
- Check: are there utilities, helpers, or patterns the Worker could have used?

### Step 0C: Ideal State Mapping
Describe what this US looks like when perfectly implemented (2-3 sentences).
How far is the current approach from this ideal? What is the gap?

### Step 0D: Implementation Alternatives (MANDATORY)
Propose at least 2 alternative approaches. For each:
- Summary (1-2 sentences)
- Effort: S (< 1 iteration) / M (1-2 iterations) / L (3+ iterations)
- Risk: low / medium / high
- Key tradeoff vs current approach

Do NOT skip this step. Even if the current approach seems correct, articulate alternatives.

### Step 0E: Scope Decision
Choose ONE. Justify with evidence from this iteration only:
- **HOLD**: Premises valid, current approach correct. Refine the contract with specific fixes: "[fix 1], [fix 2]"
- **PIVOT**: Premise [X] broken. Switch to Alternative [A]. Reason: [evidence]
- **REDUCE**: AC [N] too complex at current scope. Split into [parts] or simplify to [simpler version]
- **EXPAND**: Missing prerequisite [Y] discovered. Add to contract: [what to add]

### Step 0F: Contract Rewrite
Based on your decision, update campaign memory:
1. Rewrite "Next Iteration Contract" with the new direction
2. Append your decision and reasoning to "Key Decisions"
3. If rejecting an approach, append to "Rejected Directions" section:
   "DO NOT retry: [approach description]. Reason: [why it failed]. Evidence: [from iteration N]."
   The next Worker MUST read Rejected Directions before starting.

## Output Files

1. Write analysis to: {DESK}/memos/{SLUG}-flywheel-review.md
2. Update campaign memory: {DESK}/memos/{SLUG}-memory.md
3. Write signal: {DESK}/memos/{SLUG}-flywheel-signal.json
   Format: {"iteration": N, "decision": "hold|pivot|reduce|expand", "summary": "one line", "rejected_directions": ["approach X because Y"], "contract_updated": true, "next_mission_candidate": null, "timestamp": "ISO"}

   Optional field — `next_mission_candidate` (string | null):
   - null: no specific next mission suggested (default).
   - "<slug>": suggest a slug the consumer wrapper should chain next, given the
     current direction. The wrapper polls this field for autonomous
     multi-mission orchestration (rlp-desk does not auto-launch missions —
     the consumer wrapper owns that policy). Field is OPTIONAL; absence is
     treated as null. See docs/rlp-desk/multi-mission-orchestration.md for the
     consumer-side polling pattern.
FLYWHEEL_EOF

  # Replace placeholders with actual paths
  _render_prompt_placeholders "$F"

  echo "  + $F"
else echo "  · $F"; fi

# --- Flywheel Guard Prompt ---
F="$DESK/prompts/$SLUG.flywheel-guard.prompt.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<'GUARD_EOF'
# Flywheel Guard Review

You are an independent reviewer verifying whether a flywheel direction decision is safe to execute.
You have NO prior context about this campaign. Read the files below and evaluate the decision objectively.

## Files to Read (in order)
1. PRD: {DESK}/plans/prd-{SLUG}.md — the ground truth for what success means
2. Flywheel Decision: {DESK}/memos/{SLUG}-flywheel-signal.json — what the flywheel decided
3. Flywheel Analysis: {DESK}/memos/{SLUG}-flywheel-review.md — the flywheel's reasoning
4. Campaign Memory: {DESK}/memos/{SLUG}-memory.md — history, rejected directions, key decisions
5. Done Claim: {DESK}/memos/{SLUG}-done-claim.json — what the Worker actually produced
6. Verify Verdict: {DESK}/memos/{SLUG}-verify-verdict.json — why the Verifier failed it

## Validation Checks

### Check 1: Look-ahead Bias
List every data feature the flywheel's proposed direction depends on.
For each: "feature X — available at decision time: YES/NO/UNCLEAR"
- YES: feature is known before the event (entry time, session start price, order book state)
- NO: feature requires future information (peak price, session end, outcome)
- UNCLEAR: cannot determine from available context → mark inconclusive
If ANY feature is NO and used in a deployable strategy (not just upper-bound analysis): FAIL.

### Check 2: Metric Alignment
1. What metric does the PRD define as the optimization target?
2. What metric does the flywheel's direction optimize?
3. Are they the same?
   - Same metric → pass
   - Different metric, not flagged → FAIL (silent metric switch)
   - Different metric, flagged with evidence → FAIL with recommendation: "metric mismatch requires PRD update or user approval before proceeding"
   PRD is ground truth. The guard cannot approve off-PRD metric changes autonomously.

### Check 3: Deployability
Can the proposed direction's output be used in production as-is?
- Requires post-hoc data → FAIL
- Requires infrastructure not mentioned in PRD → FAIL
- Labeled as "upper-bound only" or "reference" → pass, but you MUST include "analysis_only": true in your verdict so Leader skips Worker dispatch (no implementation, analysis record only)

### Check 4: Repeat Pattern (same-US scoped)
Compare to prior flywheel decisions for the current US only in campaign memory's Key Decisions section.
- Same scope decision + same underlying approach as a prior flywheel for this US → FAIL
- Reframing of a previously rejected direction (check Rejected Directions) → FAIL
- Genuinely new approach → pass
Before writing your verdict, you MUST append any rejected flywheel direction to campaign memory's Rejected Directions section. This persists the record before cleanup can erase it.

## Output
Write verdict to: {DESK}/memos/{SLUG}-flywheel-guard-verdict.json

Use this format:
{
  "verdict": "pass|fail|inconclusive",
  "issues": [{"check": "check-name", "status": "pass|fail|inconclusive", "detail": "finding", "evidence": "reference"}],
  "analysis_only": false,
  "recommendation": "proceed|retry-flywheel|escalate-to-user",
  "timestamp": "ISO"
}

Rules:
- If ALL checks pass → verdict: pass, recommendation: proceed
- If ANY check is fail → verdict: fail, recommendation: retry-flywheel
- If ANY check is inconclusive and none are fail → verdict: inconclusive, recommendation: escalate-to-user
- Include specific evidence for every check. No "seems fine" or "probably ok."
GUARD_EOF

  # Replace placeholders with actual paths
  _render_prompt_placeholders "$F"

  echo "  + $F"
else echo "  · $F"; fi

# --- Context ---
F="$DESK/context/$SLUG-latest.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# $SLUG - Latest Context

## Current Frontier
### Completed
### In Progress
### Next
- (TBD by first worker)

## Key Decisions
## Known Issues
## Files Changed This Iteration
## Verification Status
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- Campaign Memory ---
F="$DESK/memos/$SLUG-memory.md"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
# $SLUG - Campaign Memory

## Stop Status
continue

## Objective
$OBJECTIVE

## Current State
Iteration 0 - not started

## Completed Stories

## Next Iteration Contract
Start from the beginning: read PRD and plan the first bounded action.

**Criteria**:
- (to be defined by first worker after reading PRD)

## Key Decisions
(seeded from brainstorm — do not erase, only append)

## Patterns Discovered
(seeded from brainstorm codebase exploration — do not erase, only append)
## Learnings
## Evidence Chain
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- PRD ---
F="$DESK/plans/prd-$SLUG.md"
if [[ ! -f "$F" ]]; then
  # A-7 fix (reaudit wave 1): generate via the same _emit_prd_template
  # function _prd_is_authored diffs against, so the writer and the
  # authored-detector can never drift out of byte-for-byte sync.
  _emit_prd_template "$SLUG" "$OBJECTIVE" > "$F"
  echo "  + $F"
else echo "  · $F"; fi

# Split PRD into per-US files (no-op with warning if no US markers)
if ! split_prd_by_us "$DESK/plans/prd-$SLUG.md" "$SLUG"; then
  # reaudit wave 1 (SV-gate finding, point c): this call sits between the
  # PRD write above and the Test Spec write further below. A fresh-mode run
  # may already have version_file'd the old test-spec away by this point,
  # so a hard failure here would otherwise leave test-spec-$SLUG.md missing
  # entirely (versioned backup exists, but nothing live) on top of the PRD
  # failure that already needs the operator's attention. Restore it before
  # exiting so init never leaves the campaign directory in that half-reset
  # state.
  if [[ ! -f "$DESK/plans/test-spec-$SLUG.md" ]]; then
    _emit_testspec_template "$SLUG" > "$DESK/plans/test-spec-$SLUG.md"
    echo "  Restored: test-spec-$SLUG.md (split failure left it missing — regenerated)" >&2
  fi
  exit 1
fi

# request-d ①-b: init-time gate-receipt drift check. Mirror of lib_ralph_desk.zsh
# compute_prd_content_hash / src/node/util/gate-receipt.mjs computePrdContentHash
# — KEEP THE THREE IN SYNC. vision-adopt §1a: the sealed set is main PRD first,
# then per-US PRD files C-sorted, then main test-spec, then per-US test-spec files
# C-sorted; each line "<basename>:<sha256(file)>\n", digest = sha256 of the
# concatenation. Only warns when a receipt already EXISTS but the contract now
# differs (e.g. --mode improve edited a sealed PRD/test-spec). Silent when no
# receipt exists yet — the receipt is written AFTER init by `gate-receipt <slug>`.
_gr_receipt="$DESK/plans/gate-receipt-$SLUG.json"
if [[ -f "$_gr_receipt" ]] && command -v jq >/dev/null 2>&1; then
  _gr_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; else sha256sum "$1" 2>/dev/null | awk '{print $1}'; fi; }
  _gr_main="$DESK/plans/prd-$SLUG.md"
  if [[ -f "$_gr_main" ]]; then
    _gr_manifest="prd-$SLUG.md:$(_gr_sha "$_gr_main")
"
    for _gr_b in ${(f)"$(cd "$DESK/plans" 2>/dev/null && ls -1 2>/dev/null | grep -E "^prd-${SLUG}-US-.*\.md$" | LC_ALL=C sort)"}; do
      [[ -n "$_gr_b" ]] && _gr_manifest+="${_gr_b}:$(_gr_sha "$DESK/plans/$_gr_b")
"
    done
    # vision-adopt §1a backward-compat: only fold the test-spec into the hash when
    # the receipt was sealed as schema 1.1+ (has a file_hashes map). A legacy
    # (1.0) receipt is PRD-only, so including the test-spec would false-mismatch a
    # zero-edit campaign. Re-sealing upgrades it to 1.1 naturally.
    if jq -e '(.file_hashes | type) == "object"' "$_gr_receipt" >/dev/null 2>&1; then
      [[ -f "$DESK/plans/test-spec-$SLUG.md" ]] && _gr_manifest+="test-spec-$SLUG.md:$(_gr_sha "$DESK/plans/test-spec-$SLUG.md")
"
      for _gr_b in ${(f)"$(cd "$DESK/plans" 2>/dev/null && ls -1 2>/dev/null | grep -E "^test-spec-${SLUG}-US-.*\.md$" | LC_ALL=C sort)"}; do
        [[ -n "$_gr_b" ]] && _gr_manifest+="${_gr_b}:$(_gr_sha "$DESK/plans/$_gr_b")
"
      done
    fi
    if command -v shasum >/dev/null 2>&1; then
      _gr_live=$(printf '%s' "$_gr_manifest" | shasum -a 256 2>/dev/null | awk '{print $1}')
    else
      _gr_live=$(printf '%s' "$_gr_manifest" | sha256sum 2>/dev/null | awk '{print $1}')
    fi
    _gr_rec=$(jq -r '.prd_sha256 // ""' "$_gr_receipt" 2>/dev/null)
    if [[ -n "$_gr_rec" && "$_gr_rec" != "$_gr_live" ]]; then
      echo "  WARNING: gate-receipt MISMATCH — the PRD changed since it was sealed." >&2
      echo "           Re-gate: score the modified PRD, then run 'gate-receipt $SLUG' (see /rlp-desk revise)." >&2
    fi
  fi
fi

# --- Test Spec ---
F="$DESK/plans/test-spec-$SLUG.md"
if [[ ! -f "$F" ]]; then
  _emit_testspec_template "$SLUG" > "$F"
  echo "  + $F"
else echo "  · $F"; fi

# Split test-spec into per-US files (no-op with warning if no US section markers)
if ! split_test_spec_by_us "$DESK/plans/test-spec-$SLUG.md" "$SLUG"; then
  # reaudit wave 1 (SV-gate finding, round 3): symmetric with
  # split_prd_by_us's guard above. Unlike the PRD case, this call sits
  # AFTER the Test Spec write block, so test-spec-$SLUG.md is already
  # guaranteed to exist by this point (preserved-as-authored or freshly
  # regenerated) — there is nothing this call's own failure could leave
  # missing that needs restoring. Still fail loudly and explicitly rather
  # than letting a bare statement's `set -e` abort silently skip everything
  # downstream (mechanical pre-gate template, .gitignore, permissions,
  # post-init validation, PRD lint) with no explanation.
  echo "  ERROR: split_test_spec_by_us failed — see the message above. Fix the" >&2
  echo "         test-spec heading(s) and re-run init." >&2
  exit 1
fi

# --- Mechanical pre-gate template (Feature 1) ---
# Optional deterministic checks the LEADER runs before each LLM verification.
# Copy pregate-<slug>.sh.example → pregate-<slug>.sh to activate; absent = no-op.
F="$DESK/plans/pregate-$SLUG.sh.example"
if [[ ! -f "$F" ]]; then
  cat > "$F" <<EOF
#!/usr/bin/env zsh
# Mechanical pre-gate for campaign: $SLUG
#
# HOW IT WORKS
#   Rename this file to  pregate-$SLUG.sh  to activate it.
#   The leader runs it (from the project root) AFTER the Worker claims done and
#   BEFORE dispatching the LLM Verifier. Exit 0 = pass (LLM verification runs as
#   usual). Non-zero exit = FAIL: the leader SKIPS LLM verification and
#   redispatches the Worker, using the tail of this script's output as the fix
#   contract. It can ONLY early-FAIL — it never produces a pass verdict, so the
#   normal Verifier still runs on every pass (Iron Law preserved).
#
#   This file is LAYER 1 (campaign-static checks). LAYER 2 runs automatically with
#   no scaffold: after layer 1 passes, the leader replays the verify-* commands you
#   recorded in done-claim.json execution_steps and fails if a claimed exit code
#   does not reproduce. See governance §3a.
#
# CONTRACT (keep it strict)
#   - DETERMINISTIC checks only: compile/build, lint/typecheck, required-file
#     existence, "tests actually ran" (test count > 0). NO LLM-judgment checks.
#   - Fast and side-effect-free. Soft timeout defaults to 300s
#     (override: run.mjs --pre-gate-timeout N, or RLP_PREGATE_TIMEOUT env).
#   - Print WHY it failed to stdout/stderr — that tail becomes the fix contract.
#
# EXAMPLES (uncomment + adapt; each failing check should exit non-zero)
#   # 1) required entrypoint exists
#   # [[ -f src/index.ts ]] || { echo "missing src/index.ts"; exit 1; }
#
#   # 2) typecheck compiles (catches TS2307 etc. — a 30s check, not an opus round)
#   # npx tsc --noEmit || { echo "typecheck failed"; exit 1; }
#
#   # 3) tests actually ran (count > 0), not "0 tests"
#   # out=\$(npm test 2>&1) || { echo "\$out" | tail -40; exit 1; }
#   # echo "\$out" | grep -qE '[1-9][0-9]* (passing|passed|tests)' || {
#   #   echo "0 tests ran — did the suite get wired up?"; exit 1; }

exit 0
EOF
  echo "  + $F"
else echo "  · $F"; fi

# --- .gitignore for runtime artifacts ---
GITIGNORE="$ROOT/.gitignore"
MARKER="# RLP Desk runtime artifacts"
DESK_REL="${RLP_DESK_RUNTIME_DIR:-.rlp-desk}"
if [[ -f "$GITIGNORE" ]]; then
  # v0.13.0: drop legacy ".claude/ralph-desk/" line if present.
  if grep -qE '^\.claude/ralph-desk/$' "$GITIGNORE"; then
    sed -i.bak -E '/^\.claude\/ralph-desk\/$/d' "$GITIGNORE"
    rm -f "${GITIGNORE}.bak"
    echo "  · .gitignore (legacy .claude/ralph-desk/ rule removed)"
  fi
  if ! grep -qE "^${DESK_REL}/$" "$GITIGNORE"; then
    if ! grep -qF "$MARKER" "$GITIGNORE"; then
      echo "" >> "$GITIGNORE"
      echo "$MARKER" >> "$GITIGNORE"
    fi
    echo "${DESK_REL}/" >> "$GITIGNORE"
    echo "  + .gitignore (rlp-desk rule for ${DESK_REL}/ appended)"
  else
    echo "  · .gitignore (${DESK_REL}/ already present)"
  fi
else
  cat > "$GITIGNORE" <<GIEOF
# RLP Desk runtime artifacts
${DESK_REL}/
GIEOF
  echo "  + .gitignore (created with rlp-desk rule for ${DESK_REL}/)"
fi

# --- Claude Code sensitive-file permissions for .rlp-desk/ ---
# Worker/Verifier need Read/Edit/Write access to .rlp-desk/ files. With the
# project-local tree outside .claude/, Claude Code's hardcoded sensitive
# policy no longer triggers, but explicit permissions still help when the
# user has configured stricter defaults.
SETTINGS_FILE="$ROOT/.claude/settings.local.json"
PERM_MARKER="Read(${DESK_REL}/**)"

if [[ -f "$SETTINGS_FILE" ]] && grep -qF "$PERM_MARKER" "$SETTINGS_FILE" 2>/dev/null; then
  echo "  · .claude/settings.local.json (rlp-desk permissions already present)"
else
  PERMS=$(printf '["Read(%s/**)", "Edit(%s/**)", "Write(%s/**)"]' "$DESK_REL" "$DESK_REL" "$DESK_REL")

  if [[ -f "$SETTINGS_FILE" ]]; then
    if command -v jq &>/dev/null; then
      jq --argjson perms "$PERMS" '
        .permissions //= {} |
        .permissions.allow //= [] |
        .permissions.allow += ($perms - .permissions.allow)
      ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" && mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      echo "  + .claude/settings.local.json (rlp-desk permissions merged)"
    else
      echo "  ⚠ jq not found. Add to .claude/settings.local.json manually:"
      echo "    permissions.allow: Read/Edit/Write(${DESK_REL}/**)"
    fi
  else
    mkdir -p "$(dirname "$SETTINGS_FILE")"
    cat > "$SETTINGS_FILE" <<SETEOF
{
  "permissions": {
    "allow": [
      "Read(${DESK_REL}/**)",
      "Edit(${DESK_REL}/**)",
      "Write(${DESK_REL}/**)"
    ]
  }
}
SETEOF
    echo "  + .claude/settings.local.json (created with rlp-desk permissions)"
  fi
  echo ""
  echo "  NOTE: Added Read/Edit/Write permissions for ${DESK_REL}/ to"
  echo "        .claude/settings.local.json (local, not committed to git)."
fi

# --- Post-init validation gate ---
INIT_FAIL=0
for REQUIRED_FILE in \
  "$DESK/prompts/$SLUG.worker.prompt.md" \
  "$DESK/prompts/$SLUG.verifier.prompt.md" \
  "$DESK/context/$SLUG-latest.md" \
  "$DESK/memos/$SLUG-memory.md" \
  "$DESK/plans/prd-$SLUG.md" \
  "$DESK/plans/test-spec-$SLUG.md"; do
  if [[ ! -f "$REQUIRED_FILE" ]]; then
    echo "  ✗ MISSING: $REQUIRED_FILE"
    INIT_FAIL=1
  fi
done
if [[ $INIT_FAIL -eq 1 ]]; then
  echo ""
  echo "ERROR: Scaffold incomplete. Some required files were not created."
  echo "Re-run init or check filesystem permissions."
  exit 1
fi

# --- PRD cross-US dependency lint (governance §7a) ---
# When VERIFY_MODE=per-us (default), each AC must reference only the same US or
# earlier verified US' artifacts. Detect future-US references and exit 2 so the
# wrapper can distinguish lint reject (2) from generic init failure (1).
#
# Detector helper — scans the PRD line-by-line, partitions content by `### US-NNN`
# headers, and emits violations when an AC inside US-N references US-R with R > N.
# Patterns are intentionally narrow (Korean + English idioms from the 2026-04-25
# bug report) to avoid false positives on benign cross-references in prose.
_detect_cross_us_refs() {
  local prd_file="$1"
  # POSIX/BSD-awk compatible: match(s, regex) sets RSTART/RLENGTH only.
  #
  # Strategy: partition the PRD into US-N blocks via `### US-NNN` headers,
  # then within each block flag any `US-([0-9]+)` token whose number R > N
  # as a cross-US violation, but ONLY on lines that look like AC content
  # (bullet starting with `-` / `*` or one of Given/When/Then markers). Prose,
  # roadmap mentions, and sub-headings are skipped. The referenced US must
  # also be defined in the same PRD — pure typos / forward-pointing
  # placeholders without a target US are not flagged.
  #
  # Two passes: pass 1 collects defined US numbers; pass 2 emits violations.
  # Pre-existing PRDs with benign cross-US prose ("see also US-005") inside
  # narrative paragraphs no longer trip the lint.
  awk '
    function is_ac_line(s) {
      # bullet styles or Given/When/Then keywords (Korean and English).
      return (s ~ /^[[:space:]]*[-*][[:space:]]/) \
          || (s ~ /(^|[[:space:]])[Gg]iven[:[:space:]]/) \
          || (s ~ /(^|[[:space:]])[Ww]hen[:[:space:]]/) \
          || (s ~ /(^|[[:space:]])[Tt]hen[:[:space:]]/)
    }
    BEGIN { current = 0; pass = 0 }
    pass == 0 && $0 ~ /^### US-[0-9]+/ {
      if (match($0, "US-[0-9]+") > 0) {
        tok = substr($0, RSTART + 3, RLENGTH - 3)
        defined[tok + 0] = 1
      }
      next
    }
    pass == 0 { next }
    pass == 1 {
      if ($0 ~ /^### US-[0-9]+/) {
        if (match($0, "US-[0-9]+") > 0) {
          tok = substr($0, RSTART + 3, RLENGTH - 3)
          current = tok + 0
        }
        next
      }
      if (current == 0) next
      if (!is_ac_line($0)) next
      line = $0
      while (match(line, "US-[0-9]+") > 0) {
        slice = substr(line, RSTART, RLENGTH)
        ref_tok = substr(slice, 4)
        ref = ref_tok + 0
        if (ref > current && defined[ref]) {
          # FNR (file-local) gives the PRD line number; NR would accumulate
          # across both awk passes and report inflated line numbers.
          printf("US-%03d:%d:%s\n", current, FNR, $0)
        }
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' pass=0 "$prd_file" pass=1 "$prd_file"
}

PRD_FILE_LINT="$DESK/plans/prd-$SLUG.md"
# Mode resolution priority (highest first):
#   1. --verify-mode CLI arg passed to init
#   2. VERIFY_MODE env var (already exported by the wrapper for run)
#   3. governance default: per-us
LINT_VERIFY_MODE="${VERIFY_MODE_ARG:-${VERIFY_MODE:-per-us}}"
if [[ -f "$PRD_FILE_LINT" ]]; then
  LINT_VIOLATIONS=$(_detect_cross_us_refs "$PRD_FILE_LINT")
  if [[ -n "$LINT_VIOLATIONS" ]]; then
    if [[ "$LINT_VERIFY_MODE" == "per-us" ]]; then
      echo ""
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
      echo "ERROR: PRD contains cross-US dependency AC incompatible with --verify-mode per-us" >&2
      echo "" >&2
      echo "$LINT_VIOLATIONS" | while IFS=: read -r us_id lineno body; do
        echo "  $PRD_FILE_LINT:$lineno  ($us_id references a higher-numbered US)" >&2
        echo "    > ${body# }" >&2
      done
      echo "" >&2
      echo "Fix options:" >&2
      echo "  - Move the cross-US AC into the higher-numbered US (the one being referenced)." >&2
      echo "  - OR re-run with VERIFY_MODE=batch to allow cross-US AC." >&2
      echo "  - See governance.md §7a for the cross-US dependency rule." >&2
      echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
      exit 2
    else
      echo ""
      echo "WARN: PRD has cross-US dependency AC. Allowed under VERIFY_MODE=$LINT_VERIFY_MODE,"
      echo "      but blocking under per-us. Locations:"
      echo "$LINT_VIOLATIONS" | while IFS=: read -r us_id lineno _body; do
        echo "  $PRD_FILE_LINT:$lineno  ($us_id)"
      done
    fi
  fi
fi

# vision-adopt §1b: 3-doc consistency lint (PRD ↔ test-spec ↔ per-US split).
# At init this is a HARD REJECT (exit 3) — the campaign has not started, so a
# structural inconsistency must be fixed before the scaffold is declared ready.
# (The run-start re-check is WARN-loud, mirroring the gate-receipt convention.)
# init does not source lib_ralph_desk.zsh (it stays standalone); run the lint in
# a subshell that sources the lib so the shared implementation is reused without
# leaking the lib's globals into init.
_LINT3_LIB="${0:A:h}/lib_ralph_desk.zsh"
if [[ -f "$_LINT3_LIB" && -f "$DESK/plans/prd-$SLUG.md" ]]; then
  if ! ( source "$_LINT3_LIB" 2>/dev/null
         log() { :; }; log_error() { :; }; log_warn() { :; }; log_debug() { :; }
         _lint_3doc_consistency "$DESK/plans/prd-$SLUG.md" "$DESK/plans/test-spec-$SLUG.md" "$DESK/plans" "$SLUG" strict ); then
    echo "" >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    echo "ERROR: PRD ↔ test-spec ↔ per-US split are structurally inconsistent (vision-adopt §1b)." >&2
    echo "       Fix the mismatches listed above, then re-run init." >&2
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >&2
    exit 3
  fi
fi

write_init_env_stamp "$SLUG"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Scaffold ready: $SLUG"
echo ""
echo "Next:"
echo "  1. Edit PRD:       $DESK/plans/prd-$SLUG.md"
echo "  2. Edit test spec: $DESK/plans/test-spec-$SLUG.md"
echo "  3. Run (copy a command below):"
echo ""
print_run_presets "$SLUG"
