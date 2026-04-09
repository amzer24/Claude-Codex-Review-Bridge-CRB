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
STATE_DIR="${CRB_STATE_DIR:-${TMPDIR:-/tmp}}"

crb_log "Stop hook invoked for session ${SESSION_ID:-unknown}"

if ! cd "$WORKDIR" 2>/dev/null; then
  crb_log "Stop hook skipped: cannot cd to $WORKDIR"
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  crb_log "Stop hook skipped: $WORKDIR is not a git work tree"
  exit 0
fi

DIFF_OUTPUT="$(git diff HEAD -- 2>/dev/null || true)"
if [[ -z "$DIFF_OUTPUT" ]]; then
  crb_log "Stop hook skipped: no diff"
  exit 0
fi

mkdir -p "$STATE_DIR" 2>/dev/null || true
SAFE_SESSION_ID="$(crb_sanitize_session_id "$SESSION_ID")"
COUNT_FILE="$STATE_DIR/codex-review-${SAFE_SESSION_ID}-count"
COUNT="0"
if [[ -f "$COUNT_FILE" ]]; then
  COUNT="$(cat "$COUNT_FILE" 2>/dev/null || printf '0')"
fi
if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
  COUNT="0"
fi

if (( COUNT >= 3 )); then
  crb_log "Stop hook skipped: review loop cap reached for ${SESSION_ID:-unknown}"
  exit 0
fi
printf '%s\n' "$((COUNT + 1))" >"$COUNT_FILE" 2>/dev/null || true

PROMPT="$(cat <<EOF
You are a senior code reviewer. Review this git diff for:
- Bugs, logic errors, off-by-one errors
- Security vulnerabilities (injection, XSS, secrets)
- Missing error handling at system boundaries
- Architectural concerns

Return structured JSON matching the output schema.

Git diff:
\`\`\`diff
$DIFF_OUTPUT
\`\`\`
EOF
)"

if ! REVIEW_OUTPUT="$(printf '%s' "$PROMPT" | crb_run_codex_review "$SCHEMA_PATH")"; then
  crb_log "Stop hook skipped: codex exec failed"
  exit 0
fi

SEVERITY="$(printf '%s' "$REVIEW_OUTPUT" | crb_review_severity 2>/dev/null || true)"
case "$SEVERITY" in
  LGTM)
    crb_log "Stop hook review result: LGTM"
    exit 0
    ;;
  MINOR)
    crb_log "Stop hook review result: MINOR"
    printf '%s\n' "$(printf '%s' "$REVIEW_OUTPUT" | crb_format_review "Codex review found minor issues:")" >&2
    exit 2
    ;;
  MAJOR)
    crb_log "Stop hook review result: MAJOR"
    printf '%s' "$(
      printf '%s' "$REVIEW_OUTPUT" |
        crb_format_review "Codex review found major issues:" |
        crb_json_system_message
    )"
    exit 0
    ;;
  *)
    crb_log "Stop hook skipped: invalid Codex severity '${SEVERITY:-empty}'"
    exit 0
    ;;
esac
