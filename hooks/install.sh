#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SETTINGS_PATH="${CRB_SETTINGS_PATH:-$HOME/.claude/settings.json}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    --help|-h)
      cat <<EOF
Usage: hooks/install.sh [--force]

Adds Claude Code Stop and PostToolUse hooks for Claude-Codex Review Bridge.

By default this script prints what it would do and exits without modifying
settings. Pass --force to patch the settings file.

Environment:
  CRB_SETTINGS_PATH  Override Claude settings path.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

STOP_COMMAND='bash "$CLAUDE_PROJECT_DIR/hooks/codex-review-stop.sh"'
FILE_COMMAND='bash "$CLAUDE_PROJECT_DIR/hooks/codex-review-file.sh"'

cat <<EOF
Claude-Codex Review Bridge hook installer

Project:  $PROJECT_DIR
Settings: $SETTINGS_PATH

Will ensure:
- Stop hook:        $STOP_COMMAND
- PostToolUse hook: $FILE_COMMAND
EOF

if [[ "$FORCE" -ne 1 ]]; then
  cat <<EOF

No changes made. Re-run with --force after reviewing the target settings path.
EOF
  exit 1
fi

mkdir -p "$(dirname "$SETTINGS_PATH")"
if [[ ! -f "$SETTINGS_PATH" ]]; then
  printf '{}\n' >"$SETTINGS_PATH"
fi

BACKUP_PATH="$SETTINGS_PATH.bak.$(date -u '+%Y%m%d%H%M%S')"
cp "$SETTINGS_PATH" "$BACKUP_PATH"

SETTINGS_PATH="$SETTINGS_PATH" node <<'NODE'
const fs = require("fs");

const settingsPath = process.env.SETTINGS_PATH;
const raw = fs.readFileSync(settingsPath, "utf8").trim();
const settings = raw ? JSON.parse(raw) : {};

settings.hooks ??= {};
settings.hooks.Stop ??= [];
settings.hooks.PostToolUse ??= [];

const stopCommand = 'bash "$CLAUDE_PROJECT_DIR/hooks/codex-review-stop.sh"';
const fileCommand = 'bash "$CLAUDE_PROJECT_DIR/hooks/codex-review-file.sh"';

function entryHasCommand(entry, command) {
  return Array.isArray(entry?.hooks) && entry.hooks.some((hook) => hook.command === command);
}

if (!settings.hooks.Stop.some((entry) => entryHasCommand(entry, stopCommand))) {
  settings.hooks.Stop.push({
    hooks: [
      {
        type: "command",
        command: stopCommand,
        timeout: 120
      }
    ]
  });
}

if (!settings.hooks.PostToolUse.some((entry) => entry.matcher === "Write|Edit" && entryHasCommand(entry, fileCommand))) {
  settings.hooks.PostToolUse.push({
    matcher: "Write|Edit",
    hooks: [
      {
        type: "command",
        command: fileCommand,
        timeout: 60
      }
    ]
  });
}

fs.writeFileSync(settingsPath, `${JSON.stringify(settings, null, 2)}\n`);
NODE

printf '\nUpdated settings. Backup written to %s\n' "$BACKUP_PATH"
