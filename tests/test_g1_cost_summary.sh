#!/usr/bin/env zsh
# G1-0 — campaign report: stray key=value line regression tests.
#
# Root cause (dogfood-gaps-g1-g4.md §G1-0): `local <name>` with NO assignment,
# applied to an already-existing variable inside a loop, is a zsh `typeset`
# DISPLAY command — it prints `name=<current value>` to stdout on every
# iteration after the first. Two sites in generate_campaign_report()
# (lib_ralph_desk.zsh) had this defect: `local us_id` (Verification Results
# loop) and `local t` (Cost & Performance loop). Fix: hoist the bare
# declaration above its loop so it is declared once, assigned (not
# re-declared) inside.
#
# Sources the REAL generate_campaign_report() (test_commit_oracle.sh style —
# `source "$LIB"` in a clean zsh, stub log/log_debug/log_error, drive it
# against a real temp git repo + real done-claim/cost-log fixtures).
set -uo pipefail
REPO="${0:A:h:h}"
LIB="$REPO/src/scripts/lib_ralph_desk.zsh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; return 0; }
no(){ FAIL=$((FAIL+1)); print "  FAIL $1"; return 0; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Build a minimal real campaign dir: git repo ROOT + LOGS_DIR with N
# iter-NNN-done-claim.json (real us_id values) and a 5-row cost-log.jsonl
# (the exact token values from the plan's arithmetic check: 5892, 5888,
# 5613, 5660, 1588 — sum 24641).
setup_campaign() {
  local root="$1" logs="$2" n_iters="$3"
  mkdir -p "$root" "$logs"
  git -C "$root" init -q
  git -C "$root" config user.email t@e.com
  git -C "$root" config user.name t
  git -C "$root" config commit.gpgsign false
  echo v1 > "$root/a.txt"
  git -C "$root" add a.txt
  git -C "$root" commit -q -m baseline
  local i us
  for (( i=1; i<=n_iters; i++ )); do
    us="US-$(printf '%03d' $i)"
    jq -n --arg u "$us" '{us_id:$u}' > "$logs/iter-$(printf '%03d' $i)-done-claim.json"
  done
  : > "$logs/cost-log.jsonl"
  local tok
  for tok in 5892 5888 5613 5660 1588; do
    jq -nc --argjson t "$tok" '{estimated_tokens:$t}' >> "$logs/cost-log.jsonl"
  done
}

# Invoke the REAL generate_campaign_report in a clean sourced-lib zsh.
run_report() { # $1=root $2=logs $3=n_iters
  zsh --no-rcs -c '
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$1"'"; LOGS_DIR="'"$2"'"; DESK="'"$1"'"; SLUG="g1-test"
    ITERATION='"$3"'; MAX_ITER='"$3"'
    START_TIME=$(date +%s)
    COST_LOG="'"$2"'/cost-log.jsonl"
    CAMPAIGN_REPORT_GENERATED=0
    COMPLETE_SENTINEL="'"$1"'/.complete"; BLOCKED_SENTINEL="'"$1"'/.blocked"
    touch "$COMPLETE_SENTINEL"
    WITH_SELF_VERIFICATION=0; WITH_SELF_VERIFICATION_REQUESTED=0
    WORKER_MODEL=w; WORKER_ENGINE=we; VERIFIER_MODEL=v; VERIFIER_ENGINE=ve
    CONSENSUS_MODE=cm; CONSENSUS_MODEL=cmm; FINAL_CONSENSUS_MODEL=fcm
    VERIFIED_US="US-001"; CONSECUTIVE_FAILURES=0
    generate_campaign_report
    cat "$LOGS_DIR/campaign-report.md"
  '
}

print -r -- "== g1: no stray t= line in a 5-row cost-log report =="
R1="$TMP/repo1"; L1="$TMP/logs1"
setup_campaign "$R1" "$L1" 2
out1=$(run_report "$R1" "$L1" 2)
if print -r -- "$out1" | grep -qE '^t='; then
  no "stray 't=' line present in report body"
else
  ok "no stray 't=' line"
fi
# Corroborate the fix is real, not a no-op: total must reflect all 5 rows
# (24641), not the 4-row undercount (23053) the display-command bug caused
# when the 5th 't=' line got swallowed into the loop's last echo.
# G1-3 wording: the raw total line now reads "Total estimated tokens (raw):"
# (was "Total estimated tokens:") to distinguish it from the new
# sol-equivalent line.
if print -r -- "$out1" | grep -q 'Total estimated tokens (raw): 24641'; then
  ok "total_tokens reflects all 5 cost rows (24641)"
else
  no "total_tokens wrong or stray-line corrupted (want 24641): $(print -r -- "$out1" | grep 'Total estimated tokens')"
fi

print -r -- "== g1: no stray us_id= line in Verification Results =="
R2="$TMP/repo2"; L2="$TMP/logs2"
setup_campaign "$R2" "$L2" 3
out2=$(run_report "$R2" "$L2" 3)
if print -r -- "$out2" | grep -qE '^us_id='; then
  no "stray 'us_id=' line present in report body"
else
  ok "no stray 'us_id=' line"
fi
# Corroborate real us_id values still render inline (fix must not blank them).
us_lines=$(print -r -- "$out2" | grep -c 'us_id=US-00[1-3]')
if (( us_lines == 3 )); then
  ok "all 3 real us_id values render inline in Verification Results"
else
  no "expected 3 inline us_id values, found $us_lines"
fi

print -r -- "== g1: general stray key=value line check (both reports) =="
stray1=$(print -r -- "$out1" | grep -cE '^[a-z_][a-z0-9_]*=')
stray2=$(print -r -- "$out2" | grep -cE '^[a-z_][a-z0-9_]*=')
if (( stray1 == 0 )); then
  ok "report1: zero bare key=value lines"
else
  no "report1: $stray1 bare key=value line(s) found"
fi
if (( stray2 == 0 )); then
  ok "report2: zero bare key=value lines"
else
  no "report2: $stray2 bare key=value line(s) found"
fi


# =============================================================================
# G1-1..G1-3: sol-equivalent cost summary (real generate_campaign_report,
# real cost-log.jsonl rows — no done-claim files needed for these cases).
# =============================================================================

# run_cost_section: write $2 (raw cost-log.jsonl content, one JSON object per
# line) to a fresh campaign dir, optionally write $3 as STATUS_FILE content,
# invoke the REAL generate_campaign_report, and echo just the
# "## Cost & Performance" section body.
#   $1 = override_models_file (empty = none)
#   $2 = cost-log content (newline-separated JSON lines)
#   $3 = status.json content (empty = no STATUS_FILE)
run_cost_section() {
  local override_file="$1" cost_log_content="$2" status_content="$3"
  local root="$TMP/root-$RANDOM" logs
  logs="$root/logs"
  mkdir -p "$root" "$logs"
  git -C "$root" init -q
  git -C "$root" config user.email t@e.com
  git -C "$root" config user.name t
  git -C "$root" config commit.gpgsign false
  echo v1 > "$root/a.txt"
  git -C "$root" add a.txt
  git -C "$root" commit -q -m baseline
  touch "$root/.complete"
  print -r -- "$cost_log_content" > "$logs/cost-log.jsonl"
  local status_file=""
  if [[ -n "$status_content" ]]; then
    status_file="$logs/status.json"
    print -r -- "$status_content" > "$status_file"
  fi

  zsh --no-rcs -c '
    RLP_DESK_MODELS_FILE="'"$override_file"'"
    LIB_DIR="'"$REPO"'/src/scripts"
    source "'"$LIB"'" 2>/dev/null
    log(){ :; }; log_debug(){ :; }; log_error(){ :; }
    ROOT="'"$root"'"; LOGS_DIR="'"$logs"'"; DESK="'"$root"'"; SLUG="g1-cost"
    ITERATION=0; MAX_ITER=0
    START_TIME=$(date +%s)
    COST_LOG="'"$logs"'/cost-log.jsonl"
    STATUS_FILE="'"$status_file"'"
    CAMPAIGN_REPORT_GENERATED=0
    COMPLETE_SENTINEL="'"$root"'/.complete"; BLOCKED_SENTINEL="'"$root"'/.blocked"
    WITH_SELF_VERIFICATION=0; WITH_SELF_VERIFICATION_REQUESTED=0
    WORKER_MODEL=w; WORKER_ENGINE=we; VERIFIER_MODEL=v; VERIFIER_ENGINE=ve
    CONSENSUS_MODE=cm; CONSENSUS_MODEL=cmm; FINAL_CONSENSUS_MODEL=fcm
    VERIFIED_US=""; CONSECUTIVE_FAILURES=0
    generate_campaign_report
    sed -n "/^## Cost/,/^## SV/p" "$LOGS_DIR/campaign-report.md"
  '
}

row() { # $1=tokens $2=model $3=engine $4=effort $5=us_id
  jq -nc --argjson t "$1" --arg m "$2" --arg e "$3" --arg f "$4" --arg u "$5" \
    '{estimated_tokens:$t, worker_model:$m, worker_engine:$e, worker_effort:$f, us_id:$u}'
}

print -r -- "== g1: luna rows convert at 0.04 (3 x 1000 -> 120) =="
out=$(run_cost_section "" "$(row 1000 gpt-5.6-luna codex high US-001)
$(row 1000 gpt-5.6-luna codex high US-001)
$(row 1000 gpt-5.6-luna codex high US-001)" "")
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 120 tokens'; then
  ok "luna 3x1000 -> 120"
else
  no "luna 3x1000 wrong: $(print -r -- "$out" | grep 'sol-equivalent')"
fi

print -r -- "== g1: mixed families sum correctly (luna+terra+sol 1000 each -> 1440) =="
out=$(run_cost_section "" "$(row 1000 gpt-5.6-luna codex high US-001)
$(row 1000 gpt-5.6-terra codex max US-001)
$(row 1000 gpt-5.6-sol codex xhigh US-001)" "")
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 1440 tokens'; then
  ok "mixed families -> 1440"
else
  no "mixed families wrong: $(print -r -- "$out" | grep 'sol-equivalent')"
fi

print -r -- "== g1: per-row truncation avoided (3 x 10 luna -> 1, not 0) =="
out=$(run_cost_section "" "$(row 10 gpt-5.6-luna codex high US-001)
$(row 10 gpt-5.6-luna codex high US-001)
$(row 10 gpt-5.6-luna codex high US-001)" "")
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 1 tokens'; then
  ok "3x10 luna -> 1 (accumulate-then-divide, not per-row truncation to 0)"
else
  no "3x10 luna wrong (per-row truncation regression?): $(print -r -- "$out" | grep 'sol-equivalent')"
fi

print -r -- "== g1: claude legs counted, never converted =="
out=$(run_cost_section "" "$(row 500 sonnet claude '' US-001)
$(row 500 sonnet claude '' US-001)" "")
if print -r -- "$out" | grep -q '^- Claude legs: 2 iteration(s)'; then
  ok "2 claude legs counted"
else
  no "claude legs count wrong: $(print -r -- "$out" | grep 'Claude legs')"
fi
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 0 tokens'; then
  ok "claude legs contribute 0 to sol-equivalent"
else
  no "claude legs leaked into sol-equivalent: $(print -r -- "$out" | grep 'sol-equivalent')"
fi

print -r -- "== g1: escalation count from model transitions (luna:high x2 -> luna:max -> terra:max => 2) =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 gpt-5.6-luna codex max US-001)
$(row 100 gpt-5.6-terra codex max US-001)" "")
if print -r -- "$out" | grep -qE '^- Escalation count: 2 ladder move'; then
  ok "escalation count = 2 across 3 transitions-with-one-repeat"
else
  no "escalation count wrong: $(print -r -- "$out" | grep 'Escalation count')"
fi

print -r -- "== g1: effort-only escalation counts (luna:high -> luna:max => 1) =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 gpt-5.6-luna codex max US-001)" "")
if print -r -- "$out" | grep -qE '^- Escalation count: 1 ladder move'; then
  ok "effort-only change counted as an escalation"
else
  no "effort-only escalation not counted: $(print -r -- "$out" | grep 'Escalation count')"
fi

print -r -- "== g1: final model per US (US-001 rows then US-002 rows -> both, last model each) =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 gpt-5.6-luna codex max US-001)
$(row 100 gpt-5.6-terra codex max US-002)" "")
fm_line=$(print -r -- "$out" | grep '^- Final model per US:')
if print -r -- "$fm_line" | grep -q 'US-001 = gpt-5.6-luna:max' && print -r -- "$fm_line" | grep -q 'US-002 = gpt-5.6-terra:max'; then
  ok "final model per US shows last model for each US"
else
  no "final model per US wrong: $fm_line"
fi

print -r -- "== g1: unknown family falls back to 1.0 with a note =="
out=$(run_cost_section "" "$(row 1000 totally-unknown-model codex high US-001)" "")
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 1000 tokens'; then
  ok "unknown family falls back to factor 1.0 (1000 tokens unchanged)"
else
  no "unknown family fallback wrong: $(print -r -- "$out" | grep 'sol-equivalent')"
fi
if print -r -- "$out" | grep -qi 'unrecognized model family'; then
  ok "unknown family note printed"
else
  no "unknown family note MISSING (silent token drop risk)"
fi

print -r -- "== g1: legacy cost-log without model fields renders and is reconciled =="
legacy_row=$(cat "$REPO/tests/fixtures/cost-summary/legacy-row.jsonl")
out=$(run_cost_section "" "$legacy_row" "")
if print -r -- "$out" | grep -q '^- (1 iteration(s) unattributed)'; then
  ok "legacy row surfaces (1 iteration(s) unattributed)"
else
  no "legacy row reconciliation line missing/wrong: $(print -r -- "$out" | grep 'unattributed')"
fi
if print -r -- "$out" | grep -q '^- Total estimated tokens (raw): 1587'; then
  ok "legacy row's tokens still counted into the raw total"
else
  no "legacy row raw total wrong: $(print -r -- "$out" | grep 'Total estimated tokens')"
fi

print -r -- "== g1: no reconciliation line when all rows attributed (negative) =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 sonnet claude '' US-002)" "")
if print -r -- "$out" | grep -q 'unattributed'; then
  no "reconciliation line present with zero unattributed rows (false positive)"
else
  ok "no reconciliation line when every row is attributed"
fi

print -r -- "== g1: cost_factors resolves shipped-first (override cannot change pricing) =="
OVERRIDE_FILE="$TMP/override-cost-factors.json"
jq -n '{cost_factors: {"gpt-5.6-luna": 0.99}}' > "$OVERRIDE_FILE"
out=$(run_cost_section "$OVERRIDE_FILE" "$(row 1000 gpt-5.6-luna codex high US-001)" "")
if print -r -- "$out" | grep -q '^- Codex legs sol-equivalent: 40 tokens'; then
  ok "shipped cost_factors (0.04) win over override (0.99)"
else
  no "override leaked into pricing (shipped-first violated): $(print -r -- "$out" | grep 'sol-equivalent')"
fi

print -r -- "== g1: report marked ESTIMATED =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)" "")
if print -r -- "$out" | grep -q '^## Cost & Performance (ESTIMATED'; then
  ok "Cost & Performance header marked ESTIMATED"
else
  no "ESTIMATED marker missing from header"
fi

print -r -- "== g1: escalation count cross-check disagreement prints both (status.json vs cost-log) =="
out=$(run_cost_section "" "$(row 100 gpt-5.6-luna codex high US-001)
$(row 100 gpt-5.6-luna codex high US-001)" '{"model_upgraded":1}')
if print -r -- "$out" | grep -qE '^- Escalation count: 0 ladder move.*disagreement'; then
  ok "escalation count disagreement (status says upgraded, cost-log says 0) prints both"
else
  no "disagreement note missing: $(print -r -- "$out" | grep 'Escalation count')"
fi

print -r -- ""
print -r -- "RESULTS: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
