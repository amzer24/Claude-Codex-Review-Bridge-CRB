#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=hooks/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
TARGET_DIR="${CRB_TARGET_DIR:-$(pwd)}"
SETTINGS_PATH_EXPLICIT=0
if [[ -n "${CRB_SETTINGS_PATH+x}" ]]; then
  SETTINGS_PATH_EXPLICIT=1
  SETTINGS_PATH="$CRB_SETTINGS_PATH"
else
  SETTINGS_PATH="$TARGET_DIR/.claude/settings.local.json"
fi
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
  CRB_INSTALL_STATE_DIR  Override private backup directory.
EOF
      exit 0
      ;;
    *)
      printf 'Unknown argument: %s\n' "$arg" >&2
      exit 1
      ;;
  esac
done

STOP_SCRIPT="$CRB_ROOT/hooks/codex-review-stop.sh"
BATCH_SCRIPT="$CRB_ROOT/hooks/codex-review-batch.sh"

cat <<EOF
Claude-Codex Review Bridge hook installer

CRB source: $CRB_ROOT
Target:     $TARGET_DIR
Settings:   $SETTINGS_PATH

Will ensure:
- Stop hook:          bash $STOP_SCRIPT
- PostToolBatch hook: bash $BATCH_SCRIPT
EOF

if [[ "$FORCE" -ne 1 ]]; then
  cat <<EOF

No changes made. Re-run with --force after reviewing the above paths.
EOF
  exit 1
fi

if ! TARGET_DIR="$(cd "$TARGET_DIR" 2>/dev/null && pwd -P)"; then
  printf 'Error: target project directory does not exist or is inaccessible.\n' >&2
  exit 1
fi
if [[ "$SETTINGS_PATH_EXPLICIT" -eq 0 ]]; then
  SETTINGS_PATH="$TARGET_DIR/.claude/settings.local.json"
fi

# Refuse link traversal before creating or replacing project settings. A
# repository-controlled .claude junction/symlink must not redirect --force to
# an arbitrary location outside the selected project.
if ! crb_path_has_no_link_components "$SETTINGS_PATH" ||
    ! node - "$TARGET_DIR" "$SETTINGS_PATH" "$SETTINGS_PATH_EXPLICIT" <<'NODE'
const fs = require("fs");
const path = require("path");
const [targetInput, settingsInput, explicitValue] = process.argv.slice(2);
const target = fs.realpathSync(path.resolve(targetInput));
const settings = path.resolve(settingsInput);
const explicit = explicitValue === "1";

function linkAt(candidate) {
  try { return fs.lstatSync(candidate).isSymbolicLink(); }
  catch (error) {
    if (error?.code === "ENOENT") return false;
    throw error;
  }
}

if (!explicit) {
  const relative = path.relative(target, settings);
  if (!relative || relative.startsWith(`..${path.sep}`) || relative === ".." || path.isAbsolute(relative)) {
    throw new Error("default settings path escapes the selected project");
  }
  let current = target;
  for (const component of relative.split(path.sep)) {
    current = path.join(current, component);
    if (linkAt(current)) throw new Error(`symlink or junction in settings path: ${current}`);
  }
} else {
  for (const candidate of [path.dirname(settings), settings]) {
    if (linkAt(candidate)) throw new Error(`symlink or junction in settings path: ${candidate}`);
  }
}
NODE
then
  printf 'Error: unsafe settings path; symlink/junction traversal is not allowed.\n' >&2
  exit 1
fi

if ! mkdir -p "$(dirname "$SETTINGS_PATH")" 2>/dev/null; then
  printf 'Error: cannot create directory for %s\n' "$SETTINGS_PATH" >&2
  exit 1
fi
if [[ ! -f "$SETTINGS_PATH" ]]; then
  printf '{}\n' >"$SETTINGS_PATH"
fi

BACKUP_DIR="${CRB_INSTALL_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/crb/backups}"
if ! crb_prepare_private_dir "$BACKUP_DIR"; then
  printf 'Error: cannot create private backup directory at %s\n' "$BACKUP_DIR" >&2
  exit 1
fi
BACKUP_PATH="$BACKUP_DIR/settings.local.json.$(date -u '+%Y%m%d%H%M%S').$$.bak"
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
settings.hooks.PostToolBatch ??= [];

const stopScript = `${crbRoot}/hooks/codex-review-stop.sh`;
const batchScript = `${crbRoot}/hooks/codex-review-batch.sh`;

function hookText(hook) {
  return [hook?.command, ...(Array.isArray(hook?.args) ? hook.args : [])]
    .filter(Boolean)
    .join(" ")
    .replace(/\\/g, "/");
}

function entryContains(entry, scriptName) {
  return Array.isArray(entry?.hooks) && entry.hooks.some((hook) => hookText(hook).includes(scriptName));
}

// Replace only CRB-owned entries. Preserve every unrelated user hook.
settings.hooks.Stop = settings.hooks.Stop.filter((entry) => !entryContains(entry, "codex-review-stop.sh"));
if (Array.isArray(settings.hooks.PostToolUse)) {
  settings.hooks.PostToolUse = settings.hooks.PostToolUse.filter(
    (entry) => !entryContains(entry, "codex-review-file.sh")
  );
  if (settings.hooks.PostToolUse.length === 0) delete settings.hooks.PostToolUse;
}
settings.hooks.PostToolBatch = settings.hooks.PostToolBatch.filter(
  (entry) => !entryContains(entry, "codex-review-batch.sh")
);

settings.hooks.Stop.push({
  hooks: [
    {
      type: "command",
      command: "bash",
      args: [stopScript],
      timeout: 150
    }
  ]
});

settings.hooks.PostToolBatch.push({
  hooks: [
    {
      type: "command",
      command: "bash",
      args: [batchScript],
      timeout: 150
    }
  ]
});

const tempPath = `${settingsPath}.crb-tmp-${process.pid}`;
try {
  fs.writeFileSync(tempPath, `${JSON.stringify(settings, null, 2)}\n`, { mode: 0o600 });
  fs.renameSync(tempPath, settingsPath);
} catch (error) {
  try { fs.unlinkSync(tempPath); } catch {}
  throw error;
}
NODE

if [[ $? -ne 0 ]]; then
  printf '\nError: settings patch failed. Restoring backup.\n' >&2
  cp "$BACKUP_PATH" "$SETTINGS_PATH"
  exit 1
fi

printf '\nUpdated settings. Backup written to %s\n' "$BACKUP_PATH"
