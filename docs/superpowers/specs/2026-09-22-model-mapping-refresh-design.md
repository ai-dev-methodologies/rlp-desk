# 모델 매핑 재구성 설계 (2026-09-22)

이 문서는 rlp-desk의 역할→모델 매핑을 2026-09 모델 라인업에 맞춰 재구성하는 설계를 소유한다. 구현 계획은 별도 plan 문서가, 사용자 대면 근거 설명은 `docs/rlp-desk/model-mapping-rationale.md`가 소유한다.

## 1. 목표와 범위

- 목표: Claude·Codex 최신 모델의 특성을 근거로 Worker·Verifier·Consensus 매핑과 업그레이드 래더를 재구성한다.
- 범위: 모델 매핑 관련 코드·표·프롬프트·문서. README부터 시작해 모델명을 언급하는 문서 전체를 동기화한다.
- 비범위: US-004(cost-log exit row bucket) 등 모델 매핑과 무관한 backlog. `model-ladder.mjs`의 EMERGENCY_LADDER 구조. Node(3회)와 zsh(2회)의 승급 간격 불일치 통일.

## 2. 배경: 라인업 변화

| 변화 | 날짜 | 영향 |
|---|---|---|
| Claude Fable 5.1 출시 | 2026-09-01 | Fable 5 대비 캐시 읽기 1/4. 문서는 "새 작업은 5.1 선호" |
| Claude Opus 5 출시 | 2026-07-24 | low/medium effort가 유난히 강함. 과검증·서브에이전트 과다 |
| Claude Sonnet 5 가격 확정 | 2026-09 | $2/$10 도입가가 표준가로 확정. 9/1 인상 취소 |
| GPT-6 Astra 출시 | 2026-09-04 | 환각률 4.2%. 비동기 질문 후 중대 결정 대기 |
| GPT-5.6 Sol/Terra/Luna GA | 2026-07-09 | Luna 가격 80% 인하(7/30). 5.5 effort와 1:1 대응 아님 |
| GPT-5.4·5.4-mini Codex 퇴역 | 2026-08-31 | 래더 잔존 키 죽음 |
| GPT-5.3-Codex-Spark 폐기 | 2026-09-14 | 래더 잔존 키 죽음 |
| GPT-5.5 Codex 퇴역 예정 | 2026-10-14 | ChatGPT 로그인 한정. API 키는 유지 |

## 3. 모델 특성 표

가격은 백만 토큰당 입력/출력(USD). Claude는 공식 가격표, Codex는 2차 출처(UNVERIFIED 2026-09-22).

| 모델 | 가격 | 컨텍스트 | 핵심 특성 | 역할 적격성 |
|---|---|---|---|---|
| claude-fable-5-1 | $10/$50, 캐시 읽기 $0.25 | 1M | 최강 추론. thinking 상시. 코딩 서브셋에서 Opus 5가 60% 비용으로 동급 | Final Verifier 전용 |
| claude-opus-5 | $5/$25 | 1M | low/medium이 유난히 강함. 지시 없어도 과검증. 서브에이전트 과다 호출 | Worker HIGH/CRITICAL. Verifier MEDIUM 이상 |
| claude-sonnet-5 | $2/$10 | 1M | 지시를 문자 그대로 해석. 도구 적극 사용. medium ≈ Sonnet 4.6 high. 토큰 약 30% 증가 | Worker MEDIUM. Verifier LOW |
| claude-haiku-4-5 | $1/$5 | 200K | 지식 정확도 63%(Opus 5는 92%). 긴 에이전트 루프 부적합 | Worker LOW 시작점 |
| gpt-6-astra | $10/$50 | 미확인 | 환각 4.2%(Sol 12.2%). 결과가 바뀔 질문을 비동기로 묻고 중대 결정에서 대기 | 판정자 전용. Worker 부적격 |
| gpt-5.6-sol | $5/$30 | 1M | 터미널·에이전트 벤치 최강. 장문맥 회수 91.5%. Ultra는 약 3배 비용에 +3점 | Worker CRITICAL 시작, speed lane. Consensus HIGH |
| gpt-5.6-terra | $2/$12 | 1M | "5.5를 쓰던 작업의 자연스러운 시작점". Sol 대비 2~3점 뒤 | Worker MEDIUM(cost lane). Consensus MEDIUM |
| gpt-5.6-luna | $0.20/$1.20 | 1M | 코딩 에이전트 지수 74.6(Opus 4.8 초과). 장문맥 회수 41%로 급락 | Worker LOW 시작. Consensus LOW. 대형 레포 탐색 US 제외 |

## 4. 역할→모델 매핑

### 4.1 Claude 전용

| 복잡도 | Worker 시작 | per-US Verifier | Final Verifier |
|---|---|---|---|
| LOW | haiku | claude-sonnet-5:high | claude-fable-5-1:max |
| MEDIUM | sonnet:medium | claude-opus-5:low | claude-fable-5-1:max |
| HIGH | opus:medium | claude-opus-5:high | claude-fable-5-1:max |
| CRITICAL | opus:high | claude-opus-5:max | claude-fable-5-1:max + 사람 |

### 4.2 Claude Worker 래더 (단일 체인)

```
haiku → sonnet:medium → opus:low → opus:medium → opus:high → opus:xhigh → BLOCKED
```

- 복잡도는 시작점만 정한다. 연속 실패가 누적되면 다음 카드로 올라간다. 승급 간격은 Node 리더 3회(`campaign-main-loop.mjs` 562~575행), zsh 리더 2회(`lib_ralph_desk.zsh` 492~524행)로 현재 다르다. 이 불일치는 기존 상태이며 이번 범위 밖이다.
- 회로차단기(CB) 기본값 6회 연속 실패가 실제 상한이다. 한 시작점에서 최대 2~3단만 올라간 뒤 BLOCKED가 된다. 체인의 나머지 단은 시작점이 높은 복잡도를 위한 것이다.
- 베어 별칭은 파싱 시점에 시작 effort로 정규화한다: `sonnet`→`sonnet:medium`, `opus`→`opus:medium`. `haiku`는 effort 개념이 없어 그대로 둔다. 래더 JSON에는 별칭 키를 두지 않는다. `--worker-model opus`를 쓰던 사용자는 동작이 바뀌므로 CHANGELOG에 명시한다.
- 근거: 장기 코딩에서 Opus 5 medium은 2점 손실에 비용 절반, low는 8점 손실에 비용 1/4이다. 베어 별칭은 effort 미지정으로 claude CLI 기본값에 맡겨지는데, 그 기본값은 미확인이다(구현 시 `claude --help`로 확인).
- effort 전달 경로는 이미 있다. Node는 `command-builder.mjs` 72~74행, zsh는 `lib_ralph_desk.zsh` 118~120행에서 `--effort`를 붙인다. 그러나 zsh 리더는 래더 결과 문자열을 `WORKER_MODEL`에 통째로 대입한다(`lib_ralph_desk.zsh` 513~519행). 래더 결과를 model과 effort로 분리하는 정규화 단계를 두 리더 모두에 추가한다. 이 값은 재시작·복원 경로에서도 보존한다.
- zsh 리더는 Claude 엔진에서도 `WORKER_CODEX_MODEL`을 우선 참조한다(`lib_ralph_desk.zsh` 495~498행). 엔진별 조회 키를 구성해 Claude 래더가 Codex 변수를 읽지 않게 한다.

### 4.3 Cross-engine (Codex 설치 시, luna-first 유지)

| 복잡도 | Worker cost lane | Worker speed lane | Verifier | Consensus per-US | Final Consensus |
|---|---|---|---|---|---|
| LOW | luna:high | 동일 | claude-sonnet-5:high | luna:max | astra:high |
| MEDIUM | luna:xhigh | 동일 | claude-opus-5:low | terra:high | astra:high |
| HIGH | luna:max | sol:medium | claude-opus-5:high | sol:medium | astra:high |
| CRITICAL | sol:high | 동일 | claude-opus-5:max | astra:medium | astra:high |

- Codex Worker 래더는 2026-08-03 정책(luna→terra→sol, ceiling sol:xhigh)을 유지한다. 퇴역 가족만 제거한다.
- Astra는 Worker 래더에 넣지 않는다. 대기 특성이 무인 루프를 멈출 수 있다.
- Final Consensus를 `sol:xhigh`에서 `astra:high`로, CRITICAL per-US Consensus를 `sol:high`에서 `astra:medium`으로 올린다.
- 이 변경의 근거는 가설이다. 일반 환각률 벤치마크(Astra 4.2%, Sol 12.2%)에서 판정 품질을 추론했고, 판정 전용 비교 증거는 없다. Self-Verification CRITICAL 시나리오에서 verdict 완결성(기록 여부, 사유 존재)만 확인한다. 판정 품질 비교는 후속 과제다.
- 판정 비용이 미미하다는 주장은 UNVERIFIED다. 현재 비용 집계는 Worker 행에만 가격을 매긴다(`lib_ralph_desk.zsh` 2011~2037행, `campaign-reporting.mjs` 186~189행). 역할별 비용 귀속은 이번 범위 밖이다.
- Codex Consensus가 타임아웃 또는 verdict 부재로 끝나면 유계 복구를 적용한다. 순서는 ① 동일 모델로 1회 재시도, ② 여전히 부재면 해당 판정만 `sol:xhigh`로 대체 실행, ③ 그래도 부재면 환경 실패로 기록하고 래더를 올리지 않는다. 보안 분류 일시정지와 비동기 질문 대기는 모두 "verdict 부재"로 나타나므로 같은 경로로 처리한다. 구현 위치는 폴링 경계다(`run_ralph_desk.zsh` 4204~4208행 타임아웃 반환, 4961~4963행 전파 지점, Node 대응 경로).

### 4.4 Luna 장문맥 규칙

브레인스토밍 복잡도 표에 "탐색 범위" 요소를 추가한다. 대형 레포 횡단 탐색이 필요한 US는 cost lane에서 `terra:medium`으로 시작한다. 이 예외는 LOW/MEDIUM/HIGH에만 적용한다. CRITICAL은 lane과 무관하게 `sol:high` floor를 유지한다(governance §1c, §4). 예외는 매핑 표의 LOW/MEDIUM/HIGH cost lane 셀보다 우선한다.

### 4.5 cost_factors

`models.json`의 `cost_factors`에 `gpt-6-astra: 2.0`을 추가한다. 키는 기존 항목처럼 전체 모델 ID를 쓴다(`lib_ralph_desk.zsh` 305~332행, `campaign-reporting.mjs` 133~135행이 effort만 떼고 정확 일치로 조회한다). 기존 `gpt-5.6-sol 1.0 / gpt-5.6-terra 0.4 / gpt-5.6-luna 0.04`는 7/30 인하 이후 가격과 일치해 유지한다.

## 5. 퇴역 처리

- `models.json`에서 `gpt-5.4`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`, `gpt-5.5` 계열 키 16개를 삭제한다.
- 퇴역 ID는 입력 즉시 리맵한다: `gpt-5.4→gpt-5.6-terra`, `gpt-5.4-mini→gpt-5.6-luna`, `gpt-5.5→gpt-5.6-sol`, `gpt-5.3-codex-spark→gpt-5.6-luna`. effort는 그대로 옮긴다. stderr에 경고 1줄을 낸다. 유예 기간은 두지 않는다.
- 인증 방식(ChatGPT 로그인, API 키)은 감지하지 않는다. API 키로 `gpt-5.5`를 계속 쓰려는 사용자는 override 래더(`~/.claude/rlp-desk-models.json`)에 5.5 키를 두고 `--worker-model gpt-5.5:high`를 쓰면 된다. 이 경우 리맵 경고만 나오고 override 값이 우선한다. 이 동작을 README에 적는다.
- 정규화는 하나의 함수로 모든 진입점에서 수행한다: ① 초기 플래그 파싱, ② 래더 결과(shipped·override 모두), ③ Consensus dispatch. zsh의 순차·병렬 Consensus는 문자열을 직접 분리해 `codex -m astra`를 만들 수 있으므로(`run_ralph_desk.zsh` 4079~4098행, 4702~4712행) 이 경로도 정규화 함수를 거친다. Node의 `nextWorkerModel` 결과도 같은 함수를 거친다.
- 별칭 `astra→gpt-6-astra`를 `GPT56_ALIASES`와 zsh `_auto_detect_engine`(`run_ralph_desk.zsh` 428~462행)에 추가한다.
- `WORKER_CODEX_MODEL` 기본값 `gpt-5.5`(`run_ralph_desk.zsh` 489행)를 `gpt-5.6-terra`로 바꾼다. 다른 Codex 기본값 변수도 같은 grep으로 확인해 갱신한다.

## 6. 변경 파일 범위

| 파일 | 변경 |
|---|---|
| `src/node/models.json` | 퇴역 키 삭제. Claude 체인 키 추가. `cost_factors["gpt-6-astra"]` |
| `src/node/cli/command-builder.mjs` | astra 별칭. 퇴역 리맵 표와 경고. 베어 별칭 시작 effort 정규화. 정규화 함수를 export |
| `src/node/runner/campaign-main-loop.mjs` | `nextWorkerModel` 결과를 정규화 함수에 통과 |
| `src/node/model-ladder.mjs` | 변경 없음 |
| `src/scripts/lib_ralph_desk.zsh` | 퇴역 리맵 표와 경고. 래더 결과 model/effort 분리. 엔진별 조회 키. Claude 래더가 `WORKER_CODEX_MODEL`을 읽지 않게 수정 |
| `src/scripts/run_ralph_desk.zsh` | `_auto_detect_engine`에 astra 별칭. Consensus dispatch 정규화. `WORKER_CODEX_MODEL` 기본값 갱신. Codex no-verdict 유계 복구 |
| `src/scripts/init_ralph_desk.zsh` | 생성 프롬프트에 Astra 판정자 규칙과 Worker 서브에이전트 억제 반영 |
| `src/model-upgrade-table.md` | 표 재작성. "모델 특성 표" 섹션 신설. 퇴역 이력 1줄 |
| `src/governance.md` | §1 지원 모델 목록. §4 라우팅 표. §5a/§5b 예시 `gpt-5.5→gpt-5.6-terra`. §7 Codex no-verdict 복구와 환경 실패 분류. Consensus 절 Astra 규칙. Worker 절 서브에이전트 억제 |
| `src/commands/rlp-desk.md` | 브레인스토밍 매핑 표 2종. 복잡도 표 "탐색 범위" 요소. 프리셋 4개 갱신 |
| `README.md` | 최상단에 "모델 매핑과 근거" 섹션 신설. 모델명 전수 동기화. override 래더로 퇴역 모델 유지하는 방법 |
| `docs/rlp-desk/model-mapping-rationale.md` | 신설. 사용자 대면 근거 문서 |
| `docs/rlp-desk/*.md` | 모델명 언급 전수 동기화 |
| `CHANGELOG.md` | 사용자 대면 변경만. 베어 별칭 정규화와 퇴역 리맵을 동작 변경으로 명시 |
| `scripts/install-manifest.js` | 신설 문서를 설치 매니페스트에 등록 |

## 7. 프롬프트 반영

- Astra 판정자 규칙: "채팅으로 질문하지 않는다. 판정에 필요한 정보가 부족하면 `request_info` verdict를 파일로 기록한다." 기존 생성 프롬프트가 불확실한 Verifier에게 `request_info`를 지시하므로(`init_ralph_desk.zsh` 862~875행) 이 규칙과 충돌하지 않는다.
- Opus Worker 서브에이전트 억제: "Worker는 서브에이전트를 생성하지 않는다."
- 두 규칙은 governance(정본 서술)와 `init_ralph_desk.zsh`의 생성 프롬프트(실제 전달 경로, 682~737행, 862~875행, 969~972행) 양쪽에 넣는다. 실제 전달은 생성 프롬프트가 담당하므로 프롬프트 전달 테스트로 확인한다. 이미 생성된 캠페인 프롬프트는 갱신하지 않으며, 다음 `init`부터 적용된다.
- Sonnet 5 문자 해석 특성은 프롬프트를 바꾸지 않고 특성 표에 기록만 한다.
- Opus 5 과검증 대응으로 제거할 문장은 없다. 현재 Worker 프롬프트의 검증 지시는 done-claim 증거 기록과 최종 전체 테스트 실행이며 프로토콜 요구사항이다.

## 8. 문서 산출물

- README.md 최상단 섹션 "모델 매핑과 근거": 매핑 표 요약 2개, 근거 3줄, rationale 문서 링크. 사용자에게 매핑의 근거를 먼저 보이는 것이 목적이다.
- `docs/rlp-desk/model-mapping-rationale.md`: 특성 표(§3), 매핑(§4), 퇴역 처리(§5), 출처 목록을 사용자 언어로 옮긴다. 이 문서가 근거의 정본이고 README는 요약과 링크만 둔다.
- 모델명을 언급하는 모든 문서를 동기화한다. 대상은 `grep -rniE 'haiku|sonnet|opus|fable|gpt-5|gpt-6|codex-spark|luna|terra|sol' README.md docs/ src/*.md src/commands/`로 정한다.
- 문서 작성은 `~/.claude/rules/doc-writing.md` 절차를 따른다: style-guide → grammar-checker → 6항목 구조 점검 → 레포 검증.

## 9. 검증 계획

1. 테스트 선행 수정 후 RED 확인. 대상 단정:
   - `tests/node/models-ladder.test.mjs` 52~56행, 67행, 103행, 133행, 143~152행(별칭 래더·shipped 기본값), 217~222행(GPT-5.4 래더). 응급 폴백(EMERGENCY_LADDER) 단정은 유지한다.
   - `tests/node/us002-cli-command-builder.test.mjs`: astra 별칭, 퇴역 리맵 경고, 베어 별칭 정규화, `cost_factors["gpt-6-astra"]` 정확 일치 조회 케이스 추가.
   - `tests/test_option_cleanup.sh` 224~235행(퇴역 키 요구), `tests/test_us011_worker_model_upgrade.sh` 338~345행(구 Claude/GPT-5.5 체인), `tests/test_us004_progressive_upgrade.sh`, `tests/test_us003_unified_model_format.sh`.
   - 신규: zsh 래더 결과 model/effort 분리, Consensus dispatch 별칭 정규화, Codex no-verdict 유계 복구, 생성 프롬프트에 Astra 규칙·서브에이전트 억제 포함 여부.
2. `npm run test:node`와 zsh 테스트 전체 green.
3. Self-Verification Gate 3시나리오(LOW/MEDIUM/CRITICAL). CRITICAL에서 Final Consensus가 실제 `codex -m gpt-6-astra`로 verdict를 기록하는지, no-verdict 복구 경로가 동작하는지 확인.
4. Codex CLI가 `gpt-6-astra`에 `model_reasoning_effort=high|medium`을 받는지 1회 호출로 확인. 실패 시 effort 값 조정. `claude --help`로 기본 effort 확인.
5. codex 리뷰: 스펙 단계 1회(완료, 14건 반영), 구현 단계 1회 이상. 0 issues에 도달해야 머지 후보다.
6. 커밋 후 `npm run verify:sync` exit 0.

## 10. 리스크와 미확인 항목

- Codex 가격은 2차 출처다. 공식 가격 페이지 확인 시 `cost_factors["gpt-6-astra"]` 재계산.
- `gpt-6-astra`가 Codex CLI에서 받는 effort 값 집합은 실행으로 확인한다.
- claude CLI의 기본 effort는 미확인이다. 베어 별칭 정규화로 이 의존을 없앤다.
- Astra 판정 우위는 가설이다. 판정 전용 비교 증거가 없다.
- 판정 비용이 미미하다는 결론은 UNVERIFIED다. 현재 집계는 Worker 행만 가격을 매긴다.
- Node 3회, zsh 2회 승급 간격 불일치는 기존 상태로 남는다.
- 베어 별칭 정규화와 퇴역 리맵은 사용자에게 보이는 동작 변경이다. CHANGELOG와 README에 명시한다.
- GPT-5.5는 API 키 로그인에서 계속 살아 있다. 계속 쓰려면 override 래더를 써야 한다.

## 11. 결정 기록

| 결정 | 선택 | 대안 |
|---|---|---|
| 재검토 범위 | 모델 매핑 관련만 | 미착수 backlog 전체, v0.25.0 사후 감사 |
| Astra 위치 | 판정자 전용 | Worker ceiling 추가, 이번 제외 |
| 퇴역 모델 | 래더 제거 + 리맵 경고 | 5.5만 유지, 문서만 갱신 |
| 접근안 | B. 특성 반영 재구성 | A. 최소 갱신, C. 특성 프로필 추상화 |
| 베어 별칭 | 파싱 시 시작 effort로 정규화 | CLI 기본 유지, 허용 중단 |
| GPT-5.5 유예 | 폐지, 즉시 리맵 | 10/14까지 유예, 래더 유지 |
| codex 스펙 리뷰 1차 | 14건(blocker 2, major 8, minor 4) 전부 반영 | — |

## 12. 출처

- Anthropic 가격표: https://platform.claude.com/docs/en/about-claude/pricing
- Claude 모델 마이그레이션·비용 가이드: claude-api 스킬 `shared/model-migration.md`, `shared/cost-optimization.md` §2.6·§2.7 (2026-06-24 캐시)
- Codex 모델 페이지: https://learn.chatgpt.com/docs/models
- Codex 변경 로그: https://learn.chatgpt.com/docs/changelog
- GPT-6 Astra 발표: https://openai.com/index/gpt-6-astra/
- GPT-5.6 벤치마크 해설: https://www.vellum.ai/blog/gpt-5-6-benchmarks-explained
- Opus 5 대 GPT-5.6 Sol 비교: https://www.datacamp.com/blog/claude-opus-5-vs-gpt-5-6-sol
