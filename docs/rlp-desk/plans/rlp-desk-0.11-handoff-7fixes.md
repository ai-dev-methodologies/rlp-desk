# rlp-desk 0.11 — Handoff Final 7-fix bundle (ralplan v3)

> v3 changes: NEW-1 (bash→zsh fixture invocation) + NEW-2 (early-exit grep broadened) Architect executor follow-ups 흡수.
> v2 changes (Architect + Critic codex iteration): PR split A/B 결정, R7 schema fallback, R8 helper-side guard, R9 reason canonicalization + edge cases, R10 normalized US extractor + quarantine (not rm), R11 early-exit grep inventory + trap, self-verification mechanical assertion 패치.

## Context

소비자 Final Handoff (`coordination/handoffs/2026-04-25-rlp-desk-final-status-and-handoff.md`) timestamp evidence 기반 7건 결함:

| ID | Severity | 결함 | Root file |
|---|---|---|---|
| P0-D | HIGH | A4 fallback 83% 빈발 (worker iter-signal 누락) | `run_ralph_desk.zsh:1587-1595`, `:526-546` |
| P1-F | MEDIUM | test-spec ≥3 tests/AC IL-4 자가모순 | `init_ralph_desk.zsh` test-spec gen + ingest |
| P1-G | MEDIUM | partial_verify signal vocabulary 부재 | `init_ralph_desk.zsh:448-454` Signal rules + verifier |
| P1-H | MEDIUM | blocked 시 memory.md/latest.md 미갱신 | worker prompt blocked exit hygiene |
| P2-I | MEDIUM | block ≠ failure → contract defect silent 12-iter | `run_ralph_desk.zsh:2659` consecutive_blocks 신규 |
| P2-J | MEDIUM | final ALL verify cross-mission us_id leak | `run_ralph_desk.zsh:2198/2425-2429` US_LIST scope |
| P2-K | LOW | cost-log 비어있음 (tmux mode) | `lib_ralph_desk.zsh:367` write_cost_log call coverage |

## PR 분할 결정 (v2)

Architect 권고에 따라 **PR-A(protocol) + PR-B(runtime) 2-PR 분할** 채택. 사용자가 "단일 PR" 명시한 경우에도 R7 schema collision (R3 와 silent fallback 위험) 때문에 분리 필요.

- **PR-A (protocol/contract)**: R5 + R6 + R7 + governance §1f/§7f/§7g + us017/us018/us019
- **PR-B (runtime/state)**: R8 + R9 + R10 + R11 + governance §8/§7a + us020/us021/us022/us023
- 자가검증 mapping 시나리오는 양 PR 모두 포함 (각 PR 의 fix 만 evaluate). 최종 self-verification (7/7) 은 PR-B merge 후 별도.

단, 사용자 직접 "단일 PR" 재요청 시 single PR 로 진행하되 self-verification 시나리오를 더 강화 (per-row mechanical assertion 필수).

## RALPLAN-DR

**Principles** (4):
1. **Fail loud, not silent** — A4 fallback / block-as-success / cross-mission leak / cost-log silence 모두 silent failure 패턴.
2. **Backward-compat first** — verify_partial 신규 status 의 기존 wrapper malformed 처리 명시. test-spec lint warn-then-strict 단계 진화.
3. **Minimal blast radius** — PR split + per-fix helper 분리. 각 fix 의 회귀는 독립 us_test.
4. **Self-verification mechanical** — 변경 사항 X가 자가검증 시나리오 Y에서 실제 트리거되었음을 grep+exit-code 로 증명.

**Decision Drivers**:
1. consumer wrapper 가 동일 패턴(83% A4 fallback, cross-mission leak, contract defect silent loop) 재발 차단.
2. 7-mission autonomous run 후 debug.log [FLOW] events 가 의미 있는 summary 보유 + audit log auditable.
3. cost-log 빈 파일 = "broken logging" 분류 가능, audit pipeline 신뢰성.

**Viable Options 비교**:

(아래 옵션 비교 v1 과 동일하나 Critic ITERATE 흡수 패치 추가)

- **R7 verify_partial schema malformed 처리 (Architect issue #2)**: `verify_partial` 인데 `verified_acs` 미존재/빈 배열 → `status='blocked'`, `reason='verify_partial_malformed'` 으로 다운그레이드. Worker autonomy 위배 차단.
- **R8 helper-side guard (Critic R8 + Architect issue #3)**: Verifier 의 mtime check 만으로 부족. `write_blocked_sentinel` 자체에 hygiene check 추가 — memory.md/latest.md mtime 이 sentinel 작성 시각보다 오래됐으면 (즉 worker 가 hygiene update 안 했으면) sentinel JSON 에 `meta.blocked_hygiene_violated=true` 자동 첨부. Worker 가 잊어도 verifier 가 즉시 인지.
- **R9 reason canonicalization (Architect issue #3)**: `_canonical_block_reason()` helper — hygiene wrapper prefix("hygiene_violated:", "wrapped:") strip 후 비교. R8 hygiene_violated 가 R9 counter 우회 차단.
- **R9 edge cases (Critic R9)**: 첫-iter block / mission setup block 은 `infra_failure` reason 으로 분류된 경우 counter 증가 안 함 (mission abort 부적절). 명시 exempt.
- **R10 normalized extractor + quarantine (Architect issue #4 + Critic R10)**: `grep -qE "^## $stale_us[: ]"` 대신 `awk '/^##[[:space:]]+(US-[0-9]+)([[:space:]:-]|$)/'` 로 정규화 추출 (PRD heading variation 대응). `rm -f` 대신 `mv` to `.sisyphus/quarantine/` (silent destructive 차단).
- **R11 trap-based final write (Architect issue #6 + Critic R11)**: init placeholder 폐기. zsh `trap 'write_cost_log "$ITERATION" || true' EXIT` 추가 + early-exit path grep inventory 회귀로 보장.
- **Self-verification per-row functions (Architect issue #5 + Critic Self-V)**: 단일 monolithic script 대신 7 함수 (`test_r5_a4_audit_triggered`, …) + 각 함수 내 pre/post 카운터 + grep 로 변경 함수 호출 증명.

---

## 해결 계획 (v2 patches highlighted)

### Fix R5: P0-D — A4 fallback 추적 + worker prompt 강화

**대상**:
1. `src/scripts/run_ralph_desk.zsh:1587-1595` + `:526-546` — A4 fallback 발동 시 audit log entry 작성 (`a4-fallback-audit.jsonl`, append).
2. `src/scripts/init_ralph_desk.zsh` worker prompt — "Step N+1 (mandatory)" 추가 + auto-generated summary penalty 명시.
3. Verifier prompt — A4 fallback summary detection 시 verdict.meta.iter_signal_quality='auto_generated'.
4. governance §1f — A4 ratio 권고 (per-mission < 10%).

**검증 (us017) — Critic R5 patch 흡수**:
- AC1: a4-fallback-audit.jsonl entry 작성 (zsh fixture)
- **AC1+ (Critic R5)**: pre_count=$(wc -l a4-fallback-audit.jsonl), trigger fixture, assert post_count > pre_count + ratio 계산 정확.
- AC2: worker prompt grep "Step N+1" + "iter-signal.json with SPECIFIC summary" 존재
- AC3: governance §1f 에 "A4 ratio < 10%" 권고 텍스트 + 측정 방법 명시
- AC4 (신규): Verifier prompt 에 "auto_generated" detection 문장 + meta field 명시

### Fix R6: P1-F — test-spec ≥3/AC enforcement (warn default + strict opt-in)

**대상**:
1. `src/scripts/init_ralph_desk.zsh` — `_lint_test_density()` helper:
   - PRD AC count 추출 (per-US, `^- AC[0-9]+:` regex)
   - test-spec test count 추출 (per-US, `^### Test ` 또는 `^\*\*T-` 헤더 카운트)
   - ratio < 3 시: WARN(default) → log_warn + audit + **init exit message 마지막에 summary 표시 (Critic R6 patch)**; STRICT(`--test-density-strict`) → exit 1.
2. `src/scripts/run_ralph_desk.zsh` + `src/node/run.mjs` — `--test-density-strict` flag stub.
3. governance §7f — Test Density Enforcement (WARN+STRICT decision tree).
4. Worker prompt — "≥3 tests/AC (happy + negative + boundary) 강제" 강화.

**검증 (us018) — Critic R6 patch 흡수**:
- AC1: `--test-density-strict` 플래그 파싱 (zsh + Node)
- AC2: WARN default — ratio<3 fixture 에서 init exit=0 + audit log entry **+ stderr/stdout 마지막 라인에 "Test density warning: US-XXX has N tests for M ACs (ratio=N/M < 3)" 메시지 포함**
- AC3: STRICT — ratio<3 fixture 에서 init exit=1 + 동일 메시지
- AC4: governance §7f 텍스트 정합 (Decision tree, downgrade 없음)

### Fix R7: P1-G — verify_partial signal vocabulary

**대상 (Critic R7 + Architect issue #2 patches)**:
1. `src/scripts/init_ralph_desk.zsh:448` Signal rules — verify_partial + 필수 필드 명시.
2. `src/scripts/init_ralph_desk.zsh build_verifier_prompt` 함수 (or equivalent prompt heredoc) — 정확 문장 추가:
   ```
   If signal status=verify_partial, evaluate ONLY verified_acs. Treat deferred_acs as out-of-scope (not fail).
   ```
3. `src/node/runner/campaign-main-loop.mjs` 신호 파싱 — verify_partial + verified_acs 미존재/빈 배열 시:
   ```js
   if (signalStatus === 'verify_partial' && (!Array.isArray(signal.verified_acs) || signal.verified_acs.length === 0)) {
     // Downgrade to blocked
     await writeSentinel(blockedSentinel, 'blocked', usId, 'verify_partial_malformed', { reason_category: 'mission_abort', recoverable: true, suggested_action: 'retry_after_fix' });
     continue;
   }
   ```
4. `src/scripts/run_ralph_desk.zsh:1313+` — verify_partial 동등 처리 (zsh 측 fallback).
5. governance §7g 신규 — Signal Vocabulary Extension + malformed downgrade 명시.

**검증 (us019)**:
- AC1: Signal rules grep verify_partial + verified_acs/deferred_acs/defer_reason
- AC2: governance §7g 정합 + malformed downgrade 명시
- AC3: Node 파서 verify_partial→verified_acs 만 verifier prompt 전달 (behavioural fixture)
- AC4: zsh 파서 verify_partial 인지
- **AC5 (Architect issue #2)**: malformed fixture (verify_partial + verified_acs=[]) → blocked sentinel 작성 + reason='verify_partial_malformed' + reason_category='mission_abort'
- **AC6 (Critic R7)**: Verifier prompt 에 정확 sentence 존재 (grep)

### Fix R8: P1-H — Blocked exit hygiene + helper-side guard

**대상 (Critic R8 + Architect issue #3 patches)**:
1. `src/scripts/init_ralph_desk.zsh` worker prompt — Blocked exit hygiene 섹션:
   > "On blocked exit (status=blocked): BEFORE writing iter-signal.json, ALWAYS append to memory.md § Blocking History `{iter, us, reason, suggested_repair}` AND update latest.md § Known Issues."
2. **`src/scripts/lib_ralph_desk.zsh:write_blocked_sentinel` (Critic R8 patch)** — sentinel write 직전 hygiene check:
   ```zsh
   local hygiene_violated=false
   local mem_file="$DESK/memos/$SLUG-memory.md"
   local lat_file="$DESK/context/$SLUG-latest.md"
   local now_ts=$(date +%s)
   for f in "$mem_file" "$lat_file"; do
     if [[ -f "$f" ]]; then
       local f_mtime=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null || echo 0)
       if (( now_ts - f_mtime > 300 )); then
         hygiene_violated=true
         break
       fi
     fi
   done
   ```
   JSON sidecar 에 `meta.blocked_hygiene_violated=$hygiene_violated` 자동 첨부.
3. `src/node/runner/campaign-main-loop.mjs` `_checkBlockedHygiene()` helper — blocked write 시 동등 검사 + analytics event.
4. governance §1f — "5th channel: memory.md/latest.md hygiene update" 추가 (4 channels → 5 channels).

**검증 (us020)**:
- AC1: Worker prompt grep "Blocked exit hygiene" + "memory.md" + "latest.md"
- AC2: governance §1f grep "5th channel" + "memory.md/latest.md hygiene"
- AC3: Node helper `_checkBlockedHygiene` 정의 (grep)
- AC4: behavioural — fixture: stale memory.md (mtime > 5min ago) → blocked sentinel JSON sidecar 의 meta.blocked_hygiene_violated=true
- **AC5 (Critic R8)**: lib_ralph_desk.zsh write_blocked_sentinel 에 hygiene_violated 자동 첨부 grep + behavioural fixture

### Fix R9: P2-I — consecutive_blocks counter + canonicalization + edge cases

**대상 (Critic R9 + Architect issue #3 patches)**:
1. `src/scripts/run_ralph_desk.zsh` 변수:
   ```zsh
   CONSECUTIVE_BLOCKS=0
   LAST_BLOCK_REASON=""
   BLOCK_CB_THRESHOLD="${BLOCK_CB_THRESHOLD:-3}"
   ```
2. **`_canonical_block_reason()` helper (Architect issue #3)**:
   ```zsh
   _canonical_block_reason() {
     local raw="$1"
     # Strip wrapper prefixes
     echo "$raw" | sed -E 's/^(hygiene_violated:|wrapped:)//' | head -c 80
   }
   ```
3. **Edge case exemption (Critic R9)** — `infra_failure` category 또는 첫 iter block 은 counter 증가 안 함:
   ```zsh
   if [[ "$reason_category" == "infra_failure" ]] || (( ITERATION <= 1 )); then
     # Exempt from consecutive_blocks
     LAST_BLOCK_REASON=""
     CONSECUTIVE_BLOCKS=0
   else
     local canonical=$(_canonical_block_reason "$reason")
     if [[ "$canonical" == "$LAST_BLOCK_REASON" ]]; then
       CONSECUTIVE_BLOCKS=$((CONSECUTIVE_BLOCKS + 1))
     else
       CONSECUTIVE_BLOCKS=1
       LAST_BLOCK_REASON="$canonical"
     fi
     if (( CONSECUTIVE_BLOCKS >= BLOCK_CB_THRESHOLD )); then
       echo '{"reason":"consecutive_blocks","count":'"$CONSECUTIVE_BLOCKS"',"last_reason":"'"$LAST_BLOCK_REASON"'"}' | atomic_write "$DESK/.sisyphus/mission-abort.json"
       exit 1
     fi
   fi
   ```
4. `src/node/runner/campaign-main-loop.mjs` 동등 (state.consecutive_blocks + last_block_reason + canonicalReason).
5. governance §8 — consecutive_blocks + canonicalization + exemption 명시.

**검증 (us021)**:
- AC1: BLOCK_CB_THRESHOLD 변수 정의 (default 3)
- AC2: zsh same-reason counter logic
- AC3: governance §8 텍스트 정합
- AC4: behavioural — 3회 동일 reason BLOCK 후 mission-abort.json 생성
- **AC5 (Architect issue #3)**: `_canonical_block_reason` helper 정의 + hygiene_violated prefix strip 검증
- **AC6 (Critic R9)**: 첫-iter block exempt fixture (ITERATION=1, reason="setup_fail") → CONSECUTIVE_BLOCKS=0 유지
- **AC7 (Critic R9)**: infra_failure category exempt fixture → CONSECUTIVE_BLOCKS=0 유지

### Fix R10: P2-J — Cross-mission us_id leak + normalized extractor + quarantine

**대상 (Critic R10 + Architect issue #4 patches)**:
1. `src/scripts/init_ralph_desk.zsh` mission init — stale us_id detect + scrub:
   ```zsh
   if [[ -f "$SIGNAL_FILE" ]]; then
     stale_us=$(jq -r '.us_id // empty' "$SIGNAL_FILE" 2>/dev/null)
     if [[ -n "$stale_us" && "$stale_us" != "ALL" ]]; then
       # Critic R10: normalized US extractor
       prd_us_list=$(awk 'match($0, /^##[[:space:]]+(US-[0-9]+)([[:space:]:-]|$)/, m) { print m[1] }' "$PRD_FILE" 2>/dev/null | sort -u)
       if ! echo "$prd_us_list" | grep -qx "$stale_us"; then
         # Architect issue #4: quarantine, not rm
         mkdir -p "$DESK/.sisyphus/quarantine"
         mv "$SIGNAL_FILE" "$DESK/.sisyphus/quarantine/iter-signal.$(date +%s).json"
         log "  Cross-mission stale us_id ($stale_us) — quarantined to .sisyphus/quarantine/"
       fi
     fi
   fi
   ```
   단, BSD awk match() 3-arg 미지원 → `match() + RSTART/RLENGTH + substr()` pattern 또는 `grep -oE` + 후처리 사용:
   ```zsh
   prd_us_list=$(grep -oE '^##[[:space:]]+US-[0-9]+([[:space:]:-]|$)' "$PRD_FILE" 2>/dev/null | grep -oE 'US-[0-9]+' | sort -u)
   ```
2. `src/scripts/run_ralph_desk.zsh:2425-2429` final ALL verify scope — US_LIST 만 신뢰 (signal_us_id US_LIST 에 없으면 무시 + warn).
3. `src/node/runner/campaign-main-loop.mjs` — 동등 처리.
4. governance §7a — cross-mission us_id leak 방어 + quarantine path 명시.

**검증 (us022)**:
- AC1: init 단계 stale us_id detect + quarantine helper (grep + behavioural)
- AC2: zsh runner final ALL verify US_LIST 신뢰
- AC3: governance §7a 텍스트 정합 + quarantine path
- AC4: behavioural — fixture mission PRD (US-001~003) + stale signal us_id=US-005 → SIGNAL_FILE quarantine 이동, .sisyphus/quarantine/ 에 파일 존재
- **AC5 (Architect issue #4)**: rm -f 사용 안 함 (`grep -n "rm -f.*SIGNAL_FILE" src/scripts/init_ralph_desk.zsh` = 0)
- **AC6 (Critic R10)**: PRD heading variation fixture (`## US-005 -`, `## US-005:`, `## US-005`) → 모두 정상 인식 (false positive 0)

### Fix R11: P2-K — Cost log non-empty + trap-based final write + early-exit inventory

**대상 (Critic R11 + Architect issue #6 patches)**:
1. `src/scripts/lib_ralph_desk.zsh:367` write_cost_log — note 필드 (bytes=0 시 'no_actual_usage_recorded').
2. **`src/scripts/run_ralph_desk.zsh` (Architect issue #6)** — main loop 진입 직후 trap 등록:
   ```zsh
   trap '_emit_final_cost_log' EXIT
   _emit_final_cost_log() {
     [[ -n "${ITERATION:-}" ]] && [[ "${COST_LOG_FINAL_WRITTEN:-0}" -eq 0 ]] && {
       write_cost_log "$ITERATION" 2>/dev/null || true
       COST_LOG_FINAL_WRITTEN=1
     }
   }
   ```
3. **Early-exit path inventory (Critic R11 + Architect NEW-2)** — us023 회귀가 다음 broadened grep 결과의 모든 path 가 trap coverage 내인지 검증:
   ```bash
   grep -nE '^[[:space:]]*(exit\b|return\b|die\b)' src/scripts/run_ralph_desk.zsh src/scripts/lib_ralph_desk.zsh | grep -v '^[^:]*:[^:]*:.*\${' > early_exits.txt
   ```
   `die` wrapper 함수가 `lib_ralph_desk.zsh` 에 정의된 경우 명시적으로 trap 우회 분석 + 회귀에 포함.
4. (init placeholder 삭제 — Architect issue #6) — 빈 cost-log 가 "broken logging" 으로 감지되도록 normal path 만 보강.
5. governance §7 Cost Tracking — tmux estimated path + trap 명시.

**검증 (us023)**:
- AC1: write_cost_log 에 note 필드 (bytes=0 시 'no_actual_usage_recorded')
- AC2: zsh runner 에 `trap '_emit_final_cost_log' EXIT` 존재 (grep)
- AC3: behavioural — write_cost_log 호출 후 cost-log.jsonl 비어있지 않음
- **AC4 (Critic R11)**: early-exit grep inventory + 모든 path 가 trap coverage 검증 (스크립트 내 모든 `exit N` 또는 `return N` 위치 grep + trap fire 시점 비교)
- **AC5 (Architect issue #6)**: init placeholder 코드 부재 (grep `placeholder.*cost-log` = 0)

---

## 자가검증 시나리오 — Mechanical per-row (v2)

`tests/test_self_verification_0_11_handoff.sh` — 7 함수 + 각 함수 내 pre/post + grep 증명:

```bash
test_r5_a4_audit_triggered() {
  local audit="$LOGS_DIR/a4-fallback-audit.jsonl"
  local pre=$(wc -l < "$audit" 2>/dev/null || echo 0)
  # Trigger: simulate done-claim without iter-signal
  echo '{"us_id":"US-001","status":"complete"}' > "$DESK/memos/${SLUG}-done-claim.json"
  rm -f "$DESK/memos/${SLUG}-iter-signal.json"
  # NEW-1 (Architect): zsh fixture invocation (run_ralph_desk.zsh is zsh, NOT bash)
  # us017 implementation MUST extract A4 fallback into a callable helper in lib_ralph_desk.zsh
  # so it can be sourced cleanly. Until then, use zsh -c with explicit DESK/SLUG/ITERATION exports.
  zsh -c "DESK='$DESK' SLUG='$SLUG' ITERATION=1 LOGS_DIR='$LOGS_DIR' source src/scripts/lib_ralph_desk.zsh; _emit_a4_fallback_audit US-001 1" 2>/dev/null
  local post=$(wc -l < "$audit" 2>/dev/null || echo 0)
  [[ "$post" -gt "$pre" ]] || { fail "R5 A4 audit not triggered (pre=$pre post=$post)"; return 1; }
  # Mechanical: grep that the patched code path was exercised
  grep -q "a4_fallback" "$audit" || { fail "R5 audit entry missing"; return 1; }
  pass "R5 A4 fallback audit triggered ($pre→$post)"
}

test_r6_test_density_warn() {
  # Fixture: PRD with 3 ACs, test-spec with 1 test
  local stderr_capture=$(./init_ralph_desk.zsh --slug test-r6 --prd fixtures/r6-bad-prd.md 2>&1)
  echo "$stderr_capture" | grep -q "Test density warning" || { fail "R6 init exit message missing warning"; return 1; }
  pass "R6 test density warning emitted to stderr"
}

# ... R7~R11 동일 패턴: 각 함수가 (1) pre-state 캡처, (2) 변경 코드 직접 invoke, (3) post-state grep 검증
```

| Fix | 시나리오 | Mechanical 증명 |
|---|---|---|
| R5 P0-D | done-claim 작성 + iter-signal 누락 → A4 fallback 발동 | `wc -l a4-fallback-audit.jsonl` pre/post 비교 + entry grep |
| R6 P1-F | test-spec AC 3개 + test 1개 fixture | stderr 의 "Test density warning" 라인 grep |
| R7 P1-G | iter-signal status=verify_partial fixture (정상 + malformed) | verifier prompt grep `verified_acs only` + malformed → blocked sentinel meta.reason='verify_partial_malformed' |
| R8 P1-H | blocked sentinel + memory.md unchanged 5min+ | sentinel JSON sidecar `meta.blocked_hygiene_violated=true` jq 추출 |
| R9 P2-I | 동일 reason 3회 BLOCK + canonicalization + edge cases | mission-abort.json 존재 + jq `.count==3` + first-iter exempt fixture CONSECUTIVE_BLOCKS=0 검증 |
| R10 P2-J | PRD US-001~003 + stale signal us_id=US-005 + heading variation | `.sisyphus/quarantine/iter-signal.*.json` 존재 + 원본 SIGNAL_FILE 부재 + 3 variation fixture 정상 인식 |
| R11 P2-K | tmux mode 5 iter run + early-exit fixture | `cost-log.jsonl` 행 수 ≥ 5 + 모두 note 필드 보유 + trap fire 검증 |

**Pass criterion**: 7/7 mechanical 증명 + 각 fix 가 변경된 함수/파일을 실제 호출했음을 grep 으로 확인 (tautology 방지).

---

## 변경 대상 파일 표

```
src/scripts/init_ralph_desk.zsh        # R5(worker prompt), R6(test density lint + flag), R7(Signal rules + verifier prompt), R8(blocked exit hygiene), R10(stale us_id quarantine)
src/scripts/run_ralph_desk.zsh         # R5(A4 audit), R6(--test-density-strict), R7(verify_partial parsing), R9(consecutive_blocks + canonical + exempt), R10(US_LIST scope), R11(trap)
src/scripts/lib_ralph_desk.zsh         # R8(write_blocked_sentinel hygiene_violated), R11(write_cost_log note + bytes=0 path)
src/node/run.mjs                       # R6(--test-density-strict stub)
src/node/runner/campaign-main-loop.mjs # R7(verify_partial parser + malformed downgrade), R8(_checkBlockedHygiene), R9(consecutive_blocks state), R10(stale us_id scrub)
src/governance.md                      # R5(§1f A4 metric), R6(§7f Test Density), R7(§7g Signal Vocabulary + malformed), R8(§1f 5th channel), R9(§8 cb + canonicalization + exempt), R10(§7a quarantine)

[테스트]
tests/test_us017_a4_fallback_audit.sh
tests/test_us018_test_density.sh
tests/test_us019_verify_partial.sh
tests/test_us020_blocked_hygiene.sh
tests/test_us021_consecutive_blocks.sh
tests/test_us022_cross_mission_us_leak.sh
tests/test_us023_cost_log_nonempty.sh
tests/test_self_verification_0_11_handoff.sh   # mechanical per-row
```

## 검증 (Self-Verification Gate)

1. **LOW** — `zsh -n` + `node --check` (~10s)
2. **MEDIUM** — us017~us023 7 신규 회귀 (~3min)
3. **CRITICAL** — us001/us007/us012/us013/us014/us015/us016 회귀 무손실 (~3min)
4. **자가검증 매핑 시나리오** — `test_self_verification_0_11_handoff.sh` 7/7 mechanical 증명

## 단일 PR 진행 결정 (사용자 명시 시)

사용자가 PR split 거부 + 단일 PR 명시한 경우:
- R5+R6+R7 (protocol) + R8+R9+R10+R11 (runtime) 단일 PR
- self-verification 시나리오는 양 영역 모두 포함하므로 보장 유지
- 단, codex review iteration 5+ 도달 시 split fallback 자동 트리거

## ADR (간결)

- **Decision**: 7건 fix. v2 patches: PR split 권고 (사용자 명시 시 단일), R7 schema fallback (verify_partial_malformed downgrade), R8 helper-side hygiene check, R9 canonical reason + edge exempt, R10 normalized extractor + quarantine, R11 trap-based final write + early-exit inventory, self-verification mechanical per-row.
- **Drivers**: silent failure 가시화 + backward-compat + minimal blast radius + mechanical self-verification.
- **Alternatives considered (각 R 별 v1 표 + v2 새 patches)**.
- **Consequences**: PR-A 먼저 머지 + soak → PR-B (권고). 단일 PR 도 가능. Worker prompt 길이 약간 증가. test-spec WARN 다수 발생 가능 (점진 strict 화).
- **Follow-ups**: test-density STRICT 의 default 화 (v0.12+), verify_partial deferred_acs 자동 우선 재시도, A4 fallback 0% 시 hard fail.
