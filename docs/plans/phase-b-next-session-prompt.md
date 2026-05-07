Phase B 진행 (PR-B1부터 시작) — ralplan 완료, plan v3 APPROVED.

배경:
- v0.15.3까지 완료. Phase F (real-LLM SV gate 10/10 coverage) 종결됨.
- v0.15.x stabilization 트랙. 신규 기능 금지, 기존 거동 강화만.
- omc는 benchmark이지 replacement 아님. rlp-desk 자율주행 장점(multi-engine consensus / multi-mission queue / BLOCK_TAGS / structured SV)은 보존.
- 이전 세션에서 ralplan(Planner→Architect→Critic codex) 완료. 2 iteration 후 Codex Critic APPROVE (P0+P1=0).

확정된 plan:
- 파일: docs/plans/v0.15-phase-b-plan-v3.md (이 파일을 먼저 읽어 plan 전체 파악)
- 결정: Option A — 4개 separate PR을 B1 → B2-FIX → B4 → B3 순서로 진행
- 핵심 차이 (원래 prompt 대비):
  - B2가 "invariant test only"가 아니라 B2-FIX (done-claim sentinel reaper 실제 substrate fix + 회귀 test)
  - 순서 재배치 (substrate fix → observability → SV)
  - B1에 Phase 0 5-iter dry-run baseline measurement 추가 (B3 tolerance bands 입력)
  - bug-06은 structural 유지 ($0), deterministic injection은 PR-B5로 deferred
  - B3 value assertions는 release-blocking, 같은 PR에 ship

이번 세션 시작 작업: PR-B1 (lifecycle audit + Phase 0 baseline)

스텝 1: 브랜치 + 사전 체크
- feat/v0.15-phase-b1-lifecycle-audit 브랜치 생성
- bash tests/sv-gate-fast.sh → 48/48 PASS 확인 (freeze stamp용)
- npm test → 339/339 PASS 확인 (freeze stamp용)
- git rev-parse HEAD → SHA 기록

스텝 2: docs/plans/v0.15-phase-b-lifecycle-audit.md 작성
- §1 Inventory: tmux send-keys 60+ call sites in run_ralph_desk.zsh / ~10 in lib_ralph_desk.zsh / 2 in pane-manager.mjs. Group by purpose (interrupt/exit/command/prompt/clear).
- §2 Table 1 (sentinel write-attribution): iter-signal/verdict/done-claim/blocked/complete × Producer × Reaper today × Reaper needed × Action
- §3 Table 2 (B4 metric proposal): 5 metric × source × tolerance band initial × emission rule
- §4 Table 3 (Phase 0 baseline) — 일단 placeholder; 스텝 3에서 채움
- §5 ASCII diagrams: D1 worker dispatch race, D2 sentinel ordering, D3 recovery handshake
- §6 Cross-reference: race window → existing fix → gap (B2-FIX targets)
- §7 Freeze stamp: SHA + sv-gate-fast 48/48 + Node suite 339/339 + 검증 commands

스텝 3: Phase 0 baseline measurement
- temporary throwaway 패치 작성 (in-branch only, NOT merged): debug-log.mjs + lib_ralph_desk.zsh에 5종 metric 임시 emission. RLP_LIFECYCLE_METRICS=1 게이트.
- 5-iter sandbox campaign 실행 (작은 fixture PRD)
- jq로 metric 수집, p50/p95 계산
- Table 3에 결과 + provenance 기록 (patch diff, 실행 command, discard 방법)
- 패치 revert 또는 별도 commit으로 격리 (절대 audit doc과 함께 merge 금지)

스텝 4: 검증 + PR
- bash tests/sv-gate-fast.sh → 48/48 PASS (변경 없음)
- npm test → 339/339 PASS (변경 없음)
- 로컬 commit (user 승인 필요)
- git push (user 승인 필요)
- gh pr create (user 승인 필요)
- codex review APPROVE까지 반복 (user 승인 후 merge)

규칙 (CLAUDE.md ABSOLUTE):
- P0+P1 = 0 까지 codex review 통과 (이미 plan은 APPROVE; PR 자체는 별도 review 필요)
- 작업 전 feature 브랜치 생성 (no direct main commit)
- self-verification gate: B1은 init/run/governance 미접촉 → trio 의무 미발동 (plan v3 §Self-verification 참조)
- npm publish / push / commit 모두 user 명시 승인 필요 (auto는 안 함)

사전 체크:
- docs/plans/v0.15-phase-b-plan-v3.md 를 먼저 끝까지 읽고 plan 전체 파악
- 현재 브랜치 main 확인, 변경사항 없음 확인
- 위 4개 스텝 실행 전 사용자에게 진행 방향 확인

DoD (PR-B1):
- AC1.1-AC1.5 (Tables 1-3, 3 diagrams, Phase 0 baseline + provenance, freeze stamp, no merged code change)
- codex review APPROVE
- sv-gate-fast 48/48 + Node suite 339/339 유지

후속 PR (이번 세션 scope 아님):
- PR-B2-FIX: lib_ralph_desk.zsh + run_ralph_desk.zsh + pane-manager.mjs done-claim reaper 확장 + 8+ invariant test
- PR-B4: debug-log.mjs LIFECYCLE 카테고리 + log_lifecycle_metric helper + RLP_LIFECYCLE_METRICS flag + campaign.jsonl shape contract test
- PR-B3: bug-05/07 two-stage assertion (presence + value) + bug-06 structural retained
- v0.15.4 release: 4개 PR merge 후 user 승인하에 npm publish + GitHub release
