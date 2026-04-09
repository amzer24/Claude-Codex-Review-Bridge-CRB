<p align="center">
  <h1 align="center">Claude-Codex Review Bridge</h1>
  <p align="center">
    <strong>Two AI agents. One review loop. Zero copy-paste.</strong>
  </p>
  <p align="center">
    Claude Code writes your code. Codex reviews it. Claude fixes the issues. Repeat until clean.
  </p>
  <p align="center">
    <a href="#install">Install</a> &middot;
    <a href="#how-it-works">How It Works</a> &middot;
    <a href="#configuration">Configuration</a> &middot;
    <a href="SPEC.md">Spec</a>
  </p>
</p>

---

### The problem

You have Claude Code open. You have Codex open. You're copying code between them like it's 2024. One writes, you paste into the other for review, copy the feedback back. Repeat.

### The fix

CRB wires them together. Claude Code's hook system triggers Codex review automatically on every file edit and task completion. Feedback routes back to Claude. The loop runs until Codex says LGTM or you intervene.

No API keys. Both tools run on your existing subscriptions.

---

## How It Works

```
  You give Claude a task
        |
        v
  Claude writes code
        |
        +-----> File edit? -----> Codex reviews the full file
        |                              |
        |                         MAJOR issue? ---> Claude gets feedback, fixes it
        |
        +-----> Task done? -----> Codex reviews the full git diff
                                       |
                                  LGTM ---------> Done. Claude stops.
                                  MINOR --------> Feedback loops back. Claude continues.
                                  MAJOR --------> Review surfaces to you.
                                       |
                                  (up to 3 rounds, then auto-exits)
```

**Stack-aware prompts** - CRB detects your project's languages, frameworks, and architecture. A Next.js app gets different review focus than a Go microservice. No configuration needed.

**No style nits** - Codex only flags real problems: bugs, security issues, missing error handling, architectural concerns. Not semicolons.

**Model presets** - Switch review depth on the fly:

| Command | Model | Reasoning | Speed | Use when |
|---------|-------|-----------|-------|----------|
| `/crb fast` | gpt-5.4-mini | low | ~8s | Rapid iteration, quick checks |
| `/crb default` | gpt-5.4 | medium | ~17s | Normal development |
| `/crb deep` | gpt-5.3-codex | high | ~16s | Pre-merge, security-critical code |

---

## Install

### Plugin (recommended)

From within Claude Code:
```
/plugin marketplace add amzer24/Claude-Codex-Review-Bridge-CRB
/plugin install claude-codex-review-bridge@claude-codex-review-bridge
/crb on
```

That's it. Three commands.

### Manual (per-project)

```bash
cd your-project
bash /path/to/Claude-Codex-Review-Bridge-CRB/hooks/install.sh --force
echo 1 > ~/.crb-enabled
```

Writes to `.claude/settings.local.json` with absolute paths. Add it to your `.gitignore`.

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

---

## Custom Review Instructions

Drop a `.crb-prompt` file in your project root:

```
All database queries must use parameterized statements.
Flag any endpoint missing authentication middleware.
Check for proper error boundaries in React components.
```

Set `CRB_PROMPT_FILE=.crb-prompt` in your environment. Codex will incorporate these alongside the auto-detected stack context.

---

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CRB_MAX_ROUNDS` | `3` | Review rounds before auto-exit (1-5) |
| `CRB_PROMPT_FILE` | - | Path to custom review instructions |
| `CRB_CODEX_TIMEOUT_SECONDS` | `120` | Codex call timeout (1-120s) |
| `CRB_MODEL` | `gpt-5.4` | Codex model (`gpt-5.4-mini`, `gpt-5.3-codex`, etc.) |
| `CRB_REASONING` | `medium` | Reasoning effort (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`) |
| `CRB_STRICT_POSTTOOL` | `0` | `1` to block Claude on MAJOR per-file issues |
| `CRB_DEBUG` | `0` | `1` to log Codex stderr (thinking tokens) |
| `CRB_DRY_RUN` | `0` | `1` to test without calling Codex |
| `CRB_LOG_FILE` | `$CLAUDE_PLUGIN_DATA/codex-review.log` | Log location |

---

## Prerequisites

- **Claude Code** (CLI or Desktop) with an active subscription
- **[Codex CLI](https://developers.openai.com/codex/cli)** signed in with your ChatGPT subscription
- **Node.js** 18+ and **Git**

<details>
<summary><strong>Windows setup</strong></summary>

Claude Code uses Git Bash internally. Make sure [Git for Windows](https://git-scm.com/downloads/win) is installed.

Verify: `bash --version`

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

## How It Was Built

This plugin was built entirely using its own review loop. Claude Code wrote the implementation. Codex reviewed every file edit and caught real bugs during development:

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
  codex-review-stop.sh       Stop hook - reviews git diff HEAD on task completion
  codex-review-file.sh       PostToolUse hook - reviews individual files on Write/Edit/MultiEdit
  hooks.json                 Plugin hook registration
  install.sh                 Manual installer (project-scoped)
  review-schema.json         Codex structured output schema (LGTM/MINOR/MAJOR)
  lib/
    common.sh                Toggle, JSON parsing, dynamic prompts, project detection
commands/
  crb.md                     /crb slash command
skills/
  crb/
    SKILL.md                 Review loop behavior instructions for Claude
tests/
  run-tests.sh               46-assertion test suite
```

---

<p align="center">
  MIT License
</p>
