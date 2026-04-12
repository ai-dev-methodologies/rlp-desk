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
      promptLines.push(`When done, signal verify with us_id="${nextUs}" (not "ALL").`);
      promptLines.push(`Signal format: {"iteration": N, "status": "verify", "us_id": "${nextUs}", ...}`);
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

  if (autonomousMode) {
    appendAutonomousModeSection(promptLines, { conflictLogPath, verifier: true });
  }

  return `${promptLines.join('\n')}\n`;
}
