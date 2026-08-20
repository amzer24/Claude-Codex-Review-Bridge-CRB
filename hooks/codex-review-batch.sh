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
STATE_DIR="${CRB_STATE_DIR:-$CRB_DATA_DIR}"

crb_log "PostToolBatch hook invoked for session ${SESSION_ID:-unknown}"

if ! crb_is_enabled; then
  crb_log "PostToolBatch hook skipped: CRB disabled"
  exit 0
fi

# PostToolBatch has no matcher. Avoid re-reviewing a stale working-tree diff
# after batches made entirely of documented read-only tools.
if ! printf '%s' "$HOOK_INPUT" | crb_batch_may_change_files; then
  crb_log "PostToolBatch hook skipped: read-only tool batch"
  exit 0
fi

if ! cd "$WORKDIR" 2>/dev/null; then
  crb_log "PostToolBatch hook skipped: cannot cd to $WORKDIR"
  exit 0
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  crb_log "PostToolBatch hook skipped: $WORKDIR is not a git work tree"
  exit 0
fi

if ! DIFF_OUTPUT="$(crb_collect_review_diff 2>/dev/null)"; then
  crb_log "PostToolBatch hook skipped: change collection failed"
  printf '%s' "$(printf '%s' "CRB batch review is incomplete because repository change collection failed. The final Stop review will retry; see /crb log." | crb_json_system_message)"
  exit 0
fi
if [[ -z "$DIFF_OUTPUT" ]]; then
  crb_log "PostToolBatch hook skipped: no eligible changes"
  exit 0
fi

if ! crb_prepare_private_dir "$STATE_DIR"; then
  crb_log "PostToolBatch hook skipped: private state directory unavailable"
  printf '%s' "$(printf '%s' "CRB batch review failed because its private state directory is unavailable." | crb_json_system_message)"
  exit 0
fi

SAFE_SESSION_ID="$(crb_sanitize_session_id "$SESSION_ID")"
HASH_FILE="$STATE_DIR/codex-review-${SAFE_SESSION_ID}-last-diff"
if [[ -L "$HASH_FILE" || ( -e "$HASH_FILE" && ! -f "$HASH_FILE" ) ]]; then
  crb_log "PostToolBatch hook skipped: unsafe diff-hash target"
  printf '%s' "$(printf '%s' "CRB batch review failed because its state target is unsafe." | crb_json_system_message)"
  exit 0
fi

DIFF_HASH="$(printf '%s' "$DIFF_OUTPUT" | crb_sha256)"
if [[ -f "$HASH_FILE" && "$(cat "$HASH_FILE" 2>/dev/null || true)" == "$DIFF_HASH" ]]; then
  crb_log "PostToolBatch hook skipped: unchanged review packet"
  exit 0
fi

PROMPT="$(crb_build_review_prompt "diff" "$DIFF_OUTPUT" | crb_bound_review_input)"
if ! REVIEW_OUTPUT="$(printf '%s' "$PROMPT" | crb_run_codex_review "$SCHEMA_PATH")"; then
  crb_log "PostToolBatch review failed: codex exec failed or returned invalid output"
  printf '%s' "$(printf '%s' "CRB batch review failed before producing a valid result. The final Stop review will retry; see /crb log." | crb_json_system_message)"
  exit 0
fi

SEVERITY="$(printf '%s' "$REVIEW_OUTPUT" | crb_review_severity 2>/dev/null || true)"
case "$SEVERITY" in
  LGTM|MINOR|MAJOR)
    crb_atomic_write "$HASH_FILE" "$DIFF_HASH" || crb_log "PostToolBatch warning: diff-hash update failed"
    ;;
  *)
    crb_log "PostToolBatch review failed: invalid Codex severity '${SEVERITY:-empty}'"
    printf '%s' "$(printf '%s' "CRB batch review failed because the reviewer returned an invalid severity." | crb_json_system_message)"
    exit 0
    ;;
esac

case "$SEVERITY" in
  MAJOR)
    crb_log "PostToolBatch review result: MAJOR"
    FORMATTED="$(printf '%s' "$REVIEW_OUTPUT" | crb_format_review "Codex found major issues in the current change set:")"
    if [[ "${CRB_STRICT_POSTTOOL:-0}" == "1" ]]; then
      if ! printf '%s' "$FORMATTED" | crb_node -e '
const fs = require("fs");
const message = fs.readFileSync(0, "utf8");
process.stdout.write(JSON.stringify({
  decision: "block",
  reason: message,
  hookSpecificOutput: {
    hookEventName: "PostToolBatch",
    additionalContext: message
  }
}));
'; then
        crb_log "PostToolBatch strict review failed: block-response encoding failed"
        # This string is static trusted JSON, so strict mode remains fail-closed
        # even if the local Node encoder becomes unavailable at this last step.
        printf '%s' '{"decision":"block","reason":"CRB strict review failed while encoding reviewer feedback. Inspect the CRB log before continuing."}'
      fi
    else
      printf '%s' "$FORMATTED" | crb_json_post_tool_context "PostToolBatch"
    fi
    ;;
  LGTM|MINOR)
    crb_log "PostToolBatch review result: $SEVERITY"
    ;;
esac

exit 0
