// request-d ①-b: gate-receipt binding.
//
// The brainstorm gate (Ambiguity Gate IL-2 + 무인-완주 unattended-completion
// check + Task Sizing) lives in the /rlp-desk brainstorm PROCEDURE. Nothing
// stopped an operator from authoring or editing a PRD *outside* that procedure
// and running it ungated (the pa-foundation field report: an unified PRD and a
// mid-campaign US-000 that never passed the gate). This module binds the gate to
// the ARTIFACT: a receipt records the content hash of every PRD file at the
// moment the gate passed; init/run recompute that hash and surface any drift.
//
// The hash construction here is intentionally simple and byte-for-byte
// reproducible by the zsh leader (lib_ralph_desk.zsh `compute_prd_content_hash`)
// so both leaders reach the same verdict:
//   1. files = [ prd-<slug>.md ] + sort_C( prd-<slug>-US-*.md )          (PRD, main first)
//            + [ test-spec-<slug>.md ] + sort_C( test-spec-<slug>-US-*.md ) (test-spec)
//   2. per file: "<basename>:<sha256(file bytes)>\n"
//   3. prd_sha256 = sha256( concat of those lines, utf8 )
// A missing main PRD hashes the empty set → empty-string sentinel hash.
//
// vision-adopt §1a: the sealed set now also covers the campaign test-spec
// file(s) — the PRD and test-spec together are the contract a campaign runs
// against, so an out-of-gate edit to either is drift. Test-spec files sort
// AFTER all PRD files so an existing sealed campaign that had no test-spec is
// unaffected until one appears. WARN-loud semantics are unchanged.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

// Enumerate the PRD files that make up a campaign's authoritative plan, in the
// deterministic order the hash is computed over. Main PRD first, then per-US
// files sorted with a plain byte (LC_ALL=C-equivalent) comparison so the zsh
// `sort` and this JS sort agree.
export function listPrdFiles(plansDir, slug) {
  const files = [];
  const main = path.join(plansDir, `prd-${slug}.md`);
  if (fs.existsSync(main)) files.push(main);
  let entries = [];
  try {
    entries = fs.readdirSync(plansDir);
  } catch {
    entries = [];
  }
  const prefix = `prd-${slug}-US-`;
  const perUs = entries
    .filter((name) => name.startsWith(prefix) && name.endsWith('.md'))
    .sort(); // default JS string sort == byte order for ASCII basenames
  for (const name of perUs) files.push(path.join(plansDir, name));
  return files;
}

// vision-adopt §1a: enumerate the campaign test-spec files (main test-spec first,
// then per-US split files) in the same deterministic byte order. Unlike the PRD,
// there is no "anchor" file requirement — a campaign may have a per-US-split
// test-spec, a monolithic one, or (for a very small campaign) none. Whatever
// exists is sealed.
export function listTestSpecFiles(plansDir, slug) {
  const files = [];
  const main = path.join(plansDir, `test-spec-${slug}.md`);
  if (fs.existsSync(main)) files.push(main);
  let entries = [];
  try {
    entries = fs.readdirSync(plansDir);
  } catch {
    entries = [];
  }
  const prefix = `test-spec-${slug}-US-`;
  const perUs = entries
    .filter((name) => name.startsWith(prefix) && name.endsWith('.md'))
    .sort();
  for (const name of perUs) files.push(path.join(plansDir, name));
  return files;
}

// The full sealed set: PRD files first, then test-spec files. This is the exact
// order the content hash is computed over (mirrored by the zsh leader). The PRD
// is the anchor — with no main PRD there is no sealable contract, so this
// returns [] even if orphan test-spec files exist (keeps listing, file_hashes
// and the content hash mutually consistent).
export function listContractFiles(plansDir, slug) {
  if (!fs.existsSync(path.join(plansDir, `prd-${slug}.md`))) return [];
  return [...listPrdFiles(plansDir, slug), ...listTestSpecFiles(plansDir, slug)];
}

// Per-file sha256 of every sealed contract file, keyed by basename. Enables the
// vision-adopt §1c revision-audit chain to record which specific file drifted
// (old_hash → new_hash) rather than only the combined bundle hash.
export function computeFileHashes(plansDir, slug) {
  const out = {};
  for (const f of listContractFiles(plansDir, slug)) {
    out[path.basename(f)] = sha256Hex(fs.readFileSync(f));
  }
  return out;
}

function hashFileList(files) {
  if (files.length === 0) return '';
  const lines = files.map((f) => {
    const base = path.basename(f);
    const fileHash = sha256Hex(fs.readFileSync(f));
    return `${base}:${fileHash}\n`;
  });
  return sha256Hex(Buffer.from(lines.join(''), 'utf8'));
}

// Deterministic content hash over the whole sealed set (PRD + test-spec).
// Empty (no main PRD) → '' — the PRD remains the anchor: a test-spec with no
// PRD is not a sealable contract.
export function computePrdContentHash(plansDir, slug) {
  if (!fs.existsSync(path.join(plansDir, `prd-${slug}.md`))) return '';
  return hashFileList(listContractFiles(plansDir, slug));
}

// vision-adopt §1a backward-compat: the PRD-ONLY hash (the pre-vision-adopt
// sealed set). Schema-1.0 receipts (written before test-spec was sealed) hold a
// PRD-only `prd_sha256`, so their live comparison MUST use this — otherwise
// every released campaign would false-mismatch the moment a test-spec exists.
export function computeLegacyPrdHash(plansDir, slug) {
  if (!fs.existsSync(path.join(plansDir, `prd-${slug}.md`))) return '';
  return hashFileList(listPrdFiles(plansDir, slug));
}

// A receipt predates the vision-adopt sealed set (schema 1.0) when it has no
// per-file `file_hashes` map. Such a receipt's `prd_sha256` is PRD-only.
function receiptIsLegacy(receipt) {
  return !receipt || !receipt.file_hashes || typeof receipt.file_hashes !== 'object';
}

// The live hash to compare a given receipt against: PRD-only for a legacy
// receipt, full sealed set for a 1.1+ receipt. Re-sealing (revise / next init)
// upgrades a legacy receipt to 1.1 naturally.
function liveHashForReceipt(plansDir, slug, receipt) {
  return receiptIsLegacy(receipt)
    ? computeLegacyPrdHash(plansDir, slug)
    : computePrdContentHash(plansDir, slug);
}

export function gateReceiptPath(plansDir, slug) {
  return path.join(plansDir, `gate-receipt-${slug}.json`);
}

// Write the receipt from the CURRENT on-disk PRD state. `scorecard` is a free
// text summary the slash flow passes through (e.g. "PASS:29 WARN:3 REJECT:0").
export function writeGateReceipt(plansDir, slug, { scorecard = '' } = {}) {
  const prdSha256 = computePrdContentHash(plansDir, slug);
  if (prdSha256 === '') {
    throw new Error(
      `no PRD found for slug "${slug}" under ${plansDir} — run \`init ${slug}\` first, then seal the gate`,
    );
  }
  const receipt = {
    schema_version: '1.1',
    slug,
    prd_sha256: prdSha256,
    // vision-adopt §1a: prd_files now enumerates the full sealed set (PRD +
    // test-spec). Name kept for backward-compat with existing receipt readers.
    prd_files: listContractFiles(plansDir, slug).map((f) => path.basename(f)),
    // vision-adopt §1c: per-file hashes so the revision-audit chain can name the
    // specific drifted file. Absent on schema 1.0 receipts (handled gracefully).
    file_hashes: computeFileHashes(plansDir, slug),
    scorecard: String(scorecard || '').trim(),
    passed_at: new Date().toISOString(),
  };
  fs.mkdirSync(plansDir, { recursive: true });
  const target = gateReceiptPath(plansDir, slug);
  fs.writeFileSync(target, `${JSON.stringify(receipt, null, 2)}\n`);
  return { receipt, path: target };
}

export function readGateReceipt(plansDir, slug) {
  const target = gateReceiptPath(plansDir, slug);
  if (!fs.existsSync(target)) return null;
  try {
    return JSON.parse(fs.readFileSync(target, 'utf8'));
  } catch {
    return null; // malformed receipt treated as absent (verify → missing)
  }
}

// Compare the live PRD hash to the receipt.
//   { status: 'ok'       } — receipt present, hash matches
//   { status: 'missing'  } — no receipt (or malformed): pre-receipt / ungated
//   { status: 'mismatch' } — receipt present, live hash differs (edited/ungated)
// Backward-compat: 'missing' is a WARN-and-proceed (old campaigns predate the
// receipt); 'mismatch' is a LOUD WARN (a PRD changed after it was sealed).
export function verifyGateReceipt(plansDir, slug) {
  const receipt = readGateReceipt(plansDir, slug);
  // vision-adopt §1a backward-compat: compare against the hash basis the receipt
  // was sealed with (PRD-only for schema 1.0, full sealed set for 1.1+). A
  // legacy receipt whose PRD+test-spec are untouched must read as 'ok', not a
  // spurious 'mismatch' driven purely by the sealed-set expansion.
  const liveHash = liveHashForReceipt(plansDir, slug, receipt);
  if (!receipt || typeof receipt.prd_sha256 !== 'string' || receipt.prd_sha256 === '') {
    return { status: 'missing', liveHash, receiptHash: null, receipt };
  }
  if (receipt.prd_sha256 === liveHash) {
    return { status: 'ok', liveHash, receiptHash: receipt.prd_sha256, receipt };
  }
  return { status: 'mismatch', liveHash, receiptHash: receipt.prd_sha256, receipt };
}

// vision-adopt §1c: contract-revision audit chain. When a sealed contract file's
// hash differs from the receipt at run start, record the change (never the
// author — git-blame actor identification was rejected) as an append-only JSONL
// line. Follows the story-ledger append-then-lock convention: the log stays
// chmod 0444 between appends so a worker cannot casually rewrite the leader's
// audit trail (anti-sloppiness, not a security boundary).
//
// Idempotent: the same file→(old_hash→new_hash) transition is recorded once even
// though the run path re-checks on every start (the receipt is WARN-only, not
// auto-re-sealed, so old/new stay constant until the operator re-gates). A later
// *further* edit produces a new new_hash → a new record.
//
// Returns the array of records appended this call (possibly empty). Best-effort:
// any error is swallowed and reported as an empty append — an audit-log failure
// must never block a campaign.
function _revisionKey(rec) {
  return `${rec.file}\0${rec.old_hash}\0${rec.new_hash}`;
}

export function appendContractRevisions(plansDir, slug, revisionsLogPath) {
  try {
    const receipt = readGateReceipt(plansDir, slug);
    if (!receipt || typeof receipt.prd_sha256 !== 'string' || receipt.prd_sha256 === '') {
      return []; // no sealed receipt → nothing to compare against
    }
    // vision-adopt §1a backward-compat: compare against the receipt's own hash
    // basis. A legacy (schema 1.0) receipt is PRD-only, so a zero-edit campaign
    // must NOT record a bundle-composition "difference" caused purely by the
    // sealed-set expanding to include the test-spec.
    if (receipt.prd_sha256 === liveHashForReceipt(plansDir, slug, receipt)) {
      return []; // no drift
    }
    const receiptVersion = String(receipt.schema_version || '1.0');
    const oldHashes = receiptIsLegacy(receipt) ? null : receipt.file_hashes;
    const ts = new Date().toISOString();
    const candidates = [];
    if (oldHashes) {
      // 1.1+ receipt: per-file diff over the full sealed set.
      const liveHashes = computeFileHashes(plansDir, slug);
      const names = new Set([...Object.keys(oldHashes), ...Object.keys(liveHashes)]);
      for (const name of [...names].sort()) {
        const oldH = oldHashes[name] || '';
        const newH = liveHashes[name] || '';
        if (oldH !== newH) {
          candidates.push({
            ts, file: name, old_hash: oldH, new_hash: newH, receipt_version: receiptVersion,
          });
        }
      }
    } else {
      // Legacy receipt: no per-file hashes. Record the PRD-only bundle drift
      // (old_hash and new_hash share the PRD-only basis, so the record only
      // fires on a genuine PRD edit, not on the test-spec sealed-set expansion).
      candidates.push({
        ts,
        file: '<contract-bundle>',
        old_hash: receipt.prd_sha256,
        new_hash: computeLegacyPrdHash(plansDir, slug),
        receipt_version: receiptVersion,
      });
    }
    if (candidates.length === 0) return [];

    // Idempotency: drop records whose (file, old_hash, new_hash) transition is
    // already in the log.
    const seen = new Set();
    if (fs.existsSync(revisionsLogPath)) {
      for (const line of fs.readFileSync(revisionsLogPath, 'utf8').split('\n')) {
        const t = line.trim();
        if (!t) continue;
        try {
          const rec = JSON.parse(t);
          seen.add(_revisionKey(rec));
        } catch { /* skip malformed prior lines */ }
      }
    }
    const toAppend = candidates.filter((rec) => !seen.has(_revisionKey(rec)));
    if (toAppend.length === 0) return [];

    // Append-then-lock (mirror of the verified-ledger primitive).
    fs.mkdirSync(path.dirname(revisionsLogPath), { recursive: true });
    if (fs.existsSync(revisionsLogPath)) {
      try { fs.chmodSync(revisionsLogPath, 0o644); } catch { /* best-effort unlock */ }
    }
    try {
      fs.appendFileSync(revisionsLogPath, toAppend.map((r) => `${JSON.stringify(r)}\n`).join(''));
    } finally {
      try { fs.chmodSync(revisionsLogPath, 0o444); } catch { /* best-effort relock */ }
    }
    return toAppend;
  } catch {
    return [];
  }
}
