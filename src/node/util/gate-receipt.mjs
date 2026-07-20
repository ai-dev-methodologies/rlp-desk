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
//   1. files = [ prd-<slug>.md ] + sort_C( prd-<slug>-US-*.md )   (main first)
//   2. per file: "<basename>:<sha256(file bytes)>\n"
//   3. prd_sha256 = sha256( concat of those lines, utf8 )
// A missing main PRD hashes the empty set → empty-string sentinel hash.

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

// Deterministic content hash over all PRD files. Empty (no main PRD) → ''.
export function computePrdContentHash(plansDir, slug) {
  const files = listPrdFiles(plansDir, slug);
  if (files.length === 0) return '';
  const lines = files.map((f) => {
    const base = path.basename(f);
    const fileHash = sha256Hex(fs.readFileSync(f));
    return `${base}:${fileHash}\n`;
  });
  return sha256Hex(Buffer.from(lines.join(''), 'utf8'));
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
    schema_version: '1.0',
    slug,
    prd_sha256: prdSha256,
    prd_files: listPrdFiles(plansDir, slug).map((f) => path.basename(f)),
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
  const liveHash = computePrdContentHash(plansDir, slug);
  const receipt = readGateReceipt(plansDir, slug);
  if (!receipt || typeof receipt.prd_sha256 !== 'string' || receipt.prd_sha256 === '') {
    return { status: 'missing', liveHash, receiptHash: null, receipt };
  }
  if (receipt.prd_sha256 === liveHash) {
    return { status: 'ok', liveHash, receiptHash: receipt.prd_sha256, receipt };
  }
  return { status: 'mismatch', liveHash, receiptHash: receipt.prd_sha256, receipt };
}
