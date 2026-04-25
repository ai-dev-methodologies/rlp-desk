# Plan: rlp-desk Batch Mode + Operational Context 개선

## Context

실제 캠페인(`prod-local-parity`, spark:high)에서 두 가지 구조적 문제가 발견됨:

1. **Batch 모드 무한 FAIL**: US 5개 이상이면 Worker가 일부만 완료 → Verifier가 전체 검증 → FAIL → 진전 무시 → CB BLOCKED. `VERIFIED_US` 추적이 per-us 모드에만 있고 batch에는 없음.

2. **서버 프로젝트 지원 부재**: Worker가 코드 수정 후 서버 restart를 안 하고, 서버 포트를 모르고, health check도 없음. spark 모델 탓이 아니라 **rlp-desk가 operational context를 brainstorm/prompt에 반영하지 않는 설계 결함**.

---

## P0: Batch 모드 Partial Progress Tracking

### 수정 대상
- `src/scripts/run_ralph_desk.zsh`
- `src/commands/rlp-desk.md` (agent mode ⑦c)

### 변경 내용

#### 1. Batch 모드에도 VERIFIED_US 추적 (run_ralph_desk.zsh)
- PASS verdict 처리(L2423): `per-us` 조건 제거 → batch에서도 `signal_us_id`가 개별 US면 `VERIFIED_US`에 추가
- FAIL verdict 처리(L2445): verdict JSON에서 `per_us_results` 파싱 → `met=true`인 US를 `VERIFIED_US`에 추가
- status.json 갱신: batch 모드에서도 `verified_us` 배열 기록

#### 2. Verifier Prompt에 VERIFIED_US 전달 (run_ralph_desk.zsh L1225-1232)
- `if [[ "$VERIFY_MODE" = "per-us"` 조건 → `if [[ -n "$VERIFIED_US"` 로 변경
- batch 모드 verifier에게도 "이미 verified된 US skip" 지시

#### 3. Fix Contract Scope Narrowing (run_ralph_desk.zsh L2461-2473)
- FAIL 시: verdict에서 pass한 US 추출 → fix contract에 "US-001~004 verified. Continue from US-005."
- Worker prompt 조합 시 `VERIFIED_US` 참조하여 축소된 scope 전달

#### 4. consecutive_failures 부분 리셋 (run_ralph_desk.zsh L2447)
- 새로 pass된 US가 있으면 (`VERIFIED_US` 길어짐) → `CONSECUTIVE_FAILURES=0` 리셋
- 진전 없이 같은 상태면 → 기존대로 증가

#### 5. Verifier Verdict에 per_us_results 필수화
- Verifier prompt template(init_ralph_desk.zsh L384-474)에 output format 추가:
  ```json
  {
    "verdict": "fail",
    "per_us_results": { "US-001": "pass", "US-005": "fail" },
    "issues": [...]
  }
  ```
- batch/per-us 공통으로 per_us_results 포함하도록 지시

---

## P1: Brainstorm Operational Context + Worker System Prompt

### 수정 대상
- `src/commands/rlp-desk.md` (brainstorm section)
- `src/scripts/init_ralph_desk.zsh` (Worker/Verifier prompt template)

### 변경 내용

#### 1. Brainstorm: Operational Context 수집 (rlp-desk.md L24-93)
현재 11개 항목 수집 중, **12번째 항목 추가**:

```
12. **Operational Context** (if applicable):
    - Does this project require a running server/service? (y/n)
    - Server start command (e.g., `npm run dev`, `python manage.py runserver`)
    - Server port (e.g., 7001)
    - Health check URL (e.g., `http://localhost:7001/health`)
    - Other runtime dependencies (e.g., database, Redis)
```

brainstorm이 프로젝트 디렉토리에서 `package.json`의 `scripts.dev`/`scripts.start`, `Makefile`, `docker-compose.yml` 등을 자동 감지하여 추천.

#### 2. Brainstorm: US 생성 시 Operational Step 포함 가이드
US/AC 작성 가이드(rlp-desk.md L26-38)에 추가:

```
- If the project has operational context (server, DB, etc.):
  - Each US that modifies server code MUST include AC:
    "Given server is running, When code is modified, Then server is restarted and responds on health check URL"
  - Do NOT assume Worker will restart server on its own — spell it out in AC
```

#### 3. Init: Worker Prompt에 Operational Rules 주입 (init_ralph_desk.zsh L285-380)
brainstorm에서 수집한 operational context를 Worker prompt template에 주입:

```markdown
## Operational Context
- **Server Command**: `npm run dev`
- **Server Port**: 7001
- **Health Check**: `http://localhost:7001/health`

### Operational Rules (always apply)
- After modifying server/application code, restart the server: `[server_cmd]`
- Before signaling done, verify server responds: `curl -s [health_url] || fail`
- Do NOT modify dependency files (package.json, requirements.txt, etc.) unless the AC explicitly requires it
- Do NOT run package install commands (npm install, pip install, etc.) unless the AC explicitly requires it
```

operational context가 없는 프로젝트(코드만 수정)면 이 섹션 생략.

#### 4. Init: Verifier Prompt에도 Operational Check 추가
Verifier prompt template(init_ralph_desk.zsh L384-474)에:

```markdown
## Operational Verification (if server context provided)
- Verify server is running on expected port before checking ACs
- If server is down, verdict=FAIL with issue: "server not running"
```

#### 5. --server-cmd / --server-port CLI 옵션 (run_ralph_desk.zsh)
brainstorm에서 수집한 값을 init이 prompt에 넣지만, run 시 override도 가능:
- `--server-cmd "npm run dev"` → Worker prompt의 서버 명령어 override
- `--server-port 7001` → Worker prompt의 포트 override
- 런타임에 iteration 시작 시 health check (optional, `--server-health-check` flag)

---

## Verification Plan

### P0 Tests
```bash
# Batch partial progress 단위 테스트
zsh tests/test_batch_partial_progress.sh
# 시나리오: batch FAIL verdict에 per_us_results 포함 → VERIFIED_US 추적 확인
# 시나리오: 새 US pass 시 consecutive_failures 리셋 확인
# 시나리오: verifier prompt에 VERIFIED_US 포함 확인 (batch 모드)
```

### P1 Tests
```bash
# Operational context 단위 테스트
zsh tests/test_operational_context.sh
# 시나리오: --server-cmd 옵션 파싱 확인
# 시나리오: Worker prompt에 operational rules 주입 확인
# 시나리오: operational context 없는 프로젝트에서는 섹션 생략 확인
```

### Self-Verification (CLAUDE.md 필수)
변경된 src 파일에 대해 3개 시나리오 (LOW/MEDIUM/CRITICAL) 자체 검증 실행.

### E2E
실제 캠페인으로 테스트:
1. batch 모드 + 10 US → partial progress 추적 확인
2. server 프로젝트 + spark:high → 서버 restart 수행 확인

---

## File Map

| 파일 | P0 | P1 |
|------|----|----|
| `src/scripts/run_ralph_desk.zsh` | VERIFIED_US batch 추적, fix contract narrowing, CF 리셋 | --server-cmd/port 옵션 |
| `src/scripts/lib_ralph_desk.zsh` | - | - |
| `src/scripts/init_ralph_desk.zsh` | - | Worker/Verifier prompt에 operational context 주입 |
| `src/commands/rlp-desk.md` | agent mode ⑦c batch 로직 | brainstorm 12번 항목, US 가이드 |
| `src/governance.md` | - | - |

---

## Scope / Non-Goals
- 모델별 가드레일 (spark 전용 금지 목록) → **하지 않음**. brainstorm/prompt 구조로 해결
- batch 모드 완전 제거 → **하지 않음**. 수정하여 사용 가능하게 함
- auto-detect project type → brainstorm에서 사용자 확인 + 파일 기반 추천만. 완전 자동화 아님
