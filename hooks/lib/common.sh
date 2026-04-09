#!/usr/bin/env bash

CRB_TOGGLE_FILE="${CRB_TOGGLE_FILE:-$HOME/.crb-enabled}"
CRB_MAX_ROUNDS="${CRB_MAX_ROUNDS:-3}"

crb_is_enabled() {
  if [[ -f "$CRB_TOGGLE_FILE" ]]; then
    local val
    val="$(cat "$CRB_TOGGLE_FILE" 2>/dev/null | tr -d '[:space:]')"
    [[ "$val" == "1" || "$val" == "true" ]]
  else
    # Default: disabled (no toggle file = off)
    # User must explicitly opt in with: echo 1 > ~/.crb-enabled
    return 1
  fi
}

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
let data;
try { data = input.trim() ? JSON.parse(input) : {}; } catch { data = {}; }
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

crb_format_stop_feedback() {
  local severity="$1"
  local round="$2"
  local max_rounds="$3"
  node -e '
const fs = require("fs");
const severity = process.argv[1];
const round = process.argv[2];
const maxRounds = process.argv[3];
const raw = fs.readFileSync(0, "utf8");
let data;
try { data = JSON.parse(raw); } catch { data = {}; }
const header = `[CRB] Codex Review - Round ${round}/${maxRounds} - ${severity}`;
const lines = [header, "-".repeat(header.length)];
if (Array.isArray(data.issues) && data.issues.length > 0) {
  lines.push("", "Issues:");
  for (const issue of data.issues) lines.push(`  * ${issue}`);
}
if (Array.isArray(data.suggestions) && data.suggestions.length > 0) {
  lines.push("", "Suggestions:");
  for (const suggestion of data.suggestions) lines.push(`  * ${suggestion}`);
}
if (severity === "MINOR") {
  lines.push("", "[CRB] Claude is addressing these and will re-submit for review.");
} else if (severity === "MAJOR") {
  lines.push("", "[CRB] Major issues found. Review paused for user attention.");
}
process.stdout.write(lines.join("\n"));
' "$severity" "$round" "$max_rounds"
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

  # Model selection: env vars override, then files, then defaults
  local model="${CRB_MODEL:-}"
  if [[ -z "$model" && -f "$HOME/.crb-model" ]]; then
    model="$(cat "$HOME/.crb-model" 2>/dev/null | tr -d '[:space:]')"
  fi
  local model_args=""
  if [[ -n "$model" ]]; then
    model_args="-m $model"
  fi

  local reasoning="${CRB_REASONING:-}"
  if [[ -z "$reasoning" && -f "$HOME/.crb-reasoning" ]]; then
    reasoning="$(cat "$HOME/.crb-reasoning" 2>/dev/null | tr -d '[:space:]')"
  fi
  reasoning="${reasoning:-medium}"
  local config_args=""
  case "$reasoning" in
    none|minimal|low|medium|high|xhigh) ;;
    *) reasoning="medium" ;;
  esac
  config_args="-c model_reasoning_effort=$reasoning -c model_verbosity=low"

  if command -v timeout >/dev/null 2>&1; then
    timeout "${timeout_seconds}s" codex exec --output-schema "$schema_path" $model_args $config_args -
  else
    codex exec --output-schema "$schema_path" $model_args $config_args -
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

crb_detect_project_context() {
  # Detect languages, frameworks, and architecture from the repo
  node -e '
const fs = require("fs");
const path = require("path");

const cwd = process.cwd();
const context = { languages: [], frameworks: [], patterns: [] };

// Detect by file extensions in git-tracked files
try {
  const { execSync } = require("child_process");
  const files = execSync("git ls-files", { encoding: "utf8", timeout: 5000 }).trim().split("\n");
  const extCounts = {};
  for (const f of files) {
    const ext = path.extname(f).slice(1).toLowerCase();
    if (ext) extCounts[ext] = (extCounts[ext] || 0) + 1;
  }
  const extMap = {
    ts: "TypeScript", tsx: "TypeScript/React", js: "JavaScript", jsx: "JavaScript/React",
    py: "Python", go: "Go", rs: "Rust", rb: "Ruby", java: "Java", kt: "Kotlin",
    cs: "C#", cpp: "C++", c: "C", swift: "Swift", php: "PHP",
    svelte: "Svelte", vue: "Vue", sh: "Shell/Bash", sql: "SQL"
  };
  const sorted = Object.entries(extCounts).sort((a, b) => b[1] - a[1]);
  for (const [ext] of sorted.slice(0, 5)) {
    if (extMap[ext]) context.languages.push(extMap[ext]);
  }
} catch {}

// Detect frameworks from config files
const markers = {
  "package.json": () => {
    try {
      const pkg = JSON.parse(fs.readFileSync("package.json", "utf8"));
      const deps = { ...pkg.dependencies, ...pkg.devDependencies };
      if (deps.next) context.frameworks.push("Next.js");
      if (deps.react) context.frameworks.push("React");
      if (deps.express) context.frameworks.push("Express");
      if (deps.fastify) context.frameworks.push("Fastify");
      if (deps.ai) context.frameworks.push("Vercel AI SDK");
      if (deps.prisma || deps["@prisma/client"]) context.frameworks.push("Prisma");
      if (deps.tailwindcss) context.frameworks.push("Tailwind CSS");
      if (deps.vue) context.frameworks.push("Vue");
      if (deps.svelte) context.frameworks.push("Svelte");
      if (deps.hono) context.frameworks.push("Hono");
    } catch {}
  },
  "requirements.txt": () => {
    try {
      const r = fs.readFileSync("requirements.txt", "utf8");
      if (/django/i.test(r)) context.frameworks.push("Django");
      if (/flask/i.test(r)) context.frameworks.push("Flask");
      if (/fastapi/i.test(r)) context.frameworks.push("FastAPI");
      if (/torch|tensorflow|keras/i.test(r)) context.frameworks.push("ML/AI");
    } catch {}
  },
  "go.mod": () => context.frameworks.push("Go modules"),
  "Cargo.toml": () => context.frameworks.push("Cargo/Rust"),
  "turbo.json": () => context.patterns.push("monorepo (Turborepo)"),
  "docker-compose.yml": () => context.patterns.push("Docker"),
  "Dockerfile": () => context.patterns.push("Docker"),
  ".github/workflows": () => context.patterns.push("GitHub Actions CI")
};

for (const [file, detect] of Object.entries(markers)) {
  try {
    if (fs.existsSync(file)) detect();
  } catch {}
}

// Detect patterns from directory structure
try {
  const dirs = fs.readdirSync(".").filter(d => fs.statSync(d).isDirectory());
  if (dirs.includes("src") && dirs.includes("tests")) context.patterns.push("src/tests layout");
  if (dirs.includes("app")) context.patterns.push("app directory routing");
  if (dirs.includes("api")) context.patterns.push("API layer");
  if (dirs.includes("hooks")) context.patterns.push("hooks/plugins");
} catch {}

// Build summary
const parts = [];
if (context.languages.length) parts.push("Languages: " + [...new Set(context.languages)].join(", "));
if (context.frameworks.length) parts.push("Frameworks: " + [...new Set(context.frameworks)].join(", "));
if (context.patterns.length) parts.push("Architecture: " + [...new Set(context.patterns)].join(", "));
process.stdout.write(parts.join(". ") || "general-purpose codebase");
'
}

crb_build_review_prompt() {
  local review_type="$1"  # "diff" or "file"
  local content="$2"
  local file_path="${3:-}"
  local project_ctx
  project_ctx="$(crb_detect_project_context 2>/dev/null || printf 'general-purpose codebase')"
  local safe_content
  safe_content="$(printf '%s' "$content" | crb_escape_fences)"

  local custom=""
  if [[ -f "${CRB_PROMPT_FILE:-}" ]]; then
    custom="$(cat "$CRB_PROMPT_FILE" 2>/dev/null || true)"
  fi

  if [[ "$review_type" == "diff" ]]; then
    cat <<EOF
Expert code reviewer. Stack: $project_ctx${custom:+
$custom}
Review this diff for bugs, security issues, missing error handling, architecture problems. No style nits. JSON output only.

\`\`\`diff
$safe_content
\`\`\`
EOF
  else
    cat <<EOF
Expert code reviewer. Stack: $project_ctx${custom:+
$custom}
Review $file_path for major issues only: bugs, security, error handling, architecture. LGTM/MINOR if no immediate action needed. JSON output only.

\`\`\`
$safe_content
\`\`\`
EOF
  fi
}

crb_escape_fences() {
  # Replace triple backticks with safe alternative to prevent fence breaking
  node -e '
const fs = require("fs");
const input = fs.readFileSync(0, "utf8");
process.stdout.write(input.replace(/`{3,}/g, "\\x60\\x60\\x60"));
'
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
