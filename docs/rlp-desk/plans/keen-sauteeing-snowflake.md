# CB 정합성 수정 + 분석 로그 항상 생성

## Context

1. CB_THRESHOLD=3에서 모델 업그레이드 경로(3~4단계) 작동 불가 — 설계 결함
2. campaign.jsonl, metadata.json이 `--debug` 전용 — 기본 실행에서 분석 데이터 없음
3. campaign.jsonl에 분석에 필요한 필드 부족 (consecutive_failures, model_upgraded 등)

---

## 변경 1: CB_THRESHOLD 기본값 3 → 6

**파일**: `src/scripts/run_ralph_desk.zsh:75`

```diff
- CB_THRESHOLD="${CB_THRESHOLD:-3}"
+ CB_THRESHOLD="${CB_THRESHOLD:-6}"
```

**파일**: `src/governance.md` §8 — CB 기본값 6 반영

---

## 변경 2: campaign.jsonl, metadata.json 항상 생성 (debug 게이팅 제거)

### 2a. analytics 디렉토리 항상 생성

**파일**: `src/scripts/run_ralph_desk.zsh` (~L1890)

```diff
- # --- Analytics directory: create only when --debug or --with-self-verification ---
- if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
-   mkdir -p "$ANALYTICS_DIR" 2>/dev/null
- fi
+ # --- Analytics directory: always create (campaign.jsonl + metadata.json are always-on) ---
+ mkdir -p "$ANALYTICS_DIR" 2>/dev/null
```

### 2b. metadata.json 항상 작성

**파일**: `src/scripts/run_ralph_desk.zsh` (~L1915-1940)

```diff
- # --- metadata.json: write at campaign start ---
- if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
-   jq -n \
-     ...
- fi
+ # --- metadata.json: always write at campaign start (cross-project identification) ---
+ jq -n \
+   ...
+   --arg project_name "$(basename "$ROOT")" \
+   ...
```

metadata.json에 `project_name` 필드 추가 (basename of ROOT).

### 2c. write_campaign_jsonl() debug 게이팅 제거

**파일**: `src/scripts/lib_ralph_desk.zsh:356`

```diff
- write_campaign_jsonl() {
-   if (( ! DEBUG )) && (( ! WITH_SELF_VERIFICATION )); then return 0; fi
+ write_campaign_jsonl() {
```

### 2d. campaign.jsonl 레코드에 분석 필드 추가

**파일**: `src/scripts/lib_ralph_desk.zsh` write_campaign_jsonl()

추가 필드:
- `consecutive_failures`: 현재 연속 실패 카운트
- `model_upgraded`: 이 iteration에서 모델 업그레이드 발생 여부 (0/1)
- `fix_contract`: 이전 iteration의 fix contract 존재 여부 (0/1)

```diff
  '{iter: $iter, us_id: $us_id, worker_model: $worker_model, ...}'
+ 에 --argjson consecutive_failures "$CONSECUTIVE_FAILURES"
+    --argjson model_upgraded "$_MODEL_UPGRADED"
```

### 2e. campaign.jsonl 버전 관리도 항상 적용

**파일**: `src/scripts/run_ralph_desk.zsh` (~L1904-1913)

```diff
- # --- campaign.jsonl versioning (in analytics dir, after mkdir) ---
- if (( DEBUG )) || (( WITH_SELF_VERIFICATION )); then
-   if [[ -f "$CAMPAIGN_JSONL" ]]; then
+ # --- campaign.jsonl versioning (always-on) ---
+ if [[ -f "$CAMPAIGN_JSONL" ]]; then
```

debug.log 버전 관리는 `--debug` 게이팅 유지 (debug.log 자체가 debug 전용이므로).

---

## 변경 3: `--with-self-verification` SV report 경로 버그 수정

**현재 버그:** SV report 경로 불일치
- **쓰기** (`lib_ralph_desk.zsh:553-556`): `$LOGS_DIR/self-verification-report-NNN.md` (프로젝트 로컬)
- **읽기** (`lib_ralph_desk.zsh:434`): `$ANALYTICS_DIR/self-verification-report-*.md` (홈)
- 쓰는 곳과 읽는 곳이 다르므로 campaign-report.md에서 SV report 참조 실패

**수정:** 읽기 경로를 `$LOGS_DIR`로 통일 (프로젝트 로컬이 맞음 — iteration 아티팩트를 분석한 결과물)

**파일**: `src/scripts/lib_ralph_desk.zsh:434`

```diff
-     sv_report=$(ls -t "$ANALYTICS_DIR"/self-verification-report-*.md 2>/dev/null | head -1)
+     sv_report=$(ls -t "$LOGS_DIR"/self-verification-report-*.md 2>/dev/null | head -1)
```

**governance §6 문서에서도 정리:**
- `self-verification-report-NNN.md` → 프로젝트 로컬 `logs/<slug>/` 에 명시
- `self-verification-data.json` → 코드에서 생성 안 함 (governance §6에만 명시, agent-mode 전용). 문서에서 "(agent-mode only)" 주석 추가

### `--with-self-verification` 파일 위치 정리

| 파일 | 위치 | 생성 조건 | 용도 |
|------|------|-----------|------|
| `self-verification-report-NNN.md` | 프로젝트 로컬 `logs/<slug>/` | `--with-self-verification` | claude CLI로 iteration 아티팩트 분석한 서술형 리포트 |
| `self-verification-data.json` | 홈 `analytics/<slug>--<hash>/` | agent-mode + `--with-self-verification` | 구조화된 SV 데이터 (tmux 모드에서는 생성 안 됨) |

---

## 변경하지 않는 것

| 항목 | 위치 | 이유 |
|------|------|------|
| `iter-NNN.*` 전체 | 프로젝트 로컬 | 프로젝트 코드/git과 직접 연결 |
| `campaign-report.md` | 프로젝트 로컬 | git diff stat 참조 |
| `cost-log.jsonl` | 프로젝트 로컬 | campaign-report가 참조 |
| `runtime/` | 프로젝트 로컬 | 실시간 운영 데이터 |
| `baseline.log` | 프로젝트 로컬 | 프로젝트 기준점 |
| `SV report` | 프로젝트 로컬 | iteration 아티팩트 분석 결과물 |
| `debug.log` | 홈, `--debug` 전용 | verbose, 필요할 때만 |

---

## 수정 대상 파일

| 파일 | 변경 |
|------|------|
| `src/scripts/run_ralph_desk.zsh` | CB default 6, analytics dir 항상 생성, metadata.json 항상 쓰기 + project_name, campaign.jsonl 버전 관리 항상 적용 |
| `src/scripts/lib_ralph_desk.zsh` | write_campaign_jsonl() debug 게이팅 제거 + 필드 추가, SV report 읽기 경로 수정 |
| `src/governance.md` | §8 CB 기본값 6, §6 파일 구조 + SV 위치 정리 |

---

## Verification (TDD)

모든 변경은 **테스트 먼저 작성 → RED 확인 → 구현 → GREEN 확인** 순서로 진행.

테스트 파일: `tests/test_cb_and_analytics.sh`

### 테스트 목록 (RED → GREEN 순서대로)

**변경 1: CB_THRESHOLD**
```bash
# T1: CB 기본값이 6인지 확인
test_cb_default_is_6() {
  source src/scripts/run_ralph_desk.zsh --dry-run 2>/dev/null  # 또는 grep
  assert CB_THRESHOLD == 6
}

# T2: consensus 모드에서 effective CB가 12(6*2)인지 확인
test_cb_consensus_doubles_to_12() {
  VERIFY_CONSENSUS=1 source ...
  assert EFFECTIVE_CB_THRESHOLD == 12
}
```

**변경 2: campaign.jsonl 항상 생성**
```bash
# T3: --debug 없이 analytics 디렉토리 생성 확인
test_analytics_dir_created_without_debug() {
  DEBUG=0 WITH_SELF_VERIFICATION=0
  # run init section → assert mkdir -p "$ANALYTICS_DIR" called
  assert -d "$ANALYTICS_DIR"
}

# T4: --debug 없이 metadata.json 생성 확인
test_metadata_written_without_debug() {
  DEBUG=0 WITH_SELF_VERIFICATION=0
  # run metadata write section
  assert -f "$METADATA_FILE"
}

# T5: metadata.json에 project_name 필드 존재
test_metadata_has_project_name() {
  assert jq -r '.project_name' "$METADATA_FILE" != "null"
}

# T6: write_campaign_jsonl()이 --debug 없이 쓰는지 확인
test_campaign_jsonl_written_without_debug() {
  DEBUG=0 WITH_SELF_VERIFICATION=0
  write_campaign_jsonl 1 "US-001" "pass"
  assert -f "$CAMPAIGN_JSONL"
}

# T7: campaign.jsonl 레코드에 consecutive_failures 필드 존재
test_campaign_jsonl_has_consecutive_failures() {
  CONSECUTIVE_FAILURES=2
  write_campaign_jsonl 1 "US-001" "fail"
  assert jq -r '.consecutive_failures' last_line == 2
}

# T8: campaign.jsonl 레코드에 model_upgraded 필드 존재
test_campaign_jsonl_has_model_upgraded() {
  _MODEL_UPGRADED=1
  write_campaign_jsonl 1 "US-001" "fail"
  assert jq -r '.model_upgraded' last_line == 1
}

# T9: campaign.jsonl 재실행 시 버전 관리 (--debug 없이)
test_campaign_jsonl_versioned_without_debug() {
  echo '{}' > "$CAMPAIGN_JSONL"
  # run versioning section
  assert -f "${CAMPAIGN_JSONL%.jsonl}-v1.jsonl"
}
```

**변경 3: SV report 경로 수정**
```bash
# T10: generate_campaign_report()가 $LOGS_DIR에서 SV report 찾는지 확인
test_sv_report_read_from_logs_dir() {
  WITH_SELF_VERIFICATION=1
  touch "$LOGS_DIR/self-verification-report-001.md"
  # generate_campaign_report 호출
  # campaign-report.md 안에 $LOGS_DIR 경로의 SV report 참조 확인
  assert grep "self-verification-report" "$LOGS_DIR/campaign-report.md"
}
```

### 실행 순서

1. 테스트 파일 작성 (`tests/test_cb_and_analytics.sh`)
2. 전체 RED 확인 (모든 테스트 fail)
3. 변경 1 구현 → T1, T2 GREEN
4. 변경 2 구현 → T3~T9 GREEN
5. 변경 3 구현 → T10 GREEN
6. governance 문서 업데이트
7. 기존 테스트 회귀 확인: `bash tests/test_us005_tmux_docs.sh`
