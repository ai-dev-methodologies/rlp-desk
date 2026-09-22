# Handoff — 모델 매핑 재구성 (2026-09-22 갱신) 다른 세션 이어받기 지시서

이 문서는 이 작업을 이어받기 위한 순서와 검증된 사실을 소유한다. 설계는
`docs/superpowers/specs/2026-09-22-model-mapping-refresh-design.md`가 소유하되,
**그 스펙은 부분적으로 낡았다** — 아래 §2가 스펙보다 우선한다.

## 1. 현재 상태

| 항목 | 값 |
|---|---|
| 브랜치 | `feat/model-mapping-refresh` — **`fix/reaudit-wave-1` 위로 리베이스됨** (main 기준 아님) |
| 브랜치 구성 | main `6d94518` → wave 1·2·3 (audit remediation / model generation / SV-gate remediation) → 스펙 커밋 → 이번 작업 |
| 완료 | 증분 ①(퇴역 키 제거), 증분 ②a(정규화·리맵) |
| 미완료 | 증분 ②b(래더 전환), consensus·no-verdict, Wave B(프롬프트·governance), Wave C(문서), codex 리뷰, 적대적 리뷰, SV 3시나리오 |

**중요**: 이 브랜치는 `fix/reaudit-wave-1`을 포함한다. 그 브랜치의 wave 1-3도
아직 main에 머지되지 않았고 자체 게이트가 미이행이다 —
`docs/plans/model-generation-wave-handoff.md` "Before merge" 참조. 이 작업의
SV 게이트는 **wave 1·2·3 + 이번 델타 전부**를 덮어야 한다.

## 2. 스펙보다 우선하는 사항 (사용자 확정, 재논의 금지)

스펙은 main `6d94518` 기준으로 작성돼 "레포에 `astra`, `gpt-6` 문자열은 없다"고
적었으나, wave 2가 이미 Fable 5.1·Codex 6 Astra를 추가했다. 충돌 4건의 결론:

| 항목 | 확정 | 스펙 원안 |
|---|---|---|
| Claude worker 래더 | `haiku → sonnet:medium → opus:low → opus:medium → opus:high → opus:xhigh → claude-fable-5-1:max → BLOCKED` | `opus:xhigh → BLOCKED` (fable 제외) |
| Final Consensus | `astra:xhigh` 유지 | `astra:high` |
| `cost_factors["gpt-6-astra"]` | **항목 없음**, 1.0 fallback 유지 | `2.0` |
| `WORKER_CODEX_MODEL` | `gpt-5.6-luna` 유지 (충돌 아님 — 스펙 §4.3의 luna-first와 일치) | `gpt-5.6-terra` |

`cost_factors`를 비워 두는 이유: 2.0은 스펙 §12가 스스로 UNVERIFIED(2차 출처)로
표기한 Codex 가격에서 나온 값이고, 1.0 fallback이 보수적·비하향 기본값이다.

## 3. 이미 반영된 것 — 다시 하지 말 것

### wave 2가 한 것
- `claude-fable-5-1`·`gpt-6-astra` 등록, 양 래더 천장 연장
- `astra` 별칭 3곳 전부: `command-builder.mjs`, `lib_ralph_desk.zsh` `parse_model_flag`,
  `run_ralph_desk.zsh` `_auto_detect_engine`
- 기본값: `FINAL_VERIFIER_MODEL=claude-fable-5-1`, `FINAL_VERIFIER_CODEX_MODEL=gpt-6-astra`,
  `FINAL_CONSENSUS_MODEL=gpt-6-astra:xhigh`, `VERIFIER_CODEX_MODEL=gpt-5.6-terra`,
  `WORKER_CODEX_MODEL=gpt-5.6-luna`
- `gpt-6-astra` 추론 레벨 실측: `low|medium|high|xhigh|max` 확인, `minimal` 거부
  확인(**모델별**), `ultra`는 수용되나 서버 열거에 없음

### 증분 ① (커밋 `bddcf08`)
퇴역 키 16개 삭제(`gpt-5.4`·`gpt-5.4-mini`·`gpt-5.5`·`gpt-5.3-codex-spark`).
관련 테스트 단정을 **속성 보존** 원칙으로 리타게팅.

### 증분 ②a (그 다음 커밋)
- Node `command-builder.mjs`: `RETIRED_MODEL_REMAP`, `BARE_ALIAS_NORMALIZATION`,
  `normalizeModelSpec()` export
- Node `run.mjs`: 모델 플래그 5개 전부 `validateModelFlag` **앞단**에 배선
- zsh `lib_ralph_desk.zsh`: `_normalize_model_spec` + `parse_model_flag`·
  `_validate_consensus_model_var` 배선
- zsh `run_ralph_desk.zsh`: `_auto_detect_engine`에 **동일 로직 복제**(아래 §5 참조)

## 4. 다음 세션에서 할 일 (순서대로)

1. `git fetch origin && git checkout feat/model-mapping-refresh && git pull --ff-only`
2. **증분 ②b — models.json 7단 래더 전환.** §2의 확정 체인으로 교체하고 베어
   `sonnet`/`opus`/`claude-fable-5-1` 키를 제거한다. 정규화(②a)가 이미 있으므로
   이제 안전하다. 깨질 단정: `test_us011` E2E(`result_sonnet == "opus"`,
   `result_opus == "claude-fable-5-1:max"`), `models-ladder.test.mjs`의 claude 체인.
3. **consensus dispatch 정규화** — `run_ralph_desk.zsh` 병렬 경로의 손수 분리
   구간(§5 위치 참조)을 `_normalize_model_spec` 경유로.
4. **Codex no-verdict 유계 복구 2·3단계** — 1단계(동일 모델 1회 재시도)는 **이미
   존재**한다(D-14). 추가할 것은 ② `gpt-5.6-sol:xhigh`로 해당 판정만 대체 실행,
   ③ 여전히 부재면 `environment` 실패로 기록하고 래더를 올리지 않기.
5. **Wave B** — `init_ralph_desk.zsh` 생성 프롬프트에 Astra 판정자 규칙(채팅 질문
   금지, `request_info` 파일 기록)과 Worker 서브에이전트 억제. `governance.md`
   모델 목록·라우팅 표. `src/commands/rlp-desk.md` 복잡도 표에 "탐색 범위" 6번째
   요소. `src/model-upgrade-table.md` 재작성.
6. **Wave C** — `docs/rlp-desk/model-mapping-rationale.md` 신설, README 최상단
   "모델 매핑과 근거" 섹션, 모델명 전수 동기화, CHANGELOG(베어 별칭 정규화와 퇴역
   리맵은 **동작 변경**이므로 명시), `scripts/install-manifest.js` 등록.
7. **codex 리뷰** 0 issues까지 반복.
8. **Fable 5.1 적대적 리뷰** — 사용자 승인 후 서브에이전트에 `model: "fable"`로
   위임. 메인 루프에서 돌리지 말 것.
9. **SV 3시나리오** — wave 1·2·3 + 이번 델타 전부. CRITICAL 시나리오는 wave 3의
   governance §1f¾를 end-to-end로 태워야 한다(실제 escalation 발화 → 산출물 생성
   → `approach_summary` 누락이 기계적 pre-gate에 튕김 → 재진술된 요약이 Verifier
   check 10⅝에 잡힘).
10. 커밋·푸시·머지는 사용자 승인 후에만.

## 5. 함정 (이 세션에서 실제로 밟은 것들)

### 서브에이전트 위임이 5번 연속 실패했다
원인은 파일 길이가 아니라 **도구 출력량**이다. 측정값:
- `npm run test:node` = **79KB** (테스트 773개를 줄마다 출력)
- `npm run test:zsh` = **200KB+**, **NUL 바이트 포함** → `grep`에 `-a` 없으면 조용히 아무것도 못 찾음
- `grep -n 'codex' run_ralph_desk.zsh` = **455 hits**, `'consensus'` = **157 hits**

서브에이전트 브리프에 검증 명령을 넣을 때 반드시 상한을 걸 것(`| tail -20`,
단일 테스트 파일). 광범위 grep을 시키지 말고 **줄 번호를 직접 찾아서 넘길 것**.
`run_ralph_desk.zsh` 7290줄, `lib_ralph_desk.zsh` 5161줄, `test_us011` 1930줄.

### CLI/env parity는 자동으로 유지되지 않는다
`parse_model_flag`(CLI)만 고치면 `_auto_detect_engine`(env, `WORKER_MODEL=...`)이
갈라진다. 후자는 lib 소싱 **전**에 실행돼 lib 함수를 호출할 수 없으므로, 이
레포는 **표를 복제하고 parity 테스트로 고정**하는 규약을 쓴다. 모델 파싱을 건드리면
반드시 양쪽을 같이 고치고 `test_us011`의 `cli-env-parity`로 확인할 것.

### 함수 추출 하네스는 새 의존을 자동으로 따라오지 않는다
`test_us003`·`test_us011`은 `parse_model_flag`를 **단독 추출**해 스크래치
스크립트에서 돌린다. 새 헬퍼를 호출하도록 바꾸면 `command not found`로 죽는데,
**그 크래시가 non-zero exit이라 "거부" 단정이 엉뚱한 이유로 통과**한다. 이번에
`_model_parse_deps` 헬퍼로 의존을 묶었다. 같은 함정이 `_validate_model_level`
때도 있었다(코드에 주석으로 남아 있음).

### 경고가 stdout 비교를 오염시킨다
`_normalize_model_spec`는 경고를 stderr로 내지만, 테스트 다수가 `2>&1`로 병합해
비교한다. `[model-remap]` 줄을 걸러내고 경고 발생 자체를 별도로 단정할 것.
bash로 실행되는 테스트에서 `print -r`(zsh 빌트인)를 쓰면 안 된다 — `printf` 사용.

### 리맵은 잘못된 입력을 유효하게 세탁할 수 있다
그래서 **리맵은 모델 부분만 바꾸고 레벨은 절대 건드리지 않는다**. 이 불변식
덕에 `gpt-5.5:`(끝 콜론)는 `gpt-5.6-sol:`이 되어도 여전히 거부되고,
`gpt-5.5:minimal`은 `gpt-5.6-sol:minimal`로 **대체 모델 어휘 기준** 정당하게
통과한다(`minimal`은 astra에서만 거부). 이 성질을 깨지 말 것.

### 기타
- `verify:sync`는 커밋 후에만 의미가 있다. 소스 편집 중에는 항상 드리프트로 나온다.
- 스펙 파일이 `docs/superpowers/specs/`에 커밋돼 있다. 저장된 규칙은 이 경로를
  로컬 전용으로 두지만, npm tarball에는 새지 않는다(`package.json` `files`는
  `docs/rlp-desk/*.md`만 포함). 머지 전 git에서 빼는 것을 사용자에게 제안할 것.

## 6. 미해결로 남긴 것 (의도적)

- **문서-코드 간극**: `src/commands/rlp-desk.md`와 init 프리셋이 아직
  `spark:high`를 유효한 `--worker-model` 값으로 광고한다
  (`test_option_cleanup.sh` DOC5가 그걸 단정). 입력은 이제 리맵되지만 광고 문구는
  Wave B에서 고쳐야 한다.
- **`opus → claude-fable-5-1:max` dangling**: models.json의 실제 키는 베어
  `claude-fable-5-1`이라, claude 천장이 명시적 `""` 종료자가 아니라 **조회
  실패로** 종료된다. 결과는 같지만(둘 다 BLOCKED) 증분 ②b가 바로잡는다.
- **경고 빈도**: `parse_model_flag`는 반복 호출되므로 퇴역 ID를 고정한 사용자는
  경고를 여러 번 볼 수 있다. Node는 옵션 파싱 시 1회다. 필요하면 후속으로 억제.

## 7. 세션 오프너로 쓸 한 줄

`feat/model-mapping-refresh` 브랜치의 `docs/plans/model-mapping-refresh-handoff.md`
§2(확정 사항)와 §5(함정)를 먼저 읽고, §4 순서대로 증분 ②b(models.json 7단 래더
전환)부터 이어서 진행해 줘.
