#!/usr/bin/env bash
set -u -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STOP_HOOK="$SCRIPT_DIR/codex-review-stop.sh"

DOCTOR_TMP="$(mktemp -d)"
trap 'rm -rf "$DOCTOR_TMP"' EXIT

(cd "$DOCTOR_TMP" && git init -q && git config user.email "crb@test" && git config user.name "CRB" && echo "x" > f.js && git add f.js && git commit -qm init && echo "y" > f.js)

if echo "{\"session_id\":\"doctor\",\"cwd\":\"$DOCTOR_TMP\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"last_assistant_message\":\"Doctor dry run completed\",\"background_tasks\":[],\"session_crons\":[]}" \
    | CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=LGTM CRB_TOGGLE_FILE=<(echo 1) bash "$STOP_HOOK" >/dev/null 2>&1; then
  echo "Hook dry run: PASS"
else
  echo "Hook dry run: FAIL"
  exit 1
fi
