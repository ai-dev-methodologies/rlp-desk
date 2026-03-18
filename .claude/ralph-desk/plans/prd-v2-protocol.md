# PRD: v2-protocol

## Objective
RLP Desk v1 프로토콜에 비판적 분석 결과를 반영하여 v2로 개선한다.
핵심 원칙: **Markdown 유지, 관심사 분리, 도구 기반 검증, 비용 효율**.

## Project Root
`/Users/kyjin/dev/own/ai-dev-methodologies/rlp-desk/.worktrees/v2-protocol`

## Target Files
- `src/governance.md` — 핵심 프로토콜 문서
- `docs/protocol-reference.md` — 프로토콜 상세 스펙
- `src/commands/rlp-desk.md` — 슬래시 커맨드 스펙
- `src/scripts/init_ralph_desk.zsh` — scaffold 생성기
- `docs/architecture.md` — 아키텍처 문서 (minor)

## User Stories

### US-001: Enhanced Memory Format
- **Priority**: P0
- **Size**: S
- **Depends on**: []
- **Description**: campaign memory를 Markdown 유지하면서 구조를 개선한다. YAML 전환은 하지 않는다.
- **Acceptance Criteria**:
  - [ ] `protocol-reference.md`의 Campaign Memory 스펙에 `## Completed Stories` 섹션 추가 (id + 1줄 summary, 선택적 interface sub-bullet)
  - [ ] `## Next Iteration Contract`에 `**Criteria**:` 하위 항목이 포함된 예시 추가
  - [ ] `## Key Decisions` 섹션 추가 (iteration, decision, reason을 free-text로)
  - [ ] 기존 `## Patterns Discovered`, `## Learnings`, `## Evidence Chain` 섹션은 유지
  - [ ] YAML 형식 언급이 protocol-reference.md에 없음 (memory는 Markdown)
  - [ ] governance.md §7의 "Read memory.md" 단계에 새 섹션 파싱 설명 추가
- **Status**: not started

### US-002: Leader Loop - Prep-stage Cleanup & Post-execution Log
- **Priority**: P0
- **Size**: S
- **Depends on**: []
- **Description**: iteration 시작 시 런타임 파일 정리 (방어적 패턴). iteration 후 결과 로그 추가.
- **Acceptance Criteria**:
  - [ ] governance.md §7 루프 시작에 "Clean previous done-claim.json, verify-verdict.json" 단계 추가 (① 직후, ② 직전)
  - [ ] protocol-reference.md Leader Loop에 동일 변경 반영
  - [ ] rlp-desk.md의 `run` 커맨드 루프에 동일 변경 반영
  - [ ] 로그 디렉토리에 `iter-NNN.result.md` 형식 정의 추가 (Result status + Files Changed via git diff --stat)
  - [ ] result.md에 authorship label 명시: `[leader-measured]`, `[git-measured]`
  - [ ] 3개 문서(governance, protocol-reference, rlp-desk.md) 간 루프 단계 번호가 일관됨
- **Status**: not started

### US-003: Circuit Breaker Enhancement
- **Priority**: P0
- **Size**: S
- **Depends on**: []
- **Description**: 연속 실패 3회(서로 다른 에러) CB 추가. status.json에 consecutive_failures 카운터 추가. "같은 issue" 판별을 criterion 기반으로 명확화.
- **Acceptance Criteria**:
  - [ ] governance.md §8에 새 CB 추가: "3 consecutive failures (different errors) → upgrade to opus → retry once → BLOCKED"
  - [ ] protocol-reference.md Circuit Breakers 테이블에 동일 추가
  - [ ] rlp-desk.md Circuit Breaker 섹션에 동일 추가
  - [ ] protocol-reference.md status.json 스펙에 `consecutive_failures: 0` 필드 추가
  - [ ] "같은 에러" 판별 기준이 "동일 acceptance criterion이 2회 연속 fail"로 명시됨
  - [ ] 3개 문서 간 CB 조건/동작이 일관됨
- **Status**: not started

### US-004: Verifier Independence Reform
- **Priority**: P0
- **Size**: M
- **Depends on**: []
- **Description**: Verifier의 scope 식별을 git diff 기반으로 변경. 3-state verdict 도입. issues에 severity 추가. deterministic 검사는 도구에 위임.
- **Acceptance Criteria**:
  - [ ] protocol-reference.md Verifier 섹션에 "scope 식별: `git diff --name-only` 사용" 명시
  - [ ] memory.md를 "orientation 참고만 가능, source of truth 아님" 으로 명시
  - [ ] verify-verdict.json 스펙에 `"verdict": "pass|fail|request_info"` (3-state)
  - [ ] `request_info`의 의미 정의: "판단 불가 시 구체적 질문을 남기고 Leader가 결정"
  - [ ] issues 배열에 `"severity": "critical|major|minor"` 필드 추가
  - [ ] "확신 없으면 fail" 규칙이 제거됨
  - [ ] "deterministic 검사(type hints, linting, 보안)는 test-spec의 도구에 위임" 명시
  - [ ] "Verifier는 AC 검증 + semantic 리뷰 + smoke test에 집중" 명시
  - [ ] governance.md §2 Verifier 역할에 위 변경 반영
  - [ ] rlp-desk.md의 Verifier 실행 단계에서 `request_info` 분기 추가: Leader가 Worker에게 전달하거나 직접 판단
- **Status**: not started

### US-005: Fix Loop Protocol
- **Priority**: P1
- **Size**: M
- **Depends on**: [US-003, US-004]
- **Description**: Verifier fail 시 구조화된 수정 루프 정의. Leader가 issues를 구조화해서 Worker에게 전달.
- **Acceptance Criteria**:
  - [ ] governance.md에 "Fix Loop Protocol" 섹션 추가 (§7과 §8 사이 또는 §7 내부)
  - [ ] Fix Loop 흐름 정의: Verifier fail → Leader가 verdict issues 읽기 → severity 순 정렬 → next contract에 구조화된 issues 전달
  - [ ] next contract의 fix 모드 예시: issues 목록 + "수정에 필요한 변경만 허용 (모든 변경은 issue 해결에 대한 정당화 필요)" (traceability rule)
  - [ ] fix_hint는 `(suggestion, non-authoritative)` 표시와 함께 optional로 명시
  - [ ] consecutive_failures 카운터가 status.json에서 Leader가 관리하는 것으로 명시
  - [ ] protocol-reference.md에 Fix Loop 상세 스펙 추가
  - [ ] rlp-desk.md의 Verifier 실행 후 fail 분기에 Fix Loop 참조 추가
- **Status**: not started

### US-006: Worker Prompt Template Enhancement
- **Priority**: P1
- **Size**: S
- **Depends on**: [US-001]
- **Description**: init 스크립트의 worker prompt 템플릿에 "Before You Start" 섹션과 scope 규칙 추가.
- **Acceptance Criteria**:
  - [ ] init_ralph_desk.zsh의 worker prompt에 "Before you start" 섹션 추가
  - [ ] 읽기 순서: 1. Campaign Memory → 2. PRD → 3. Test Spec → 4. Latest Context
  - [ ] 3가지 scope 규칙 추가: (1) 프로젝트 루트 밖 파일 금지, (2) 프롬프트 파일 수정 금지, (3) next contract에 없는 작업 금지
  - [ ] "iteration 완료 시 변경사항 커밋" 규칙 추가
  - [ ] 기존 "Required reads", "Iteration rules", "Stop behavior" 섹션과 충돌 없음
- **Status**: not started

### US-007: Verifier Prompt Template Enhancement
- **Priority**: P1
- **Size**: S
- **Depends on**: [US-004]
- **Description**: init 스크립트의 verifier prompt 템플릿을 US-004 개혁에 맞게 업데이트.
- **Acceptance Criteria**:
  - [ ] "If uncertain, verdict = fail" 규칙이 제거됨
  - [ ] "If uncertain, verdict = request_info (구체적 질문을 summary에 기술)" 로 대체
  - [ ] "scope 식별: `git diff --name-only`로 변경 파일 확인 후 해당 파일 + 관련 imports만 읽기" 추가
  - [ ] "Campaign Memory는 orientation 참고만 가능" 명시
  - [ ] verdict JSON에 `request_info` 추가, issues에 `severity` 필드 추가
  - [ ] "Smoke test 실행" 단계 추가 (PRD에 정의된 경우)
- **Status**: not started

### US-008: Scaffold & Template Updates
- **Priority**: P2
- **Size**: S
- **Depends on**: [US-001, US-006, US-007]
- **Description**: init 스크립트의 memory, context, PRD 템플릿을 새 형식에 맞게 업데이트.
- **Acceptance Criteria**:
  - [ ] Memory 템플릿에 `## Completed Stories`, `## Key Decisions` 섹션 추가
  - [ ] PRD 템플릿의 User Story에 `- **Depends on**: []` 필드 추가
  - [ ] PRD 템플릿의 User Story에 `- **Size**: S|M|L` 필드 추가
  - [ ] status.json 초기값에 `consecutive_failures: 0` 포함되도록 문서화
  - [ ] 선택적 `plans/quality-spec-<slug>.md` 파일 언급 (init에서 생성하진 않되 문서에서 설명)
  - [ ] 예시 프로젝트(examples/calculator)의 템플릿은 이번 scope에서 제외 (Non-Goal)

## Non-Goals
- YAML memory 형식 도입
- Rolling summary (최근 N개만 상세)
- Python-specific coding standards를 프로토콜에 하드코딩
- Architecture diagram을 worker prompt에 포함
- Verifier가 전체 소스 파일 읽기
- LLM이 type hints/linting/보안 검사 직접 수행
- examples/calculator 업데이트
- tmux-runner 관련 변경

## Technical Constraints
- 모든 변경은 기존 파일의 수정 (새 파일 최소화)
- 3개 핵심 문서(governance, protocol-reference, rlp-desk.md) 간 일관성 필수
- 기존 v1 프로토콜의 핵심 원칙(fresh context, filesystem=memory, Worker claim≠complete) 유지
- init 스크립트 변경 시 기존 프로젝트 호환성 유지 (이미 존재하는 파일은 덮어쓰지 않음)

## Done When
- 모든 acceptance criteria 통과
- 3개 핵심 문서 간 일관성 확인
- init 스크립트가 새 템플릿을 올바르게 생성
- Independent verifier가 확인
