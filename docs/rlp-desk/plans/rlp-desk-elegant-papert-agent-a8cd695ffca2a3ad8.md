# Architect Review — rlp-desk-elegant-papert (ralplan v3)

대상: `docs/plans/rlp-desk-elegant-papert.md` (314 lines, v3 초안)
Scope: Architect 검토만. 신규 계획 작성 금지, 약점·누락·모순 표면화.

---

## 1. Steelman Antithesis (가장 약한 가정)

**A. 카테고리 6종은 wrapper-friendly가 아니라 wrapper-confusing.**
plan L60-66은 `spec/dep/context/infra/repeat/unknown` 6종을 채택하지만, L82-87 매핑표에서 verifier verdict 4종(spec/implementation/integration/flaky)을 강제로 6종에 욱여넣는다. 결과: ① `implementation→repeat` 매핑은 의미 변환 (코드 결함이 "재시도 누적"으로 둔갑) — wrapper가 `repeat`를 보고 "재시도 하라"고 잘못 결정할 위험. ② `dep`는 verifier verdict에서 절대 발생 안 함 (integration→dep 단방향). ③ `unknown` fallback이 plan L66 "반드시 매핑 시도"로 명시되지만, 6종 중 어느 것도 fit 안 되는 케이스(예: 사용자 취소, OOM)가 unknown으로 폭주하면 wrapper는 결국 unknown 한 버킷만 분기하는 degenerate 정책으로 귀결. **결론: 카테고리 6종이 정말 분류축으로 기능하는지, 아니면 verifier 출처와 leader 출처를 통일하려다 의미만 흐려졌는지 plan 안에서 답이 없다.**

**B. Sentinel schema "2.0"은 backward-compat 보증이 아니라 마케팅 라벨.**
plan L107-118 sentinel 라인 추가 순서: `BLOCKED:` → `Reason:` → `Category:` → `Schema-Version: 2.0`. 그러나 lib_ralph_desk.zsh:470 기존 파서는 `grep -m1 -E '^[Rr]eason:'`로 1번째 매치만 본다 — 무관. 진짜 위험은 **wrapper-side 1-line 가정 파서**(외부 컨슈머)와 `head -1` shell 패턴. plan은 "신규 필드 무시 가능"이라고만 적었지 wrapper 파서 깨짐 케이스의 grep/awk 패턴 enumeration이 없다. v1↔v2 sentinel을 한 디렉터리 안에 동시에 둘 수 있는 시나리오(replay 후 v2 sentinel + 잔존 v1 status.json)가 있는데, schema_version으로 분기 안내가 없다.

---

## 2. Real Tradeoff Tensions

**T1. Sentinel multi-line 확장 vs 외부 wrapper grep 패턴.**
campaign-main-loop.mjs:337의 writeSentinel은 이미 RC-1/2에서 2번째 줄 `Reason:`을 추가했다(L342-344 확인). plan은 3번째 줄 `Category:`, 4번째 줄 `Schema-Version:`을 더한다. 1줄→2줄 전환은 7 commits에서 이미 risk 흡수했지만, **3→4줄 확장이 매번 1줄 risk를 누적**한다는 점이 plan에 빠짐. 대안 옵션 B(`failure-classifier.json` 분리)를 L40에서 "두 파서 변경"이라며 탈락시키지만, 실제로는 sentinel 1줄 약속 + sidecar JSON 한 파일이 wrapper grep을 깨지 않는 minimum-surface가 될 수도 있다. plan은 이 tradeoff를 sentinel-내부 vs sidecar 둘 다 비교하지 않고 sentinel-내부만 채택했다.

**T2. Schema version "field-presence" vs "explicit version".**
plan L120 "v1 환경 wrapper가 v2 출력을 읽어도 신규 필드 무시하면 그만" — 이는 **field-presence detection**이고, L107-109 `schema_version: "2.0"` 명시는 **explicit version**이다. 두 모델을 동시에 쓰면 파서가 "schema_version 미존재 = v1 vs schema_version=2.0 = v2"인지 "필드 존재 여부로 판정"인지 헷갈린다. migration script(L118 `migrate-state-v1-to-v2.zsh`)는 explicit-version을 가정하는데, lib L470의 정상 코드는 field-presence(`grep -m1 Reason:`)에 가깝다. **두 모델을 plan 안에서 골라야 한다.**

**T3. Lane enforce를 informational WARN으로 두면 self-verification gate가 못 잡는다.**
plan L135 mtime audit를 "informational WARN, BLOCKED 아님"로 결정. CLAUDE.md "Self-Verification Gate" CRITICAL 시나리오는 PASS/FAIL만 판정하는데, WARN은 어느 쪽인가? plan us016(L258)은 "mtime WARN 이벤트 fixture"만 검증하고 worker가 PRD를 수정한 시나리오를 BLOCKED으로 전이시키지 않는다. 결과: lane 위반이 governance §7¾ "위반 시 BLOCKED" 약속과 plan §1f L132 "위반 시 IL-2 감점, leader가 BLOCKED(category=spec)으로 전이"와 모순(plan 본문이 자기 자신과 충돌).

**T4. `clean` 명령이 fresh-context 약속과 어떻게 정합되는지 불명.**
plan L172-178 clean은 PRD/test-spec 보존, memos/sentinel/status 삭제. 그러나 governance §1f fresh-context 원칙은 "Worker/Verifier 매 iteration 새 프로세스, MCP 비활성"이지 PRD 보존을 금지하지 않는다 — 그러므로 L181 "Replay 후 재시도는 fresh-context 약속을 깨지 않음"은 본질적으로 truism. 진짜 risk는 **replay 후 us_fail_history와 consecutive_failures가 어떻게 되느냐**다(memory 초기화로 0이 되면 cb_threshold 6 재진입, 무한 replay 가능). plan에 history 카운터 reset 정책이 없다.

---

## 3. Principle Violations / 누락

**V1. CLAUDE.md "Local File Sync" 표 갱신이 plan L248 한 줄로 처리됨.**
"신규 clean_ralph_desk.zsh + 3 신규 blueprint 자동 wildcard 포함"이라고 적었지만, CLAUDE.md 실제 표(읽음)는 wildcard가 아니라 명시 enumeration이다 (`docs/blueprints/*` 만 wildcard, runtime zsh는 5개 명시 라인). `clean_ralph_desk.zsh`는 **표 안에 신규 라인으로 추가 + diff -q 검증 라인 추가**가 필요한데 plan은 표 패치를 명시하지 않았다.

**V2. `install.sh` 패치 누락 (CRITICAL).**
install.sh L34-39를 읽음 — runtime zsh는 명시적 curl로 한 줄씩 다운로드. plan L172 신규 `clean_ralph_desk.zsh`는 **install.sh에 curl 라인 추가 안 하면 npm 외부 사용자(curl 설치) 환경에서 누락**된다. plan 어디에도 install.sh 패치가 없음. 마찬가지로 `migrate-state-v1-to-v2.zsh`(L118, repo 루트)도 install.sh 권유 다운로드 대상인지 미정의.

**V3. `package.json#files` 영향 미검토.**
신규 `src/scripts/clean_ralph_desk.zsh`, `scripts/migrate-state-v1-to-v2.zsh`(L245), 3 blueprint 파일이 npm tarball에 포함되는지 plan에 언급 없음. MEMORY.md `feedback_verify_before_publish.md` 룰 — "publish 전 postinstall.js/install.sh/CLAUDE.md 3곳 동기화 검증" — 의 install.sh 한 곳을 위반.

**V4. KISS 위반 — P2#7 단일 파일 통합이 sub-PR 한계 초과.**
plan L144-156은 cost-log.jsonl과 campaign.jsonl을 통합하면서 "deprecation 노트 추가, 기간 유지". sub-PR E(L276)에 P2#7+#8+#9 묶여 있는데, ① cost-log deprecation, ② event_type 7종 enum, ③ replay 신설을 한 PR에 넣는 건 review fatigue 유발. PR 분할 전략이 KISS와 충돌.

**V5. governance §1f "세 채널" → "네 채널" 승격이 명시 안 됨.**
plan L42는 "§1f 세 채널에 카테고리도 함께 명시"라고만 적음. 그러나 카테고리는 sentinel/status/console/report 4 채널로 흐른다 (L74 report, L77 sentinel, L78 stderr, L80 status). §1f 본문 텍스트가 "세 채널"인지 "네 채널 + 카테고리 cross-cutting"인지 plan에 정확한 §1f 패치 문장이 없다.

**V6. P3#10/#11 "spec-only"가 governance §8 일관성을 깰 위험.**
plan L186-209는 §8에 Adaptive Iter Cap + Gate-fail Trigger 두 신규 섹션 추가 + CLI flag stub. CLI flag가 동작 안 하는 채로 governance에 명세만 들어가면, 사용자가 `--adaptive-cap strict`를 켰을 때 silent no-op. plan us019(L261)은 "CLI 플래그 stub 파싱 OK"만 검증하지 stub이 사용자에게 "not implemented" 경고를 내는지 검증 없음 — silent failure 0 원칙(L30) 자기위반.

**V7. RC-3 docs(`multi-mission-orchestration.md`)와 P1#4 emit의 위치 미상.**
plan L96 "flywheel-signal.json 작성처(prompt-assembler / flywheel runner) — 현재 어떤 prompt가 flywheel signal을 만드는지 추적 후"라고 적었다 — **추적 자체가 plan 단계에서 끝나야 하는데 implementation 단계로 미뤘다.** sub-PR-B(L274)가 "추적 + emit + 테스트"를 한 번에 하면 추적 결과에 따라 surface가 폭증할 수 있다.

---

## 4. Synthesis (file/line 수준 plan 보강안)

- **L60-66 카테고리 표 아래에** "wrapper recovery 매핑 가이드" 1단락 추가: 각 카테고리에 권장 wrapper 액션(retry/escalate/abort) 명시 → T1-A의 의미 충돌 해소. unknown은 "wrapper가 abort 권고"로 명시.
- **L82-87 매핑표를 양방향 명시**: verifier→category와 category→wrapper-action 두 표 분리. `implementation→repeat` 표기는 폐기하고 `implementation→implementation`(spec 6→7종 확장) 또는 `implementation→spec`(코드 결함을 spec drift로 분류) 중 택1 — 어느 쪽이든 plan에서 결정.
- **L107-120 사이에** "Schema detection 단일 모델 채택" 라인 추가: explicit-version만 사용, field-presence는 폐기. lib_ralph_desk.zsh:470 grep을 "schema_version 검사 후 분기"로 패치하는 항목을 P1#5 대상에 명시.
- **L131-135 Lane enforce 모순 해소**: §7¾ 본문에 "informational WARN"과 "BLOCKED 전이"의 트리거 차이를 표로 정의 (worker가 PRD에 1자 추가=WARN, AC 의미 변경=BLOCKED). 모순 텍스트(IL-2 감점 + BLOCKED + WARN)를 한 결정 트리로 통일.
- **L172-181 clean 명령에** `--reset-history` 플래그 추가 명시 + us_fail_history 초기화 정책 명시 (T4 해소). 기본값은 "보존" (무한 replay 방지) — wrapper가 명시적으로 의도해야 reset.
- **L215-246 변경 대상 파일 표에** 다음 라인 추가:
  - `install.sh` — 신규 zsh curl 라인 (V2)
  - `package.json` (files 필드) — 신규 zsh + blueprint 포함 검증 (V3)
  - `CLAUDE.md` Local File Sync 표 — 명시 enumeration 추가 (V1)
- **PR 분할 전략 L268-279에** PR-E를 P2#7과 P2#8+#9 둘로 더 분할 권고 (V4) — 단일 file consolidation은 review 단위 1 PR이 적절.
- **us019(L261)에** "CLI flag stub이 사용자에게 'not implemented in v2.0' WARN을 출력하는지" AC 추가 (V6).
- **P1#4 emit(L93-100)을** "추적은 본 plan 산출물, emit은 sub-PR-B"로 분리 — 추적 결과 prompt 파일 path를 plan 안에 미리 기재 (V7 risk 차단).

---

## References

- `src/node/runner/campaign-main-loop.mjs:337-345` — writeSentinel 현재 형태 (Reason 1줄, Category 추가 시 라인 누적)
- `src/scripts/lib_ralph_desk.zsh:470-472` — sentinel 파서 `grep -m1 ^[Rr]eason:` (field-presence)
- `src/scripts/lib_ralph_desk.zsh:709-719` — write_blocked_sentinel 현재 (zsh 측, mjs와 라인 형식 정합 필요)
- `src/scripts/lib_ralph_desk.zsh:440-453` — appendIterationAnalytics campaign.jsonl 현재 record (event_type 부재, 신규 필드 추가 시 backward-compat 영향)
- `install.sh:31-52` — 명시적 curl 다운로드, 신규 zsh 추가 시 패치 필수
- `CLAUDE.md` Local File Sync 표 — runtime 5개 + reference 8개 명시 enumeration
- `docs/plans/rlp-desk-elegant-papert.md:60-66` (카테고리 6종), `:82-87` (매핑), `:107-120` (schema), `:131-135` (lane), `:172-181` (clean), `:248` (sync 표 한줄), `:268-279` (PR 분할)
