# rlp-desk 전략 재평가 — autoplan 입력

> **목표**: rlp-desk를 계속 발전시킬지(patch/redesign), 폐기 후 재구성할지(rebuild), 기존 도구로 pivot할지 결정.
> **핵심 KPI**: blueprint 처음 → 끝 자율 완료. 사람 개입 최소.
> **현재 상태**: 6주간 10개 bug, 매주 1-2개 신규 발견, manual recovery마저 broken (#10).

---

## 1. Vision (BOS dev 합의, 2026 초)

1. ralph-loop를 **fresh-context**로 매번 시작 (컨텍스트 오염 없음)
2. idea → plan distillation
3. PRD 정형화
4. Worker/Verifier 사이클로 반복 개선
5. **완전 자율화** — 사람 개입 최소

→ 5번이 단일 success criterion. 1-4는 5번을 달성하기 위한 메커니즘.

---

## 2. Reality — 6주간 측정된 사실

### Bug 발생 패턴

| # | 일자 | 카테고리 | 회수 가능 | 다음 fix가 노출한 다음 bug |
|---|---|---|---|---|
| #1 | 2026-05-01 | LLM-runtime (`.claude/` self-modification gate) | partial — codex worker로 우회 | #2 (tmux session) |
| #2 | 2026-05-01 | tmux session lifecycle | yes | #3 |
| #3 | 2026-05-04 | verifier no-progress | yes | #4 (regression of #3) |
| #4 | 2026-05-05 | #3 regression | partial | #5 |
| #5 | 2026-05-05 | worker dead on reuse (pane lifecycle) | yes | #6 |
| #6 | 2026-05-06 | claude worker idle false-positive | yes | #7 |
| #7 | 2026-05-06 | post-sentinel process race (1m43s drift) | yes | #8 + #10 |
| #8 | 2026-05-06 | worker incomplete + leader A4 fallback | partial | #10 |
| #9 | (별도) | verified_us 영속성 (status.json) | yes | — |
| #10 | 2026-05-07 | leader ignores phase=verify on relaunch — **회수마저 깨짐** | NO (이게 회수 메커니즘) | ? |

**Pattern observed:**
- 매주 1-2개 신규 bug
- 절반은 **이전 fix가 노출**한 새 failure mode (regression style)
- Bug #10이 가장 심각 — 회수 메커니즘 자체가 broken → BLOCKED 시 operator의 manual recovery가 무효화

### Bug 카테고리 분류

| 카테고리 | Bug | 비중 | architectural 필연성? |
|---|---|---|---|
| (a) tmux/process lifecycle race | #2, #5, #6, #7 | 40% | **YES** — tmux pane lifecycle은 claude/codex TUI lifecycle과 분리됨. race window가 본질적 |
| (b) artifact contract / schema | #3, #4, #8, #9 | 40% | partial — schema가 더 strict하면 줄어들지만 LLM이 schema 어기는 빈도가 본질적 |
| (c) LLM-runtime constraint | #1 | 10% | **YES** — Claude Code의 `.claude/` self-modification gate는 외부 변수 |
| (d) recovery hygiene | #10 | 10% | accidental — fix 가능 |

→ **80%가 architectural inevitability** (a + c). schema strict + retry는 (b)를 줄이지만 LLM 비결정성이 한계.

### SV gate 한계

- 모든 sv-self-verify-*.sh가 **Worker/Verifier metaphor만 사용** → 실제 LLM agent run 없음
- grep + unit test + regression의 5-category labeling
- → 10개 bug가 SV gate 통과 후 production에서 발견됐다는 사실 = **framework이 production failure mode를 cover 못 함**
- Production failure mode는 **LLM/tmux/network/timing 비결정성** — unit test로 잡을 수 없는 영역

### In-flight 미완 branch

- `feat/native-agent-revert`: P0(Bug #7 fix) + P1(slash native prose 회복) — 미완. Plan: 5 round ralplan 합의됨, codex critic APPROVED
- `feat/bug10-relaunch-hygiene`: PR-A commit 95c0d4e + SV gate 추가 — 방금 완료, push 안 됨

→ 두 branch 모두 land 안 됨 = 새 bug 발견 시 기존 fix가 무력화될 위험

---

## 3. 4가지 옵션

### Option A — Continue patching (현재 path)
PR-A (Bug #10) → PR-B (bundler) → PR-C (patterns) → 다음 bug → 반복.

### Option B — Fundamental redesign (vision 유지, architecture 재설계)
**핵심 변경**: tmux pane orchestration 폐기 → Claude Code Native Agent() / subprocess 직접 dispatch. Sentinel file → in-memory channel. 두 변경으로 (a) 카테고리 80%가 제거.

### Option C — Scrap and rebuild (vision 일부 수정)
6주 코드 폐기. Vision 5번 (완전 자율화)은 유지하되 1번(fresh-context)은 task-isolated subprocess로 재정의. ralph-loop 자체 폐기 가능 — 그냥 plan→worker→verify 사이클로 단순화.

### Option D — Pivot to existing tool
- ralph plugin (cradle): 가벼움, 기능 부족
- omc (oh-my-claudecode): /ralph + /ralplan + /omc-teams + /autopilot — 이미 multi-model orchestration 있음
- superpowers: subagent-driven-development, executing-plans, brainstorming — plan→exec 사이클은 이미 있음
- claude-devfleet: dmux 기반, multi-agent

---

## 4. 평가 항목 (각 옵션마다)

| 항목 | 정의 | 이유 |
|---|---|---|
| Vision 보존도 | 5개 vision 중 살아남는 개수 | "완전 자율화" 달성 가능성 |
| Time-to-first-successful-blueprint | 처음으로 blueprint를 끝까지 자율 완료하는 데 걸리는 시간 | **단일 핵심 KPI** |
| Sunk cost write-off % | 폐기되는 코드/SV 비율 | 결정의 reversibility |
| Bug regression 위험 | 새 시스템에서 #1-#10 같은 bug가 다시 나올 확률 | "다음 6주에 또 10개?" |
| Personal capacity ROI | 1주 투자 시 deliverable | sustainability |

---

## 5. In-flight branch 처리 결정

이 평가가 끝난 후 결정:
- `feat/native-agent-revert`: land / abandon / re-scope?
- `feat/bug10-relaunch-hygiene`: 이미 commit 95c0d4e, push할까 hold할까?

선택 옵션이 무엇이든 두 branch는 처리 필요.

---

## 6. 제약

- BOS dev가 실제 캠페인을 돌려야 함 → short-term (1-2주) patching 불가피
- rlp-desk는 npm published — breaking change는 user-facing (semver 고려)
- 분석은 advisory only — 실제 코드 수정/commit/push는 사용자 승인 별도

---

## 7. autoplan에 요구 — 이 문서를 입력으로

CEO 관점: rlp-desk가 푸는 문제가 옳은가? 다른 도구로 같은 가치를 이미 얻을 수 있나?
Eng 관점: 6주간의 architectural pattern을 보면 (a) 80% 카테고리가 patching으로 해결될까? 아니면 redesign이 필연인가?
DX 관점: rlp-desk는 dev tool — operator(BOS dev)가 매번 30분씩 hand-write recovery를 해야 한다는 사실이 DX failure인가?

각 phase에서 dual voices (Codex + Claude subagent) 실행, consensus table 생성, 4 options steelman.
