# rlp-desk 10차 요청 — 에러 계열 제거 2건 + 중간 관찰 보고 — 2026-07-22

요청자: tire-plletdata PO 세션. 오너 원칙("에러 상황이 나오면 도구를 개선해 그 계열을 제거한다 — 자동복구로 덮지 않는다")에 맞춰 **둘 다 근본 제거 제안**으로 쓴다. F-1(업데이트 다이얼로그)은 v0.22.21로 기해소 확인했으므로 제외.

## ① (P2) echo-verify 재사용-pane 변종 — 준비 판정의 계열 제거

**사고 실측 (v0.22.22 위에서 발생 — 미봉인 갭)**: 47차 직전 런(46차) iter-3, 워커 재디스패치가 **재사용 pane %2463**에 paste → `launch paste echo mismatch (attempt 1/3→3/3)`이 **1초 내 소진**(15:07:59~15:08:00) → `Worker codex failed to start in pane after replace+retry` BLOCKED.

**원인**: `_wait_pane_shell_ready`의 준비 판정이 "non-blank 텍스트 존재"라서 — fresh pane(request-k 케이스)에는 유효하지만 **재사용 pane에서는 옛 출력 때문에 항상 즉시 통과**한다. 직전 프로세스가 쉘로 복귀하기 전에 paste가 유실되고, 재시도 간격(0.15s)이 짧아 3회가 1초 안에 끝난다.

**계열 제거 제안**: 준비 판정을 콘텐츠 기반이 아니라 **프로세스 기반으로 교체** — `tmux display-message -p -t <pane> '#{pane_current_command}'`가 `zsh|bash`가 될 때까지 대기(타임아웃 fail-open 유지). 이러면 fresh(rc 로딩 중=zsh이지만 프롬프트 전)와 재사용(이전 프로세스 잔존) 두 케이스가 한 판정으로 덮인다 — fresh 케이스에는 기존 non-blank 검사를 AND로 유지하면 완전하다. 재시도 간격도 0.15s→0.5s+ 권장(3회가 1초에 끝나는 구조 자체가 재시도의 의미를 없앤다).

**참조 구현**: 우리 로컬 핫픽스 2블록이 설치본 `~/.claude/ralph-desk/run_ralph_desk.zsh`에 `[tire-plletdata LOCAL HOTFIX 2026-07-22` 마커로 있다 (쉘-복귀 대기 최대 8s + 간격 0.8s). 적용 후 47차 재사용-pane 재디스패치 포함 mismatch 0 (관측 계속 중).

**수용 기준**: 재사용 pane 재디스패치 경로에서 echo mismatch 오탐 0 / fresh-pane 회귀 없음(기존 request-k 테스트 유지) / 반영 시 우리 핫픽스 마커 제거 확인 안내.

## ② (P2) verdict·전달 산출물의 런별 아카이브 부재 — 증거 소실 계열 제거

**문제 실측**: iter 로그 파일(`iter-NNN.verify-verdict-*.json`, done-claim 등)이 **재기동마다 같은 파일명으로 덮어써진다**. 실피해: PRD 정식 개정(341 cohort) 후 기존 검증 US들을 새 PRD 해시로 `ledger-seed` 재바인딩해야 했는데, **US-001·002·003의 claude pass verdict 파일이 후속 런들에 덮여 소실** → 재시드 불가 → final 검증을 build-mode 신선 검증으로 감수 중 (US-007 장기화의 원인 중 하나 — build-mode는 매 라운드 fresh E2E를 요구).

**계열 제거 제안**: verdict·done-claim·iter-signal을 run 단위 하위 경로(예: `logs/<slug>/runs/<run-ts>/iter-NNN.*`) 또는 append-only로 보존하고, `ledger-seed --evidence`가 아카이브 경로를 인정하게. 이는 자동복구가 아니라 **증거 보존 체계**다 — verified.jsonl이 원장이듯 verdict는 그 원장의 영수증인데 현재 유일하게 휘발된다.

**수용 기준**: 임의 시점 재기동 후에도 과거 모든 pass verdict가 파일로 회수 가능 / ledger-seed가 아카이브 verdict를 evidence로 수용.

## ③ 중간 관찰 보고 (요청 아님 — 부탁받았던 관측 항목)

- **다중 클라이언트 pane 고정 (0.22.19~)**: 재기동 7회+, 동시 attach 클라이언트 6+ 환경에서 **캠페인 세션 밖 pane 생성 0** — k ② 수리 유효.
- **capacity 자동재개**: 스톨 재발 0으로 미발화 (오탐 주입도 0).
- **update 다이얼로그 (0.22.21)**: 억제 후 재출현 0.
- **0.22.22 신기능**(3-문서 lint·contract-revisions·external_fact): 47차부터 라이브 — 최종 관측은 캠페인 완주 보고서에 동봉하겠다.
- wrapper 지침 수용: 우리 워처는 sidecar의 `recoverable/suggested_action` 필드를 읽는다 (reason_category 유도 안 함).

## 로그·증거 경로 (절대경로)

- ① 사고: `/tmp/pa-foundation-leader-46.log` 15:07:59~15:08:03 구간, 아카이브 `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/logs/pa-foundation/blocked-archive/blocked-46-echo-reused-pane-*.md`
- ① 참조 구현: `~/.claude/ralph-desk/run_ralph_desk.zsh`의 `[tire-plletdata LOCAL HOTFIX 2026-07-22` 2블록
- ② 소실 사례: 재시드 성공분은 `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/memos/pa-foundation-verified.jsonl`의 seeded 3건(US-000·004·005, prd 0428ab52)·불가분은 US-001~003 (당시 `iter-*.verify-verdict-claude.json` 현존 파일들이 전부 후속 런 산출물로 대체된 상태로 확인 가능)
- analytics: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/analytics/pa-foundation--d467238d/campaign-v*.jsonl`
