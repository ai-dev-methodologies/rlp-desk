# rlp-desk 8차 요청 — done-claim 프로세스 감사의 기계화: pre-gate 내장 lint (P2) — 2026-07-21

요청자: tire-plletdata PO 세션 (pa-foundation 캠페인, v0.22.16 운용 중).
참고: 앞서 7차 종결 보고(`tire-plletdata-request-g-closure.md`)에서 "8차 후보"로 예고했던 omz 첫-글자 삼킴 건은 **이 요청이 아니라 별도(9차 후보)로 유지**한다 — 이 문서는 pre-gate 확장 단독 건이다.

## 배경 서사 (맥락 자족형)

1. pa-foundation 캠페인은 `--consensus all`로 매 US 검증에 codex 교차 다리를 쓴다. codex 검증 프롬프트에는 **Worker Process Audit**(build-mode에서 done-claim의 AC별 TDD 순서 증거 감사)가 포함되어 있다.
2. US-002(신규 build 작업)에서 codex가 2라운드 연속 fail을 냈는데, verdict 원문을 보면 **"four acceptance criteria pass fresh verification"** — 즉 산출물 4개 AC 전부 실검증 통과인데, done-claim의 `execution_steps`에서 AC3의 `write_test → verify_red → implement → verify_green` 순서 라벨이 불완전(`implement:all` 묶음 라벨, AC3 개별 라벨 누락)하다는 **순수 증거-형식 사유**로 fail이었다.
3. 이 형식 결함은 100% 결정론적으로 판정 가능하다(JSON 필드 순서 검사). 그런데 현재 도구의 기계 pre-gate(1층: 캠페인 스크립트 실행 / 2층: done-claim 명령 replay)는 이를 검사하지 않아, **초 단위로 잡을 수 있는 결함이 라운드당 20~25분짜리 LLM 교차검증까지 흘러가 fail을 만든다.**
4. 사용자(오너) 지시 취지 verbatim: *"형식 트집으로 시간 끄는 걸 각 검증마다 기계적인 검증으로 빠르게 잡기로 했잖아 — 반영했어?"* → 우리가 캠페인 로컬 pre-gate 스크립트에 lint를 추가해 임시 봉합했고, *"이런 기계 검증 pre-gate 추가도 rlp-desk 개선사항에 넣어놔 그리고 요청하자"* 지시로 이 요청서를 쓴다.

## 실측 낭비 (근거)

- US-002 형식-사유 fail 2라운드: iter-002 (worker 627s + verify 964s) + iter-004 (worker 1059s + verify 1269s) ≈ **누적 ~65분** — 산출물은 이미 green인 상태에서 라벨 형식만으로 소모.
- 캠페인 전체 원장(37 iteration): per-US codex 다리 판정 **pass 0 / fail 15** — 상당수가 산출물 결함이 아닌 프로세스-증거 형식/라우팅 사유였다 (독트린 건은 6차 ledger-seed로 기해소, 이번 건이 남은 형식 계열).

## 요청 — pre-gate에 done-claim 형식 lint 내장 (Layer 1.5)

1. **워커 done-claim 제출 직후, 검증자 디스패치 전에** 도구가 결정론 lint를 실행:
   - build-mode 클레임(execution_steps에 `write_test` 존재)에 한해, **등장하는 각 AC마다** `write_test → verify_red → implement → verify_green` 4단계가 해당 AC 라벨(`ac_id`, 쉼표 리스트 인정)로 **순서대로** 존재하는지 검사. `ac_id:"all"` 묶음 라벨은 단계 충족으로 불인정 (codex 감사 기준과 동일).
   - `write_test` 없는 confirmation/replay 클레임은 스킵 (오탐 방지 — 우리 실데이터 US-001 replay 클레임으로 스킵 경로 검증됨).
2. **실패 시 검증자 디스패치 없이 즉시 워커 fix contract로 반려** — 출력에 AC별 단계 인덱스 좌표(`-1`=누락, 비단조=역전)를 포함해 워커가 좌표만 보고 고치게. (기존 pre-gate 원칙 "실패 출력 tail = fix contract" 그대로.)
3. **기준의 단일 정본화**: 이 lint 규칙과 검증자 프롬프트의 Worker Process Audit 기준이 **같은 정의를 공유**해야 한다 (기계가 pass한 형식을 LLM이 다시 트집 잡으면 무의미). 아울러 **워커 프롬프트에도 done-claim 증거 형식 명세를 명시**해 작성 시점부터 맞게 쓰도록 (현재는 검증 단계에서야 기준이 드러남).
4. 규칙은 확장 가능하게 — 캠페인별 추가 형식 규칙을 얹을 수 있는 구조(env 또는 캠페인 스크립트 훅)면 충분하다.

## 참조 구현 (우리 임시 조치 — 그대로 가져가도 됨)

`tire-plletdata/.rlp-desk/plans/pregate-pa-foundation.sh` 4번 검사. 핵심 jq:

```jq
def acs: ((.ac_id // "") | split(",") | map(gsub("\\s+";"")) | map(select(. != "" and . != "all")));
[.execution_steps | to_entries[] | {i: .key, step: .value.step, a: (.value | acs)}] as $S
| ([$S[].a[]] | unique) as $ACS
| [ $ACS[] as $ac
    | (["write_test","verify_red","implement","verify_green"]
       | map(. as $p | ([$S[] | select(.step == $p and (.a | index($ac)))] | (.[0].i // -1)))) as $idx
    | select(($idx | min) < 0 or ($idx != ($idx | sort)))
    | {ac: $ac, idx: $idx} ]
```

검증 케이스 3종 통과 확인: ①합성 FAIL(US-002 재현 — AC3 implement 누락+`implement:all`) → `{"ac":"AC3","idx":[4,5,-1,6]}` 정확 검출 ②합성 PASS(쉼표 라벨 포함 4단계 완비) → `[]` ③실데이터 confirmation 클레임 → 스킵.

## 수용 기준

- build-mode done-claim의 AC별 TDD 순서 결함이 검증자 디스패치 **전에** 기계 반려되고, fix contract에 AC·단계 좌표가 포함된다.
- confirmation/replay 클레임(write_test 부재)에 오탐 0.
- lint를 통과한 형식에 대해 codex Worker Process Audit가 같은 사유로 fail을 내지 않는다 (기준 단일 정본 확인).
- 워커 프롬프트에 done-claim 증거 형식 명세가 포함된다.

## 우선순위

P2 — 차단 아님(우리 캠페인 로컬 스크립트로 임시 봉합됨). 단 consensus-all을 쓰는 모든 캠페인에서 라운드당 20~25분×반복의 구조적 낭비라 개선 가치가 높다.

## 로그·증거 경로 일습 (절대경로)

- codex fail verdict 원문: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/logs/pa-foundation/iter-002.verify-verdict-codex.json`, `iter-004.verify-verdict-codex.json` (US-002 형식-사유 fail 2건)
- done-claim 실물(형식 대상): 같은 디렉터리 `iter-*-done-claim.json`
- 우리 임시 lint: `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/plans/pregate-pa-foundation.sh` (4번 검사)
- analytics(iteration별 소요·verdict): `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/analytics/pa-foundation--d467238d/campaign-v*.jsonl`
- 리더 stdout: `/tmp/pa-foundation-leader-31.log`
- 캠페인 메모(워커 측 예방 계약 조항 "done-claim 증거 형식"): `/Users/plletdata/Documents/AI/kyjin/tire-plletdata/.rlp-desk/memos/pa-foundation-memory.md`
