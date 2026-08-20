# GPT-5.6 Codex Compatibility Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Update CRB's model presets, reasoning controls, tests, and documentation for the GPT-5.6 Codex model family while preserving custom and older model overrides and verified Windows hook behavior.

**Architecture:** Keep the default preset delegated to the installed Codex CLI so it follows future CLI defaults. Map the explicit speed and depth presets to GPT-5.6 Luna and GPT-5.6 Sol, respectively, and extend the shared command builder to pass the GPT-5.6 `max` reasoning effort without changing existing fallback behavior.

**Tech Stack:** Bash, Codex CLI non-interactive mode, Node.js test helpers, Claude Code plugin manifests and Markdown command/skill files.

### Task 1: Lock in GPT-5.6 command behavior

**Files:**
- Modify: `tests/run-tests.sh`
- Test: `tests/run-tests.sh`

**Step 1: Write failing tests**

Add a fake `codex` executable that records the arguments passed by `crb_run_codex_review`. Assert that `CRB_MODEL=gpt-5.6-sol` is forwarded with `-m` and that `CRB_REASONING=max` and Codex-specific `ultra` are forwarded unchanged. Add a source-level preset test asserting that the fast and deep commands persist `gpt-5.6-luna` and `gpt-5.6-sol`.

**Step 2: Verify the tests fail**

Run: `bash tests/run-tests.sh`

Expected: the `max` effort and current preset assertions fail because the implementation falls back to `medium` and still names GPT-5.4/GPT-5.3 models.

### Task 2: Update runtime compatibility

**Files:**
- Modify: `hooks/lib/common.sh`
- Modify: `commands/crb.md`
- Test: `tests/run-tests.sh`

**Step 1: Implement the smallest runtime changes**

Allow `max` and Codex-specific `ultra` in the reasoning-effort validation case. Change `/crb fast` to persist `gpt-5.6-luna` with low effort and `/crb deep` to persist `gpt-5.6-sol` with high effort. Keep `/crb default` unpinned and remove stale claims about its exact model.

During the first full Windows run, the existing file-hook tests exposed that Git Bash can emit absolute paths as `C:/...` while the normalizer only recognized `C:\...`. Extend normalization to both slash styles and keep the existing path-confinement tests green; add an explicit forward-slash drive-path assertion.

**Step 2: Verify the focused behavior passes**

Run: `bash tests/run-tests.sh`

Expected: all command-capture and preset tests pass.

### Task 3: Refresh public compatibility documentation

**Files:**
- Modify: `README.md`
- Modify: `skills/crb/SKILL.md`
- Modify: `.claude-plugin/plugin.json`
- Modify: `.claude-plugin/marketplace.json`

**Step 1: Update user-facing guidance**

Document the GPT-5.6 Luna/Sol presets, list Sol/Terra/Luna as valid custom targets, add `max` plus availability-dependent Codex `ultra`, and explain that the unpinned default follows the Codex CLI/account default. Make the current-CLI/model-access requirement explicit and strengthen `/crb doctor` to verify `codex exec`. Remove stale timing and GPT-5.5 authentication claims that cannot be guaranteed across current accounts.

**Step 2: Bump synchronized plugin metadata**

Advance both manifests to version `1.4.0` for the compatibility release.

### Task 4: Verify the migration

**Files:**
- Test: `tests/run-tests.sh`
- Verify: all changed shell, Markdown, JSON, and manifest files

**Step 1: Run shell syntax checks**

Run: `bash -n hooks/codex-review-stop.sh hooks/codex-review-file.sh hooks/crb-doctor.sh hooks/install.sh hooks/lib/common.sh tests/run-tests.sh`

Expected: exit 0 with no output.

**Step 2: Run the full regression suite**

Run: `bash tests/run-tests.sh`

Expected: `all tests passed` and no failed assertions.

**Step 3: Verify metadata and final diff**

Parse both JSON manifests with Node.js, confirm their versions match, search for stale preset model IDs in active public surfaces, and inspect `git diff --check` plus the complete working-tree diff.

No commit, push, or release action is included; those require separate authorization.
