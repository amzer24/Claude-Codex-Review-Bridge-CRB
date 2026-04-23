---
name: crb
description: Control the Codex review bridge - toggle, model presets, logs, diagnostics
userInvocable: true
---

# /crb - Claude-Codex Review Bridge

Parse the argument and execute the matching action. If no argument, show help.

## Actions

### `on`
```bash
echo 1 > ~/.crb-enabled
```
Respond: **CRB enabled.** Codex will review your code on every edit and task completion.

### `off`
```bash
echo 0 > ~/.crb-enabled
```
Respond: **CRB disabled.** Reviews paused.

### `status`
Read actual persisted state and display as a dashboard:
```bash
TOGGLE="$(cat ~/.crb-enabled 2>/dev/null || echo 'not set')"
MODEL="$(cat ~/.crb-model 2>/dev/null || echo 'codex default')"
REASONING="$(cat ~/.crb-reasoning 2>/dev/null || echo 'medium')"
STRICT="${CRB_STRICT_POSTTOOL:-0}"
CRB_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}"
LOG="$CRB_DIR/codex-review.log"
LAST_ENTRY="$(tail -1 "$LOG" 2>/dev/null || echo 'no activity yet')"
COUNTERS="$(ls "$CRB_DIR"/codex-review-*-count 2>/dev/null | wc -l | tr -d ' ')"
```

Use the **actual values** from those reads. Format as:
```
CRB Status
  Review:    [enabled if TOGGLE=1, disabled if 0 or not set]
  Model:     [actual MODEL value] ([actual REASONING value] reasoning)
  Strict:    [on if STRICT=1, off otherwise]
  Log:       [actual LOG path]
  Last:      [actual LAST_ENTRY]
  Counters:  [actual COUNTERS] active session(s)
```

Do NOT hardcode any values. Show what the files actually contain.

### `log`
```bash
# Hooks may be invoked without CLAUDE_PLUGIN_DATA set, so logs can live in
# either location. Merge both, sort by timestamp, show the last 30 lines.
PLUGIN_LOG="${CLAUDE_PLUGIN_DATA:-}/codex-review.log"
TMP_LOG="${TMPDIR:-/tmp}/codex-review.log"
LOGS=()
[[ -n "${CLAUDE_PLUGIN_DATA:-}" && -f "$PLUGIN_LOG" ]] && LOGS+=("$PLUGIN_LOG")
[[ -f "$TMP_LOG" ]] && LOGS+=("$TMP_LOG")
if (( ${#LOGS[@]} == 0 )); then
  echo "No log file found."
else
  cat "${LOGS[@]}" | sort -s -k1,1 | tail -30
fi
```
Show the output to the user.

### `reset`
```bash
CRB_DIR="${CLAUDE_PLUGIN_DATA:-${TMPDIR:-/tmp}}"
rm -f "$CRB_DIR"/codex-review-*-count "${TMPDIR:-/tmp}"/codex-review-*-count 2>/dev/null
```
Respond: **Loop counters reset.**

### `fast`
```bash
echo "gpt-5.4-mini" > ~/.crb-model
echo "low" > ~/.crb-reasoning
```
Respond: **Fast mode** - gpt-5.4-mini, low reasoning. Quick reviews (~8s).

### `deep`
```bash
echo "gpt-5.3-codex" > ~/.crb-model
echo "high" > ~/.crb-reasoning
```
Respond: **Deep mode** - gpt-5.3-codex, high reasoning. Thorough reviews (~16s).

### `default`
```bash
rm -f ~/.crb-model ~/.crb-reasoning
```
Respond: **Default mode** - uses Codex CLI's own default model (gpt-5.5 with ChatGPT sign-in, falls back automatically). Set `CRB_MODEL` or run `/crb fast`/`deep` to override.

### `doctor`
Run all checks and report as a checklist:

```bash
echo "=== CRB Doctor ==="

# Prerequisites
bash --version 2>/dev/null | head -1 && echo "  bash: OK" || echo "  bash: FAIL"
node --version 2>/dev/null && echo "  node: OK" || echo "  node: FAIL"
git --version 2>/dev/null && echo "  git: OK" || echo "  git: FAIL"
codex --version 2>/dev/null && echo "  codex: OK" || echo "  codex: FAIL"

# Config
echo ""
echo "=== Config ==="
echo "  Toggle: $(cat ~/.crb-enabled 2>/dev/null || echo 'not set (disabled)')"
echo "  Model: $(cat ~/.crb-model 2>/dev/null || echo 'default (codex CLI default)')"
echo "  Reasoning: $(cat ~/.crb-reasoning 2>/dev/null || echo 'default (medium)')"

# Dry run
echo ""
echo "=== Dry Run ==="
DOCTOR_TMP="$(mktemp -d)"
(cd "$DOCTOR_TMP" && git init -q && git config user.email "crb@test" && git config user.name "CRB" && echo "x" > f.js && git add f.js && git commit -qm init && echo "y" > f.js)
# Find the hook script: plugin/project env first, then installed plugin metadata.
# Do not search cwd; that could run an untrusted project script.
CRB_HOOK=""
for candidate in "${CLAUDE_PLUGIN_ROOT:-}" "${CLAUDE_PROJECT_DIR:-}"; do
  if [[ -n "$candidate" && -f "$candidate/hooks/codex-review-stop.sh" ]]; then
    CRB_HOOK="$candidate/hooks/codex-review-stop.sh"
    break
  fi
done
if [[ -z "$CRB_HOOK" ]]; then
  CRB_HOOK="$(node <<'NODE' 2>/dev/null || true
const fs = require("fs");
const path = require("path");
const metadataPath = path.join(process.env.HOME || "", ".claude", "plugins", "installed_plugins.json");
try {
  const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8"));
  const entries = metadata.plugins?.["claude-codex-review-bridge@claude-codex-review-bridge"] || [];
  for (const entry of entries) {
    const installPath = entry?.installPath;
    if (!installPath) continue;
    const hookPath = path.join(installPath, "hooks", "codex-review-stop.sh");
    if (fs.existsSync(hookPath)) {
      process.stdout.write(hookPath);
      process.exit(0);
    }
  }
} catch (_) {}
process.exit(1);
NODE
)"
fi
if [[ -z "$CRB_HOOK" ]]; then
  echo "  Hook dry run: SKIP (no hook found in CLAUDE_PLUGIN_ROOT, CLAUDE_PROJECT_DIR, or installed_plugins.json)"
else
  if echo "{\"session_id\":\"doctor\",\"cwd\":\"$DOCTOR_TMP\"}" | CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=LGTM CRB_TOGGLE_FILE=<(echo 1) bash "$CRB_HOOK" >/dev/null 2>&1; then
    echo "  Hook dry run: PASS"
  else
    echo "  Hook dry run: FAIL"
  fi
fi
rm -rf "$DOCTOR_TMP"
```

Format as a clean checklist. Flag any FAILs with suggested fixes.

### No argument or `help`
```
/crb on       Enable Codex review
/crb off      Disable Codex review
/crb status   Dashboard (toggle, model, log, counters)
/crb log      Recent review activity
/crb reset    Reset loop counter
/crb fast     Fast mode  (gpt-5.4-mini, ~8s)
/crb deep     Deep mode  (gpt-5.3-codex, ~16s)
/crb default  Default    (codex's own default model)
/crb doctor   Verify setup
```
