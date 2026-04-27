# Plan: rlp-desk 옵션 인터페이스 정리 + brainstorm/init 추천 보강

## Context

rlp-desk 옵션이 유기적으로 성장하면서 20개+로 늘어남. 중복, 충돌, 미구분 문제 발생:
- `--worker-engine`, `--worker-codex-model`, `--worker-codex-reasoning`은 `--worker-model`이 이미 통합 처리 (parse_model_flag)
- consensus 옵션 3중 충돌 (`--verify-consensus`, `--final-consensus`, `--consensus-scope`)
- per-US Verifier vs Final Verifier 구분 없음
- brainstorm 모델 추천이 2열(Worker/Verifier)만 있어 per-US/Final 구분 안 됨
- gpt-5.3-codex 경로가 유저 결정 없이 코드에 존재
- brainstorm/init에서 정책 기반 추천이 부족 (batch capacity, spark vs gpt-5.4 기준 등)

## 근거 문서

| 근거 | 위치 | 핵심 내용 |
|------|------|----------|
| 검증 철학 | `memory/feedback_verification_philosophy.md` | 기본값: haiku/sonnet/opus, per-US 가볍게, final 엄격, cross-engine 추천 |
| CB threshold | `memory/feedback_cb_threshold_six.md` | CB=6 확정, claude 3단계 커버 |
| 모델 구분 | `memory/feedback_no_assumption.md` | spark=Pro 적극 추천, gpt-5.4=fallback, gpt-5.3-codex 미확정 |
| Task sizing | `memory/feedback_us_size_limit.md` | Worker comfortable zone 안에 분할 |
| 현행 옵션 | `src/commands/rlp-desk.md:186-207` | 현재 20개+ 옵션 목록 |
| parse_model_flag | `src/scripts/lib_ralph_desk.zsh:38-57` | `모델명`=claude, `모델명:추론`=codex 통합 파싱 |
| get_next_model | `src/scripts/lib_ralph_desk.zsh:81-110` | 엔진별 업그레이드 경로 |
| check_model_upgrade | `src/scripts/lib_ralph_desk.zsh:116-168` | Worker만 상향, Verifier 고정 |

---

## 최종 옵션 (14개)

### 1. 실행

| # | 옵션 | 고정 기본값 | 설명 |
|---|------|------------|------|
| 1 | `--mode agent\|tmux` | `agent` | agent=LLM Leader, tmux=shell Leader |

### 2. Worker

| # | 옵션 | 고정 기본값 | 포맷 | 설명 |
|---|------|------------|------|------|
| 2 | `--worker-model` | `haiku` | `haiku` 또는 `spark:high` | `모델명`=claude, `모델명:추론`=codex. parse_model_flag()가 engine/model/reasoning 자동 분리 |
| 3 | `--lock-worker-model` | off | flag | 실패 시 자동 모델 업그레이드(check_model_upgrade) 비활성화 |

### 3. Verifier (per-US)

| # | 옵션 | 고정 기본값 | 포맷 | 설명 |
|---|------|------------|------|------|
| 4 | `--verifier-model` | `sonnet` | `sonnet` 또는 `gpt-5.4:high` | per-US 검증 모델. 캠페인 내내 고정 (progressive upgrade 없음) |

### 4. Verifier (final ALL)

| # | 옵션 | 고정 기본값 | 포맷 | 설명 |
|---|------|------------|------|------|
| 5 | `--final-verifier-model` | `opus` | `opus` 또는 `gpt-5.4:high` | final ALL 검증 모델. 미지정 시 opus 고정 (per-US와 독립) |

### 5. Consensus

| # | 옵션 | 고정 기본값 | 설명 |
|---|------|------------|------|
| 6 | `--consensus` | `off` | `off`: 단일 엔진 / `all`: 매 verify 교차 / `final-only`: final ALL에서만 교차 |
| 7 | `--consensus-model` | `gpt-5.4:medium` | per-US 교차 verifier. 가볍게 |
| 8 | `--final-consensus-model` | `gpt-5.4:high` | final 교차 verifier. 엄격하게. spark 불가(100k limit) |

consensus 동작:

| 상황 | 주 verifier | 교차 verifier |
|------|------------|--------------|
| per-US, 주=claude | `--verifier-model` (sonnet) | `--consensus-model` (gpt-5.4:medium) |
| per-US, 주=codex | `--verifier-model` (gpt-5.4:high 등) | claude `opus` 고정 |
| final, 주=claude | `--final-verifier-model` (opus) | `--final-consensus-model` (gpt-5.4:high) |
| final, 주=codex | `--final-verifier-model` (gpt-5.4:high 등) | claude `opus` 고정 |

- 양쪽 모두 pass해야 통과. 엔진 우선권 없음.
- spark는 consensus 교차에 사용 불가 (100k output limit).

### 6. 검증 전략

| # | 옵션 | 고정 기본값 | 설명 |
|---|------|------------|------|
| 9 | `--verify-mode` | `per-us` | `per-us`: US마다 검증→final ALL / `batch`: 전부 후 한번에 |

### 7. 안전장치

| # | 옵션 | 고정 기본값 | 설명 |
|---|------|------------|------|
| 10 | `--cb-threshold` | `6` | 연속 fail N회 → BLOCKED. consensus 시 자동 ×2 (=12) |
| 11 | `--max-iter` | `100` | 최대 iteration → TIMEOUT |
| 12 | `--iter-timeout` | `600` | iteration당 timeout 초 (tmux만 적용) |

### 8. 로깅/분석

| # | 옵션 | 고정 기본값 | 설명 |
|---|------|------------|------|
| 13 | `--debug` | off | `~/.claude/ralph-desk/analytics/<slug>/debug.log` |
| 14 | `--with-self-verification` | off | campaign 후 SV 리포트 → 다음 brainstorm 피드백(§8½) |

---

## 제거 옵션 (내부 구현으로 숨김)

| 제거 옵션 | 대체 방법 |
|-----------|----------|
| `--worker-engine` | `--worker-model` 포맷에서 자동 추론 |
| `--worker-codex-model` | `--worker-model spark:high`에 포함 |
| `--worker-codex-reasoning` | `--worker-model spark:high`에 포함 |
| `--verifier-engine` | `--verifier-model` 포맷에서 자동 추론 |
| `--verifier-codex-model` | `--verifier-model`에 포함 |
| `--verifier-codex-reasoning` | `--verifier-model`에 포함 |
| `--verify-consensus` | `--consensus all` |
| `--final-consensus` | `--consensus final-only` |
| `--consensus-scope` | `--consensus`에 통합 |
| `--consensus-fail-fast` | 제거 (복잡도 대비 가치 낮음) |

내부적으로 env var (`WORKER_ENGINE`, `WORKER_CODEX_MODEL` 등)는 유지 — `parse_model_flag()`가 `--worker-model`에서 분리하여 설정.

---

## Brainstorm 모델 추천 구조 (신규)

### Claude-only (codex 미설치)

| 복잡도 | Worker | per-US Verifier | Final Verifier | Consensus |
|--------|--------|----------------|----------------|-----------|
| LOW | haiku | sonnet | opus | off |
| MEDIUM | sonnet | opus | opus | off |
| HIGH | opus | opus | opus | off |
| CRITICAL | opus | opus | opus + human | off |

### Cross-engine (codex 설치, ★ 추천)

| 복잡도 | Worker | per-US Verifier | Final Verifier | Consensus |
|--------|--------|----------------|----------------|-----------|
| LOW | spark:high | sonnet | opus | final-only |
| MEDIUM | spark:high | opus | opus | final-only |
| HIGH | gpt-5.4:high | opus | opus | all |
| CRITICAL | gpt-5.4:high | opus | opus + human | all |

Worker 모델 선택 기준:
- **spark:high** — 기본 추천. Pro 토큰풀 분리 = 비용 절감. PRD AC ≤ 15개
- **gpt-5.4:high** — spark 100k output limit 초과 시 fallback. PRD AC > 15개

### Brainstorm 추천 예시 (codex 있을 때)

```
★ 추천: cross-engine + final-consensus
/rlp-desk run <slug> --mode tmux --worker-model spark:high --consensus final-only --debug

대규모 PRD (spark 100k 초과):
/rlp-desk run <slug> --mode tmux --worker-model gpt-5.4:high --consensus final-only --debug

극도로 중요 (전체 consensus):
/rlp-desk run <slug> --mode tmux --worker-model gpt-5.4:high --consensus all --debug

claude-only:
/rlp-desk run <slug> --debug
```

---

## Batch Capacity Check (신규)

brainstorm에서 batch 모드 + 대규모 PRD 감지 시 자동 경고:

| 조건 | 경고 | 제안 |
|------|------|------|
| batch + spark + AC > 10 | "spark 100k output limit 주의" | wave split 또는 gpt-5.4 전환 |
| batch + gpt-5.4 + AC > 15 | "단일 batch에 AC 과다" | wave split (US 3-4개씩 묶음) |
| per-us + 어떤 모델이든 | 경고 없음 | US별 처리라 limit 문제 없음 |

---

## 확정 사항

1. **교차 verifier claude 기본값**: `opus` 확정 (주 verifier가 codex일 때)
2. **gpt-5.3-codex 경로**: get_next_model()에서 **제거** 확정 (spark + gpt-5.4만 유지)
3. **`--verifier-model` 기본값**: `sonnet` (per-US 가볍게, feedback_verification_philosophy.md)
4. **`--consensus-model` 기본값**: `gpt-5.4:medium` (per-US 교차, 가볍게)
5. **`--final-consensus-model` 기본값**: `gpt-5.4:high` (final 교차, 엄격하게)
6. **교차 claude** (주 verifier가 codex일 때): `opus` 고정

---

## Brainstorm/Init 추천 흐름 (보강)

brainstorm 단계 7~8번을 아래로 교체:

### brainstorm step 7: 모델 추천

1. 복잡도 평가 (5-factor table, 현행 유지)
2. codex 설치 여부 확인 (`command -v codex`)
3. **4열 추천 테이블 제시** (Worker / per-US Verifier / Final Verifier / Consensus)
4. spark vs gpt-5.4 판단: AC 총 개수 세어서
   - AC ≤ 15 → spark:high 추천 ("Pro 토큰풀 분리, 비용 절감")
   - AC > 15 → gpt-5.4:high 추천 ("spark 100k output limit 초과")
5. verify-mode가 batch이면 batch capacity check 실행 (아래 참조)

### brainstorm step 8 (init 후 명령어 제시): 추천 순서

codex 있을 때:
```
★ 추천: cross-engine + final-consensus (비용 절감 + blind-spot 커버)
/rlp-desk run <slug> --mode tmux --worker-model spark:high --consensus final-only --debug

대규모 PRD (AC > 15, spark limit 초과):
/rlp-desk run <slug> --mode tmux --worker-model gpt-5.4:high --consensus final-only --debug

극도로 중요 (매 US 교차검증):
/rlp-desk run <slug> --mode tmux --worker-model gpt-5.4:high --consensus all --debug

claude-only (교차검증 없음):
/rlp-desk run <slug> --debug
```

codex 없을 때:
```
★ 추천:
/rlp-desk run <slug> --mode tmux --debug

⚠️ codex 미설치 — 같은 엔진은 같은 blind spot을 공유합니다.
cross-engine 교차검증: npm install -g @openai/codex
```

### init 후 옵션 설명

init 완료 후 명령어 제시 시 아래 설명 포함:

```
옵션 설명:
  --worker-model          Worker 모델 (haiku|sonnet|opus 또는 spark:high|gpt-5.4:high)
  --verifier-model        per-US 검증 모델 (기본: sonnet, 가볍게)
  --final-verifier-model  final ALL 검증 모델 (기본: opus, 엄격하게)
  --consensus             교차검증 (off|all|final-only)
  --consensus-model       per-US 교차 모델 (기본: gpt-5.4:medium)
  --final-consensus-model final 교차 모델 (기본: gpt-5.4:high)
```

---

## 변경 대상 파일

| 파일 | 변경 내용 |
|------|----------|
| `src/commands/rlp-desk.md` | 옵션 14개로 정리, brainstorm 추천 4열 테이블, batch capacity check, init 추천 예시 보강 |
| `src/governance.md` | consensus 섹션 정리, `--final-verifier-model` + `--final-consensus-model` 문서화, §7b 교차검증 테이블 |
| `src/scripts/run_ralph_desk.zsh` | `--consensus` 통합 플래그, `--final-verifier-model`, `--final-consensus-model` 파싱, deprecated 옵션 경고 |
| `src/scripts/lib_ralph_desk.zsh` | gpt-5.3-codex 경로 제거 (spark + gpt-5.4만 유지) |
| `README.md` | 옵션 레퍼런스 테이블 14개로 갱신, 추천 예시, per-US/final 구분 설명 |

## 검증

1. 기존 테스트 regression: `bash tests/test_cb_and_analytics.sh && bash tests/test_us004_progressive_upgrade.sh && bash tests/test_v052_improvements.sh`
2. 신규 테스트: `tests/test_option_cleanup.sh` — 옵션 파싱, 기본값, deprecated 경고
3. `zsh -n` syntax check
4. Self-verification 3 scenarios (CLAUDE.md gate)
