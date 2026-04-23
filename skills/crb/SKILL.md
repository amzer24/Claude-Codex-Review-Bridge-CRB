---
name: crb
description: Claude-Codex Review Bridge - Codex automatically reviews Claude's code. Manages the review loop, model presets, and feedback handling.
---

# Claude-Codex Review Bridge (CRB)

CRB makes Codex your automatic code reviewer. Every file you edit and every task you complete gets reviewed by Codex. Feedback routes back to you automatically.

## Quick Reference

| Command | What it does |
|---------|-------------|
| `/crb on` | Enable Codex review |
| `/crb off` | Disable Codex review |
| `/crb status` | Show toggle, model, and log path |
| `/crb log` | Show recent review activity |
| `/crb reset` | Reset review loop counter |
| `/crb fast` | Fast mode - gpt-5.4-mini, low reasoning (~8s) |
| `/crb deep` | Deep mode - gpt-5.3-codex, high reasoning (~16s) |
| `/crb default` | Default mode - Codex CLI's own default model + medium reasoning |
| `/crb doctor` | Verify all prerequisites are working |

## What Happens When CRB Is Enabled

### On every file Write/Edit/MultiEdit (PostToolUse hook)

Codex reviews the **full file** (not just the edit snippet). Only **MAJOR** issues interrupt your flow - MINOR/LGTM are silent. You'll see `CRB: Codex reviewing file...` in the status bar.

### On every task completion (Stop hook)

Codex reviews **git diff HEAD** (all uncommitted changes). This is where the review loop lives:

```
Claude finishes work --> Stop hook fires --> Codex reviews full diff
    |
    LGTM -------> Claude stops. You're done.
    MINOR ------> Feedback loops back. Claude addresses it and re-submits.
    MAJOR ------> Review shown to you. Claude stops for your input.
    |
    (loop runs up to 3 rounds, then auto-exits)
```

You'll see `CRB: Codex reviewing diff...` in the status bar during review.

## How Claude Should Handle Review Feedback

When you receive Codex feedback (via Stop stderr or PostToolUse additionalContext):

1. **Show the user what Codex found** before doing anything else.
2. **Evaluate each issue on merit.** Codex is a peer, not an authority.
3. **Fix valid issues.** Make the changes.
4. **Push back on incorrect feedback.** If Codex is wrong, say why and keep the code as-is.
5. **Never silently ignore feedback.** Always acknowledge it.
6. **After fixing, let the Stop hook re-review.** The loop continues until LGTM or round cap.

### Response pattern for MINOR (Stop hook):

```
**Codex Review (Round 1/3)** found minor issues:
- Missing null check on `db.query` result: **Agree**, fixing now.
- Suggests adding pagination: **Disagree** - this is an internal admin endpoint with <100 records. Keeping as-is.

Fixing the null check...
```

### Response pattern for MAJOR (PostToolUse):

```
**Codex flagged a major issue in `auth.ts`:**
SQL injection via string concatenation in the login query.
**Agree** - switching to parameterized query now.
```

## Stack-Aware Reviews

CRB auto-detects your project's languages, frameworks, and architecture from `package.json`, `requirements.txt`, `go.mod`, `Cargo.toml`, directory structure, and file extensions. The review prompt adapts automatically - no configuration needed.

## Custom Review Focus

Set `CRB_PROMPT_FILE` to a file with project-specific instructions that get prepended to every review:

```bash
export CRB_PROMPT_FILE=.crb-prompt
```

Example `.crb-prompt`:
```
All API endpoints must validate authentication via middleware.
Database queries must use parameterized statements, never string concatenation.
React components must have error boundaries.
```
