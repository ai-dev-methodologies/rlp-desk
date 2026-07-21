// request-f §3: operator ledger-seed.
//
// The story-scoped confirmation path (request-e ②, derive_verification_mode's
// 4th-arg branch in lib_ralph_desk.zsh) routes an already-verified story to
// `confirmation` ONLY when a PRD-bound verified-ledger entry exists for it. That
// entry is written exclusively on a consensus pass (_append_verified_ledger). A
// story that could NEVER earn a consensus pass because of an OLD-VERSION defect
// (the pa-foundation US-000: a killed verifier + mode misrouting) therefore has
// no entry and stays pinned to `build` forever — the exact iter-012 case ② was
// meant to rescue. This command is the formal recovery path: an operator, having
// re-run the claude leg fresh and captured its pass verdict, seeds the routing
// entry by hand.
//
// ANTI-GAMING INVARIANTS (BINDING — do not weaken):
//  * A seed NEVER grants a pass. It only supplies the ledger anchor that routes
//    verification MODE (build vs confirmation dispatch). Both verifier legs
//    (claude + codex) still run their OWN fresh re-verification every iteration —
//    that invariant is untouched. The seed cannot make a broken deliverable pass.
//  * `seeded:true` + `operator_note` make every seeded entry audit-visible in the
//    durable ledger (grep-able; never a silent credit).
//  * Operator-only command, documented to be run while the campaign is STOPPED.
//    There is NO runtime enforcement of "stopped" (the append-then-lock 0444
//    primitive is anti-sloppiness, not a concurrency boundary) — comment, not
//    code, is the contract. Run it with the loop halted.

import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';

import { normalizeVerdict } from '../shared/verdict-schema.mjs';

export const US_ID_RE = /^US-[0-9]+$/;

// The durable verified ledger the zsh leader appends to
// (run_ralph_desk.zsh:487 VERIFIED_LEDGER="$MEMOS_DIR/${SLUG}-verified.jsonl").
export function ledgerPath(memosDir, slug) {
  return path.join(memosDir, `${slug}-verified.jsonl`);
}

// The main PRD the consumer hashes (run_ralph_desk.zsh:435
// PRD_FILE="$DESK/plans/prd-$SLUG.md"). derive_verification_mode binds each
// entry to `git hash-object` of THIS file, so the seed must hash the same file.
export function prdPath(plansDir, slug) {
  return path.join(plansDir, `prd-${slug}.md`);
}

// Mirror _prd_us_set (lib_ralph_desk.zsh:2681):
//   grep -oE '^### US-[0-9]+' | sed 's/^### //' | sort -u
// (sort -u only affects ordering; membership is what the caller checks.)
export function extractPrdUsSet(prdContent) {
  const set = [];
  for (const match of String(prdContent).matchAll(/^### (US-[0-9]+)/gm)) {
    if (!set.includes(match[1])) set.push(match[1]);
  }
  return set;
}

// `git hash-object <file>` — content-addressed, needs no object DB, so it works
// in any repo (matches _ledger_prd_hash lib_ralph_desk.zsh:2652).
function gitHashObject(root, file) {
  const res = spawnSync('git', ['hash-object', file], { cwd: root, encoding: 'utf8' });
  if (res.status !== 0) {
    throw new Error(`git hash-object failed for ${file}: ${(res.stderr || '').trim() || 'unknown error'}`);
  }
  return res.stdout.trim();
}

// Resolve the commit anchor to a FULL sha. Default HEAD; an explicit --commit
// must (a) resolve as a commit AND (b) be an ancestor of HEAD — the same two
// gates the story-scoped consumer applies to the entry's commit before it will
// confirm (lib_ralph_desk.zsh:2757-2762).
function resolveCommitAnchor(root, commitArg) {
  if (!commitArg) {
    const head = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
    if (head.status !== 0 || !head.stdout.trim()) {
      throw new Error(`cannot resolve HEAD in ${root} (not a git repo?)`);
    }
    return head.stdout.trim();
  }
  const resolved = spawnSync(
    'git',
    ['-C', root, 'rev-parse', '--verify', '--quiet', `${commitArg}^{commit}`],
    { encoding: 'utf8' },
  );
  if (resolved.status !== 0 || !resolved.stdout.trim()) {
    throw new Error(`--commit ${commitArg} does not resolve to a commit in ${root}`);
  }
  const fullSha = resolved.stdout.trim();
  const ancestor = spawnSync(
    'git',
    ['-C', root, 'merge-base', '--is-ancestor', fullSha, 'HEAD'],
    { encoding: 'utf8' },
  );
  if (ancestor.status !== 0) {
    throw new Error(`--commit ${commitArg} is not an ancestor of HEAD`);
  }
  return fullSha;
}

// Append one JSONL line keeping the file 0444 between writes — the Node mirror
// of _ledger_append_line (lib_ralph_desk.zsh:2621): unlock (if the file exists)
// → append → relock in a finally that ALWAYS runs, so an interruption cannot
// leave a half-written or writable ledger. A missing file is created (+ parent
// dirs) then locked.
export function appendLockedLine(ledgerFile, line) {
  fs.mkdirSync(path.dirname(ledgerFile), { recursive: true });
  const existed = fs.existsSync(ledgerFile);
  if (existed) {
    try {
      fs.chmodSync(ledgerFile, 0o644);
    } catch (err) {
      // Unlock failure aborts the append (ledger untouched) — mirrors zsh's
      // fail-closed "append aborted" when chmod 0644 fails.
      throw new Error(`verified ledger unlock failed (${ledgerFile}): ${err.message}`);
    }
  }
  try {
    fs.appendFileSync(ledgerFile, line.endsWith('\n') ? line : `${line}\n`);
  } finally {
    try {
      fs.chmodSync(ledgerFile, 0o444);
    } catch { /* relock best-effort — mirrors zsh log_warn on relock failure */ }
  }
}

// Build the single JSONL entry. Contract order preserved (JSON.stringify keeps
// insertion order).
//
// NO `iter` field: the ledger READERS were surveyed —
//   - derive_verification_mode (lib_ralph_desk.zsh) selects .us_id/.commit/.prd/.coverage
//   - run_ralph_desk.zsh:4317 resume coverage scan reads .us_id only
//   - init_ralph_desk.zsh:519 just `rm -f`s the file
// none read `.iter`. The only `.iter` readers (campaign-reporting.mjs) read the
// analytics campaign.jsonl, a DIFFERENT file. So `iter` is omitted per §3 spec.
export function buildLedgerEntry({ usId, commit, prdHash, note, now = new Date() }) {
  return {
    us_id: usId,
    verified_at: now.toISOString(),
    commit,
    prd: prdHash,
    seeded: true,
    operator_note: note,
  };
}

// Full seed: fail-closed validation (ledger untouched on ANY failure), then a
// single append-then-lock. Returns { entry, ledgerFile, prdHash, commit }.
export function seedLedger({
  root,
  plansDir,
  memosDir,
  slug,
  usId,
  evidencePath,
  note,
  commit: commitArg,
  now = new Date(),
}) {
  // (4) --note required, non-empty.
  if (typeof note !== 'string' || note.trim() === '') {
    throw new Error('--note is required and must be a non-empty operator note');
  }
  // (2, shape) us_id must be a single-story marker.
  if (!US_ID_RE.test(String(usId))) {
    throw new Error(`invalid us_id: ${JSON.stringify(usId)} — must match ^US-[0-9]+$`);
  }
  // (3) --evidence required; exists; single JSON object; normalized verdict
  // "pass"; us_id matches exactly (an "ALL" evidence file is rejected here).
  if (!evidencePath) {
    throw new Error('--evidence <path-to-claude-pass-verdict.json> is required');
  }
  if (!fs.existsSync(evidencePath)) {
    throw new Error(`evidence file not found: ${evidencePath}`);
  }
  let evidence;
  try {
    evidence = JSON.parse(fs.readFileSync(evidencePath, 'utf8'));
  } catch (err) {
    throw new Error(`evidence is not valid JSON (${evidencePath}): ${err.message}`);
  }
  if (evidence === null || typeof evidence !== 'object' || Array.isArray(evidence)) {
    throw new Error(`evidence must be a single JSON object (${evidencePath})`);
  }
  const verdict = normalizeVerdict(evidence).verdict;
  if (verdict !== 'pass') {
    throw new Error(
      `evidence verdict is not "pass" (got ${JSON.stringify(verdict ?? null)}) — `
        + 'a seed requires a claude-leg pass verdict',
    );
  }
  if (evidence.us_id !== usId) {
    throw new Error(
      `evidence us_id ${JSON.stringify(evidence.us_id ?? null)} does not match ${usId} `
        + '(an "ALL" or wrong-story verdict is rejected)',
    );
  }
  // (1) PRD file exists; hash it — this hash becomes the entry's `prd` binding.
  const prdFile = prdPath(plansDir, slug);
  if (!fs.existsSync(prdFile)) {
    throw new Error(`PRD not found: ${prdFile} — run \`init ${slug}\` first`);
  }
  const prdHash = gitHashObject(root, prdFile);
  // (2, membership) us_id must be a US marker in that PRD.
  const prdUs = extractPrdUsSet(fs.readFileSync(prdFile, 'utf8'));
  if (!prdUs.includes(usId)) {
    throw new Error(
      `${usId} is not a US marker in the PRD (${prdFile}) — markers: ${prdUs.join(', ') || '(none)'}`,
    );
  }
  // (5) commit anchor: default HEAD; explicit --commit must resolve + be an
  // ancestor of HEAD. Records the FULL sha.
  const commit = resolveCommitAnchor(root, commitArg);

  // All validation passed — build and append (this is the FIRST ledger touch).
  const entry = buildLedgerEntry({ usId, commit, prdHash, note, now });
  const ledgerFile = ledgerPath(memosDir, slug);
  appendLockedLine(ledgerFile, JSON.stringify(entry));
  return { entry, ledgerFile, prdHash, commit };
}
