# SPEC: Claude-Codex Review Bridge

## Objective

Build a local orchestration system where **Claude Code is the implementer** and **OpenAI Codex is the reviewer**. Codex reviews both plans and code output from Claude Code, with feedback automatically looped back. Minor issues auto-resolve; major concerns surface to the user.

**Target user:** Developer (you) running both tools locally with their respective subscriptions.

**Key constraint:** Must work with **Claude Pro/Max subscription** and **ChatGPT Pro subscription** — no API keys, no per-token billing. Both `claude -p` and `codex exec` authenticate via their subscription OAuth flows.

---

## Architecture

### Phase 1: Claude Code Hooks (zero new code beyond shell scripts)

Use Claude Code's built-in hooks system to trigger Codex review at two lifecycle points:

```
Claude Code working
    │
    ├── [PostToolUse: Write/Edit/MultiEdit] ──→ Codex reviews changed file
    │   ├── Minor issues → ignored (only MAJOR surfaced per-file)
    │   └── Major issues → exit 0 + hookSpecificOutput.additionalContext (Claude sees feedback)
    │
    └── [Stop] ──→ Codex reviews full diff + plan
        ├── LGTM → exit 0, Claude stops normally
        ├── Minor issues → exit 2, feedback on stderr (Claude continues)
        └── Major issues → exit 0 + JSON systemMessage (Claude stops, user sees warning)
```

**How the feedback loop works:**
1. Claude Code finishes a task (Stop event fires)
2. Hook script captures the git diff and transcript context
3. Hook builds a full prompt (review instructions + diff) and pipes it to `codex exec --output-schema "$SCRIPT_DIR/review-schema.json" -` via stdin
4. Hook parses structured JSON output from Codex for severity
5. If LGTM: exit 0 with no output → Claude stops normally
6. If MINOR: exit 2, write feedback to **stderr** → Claude resumes and sees stderr as context
7. If MAJOR: exit 0 with JSON `{"systemMessage": "Codex review found major issues:\n..."}` → Claude stops normally, user sees the warning

**Important: exit code 2 + stderr is the feedback mechanism.** Claude Code only parses JSON stdout on exit 0. On exit 2, stderr content is what gets surfaced to Claude as context for continuation.

### Phase 1.5: Claude Code Plugin Packaging (after Phase 1 is stable)

Wrap the working hook scripts into a distributable Claude Code plugin so anyone can install with one command:

```
/plugin marketplace add amzer24/Claude-Codex-Review-Bridge-CRB
/plugin install claude-codex-review-bridge@claude-codex-review-bridge
```

**Plugin structure:**
```
.claude-plugin/
├── plugin.json                    # Plugin manifest (name, version, description)
└── marketplace.json               # Marketplace entry for discovery
hooks/
├── hooks.json                     # Hook config (replaces manual settings.json patching)
├── codex-review-stop.sh
├── codex-review-file.sh
└── review-schema.json
skills/
└── crb/
    └── SKILL.md                   # Manual commands: "run a Codex review now", "show CRB status"
README.md                          # Install, auth prerequisites, usage
```

**Key difference from Phase 1:** Hook config lives in `hooks/hooks.json` (plugin-managed) instead of requiring manual `settings.json` edits. The `install.sh` becomes unnecessary once packaged as a plugin.

### Phase 2: Orchestrator CLI (optional, builds on Phase 1)

A lightweight Node.js CLI wrapping the hook scripts with:
- Configurable review policies (what severity auto-loops vs surfaces)
- Review history/log (markdown files in `.reviews/`)
- Plan review mode (pipe a plan through Codex before Claude implements)
- Max review rounds cap (prevent infinite loops)

---

## Phase 1 Implementation Detail

### Hook Configuration (`settings.json`)

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/hooks/codex-review-stop.sh\"",
            "timeout": 120
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/hooks/codex-review-file.sh\"",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

> **Note:** Each event entry contains an inner `hooks` array. Timeout is in **seconds**, not milliseconds. `$CLAUDE_PROJECT_DIR` resolves to the project root automatically.

### Hook Scripts

#### `codex-review-stop.sh` (full diff review on Stop)

**Input:** Receives JSON on stdin with `session_id`, `cwd`, `transcript_path`
**Logic:**
1. Read the JSON input from stdin
2. Run `git diff HEAD --` in the working directory to capture all changes (staged + unstaged) relative to HEAD
3. If no diff, exit 0 (nothing to review)
4. Build full prompt (instructions + diff) and pipe to `codex exec --output-schema "$SCRIPT_DIR/review-schema.json" -` via stdin
5. Parse `severity` field from Codex JSON output
6. Return appropriate JSON + exit code based on severity

**Codex structured output:** Use `codex exec --output-schema` to force JSON output instead of free-text parsing. This eliminates parsing brittleness from ANSI codes, model drift, or extra text.

**Schema file (`hooks/review-schema.json`):** All scripts resolve this path relative to their own directory via `SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"`.
```json
{
  "type": "object",
  "properties": {
    "severity": { "type": "string", "enum": ["LGTM", "MINOR", "MAJOR"] },
    "issues": {
      "type": "array",
      "items": { "type": "string" }
    },
    "suggestions": {
      "type": "array",
      "items": { "type": "string" }
    }
  },
  "required": ["severity", "issues", "suggestions"]
}
```

**Codex review prompt template:**
```
You are a senior code reviewer. Review this git diff for:
- Bugs, logic errors, off-by-one errors
- Security vulnerabilities (injection, XSS, secrets)
- Missing error handling at system boundaries
- Architectural concerns

Return structured JSON matching the output schema.
```

#### `codex-review-file.sh` (per-file review on Write/Edit/MultiEdit)

**Input:** Receives JSON with `tool_input.file_path` and `tool_input.content` or `tool_input.new_string`
**Logic:**
1. Extract the file path and change content from stdin JSON
2. **Gate: only review git-tracked files** — run `git ls-files --error-unmatch -- "$file"` and skip if untracked
3. Skip non-code files (`.md`, `.json`, `.lock`, images, etc.)
4. Build full prompt (review instructions + file content) and pipe to `codex exec --output-schema "$SCRIPT_DIR/review-schema.json" -` via stdin
5. Only surface MAJOR issues (to avoid interrupting flow on every edit)
6. If MAJOR: return PostToolUse-specific feedback — `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "Codex found major issue in $file: ..."}}` on stdout, exit 0. This feeds back to Claude so it can address the issue. Otherwise exit 0 silently

### Severity Classification

**Stop hook:**

| Severity | Action | Exit Code | Output Channel |
|----------|--------|-----------|----------------|
| LGTM | Claude stops normally | 0 | No output |
| MINOR | Claude continues with feedback | 2 | **stderr** (Claude sees this as context) |
| MAJOR | Claude stops, user sees review | 0 | **stdout** JSON: `{"systemMessage": "..."}` |

**PostToolUse hook (Write/Edit/MultiEdit):**

| Severity | Action | Exit Code | Output Channel |
|----------|--------|-----------|----------------|
| LGTM / MINOR | Ignored, no interruption | 0 | No output |
| MAJOR | Claude sees feedback, addresses it | 0 | **stdout** JSON: `{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "..."}}` |

### Loop Protection

- Max 3 review rounds per session (tracked via temp file keyed by `session_id`)
- After 3 rounds, always exit 0 regardless of Codex feedback
- Counter file: `$CLAUDE_PLUGIN_DATA/codex-review-{session_id}-count` when installed as a plugin, falling back to `${TMPDIR:-/tmp}` for manual installs

---

## Phase 2 Implementation Detail (Future)

### CLI Tool: `crb` (Claude-Codex Review Bridge)

```bash
crb plan "build a user auth system"    # Codex reviews a plan before Claude implements
crb review                              # Manually trigger Codex review of current changes
crb config                              # Edit review policies
crb log                                 # View review history
crb install                             # Set up hooks in Claude Code settings.json
```

### Tech Stack

- **Runtime:** Node.js (TypeScript)
- **No frameworks** — pure CLI with `commander` for arg parsing
- **No API keys** — shells out to `claude -p` and `codex exec` which use their own subscription auth
- **State:** Flat files in `.reviews/` directory (markdown review logs)

### Plan Review Flow (Phase 2)

```
User runs: crb plan "build feature X"
    │
    ├── claude -p "create a detailed implementation plan for: build feature X"
    │   └── Plan saved to .reviews/plan-{timestamp}.md
    │
    ├── codex exec "review this implementation plan for completeness, risks, and missed edge cases"
    │   └── Review saved to .reviews/plan-review-{timestamp}.md
    │
    ├── If MAJOR concerns:
    │   └── Show review to user, ask to proceed or revise
    │
    └── If LGTM/MINOR:
        └── claude -p "implement the plan, addressing these review notes: {feedback}"
```

---

## Project Structure

```
CLI_test/
├── SPEC.md                          # This file
├── .claude-plugin/
│   ├── plugin.json                  # Plugin manifest (Phase 1.5)
│   └── marketplace.json             # Marketplace entry (Phase 1.5)
├── hooks/
│   ├── hooks.json                   # Hook config for plugin system (Phase 1.5)
│   ├── codex-review-stop.sh         # Stop hook — full diff review
│   ├── codex-review-file.sh         # PostToolUse hook — per-file review
│   ├── review-schema.json           # JSON schema for Codex --output-schema
│   └── install.sh                   # Manual settings.json patcher (Phase 1 only)
├── skills/
│   └── crb/
│       └── SKILL.md                 # Manual review commands (Phase 1.5)
├── README.md                        # Install, auth, usage docs (Phase 1.5)
├── .reviews/                        # Review history (Phase 2)
└── src/                             # Phase 2 CLI source (TypeScript)
    ├── index.ts
    ├── commands/
    │   ├── plan.ts
    │   ├── review.ts
    │   └── config.ts
    └── lib/
        ├── codex.ts                 # codex exec wrapper
        ├── claude.ts                # claude -p wrapper
        └── severity.ts             # Severity parser
```

---

## Code Style

- Shell scripts: Bash 4+, targeting **WSL or Git Bash on Windows**, native Bash on macOS/Linux
- TypeScript (Phase 2): strict mode, no `any`, minimal dependencies
- No build step for Phase 1 — just shell scripts
- **Windows strategy:** Target WSL as primary (Codex CLI docs recommend WSL for Windows). Git Bash as fallback. The `install.sh` script detects the environment and generates the appropriate hook `command` paths. Native PowerShell is out of scope for Phase 1 — hooks use `bash` shell explicitly

---

## Testing Strategy

### Phase 1
- **Manual:** Run Claude Code with hooks installed, verify Codex gets invoked and feedback loops back
- **Dry run mode:** Environment variable `CRB_DRY_RUN=1` skips actual `codex exec` call and returns mock review output
- **Logging:** All hook invocations logged to `$CLAUDE_PLUGIN_DATA/codex-review.log` when installed as a plugin, falling back to `${TMPDIR:-/tmp}/codex-review.log`

### Phase 2
- Unit tests for severity parser and JSON formatting
- Integration tests using `CRB_DRY_RUN=1` mode
- Test framework: Node.js built-in test runner (`node --test`)

---

## Boundaries

### Always Do
- Use subscription auth for both tools (no API keys)
- Cap review rounds to prevent infinite loops
- Log all reviews for auditability
- **Only review git-tracked files** — enforce with `git ls-files --error-unmatch` before sending to Codex. This covers `.gitignore` and also prevents reviewing untracked/new files that haven't been staged
- Timeout Codex calls (120s max) to prevent hangs

### Ask First
- Before modifying Claude Code's `settings.json` (the install script)
- Before increasing max review rounds beyond 3
- Before adding new hook events beyond Stop and PostToolUse
- Before any Phase 2 work

### Never Do
- Send code to third-party services beyond the authenticated Claude and Codex CLIs (no additional external APIs, paste services, or telemetry)
- Store API keys or tokens in hook scripts
- Auto-commit based on review results
- Let the review loop run more than 5 rounds under any circumstance
- Modify files that Codex is reviewing (avoid write conflicts)

---

## Acceptance Criteria

### Phase 1 (MVP)
- [x] `codex-review-stop.sh` captures git diff and sends to Codex for review
- [x] Codex review output is parsed for LGTM/MINOR/MAJOR severity
- [x] MINOR feedback auto-loops back to Claude Code via **stderr + exit 2**
- [x] MAJOR feedback surfaces to user via **stdout JSON `systemMessage`** + exit 0
- [x] LGTM lets Claude stop normally
- [x] Loop counter prevents more than 3 review rounds
- [x] Dry run mode works without Codex installed
- [x] `install.sh` correctly patches Claude Code settings.json
- [x] Works on Windows (Git Bash) and macOS/Linux

### Phase 1.5 (Plugin Packaging)
- [x] `plugin.json` manifest with name, version, description
- [x] `hooks/hooks.json` replaces manual `settings.json` patching
- [x] Optional `skills/crb/SKILL.md` for manual review commands
- [x] `README.md` with install prerequisites and usage
- [x] Installable via `/plugin marketplace add` and `/plugin install`

### Phase 2 (Future)
- [ ] `crb plan` sends plan through Codex review before implementation
- [ ] `crb review` triggers manual review of current changes
- [ ] `crb log` shows review history
- [ ] `crb install` sets up hooks non-destructively

---

## Open Questions

1. **Codex subscription + `codex exec`:** Verified live with ChatGPT subscription OAuth on this Windows/Git Bash setup. Keep this on the watchlist because Codex CLI auth behavior can change.
2. **PostToolUse frequency:** Reviewing every Write/Edit/MultiEdit may be too noisy. Should we batch and only review on Stop? Or only review files matching certain patterns?
3. **Transcript access:** The Stop hook receives `transcript_path` — should we send conversation context to Codex alongside the diff for better review quality?
4. **Windows compatibility:** Verified on Windows with Git Bash. Codex CLI docs recommend WSL for Windows; WSL should remain supported but needs separate end-user testing.

---

## Existing Alternatives Considered

| Option | Verdict |
|--------|---------|
| **GitHub Agent HQ** | Managed platform, requires Pro+ GitHub tier. Overkill for local workflow. |
| **OpenCode + OMO** | Strong multi-agent base but uses API keys, not subscriptions. Watch for future. |
| **Composio Agent Orchestrator** | Good for fleet management, wrong scale for 2-agent local workflow. |
| **Claude Code Agent SDK** | Requires API billing, not subscription-compatible. |
| **Pi** | Single-agent only, no orchestration. Not suitable. |
| **Claude Code hooks (chosen)** | Zero new dependencies, works with subscriptions, built-in feedback loop via exit code 2. Simplest path. |
