#!/usr/bin/env zsh
# ============================================================================
# US-003 AC1-AC5 — iter-signal canonical `status` key: tolerant-read legacy
# `stop`.
#
# `docs/rlp-desk/verification-history.md:94`: precedent worker prompts wrote
# a `stop` key; the zsh leader parses `.status` -> null -> "Unknown signal
# status" -> circuit breaker -> BLOCKED campaign on a key-name mismatch
# alone. Fix = tolerant-read `stop` on the READ side, canonical-write
# `status` unchanged on the WRITE side.
#
# This test drives the REAL extracted reader, _resolve_iter_signal_status
# (lib_ralph_desk.zsh), against fixture signal files on disk — the same
# function run_ralph_desk.zsh's single live `.status` read site (the
# `signal_status=$(_resolve_iter_signal_status "$SIGNAL_FILE")` assignment
# feeding the step-⑥ case dispatch) calls.
#
# Coverage split (do not blur): zsh leader is LIVE (this test). Node
# (campaign-main-loop.mjs) is dead-code parity, covered separately by
# tests/node/iter-signal-key-tolerance.test.mjs — never cited as coverage
# here. The native leader does not read iter-signal `status` at all
# (rlp-desk.md:557 reads `us_id` only), so it is out of scope for AC1-AC5.
#
# Also pins AC5: all 4 zsh iter-signal SYNTHESIZER sites still write the
# canonical `status` key, never legacy `stop`, across the 3 quoting forms
# actually used in run_ralph_desk.zsh:
#   plain   "status":"verify"       (codex-exit, A4 fallback)
#   escaped \"status\":\"verify\"   (sequential-final-verify)
#   spaced  "status": "verify"      (D-16 leader-finalize)
# ============================================================================
set -uo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
LIB="$ROOT_DIR/src/scripts/lib_ralph_desk.zsh"
RUN="$ROOT_DIR/src/scripts/run_ralph_desk.zsh"
[[ -f "$LIB" ]] || { print -u2 "FAIL: $LIB not found"; exit 1; }
[[ -f "$RUN" ]] || { print -u2 "FAIL: $RUN not found"; exit 1; }

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); print "  PASS $1"; }
no(){ FAIL=$((FAIL+1)); print -u2 "  FAIL $1"; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# _resolve <json-body> <out-var-resolved> <out-var-errfile> — writes the JSON
# to a fixture file, calls the REAL _resolve_iter_signal_status in a clean
# subshell, captures stdout (the resolved value) and stderr (log lines)
# separately, so pollution of the return channel would show up as a wrong
# $resolved rather than being silently masked.
_resolve() {
  local json="$1" tag="$2"
  local sig="$TMPD/sig-$tag.json"
  local err="$TMPD/err-$tag.log"
  print -r -- "$json" > "$sig"
  local resolved
  resolved=$(zsh -c '
    source "'"$LIB"'" 2>/dev/null
    log_debug(){ :; }; log_error(){ :; }
    _resolve_iter_signal_status "'"$sig"'"
  ' 2>"$err")
  print -r -- "$resolved"
  print -r -- "$err" > "$TMPD/.lasterr"
}

# ---------------------------------------------------------------------------
# AC1 — status present, no stop -> byte-identical (no log noise)
# ---------------------------------------------------------------------------
resolved=$(_resolve '{"status":"verify","us_id":"US-003"}' ac1)
errfile=$(cat "$TMPD/.lasterr")
if [[ "$resolved" == "verify" ]]; then ok "AC1 status-only resolves to status"; else no "AC1 resolved wrong: [$resolved]"; fi
_n=$(grep -c . "$errfile" 2>/dev/null)
if [[ "$_n" == "0" ]]; then ok "AC1 no log noise when status alone present"; else no "AC1 unexpected log output ($_n lines): $(cat "$errfile")"; fi

# ---------------------------------------------------------------------------
# AC2 — legacy stop only, no status -> resolves stop's value + ONE
# deprecation log line naming the file
# ---------------------------------------------------------------------------
resolved=$(_resolve '{"stop":"verify","us_id":"US-003"}' ac2)
errfile=$(cat "$TMPD/.lasterr")
if [[ "$resolved" == "verify" ]]; then ok "AC2 legacy stop-only resolves to stop's value"; else no "AC2 resolved wrong: [$resolved]"; fi
_n=$(grep -c . "$errfile" 2>/dev/null)
if [[ "$_n" == "1" ]]; then ok "AC2 exactly one deprecation log line"; else no "AC2 expected 1 log line, got $_n: $(cat "$errfile")"; fi
if grep -q "DEPRECATED" "$errfile" 2>/dev/null && grep -qF "$TMPD/sig-ac2.json" "$errfile" 2>/dev/null; then
  ok "AC2 deprecation log names the file"
else
  no "AC2 deprecation log missing DEPRECATED marker or filename: $(cat "$errfile" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# AC3 — both present, DIFFERENT values -> status wins + divergence logged
# ---------------------------------------------------------------------------
resolved=$(_resolve '{"status":"verify","stop":"continue","us_id":"US-003"}' ac3)
errfile=$(cat "$TMPD/.lasterr")
if [[ "$resolved" == "verify" ]]; then ok "AC3 status wins over divergent stop"; else no "AC3 resolved wrong: [$resolved]"; fi
if grep -qi "divergent" "$errfile" 2>/dev/null; then ok "AC3 divergence logged"; else no "AC3 divergence not logged: $(cat "$errfile" 2>/dev/null)"; fi

# AC3b — same-value agreement must NOT log a spurious divergence warning.
resolved=$(_resolve '{"status":"verify","stop":"verify","us_id":"US-003"}' ac3b)
errfile=$(cat "$TMPD/.lasterr")
_n=$(grep -c . "$errfile" 2>/dev/null)
if [[ "$resolved" == "verify" && "$_n" == "0" ]]; then
  ok "AC3b agreeing status/stop values produce no log noise"
else
  no "AC3b unexpected: resolved=[$resolved] err=$(cat "$errfile" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# AC4 — neither key present -> existing "Unknown signal status" soft-fail
# byte-unchanged. jq -r '.status' on a missing key prints the literal string
# "null" (not empty) — that is the exact value the pre-existing case `*)`
# branch already logged as "Unknown signal status: null"; this AC guarantees
# _resolve_iter_signal_status still returns that same literal.
# ---------------------------------------------------------------------------
resolved=$(_resolve '{"us_id":"US-003","summary":"no status field"}' ac4)
errfile=$(cat "$TMPD/.lasterr")
if [[ "$resolved" == "null" ]]; then
  ok "AC4 neither key present -> literal 'null' passthrough (Unknown-signal-status soft-fail unchanged)"
else
  no "AC4 expected literal 'null', got [$resolved]"
fi
_n=$(grep -c . "$errfile" 2>/dev/null)
if [[ "$_n" == "0" ]]; then ok "AC4 no new log noise when neither key present"; else no "AC4 unexpected log output: $(cat "$errfile")"; fi

# ---------------------------------------------------------------------------
# Live call-site wiring — run_ralph_desk.zsh's single read site must call the
# extracted reader, not a bare `jq -r '.status'`.
# ---------------------------------------------------------------------------
if grep -qF 'signal_status=$(_resolve_iter_signal_status "$SIGNAL_FILE")' "$RUN"; then
  ok "run_ralph_desk.zsh's live read site calls _resolve_iter_signal_status"
else
  no "run_ralph_desk.zsh's live read site does not call _resolve_iter_signal_status"
fi

# ============================================================================
# AC5 — all 4 zsh iter-signal SYNTHESIZER sites write canonical `status`,
# never `stop`. The detector tolerates all 3 quoting forms; a "synthesizer
# site" is a status-JSON line whose statement (same line or the next, to
# cover a trailing `\` continuation into the piped `atomic_write` call)
# actually writes to a signal file via atomic_write — this excludes the
# in-prompt example JSON text (~:3110) and the unrelated heartbeat channel
# ("epoch"/"exited", ~:3216/:3388), neither of which is an iter-signal write.
# ============================================================================
_status_write_lines=()
while IFS= read -r line; do
  [[ -n "$line" ]] && _status_write_lines+=("$line")
done < <(grep -nE '\\?"status\\?"[[:space:]]*:[[:space:]]*\\?"' "$RUN" | grep -v '"epoch"' | cut -d: -f1)

_synth_count=0
_synth_lines=""
for lineno in "${_status_write_lines[@]}"; do
  window=$(sed -n "${lineno},$((lineno+1))p" "$RUN")
  if print -r -- "$window" | grep -q "atomic_write"; then
    _synth_count=$((_synth_count+1))
    _synth_lines+="$lineno "
  fi
done

if [[ "$_synth_count" -ge 4 ]]; then
  ok "AC5 found >=4 iter-signal synthesizer sites ($_synth_count: $_synth_lines) across the 3 quoting forms"
else
  no "AC5 expected >=4 synthesizer sites writing status, found $_synth_count (lines: $_synth_lines)"
fi

# Non-vacuity: the detector regex actually tolerates all 3 quoting forms by
# construction — assert against synthetic text, not just the real file.
for form in '"status":"verify"' '\"status\":\"verify\"' '"status": "verify"'; do
  if print -r -- "$form" | grep -qE '\\?"status\\?"[[:space:]]*:[[:space:]]*\\?"'; then
    ok "AC5 detector regex tolerates quoting form: $form"
  else
    no "AC5 detector regex REJECTED quoting form: $form"
  fi
done

# Bidirectional: no iter-signal synthesizer line (status-write line, or the
# line right after it) writes a literal `"stop":"..."` key — a regression
# back to the legacy key at a WRITE site would defeat AC5's intent even
# though the READ side stays tolerant.
_stop_write_hit=0
for lineno in "${_status_write_lines[@]}"; do
  window=$(sed -n "${lineno},$((lineno+1))p" "$RUN")
  if print -r -- "$window" | grep -qE '\\?"stop\\?"[[:space:]]*:[[:space:]]*\\?"'; then
    _stop_write_hit=1
    no "AC5 synthesizer site at line $lineno also writes a literal 'stop' key"
  fi
done
[[ "$_stop_write_hit" -eq 0 ]] && ok "AC5 no synthesizer site writes a literal 'stop' key"

echo ""
echo "=== test_iter_signal_key_tolerance.sh: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
