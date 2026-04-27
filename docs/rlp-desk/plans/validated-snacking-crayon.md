# Plan: Flywheel Phase 1 — SV Report Generation + Brainstorm Feedback Loop

## Context

rlp-desk의 flywheel 아키텍처(governance §8½ + brainstorm step 0)가 설계되어 있지만 구현이 끊겨 있다.
`--with-self-verification` 플래그가 파싱되지만 실제 SV 리포트 생성 코드가 없고, brainstorm step 0도 SV 리포트를 읽는 로직이 없다.

**목표:** 캠페인 A → SV 리포트 생성 → 캠페인 B brainstorm이 A의 패턴 참조 — 최소한의 피드백 루프 완성.

**브랜치:** `feature/flywheel-sv-report`

---

## Current State (Gap Analysis)

| 구성요소 | 상태 | 위치 |
|----------|------|------|
| `--with-self-verification` 플래그 파싱 | ✅ | run.mjs:142-144 |
| 10섹션 SV 리포트 템플릿 정의 | ✅ | rlp-desk.md:522-573 |
| §8½ 피드백 루프 정의 | ✅ | governance.md:629-635 |
| Brainstorm step 0 정의 | ✅ | rlp-desk.md:115 |
| `generateSVReport()` 함수 | ❌ | 존재하지 않음 |
| campaign-main-loop.mjs에서 SV 호출 | ❌ | svSummary 파라미터 안 전달 (465, 568, 590) |
| analytics 디렉토리 생성 | ❌ | 코드 없음 |
| SV 리포트 테스트 | ❌ | us007에 없음 |

---

## Changes

### Change 1: `generateSVReport()` 함수 구현
**File:** `src/node/reporting/campaign-reporting.mjs` (확장)

기존 `generateCampaignReport()` (line 159) 옆에 `generateSVReport()` 추가.

**Input:**
- `slug` — campaign slug
- `logsDir` — `.claude/ralph-desk/logs/<slug>/` (done-claim, verify-verdict 파일 위치)
- `prdFile` — PRD 경로
- `testSpecFile` — test-spec 경로
- `analyticsFile` — campaign.jsonl 경로
- `outputDir` — `~/.claude/ralph-desk/analytics/<slug>/` (SV 리포트 출력)

**로직:**
1. `logsDir`에서 `iter-*-done-claim.json`, `iter-*-verify-verdict.json` 파일 수집
2. done-claim에서 execution_steps 파싱 → Worker Process Quality 집계
3. verify-verdict에서 reasoning 파싱 → Verifier Judgment Quality 집계
4. campaign.jsonl에서 per-iteration 요약 → Automated Validation Summary
5. AC lifecycle 추적 (first claimed, first verified, reopen count)
6. 10섹션 마크다운 생성
7. `outputDir/self-verification-report-NNN.md`에 버전드 파일 쓰기
8. `outputDir/self-verification-data.json`에 구조화 데이터 쓰기

**10섹션 구현 우선순위:**
- 필수 (핵심 피드백): §1 Automated Validation, §3 Worker Process Quality, §7 Patterns, §8 Recommendations
- 중요 (진단): §2 Failure Deep Dive, §4 Verifier Quality, §5 AC Lifecycle
- 보조 (참고): §6 Test-Spec Adherence, §9 Cost, §10 Blind Spots

**Return:** `{ reportPath, version, summary }` — summary는 generateCampaignReport()의 svSummary 파라미터로 전달

### Change 2: campaign-main-loop.mjs에 SV 생성 연결
**File:** `src/node/runner/campaign-main-loop.mjs` lines 465, 568, 590

현재 `generateCampaignReport()` 호출 3곳에서:
1. `options.withSelfVerification` 체크
2. true면 `generateSVReport()` 호출
3. 결과의 summary를 `svSummary` 파라미터로 전달

**Before (현재):**
```javascript
await generateCampaignReport({
  slug, reportFile, prdFile, statusFile, analyticsFile, now
});
```

**After:**
```javascript
let svSummary = 'N/A — --with-self-verification not enabled';
if (options.withSelfVerification) {
  const sv = await generateSVReport({
    slug, logsDir: paths.logsDir, prdFile: paths.prdFile,
    testSpecFile: paths.testSpecFile, analyticsFile: paths.analyticsFile,
    outputDir: paths.analyticsDir,
  });
  svSummary = sv.summary;
}
await generateCampaignReport({
  slug, reportFile, prdFile, statusFile, analyticsFile, now, svSummary
});
```

### Change 3: analytics 디렉토리 생성
**File:** `src/node/runner/campaign-main-loop.mjs` (초기화 단계)

캠페인 시작 시 `~/.claude/ralph-desk/analytics/<slug>/` 디렉토리 생성.
- slug에 `--<root_hash>` 접미사 추가 (cross-project 충돌 방지, rlp-desk.md:248 스펙)
- metadata.json 초기 작성

**paths 객체에 추가:**
```javascript
analyticsDir: join(homeDir, '.claude/ralph-desk/analytics', `${slug}--${rootHash}`),
```

### Change 4: Brainstorm Step 0 SV Report Feedback 구현
**File:** `src/commands/rlp-desk.md` brainstorm section (line 115 area)

현재 step 0은 한 줄 설명만 있음. 구체적 실행 절차 추가:

```markdown
0. **SV Report Feedback** — If a prior campaign's self-verification report exists:
   a. Scan `~/.claude/ralph-desk/analytics/` for directories matching this project root
   b. Read the latest `self-verification-report-*.md` from each matching directory
   c. Extract from §7 (Patterns) and §8 (Recommendations):
      - Which US types/sizes failed most frequently
      - Which AC quality dimensions scored lowest
      - Which model tiers underperformed for this project's complexity
      - Specific brainstorm/PRD/test-spec recommendations from prior campaigns
   d. Present findings to user: "Prior campaign analysis found: [patterns]. Recommendations: [suggestions]."
   e. If no prior reports exist, skip and note "No prior campaign data available."
```

---

## Implementation Sequence

| Wave | Changes | Files | Dependency |
|------|---------|-------|------------|
| 1 | Change 1 (generateSVReport) | campaign-reporting.mjs | None |
| 1 | Change 3 (analytics dir) | campaign-main-loop.mjs + paths.mjs | None |
| 2 | Change 2 (SV 호출 연결) | campaign-main-loop.mjs | Change 1, 3 |
| 3 | Change 4 (brainstorm step 0) | rlp-desk.md | Change 1 (reports exist) |

Wave 1은 병렬 가능 (서로 독립).
Wave 2는 Wave 1 완료 후.
Wave 3는 별도 — rlp-desk.md만 수정.

---

## TDD Plan

### 테스트 파일: `tests/node/test-sv-report.mjs` (새로 생성)

**Change 1 테스트:**
- T1.1: done-claim + verify-verdict 파일에서 10섹션 리포트 생성
- T1.2: 빈 logs 디렉토리 → graceful 처리 (빈 리포트)
- T1.3: Worker Process Quality §3 — TDD compliance % 정확성
- T1.4: Verifier Judgment Quality §4 — reasoning completeness % 정확성
- T1.5: AC Lifecycle §5 — reopen count 추적
- T1.6: Patterns §7 + Recommendations §8 — 패턴 추출
- T1.7: 버전드 파일 쓰기 (NNN 증가)
- T1.8: self-verification-data.json 구조 검증

**Change 2 테스트:**
- T2.1: withSelfVerification=false → svSummary 기본값
- T2.2: withSelfVerification=true → generateSVReport 호출됨

**Change 3 테스트:**
- T3.1: analytics 디렉토리 생성 확인
- T3.2: metadata.json 구조 검증

**Change 4 테스트:**
- T4.1: rlp-desk.md에 step 0 실행 절차 존재 (grep)

---

## Verification

### TDD Flow
1. 테스트 작성 → RED (generateSVReport 없으므로)
2. Change 1 구현 → 테스트 GREEN
3. Change 3 구현 → analytics dir 테스트 GREEN
4. Change 2 구현 → 연결 테스트 GREEN
5. Change 4 구현 → grep 테스트 GREEN

### E2E Verification
1. 테스트 프로젝트에서 campaign 실행 (with-self-verification 플래그)
2. `~/.claude/ralph-desk/analytics/<slug>/self-verification-report-001.md` 생성 확인
3. 리포트에 10섹션 존재 확인
4. 두 번째 campaign brainstorm에서 첫 캠페인 패턴 참조 확인

### Self-Verification Gate
governance.md 변경 없음 (§8½는 이미 정의됨). rlp-desk.md만 변경.
init_ralph_desk.zsh 변경 없으면 2시나리오만 필요:
- LOW: SV 리포트 없는 상태에서 brainstorm → "No prior data" 스킵
- MEDIUM: SV 리포트 있는 상태에서 brainstorm → 패턴 참조

---

## Critical Files

| File | Changes |
|------|---------|
| `src/node/reporting/campaign-reporting.mjs` | Change 1: generateSVReport() 추가 |
| `src/node/runner/campaign-main-loop.mjs` | Change 2: SV 호출 연결, Change 3: analytics dir |
| `src/node/shared/paths.mjs` | Change 3: analyticsDir path 추가 |
| `src/commands/rlp-desk.md` | Change 4: brainstorm step 0 절차 확장 |
| `tests/node/test-sv-report.mjs` | 새로 생성 — SV 리포트 테스트 |

### Reuse 가능한 기존 코드
- `versionFile()` (campaign-reporting.mjs:47-60) — 버전드 파일 쓰기
- `readAnalytics()` (campaign-reporting.mjs:70-80) — campaign.jsonl 파싱
- `readJsonIfExists()` (campaign-reporting.mjs:62-68) — JSON 안전 읽기
- `summarizeUsStatus()` (campaign-reporting.mjs:91-96) — US 상태 집계
- `summarizeVerificationResults()` (campaign-reporting.mjs:98-102) — 검증 결과 집계
