#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=hooks/lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"

SCHEMA_PATH="$SCRIPT_DIR/review-schema.json"
HOOK_INPUT="$(cat)"
SESSION_ID="$(printf '%s' "$HOOK_INPUT" | crb_json_get "session_id")"
CWD_VALUE="$(printf '%s' "$HOOK_INPUT" | crb_json_get "cwd")"
TRANSCRIPT_PATH="$(printf '%s' "$HOOK_INPUT" | crb_json_get "transcript_path")"
STOP_HOOK_ACTIVE="$(printf '%s' "$HOOK_INPUT" | crb_json_get "stop_hook_active")"
WORKDIR="$(crb_normalize_path "${CWD_VALUE:-$(pwd)}")"
STATE_DIR="${CRB_STATE_DIR:-$CRB_DATA_DIR}"

crb_log "Stop hook invoked for session ${SESSION_ID:-unknown}"

if ! crb_is_enabled; then
  crb_log "Stop hook skipped: CRB disabled"
  exit 0
fi

BACKGROUND_COUNT="$(printf '%s' "$HOOK_INPUT" | crb_json_array_length "background_tasks")"
CRON_COUNT="$(printf '%s' "$HOOK_INPUT" | crb_json_array_length "session_crons")"
if (( BACKGROUND_COUNT > 0 || CRON_COUNT > 0 )); then
  crb_log "Stop hook deferred: background work or session schedules are still active"
  printf '%s' "$(
    printf '%s' "CRB review deferred because background work or a session schedule is still active." |
      crb_json_system_message
  )"
  exit 0
fi

if ! cd "$WORKDIR" 2>/dev/null; then
  crb_log "Stop hook skipped: cannot cd to $WORKDIR"
  exit 0
fi

# Collect a bounded, privacy-filtered patch if this is a Git repository.
DIFF_OUTPUT=""
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! DIFF_OUTPUT="$(crb_collect_review_diff 2>/dev/null)"; then
    crb_log "Stop hook skipped: change collection failed"
    printf '%s' "$(printf '%s' "CRB review is incomplete because repository change collection failed. No review round was consumed; see /crb log." | crb_json_system_message)"
    exit 0
  fi
else
  crb_log "Stop hook: not a git repo, will review response text only"
fi

# Current Claude payloads provide the final message directly because the
# transcript may lag. Keep transcript parsing only as a compatibility fallback.
RESPONSE_TEXT="$(printf '%s' "$HOOK_INPUT" | crb_json_get "last_assistant_message")"
if [[ -z "$RESPONSE_TEXT" ]]; then
  RESPONSE_TEXT="$(crb_get_last_assistant_message "$TRANSCRIPT_PATH")"
fi
if [[ -n "$RESPONSE_TEXT" ]]; then
  RESPONSE_TEXT="$(
    printf '%s' "$RESPONSE_TEXT" |
      CRB_MAX_INPUT_BYTES="${CRB_MAX_RESPONSE_BYTES:-100000}" crb_bound_review_input
  )"
fi

if [[ -z "$DIFF_OUTPUT" && -z "$RESPONSE_TEXT" ]]; then
  crb_log "Stop hook skipped: no diff and no response text"
  exit 0
fi

if ! crb_prepare_private_dir "$STATE_DIR"; then
  crb_log "Stop hook skipped: private state directory unavailable"
  printf '%s' "$(printf '%s' "CRB review failed because its private state directory is unavailable." | crb_json_system_message)"
  exit 0
fi
SAFE_SESSION_ID="$(crb_sanitize_session_id "$SESSION_ID")"
COUNT_FILE="$STATE_DIR/codex-review-${SAFE_SESSION_ID}-count"

if [[ -L "$COUNT_FILE" || ( -e "$COUNT_FILE" && ! -f "$COUNT_FILE" ) ]]; then
  crb_log "Stop hook skipped: unsafe counter target"
  printf '%s' "$(printf '%s' "CRB review failed because its counter target is unsafe." | crb_json_system_message)"
  exit 0
fi

# A current Stop payload explicitly marks the start of a fresh review cycle.
# Missing state is treated as a legacy payload and keeps the old counter.
if [[ "$STOP_HOOK_ACTIVE" == "false" ]]; then
  rm -f -- "$COUNT_FILE" 2>/dev/null || true
fi

COUNT="0"
if [[ -f "$COUNT_FILE" ]]; then
  COUNT="$(cat "$COUNT_FILE" 2>/dev/null || printf '0')"
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT="0"
fi

MAX_ROUNDS="${CRB_MAX_ROUNDS:-3}"
if ! [[ "$MAX_ROUNDS" =~ ^[0-9]+$ ]] || (( MAX_ROUNDS < 1 )); then
  MAX_ROUNDS=3
fi
if (( MAX_ROUNDS > 5 )); then
  MAX_ROUNDS=5
fi
if (( COUNT >= MAX_ROUNDS )); then
  crb_log "Stop hook skipped: review loop cap reached ($COUNT/$MAX_ROUNDS) for ${SESSION_ID:-unknown}"
  printf '%s' "$(printf '%s' "CRB review loop cap reached ($COUNT/$MAX_ROUNDS). Review is incomplete; inspect the CRB log or run /crb reset." | crb_json_system_message)"
  exit 0
fi
ROUND="$((COUNT + 1))"
crb_log "Stop hook: starting review round $ROUND/$MAX_ROUNDS"

PROMPT="$(crb_build_review_prompt "diff" "$DIFF_OUTPUT" "" "$RESPONSE_TEXT" | crb_bound_review_input)"

if ! REVIEW_OUTPUT="$(printf '%s' "$PROMPT" | crb_run_codex_review "$SCHEMA_PATH")"; then
  crb_log "Stop hook review failed: codex exec failed or returned invalid output"
  printf '%s' "$(printf '%s' "CRB review failed before producing a valid result. No review round was consumed; see /crb log." | crb_json_system_message)"
  exit 0
fi

SEVERITY="$(printf '%s' "$REVIEW_OUTPUT" | crb_review_severity 2>/dev/null || true)"
case "$SEVERITY" in
  LGTM)
    crb_log "Stop hook review result: LGTM (round $ROUND/$MAX_ROUNDS)"
    rm -f "$COUNT_FILE" 2>/dev/null || true
    exit 0
    ;;
  MINOR)
    crb_log "Stop hook review result: MINOR (round $ROUND/$MAX_ROUNDS)"
    if ! crb_atomic_write "$COUNT_FILE" "$ROUND"; then
      crb_log "Stop hook review stopped: counter update failed"
      printf '%s' "$(
        printf '%s' "$REVIEW_OUTPUT" |
          crb_format_review "Codex found minor issues, but CRB could not persist its review-round state. The automatic loop has stopped; inspect the findings and /crb log." |
          crb_json_system_message
      )"
      exit 0
    fi
    printf '%s\n' "$(printf '%s' "$REVIEW_OUTPUT" | crb_format_stop_feedback "MINOR" "$ROUND" "$MAX_ROUNDS")" >&2
    exit 2
    ;;
  MAJOR)
    crb_log "Stop hook review result: MAJOR (round $ROUND/$MAX_ROUNDS)"
    if ! crb_atomic_write "$COUNT_FILE" "$ROUND"; then
      crb_log "Stop hook major review: counter update failed; loop remains stopped"
    fi
    printf '%s' "$(
      printf '%s' "$REVIEW_OUTPUT" |
        crb_format_stop_feedback "MAJOR" "$ROUND" "$MAX_ROUNDS" |
        crb_json_system_message
    )"
    exit 0
    ;;
  *)
    crb_log "Stop hook review failed: invalid Codex severity '${SEVERITY:-empty}'"
    printf '%s' "$(printf '%s' "CRB review failed because the reviewer returned an invalid severity. No review round was consumed." | crb_json_system_message)"
    exit 0
    ;;
esac
