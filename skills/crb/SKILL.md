---
name: crb
description: Claude-Codex Review Bridge - toggle Codex review loop and manage review behavior
---

# Claude-Codex Review Bridge (CRB)

## Commands

### Toggle Review Loop

**Enable Codex review:**
```bash
echo "1" > ~/.crb-enabled
```

**Disable Codex review:**
```bash
echo "0" > ~/.crb-enabled
```

**Check status:**
```bash
cat ~/.crb-enabled 2>/dev/null || echo "enabled (default)"
```

When enabled, Codex automatically reviews:
- **Every file write/edit** (PostToolUse) — only MAJOR issues interrupt
- **Every task completion** (Stop) — LGTM/MINOR/MAJOR severity routing

### View Review Log

```bash
tail -20 "${TMPDIR:-/tmp}/codex-review.log"
```

### Reset Loop Counter

If the review loop hit its cap (3 rounds) and you want to allow more:
```bash
rm -f "${TMPDIR:-/tmp}"/codex-review-*-count
```

## Review Loop Behavior

When CRB is enabled and Claude finishes work, the following loop runs automatically:

```
Claude completes work
    |
    v
Stop hook fires --> Codex reviews git diff HEAD
    |
    +-- LGTM --> exit 0, no output --> Claude stops normally
    |
    +-- MINOR --> stderr feedback + exit 2 --> Claude continues
    |   |
    |   v
    |   Claude reads Codex feedback, addresses issues, re-attempts stop
    |   |
    |   v
    |   Stop hook fires again (round N+1) --> Codex re-reviews
    |   (repeats up to 3 rounds, then auto-exits)
    |
    +-- MAJOR --> systemMessage with full review --> Claude stops for user
```

## Instructions for Claude

When you receive Codex review feedback (via stderr on Stop, or via additionalContext on PostToolUse):

1. **Read the feedback carefully.** Codex is a peer reviewer, not an authority. Evaluate each issue on its merits.
2. **Address valid issues.** Make the code changes needed to resolve them.
3. **Push back on incorrect feedback.** If Codex flagged something that is actually correct, do NOT change it. Note why in your response.
4. **Show progress to the user.** Before addressing feedback, briefly state: what Codex found, what you agree with, and what you'll fix.
5. **After fixing, attempt to complete again.** This triggers the next review round. The loop continues until Codex returns LGTM or the round cap (3) is reached.
6. **Never silently ignore review feedback.** Always acknowledge what Codex said, even if you disagree.

### Example response pattern when receiving MINOR feedback:

```
Codex Review (Round 1/3) found minor issues:
- [issue 1]: Agree, fixing now.
- [issue 2]: Disagree - [reason]. Keeping as-is.

Addressing issue 1...
```

### Per-file MAJOR feedback (PostToolUse):

When you receive `additionalContext` from a PostToolUse hook with Codex review:
1. Stop what you're doing and read the feedback.
2. Address the MAJOR issue in the file before continuing.
3. Tell the user what Codex found and what you changed.
