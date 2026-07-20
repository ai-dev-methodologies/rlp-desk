// Campaign-scope waiver validator (US-002, PRD campaign-hardening-v1).
//
// A `.rlp-desk/plans/waivers.json` lets an operator waive a gate finding that
// is PROVEN pre-existing by an immutable baseline artifact — the failure mode
// #2 deadlock (a real vuln predates the campaign, no in-loop N/A path, worker
// self-blocks, terminal BLOCKED). The waiver channel is FAIL CLOSED: a waiver
// is honored ONLY when (a) it is well-formed, (b) it is bound to the running
// campaign slug, (c) the named baseline artifact exists, (d) that artifact's
// recomputed sha256 equals the recorded hash (immutability), and (e) the
// finding_id is actually present in the artifact's findings[] for that gate.
// There is NO assertion fallback and NO commit-ancestry check (ancestry adds no
// security and creates drift — AC2.2). Authorization is out-of-band: the
// operator supplies the expected waivers.json sha256 at process start via
// `--waivers-sha256`; a present file whose hash the flag does not authorize has
// EVERY waiver rejected (a worker cannot smuggle a waiver in by pre-writing the
// file — AC2.4).
//
// This module is the PURE-FUNCTION validator (Principle 6): `validateWaivers`
// is I/O-free and takes injected artifact facts. `loadCampaignWaivers` is the
// thin fs wrapper that reads the file, computes hashes, and builds the artifact
// resolver. The zsh production leader (lib_ralph_desk.zsh `load_campaign_waivers`)
// implements the identical enum + semantics; a shared-fixture set drives both.

import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

// The complete rejection-reason enum (AC2.2a). Every rejected waiver names
// exactly one of these; the zsh mirror uses the same string values.
export const WAIVER_REJECT_REASONS = Object.freeze({
  ARTIFACT_MISSING: 'artifact_missing',
  SHA256_MISMATCH: 'sha256_mismatch',
  FINDING_NOT_IN_ARTIFACT: 'finding_not_in_artifact',
  SLUG_MISMATCH: 'slug_mismatch',
  MALFORMED_SCHEMA: 'malformed_schema',
  UNAUTHORIZED_HASH_CHANGE: 'unauthorized_hash_change',
});

// AC2.1 schema (array of): id, campaign_slug, gate, finding_id,
// baseline_artifact_path, baseline_artifact_sha256, reason — all required,
// all non-empty strings.
const REQUIRED_FIELDS = [
  'id',
  'campaign_slug',
  'gate',
  'finding_id',
  'baseline_artifact_path',
  'baseline_artifact_sha256',
  'reason',
];

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim() !== '';
}

// Stable diagnostic id: the waiver's own id when present, else a positional
// tag so a malformed entry that lacks an id still surfaces loudly (AC2.2a).
function waiverId(waiver, index) {
  return isNonEmptyString(waiver?.id) ? waiver.id : `#${index}`;
}

function schemaError(waiver) {
  if (!waiver || typeof waiver !== 'object' || Array.isArray(waiver)) {
    return 'waiver entry is not a JSON object';
  }
  const missing = REQUIRED_FIELDS.filter((field) => !isNonEmptyString(waiver[field]));
  if (missing.length > 0) {
    return `missing or non-string required field(s): ${missing.join(', ')}`;
  }
  return null;
}

function short(hash) {
  return typeof hash === 'string' ? hash.slice(0, 12) : '(none)';
}

// Evaluate the waiver set against injected facts. Pure — no fs, no crypto.
//
// input:
//   waiversRaw       raw waivers.json string, an already-parsed array, or null
//                    (null/undefined → file absent → zero waivers, no rejections)
//   runningSlug      the campaign slug the leader is running
//   expectedSha256   authorization hash from --waivers-sha256 (null/'' = flag absent)
//   actualSha256     recomputed sha256 of the waivers.json file (null when absent)
//   resolveArtifact  (baseline_artifact_path) => { exists, sha256, findings, gate }
//                    injected so this function stays I/O-free
//
// returns { honored: [waiver...], rejected: [{ id, reason, detail }...] }.
//   honored → the validated waiver objects (id, gate, finding_id, reason, ...).
//   rejected → one entry per rejected waiver, reason drawn from the enum.
export function validateWaivers({
  waiversRaw = null,
  runningSlug = '',
  expectedSha256 = null,
  actualSha256 = null,
  resolveArtifact = () => ({ exists: false, sha256: null, findings: null, gate: null }),
} = {}) {
  // AC2.4a: file absent → no waivers, the flag is unnecessary.
  if (waiversRaw === null || waiversRaw === undefined) {
    return { honored: [], rejected: [] };
  }

  // Parse. Malformed JSON / non-array → zero honored, one file-level
  // malformed_schema rejection (AC2.1 fail-closed).
  let parsed;
  if (typeof waiversRaw === 'string') {
    try {
      parsed = JSON.parse(waiversRaw);
    } catch {
      return {
        honored: [],
        rejected: [{ id: null, reason: WAIVER_REJECT_REASONS.MALFORMED_SCHEMA, detail: 'waivers.json is not valid JSON' }],
      };
    }
  } else {
    parsed = waiversRaw;
  }
  if (!Array.isArray(parsed)) {
    return {
      honored: [],
      rejected: [{ id: null, reason: WAIVER_REJECT_REASONS.MALFORMED_SCHEMA, detail: 'waivers.json is not a JSON array' }],
    };
  }

  // AC2.4: authorization gate (out-of-band hash). A present file whose actual
  // hash the --waivers-sha256 flag does not authorize (flag absent OR mismatch)
  // has EVERY waiver rejected unauthorized_hash_change. Parsed first so each
  // rejection carries the waiver's own id (loud, per AC2.2a).
  const authorized =
    isNonEmptyString(expectedSha256) && expectedSha256 === actualSha256;
  if (!authorized) {
    const detail = !isNonEmptyString(expectedSha256)
      ? `waivers.json present but no --waivers-sha256 authorization supplied (file sha256 ${short(actualSha256)})`
      : `--waivers-sha256 ${short(expectedSha256)} does not match waivers.json actual sha256 ${short(actualSha256)}`;
    return {
      honored: [],
      rejected: parsed.map((waiver, index) => ({
        id: waiverId(waiver, index),
        reason: WAIVER_REJECT_REASONS.UNAUTHORIZED_HASH_CHANGE,
        detail,
      })),
    };
  }

  // Per-waiver validation. Check order isolates each reason so a fixture can
  // provoke exactly one (schema → slug → artifact_missing → sha256 → finding).
  const honored = [];
  const rejected = [];
  parsed.forEach((waiver, index) => {
    const id = waiverId(waiver, index);

    const schemaErr = schemaError(waiver);
    if (schemaErr) {
      rejected.push({ id, reason: WAIVER_REJECT_REASONS.MALFORMED_SCHEMA, detail: schemaErr });
      return;
    }

    if (waiver.campaign_slug !== runningSlug) {
      rejected.push({
        id,
        reason: WAIVER_REJECT_REASONS.SLUG_MISMATCH,
        detail: `campaign_slug "${waiver.campaign_slug}" does not match running slug "${runningSlug}"`,
      });
      return;
    }

    const artifact = resolveArtifact(waiver.baseline_artifact_path) ?? { exists: false };
    if (!artifact.exists) {
      rejected.push({
        id,
        reason: WAIVER_REJECT_REASONS.ARTIFACT_MISSING,
        detail: `baseline artifact not found: ${waiver.baseline_artifact_path}`,
      });
      return;
    }

    if (artifact.sha256 !== waiver.baseline_artifact_sha256) {
      rejected.push({
        id,
        reason: WAIVER_REJECT_REASONS.SHA256_MISMATCH,
        detail: `baseline artifact sha256 ${short(artifact.sha256)} != recorded ${short(waiver.baseline_artifact_sha256)} (tampered or wrong file)`,
      });
      return;
    }

    // Finding identity on gate + finding_id (AC2.2c). The artifact's own gate
    // (when it records one) must match the waiver's gate, AND the finding_id
    // must be present in findings[]. A mismatch on either is a finding-identity
    // failure — the proof does not cover this finding.
    const findings = Array.isArray(artifact.findings) ? artifact.findings : [];
    const gateMatches = artifact.gate == null || artifact.gate === waiver.gate;
    const findingPresent = gateMatches && findings.some((f) => f && f.finding_id === waiver.finding_id);
    if (!findingPresent) {
      rejected.push({
        id,
        reason: WAIVER_REJECT_REASONS.FINDING_NOT_IN_ARTIFACT,
        detail: `finding_id "${waiver.finding_id}" not present in baseline artifact for gate "${waiver.gate}"`,
      });
      return;
    }

    honored.push({
      id: waiver.id,
      campaign_slug: waiver.campaign_slug,
      gate: waiver.gate,
      finding_id: waiver.finding_id,
      baseline_artifact_path: waiver.baseline_artifact_path,
      baseline_artifact_sha256: waiver.baseline_artifact_sha256,
      reason: waiver.reason,
    });
  });

  return { honored, rejected };
}

// sha256 of a file's raw bytes (hex) — parity with `shasum -a 256 <file>`.
// Returns null when the file cannot be read.
export function sha256OfFile(filePath) {
  try {
    return createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
  } catch {
    return null;
  }
}

// Thin fs wrapper (AC2.6 Node oracle mirror). Reads waivers.json, computes its
// actual sha256, builds a fs-backed artifact resolver rooted at rootDir, and
// delegates the decision to the pure validateWaivers. Returns the validator
// result plus actualSha256 (the rotated authorized snapshot on success — AC2.4b).
export function loadCampaignWaivers({ waiversPath, rootDir, runningSlug, expectedSha256 = null } = {}) {
  let waiversBuf;
  try {
    waiversBuf = fs.readFileSync(waiversPath);
  } catch {
    // File absent → zero waivers (AC2.4a). No rotation.
    return { honored: [], rejected: [], actualSha256: null };
  }
  const actualSha256 = createHash('sha256').update(waiversBuf).digest('hex');

  const resolveArtifact = (artifactPath) => {
    const resolved = path.isAbsolute(artifactPath)
      ? artifactPath
      : path.resolve(rootDir ?? '.', artifactPath);
    let buf;
    try {
      buf = fs.readFileSync(resolved);
    } catch {
      return { exists: false, sha256: null, findings: null, gate: null };
    }
    const sha256 = createHash('sha256').update(buf).digest('hex');
    let gate = null;
    let findings = null;
    try {
      const doc = JSON.parse(buf.toString('utf8'));
      gate = typeof doc?.gate === 'string' ? doc.gate : null;
      findings = Array.isArray(doc?.findings) ? doc.findings : [];
    } catch {
      // A baseline artifact that is not parseable JSON cannot prove a finding
      // identity — leave findings null so finding_not_in_artifact fires.
      findings = null;
    }
    return { exists: true, sha256, findings, gate };
  };

  const result = validateWaivers({
    waiversRaw: waiversBuf.toString('utf8'),
    runningSlug,
    expectedSha256,
    actualSha256,
    resolveArtifact,
  });
  return { ...result, actualSha256 };
}
