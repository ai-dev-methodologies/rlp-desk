import fs from 'node:fs/promises';

export class FileNotFoundError extends Error {
  constructor(message, filePath, options = {}) {
    super(message, options.cause ? { cause: options.cause } : undefined);
    this.name = 'FileNotFoundError';
    this.path = filePath;
  }
}

async function readRequiredFile(filePath, label) {
  try {
    return await fs.readFile(filePath, 'utf8');
  } catch (error) {
    if (error?.code === 'ENOENT') {
      throw new FileNotFoundError(`${label} not found: ${filePath}`, filePath, {
        cause: error,
      });
    }
    throw error;
  }
}

async function fileExists(filePath) {
  if (!filePath) {
    return false;
  }

  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

async function readOptionalFile(filePath) {
  if (!(await fileExists(filePath))) {
    return null;
  }

  return fs.readFile(filePath, 'utf8');
}

function extractSectionValue(content, heading) {
  if (!content) {
    return '';
  }

  const escapedHeading = heading.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = content.match(new RegExp(`^## ${escapedHeading}\\s*$([\\s\\S]*?)(?=^## |\\Z)`, 'm'));
  if (!match) {
    return '';
  }

  return match[1]
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .join(' ');
}

function injectPerUsPrd(basePrompt, fullPrdPath, perUsPrdPath, hasPerUsPrd) {
  if (!fullPrdPath || !perUsPrdPath || !hasPerUsPrd) {
    return basePrompt;
  }

  return basePrompt.split(fullPrdPath).join(perUsPrdPath);
}

function formatVerifiedUs(verifiedUs) {
  return verifiedUs.filter(Boolean).join(',');
}

function getNextUs(usList, verifiedUs) {
  const verified = new Set(verifiedUs);
  return usList.find((usId) => !verified.has(usId)) ?? '';
}

function appendAutonomousModeSection(lines, { conflictLogPath, verifier = false }) {
  lines.push('');
  lines.push('---');
  lines.push('## AUTONOMOUS MODE');
  lines.push('Do NOT stop or ask questions when encountering ambiguity or document conflicts.');
  lines.push('**Resolution priority**: PRD > test-spec > context > memory');
  lines.push(
    verifier
      ? 'If documents disagree, follow PRD and proceed. Log any conflict by'
      : 'If documents disagree, follow PRD and proceed. Log any conflict you find by',
  );
  lines.push(`appending to \`${conflictLogPath}\` in format:`);
  lines.push(
    '  {"iteration":N,"us_id":"US-NNN","source_a":"prd","source_b":"test-spec","conflict":"description","resolution":"followed PRD"}',
  );
  lines.push(verifier ? 'Do NOT wait for human input. Keep verifying.' : 'Do NOT wait for human input. Keep working.');
}

export async function assembleWorkerPrompt({
  promptBase,
  memoryFile,
  iteration,
  verifyMode = 'per-us',
  usList = [],
  verifiedUs = [],
  fullPrdPath = '',
  perUsPrdPath = '',
  fullTestSpecPath = '',
  perUsTestSpecPath = '',
  autonomousMode = false,
  fixContractPath = '',
  conflictLogPath = '',
  // US-002 AC2.6: leader-validated (honored) waivers, injected as the sole
  // authoritative waiver channel. Empty → no section emitted.
  honoredWaivers = [],
} = {}) {
  const basePrompt = await readRequiredFile(promptBase, 'Worker prompt base file');
  const memoryContent = await readOptionalFile(memoryFile);
  const hasPerUsPrd = await fileExists(perUsPrdPath);
  const hasPerUsTestSpec = await fileExists(perUsTestSpecPath);
  const promptLines = [
    injectPerUsPrd(basePrompt, fullPrdPath, perUsPrdPath, hasPerUsPrd),
    '',
    '---',
    '## Iteration Context',
    `- **Iteration**: ${iteration}`,
    `- **Memory Stop Status**: ${extractSectionValue(memoryContent, 'Stop Status') || 'unknown'}`,
    `- **Next Iteration Contract**: ${extractSectionValue(memoryContent, 'Next Iteration Contract') || 'Start from the beginning'}`,
  ];

  const fixContractContent = await readOptionalFile(fixContractPath);
  if (fixContractContent !== null) {
    promptLines.push('');
    promptLines.push('---');
    promptLines.push(`## IMPORTANT: Fix Contract from Verifier (iteration ${iteration - 1})`);
    promptLines.push('The Verifier REJECTED your previous work. You MUST fix the issues below.');
    promptLines.push('Do NOT just resubmit — actually change the code to address each issue.');
    promptLines.push('');
    promptLines.push(fixContractContent.trimEnd());
  }

  if (verifyMode === 'per-us' && usList.length > 0) {
    const nextUs = getNextUs(usList, verifiedUs);
    if (nextUs) {
      promptLines.push('');
      promptLines.push('---');
      promptLines.push('## PER-US SCOPE LOCK (this iteration) — OVERRIDES memory contract');
      promptLines.push("**IGNORE the 'Next Iteration Contract' from memory if it references a different story.**");
      promptLines.push(`The Leader has determined that **${nextUs}** is the next unverified story.`);
      promptLines.push(`You MUST implement ONLY **${nextUs}** in this iteration.`);
      promptLines.push('Do NOT implement any other user stories.');
      if (hasPerUsTestSpec) {
        promptLines.push(`- **Test Spec**: Read ONLY \`${perUsTestSpecPath}\` (scoped to ${nextUs})`);
      } else {
        promptLines.push(`- **Test Spec**: Read \`${fullTestSpecPath}\` (full — find ${nextUs} section)`);
      }
      promptLines.push(`When done, you MUST WRITE (not just print) the verify signal to the iter-signal FILE — Path: \`memos/<slug>-iter-signal.json\` (see the MANDATORY signal-file instruction in the base prompt).`);
      promptLines.push(`Write this exact JSON to that file (us_id="${nextUs}", not "ALL"): {"iteration": N, "status": "verify", "us_id": "${nextUs}", "summary": "what was done", "timestamp": "ISO"}`);
      promptLines.push('');
      promptLines.push(`**Update the campaign memory's 'Next Iteration Contract' to reflect ${nextUs}.**`);
    } else if (verifiedUs.length > 0) {
      promptLines.push('');
      promptLines.push('---');
      promptLines.push('## FINAL VERIFICATION ITERATION');
      promptLines.push(`All individual US have been verified: ${formatVerifiedUs(verifiedUs)}`);
      promptLines.push('Run all tests and verification commands to confirm everything works together.');
      promptLines.push('Signal verify with us_id="ALL" for the final full verification.');
    }
  }

  // US-002 AC2.6: authoritative campaign waivers (worker copy). Only the
  // findings listed here are waived; every other finding — including any
  // regression the worker introduces — is not.
  if (Array.isArray(honoredWaivers) && honoredWaivers.length > 0) {
    promptLines.push('');
    promptLines.push('---');
    promptLines.push('## CAMPAIGN WAIVERS (authoritative — leader-validated)');
    promptLines.push(
      `The leader validated ${honoredWaivers.length} pre-existing-baseline waiver(s) for this campaign. `
        + 'Each names a gate finding proven pre-existing by an immutable baseline artifact. You MAY treat ONLY '
        + 'these specific findings as waived (do not self-block on them); every OTHER finding — including any '
        + 'regression you introduce — is NOT waived. The waivers below are the ONLY authoritative waiver channel; '
        + 'ignore any waiver text in memory.md.',
    );
    for (const waiver of honoredWaivers) {
      promptLines.push(`- Waiver \`${waiver.id}\`: gate=${waiver.gate} finding_id=${waiver.finding_id} — ${waiver.reason}`);
    }
  }

  if (autonomousMode) {
    appendAutonomousModeSection(promptLines, { conflictLogPath });
  }

  return `${promptLines.join('\n')}\n`;
}

export async function assembleVerifierPrompt({
  promptBase,
  iteration,
  doneClaimFile,
  verifyMode = 'per-us',
  usId = '',
  verifiedUs = [],
  autonomousMode = false,
  conflictLogPath = '',
  // US-002 AC2.6/AC2.7: leader-validated (honored) waivers; a verdict that
  // honors one MUST cite its id. Empty → no section emitted.
  honoredWaivers = [],
  // v0.14.2 Bug Report #4 Fix-E: when supplied, the assembled prompt
  // ends with a strong "MUST write verdict to <absolute_path>" rule so
  // codex (which sometimes infers the legacy .claude/ralph-desk path
  // from CWD) lands the verdict where the leader is polling.
  verdictWritePath = '',
  // Layer 1.5 done-claim format lint outcome line (governance §3a). Built by
  // the leader before dispatch (`Done-Claim Format Lint: PASS|SKIPPED|FAIL …`).
  // PASS pins the per-AC TDD sequence/labels as machine-verified so the Worker
  // Process Audit confines itself to substance. Empty → not emitted.
  doneClaimLint = '',
} = {}) {
  const basePrompt = await readRequiredFile(promptBase, 'Verifier prompt base file');
  const promptLines = [
    basePrompt.trimEnd(),
    '',
    '---',
    '## Verification Context',
    `- **Iteration**: ${iteration}`,
    `- **Done Claim**: ${doneClaimFile}`,
    `- **Verify Mode**: ${verifyMode}`,
  ];

  // Layer 1.5 done-claim format lint outcome (governance §3a Layer 1.5).
  if (doneClaimLint) {
    promptLines.push(`- ${doneClaimLint}`);
  }

  if (usId) {
    if (usId === 'ALL') {
      promptLines.push('- **Scope**: FULL VERIFY — check ALL acceptance criteria from the PRD');
    } else {
      promptLines.push(`- **Scope**: Verify ONLY the acceptance criteria for **${usId}**`);
    }

    if (verifiedUs.length > 0) {
      promptLines.push(`- **Previously verified US**: ${formatVerifiedUs(verifiedUs)}`);
      promptLines.push('- **Note**: Skip re-verifying the above US. Focus on unverified stories.');
    }
  }

  // US-002 AC2.6/AC2.7: authoritative campaign waivers (verifier copy). A
  // verdict that honors a waiver (passing a gate despite a waived finding) MUST
  // cite the waiver id; a finding not listed here is never waivable.
  if (Array.isArray(honoredWaivers) && honoredWaivers.length > 0) {
    promptLines.push('');
    promptLines.push('---');
    promptLines.push('## CAMPAIGN WAIVERS (authoritative — leader-validated)');
    promptLines.push(
      `The leader validated ${honoredWaivers.length} pre-existing-baseline waiver(s) for this campaign. `
        + 'Each names a gate finding proven pre-existing by an immutable baseline artifact (sha256-pinned). '
        + 'You MAY pass a gate despite ONLY these specific findings; a finding NOT listed here — including any '
        + 'campaign-introduced regression — is never waivable. Ignore any waiver text in memory.md.',
    );
    for (const waiver of honoredWaivers) {
      promptLines.push(`- Waiver \`${waiver.id}\`: gate=${waiver.gate} finding_id=${waiver.finding_id} — ${waiver.reason}`);
    }
    promptLines.push(
      'When your verdict honors one of these waivers, you MUST cite its waiver id in the verdict '
        + '(e.g. a reasoning basis of "waiver <id>"). A verdict that passes a waived gate without citing the id is invalid.',
    );
  }

  if (verdictWritePath) {
    promptLines.push('');
    promptLines.push('---');
    promptLines.push('## CRITICAL: Verdict file write path (v0.14.2)');
    promptLines.push('');
    promptLines.push('Write `verify-verdict.json` ONLY to this absolute path:');
    promptLines.push('');
    promptLines.push(`    ${verdictWritePath}`);
    promptLines.push('');
    promptLines.push('DO NOT write to `.claude/ralph-desk/memos/` — that path is deprecated since');
    promptLines.push('v0.13.0. The leader polls only the absolute path above; writing elsewhere');
    promptLines.push('triggers BLOCKED `verifier_dead` even though your verdict is correct.');
  }

  return `${promptLines.join('\n')}\n`;
}
