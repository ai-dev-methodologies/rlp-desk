# Vision adopt package — PO-output gates + taxonomy hardening (v0.22.22)

Date: 2026-07-22 · Status: approved (owner rulings after ultracode adversarial review, wf_bf7e570c-bf5)
Source: `docs/incoming-requests/tire-plletdata-vision-2026-07-22-full-autonomy.md`

## Owner rulings framing this scope
- Auto-restart supervisor: **permanently rejected** — every recurring error class is
  eliminated by improving rlp-desk itself, never papered over by an auto-retry layer.
- Owner fact-query channel: **deferred** — no governance IL-2½ amendment; label only.
- This package adopts the surviving pieces: the CONFIRMED supervision-regression gap
  (PO/contract-edit side is thin while worker side is deeply audited) + small taxonomy
  and doc hardenings. AI-PO persona harness stays a future architecture track.

## Scope

### 1. PO-output machine gates (three decoupled hardenings, human-PO-useful today)
a. **gate-receipt → test-spec coverage**: the content-hash binding
   (`src/node/util/gate-receipt.mjs`, wired in `src/commands/rlp-desk.md` §brainstorm,
   `src/node/run.mjs`, `src/scripts/run_ralph_desk.zsh`) currently seals PRD + per-US
   split files. Extend the sealed set to the campaign test-spec file(s). Keep the
   established WARN-loud (never silently proceed, never hard-kill mid-campaign) semantics.
b. **3-doc consistency lint**: new deterministic lint cross-checking PRD ↔ test-spec ↔
   per-US split structural consistency (every US in the split exists in the PRD; AC
   ids referenced by the test-spec exist in the PRD; per-US AC counts consistent).
   Precedent: `_lint_test_density`. Enforcement: at brainstorm/init = REJECT (hard,
   campaign not started); at run-start re-check = WARN-loud (mirror gate-receipt).
c. **Contract-revision audit chain**: append-only
   `.rlp-desk/logs/<slug>/contract-revisions.jsonl` — whenever a sealed contract file's
   hash differs from the receipt at run start, append `{ts, file, old_hash, new_hash,
   receipt_version}` before re-sealing. Follow the story-ledger append-then-lock
   convention. NO actor attribution (git-blame actor identification was previously
   rejected — record the change, not the author).

### 2. recoverable-flag reconciliation (zsh ↔ Node)
zsh `_blocked_recoverable_for_category` blanket-defaults infra_failure→recoverable=true;
Node `_classifyBlock` (campaign-main-loop.mjs) classifies most infra_failure sources
recoverable=false with investigate_*/manual_* actions. Reconcile call-site-by-call-site
with **Node's conservative taxonomy as the reference** (fail-fast wins — owner ruling).
zsh gains per-callsite/per-source overrides where needed; genuinely transient categories
(API transient/backoff class) stay recoverable. Add a shared-fixture parity test
(commit-oracle pattern) pinning zsh↔Node agreement per reason source. Update the
governance §1f wrapper-contract table if any documented mapping changes.

### 3. `external_fact` reason_category (label only — NO channel)
Add to the closed reason_category enum everywhere it is enumerated (governance table,
zsh + Node sentinel writers, `tests/test_us015_sentinel_json_taxonomy.sh`,
artifact/docs enums). Semantics: campaign halted on a contract gap that requires an
owner-supplied out-of-repo fact (e.g. another team's intent behind a data change);
recoverable=false; suggested_action=retry_after_fix (update the contract with the fact,
then relaunch). Halt semantics UNCHANGED — this makes halt-and-classify machine-legible;
it does not create any runtime owner interaction (IL-2½ untouched).

### 4. IL-2¾ third work-type: 검증형 (verification/doctrine-type)
Amend IL-2¾ (governance work-type classification + the brainstorm step in
src/commands/rlp-desk.md): alongside 명세형/발굴형, add 검증형 — a US whose deliverable
is verifying/confirming existing behavior, where the TDD RED phase is structurally
impossible; classification auto-assigns the doctrine-based alternative gate
(the existing RED-불가 exemption plumbing) instead of leaving it per-campaign doctrine.

### 5. init CLI version stamp
At campaign init, record `codex --version` / `claude --version` (best-effort,
non-blocking, absent tools recorded as "not installed") into session-config or the
campaign memo. Diagnostic breadcrumb for CLI-release incidents (0.145.0 class);
NO version pinning/enforcement.

## Testing
- Node: gate-receipt test-spec coverage; consistency-lint unit (pass/fail fixtures);
  revision-chain append + append-then-lock; recoverable parity (shared fixtures).
- zsh: parity side of §2; us015 taxonomy update for external_fact; structural asserts
  for §4/§5 wiring.
- Full `npm run test:zsh` + `npm run test:node` green.
- governance.md + rlp-desk.md change ⇒ Self-Verification Gate (3 scenarios) before commit.

## Ship
v0.22.22 — Tier-1 + npm publish (registry current at 0.22.21).
