# Hotfix: Revert keybinding changes from init_ralph_desk.zsh

**Created**: 2026-03-30
**Updated**: 2026-03-30 (Phase 1-4 구현 완료, 커밋 대기)
**Branch**: main (v0.5.0, 커밋 대기 변경 +89 lines)

---

## Context

v0.5.0 코드는 main에 머지 + push 완료. npm publish와 gh release만 남음. lib_ralph_desk.zsh 추출 완료 (internal refactoring, semver 변경 불필요). 이 계획은 master issue list의 미해결 항목 전체를 다룸.

---

## Phase 0: npm publish v0.5.0 (보류 — 유저 요청 시)

1. `gh release create v0.5.0` (user-facing release notes)
2. `npm publish`
3. Local file sync 확인

---

## Phase 1: 검증 필요 항목 (구현됨, 실전 테스트 미완)

### A14/A15: init --mode improve (test-spec 보존 + sentinel 정리)
- **상태**: v05 캠페인에서 구현, test_a14a15_init_improve.sh 존재
- **필요**: 실제 `--mode improve` 시나리오 수동 테스트로 동작 확인
- **파일**: `src/scripts/init_ralph_desk.zsh`

### A18: zombie runner lockfile
- **상태**: lockfile 로직 구현됨 (8 references in run_ralph_desk.zsh)
- **필요**: 실전 캠페인에서 중복 실행 방지 검증
- **파일**: `src/scripts/run_ralph_desk.zsh`

---

## Phase 2: HIGH 우선순위 이슈

### A10: "edit its own settings" permission prompt 블로킹
- **문제**: Claude Code가 자체 settings 수정 시 permission 프롬프트 발생 → Worker 블로킹
- **근본 원인**: `--dangerously-skip-permissions`로도 우회 불가
- **접근**: Claude Code 측 해결 대기 or Worker prompt에 settings 수정 금지 규칙 강화
- **파일**: `src/commands/rlp-desk.md` (Worker prompt), `src/governance.md`
- **크기**: SMALL (prompt 변경만)

### C4: /rlp-desk status 상세 보고
- **문제**: 현재 status가 빈약 — 현재 US, 시도 횟수, 실패 원인, 실패 주체 미표시
- **접근**: status.json에 이미 필드 존재 → rlp-desk.md status 서브커맨드에서 파싱 + 표시
- **파일**: `src/commands/rlp-desk.md` (status 섹션)
- **TDD**: `tests/test_status_detail.sh` 신규
- **크기**: MEDIUM

### B3/B4: 런타임 per-US document splitting
- **문제**: init에서 PRD/test-spec 분할은 완료됐지만, run 중 Worker prompt에 해당 US만 주입하는 로직 미완
- **접근**: write_worker_trigger()에서 per-US PRD/test-spec 파일 존재 시 해당 파일만 inject
- **파일**: `src/scripts/run_ralph_desk.zsh` (write_worker_trigger), `src/scripts/lib_ralph_desk.zsh` (inject_per_us_prd 이미 존재 확인 필요)
- **TDD**: 기존 test_us002_perus_inject.sh 확장
- **크기**: MEDIUM

---

## Phase 3: MEDIUM 우선순위 이슈

### A16: tmux foreground 실행 충돌
- **문제**: run_ralph_desk.zsh를 foreground로 실행하면 Claude Code pane과 충돌
- **접근**: rlp-desk.md에서 run_in_background 필수 명시 + foreground 감지 시 경고
- **파일**: `src/commands/rlp-desk.md`, `src/scripts/run_ralph_desk.zsh`
- **크기**: SMALL

### D1/D2: rlp-desk resume 서브커맨드
- **문제**: 캠페인 중단 후 재시작 시 verified_us 복원 안 됨
- **접근**: status.json에서 verified_us 읽어 복원 + resume 서브커맨드 추가
- **파일**: `src/commands/rlp-desk.md` (resume 섹션), `src/scripts/run_ralph_desk.zsh` (--resume 플래그)
- **TDD**: `tests/test_resume.sh` 신규
- **크기**: MEDIUM

---

## Phase 4: LOW 우선순위 / Backlog

### A5: Rate limit 후 pane 오염 — ✅ 구현됨 (미커밋)
- poll_for_signal에서 "queued messages" 감지 시 pane C-c + /exit 자동 실행

### C3: Agent mode campaign.jsonl — ✅ 구현됨 (미커밋)
- rlp-desk.md ⑧ 섹션에 campaign.jsonl APPEND 지시 추가

### F8: --consensus-fail-fast — ✅ 구현됨 (미커밋)
- CONSENSUS_FAIL_FAST 환경변수 + claude fail 시 codex skip 로직

### F9: rlp-desk analytics 서브커맨드 — ✅ 스텁 추가 (미커밋)
- rlp-desk.md에 analytics 서브커맨드 문서화 (실제 구현은 Agent mode LLM이 해석)

### A17: logs/ 디렉토리 구조 리팩토링 — ❌ 미착수
- **크기**: LARGE (경로 참조 수십 곳 변경)
- **다음 세션으로 보류**

---

## 실행 순서 (권장)

```
Phase 0: npm publish (유저 요청 시)
Phase 1: A14/A15 + A18 실전 검증 (수동 테스트, 코드 변경 없음)
Phase 2: C4 → B3/B4 → A10 (순서대로, 각각 독립)
Phase 3: A16 → D1/D2
Phase 4: Backlog (필요 시)
```

Phase 2의 C4, B3/B4, A10은 독립적이므로 병렬 가능.

---

## Verification

- 각 Phase 완료 후: `for f in tests/test_*.sh; do bash "$f" || exit 1; done`
- 신규 기능: TDD (test 먼저, RED 확인, 구현, GREEN 확인)
- CLAUDE.md 규칙: 커밋 전 유저 승인, npm publish 전 유저 승인
