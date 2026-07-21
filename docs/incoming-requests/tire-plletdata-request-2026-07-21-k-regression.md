# rlp-desk 회귀 보고 (P1) — v0.22.17/18 ④ 에코 검증의 tail-10 공백행 오판 + LEADER_PANE 오검출 관찰 — 2026-07-21 밤

요청자: tire-plletdata PO 세션. 먼저: request-h(lint)·request-j(하드닝 4건)·README hero까지 **당일 배포**해준 것 확인했고 감사하다. 다만 19:27 배포분(0.22.17/18)의 ④ 구현에 P1 회귀가 있어 캠페인 재기동이 4연속 즉사했고(34~37차), 원인을 우리가 격리·로컬 핫픽스했다. 소스 반영을 요청한다.

## 회귀 ① (P1) — `_paste_cmd_echo_verified`의 tail -10이 새 pane에서 항상 공백만 봄

**증상**: 워커 pane 기동 시 `launch paste echo mismatch (attempt 1/3→3/3)` → replace+retry → 동일 → `[infra_failure]` BLOCKED. 재기동 4회 전부 pane 생성 ~2초 내 사망.

**원인 (실측 격리)**:
- 갓 split된 pane은 **첫 프롬프트가 viewport 최상단**에 그려지고 그 아래 ~30행은 빈 줄이다 (사용된 쉘처럼 프롬프트가 하단에 있지 않음).
- 검증식 `_tail=$(capture-pane -p | tail -10)`은 **하단 10행 = 전부 빈 줄**을 취하고, `$()`가 후행 개행을 제거해 `_tail=""` → prefix grep 영구 실패.
- **명령 에코 자체는 완벽했다**: 같은 순간 파일로 뜬 캡처(34행) 상단에 `❯ /opt/homebrew/bin/codex -m gpt-5.6-terra -c model_reasoning_effort="high" …` 온전히 존재 (od 덤프로 하단 10행이 `\n`뿐임을 확인). 즉 오탐이 100% 재현되는 구조라, rc-swallow 실사고보다 훨씬 자주 발화한다.
- 참고: 주석의 "tail -10 (not -6)" 논리는 랩 대응으로는 맞지만 프롬프트-상단 케이스를 못 덮는다. 자체 테스트(test_launch_echo_verify.sh)가 이 케이스를 안 가진 것으로 추정.

**수정 제안 (우리 로컬 핫픽스 그대로 — 1줄)**:
```zsh
_tail=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null | grep -v '^[[:space:]]*$' | tail -10)
```
빈 행 제거 후 tail — 프롬프트 위치와 무관해지고 랩 대응(-10)은 유지된다.

**보조 제안**: 첫 paste 전 쉘-준비 대기(가시 텍스트 등장까지 ≤6s 폴링)도 함께 넣으면 진짜 cold-rc 케이스(paste가 rc 로딩보다 빠른 경우)까지 봉합된다 — 우리 로컬 핫픽스에 포함, 아래 diff 참조.

**검증**: 핫픽스 적용 직후 재기동(38차)에서 mismatch 0, 워커 즉시 기동·트리거 제출·Working 진입. 라이브 clean.

## 관찰 ② (P2 참고) — LEADER_PANE이 활성 pane을 따라감 (② session-pinning 관련)

- 리더를 캠페인 세션 내 전용 pane(%2175)에서 기동했는데 로그는 `Leader pane: %2177`(같은 세션의 **다른** pane — 오퍼레이터의 Claude CLI, 당시 활성 pane)로 기록했다. 리더 pane 결정이 "자기 tty의 pane"이 아니라 "클라이언트 활성 pane"을 잡는 것으로 보인다.
- 더 이전 재기동(20:40 이전 1회)에서는 pane들이 **무관한 타 세션 2곳**(j-pa-develop %2277, pa %2278)까지 흩어진 관측이 있다 — 다중 attached 클라이언트 환경에서 활성-pane 추종의 결과로 추정. ②의 수용 기준("캠페인 pane이 캠페인 세션 밖 생성 0")으로 재검 부탁한다. 재현 환경: tmux 클라이언트 6+개 동시 attach.

## 우리 로컬 핫픽스 현황 (다음 배포에서 대체될 것)

설치본 `~/.claude/ralph-desk/run_ralph_desk.zsh`에 `[tire-plletdata LOCAL HOTFIX` 마커 3블록: ①쉘-준비 대기 ②mismatch 진단 덤프(발화 시 /tmp/echo-verify-debug.log) ③tail 공백행 제거(진범 수정). 정식 배포가 오면 우리가 제거·재설치한다.

## 증거 경로 (절대경로)

- 즉사 4회: `/tmp/pa-foundation-leader-34.log` ~ `-37.log` (echo mismatch·BLOCKED 라인)
- 오판 순간 원본 캡처: `/tmp/cap-probe.txt` (상단 에코 온전 + 하단 `\n`×10, od 확인), 진단 덤프 `/tmp/echo-verify-debug.log` (PANE_INFO: pane_dead=0·zsh·35x34·CAPTURE 34행인데 _tail 공백)
- 수리 후 클린 기동: `/tmp/pa-foundation-leader-38.log`
- 타 세션 유출 관측: 20:40 재기동 구간, `tmux list-panes -a` 실측 (j-pa-develop %2277 / pa %2278)
