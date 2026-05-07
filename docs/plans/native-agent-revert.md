# Native Agent() Revert Plan (P0+P1)

6-round ralplan consensus 결과. Goal: slash command(`src/commands/rlp-desk.md`)가 진짜 leader가 되어 Claude Code Agent() 호출 + Bash codex exec로 worker/verifier를 spawn하는 v0.13.x 이전 방식으로 회귀. `--mode tmux`(zsh runner) 경로 미변경.

## Scope

- **P0**: Bug #7 fix 단독 commit + 명시적 invariant ADR
- **P1**: slash command native prose 회복 + `--mode native` 도입 + Node CLI `--mode agent` deprecation banner
- **Out-of-scope**: P2 (Node CLI default flip, `--mode agent` hard-error), P3 (Node leader 삭제 ~4.5k LOC + repo-wide ghost-removal gate). 19th launch 종료 후 별도 PR.

## Principles

1. Naming truth: `--mode agent`라는 flag 하나가 두 곳에서 다른 의미를 가지는 상태 해소.
2. Single leader per mode.
3. Surgical revert: tmux 경로 + 19th launch 영향 0.
4. Bug #7 fix preservation: zsh side에 invariant 보존됨을 ADR로 명시.
5. Reversibility: silent reclaim 없음. `--mode agent` (Node CLI)는 호환 유지하면서 deprecation warning만.

## P0 — Bug #7 fix commit + Invariant ADR

### a. Bug #7 fix commit
- 현재 working tree (5 src + 4 untracked tests + 1 plan markdown) 단독 commit
- Local sync는 이미 완료(`~/.claude/ralph-desk/` chmod 0o444 + banner)

### b. ADR `docs/adr/0001-bug7-invariant-zsh-only-by-structural-necessity.md`

명시적 scope:
- Bug #7 invariant는 **slash-command Native Agent() / Bash codex exec path**에 한정해 **zsh runner side에 enforce**된다.
- Native Agent() path는 short-lived per-call subagent — long-lived TUI process가 없어 동일 race를 가지지 않는다.
- Node CLI `--mode agent`(Node leader, deprecated alpha)는 long-lived tmux pane을 사용 → 동일 race 보유. P3에서 삭제될 때까지 별도 reaper/lock 코드(`src/node/runner/campaign-main-loop.mjs:1091`, `:1577`, `src/node/tmux/pane-manager.mjs`, `src/node/shared/fs.mjs`) 유지.
- zsh side invariant 인용 (codex critic verified file:line):
  - `src/scripts/lib_ralph_desk.zsh:248` — helpers (`_kill_pane_process`, `_lock_sentinel`, `_unlock_sentinel`)
  - `src/scripts/run_ralph_desk.zsh:2179` — partial-write `jq -e .` validity gate
  - `src/scripts/run_ralph_desk.zsh:2484` — verifier reap+lock (per-US main path)
  - `src/scripts/run_ralph_desk.zsh:2551` — final-verify per-US reap+lock
  - `src/scripts/run_ralph_desk.zsh:2969` — prep cleanup unlock
  - `src/scripts/run_ralph_desk.zsh:3036` — worker reap+lock
  - `src/scripts/run_ralph_desk.zsh:3247` — verifier reap+lock (consensus)

### c. re-sync
- `node scripts/postinstall.js`
- banner-aware diff: src ⇆ `~/.claude/ralph-desk/`

### Acceptance
- AC0.1 `git log -1`이 Bug #7 fix
- AC0.2 ADR file 존재 + 위 7 file:line 인용 + scope 명문
- AC0.3 `bash tests/test-bug7-post-sentinel-race.sh` + `bash tests/test-bug7-poll-partial-write.sh` 통과
- AC0.4 Node 315/315 통과
- AC0.5 banner-aware diff src ⇆ install 일치

## P1 — Slash native prose + `--mode native` + Node CLI deprecation

### a. `src/commands/rlp-desk.md` audit list (전체)

| Line | 현재 | 변경 후 |
|---|---|---|
| 192 | init이 emit하는 첫 "/rlp-desk run" Full options reference 블록의 `--mode agent\|tmux` | `--mode native\|tmux (default: native)` (recommended example는 `--mode tmux` 유지) |
| 227 | 두 번째 init emission | 동일 처리 |
| 255 | Options block: `- \`--mode agent\|tmux\` (default: \`agent\`)` | `- \`--mode native\|tmux\` (default: \`native\`)` (정확 라인 형태) |
| 287 | Mode Selection: "If absent or `agent`, use the Agent() path below" | 두 축 명문화: `--mode native` (default, slash native Agent() leader) / `--mode tmux` (zsh runner). Legacy `--mode agent` deprecation+redirect prose. Direct Node CLI `node run.mjs --mode agent`는 deprecated alpha — 별도 paragraph |
| 334 | tmux fallback "suggest `--mode agent`" | "suggest `--mode native`" |
| 342 | "SV/flywheel은 `--mode agent`에서 지원" | "SV/flywheel은 현재 Node-leader `--mode agent` (deprecated alpha, direct Node CLI)에서만 구현. Native Agent() path(`--mode native`)는 SV/flywheel 미구현 — post-P3 작업" |
| 343 | Tmux IMPORTANT RULES "always invokes node ..." | `--mode tmux` 한정으로 scope |
| 360-410 | "Why Agent mode is structurally immune" + "PLATFORM CONSTRAINT" 분산 | 단일 박스 `### Native Agent() Safety Contract`로 verbatim 흡수. 4 sentinel: turn-keepalive, no `subagent_type`, `mode="bypassPermissions"` mandatory, long-running→tmux |
| 448, 460 | claude/codex worker dispatch code | 변경 없음 (이미 native wired) |
| 778 | "agent=LLM leader, tmux=shell leader" help | "native=Native Agent() leader (slash), tmux=zsh leader (production). Legacy `agent` redirects to `native`. Direct Node CLI `--mode agent`는 deprecated alpha — Direct Node CLI invocation 섹션 참조" |
| 784 | run 예시 fallback에 `--mode agent` | `--mode native` |
| 802 | "Agent Mode (default: --mode agent)" 헤딩 | "Native Agent() Mode (default: --mode native)" |

### b. `src/node/run.mjs`

- 신규 `--mode native` 핸들러:
  - stderr: `ERROR: --mode native is slash-command-only. The Node CLI does not implement it. Use \`/rlp-desk run --mode native\` from a Claude Code session, or use \`--mode {tmux,agent}\` for direct CLI invocation.`
  - exit 2
- `--mode agent` (Node CLI, line 366-374) deprecation banner 강화:
  ```
  WARNING: --mode agent (Node-leader alpha) is deprecated.
  This is the direct Node-CLI alpha path — UNRELATED to the slash command's
  Native Agent() path (`/rlp-desk run --mode native`).
  For production tmux orchestration use `--mode tmux`.
  For Claude Code Native Agent() campaigns use `/rlp-desk run --mode native`
  from a Claude Code session.
  This mode will hard-error in the next major release.
  ```
  - default 동작 unchanged (silent reclaim NO; backward compat)
  - `--allow-deprecated` flag 도입 X (P3에서 삭제할 ghost flag 회피)
  - wrapper가 silence 원하면 `2>/dev/null`

### c. Tests

#### us008 신규 3 cases
1. `node run.mjs run demo --mode native` → exit 2 + stderr ERROR 메시지
2. `node run.mjs run demo --mode agent` → stderr deprecation banner + exit 0 (default 동작 유지)
3. `node run.mjs run demo --mode tmux` 회귀 unchanged

#### SV grep/awk guards (`tests/sv-gate-bug7-mode-prose.sh` 신규 또는 sv-gate-fast.sh 병합)

```bash
# 1. count-aware: --mode native 최소 5회 등장
[ "$(grep -c '\-\-mode native' src/commands/rlp-desk.md)" -ge 5 ] || { echo "FAIL: --mode native must appear ≥5 times"; exit 1; }

# 2. block-aware safety contract
WINDOW=$(awk '/^### Native Agent\(\) Safety Contract/,/^### /' src/commands/rlp-desk.md)
echo "$WINDOW" | grep -q 'Turn-keepalive: every status report uses' || { echo "FAIL: turn-keepalive sentinel"; exit 1; }
echo "$WINDOW" | grep -q 'no `subagent_type` parameter' || { echo "FAIL: no-subagent_type sentinel"; exit 1; }
echo "$WINDOW" | grep -q 'mode="bypassPermissions" mandatory' || { echo "FAIL: bypassPermissions sentinel"; exit 1; }
echo "$WINDOW" | grep -qi 'long-running.*tmux' || { echo "FAIL: long-running tmux recommendation"; exit 1; }

# 3. dispatch snippet preservation (AC1.5a static)
awk '/^If claude engine \(default\):/,/^If codex engine:/' src/commands/rlp-desk.md > /tmp/_disp_claude
grep -q 'Agent(' /tmp/_disp_claude || { echo "FAIL: claude dispatch missing Agent("; exit 1; }
grep -q 'mode="bypassPermissions"' /tmp/_disp_claude || { echo "FAIL: claude dispatch missing bypassPermissions"; exit 1; }
awk '/^If codex engine:/,/^\*\*⑥\*\*|^### /' src/commands/rlp-desk.md > /tmp/_disp_codex
grep -q 'Bash("codex exec' /tmp/_disp_codex || { echo "FAIL: codex dispatch missing Bash codex exec"; exit 1; }

# 4. Options block exact match
WINDOW=$(awk '/^Options \(parse from/,/^- `--worker-model/' src/commands/rlp-desk.md)
echo "$WINDOW" | grep -qE '^\- `--mode native\|tmux` \(default: `native`\)$' || { echo "FAIL: Options block --mode line not exact"; exit 1; }
echo "$WINDOW" | grep -qE '\-\-mode .*agent' && { echo "FAIL: stale 'agent' in Options block --mode line"; exit 1; }

# 5. Tmux IMPORTANT RULES contradiction removed
! awk '/^\*\*IMPORTANT RULES:\*\*/,/^####/' src/commands/rlp-desk.md | grep -q "always invokes node" || { echo "FAIL: stale 'always invokes node'"; exit 1; }

# 6. Legacy redirect prose present
grep -q 'Legacy.*\-\-mode agent.*redirect' src/commands/rlp-desk.md || { echo "FAIL: deprecation prose missing"; exit 1; }
```

#### AC1.5b: manual transcript artifact

`docs/verifications/p1-native-mode-transcript.md` (git-tracked):

1. P1 land 후 Claude Code session에서 `/rlp-desk run sample --mode native` 1 iteration 실행
2. 전체 transcript 캡처 — 다음 관측 포함:
   - `Agent(model=…, mode="bypassPermissions", …)` worker dispatch 라인
   - status report가 `Bash("echo '...'")` 로 wrap
   - `subagent_type=` 미사용
3. Reviewer가 `## Reviewer Sign-off` 섹션에 이름 + 날짜 기재
4. CI guard: 파일 존재 + signoff 비-placeholder 검증 (`grep -E "^- Name: \S+"`, `grep -E "^- Date: [0-9]{4}-[0-9]{2}-[0-9]{2}"`)

### d. Re-sync
- `node scripts/postinstall.js`
- banner-aware diff for `src/commands/rlp-desk.md` ⇆ `~/.claude/commands/rlp-desk.md`, `src/node/run.mjs` ⇆ `~/.claude/ralph-desk/node/run.mjs`

### Acceptance
- AC1.1 6 grep/awk guards all return 0
- AC1.2 us008 신규 3 cases all green
- AC1.3 us008/us006 기존 회귀 0
- AC1.4 banner-aware diff src ⇆ install 일치
- AC1.5a 정적 dispatch grep (#3) 통과
- AC1.5b transcript artifact + signoff non-placeholder

## Out-of-scope (deferred PR list)

- **P2**: `src/node/run.mjs:16` default `'agent'` → `'tmux'` flip + `--mode agent` (Node CLI) hard-error. 19th launch 종료 후, 외부 wrapper 영향 평가 후 별도 PR.
- **P3**: Node leader 삭제 (`src/node/runner/campaign-main-loop.mjs`, `src/node/tmux/`, `src/node/polling/` 등 ~4.5k LOC) + Bug-7 Node 통합 테스트 폐기 + repo-wide ghost-removal gate (`rg -n "Node leader\|node-leader\|--mode agent" src docs scripts tests` = 의도된 hits만). P2 후.
- **`--mode agent` reclaim to Native Agent()**: P3 이후 next major version에서만. 이번 PR에선 silent reclaim 없음.

## Pre-mortem

1. **`--mode agent` 호출자가 native와 alpha 의미를 헷갈린다** — slash command에서 호출 시 deprecation+redirect로 native path 진행. 외부 shell wrapper에서 `node run.mjs run X --mode agent` 호출 시 deprecation banner + 기존 Node leader path. 두 경로 모두 메시지로 명시.
2. **Native Agent() turn-end가 사용자를 괴롭힌다** — Safety Contract 박스의 turn-keepalive 명문화로 mitigate. 그래도 100%는 아니므로 docs는 long-running = `--mode tmux` 강력 권고.
3. **외부 wrapper가 `--mode agent` (Node CLI) 의존** — 동작 unchanged + deprecation banner만. P3에서야 hard-error. wrapper는 그동안 마이그레이션.

## Verification end-to-end (P0+P1 land 후)

1. `git log --oneline HEAD~3..HEAD` — Bug #7 + ADR + P1 commits
2. `node --test 'tests/node/*.test.mjs' 'tests/node/*.mjs'` — 315+3 = 318 통과
3. `bash tests/test-bug7-post-sentinel-race.sh` + `bash tests/test-bug7-poll-partial-write.sh` 통과
4. `bash tests/sv-gate-bug7-mode-prose.sh` (또는 sv-gate-fast.sh) — 6 grep/awk guards 0
5. banner-aware diff src ⇆ `~/.claude/`
6. AC1.5b: 사용자가 Claude Code session에서 `/rlp-desk run sample --mode native` 실행 후 transcript 검토 + signoff

## Round-by-round resolution table

| Round | Verdict | Findings closed |
|---|---|---|
| 1 (Architect) | shift to A-strict | option A → A-strict |
| 2 (Critic codex) | ITERATE 7 | entrypoint, default flip, ADR scope, naming, reclaim, AC, re-sync |
| 3 (Architect) | ITERATE 2 | synonym ghost, allow-deprecated ghost |
| 4 (Critic codex) | ITERATE 4 | init blocks (192/227), fallback (334/342), grep guards, ADR scope |
| 5 (Critic codex) | ITERATE 3 | label expansion (778/802), exact options match, AC1.5 runnable |
| 6 (Critic codex) | ITERATE 3 (1 actionable, 2 cross-check false-positives) | signoff non-placeholder check |

Net: 모든 v0-v5 actionable findings closed. Round 6 finding 3 (signoff non-placeholder)은 v7에 이미 반영됨 (AC1.5b CI guard 4번째 항목). Round 6 finding 1/2는 v6 base에 이미 포함된 사항 — critic의 cross-check 누락.
