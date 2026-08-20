<p align="center">
  <h1 align="center">Claude-Codex Review Bridge</h1>
  <p align="center">
    <strong>Two AI agents. One review loop. Zero copy-paste.</strong>
  </p>
  <p align="center">
    Claude Code writes your code — and plans it. Codex reviews both. Claude fixes the issues. Repeat until clean.
  </p>
  <p align="center">
    <a href="#install">Install</a> &middot;
    <a href="#how-it-works">How It Works</a> &middot;
    <a href="#configuration">Configuration</a>
  </p>
</p>

---

### The problem

You have Claude Code open. You have Codex open. You're copying code between them like it's 2024. One writes, you paste into the other for review, copy the feedback back. Repeat.

### The fix

CRB wires them together. Claude Code triggers one Codex review after each file-changing tool batch and another when Claude finishes a response. Codex can review a plan before code is written, then review the complete change set at task completion. Feedback routes back to Claude until Codex says LGTM or you intervene.

No API keys. Both tools run on your existing subscriptions.

---

## How It Works

```
  You give Claude a task
        |
        v
  Claude responds (plan, code, or both)
        |
        +-----> Change batch? ----> Codex reviews one consolidated patch
        |                                |
        |                           MAJOR issue? --> Claude gets feedback, fixes it
        |
        +-----> Task done? -------> Codex reviews the last response + git diff
                                         |
                                    LGTM ---------> Done. Claude stops.
                                    MINOR --------> Feedback loops back. Claude continues.
                                    MAJOR --------> Review surfaces to you.
                                         |
                                    (up to 3 rounds, then auto-exits)
```

**Reviews plans, not just code** — CRB uses Claude's current `last_assistant_message`, with a transcript fallback for older Claude Code releases. A plan-only response is reviewed even when no files changed.

**Change-complete patches** - CRB reviews staged, unstaged, eligible untracked, and pre-first-commit changes. It avoids textconv/external diff drivers and deduplicates unchanged batches.

**Stack-aware prompts** - CRB derives coarse language and project context from tracked path names without opening repository files outside the review packet.

**No style nits** - Codex only flags real problems: bugs, security issues, missing error handling, architectural concerns. Not semicolons.

**Model presets** - Switch review depth on the fly:

| Command | Model | Reasoning | Profile | Use when |
|---------|-------|-----------|---------|----------|
| `/crb fast` | gpt-5.6-luna | low | Efficient | Rapid iteration, quick checks |
| `/crb default` | Codex CLI default | medium | Account default | Normal development |
| `/crb deep` | gpt-5.6-sol | high | Quality-first | Pre-merge, security-critical code |

The default preset remains unpinned so it follows Codex's current built-in/account-available default. CRB intentionally ignores `config.toml` during reviews, so a user-configured provider or default model is not inherited. Explicit CRB overrides can use models available to the signed-in Codex account, including `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna`; the `gpt-5.6` alias routes to Sol. See the [official OpenAI model guidance](https://developers.openai.com/api/docs/guides/latest-model).

---

## Install

### Plugin (recommended)

From within Claude Code, run each command separately:

**1. Add the marketplace source:**
```
/plugin marketplace add amzer24/Claude-Codex-Review-Bridge-CRB
```

**2. Install the plugin:**
```
/plugin install claude-codex-review-bridge@claude-codex-review-bridge
```

**3. Enable CRB:**
```
/crb on
```

**4. Verify setup:**
```
/crb doctor
```

That's it. Run the commands one at a time.

### Manual (per-project)

```bash
cd your-project
bash /path/to/Claude-Codex-Review-Bridge-CRB/hooks/install.sh --force
echo 1 > ~/.crb-enabled
```

Writes exec-form hooks to `.claude/settings.local.json` with absolute script paths. The installer migrates legacy CRB `PostToolUse` entries and stores its backup under private user state, not in the target repository. Add `.claude/settings.local.json` to your `.gitignore`.

### Local dev/testing

```bash
claude --plugin-dir /path/to/Claude-Codex-Review-Bridge-CRB
```

---

## Usage

CRB is **disabled by default**. You control it:

| Command | What it does |
|---------|-------------|
| `/crb on` | Enable Codex review |
| `/crb off` | Disable Codex review |
| `/crb status` | Check if CRB is active |
| `/crb log` | View recent review activity |
| `/crb reset` | Reset the review loop counter |
| `/crb doctor` | Verify bash, node, git, codex, config, and hook dry run |
| `/crb fast` | Use faster lower-reasoning reviews |
| `/crb default` | Restore the default review model |
| `/crb deep` | Use deeper pre-merge reviews |

---

## Custom Review Instructions

Drop a `.crb-prompt` file in your project root:

```
All database queries must use parameterized statements.
Flag any endpoint missing authentication middleware.
Check for proper error boundaries in React components.
```

Set `CRB_PROMPT_FILE=.crb-prompt` in your environment. The file must be an ordinary, non-symlink file inside the current repository. Codex will incorporate these alongside the auto-detected stack context.

To exclude additional paths from review, add a `.crbignore` file using Git-ignore-style patterns:

```gitignore
fixtures/customer-export.json
generated/
*.snapshot
```

CRB also excludes common secret-bearing paths such as `.env*`, private-key formats, credential files, `.ssh/`, `.aws/`, and `secrets/`. Git-ignore rules exclude eligible untracked files; tracked files remain reviewable unless a secret filter or `.crbignore` excludes them. Treat the filters as a safety net: review your diff and `.crbignore` before enabling automatic review in a sensitive repository.

---

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CRB_MAX_ROUNDS` | `3` | Review rounds before auto-exit (1-5) |
| `CRB_PROMPT_FILE` | - | Path to a non-symlink custom-review file inside the current repository |
| `CRB_CODEX_TIMEOUT_SECONDS` | `120` | Codex call timeout (1-120s) |
| `CRB_MAX_INPUT_BYTES` | `500000` | Maximum combined review-prompt bytes (1 KiB-5 MiB) |
| `CRB_MAX_RESPONSE_BYTES` | `100000` | Maximum bytes retained from Claude's final response |
| `CRB_MAX_CUSTOM_PROMPT_BYTES` | `16384` | Maximum bytes read from custom review criteria |
| `CRB_MAX_OUTPUT_BYTES` | `32768` | Maximum accepted structured Codex output (4-128 KiB) |
| `CRB_MODEL` | Codex CLI default | Override the model with an ID available to your CLI/account, such as `gpt-5.6-sol`, `gpt-5.6-terra`, or `gpt-5.6-luna`. `gpt-5.6` is the Sol alias. |
| `CRB_REASONING` | `medium` | Reasoning effort (`none`, `low`, `medium`, `high`, `xhigh`, `max`). `ultra` is a Codex-specific, availability-dependent Sol/Terra effort; CRB still disables reviewer delegation/tools. `minimal` remains accepted for compatible older models. |
| `CRB_STRICT_POSTTOOL` | `0` | `1` to block the Claude agent loop on a MAJOR batch review |
| `CRB_LOCK_WAIT_SECONDS` | `5` | How long a review waits for CRB's single-review concurrency lock (0-20s) |
| `CRB_DEBUG` | `0` | `1` to append Codex diagnostic stderr to the private log |
| `CRB_DRY_RUN` | `0` | `1` to test without calling Codex |
| `CRB_LOG_FILE` | plugin data or `$XDG_STATE_HOME/crb/codex-review.log` | Private log location |

---

## Prerequisites

- **Claude Code** (CLI or Desktop) with an active subscription
- **[Standalone Codex CLI](https://developers.openai.com/codex/cli)** signed in with your ChatGPT subscription and available as `codex` in the same Bash environment Claude Code uses. A version bundled inside the Codex Desktop app does not by itself guarantee hook access. Using a GPT-5.6 preset requires a current Codex CLI and model access on your account.
- **Node.js** 18+ and **Git**

<details>
<summary><strong>Windows setup</strong></summary>

Claude Code uses Git Bash internally. Make sure [Git for Windows](https://git-scm.com/downloads/win) is installed.

Verify both tools from Git Bash, not only PowerShell or Codex Desktop:

```bash
bash --version
codex --version
codex exec --help
```

If `/crb doctor` cannot run `codex exec`, install the standalone CLI using the [official Codex CLI instructions](https://developers.openai.com/codex/cli) or put that standalone installation on Git Bash's `PATH`.

If it resolves to WSL instead of Git Bash, set the path explicitly:
```json
{
  "env": {
    "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
  }
}
```
</details>

---

## Compatibility

| Platform | Status |
|----------|--------|
| Claude Code CLI | Windows (tested), macOS, Linux |
| Claude Code Desktop | Windows, macOS |
| Claude Code Web | Not supported (needs local `codex` binary) |

---

## Security and Privacy Boundary

CRB sends the bounded patch, Claude's bounded final response, coarse path-derived project context, and optional custom criteria to OpenAI through your local authenticated Codex CLI. It does not send an API key and it does not give the reviewer direct repository access.

Every review runs from a new private empty directory with read-only sandboxing. CRB ignores Codex user config and exec rules while retaining login authentication; disables `AGENTS.md`, shell and shell snapshots, apps/connectors, plugins and bundled skills, memories, hooks, MCP, multi-agent tools, image reads, web search, and approval requests; validates the structured response locally; and removes the temporary workspace afterward. Repository content and reviewer text are both treated as untrusted data.

Review failures, invalid output, background-work deferrals, and loop caps are visible but non-blocking by default. `CRB_STRICT_POSTTOOL=1` changes only MAJOR batch findings to a blocking decision.

---

## How It Was Built

This plugin was built using its own review loop. Claude Code wrote the implementation and Codex reviewed the resulting change sets, catching real bugs during development:

- SQL injection in test fixtures
- Incomplete closure APIs (private Map inaccessible to cleanup functions)
- Missing `try/catch` on JSON parsing in the hook runtime
- Prompt injection via triple backticks in reviewed code
- Symlink traversal that could leak local files to the reviewer
- Git `--no-ext-diff` needed to prevent external diff driver execution

Every fix was triggered by Codex feedback flowing back through the hook system. The tool reviewed itself into existence.

---

## Architecture

```
hooks/
  codex-review-stop.sh       Stop hook - reviews the final response + bounded change set
  codex-review-batch.sh      PostToolBatch hook - reviews one consolidated change set
  hooks.json                 Plugin hook registration
  install.sh                 Manual installer (project-scoped)
  review-schema.json         Codex structured output schema (LGTM/MINOR/MAJOR)
  lib/
    common.sh                Toggle, JSON parsing, dynamic prompts, project detection
skills/
  crb/
    SKILL.md                 User-only /crb dispatcher + review handling guidance
tests/
  run-tests.sh               Hook, plugin, installer, and doc regression tests
```

---

<p align="center">
  <a href="LICENSE">MIT License</a>
</p>
