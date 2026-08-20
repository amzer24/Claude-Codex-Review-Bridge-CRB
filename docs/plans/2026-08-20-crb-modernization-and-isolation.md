# CRB Modernization and Reviewer-Isolation Implementation Plan

> **For Claude:** This plan records the approved implementation contract. Execute each slice test-first and preserve the existing GPT-5.6 compatibility work.

**Goal:** Make CRB safe and reliable with current Claude Code and Codex CLI behavior while preserving its subscription-based, automatic peer-review workflow.

**Architecture:** Keep Claude hooks as the orchestration boundary and Codex `exec` as the reviewer, but pass Codex only a bounded review packet from a private empty working directory. Consolidate CRB into one current Claude skill, use current Stop payload fields, review one consolidated change set after tool batches, and make incomplete review states visible without granting the reviewer repository tools or instructions.

**Tech Stack:** Bash, Node.js helpers, Git, Claude Code hooks/plugins/skills, Codex CLI non-interactive mode, JSON Schema.

## Acceptance contract

- `/crb on|off|status|log|reset|fast|deep|default|doctor` remains user-invocable through one non-duplicated Claude skill.
- GPT-5.6 Luna/Sol presets and supported reasoning levels, including availability-dependent Ultra, continue to reach Codex unchanged.
- Codex reviews run from a private empty directory with repository instructions, user rules/config, MCP, shell, apps, hooks, agents, image, and web access disabled by default.
- Review prompts explicitly treat diffs, responses, custom criteria, and reviewer output as untrusted data; input and output sizes are bounded.
- Stop reviews prefer `last_assistant_message`, fall back to legacy transcripts, reset loop state for a fresh stop cycle, and do not review while background work is still active.
- Change review includes staged, unstaged, eligible untracked, and initial-commit changes without textconv; sensitive or ignored paths are not transmitted.
- Parallel tool calls produce at most one consolidated PostToolBatch review per batch, with outer Claude timeouts greater than CRB's internal timeout.
- Review failures, invalid output, and loop caps are visible and non-blocking by default; strict mode retains an explicit fail-closed path for major findings.
- Runtime state, logs, counters, temporary files, installer backups, and child-process cleanup use private and bounded handling across Linux, macOS, and Git Bash.

### Task 1: Lock current Claude plugin behavior in tests

**Files:**
- Modify: `tests/run-tests.sh`
- Modify: `.claude-plugin/plugin.json`
- Modify: `skills/crb/SKILL.md`
- Delete: `commands/crb.md`

Add failing assertions for a single `crb` skill, its full dispatcher, user-only invocation, and removal of the duplicate command manifest surface. Consolidate the command implementation into `skills/crb/SKILL.md`, then verify Claude plugin validation and inventory.

### Task 2: Isolate and bound Codex execution

**Files:**
- Modify: `tests/run-tests.sh`
- Modify: `hooks/lib/common.sh`
- Modify: `hooks/review-schema.json`

Capture the exact Codex command and working directory in tests. Assert a private empty `-C` directory, ignored user/rule config, disabled project instructions and tools, MCP isolation, read-only sandboxing, bounded output, and cleanup. Add hostile prompt/output fixtures and schema bounds before implementing the secure command builder and formatter.

### Task 3: Modernize Stop state and change collection

**Files:**
- Modify: `tests/run-tests.sh`
- Modify: `hooks/codex-review-stop.sh`
- Modify: `hooks/lib/common.sh`

Add failing cases for direct `last_assistant_message`, legacy transcript fallback, fresh-cycle counter reset, active background work, review failures, invalid output, staged/unstaged/untracked/initial-commit changes, secret exclusions, `.crbignore`, and input truncation. Implement one shared bounded review-packet collector and private atomic counter handling.

### Task 4: Replace per-tool reviews with one batch review

**Files:**
- Add: `hooks/codex-review-batch.sh`
- Delete: `hooks/codex-review-file.sh`
- Modify: `hooks/hooks.json`
- Modify: `hooks/install.sh`
- Modify: `tests/run-tests.sh`

Add PostToolBatch payload and migration tests. Review the consolidated bounded change packet once after a batch that may modify files, emit current hook output, retain strict major handling, remove legacy CRB PostToolUse entries during manual installation, and enforce `outer timeout > internal timeout`.

### Task 5: Harden local state and platform behavior

**Files:**
- Modify: `hooks/lib/common.sh`
- Modify: `hooks/install.sh`
- Modify: `.gitignore`
- Modify: `tests/run-tests.sh`

Move manual state to an XDG/private user directory, reject symlink/non-regular log and counter targets, write counters and settings atomically, keep backups out of the target repository, and terminate the Codex process tree in the portable watchdog path. Add focused regression coverage for each boundary.

### Task 6: Refresh release documentation and verify

**Files:**
- Modify: `README.md`
- Modify: `skills/crb/SKILL.md`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`
- Modify: `tests/run-tests.sh`

Document current Claude/Codex behavior, privacy boundaries, batch and Stop coverage, input limits, failure semantics, model presets, and migration instructions. Synchronize release metadata, run shell syntax/JSON/schema/plugin validation, execute the full Git Bash suite, and repeat the authenticated GPT-5.6 smoke request only if the final command surface changed materially.

### Task 7: Apply updated review gates

Run the freshly updated GStack engineering standards review and spec review separately, followed by the current GStack pre-landing review and Codex Security diff scan. Validate each candidate finding against the final patch, fix confirmed issues test-first, and rerun all affected gates.
