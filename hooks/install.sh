#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGET_DIR="${CRB_TARGET_DIR:-$(pwd)}"
SETTINGS_PATH="${CRB_SETTINGS_PATH:-$TARGET_DIR/.claude/settings.local.json}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force)
      FORCE=1
      ;;
    --help|-h)
      cat <<EOF
Usage: cd your-project && /path/to/hooks/install.sh [--force]

Adds Claude Code hooks for Claude-Codex Review Bridge to the current
project. Hook commands use absolute paths to the CRB scripts, so hooks
work regardless of which project is active.

Installs to: \$PWD/.claude/settings.local.json (project-scoped, gitignored)

Environment:
  CRB_TARGET_DIR      Override target project directory (default: \$PWD).
  CRB_SETTINGS_PATH   Override Claude settings path.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

# Shell-escape the CRB_ROOT path for safe embedding in hook commands
ESCAPED_ROOT="$(printf '%s' "$CRB_ROOT" | sed "s/'/'\\\\''/g")"
STOP_COMMAND="bash '$ESCAPED_ROOT/hooks/codex-review-stop.sh'"
FILE_COMMAND="bash '$ESCAPED_ROOT/hooks/codex-review-file.sh'"

cat <<EOF
Claude-Codex Review Bridge hook installer

CRB source: $CRB_ROOT
Target:     $TARGET_DIR
Settings:   $SETTINGS_PATH

Will ensure:
- Stop hook:        $STOP_COMMAND
- PostToolUse hook: $FILE_COMMAND
EOF

if [[ "$FORCE" -ne 1 ]]; then
  cat <<EOF

No changes made. Re-run with --force after reviewing the above paths.
EOF
  exit 1
fi

if ! mkdir -p "$(dirname "$SETTINGS_PATH")" 2>/dev/null; then
  printf 'Error: cannot create directory for %s\n' "$SETTINGS_PATH" >&2
  exit 1
fi
if [[ ! -f "$SETTINGS_PATH" ]]; then
  printf '{}\n' >"$SETTINGS_PATH"
fi

BACKUP_PATH="$SETTINGS_PATH.bak.$(date -u '+%Y%m%d%H%M%S')"
if ! cp "$SETTINGS_PATH" "$BACKUP_PATH"; then
  printf 'Error: cannot create backup at %s\n' "$BACKUP_PATH" >&2
  exit 1
fi

CRB_ROOT="$CRB_ROOT" SETTINGS_PATH="$SETTINGS_PATH" node <<'NODE'
const fs = require("fs");

const settingsPath = process.env.SETTINGS_PATH;
const crbRoot = process.env.CRB_ROOT;
const raw = fs.readFileSync(settingsPath, "utf8").trim();
const settings = raw ? JSON.parse(raw) : {};

settings.hooks ??= {};
settings.hooks.Stop ??= [];
settings.hooks.PostToolUse ??= [];

// Single-quote the path to prevent shell metacharacter expansion
const escaped = crbRoot.replace(/'/g, "'\\''");
const stopCommand = `bash '${escaped}/hooks/codex-review-stop.sh'`;
const fileCommand = `bash '${escaped}/hooks/codex-review-file.sh'`;

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

if (!settings.hooks.PostToolUse.some((entry) => entry.matcher === "Write|Edit|MultiEdit" && entryHasCommand(entry, fileCommand))) {
  settings.hooks.PostToolUse.push({
    matcher: "Write|Edit|MultiEdit",
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

if [[ $? -ne 0 ]]; then
  printf '\nError: settings patch failed. Restoring backup.\n' >&2
  cp "$BACKUP_PATH" "$SETTINGS_PATH"
  exit 1
fi

printf '\nUpdated settings. Backup written to %s\n' "$BACKUP_PATH"
