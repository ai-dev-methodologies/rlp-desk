# Handoff — 모델 매핑 재구성 (2026-09-22) 다른 PC 이어받기 지시서

이 문서는 다른 머신에서 이 작업을 이어받기 위한 순서와 검증된 사실을 소유한다. 설계 자체는 `docs/superpowers/specs/2026-09-22-model-mapping-refresh-design.md`가 소유한다.

## 1. 현재 상태

| 항목 | 값 |
|---|---|
| 브랜치 | `feat/model-mapping-refresh` (main `6d94518` v0.25.0에서 분기) |
| 완료 | 브레인스토밍, 설계 승인, 스펙 작성, codex 스펙 리뷰 1차(14건) 반영 |
| 미완료 | 사용자 스펙 리뷰 게이트, 구현 계획(writing-plans), 구현, codex 구현 리뷰, SV 3시나리오 |
| 원래 브랜치 | `fix/cost-log-exit-row-bucket`(US-004)은 main과 같은 커밋. 이 작업과 무관 |

## 2. 사용자가 이미 내린 결정

| 결정 | 선택 |
|---|---|
| 재검토 범위 | 모델 매핑 관련만. US-004 등 backlog 제외 |
| GPT-6 Astra | 판정자 전용(Final Consensus `astra:high`, CRITICAL per-US Consensus `astra:medium`). Worker 부적격 |
| 퇴역 Codex 모델 | 래더에서 제거, 즉시 리맵+경고. 유예 없음 |
| 접근안 | B. 특성 반영 재구성(effort 단계 Claude Worker 래더) |
| 베어 별칭 | 파싱 시 `sonnet→sonnet:medium`, `opus→opus:medium` 정규화 |
| 문서 | README 최상단에 "모델 매핑과 근거" 섹션. `docs/rlp-desk/model-mapping-rationale.md` 신설. 모델명 문서 전수 동기화 |
| 리뷰 | codex 리뷰를 스펙·구현 양 단계에서 적극 사용. 0 issues 기준 |

## 3. 다음 머신에서 할 일 (순서대로)

1. `git fetch origin && git checkout feat/model-mapping-refresh && git pull --ff-only`
2. 스펙 파일을 읽고 사용자에게 리뷰 게이트를 연다. 수정 요청이 있으면 스펙을 고친 뒤 codex 리뷰를 다시 돈다.
3. 승인 후 `superpowers:writing-plans` 스킬로 구현 계획을 작성한다. 스펙 §6(변경 파일), §9(검증 계획)가 계획의 입력이다.
4. 구현은 TDD. 스펙 §9의 테스트 행을 먼저 RED로 만든다. `src/governance.md`, `src/commands/rlp-desk.md`, `src/scripts/init_ralph_desk.zsh`가 바뀌므로 Self-Verification Gate 3시나리오가 커밋 조건이다(CLAUDE.md).
5. 구현 완료 후 codex 리뷰(`/codex:rescue` 또는 codex review)를 0 issues까지 반복한다.
6. 문서 작업은 `~/.claude/rules/doc-writing.md` 절차(style-guide → grammar-checker → 6항목 점검 → 레포 검증)를 따른다.
7. 커밋·푸시·머지는 사용자 승인 후에만 한다.

## 4. 검증된 사실 (2026-09-22, 이 머신)

- Claude effort는 Node(`src/node/cli/command-builder.mjs` 72~74행)와 zsh(`src/scripts/lib_ralph_desk.zsh` 118~120행) 모두 `--effort`로 전달된다.
- zsh 리더는 래더 결과 문자열을 `WORKER_MODEL`에 통째로 대입한다(`lib_ralph_desk.zsh` 513~519행). model/effort 분리가 필요하다.
- zsh 순차·병렬 Consensus는 문자열을 직접 분리한다(`run_ralph_desk.zsh` 4079~4098행, 4702~4712행). 별칭 정규화를 거치지 않는다.
- `_auto_detect_engine`은 `run_ralph_desk.zsh` 428~462행에 있다. `lib_ralph_desk.zsh`가 아니다.
- `WORKER_CODEX_MODEL` 기본값은 `gpt-5.5`(`run_ralph_desk.zsh` 489행)다.
- 승급 간격: Node 3회, zsh 2회. CB 기본 6회.
- 레포에 `astra`, `gpt-6` 문자열은 없다.
- Worker 프롬프트에는 자기 재검증 지시가 없다. done-claim 증거 기록과 최종 전체 테스트 실행만 있다.
- 로컬 Codex 설정은 `gpt-6-astra`, effort `medium`. Claude Code 메인 모델은 `claude-fable-5-1`.
- 가격: Anthropic 공식 가격표에서 Sonnet 5 $2/$10이 표준가로 확정됨. Codex 가격은 2차 출처(UNVERIFIED).

## 5. 함정

- 라인 번호는 HEAD `6d94518` 기준이다. 편집 전 `grep -n`으로 다시 잡는다.
- `tests/test_option_cleanup.sh` 224~235행과 `tests/test_us011_worker_model_upgrade.sh` 338~345행이 퇴역 키·구 체인을 단정한다. 래더를 바꾸면 이 둘도 바뀐다.
- override 래더(`~/.claude/rlp-desk-models.json`)는 임의 문자열을 그대로 돌려준다. 래더 결과 소비 지점에서 정규화해야 한다.
- Astra는 중대 결정에서 사용자 응답을 기다린다. Worker에 넣으면 무인 루프가 멈춘다. 판정자로 쓸 때도 no-verdict 유계 복구(스펙 §4.3)가 필요하다.
- `verify:sync`는 커밋 후에만 의미가 있다. 소스 편집 중에는 항상 드리프트로 나온다.

## 6. 세션 오프너로 쓸 한 줄

`feat/model-mapping-refresh` 브랜치의 `docs/superpowers/specs/2026-09-22-model-mapping-refresh-design.md`를 읽고, `docs/plans/model-mapping-refresh-handoff.md` §3 순서대로 사용자 스펙 리뷰 게이트부터 이어서 진행해 줘.
