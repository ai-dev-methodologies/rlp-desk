# tire 검증 보고 — v0.22.15 (6차 회신의 검증 요청 3건) — 2026-07-21

결론 먼저: **① ② 모두 clean — Tier-2(push/레지스트리) 진행해도 좋다.** ③ 이상 0건.

## ① ledger-seed 실사용 (격리 worktree, 실제 claude-pass verdict 사용)

- **성공 케이스**: `ledger-seed pa-foundation US-000 --evidence <iter-012 claude pass verdict> --note "…"` →
  - receipt 출력 완전: ledger 경로 / commit `6f57aad1d8` / prd `127405a7ad`(우리 PRD의 git hash-object와 일치 확인) / `seeded: true` / operator_note / **anti-gaming NOTE 문구**("a seed does NOT grant a pass…")까지 그대로 출력
  - 원장 항목 필드 전부 정확: `{"us_id":"US-000","seeded":true,"operator_note":…,"prd":…,"commit":…,"verified_at":…}`
- **fail-closed 2케이스 실측**:
  - PRD 부재 → `PRD not found … run init first` 거부, 원장 무접촉
  - verdict=fail evidence(codex fail verdict로 시도) → `evidence verdict is not "pass" (got "fail")` 거부, **원장 라인 수 불변(1) = 무접촉 확인**

## ② story-scoped basis 소비 (재개 캠페인 라이브)

- `[FLOW] verification_mode` 라인 방출 정상 + 의미론 정확 — 신규 스토리에 대해:
  `[FLOW] verification_mode=build basis="no PRD-bound verified ledger entry for US-001" iter=2` ✓ (신규 US는 build가 맞음)
- 재개 시 시드 원장 소비도 정상: `Restored verified_us from durable ledger: US-000` → 캠페인이 US-001로 전진 (수기 시드 57b4c41 그대로 유효 — 회신 내용대로)
- `confirmation|story-scoped` basis의 **디스패치 소비 라인**은 원장-항목-보유 US가 재디스패치되는 시점(최종 순차 검증의 US-000 스코프)에 관측될 예정 — 관측 즉시 추가 보고하겠다. (설치 직후 derive 함수 직접 실행으로는 `confirmation|story-scoped: US-000 verified at … (ancestor of HEAD)` 정확 반환을 이미 확인함)

## ③ 이상 여부

- 0건. P3 참고 2건(--note 선행 하이픈, 문서-계약 프레이밍)은 인지·수용.
- §2(IL-2¾ 분류 게이트) 문서 반영도 확인 — 다음 캠페인(metric-external-evidence) brainstorm에서 첫 실적용 예정.

감사하다 — 6차까지의 사이클(P1 버그 이틀 내 3건 수리 + 설계 2건 채택)이 실캠페인을 실제로 살렸다.
