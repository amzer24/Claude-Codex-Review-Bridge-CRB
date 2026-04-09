#!/usr/bin/env bash
set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STOP_HOOK="$ROOT/hooks/codex-review-stop.sh"
FILE_HOOK="$ROOT/hooks/codex-review-file.sh"
INSTALL_SCRIPT="$ROOT/hooks/install.sh"
TMP_BASE="${TMPDIR:-/tmp}/crb-tests-$$"
FAILURES=0

mkdir -p "$TMP_BASE"
trap 'rm -rf "$TMP_BASE"' EXIT

fail() {
  printf 'not ok - %s\n' "$1" >&2
  FAILURES=$((FAILURES + 1))
}

pass() {
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$message"
  else
    fail "$message (expected '$expected', got '$actual')"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$message"
  else
    fail "$message (missing '$needle' in '$haystack')"
  fi
}

assert_empty() {
  local value="$1"
  local message="$2"
  if [[ -z "$value" ]]; then
    pass "$message"
  else
    fail "$message (got '$value')"
  fi
}

make_repo() {
  local name="$1"
  local repo="$TMP_BASE/$name"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    git init -q
    git config user.email "crb@example.test"
    git config user.name "CRB Tests"
    git config core.autocrlf false
    printf 'console.log("original");\n' > app.js
    printf '# original\n' > README.md
    git add app.js README.md
    git commit -q -m "initial"
  )
  printf '%s\n' "$repo"
}

run_hook() {
  local hook="$1"
  local input="$2"
  local stdout_file="$TMP_BASE/stdout"
  local stderr_file="$TMP_BASE/stderr"
  local state_dir="${CRB_STATE_DIR:-$TMP_BASE/state}"
  mkdir -p "$state_dir"
  rm -f "$stdout_file" "$stderr_file"
  printf '%s' "$input" | CRB_STATE_DIR="$state_dir" "$hook" >"$stdout_file" 2>"$stderr_file"
  local status=$?
  HOOK_STATUS="$status"
  HOOK_STDOUT="$(cat "$stdout_file" 2>/dev/null || true)"
  HOOK_STDERR="$(cat "$stderr_file" 2>/dev/null || true)"
}

test_stop_lgtm_exits_silent() {
  local repo
  repo="$(make_repo stop-lgtm)"
  printf 'console.log("changed");\n' > "$repo/app.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=LGTM run_hook "$STOP_HOOK" "{\"session_id\":\"stop-lgtm\",\"cwd\":\"$repo\"}"

  assert_eq "0" "$HOOK_STATUS" "Stop LGTM exits 0"
  assert_empty "$HOOK_STDOUT" "Stop LGTM stdout is empty"
  assert_empty "$HOOK_STDERR" "Stop LGTM stderr is empty"
}

test_stop_minor_exits_2_with_stderr() {
  local repo
  repo="$(make_repo stop-minor)"
  printf 'console.log("minor");\n' > "$repo/app.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR run_hook "$STOP_HOOK" "{\"session_id\":\"stop-minor\",\"cwd\":\"$repo\"}"

  assert_eq "2" "$HOOK_STATUS" "Stop MINOR exits 2"
  assert_empty "$HOOK_STDOUT" "Stop MINOR stdout is empty"
  assert_contains "$HOOK_STDERR" "Codex review found minor issues" "Stop MINOR stderr contains feedback"
}

test_stop_major_system_message() {
  local repo
  repo="$(make_repo stop-major)"
  printf 'console.log("major");\n' > "$repo/app.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MAJOR run_hook "$STOP_HOOK" "{\"session_id\":\"stop-major\",\"cwd\":\"$repo\"}"

  assert_eq "0" "$HOOK_STATUS" "Stop MAJOR exits 0"
  assert_contains "$HOOK_STDOUT" '"systemMessage"' "Stop MAJOR stdout contains systemMessage"
  assert_contains "$HOOK_STDOUT" "major issues" "Stop MAJOR message mentions major issues"
  assert_empty "$HOOK_STDERR" "Stop MAJOR stderr is empty"
}

test_stop_loop_cap_exits_silent() {
  local repo
  repo="$(make_repo stop-loop-cap)"
  printf 'console.log("loop");\n' > "$repo/app.js"
  local state_dir="$TMP_BASE/state"
  mkdir -p "$state_dir"

  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR CRB_STATE_DIR="$state_dir" run_hook "$STOP_HOOK" "{\"session_id\":\"loop-cap\",\"cwd\":\"$repo\"}"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR CRB_STATE_DIR="$state_dir" run_hook "$STOP_HOOK" "{\"session_id\":\"loop-cap\",\"cwd\":\"$repo\"}"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR CRB_STATE_DIR="$state_dir" run_hook "$STOP_HOOK" "{\"session_id\":\"loop-cap\",\"cwd\":\"$repo\"}"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR CRB_STATE_DIR="$state_dir" run_hook "$STOP_HOOK" "{\"session_id\":\"loop-cap\",\"cwd\":\"$repo\"}"

  assert_eq "0" "$HOOK_STATUS" "Stop loop cap exits 0 after three rounds"
  assert_empty "$HOOK_STDOUT" "Stop loop cap stdout is empty"
  assert_empty "$HOOK_STDERR" "Stop loop cap stderr is empty"
}

test_stop_includes_staged_changes() {
  local repo
  repo="$(make_repo stop-staged)"
  printf 'console.log("staged");\n' > "$repo/app.js"
  (cd "$repo" && git add app.js)

  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR run_hook "$STOP_HOOK" "{\"session_id\":\"stop-staged\",\"cwd\":\"$repo\"}"

  assert_eq "2" "$HOOK_STATUS" "Stop reviews staged changes from git diff HEAD"
  assert_contains "$HOOK_STDERR" "minor issues" "Stop staged change gets reviewed"
}

test_file_untracked_is_skipped() {
  local repo
  repo="$(make_repo file-untracked)"
  printf 'console.log("new");\n' > "$repo/new.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MAJOR run_hook "$FILE_HOOK" "{\"session_id\":\"file-untracked\",\"cwd\":\"$repo\",\"tool_input\":{\"file_path\":\"$repo/new.js\"}}"

  assert_eq "0" "$HOOK_STATUS" "File hook skips untracked files with exit 0"
  assert_empty "$HOOK_STDOUT" "File untracked skip stdout is empty"
  assert_empty "$HOOK_STDERR" "File untracked skip stderr is empty"
}

test_file_non_code_is_skipped() {
  local repo
  repo="$(make_repo file-non-code)"
  printf '# changed\n' > "$repo/README.md"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MAJOR run_hook "$FILE_HOOK" "{\"session_id\":\"file-non-code\",\"cwd\":\"$repo\",\"tool_input\":{\"file_path\":\"$repo/README.md\"}}"

  assert_eq "0" "$HOOK_STATUS" "File hook skips non-code files with exit 0"
  assert_empty "$HOOK_STDOUT" "File non-code skip stdout is empty"
  assert_empty "$HOOK_STDERR" "File non-code skip stderr is empty"
}

test_file_major_additional_context() {
  local repo
  repo="$(make_repo file-major)"
  printf 'console.log("major");\n' > "$repo/app.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MAJOR run_hook "$FILE_HOOK" "{\"session_id\":\"file-major\",\"cwd\":\"$repo\",\"tool_input\":{\"file_path\":\"$repo/app.js\"}}"

  assert_eq "0" "$HOOK_STATUS" "File hook MAJOR exits 0"
  assert_contains "$HOOK_STDOUT" '"hookSpecificOutput"' "File MAJOR emits hookSpecificOutput"
  assert_contains "$HOOK_STDOUT" '"hookEventName":"PostToolUse"' "File MAJOR declares PostToolUse"
  assert_contains "$HOOK_STDOUT" '"additionalContext"' "File MAJOR emits additionalContext"
  assert_empty "$HOOK_STDERR" "File MAJOR stderr is empty"
}

test_file_minor_is_ignored() {
  local repo
  repo="$(make_repo file-minor)"
  printf 'console.log("minor");\n' > "$repo/app.js"
  CRB_DRY_RUN=1 CRB_DRY_RUN_SEVERITY=MINOR run_hook "$FILE_HOOK" "{\"session_id\":\"file-minor\",\"cwd\":\"$repo\",\"tool_input\":{\"file_path\":\"$repo/app.js\"}}"

  assert_eq "0" "$HOOK_STATUS" "File hook MINOR exits 0"
  assert_empty "$HOOK_STDOUT" "File MINOR stdout is empty"
  assert_empty "$HOOK_STDERR" "File MINOR stderr is empty"
}

test_schema_path_exists() {
  if [[ -f "$ROOT/hooks/review-schema.json" ]]; then
    pass "Schema exists at hooks/review-schema.json"
  else
    fail "Schema exists at hooks/review-schema.json"
  fi
}

test_install_requires_force() {
  local settings="$TMP_BASE/settings.json"
  printf '{}\n' > "$settings"
  CRB_SETTINGS_PATH="$settings" "$INSTALL_SCRIPT" >"$TMP_BASE/install.stdout" 2>"$TMP_BASE/install.stderr"
  local status=$?
  local stdout
  stdout="$(cat "$TMP_BASE/install.stdout")"

  assert_eq "1" "$status" "install.sh refuses to modify settings without --force"
  assert_contains "$stdout" "--force" "install.sh explains --force requirement"
}

test_install_force_patches_settings() {
  local settings="$TMP_BASE/settings-force.json"
  printf '{"permissions":{"allow":["Bash(existing)"]}}\n' > "$settings"
  CRB_SETTINGS_PATH="$settings" "$INSTALL_SCRIPT" --force >"$TMP_BASE/install-force.stdout" 2>"$TMP_BASE/install-force.stderr"
  local status=$?
  local content
  content="$(cat "$settings")"

  assert_eq "0" "$status" "install.sh --force exits 0"
  assert_contains "$content" '"Stop"' "install.sh --force adds Stop hook"
  assert_contains "$content" '"PostToolUse"' "install.sh --force adds PostToolUse hook"
  assert_contains "$content" 'codex-review-stop.sh' "install.sh --force adds Stop command"
  assert_contains "$content" 'codex-review-file.sh' "install.sh --force adds file command"
  assert_contains "$content" 'Bash(existing)' "install.sh --force preserves existing settings"
}

test_stop_lgtm_exits_silent
test_stop_minor_exits_2_with_stderr
test_stop_major_system_message
test_stop_loop_cap_exits_silent
test_stop_includes_staged_changes
test_file_untracked_is_skipped
test_file_non_code_is_skipped
test_file_major_additional_context
test_file_minor_is_ignored
test_schema_path_exists
test_install_requires_force
test_install_force_patches_settings

if [[ "$FAILURES" -ne 0 ]]; then
  printf '%s test assertion(s) failed\n' "$FAILURES" >&2
  exit 1
fi

printf 'all tests passed\n'
