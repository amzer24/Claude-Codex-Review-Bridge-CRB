# Claude-Codex Review Bridge (CRB)

Automated code review loop: Claude Code writes, Codex reviews, Claude fixes. Repeat until clean.

## Prerequisites

- [Claude Code](https://claude.ai/claude-code) with an active subscription
- [Codex CLI](https://developers.openai.com/codex/cli) authenticated with your ChatGPT subscription (`codex` in PATH)
- Node.js 18+
- Git

## Install

**As a Claude Code plugin (recommended):**
```bash
claude --plugin-dir /path/to/claude-codex-review-bridge
```

**Manual (project-scoped):**
```bash
cd your-project
bash /path/to/claude-codex-review-bridge/hooks/install.sh --force
```

## Enable

CRB is **disabled by default**. Opt in explicitly:
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
    +-- PostToolUse hook fires (Write/Edit on tracked code files)
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

Create a `.crb-prompt` file in your project root with additional review instructions:
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

## License

MIT
