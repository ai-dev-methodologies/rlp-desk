# request-l — Leader launch contract docs + canonical layout enforcement (v0.22.20)

Date: 2026-07-21 · Status: approved (user + owner mandate via tire reply)
Sources: `docs/incoming-requests/tire-plletdata-request-2026-07-21-l-docs.md`, `docs/incoming-requests/tire-plletdata-request-l-reply.md`

## Corrected premise (why scope differs from the original request)

Detached launch was never the leak cause; both launch paths are coded and now safe
(0.22.18 empty-target guards + session invariant, 0.22.19 `$TMUX_PANE` anchoring).
Confirmed by tire's own logs (32차 `Leader pane: %774`, 41차 `%2175` correct, leak 0).
The "detached unsupported" contract is withdrawn. Remaining real gaps: leader pane
width (manual resize burden, split failure risk) and layout drift (no verification;
drift invites manual join-pane which killed campaign 32).

## Scope

### 1. Docs — dual launch paths + canonical layouts (README + governance + help)
- README tmux section: 2-3 sentences documenting BOTH launch paths as canonical:
  inside tmux → leader anchors on its own `$TMUX_PANE` (0.22.19+); outside tmux →
  the runner **fails fast** (`start tmux first`). Either way campaign panes never land
  outside the campaign session (0.22.18 invariant).
  > CORRECTED DURING IMPLEMENTATION (2026-07-22): this line originally said "outside
  > tmux → runner creates a dedicated campaign session". That branch exists in
  > `create_session` but is unreachable via normal invocation — the top-level guard
  > in `run_ralph_desk.zsh` hard-rejects an unset `$TMUX` ("start tmux first") before
  > `main` runs, and `run.mjs` spawns the zsh runner with inherited stdio without
  > wrapping a session. The source request doc authorized documenting current behavior
  > ("현행 동작을 정본으로 서술"), which is fail-fast. The §2/§3 width+geometry guards are
  > still wired into BOTH `create_session` branches for defense-in-depth.
- Canonical layout contract, TWO forms, as diagrams in README AND governance:
  - Human operator (3-pane): `[operator pane = leader | worker | verifier stack]`
    (original design — operator's own shell hosts the leader).
  - AI operator (4-pane, owner-mandated): `[operator pane (AI CLI) | leader pane
    (always visible) | right column stack: worker / verifier / (consensus)]`.
    The leader pane is a pane-creation anchor, not a log viewer; it stays visible
    at a readable width (never collapsed) — owner decision "개발자도 뭔지 알아야 한다".
- `--mode tmux` help text: one line stating the same.
- governance edit ⇒ Self-Verification Gate (3 scenarios) applies before commit.

### 2. Leader pane width guarantee (code)
- New helper `_ensure_leader_pane_width <cols> <ctx>`: reads `#{pane_width}` of
  `$LEADER_PANE`; if below target, `tmux resize-pane -x <cols>`; re-checks.
- Two knobs (validated via the existing D-19 numeric-knob guard):
  - `RLP_LEADER_MIN_WIDTH` (default 30) — readable minimum, enforced at startup
    and each iteration top (inside `_r12_check_lifecycle`). Resize failure here
    logs a warning only (cosmetic; never blocks a healthy campaign).
  - `RLP_LEADER_SPLIT_WIDTH` (default 110) — enforced immediately before every
    `-h` split from the leader (create_session, worker/verifier recreation).
    If still too narrow after resize, explicit error (startup: hard error exit 1;
    in-loop: `write_blocked_sentinel ... infra_failure`) — the split would fail
    anyway; the error must name the pane, widths, and the knob.
- Also: run `RLP_SHELL_READY_TIMEOUT_S` through the same D-19 validation
  (clears the accepted LOW from the request-k review).

### 3. Geometry verification + enforcement (code)
- Creation-time enforcement: all pane creation/recreation paths keep the canonical
  split chain (leader → `-h` worker; worker → `-v` verifier; verifier → `-v`
  consensus). No path may target another window/column.
- Post-creation verification (extends the 0.22.18 `_assert_pane_in_session` family),
  deterministic predicate via `display-message -p -t <pane>`:
  - worker/verifier/consensus: same `#{window_id}` and session as leader;
  - `pane_left(W) == pane_left(V) == pane_left(C)` (single right column);
  - `pane_left(W) > pane_left(leader)`;
  - `pane_top(W) < pane_top(V) < pane_top(C)` (top-down stack order).
- Verification points: after create_session (both branches), after
  replace_worker_pane, after consensus-pane creation.
- On mismatch: NO auto move-pane (campaign-32 ledger-corruption class risk).
  Startup: hard error exit 1 with a diagnostic naming expected vs actual geometry.
  In-loop: `write_blocked_sentinel "pane geometry violation ..." "" "infra_failure"`.
  Silent drift is forbidden.

### 4. Absorbed / dropped
- Operator pattern note (item ②) absorbed into §1 docs (manual resize procedure
  disappears with §2).
- "Detached unsupported" declaration: dropped (premise corrected).
- Auto-repair (move-pane): rejected by design (user decision).

## Testing
- Extend `tests/test_pane_session_pinning.sh`: geometry predicate pass case
  (canonical stack), fail cases (extra column via differing pane_left, wrong
  window_id, wrong stack order), stubbed tmux display-message conventions.
- New/extended width tests: below-min triggers resize call; resize failure at
  split point → error path; knob validation (non-integer falls back to default).
- Structural asserts: help line present; README/governance carry both diagrams.
- Full `npm run test:zsh` + `npm run test:node` green; SV gate 3 scenarios
  (governance changed) before commit.

## Ship
v0.22.20, Tier-1 (FF merge → tag → local sync + §4.5) + npm publish (registry is
already at 0.22.19; publish keeps external users current).
