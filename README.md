# Claude-Codex Review Bridge (CRB)

Automated code review loop: Claude Code writes, Codex reviews, Claude fixes. Repeat until clean.

Works with Claude Code CLI and Desktop app (Windows & Mac).

## Prerequisites

- **Claude Code** (CLI, Desktop, or Web) with an active subscription
- **[Codex CLI](https://developers.openai.com/codex/cli)** authenticated with your ChatGPT subscription (`codex` in PATH)
- **Node.js** 18+
- **Git** (with Git Bash on Windows)

### Windows-specific

Claude Code uses **Git Bash internally** to run hook scripts. Verify it works:
```bash
bash --version
```
If this fails or returns Windows Subsystem bash instead of Git Bash, ensure [Git for Windows](https://git-scm.com/downloads/win) is installed and its `bin/` directory is on your PATH. You can also set the path explicitly in Claude Code settings:
```json
{
  "env": {
    "CLAUDE_CODE_GIT_BASH_PATH": "C:\\Program Files\\Git\\bin\\bash.exe"
  }
}
```

## Install

### Option 1: Plugin via marketplace (recommended)

From within Claude Code (CLI or Desktop):
```
/plugin marketplace add amzer24/Claude-Codex-Review-Bridge-CRB
/plugin install claude-codex-review-bridge@claude-codex-review-bridge
```

The plugin registers hooks automatically. No manual settings edits needed.

### Option 2: Plugin from local directory (development/testing)

Clone the repo, then load it directly (CLI only):
```bash
claude --plugin-dir /path/to/Claude-Codex-Review-Bridge-CRB
```

### Option 3: Manual install (project-scoped)

For projects where you don't want the full plugin:
```bash
cd your-project
bash /path/to/Claude-Codex-Review-Bridge-CRB/hooks/install.sh --force
```

This writes hooks to `your-project/.claude/settings.local.json` using absolute paths to the CRB scripts. Add `.claude/settings.local.json` to your `.gitignore`.

## Enable

CRB is **disabled by default** to protect privacy. Opt in explicitly:
```bash
echo 1 > ~/.crb-enabled
```

Disable:
```bash
echo 0 > ~/.crb-enabled
```

## How It Works

```
Claude edits code
    |
    +-- PostToolUse hook fires (Write/Edit/MultiEdit on tracked code files)
    |   Codex reviews the full file. MAJOR issues feed back to Claude.
    |
    +-- Stop hook fires (Claude finishes a task)
        Codex reviews git diff HEAD.
        LGTM: Claude stops.
        MINOR: feedback loops back, Claude continues (up to 3 rounds).
        MAJOR: review shown to user, Claude stops.
```

The review prompt automatically detects your project's languages, frameworks, and architecture to give stack-specific feedback.

## Custom Review Instructions

Create a file with project-specific review instructions:
```
Focus on SQL injection in all database queries.
Ensure all API endpoints validate authentication.
```

Then set `CRB_PROMPT_FILE=.crb-prompt` in your environment.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `CRB_TOGGLE_FILE` | `~/.crb-enabled` | Path to enable/disable toggle file |
| `CRB_MAX_ROUNDS` | `3` | Max review rounds per session (clamped 1-5) |
| `CRB_DRY_RUN` | `0` | Set to `1` to skip real Codex calls |
| `CRB_DRY_RUN_SEVERITY` | `LGTM` | Severity for dry run (`LGTM`, `MINOR`, `MAJOR`) |
| `CRB_CODEX_TIMEOUT_SECONDS` | `120` | Codex call timeout (clamped 1-120) |
| `CRB_PROMPT_FILE` | unset | Path to custom review instructions file |
| `CRB_LOG_FILE` | `$TMPDIR/codex-review.log` | Log file path |

## View Logs

```bash
tail -20 "${TMPDIR:-/tmp}/codex-review.log"
```

## Reset Loop Counter

```bash
rm -f "${TMPDIR:-/tmp}"/codex-review-*-count
```

## Compatibility

| Platform | Status |
|----------|--------|
| Claude Code CLI (Windows) | Tested - requires Git Bash |
| Claude Code CLI (macOS/Linux) | Supported |
| Claude Code Desktop (Windows) | Supported - uses Git Bash internally |
| Claude Code Desktop (macOS) | Supported |
| Claude Code Web | Not supported - requires local `codex` binary |

## License

MIT
