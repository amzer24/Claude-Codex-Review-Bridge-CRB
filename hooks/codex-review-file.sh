#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SCHEMA_PATH="$SCRIPT_DIR/review-schema.json"
HOOK_INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | crb_json_get "session_id")"
CWD_VALUE="$(printf '%s' "$HOOK_INPUT" | crb_json_get "cwd")"
WORKDIR="$(crb_normalize_path "${CWD_VALUE:-$(pwd)}")"
RAW_FILE_PATH="$(printf '%s' "$HOOK_INPUT" | crb_json_get "tool_input.file_path")"

crb_log "PostToolUse hook invoked for session ${SESSION_ID:-unknown}"

if ! crb_is_enabled; then
  crb_log "PostToolUse hook skipped: CRB disabled"
  exit 0
fi

if [[ -z "$RAW_FILE_PATH" ]]; then
  crb_log "PostToolUse hook skipped: no file path"
  exit 0
fi

if ! cd "$WORKDIR" 2>/dev/null; then
  crb_log "PostToolUse hook skipped: cannot cd to $WORKDIR"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  crb_log "PostToolUse hook skipped: $WORKDIR is not a git work tree"
  exit 0
fi

FILE_PATH="$(crb_normalize_path "$RAW_FILE_PATH")"

# Resolve git repository root and canonicalize the target path, then enforce
# that it lives under the repo. Blocks absolute paths and ../ traversal that
# would leak files from outside the work tree to the reviewer.
GIT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [[ -z "$GIT_ROOT" ]]; then
  crb_log "PostToolUse hook skipped: cannot resolve git root"
  exit 0
fi
# Canonicalize the git root too, so the prefix comparison survives symlinks
# in the path leading up to the repo (e.g. /var -> /private/var on macOS).
CANONICAL_ROOT="$({ cd "$GIT_ROOT" && pwd -P; } 2>/dev/null)"
if [[ -z "$CANONICAL_ROOT" ]]; then
  crb_log "PostToolUse hook skipped: cannot canonicalize git root"
  exit 0
fi

# Canonicalize target. For existing files, resolve via pwd -P of its parent;
# for missing files, fall back to a lexical path under the workdir.
if [[ "$FILE_PATH" = /* ]]; then
  CANDIDATE="$FILE_PATH"
else
  CANDIDATE="$WORKDIR/$FILE_PATH"
fi
if [[ -e "$CANDIDATE" ]]; then
  CANONICAL_FILE="$({ cd "$(dirname "$CANDIDATE")" && printf '%s/%s' "$(pwd -P)" "$(basename "$CANDIDATE")"; } 2>/dev/null)"
else
  CANONICAL_FILE="$CANDIDATE"
fi
if [[ -z "$CANONICAL_FILE" ]]; then
  crb_log "PostToolUse hook skipped: cannot canonicalize $FILE_PATH"
  exit 0
fi
if [[ "$CANONICAL_FILE" != "$CANONICAL_ROOT"/* && "$CANONICAL_FILE" != "$CANONICAL_ROOT" ]]; then
  crb_log "PostToolUse hook skipped: path outside repo ($CANONICAL_FILE)"
  exit 0
fi

GIT_FILE_PATH="${CANONICAL_FILE#"$CANONICAL_ROOT/"}"

# Untracked (new) files are reviewed too — that's when review catches the most.

if ! crb_is_code_file "$GIT_FILE_PATH"; then
  crb_log "PostToolUse hook skipped: non-code file $GIT_FILE_PATH"
  exit 0
fi

# Reject symlinks to prevent leaking arbitrary local files
if [[ -L "$CANONICAL_FILE" ]] || [[ -L "$FILE_PATH" ]]; then
  crb_log "PostToolUse hook skipped: symlink $GIT_FILE_PATH"
  exit 0
fi

# Read full file from disk for complete context.
# tool_input.new_string (Edit) is only a partial snippet and causes false positives.
if [[ -f "$CANONICAL_FILE" ]]; then
  CHANGE_CONTENT="$(cat "$CANONICAL_FILE")"
else
  CHANGE_CONTENT="$(printf '%s' "$HOOK_INPUT" | crb_json_get "tool_input.content")"
fi

PROMPT="$(crb_build_review_prompt "file" "$CHANGE_CONTENT" "$GIT_FILE_PATH")"

if ! REVIEW_OUTPUT="$(printf '%s' "$PROMPT" | crb_run_codex_review "$SCHEMA_PATH")"; then
  crb_log "PostToolUse hook skipped: codex exec failed"
  exit 0
fi

SEVERITY="$(printf '%s' "$REVIEW_OUTPUT" | crb_review_severity 2>/dev/null || true)"
case "$SEVERITY" in
  MAJOR)
    crb_log "PostToolUse hook review result: MAJOR"
    FORMATTED="$(printf '%s' "$REVIEW_OUTPUT" | crb_format_review "Codex found major issue in $GIT_FILE_PATH:")"
    if [[ "${CRB_STRICT_POSTTOOL:-0}" == "1" ]]; then
      # Strict mode: block + reason forces Claude to address before continuing.
      # Fail closed if node is unavailable or the encoder errors — emit a
      # minimal block decision on stderr and exit 2 so the user still sees it.
      if ! command -v node >/dev/null 2>&1; then
        crb_log "PostToolUse strict mode: node unavailable, fail-closed"
        printf 'CRB strict mode: MAJOR issue but block JSON encoder unavailable.\n%s\n' "$FORMATTED" >&2
        exit 2
      fi
      BLOCK_JSON="$(printf '%s' "$FORMATTED" | node -e '
const fs = require("fs");
const msg = fs.readFileSync(0, "utf8");
process.stdout.write(JSON.stringify({
  decision: "block",
  reason: msg,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: msg
  }
}));
')" || BLOCK_JSON=""
      if [[ -z "$BLOCK_JSON" ]]; then
        crb_log "PostToolUse strict mode: block JSON encoding failed, fail-closed"
        printf 'CRB strict mode: MAJOR issue but block JSON encoding failed.\n%s\n' "$FORMATTED" >&2
        exit 2
      fi
      printf '%s' "$BLOCK_JSON"
    else
      printf '%s' "$FORMATTED" | crb_json_post_tool_context
    fi
    exit 0
    ;;
  LGTM|MINOR)
    crb_log "PostToolUse hook review result: $SEVERITY"
    exit 0
    ;;
  *)
    crb_log "PostToolUse hook skipped: invalid Codex severity '${SEVERITY:-empty}'"
    exit 0
    ;;
esac
