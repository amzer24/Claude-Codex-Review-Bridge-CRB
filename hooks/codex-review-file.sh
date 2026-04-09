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
NORMALIZED_WORKDIR="$(crb_normalize_path "$WORKDIR")"
if [[ "$FILE_PATH" == "$NORMALIZED_WORKDIR/"* ]]; then
  GIT_FILE_PATH="${FILE_PATH#"$NORMALIZED_WORKDIR/"}"
else
  GIT_FILE_PATH="$FILE_PATH"
fi

if ! git ls-files --error-unmatch -- "$GIT_FILE_PATH" >/dev/null 2>&1; then
  crb_log "PostToolUse hook skipped: untracked file $GIT_FILE_PATH"
  exit 0
fi

if ! crb_is_code_file "$GIT_FILE_PATH"; then
  crb_log "PostToolUse hook skipped: non-code file $GIT_FILE_PATH"
  exit 0
fi

# Always send the full file to Codex for complete context.
# tool_input.new_string (Edit) is only a partial snippet and causes
# false positives when Codex can't see the rest of the file.
if [[ -f "$GIT_FILE_PATH" ]]; then
  CHANGE_CONTENT="$(cat "$GIT_FILE_PATH")"
elif [[ -f "$FILE_PATH" ]]; then
  CHANGE_CONTENT="$(cat "$FILE_PATH")"
else
  CHANGE_CONTENT="$(printf '%s' "$HOOK_INPUT" | crb_json_get "tool_input.content")"
fi

SAFE_CONTENT="$(printf '%s' "$CHANGE_CONTENT" | crb_escape_fences)"

PROMPT="$(cat <<EOF
You are a senior code reviewer. Review this changed file for major issues only:
- Bugs or logic errors that are likely to break behavior
- Security vulnerabilities (injection, XSS, secrets)
- Missing error handling at system boundaries
- Architectural concerns that should be addressed before continuing

Return structured JSON matching the output schema. Use LGTM or MINOR for issues that do not need immediate Claude feedback.

File: $GIT_FILE_PATH
\`\`\`
$SAFE_CONTENT
\`\`\`
EOF
)"

if ! REVIEW_OUTPUT="$(printf '%s' "$PROMPT" | crb_run_codex_review "$SCHEMA_PATH")"; then
  crb_log "PostToolUse hook skipped: codex exec failed"
  exit 0
fi

SEVERITY="$(printf '%s' "$REVIEW_OUTPUT" | crb_review_severity 2>/dev/null || true)"
case "$SEVERITY" in
  MAJOR)
    crb_log "PostToolUse hook review result: MAJOR"
    printf '%s' "$(
      printf '%s' "$REVIEW_OUTPUT" |
        crb_format_review "Codex found major issue in $GIT_FILE_PATH:" |
        crb_json_post_tool_context
    )"
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
