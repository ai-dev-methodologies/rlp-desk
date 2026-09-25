# Handoff — 모델 매핑 재구성 (2026-09-25 갱신) 다른 세션 이어받기 지시서

이 문서는 이 작업을 이어받기 위한 순서와 검증된 사실을 소유한다. 설계는
`docs/superpowers/specs/2026-09-22-model-mapping-refresh-design.md`가 소유하되,
**그 스펙은 부분적으로 낡았다** — 아래 §2가 스펙보다 우선한다.

## 0. 재개하면 가장 먼저 (읽는 순서: §0 → §2 → §3a → §5 → §4 → §4a)

### 작업 트리가 더럽다 — 커밋 전 상태로 이어받는다
HEAD는 `a904ca0`(= origin, 푸시 동기화됨)이고, 그 **위에 미커밋 변경 9개 파일**이
얹혀 있다. 이게 증분 ②b + consensus 정규화의 전부다. `git stash`/`checkout`으로
날리지 말 것. 커밋은 사용자 게이트다(CLAUDE.md Commit & Publish Gate).

```
 M docs/plans/model-mapping-refresh-handoff.md
 M src/node/models.json
 M src/scripts/lib_ralph_desk.zsh
 M src/scripts/run_ralph_desk.zsh
 M tests/node/models-ladder.test.mjs
 M tests/sv-large-campaign/test-model-upgrade-ladder.zsh
 M tests/test_defect2_ceiling_and_approach_escalation.sh
 M tests/test_us004_progressive_upgrade.sh
 M tests/test_us011_worker_model_upgrade.sh
```

### 그린 기준선 (2026-09-25 재측정, 위 트리 상태에서)
```bash
npm run test:node                                   # 781/781, fail 0
npm run test:zsh                                    # exit 0, FAILING FILES 없음
npm run sv-gate:fast                                # 99/99
zsh tests/sv-large-campaign/test-model-upgrade-ladder.zsh   # 22/22
```
이 4개가 이 델타의 회귀 감지선이다. `verify:sync`는 **커밋 후에만** 의미가 있다.

**주의**: `zsh tests/sv-large-campaign/test-dbacklog.zsh`는 **베이스라인에서도
3 FAIL**이다(D-1c malformed-spec, D-17a banner, D-17a 429). 이 델타와 무관하니
회귀로 착각하지 말 것 — 판단 전에 `git stash`로 대조할 것.

### 사용자 결정 대기 3건 (직전 세션이 물었고 아직 답을 못 받음)
1. `tests/sv-large-campaign/`을 `test:zsh` 또는 sv-gate에 편입할까? (현재 어떤
   npm 게이트도 안 탄다 — §3a 발견 1)
2. per-US Verifier 기본 effort: `sonnet:medium`(현재 동작) 유지 vs 스펙 §4.1대로
   `sonnet:high`? (§3a 발견 5)
3. 지금 커밋할까, §4의 4번까지 끝내고 한 번에 커밋할까?

**이 3건에 답이 없으면 4번 작업은 시작해도 되지만 커밋은 하지 말 것.**

## 1. 현재 상태

| 항목 | 값 |
|---|---|
| 브랜치 | `feat/model-mapping-refresh` — **`fix/reaudit-wave-1` 위로 리베이스됨** (main 기준 아님) |
| 브랜치 구성 | main `6d94518` → wave 1·2·3 (audit remediation / model generation / SV-gate remediation) → 스펙 커밋 → 이번 작업 |
| 완료 | 증분 ①(퇴역 키 제거), 증분 ②a(정규화·리맵), **증분 ②b(7단 래더)**, **consensus dispatch 정규화** |
| 미완료 | Codex no-verdict 유계 복구 2·3단계, Wave B(프롬프트·governance), Wave C(문서), codex 리뷰, 적대적 리뷰, SV 3시나리오 |

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

### 증분 ②a (커밋 `e60372a`)
- Node `command-builder.mjs`: `RETIRED_MODEL_REMAP`, `BARE_ALIAS_NORMALIZATION`,
  `normalizeModelSpec()` export
- Node `run.mjs`: 모델 플래그 5개 전부 `validateModelFlag` **앞단**에 배선
- zsh `lib_ralph_desk.zsh`: `_normalize_model_spec` + `parse_model_flag`·
  `_validate_consensus_model_var` 배선
- zsh `run_ralph_desk.zsh`: `_auto_detect_engine`에 **동일 로직 복제**(아래 §5 참조)

## 3a. 2026-09-23 세션이 한 것 (아직 커밋 안 됨)

### 증분 ②b — 7단 래더
- `src/node/models.json`: claude 체인을
  `haiku → sonnet:medium → opus:low → opus:medium → opus:high → opus:xhigh →
  claude-fable-5-1:max → ""`. 베어 `sonnet`/`opus`/`claude-fable-5-1` 키 삭제.
- **핵심 결함 2건을 같이 고쳐야 성립한다** (래더만 바꾸면 claude 승급이 죽는다):
  - `lib_ralph_desk.zsh` `check_model_upgrade` claude 분기가 조회 키를 베어
    `$WORKER_MODEL`로 만들었다 → `haiku` 말고는 전부 키 미스 → 첫 승급부터
    `already_max`. `WORKER_EFFORT`를 실은 `model:effort`로 교체.
    `get_model_string()`은 **쓰지 않았다** — claude에서 베어를 반환하는 계약이
    `test_engine_refactor` T2-2/T2-5에 고정돼 있다.
  - `run_ralph_desk.zsh` CB 블록의 `_ceiling_model_str`도 같은 베어 키 → 모든
    단에서 "천장 도달"로 오판정하며 architecture escalation을 헛발화. 동일하게 수정.
- EMERGENCY_LADDER(Node·zsh 양쪽)는 **의도적으로 4단 그대로**다(스펙 §1 비범위).

### consensus dispatch 정규화
- `_validate_consensus_model_var`가 **콜론 없는 값에서 정규화 결과를 되쓰지 않고
  `return 0`** 했다. 결과: `--consensus-model spark`가 퇴역 경고를 내고도 그대로
  `codex -m spark`로 나가고, `--consensus-model astra`는 별칭 그대로 나갔다.
  베어 경로에서도 `typeset -g`로 정본 ID를 되쓰도록 수정. 죽은 `spark)` 케이스 암
  (퇴역 ID로 매핑) 제거.
- 손수 분리 구간 2곳(`run_single_verifier` 4499행대, `run_consensus_verification_parallel`
  5175행대)은 **건드리지 않았다** — 둘 다 이 전역을 읽으므로 한 곳에서 정본화하는
  쪽이 맞다.

### 테스트 리타게팅
`models-ladder.test.mjs`(7단 walk + 베어 키 부재 단정 신설), `test_us011`,
`test_us004`(L2-1을 walk로), `test_defect2`, `sv-large-campaign/test-model-upgrade-ladder.zsh`.

- `test_defect2`는 CB=6 + 4단 래더 전제 위에 있었다. 시작 단을 `opus:medium`으로
  옮겨 "천장 승급이 CB 경계와 겹친다"는 성질을 보존했다(7단에서 그 지점은
  ceiling-3hop = `opus:medium`). haiku 시작은 6홉이라 A1~A4가 공허해진다.
- `test_us011`의 US001-emergency는 **공허하게 통과하고 있었다**: `extract_fn`이
  `get_next_model` 본문 앞에 자기 `LIB_DIR`를 **prepend**하므로 본문 **앞**에 쓴
  `LIB_DIR` 무효화가 덮어써졌다. 응급 래더가 아니라 shipped를 타고 있었고, 구
  래더에서는 둘의 답이 같아 드러나지 않았다. `LIB_DIR` 할당을 본문 **뒤**로 옮겼다.

### 검증 (이 세션 실측)
`npm run test:node` 781/781 · `npm run test:zsh` exit 0 · `npm run sv-gate:fast`
99/99 · `sv-large-campaign/test-model-upgrade-ladder.zsh` 22/22.

### 남긴 발견 (이번 델타의 회귀 아님)
1. **`tests/sv-large-campaign/*.zsh`는 `test:zsh` 글롭 밖이다**(`tests/test_*.sh`,
   `tests/test_*.zsh`). 그래서 `test-model-upgrade-ladder.zsh`가 증분 ① 이후 계속
   3건 RED인 채 방치돼 있었다(gpt-5.5·spark 단정). 이번에 같이 고쳤다. **게이트에
   이 디렉터리를 넣을지 결정 필요.**
2. `tests/sv-large-campaign/test-dbacklog.zsh`는 **베이스라인에서도 3 FAIL**
   (D-1c malformed-spec validation, D-17a banner, D-17a 429). 이번 작업과 무관.
3. **래더 출력 정규화(스펙 §5 ②)는 아직 미배선**이다. shipped 래더 값은 이미
   정본이라 무해하지만, 사용자 override 래더가 `gpt-5.5:high`를 돌려주면 그대로
   디스패치된다. zsh 쪽은 `get_next_model`에 `_normalize_model_spec` 의존을 추가하는
   순간 §5의 "함수 추출 하네스" 함정을 밟는다(테스트 6개의 추출 헬퍼를 같이 고쳐야
   한다). 독립 항목으로 잡을 것.
4. `campaign-main-loop.mjs:715`의 폴백 기본값이 아직 베어다
   (`worker_model ?? 'sonnet'`, `final_verifier_model ?? 'opus'`). `run.mjs`가 항상
   기본값을 채우므로 실제로는 도달 불가. Wave B/C에서 정리 여부 판단.
5. `VERIFIER_MODEL` 기본 `sonnet`은 ②a 정규화로 `sonnet:medium`이 된다. 스펙
   §4.1은 per-US Verifier LOW를 `claude-sonnet-5:high`로 적는다. **불일치 — Wave B
   결정 필요.**

## 4. 다음 세션에서 할 일 (순서대로)

1. `git status --short --branch`로 §0의 미커밋 9개 파일이 그대로인지 먼저 확인한다.
   **`git checkout`/`git stash`로 브랜치를 갈아타지 말 것** — 작업 결과가 전부
   미커밋 상태다. (동기화가 필요하면 `git fetch origin && git ls-remote origin
   feat/model-mapping-refresh`로 HEAD 일치만 확인. 현재 `a904ca0`으로 일치.)
2. ~~**증분 ②b — models.json 7단 래더 전환.**~~ **완료(미커밋).** §3a 참조.
3. ~~**consensus dispatch 정규화**~~ **완료(미커밋).** §3a 참조.
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

## 4a. §4의 4번(Codex no-verdict 유계 복구) 착수 지점 — 실측 줄 번호

스펙 §4.3의 줄 번호(4204~4208, 4961~4963)는 **낡았다**. 2026-09-25 실측:

| 지점 | 위치 | 현재 동작 |
|---|---|---|
| 순차 consensus, claude verdict null 재시도 | `run_ralph_desk.zsh` 5411~5430 | 1회 재시도 → 여전히 null이면 `return 1` |
| 순차 consensus, **codex verdict null 재시도 (= D-14, 1단계)** | `run_ralph_desk.zsh` 5438~5454 | 1회 재시도 → 여전히 null이면 `log_error` 후 `return 1` |
| 병렬 consensus, 양측 verdict 판독 + null 거부 | `run_ralph_desk.zsh` 5340~5346 | 재시도 **없음** — 바로 `VERIFIER_ABORT_REASON` + `return 1` |
| 병렬 consensus, 폴링 타임아웃 | `run_ralph_desk.zsh` 5298 | `... — timeout` 사유로 abort |

추가할 것(스펙 §4.3):
- ② 1회 재시도 후에도 verdict 부재면 **그 판정만** `gpt-5.6-sol:xhigh`로 대체 실행
- ③ 그래도 부재면 `environment` 실패로 기록하고 **래더를 올리지 않는다**

**중요 — 스펙의 "Node 대응 경로"는 존재하지 않는다 (2026-09-25 확인).** Node는
consensus를 구현하지 않는다: `run.mjs`가 `--consensus*` 옵션을 파싱해
`CONSENSUS_MODEL`/`FINAL_CONSENSUS_MODEL` 등 env로 zsh 리더에 넘길 뿐이고
(`run.mjs` 36~41, 247~260, 668~669), `campaign-main-loop.mjs`의 "consensus"는
주석 1건뿐이다. **4번은 zsh 전용 작업이다.**

병렬 경로는 null 재시도 자체가 없으므로, ②③을 넣으면 순차·병렬 **양쪽**에 넣어야
한다. 넣지 않기로 하면 그 결정을 문서에 남길 것.

## 5. 함정 (이 세션에서 실제로 밟은 것들)

### 서브에이전트 위임이 5번 연속 실패했다
원인은 파일 길이가 아니라 **도구 출력량**이다. 측정값:
- `npm run test:node` = **79KB** (테스트 781개를 줄마다 출력)
- `npm run test:zsh` = **200KB+**, **NUL 바이트 포함** → `grep`에 `-a` 없으면 조용히 아무것도 못 찾음
- `grep -n 'codex' run_ralph_desk.zsh` = **455 hits**, `'consensus'` = **157 hits**

서브에이전트 브리프에 검증 명령을 넣을 때 반드시 상한을 걸 것(`| tail -20`,
단일 테스트 파일). 광범위 grep을 시키지 말고 **줄 번호를 직접 찾아서 넘길 것**.
`run_ralph_desk.zsh` 7344줄, `lib_ralph_desk.zsh` 5277줄, `test_us011` 2009줄
(2026-09-25 실측 — 이 파일들은 계속 자라므로 위임 전에 `wc -l`로 다시 잴 것).

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

### 래더를 바꾸면 조회 키 2곳이 같이 깨진다
`models.json`만 고치면 claude 승급이 **조용히** 죽는다. 조회 키를 만드는 곳이
`lib_ralph_desk.zsh` `check_model_upgrade`와 `run_ralph_desk.zsh` CB 블록
`_ceiling_model_str` 둘이고, 둘 다 claude에서 베어 이름을 썼다. 어느 쪽도
크래시하지 않고 "이미 천장"으로 답한다. §3a 참조.

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
- ~~**`opus → claude-fable-5-1:max` dangling**~~ — 증분 ②b에서 해소.
  `claude-fable-5-1:max`가 명시적 `""` 종료자를 가진 실제 키가 됐다.
- **경고 빈도**: `parse_model_flag`는 반복 호출되므로 퇴역 ID를 고정한 사용자는
  경고를 여러 번 볼 수 있다. Node는 옵션 파싱 시 1회다. 필요하면 후속으로 억제.

## 7. 세션 오프너로 쓸 한 줄

`feat/model-mapping-refresh` 브랜치의 `docs/plans/model-mapping-refresh-handoff.md`
§0(재개 즉시 확인 — 미커밋 트리·그린 기준선·대기 중인 결정 3건), §2(확정 사항),
§3a(직전 세션 산출물), §5(함정)를 이 순서로 먼저 읽고, §4의 4번(Codex no-verdict
유계 복구 2·3단계)부터 이어서 진행해 줘. 작업 트리는 미커밋 상태이고 커밋은 내
승인 뒤에만 해.
