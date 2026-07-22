# tire 사건 조기 공유 (P2 후보) — codex CLI 0.145.0 업데이트 다이얼로그가 F-1 Skip 핸들러를 뚫음 — 2026-07-22 새벽

정식 10차 요청은 캠페인 완주 후 묶어 보내겠지만, **이 건은 너희 다른 캠페인도 즉시 걸릴 표면**이라 먼저 알린다.

## 사건

- 2026-07-22 04:44, codex CLI 0.145.0 릴리스 이후 모든 codex TUI 기동에 업데이트 다이얼로그(`✨ Update available! 0.144.6 -> 0.145.0 / 1. Update now / 2. Skip`)가 표시됨.
- 러너의 F-1 핸들러가 `update prompt detected — selecting '2. Skip'`을 **3회 수행했으나 다이얼로그가 계속 재출현** (선택이 먹히지 않음 — 새 다이얼로그의 키 처리 방식 변화로 추정). 검증자 execution-start 신호 부재 → 재디스패치 2회 소진 → `[infra_failure] Codex verifier-codex never started` BLOCKED.
- 우리 조치: CLI를 0.145.0으로 업데이트해 다이얼로그 자체를 소멸시키고 재기동 — 이후 `Update available` 검출 0, 워커 정상 (파싱 회귀 감시 중, 현재까지 이상 없음).

## 제안 (10차에서 정식화 예정 — 미리 검토해두면 좋을 방향)

1. **근본**: TUI 기동 시 업데이트 체크를 끄는 플래그/환경변수로 기동 (codex가 지원한다면) — 다이얼로그 표면 자체를 제거. CLI 릴리스마다 재발하는 구조라 Skip 핸들러 강화는 두더지잡기다.
2. 차선: F-1 핸들러를 0.145.0 다이얼로그의 실제 키 시퀀스로 갱신 + Skip 실패 N회 시 "operator에게 CLI 업데이트 필요" 명시 에러 (지금은 무관해 보이는 submission failure로 죽음).

## 로그

- `/tmp/pa-foundation-leader-43.log` 04:44:47~04:47:25 구간 (`update prompt detected` ×3 → `never started` → BLOCKED)
- 처치 후 클린: `/tmp/pa-foundation-leader-44.log` (Update available 검출 0)
