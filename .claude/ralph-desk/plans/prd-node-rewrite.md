# PRD: node-rewrite

## Objective
Rewrite rlp-desk's 3 zsh scripts (run_ralph_desk.zsh ~2700 lines, lib_ralph_desk.zsh ~900 lines, init_ralph_desk.zsh ~900 lines) into Node.js modules. Preserve: fresh context isolation, cross-engine dispatch (Claude+Codex), campaign analytics, tmux real-time observation. tmux control via child_process.execSync/exec. npm package structure maintained. The new Node.js code replaces zsh scripts entirely — no hybrid.

## User Stories

### US-00: Bootstrap Filesystem Foundations
- **Priority**: P0
- **Size**: S
- **Type**: code
- **Risk**: LOW
- **Depends on**: []
- **Acceptance Criteria**:
  - AC1:
    - Given: The Node rewrite needs repo-local filesystem primitives
    - When: `resolveProjectPath(...segments)` is called with repo-local segments
    - Then: it returns an absolute path inside the repository root. Attempts to escape the root must throw an error.
  - AC2:
    - Given: A target file path inside the repository root
    - When: `writeFileAtomic(targetPath, content)` is called
    - Then: it writes the content atomically within the repository root and rejects outside-root targets.
- **Boundary Cases**: no path segments, overwrite existing file, traversal outside root
- **Verification Layers**: L1 (unit tests) + L3 (real filesystem simulation)
- **Status**: implemented

### US-001: Tmux Pane Manager
- **Priority**: P0
- **Size**: M
- **Type**: code
- **Risk**: MEDIUM
- **Depends on**: []
- **Acceptance Criteria**:
  - AC-1.1:
    - Given: A tmux session is active
    - When: pane manager creates a new pane with a given layout
    - Then: pane is created and its ID is returned. `tmux list-panes` confirms the pane exists.
  - AC-1.2:
    - Given: A pane ID and a shell command string
    - When: sendKeys is called
    - Then: the command appears in the pane's capture output within 2 seconds
  - AC-1.3:
    - Given: A pane running a codex or claude process
    - When: waitForProcessExit is called
    - Then: it resolves only after pane_current_command returns to zsh/bash. Must NOT resolve while process is still running.
  - AC-1.4 (negative):
    - Given: An invalid pane ID
    - When: sendKeys is called
    - Then: it throws a TmuxError with the invalid pane ID in the message. Must NOT silently fail.
- **Boundary Cases**: pane already dead, tmux not installed, session name collision
- **Verification Layers**: L1 (unit tests) + L3 (integration with real tmux)
- **Status**: not started

### US-002: CLI Command Builder
- **Priority**: P0
- **Size**: S
- **Type**: code
- **Risk**: LOW
- **Depends on**: []
- **Acceptance Criteria**:
  - AC-2.1:
    - Given: model="opus", effort="max"
    - When: buildClaudeCmd("tui", model, {effort}) is called
    - Then: output contains `--model opus --effort max --mcp-config '{"mcpServers":{}}' --strict-mcp-config --dangerously-skip-permissions` and starts with `DISABLE_OMC=1`
  - AC-2.2:
    - Given: model="gpt-5.4", reasoning="high"
    - When: buildCodexCmd("tui", model, {reasoning}) is called
    - Then: output contains `-m gpt-5.4 -c model_reasoning_effort="high" --disable plugins --dangerously-bypass-approvals-and-sandbox`
  - AC-2.3:
    - Given: value="opus:max" for role="worker"
    - When: parseModelFlag(value, role) is called
    - Then: returns {engine:"claude", model:"opus", effort:"max"}
  - AC-2.4:
    - Given: value="spark:medium"
    - When: parseModelFlag(value) is called
    - Then: returns {engine:"codex", model:"gpt-5.3-codex-spark", reasoning:"medium"}
  - AC-2.5 (negative):
    - Given: value="a:b:c"
    - When: parseModelFlag(value) is called
    - Then: throws an error with "invalid format" message
- **Boundary Cases**: empty effort, empty model, undefined reasoning
- **Verification Layers**: L1 (unit tests)
- **Status**: not started

### US-003: Signal and Verdict Poller
- **Priority**: P0
- **Size**: M
- **Type**: code
- **Risk**: MEDIUM
- **Depends on**: [US-001]
- **Acceptance Criteria**:
  - AC-3.1:
    - Given: A verdict JSON file does not exist yet
    - When: pollForSignal is called with a timeout of 5 seconds
    - Then: it polls at the configured interval until the file appears and contains valid JSON, then resolves with the parsed content
  - AC-3.2:
    - Given: A verdict file exists AND the codex process is still running in the pane
    - When: pollForSignal is called in codex mode
    - Then: it waits for BOTH file existence AND process exit before resolving (two-phase poll)
  - AC-3.3:
    - Given: No verdict file appears within timeout
    - When: pollForSignal reaches timeout
    - Then: it rejects with a TimeoutError. Must NOT hang indefinitely.
  - AC-3.4 (negative):
    - Given: A verdict file exists but contains invalid JSON
    - When: pollForSignal detects it
    - Then: it continues polling (does not resolve with corrupt data)
- **Boundary Cases**: file written partially (atomic write in progress), pane dies before verdict, API transient errors in pane
- **Verification Layers**: L1 (unit tests with mock fs) + L3 (integration with real file polling)
- **Status**: not started

### US-004: Prompt Assembler
- **Priority**: P0
- **Size**: M
- **Type**: code
- **Risk**: MEDIUM
- **Depends on**: []
- **Acceptance Criteria**:
  - AC-4.1:
    - Given: A worker prompt base file, iteration=3, fix-contract from previous iteration exists
    - When: assembleWorkerPrompt is called
    - Then: output contains the base prompt content verbatim, iteration context section, fix contract section, and PER-US SCOPE LOCK section with correct US ID
  - AC-4.2:
    - Given: autonomousMode=true
    - When: assembleWorkerPrompt is called
    - Then: output contains AUTONOMOUS MODE section with PRD priority rule and conflict-log.jsonl format
  - AC-4.3:
    - Given: A verifier prompt base file, us_id="US-002", verified_us=["US-001"]
    - When: assembleVerifierPrompt is called
    - Then: output contains verification scoped to US-002 only, with note that US-001 is already verified
  - AC-4.4 (negative):
    - Given: Worker prompt base file does not exist
    - When: assembleWorkerPrompt is called
    - Then: throws FileNotFoundError with the missing path
- **Boundary Cases**: empty memory file, no fix-contract, us_id="ALL" (final verify), per-US PRD file missing (fallback to full PRD)
- **Verification Layers**: L1 (unit tests) + L3 (output content verification)
- **Status**: not started

### US-005: Campaign Initializer (init command)
- **Priority**: P1
- **Size**: M
- **Type**: code
- **Risk**: MEDIUM
- **Depends on**: []
- **Acceptance Criteria**:
  - AC-5.1:
    - Given: A slug "test-campaign" and an objective string
    - When: init("test-campaign", objective) is called
    - Then: scaffold directories and files are created: prompts/, plans/, memos/, logs/, context/. All expected files exist.
  - AC-5.2:
    - Given: A PRD with 3 US sections marked with `## US-NNN:`
    - When: init splits the PRD
    - Then: 3 per-US PRD files are created at plans/prd-{slug}-US-00{1,2,3}.md, each containing only its US section plus the objective header
  - AC-5.3:
    - Given: A slug that already has a PRD (re-init)
    - When: init is called with mode="fresh"
    - Then: existing PRD is deleted and recreated. Old files are not preserved.
  - AC-5.4 (negative):
    - Given: No tmux session and mode=tmux
    - When: init checks prerequisites
    - Then: reports "tmux required" and exits without creating scaffold
- **Boundary Cases**: slug with special characters, existing scaffold with partial files, .gitignore already has rlp-desk rules
- **Verification Layers**: L1 (unit tests) + L3 (real filesystem scaffold check)
- **Status**: not started

### US-006: Campaign Main Loop
- **Priority**: P0
- **Size**: L
- **Type**: code
- **Risk**: HIGH
- **Depends on**: [US-001, US-002, US-003, US-004]
- **Acceptance Criteria**:
  - AC-6.1:
    - Given: A valid scaffold with PRD, prompts, and test-spec
    - When: run("test-slug", {mode:"tmux", workerModel:"gpt-5.4:medium"}) is called
    - Then: tmux session is created with leader/worker/verifier panes. Worker is launched with correct model and flags. Status.json is written with iteration=1, phase="worker".
  - AC-6.2:
    - Given: Worker completes and writes done-claim with us_id="US-001"
    - When: leader detects the signal
    - Then: verifier is launched with prompt scoped to US-001 only. Verdict is read and processed correctly (pass→next US, fail→fix contract).
  - AC-6.3:
    - Given: 3 consecutive failures on the same US with gpt-5.4:medium worker
    - When: circuit breaker logic runs
    - Then: worker model is upgraded to gpt-5.4:high. Status.json reflects the upgrade. If still failing after xhigh, campaign is BLOCKED.
  - AC-6.4:
    - Given: All per-US verifications pass
    - When: final sequential verify runs
    - Then: each US is re-verified individually, then integration test runs. COMPLETE sentinel is written only after all pass.
  - AC-6.5 (negative):
    - Given: BLOCKED sentinel exists
    - When: run is called
    - Then: it refuses to start and tells user to run clean first
- **Boundary Cases**: campaign interrupted mid-iteration (resume), codex worker exits without done-claim, consensus disagreement (6 rounds max)
- **Verification Layers**: L1 (unit tests for state machine) + L2 (integration with mock tmux) + L3 (E2E with real tmux) + L4 (failure injection)
- **Status**: not started

### US-007: Analytics and Reporting
- **Priority**: P1
- **Size**: S
- **Type**: code
- **Risk**: LOW
- **Depends on**: [US-006]
- **Acceptance Criteria**:
  - AC-7.1:
    - Given: A completed campaign with 5 iterations
    - When: campaign report is generated
    - Then: campaign-report.md contains all 8 required sections (Objective, Execution Summary, US Status, Verification Results, Issues, Cost, SV Summary, Files Changed)
  - AC-7.2:
    - Given: Each iteration completes
    - When: analytics logger appends data
    - Then: campaign.jsonl has one valid JSON line per iteration with all required fields (iter, us_id, worker_model, worker_engine, verdict, duration, timestamp)
  - AC-7.3:
    - Given: status.json is written after each iteration
    - When: status command reads it
    - Then: displays iteration, phase, models, verified_us, consecutive_failures, and elapsed time
- **Boundary Cases**: empty campaign (0 iterations), campaign.jsonl already exists (versioning), status.json corrupt
- **Verification Layers**: L1 (unit tests)
- **Status**: not started

### US-008: CLI Entry Point and npm Integration
- **Priority**: P1
- **Size**: M
- **Type**: infra
- **Risk**: MEDIUM
- **Depends on**: [US-005, US-006, US-007]
- **Acceptance Criteria**:
  - AC-8.1:
    - Given: npm package is installed
    - When: postinstall runs
    - Then: Node.js runtime files are installed to ~/.claude/ralph-desk/. Old zsh scripts are replaced.
  - AC-8.2:
    - Given: rlp-desk.md command file updated to call Node
    - When: user runs `/rlp-desk run test --mode tmux --worker-model gpt-5.4:medium --debug`
    - Then: Node CLI parses all flags correctly and launches the campaign with correct configuration
  - AC-8.3:
    - Given: All Node modules are in place
    - When: `node src/node/run.mjs --help` is executed
    - Then: displays all available options matching the current zsh CLI interface (no missing flags)
  - AC-8.4 (negative):
    - Given: Node.js is not installed (version < 16)
    - When: postinstall runs
    - Then: falls back gracefully with clear error message. Must NOT corrupt existing zsh installation.
- **Boundary Cases**: mixed install (some zsh + some node files), npm uninstall cleanup, reinstall over existing
- **Verification Layers**: L1 (unit tests) + L3 (real npm install cycle)
- **Status**: not started

## Non-Goals
- Rewriting governance.md or rlp-desk.md (command template)
- Adding new features beyond what zsh version supports
- Supporting platforms other than macOS/Linux
- Removing tmux dependency

## Technical Constraints
- Node.js >= 16 (match existing package.json)
- No external npm dependencies for core runtime (child_process, fs, path only)
- tmux control via child_process.execSync for synchronous operations, child_process.exec for async polling
- All file writes must be atomic (write to .tmp then rename, matching existing pattern)
- JSON handling via built-in JSON.parse/stringify (no jq dependency)

## Done When
- All 8 US acceptance criteria pass with quantitative evidence
- All boundary cases covered
- All required verification layers executed
- zsh scripts fully replaced — `npm publish` distributes Node.js files only
- `/rlp-desk run` works identically to current zsh version from user perspective
- Independent verifier confirms via Evidence Gate (governance §1b)
