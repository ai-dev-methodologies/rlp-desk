# rlp-desk 후속 갭 보고 — ①b 배포 검증 결과 + 부트스트랩 갭 1건 (2026-07-20 3차)

요청자: tire-plletdata PO 세션. **2차 요청서(①재개-런/②F-8/③제출보장) 배포분은 설치본 스팟체크 전부 통과** — CAMPAIGN_PREEXISTING_DIRTY 차감(lib:2306), literal-pathspecs+add -f(runner:888/891), SUBMISSION_TIMEOUT/재주입(runner:107-108) 확인. 감사합니다. 아래는 설치본으로 실캠페인 재개를 시도하며 발견한 **후속 갭 1건**이다.

## 갭: 수정-이전 시대에 손상된 캠페인은 ①b에 도달하지 못함 (닭-달걀)

### 실측 (pa-live-audit-unblock, 설치본 새 빌드에서 재현)

```
$ CAMPAIGN_PREEXISTING_DIRTY="$(git diff --name-only HEAD)" \
  derive_verification_mode <ledger> <prd> <root>
build|ledger coverage does not equal the PRD US set
```

- 원장(`verified.jsonl`)에 US-002만 존재. US-001은 **구버그 시대(모드 오분류)** 에 codex가 4/4 절차-fail시켜 합의 기록을 영영 못 얻음 (아카이브 iter-001~004 verdict 전수 확인 — pass 이력 0, "유실"이 아니라 "미획득").
- coverage 게이트는 ①b **앞**에 있어서, 상주-dirt 차감이 실행되기 전에 build로 확정됨.
- build 모드 → codex strict RED/GREEN 계약 → 이미 GREEN인 US-001은 정직한 RED 불가 → 4/4 재현된 fail 벽.
- 즉: **원장 완결은 confirmation의 전제인데, 원장 완결 자체가 (구버그 때문에) confirmation 없이는 못 얻는 상태.** ①b는 원장이 온전한 캠페인만 구제한다.

### 요청 (판단은 maintainer 몫 — 두 방향 중 택1 또는 "workaround로 충분" 판정도 수용)

- **a) 부트스트랩 경로**: PRD 전 US 완료 표시 + 아카이브에 전체 verdict 이력 존재 + 오퍼레이터 명시 opt-in(플래그/env) 조건에서, 1회성 "confirmation-bootstrap" 검증 허용 — 양 엔진이 done-claim RED/GREEN 요구 없이 **자체 fresh 재실행 기반**으로 판정하고, 합의 pass 시 리더가 원장 항목을 기록(닭-달걀 해소). anti-gaming: opt-in 없이는 불가 + 판정 자체는 여전히 fresh 재실행.
- **b) 공식 workaround 문서화**: 이런 캠페인은 "실질 완료·공식 미완"으로 닫고, 산출물 확정은 **새 slug 확인 캠페인**(감사형 US — 검증 명령 자체가 test-first가 되는 구조, 동일 캠페인의 US-002가 codex 합의를 통과한 검증된 형태)으로 재스탬프. 도구 수정 0.

tire 세션은 당장은 **b)로 자체 진행**한다(다음 캠페인에 확정-재검증 US 편입 예정) — 급하지 않음. a)는 앞으로 중단·재개가 잦은 환경에서 같은 손상이 재발할 수 있어 기록 차원으로 올려둔다.

## 우선순위

낮음~중간 (workaround 존재, 완주 차단 아님). 2차 요청서 3건 같은 blocking 아님.
