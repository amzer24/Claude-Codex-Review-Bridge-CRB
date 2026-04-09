#!/usr/bin/env bash

crb_log() {
  local message="$1"
  local log_file="${CRB_LOG_FILE:-${TMPDIR:-/tmp}/codex-review.log}"
  mkdir -p "$(dirname "$log_file")" 2>/dev/null || true
  printf '[%s] %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$message" >>"$log_file" 2>/dev/null || true
}

crb_json_get() {
  local path="$1"
  node -e '
const fs = require("fs");
const path = process.argv[1].split(".");
const input = fs.readFileSync(0, "utf8");
const data = input.trim() ? JSON.parse(input) : {};
let value = data;
for (const key of path) {
  if (value == null || !Object.prototype.hasOwnProperty.call(value, key)) {
    process.exit(0);
  }
  value = value[key];
}
if (value == null) process.exit(0);
if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
  process.stdout.write(String(value));
} else {
  process.stdout.write(JSON.stringify(value));
}
' "$path"
}

crb_review_severity() {
  crb_json_get "severity"
}

crb_format_review() {
  local intro="$1"
  node -e '
const fs = require("fs");
const intro = process.argv[1];
const raw = fs.readFileSync(0, "utf8");
let data;
try {
  data = raw.trim() ? JSON.parse(raw) : {};
} catch (error) {
  process.stdout.write(`${intro}\n\nRaw Codex output:\n${raw}`);
  process.exit(0);
}
const lines = [intro];
if (Array.isArray(data.issues) && data.issues.length > 0) {
  lines.push("", "Issues:");
  for (const issue of data.issues) lines.push(`- ${issue}`);
}
if (Array.isArray(data.suggestions) && data.suggestions.length > 0) {
  lines.push("", "Suggestions:");
  for (const suggestion of data.suggestions) lines.push(`- ${suggestion}`);
}
process.stdout.write(lines.join("\n"));
' "$intro"
}

crb_json_system_message() {
  node -e '
const fs = require("fs");
const message = fs.readFileSync(0, "utf8");
process.stdout.write(JSON.stringify({ systemMessage: message }));
'
}

crb_json_post_tool_context() {
  node -e '
const fs = require("fs");
const message = fs.readFileSync(0, "utf8");
process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: message
  }
}));
'
}

crb_dry_run_review() {
  local severity="${CRB_DRY_RUN_SEVERITY:-LGTM}"
  case "$severity" in
    LGTM|MINOR|MAJOR) ;;
    *) severity="LGTM" ;;
  esac

  node -e '
const severity = process.argv[1];
const lower = severity.toLowerCase();
process.stdout.write(JSON.stringify({
  severity,
  issues: severity === "LGTM" ? [] : [`Dry run ${lower} issue`],
  suggestions: severity === "LGTM" ? [] : [`Dry run ${lower} suggestion`]
}));
' "$severity"
}

crb_run_codex_review() {
  local schema_path="$1"
  if [[ "${CRB_DRY_RUN:-0}" == "1" ]]; then
    crb_dry_run_review
    return 0
  fi

  local timeout_seconds="${CRB_CODEX_TIMEOUT_SECONDS:-120}"
  if ! [[ "$timeout_seconds" =~ ^[0-9]+$ ]] || (( timeout_seconds < 1 || timeout_seconds > 120 )); then
    timeout_seconds="120"
  fi

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" codex exec --output-schema "$schema_path" -
  else
    codex exec --output-schema "$schema_path" -
  fi
}

crb_is_code_file() {
  local file_path="$1"
  case "${file_path##*.}" in
    c|cc|cpp|cs|css|go|h|hpp|html|java|js|jsx|kt|mjs|php|py|rb|rs|sh|sql|svelte|swift|ts|tsx|vue)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

crb_sanitize_session_id() {
  local session_id="$1"
  printf '%s' "${session_id:-unknown}" | tr -c 'A-Za-z0-9_.-' '_'
}

crb_normalize_path() {
  local path="$1"
  if [[ "$path" =~ ^[A-Za-z]:\\ ]] && command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$path"
  elif [[ "$path" =~ ^[A-Za-z]:\\ ]] && command -v wslpath >/dev/null 2>&1; then
    wslpath -u "$path"
  else
    printf '%s' "$path"
  fi
}
