---
name: crb
description: Toggle Codex review bridge on/off, check status, or view logs
userInvocable: true
---

# /crb - Claude-Codex Review Bridge Control

Parse the argument to determine the action:

- `/crb on` - Enable Codex review
- `/crb off` - Disable Codex review
- `/crb status` - Show current status
- `/crb log` - Show recent review log
- `/crb reset` - Reset the loop counter

## Instructions

Based on the argument provided:

### `on`
Run: `echo 1 > ~/.crb-enabled`
Then confirm: "CRB enabled. Codex will review your code on every edit and task completion."

### `off`
Run: `echo 0 > ~/.crb-enabled`
Then confirm: "CRB disabled. Codex reviews are paused."

### `status`
Run: `cat ~/.crb-enabled 2>/dev/null || echo "not set"`
Report:
- If content is `1`: "CRB is **enabled**."
- If content is `0`: "CRB is **disabled**."
- If file missing: "CRB is **disabled** (default). Run `/crb on` to enable."

### `log`
Run: `tail -30 "${TMPDIR:-/tmp}/codex-review.log" 2>/dev/null || echo "No log file found."`
Show the output to the user.

### `reset`
Run: `rm -f "${TMPDIR:-/tmp}"/codex-review-*-count`
Then confirm: "Review loop counters reset."

### No argument or `help`
Show this summary:
```
/crb on      Enable Codex review
/crb off     Disable Codex review
/crb status  Show current status
/crb log     Show recent review log
/crb reset   Reset loop counter
```
