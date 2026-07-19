#!/usr/bin/env bash
# Idempotent prerequisite checker and fixer for the repository.
# Detects missing dependencies across all ecosystems and installs them.
# Safe to run repeatedly — skips work when prerequisites are already met.
#
# Usage:
#   bash tools/bootstrap.sh [OPTIONS] [ROOT]
#
# Options:
#   --check-only   Report missing prerequisites without fixing them
#   --quiet        Suppress output when all prerequisites are met
#   --report-rows  Emit one TSV record per check (ROW<TAB>STATUS<TAB>NAME<TAB>DETAIL).
#                  Suppresses prose; consumed by /onboard Phase 5 sub-step rows.
#                  STATUS is one of: PASS | WARN | FAIL | SKIP.
#
# Arguments:
#   ROOT           Repository root to check (default: auto-detect from script location)
#
# Exit codes:
#   0  All prerequisites met (or fixed successfully)
#   1  Prerequisites missing and --check-only, or remediation failed
#
# Called by: tools/worktree/setup-worktree.sh (setup pipelines), manual, CI

# Omit -e: functions return non-zero to signal failures; callers check via || pattern.
set -uo pipefail

CHECK_ONLY=false
MEDIA_TOOLS_REQUIRED="${MEDIA_TOOLS_REQUIRED:-true}"
QUIET=false
REPORT_ROWS=false
ROOT=""

for arg in "$@"; do
  case "$arg" in
    --check-only) CHECK_ONLY=true ;;
    --quiet) QUIET=true ;;
    --report-rows) REPORT_ROWS=true ;;
    -*) ;; # Ignore unknown flags for forward-compatibility
    *) ROOT="$arg" ;;
  esac
done

ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# --- Fast-path: skip full prereq scan when no manifest has changed since last
# successful run. --check-only and --report-rows always do the full pass.
#
# State file: $XDG_CACHE_HOME (or %LOCALAPPDATA% on Windows)/medley-bootstrap/last-success-<root-hash>.ts
# Invalidators: package.json, pyproject.toml, package-lock.json, uv.lock newer
#               than the state file, OR bootstrap.sh itself newer than state.
# Atomic write: temp file + mv to survive concurrent sessions (last-write-wins).
if [[ -n "${LOCALAPPDATA:-}" ]]; then
  STATE_DIR="${LOCALAPPDATA//\\//}/medley-bootstrap"
else
  STATE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/medley-bootstrap"
fi
ROOT_HASH=$(printf '%s' "$ROOT" | cksum | cut -d' ' -f1)
STATE_FILE="$STATE_DIR/last-success-${ROOT_HASH}.ts"

if [[ "$CHECK_ONLY" != "true" && "$REPORT_ROWS" != "true" && -f "$STATE_FILE" ]]; then
  # bootstrap.sh itself newer than state → invalidate
  if [[ "${BASH_SOURCE[0]}" -nt "$STATE_FILE" ]]; then
    : # fall through to full scan
  else
    NEWER=$(find "$ROOT" \
      \( -name node_modules -o -name .git -o -name bin -o -name obj -o -name .venv \) -prune -o \
      \( -name 'package.json' -o -name 'pyproject.toml' -o -name 'package-lock.json' -o -name 'uv.lock' \) \
      -newer "$STATE_FILE" -print 2>/dev/null | head -n1)
    if [[ -z "$NEWER" ]]; then
      [[ "$QUIET" != "true" ]] && printf 'MCP prerequisites: cached OK\n'
      exit 0
    fi
  fi
fi

# Per-message-class line accumulators. Each entry is one already-rendered
# output line WITHOUT trailing newline. Emitted via `printf '%s\n'` so the
# final output shape matches the prior `printf '%b' "$STRING"` form byte-
# for-byte (bootstrap.test.sh asserts on exact-string substrings like
# "ffmpeg: not found on PATH (optional)" and "Playwright Chromium browser
# not installed" — drift in line shape breaks those gates).
ACTIONS=()
WARNINGS=()
FAILURES=()

# Emit a TSV row when --report-rows is set, otherwise no-op. Each check_*
# helper calls record_row exactly once per invocation. Status semantics:
#   PASS  — present and (where applicable) meets the version floor
#   WARN  — present but below floor (optional), missing but optional, or could not be probed (skipped)
#   FAIL  — missing and required, OR present-but-below-floor and required (fails the prose --check-only)
#   SKIP  — prerequisite for the check itself is missing (e.g. npm absent)
record_row() {
  [[ "$REPORT_ROWS" == "true" ]] || return 0
  printf 'ROW\t%s\t%s\t%s\n' "$1" "$2" "$3"
}

check_node_project() {
  local dir="$1" name="$2"

  if [[ ! -f "$dir/package.json" ]]; then
    record_row SKIP "$name" "no package.json at $dir"
    return 0
  fi

  if ! command -v npm >/dev/null 2>&1; then
    WARNINGS+=("  - ${name}: npm not installed (skipped)")
    record_row SKIP "$name" "npm not installed"
    return 0
  fi

  # Check node_modules — missing or stale (package.json updated after install).
  # Note: -nt compares mtime, so git checkout/rebase can trigger false positives.
  # Acceptable trade-off — npm install with a satisfied lockfile is fast (~2-3s).
  if [[ ! -d "$dir/node_modules" ]] || [[ "$dir/package.json" -nt "$dir/node_modules" ]]; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      WARNINGS+=("  - ${name}: node_modules missing or stale")
      record_row FAIL "$name" "node_modules missing or stale — run: cd ${dir} && npm install"
      return 1
    fi
    if (cd "$dir" && npm install --silent >/dev/null 2>&1); then
      ACTIONS+=("  - ${name}: installed npm dependencies")
    else
      FAILURES+=("  - ${name}: npm install failed — run: cd ${dir} && npm install")
      record_row FAIL "$name" "npm install failed — run: cd ${dir} && npm install"
      return 1
    fi
  fi

  # Check TypeScript build output — missing means needs build. Skip for --noEmit
  # build scripts: those typecheck only and emit no build/index.js, so the marker
  # would always read "missing" and trigger a perpetual rebuild / --check-only fail.
  local build_noemit=false
  if grep -Eq '"build"[[:space:]]*:[[:space:]]*"[^"]*--noEmit' "$dir/package.json" 2>/dev/null; then
    build_noemit=true
  fi
  if [[ -f "$dir/tsconfig.json" ]] && [[ "$build_noemit" == false ]] && [[ ! -f "$dir/build/index.js" ]]; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      WARNINGS+=("  - ${name}: build output missing")
      record_row FAIL "$name" "build output missing — run: cd ${dir} && npm run build"
      return 1
    fi
    if (cd "$dir" && npm run build >/dev/null 2>&1); then
      ACTIONS+=("  - ${name}: built TypeScript")
    else
      FAILURES+=("  - ${name}: build failed — run: cd ${dir} && npm run build")
      record_row FAIL "$name" "build failed — run: cd ${dir} && npm run build"
      return 1
    fi
  fi

  local detail="node_modules present"
  if [[ -f "$dir/tsconfig.json" ]]; then
    if [[ "$build_noemit" == true ]]; then
      detail="$detail + TS typecheck (noEmit)"
    else
      detail="$detail + TS build artifact"
    fi
  fi
  record_row PASS "$name" "$detail"
}

check_python_project() {
  local dir="$1" name="$2"

  if [[ ! -f "$dir/pyproject.toml" ]]; then
    record_row SKIP "$name" "no pyproject.toml at $dir"
    return 0
  fi

  if ! command -v uv >/dev/null 2>&1; then
    WARNINGS+=("  - ${name}: uv not installed (skipped)")
    record_row SKIP "$name" "uv not installed"
    return 0
  fi

  if [[ ! -d "$dir/.venv" ]] || [[ "$dir/pyproject.toml" -nt "$dir/.venv" ]]; then
    if [[ "$CHECK_ONLY" == "true" ]]; then
      WARNINGS+=("  - ${name}: .venv missing or stale")
      record_row FAIL "$name" ".venv missing or stale — run: cd ${dir} && uv sync"
      return 1
    fi
    if (cd "$dir" && uv sync --quiet 2>/dev/null); then
      ACTIONS+=("  - ${name}: synced Python venv")
    else
      FAILURES+=("  - ${name}: uv sync failed — run: cd ${dir} && uv sync")
      record_row FAIL "$name" "uv sync failed — run: cd ${dir} && uv sync"
      return 1
    fi
  fi

  record_row PASS "$name" ".venv present"
}

# Record a "binary missing on PATH" outcome consistently across check_binary_tool
# and check_binary_tool_with_floor. Returns 1 when required, 0 when optional, so
# callers can `|| HAS_FAILURE=true` directly.
record_missing_binary() {
  local name="$1" install_hint="$2" required="$3"
  if [[ "$required" == "true" ]]; then
    WARNINGS+=("  - ${name}: not found on PATH")
    WARNINGS+=("    Install: ${install_hint}")
    record_row FAIL "$name" "missing — install: ${install_hint}"
    return 1
  fi
  WARNINGS+=("  - ${name}: not found on PATH (optional)")
  WARNINGS+=("    Install: ${install_hint}")
  record_row WARN "$name" "missing optional tool — install: ${install_hint}"
  return 0
}

check_binary_tool() {
  local cmd="$1" name="$2" install_hint="$3"
  local required="${4:-true}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    record_missing_binary "$name" "$install_hint" "$required"
    return $?
  fi
  record_row PASS "$name" "$cmd on PATH"
}

# Detect whether Playwright's Chromium browser is installed for a project
# that depends on playwright. `npm install` does NOT auto-download browsers
# (postinstall is separate), so browsers are a distinct prerequisite from
# node_modules. Cache location follows Playwright's documented defaults
# unless PLAYWRIGHT_BROWSERS_PATH is set:
#   - =0 (hermetic)  → node_modules/playwright-core/.local-browsers
#   - =<abs-path>    → <abs-path>
#   - unset          → per-OS default (Windows LOCALAPPDATA, macOS Caches,
#                      Linux XDG_CACHE_HOME)
# The glob chromium-[0-9]* matches the real browser directory and isolates
# it from the sibling chromium_headless_shell-* install.
check_playwright_browsers() {
  local dir="$1" name="$2"

  if [[ ! -f "$dir/package.json" ]]; then
    record_row SKIP "$name" "no package.json at $dir"
    return 0
  fi
  if ! grep -q '"playwright"' "$dir/package.json" 2>/dev/null; then
    record_row SKIP "$name" "playwright not in package.json"
    return 0
  fi

  local cache_dir
  if [[ "${PLAYWRIGHT_BROWSERS_PATH:-}" == "0" ]]; then
    cache_dir="$dir/node_modules/playwright-core/.local-browsers"
  elif [[ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ]]; then
    cache_dir="$PLAYWRIGHT_BROWSERS_PATH"
  else
    case "$(uname -s 2>/dev/null || echo unknown)" in
      MINGW* | MSYS* | CYGWIN*)
        cache_dir="${LOCALAPPDATA:-$HOME/AppData/Local}/ms-playwright"
        ;;
      Darwin)
        cache_dir="$HOME/Library/Caches/ms-playwright"
        ;;
      *)
        cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright"
        ;;
    esac
  fi
  # On Git Bash, LOCALAPPDATA comes through as a Windows-style path with
  # backslashes, which breaks `compgen -G` (globs don't match across \).
  # Normalize to forward slashes via tr. On macOS/Linux this is a no-op.
  cache_dir=$(printf '%s' "$cache_dir" | tr '\\' '/')

  if [[ -d "$cache_dir" ]] && compgen -G "$cache_dir/chromium-[0-9]*" >/dev/null; then
    record_row PASS "$name" "Chromium installed under $cache_dir"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    WARNINGS+=("  - ${name}: Playwright Chromium browser not installed")
    WARNINGS+=("    Install: cd ${dir} && npx playwright install chromium")
    record_row FAIL "$name" "Chromium missing — run: cd ${dir} && npx playwright install chromium"
    return 1
  fi
  if ! command -v npx >/dev/null 2>&1; then
    FAILURES+=("  - ${name}: npx not on PATH — run: cd ${dir} && npx playwright install chromium")
    record_row FAIL "$name" "npx not on PATH — run: cd ${dir} && npx playwright install chromium"
    return 1
  fi
  if (cd "$dir" && npx playwright install chromium >/dev/null 2>&1); then
    ACTIONS+=("  - ${name}: installed Playwright Chromium browser")
    record_row PASS "$name" "Chromium installed (just now)"
  else
    FAILURES+=("  - ${name}: playwright install failed — run: cd ${dir} && npx playwright install chromium")
    record_row FAIL "$name" "playwright install failed — run: cd ${dir} && npx playwright install chromium"
    return 1
  fi
}

# Extension of check_binary_tool that additionally enforces a major.minor
# version floor. Returns 1 when missing or below the floor so the caller's
# `|| HAS_FAILURE=true` pattern propagates consistently. Version is captured
# via `$cmd --version | head -n1` by default; override with $version_cmd for
# tools that emit non-standard banners.
#
# Emits one record_row per invocation (does NOT delegate to check_binary_tool
# to avoid double-emitting when --report-rows is set).
check_binary_tool_with_floor() {
  local cmd="$1" name="$2" floor="$3" install_hint="$4" required="${5:-true}" version_cmd="${6:-}"

  if ! command -v "$cmd" >/dev/null 2>&1; then
    record_missing_binary "$name" "$install_hint" "$required"
    return $?
  fi

  local raw version have_maj have_min want_maj want_min
  if [[ -n "$version_cmd" ]]; then
    raw=$(eval "$version_cmd" 2>/dev/null | tr -d '\r' | head -n1)
  else
    raw=$("$cmd" --version 2>/dev/null | tr -d '\r' | head -n1)
  fi
  # Extract first dotted version triple/pair from the banner.
  version=$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
  if [[ -z "$version" ]]; then
    record_row PASS "$name" "$cmd on PATH (version unparseable)"
    return 0 # Presence satisfies the check; version parse is best-effort.
  fi
  have_maj="${version%%.*}"
  have_min="${version#*.}"
  have_min="${have_min%%.*}"
  want_maj="${floor%%.*}"
  want_min="${floor#*.}"
  want_min="${want_min%%.*}"
  if ((10#$have_maj > 10#$want_maj)) \
    || { ((10#$have_maj == 10#$want_maj)) && ((10#$have_min >= 10#$want_min)); }; then
    record_row PASS "$name" "$version meets >= $floor"
    return 0
  fi
  if [[ "$required" == "true" ]]; then
    WARNINGS+=("  - ${name}: ${version} is below ${floor} floor")
    WARNINGS+=("    Upgrade: ${install_hint}")
    # Required below-floor is a real prerequisite failure (return 1 below sets
    # HAS_FAILURE). Emit FAIL — not WARN — so the --report-rows status encodes
    # the severity; a consumer that degrades WARN to a pass (e.g. /onboard
    # Phase 5) would otherwise mark a stale required tool as satisfied.
    record_row FAIL "$name" "$version below $floor (required) — upgrade: ${install_hint}"
    return 1
  fi
  WARNINGS+=("  - ${name}: ${version} is below ${floor} floor (optional)")
  WARNINGS+=("    Upgrade: ${install_hint}")
  record_row WARN "$name" "$version below $floor (optional) — upgrade: ${install_hint}"
  return 0
}

# Detect whether a PowerShell module is importable. When missing, installs into
# CurrentUser scope via Install-PSResource (PSResourceGet, faster) with a
# fallback to legacy Install-Module. Skips silently when pwsh is absent — most
# lint hooks degrade gracefully without it.
check_pwsh_module() {
  local module="$1" install_hint="$2"

  if ! command -v pwsh >/dev/null 2>&1; then
    # No PowerShell — module check is moot. Other checks already warn on pwsh.
    record_row SKIP "$module" "pwsh not on PATH"
    return 0
  fi

  # Validate $module against an allowlist before splicing into PS command
  # strings. PowerShell single-quoted strings escape ' as '' (doubled), not
  # \', so a module name containing a single quote would break out of the
  # quoted context. Restricting to PSGallery-style identifiers makes that
  # impossible regardless of how callers source the value.
  if [[ ! "$module" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "check_pwsh_module: invalid module name '$module' (must match [A-Za-z0-9._-]+)" >&2
    record_row FAIL "$module" "invalid module name"
    return 1
  fi

  # Cache hit (24h TTL keyed on $PSModulePath hash) avoids the ~300-1000ms
  # pwsh cold-start on every session. Cache file lives next to bootstrap state.
  local ps_path_hash cache_file cache_age now_epoch
  ps_path_hash=$(printf '%s' "${PSModulePath:-}" | sha256sum 2>/dev/null | cut -c1-16)
  [[ -z "$ps_path_hash" ]] && ps_path_hash="nohash"
  cache_file="$STATE_DIR/pwsh-module-${module}.${ps_path_hash}"
  if [[ -f "$cache_file" ]]; then
    # ${EPOCHSECONDS:-…} falls back to date when the bash 5.0+ builtin is absent
    # (e.g. macOS bash 3.2). The prior ${EPOCHSECONDS:+…} || date form expanded to
    # an empty command that returned 0, so || short-circuited and cache_age went
    # negative — silently disabling the 24h cache on bash 3.2.
    now_epoch=${EPOCHSECONDS:-$(date +%s)}
    cache_age=$((now_epoch - $(stat -c %Y "$cache_file" 2>/dev/null || stat -f %m "$cache_file" 2>/dev/null || echo 0)))
    if [[ "$cache_age" -ge 0 && "$cache_age" -lt 86400 ]]; then
      record_row PASS "$module" "PowerShell module installed (cached, age=${cache_age}s)"
      return 0
    fi
  fi

  if pwsh -NoProfile -NonInteractive -Command \
    "if (Get-Module -ListAvailable -Name '$module') { exit 0 } else { exit 1 }" \
    >/dev/null 2>&1; then
    mkdir -p "$STATE_DIR" 2>/dev/null && : >"$cache_file" 2>/dev/null
    record_row PASS "$module" "PowerShell module installed"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    WARNINGS+=("  - ${module}: PowerShell module not installed")
    WARNINGS+=("    Install: ${install_hint}")
    record_row FAIL "$module" "PowerShell module not installed — install: ${install_hint}"
    return 1
  fi

  if pwsh -NoProfile -NonInteractive -Command \
    "Install-PSResource -Name '$module' -Scope CurrentUser -TrustRepository -Reinstall:\$false -ErrorAction Stop" \
    >/dev/null 2>&1; then
    ACTIONS+=("  - ${module}: installed PowerShell module via Install-PSResource")
    record_row PASS "$module" "installed via Install-PSResource"
    return 0
  fi

  if pwsh -NoProfile -NonInteractive -Command \
    "Install-Module -Name '$module' -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop" \
    >/dev/null 2>&1; then
    ACTIONS+=("  - ${module}: installed PowerShell module via Install-Module")
    record_row PASS "$module" "installed via Install-Module"
    return 0
  fi

  FAILURES+=("  - ${module}: install failed — run manually: ${install_hint}")
  record_row FAIL "$module" "install failed — run manually: ${install_hint}"
  return 1
}

HAS_FAILURE=false

check_binary_tool "actionlint" "actionlint" \
  "winget install rhysd.actionlint (Windows) | brew install actionlint (macOS) | download from github.com/rhysd/actionlint/releases (Linux)" \
  || HAS_FAILURE=true
check_binary_tool "check-jsonschema" "check-jsonschema" \
  "pip install check-jsonschema (all platforms) | brew install check-jsonschema (macOS)" \
  || HAS_FAILURE=true

# jq is a hard dependency of the Claude Code hook layer and the lefthook
# scripts — both parse stdin/tool JSON via jq. jq-absent does not fail loudly;
# the hooks silently degrade. branch-protection.sh's `hook::jq_field ... || exit 0`
# in particular fails OPEN, allowing source-code writes on main. Not bundled by
# Git for Windows or the base OS, so it is a realistic gap on a fresh clone.
check_binary_tool "jq" "jq" \
  "winget install jqlang.jq (Windows) | brew install jq (macOS) | sudo apt install jq (Linux)" \
  || HAS_FAILURE=true

# gh powers the work-item-tracker seam's GitHub adapter (native sub-issue/
# dependency flags) plus the bot-identity wrapper and PR/issue skills. Presence
# is the bootstrap contract; the >= 2.94 version floor is enforced at point of
# use by the seam dispatcher (work-item-tracker.sh check_gh_version, exit 3).
check_binary_tool "gh" "GitHub CLI" \
  "winget install GitHub.cli (Windows) | brew install gh (macOS) | see cli.github.com (Linux)" \
  || HAS_FAILURE=true
# rg: optional shell backend for tools/repo-grep.sh --engine rg; Cursor bundles rg.
# Repo .ignore speeds shell rg only — see docs/conventions/search-hygiene.md.
if command -v rg >/dev/null 2>&1; then
  rg_version="$(rg --version 2>/dev/null | head -n1 || true)"
  record_row PASS "ripgrep" "${rg_version:-rg on PATH} — scoped search: docs/conventions/search-hygiene.md"
else
  record_row WARN "ripgrep" "not on PATH — use tools/repo-grep.sh (git engine) or Cursor Grep; see docs/conventions/search-hygiene.md"
fi
check_binary_tool_with_floor "ffmpeg" "ffmpeg" "7.1" \
  "winget install Gyan.FFmpeg (Windows) | brew install ffmpeg (macOS) | sudo apt install ffmpeg (Linux)" \
  "$MEDIA_TOOLS_REQUIRED" \
  || HAS_FAILURE=true
check_binary_tool_with_floor "yt-dlp" "yt-dlp" "2026.7" \
  "winget install yt-dlp.yt-dlp (Windows) | brew install yt-dlp (macOS) | pip install -U yt-dlp or distro package (Linux)" \
  "false" \
  || HAS_FAILURE=true
check_binary_tool "grok" "Grok Build CLI" \
  "curl -fsSL https://x.ai/cli/install.sh | bash — then grok login; optional for ai-briefing Wave 0 + agent-loop grok-default. See docs/grok-build/README.md" \
  "false" \
  || true
check_binary_tool "magick" "ImageMagick 7" \
  "winget install ImageMagick.ImageMagick (Windows) | brew install imagemagick (macOS) | sudo apt install imagemagick (Linux)" \
  "$MEDIA_TOOLS_REQUIRED" \
  || HAS_FAILURE=true

# uv is a soft-warn: report when stale but do not fail bootstrap. A stale
# uv still installs older Python versions correctly, just without 3.14.x
# support. Hard-fail would block fresh clones on machines with a usable
# but outdated uv. We pass the version-floor check_binary_tool_with_floor
# and intentionally drop its return code so HAS_FAILURE is not set.
check_binary_tool_with_floor "uv" "uv" "0.10" \
  "uv self update (or winget upgrade astral-sh.uv / brew upgrade uv)" \
  || true

# PSScriptAnalyzer powers the .lefthook/pre-commit/psscriptanalyzer.sh hook
# locally; without it the hook silently no-ops and only CI catches violations.
# Pin floor at 1.25.0 — earlier 1.24.x ships analyzer rules that NRE under
# pwsh 7.4.14+ on the per-file Invoke-ScriptAnalyzer loop. See
# .claude/rules/ci/conventions.md "PSScriptAnalyzer Linux NRE flake".
check_pwsh_module "PSScriptAnalyzer" \
  "pwsh -NoProfile -Command 'Install-PSResource -Name PSScriptAnalyzer -Version \"[1.25.0, ]\" -Scope CurrentUser -TrustRepository'" \
  || HAS_FAILURE=true

# Cross-cutting quality tooling — lefthook pre-commit + /lint cross-cutting + /verify-changes.
# typos: spell-checker; auto-discovers _typos.toml from repo root.
check_binary_tool "typos" "typos" \
  "winget install Crate-CI.Typos (Windows) | brew install typos-cli (macOS) | cargo install typos-cli (Linux)" \
  || HAS_FAILURE=true

# gitleaks: staged-secret scan; auto-discovers .gitleaks.toml from repo root.
check_binary_tool "gitleaks" "gitleaks" \
  "winget install Gitleaks.Gitleaks (Windows) | brew install gitleaks (macOS) | download from github.com/gitleaks/gitleaks/releases (Linux)" \
  || HAS_FAILURE=true

# lychee: offline markdown link + fragment reference-integrity gate
# (markdown-debt lane B; .lefthook/pre-commit/markdown-link-check.sh). RECOMMENDED,
# not hard-required: the local lane self-skips when lychee is absent (OD-3) and the
# CI reference-integrity job (markdown-ci.yml, pinned 0.24.2) is the authoritative
# enforcer — so warn on absence, do not fail bootstrap. The install hint mirrors the
# lane's own self-skip message so /onboard fix lands the same package.
check_binary_tool "lychee" "lychee" \
  "winget install lycheeverse.lychee (Windows) | brew install lychee (macOS) | cargo install lychee or download from github.com/lycheeverse/lychee/releases (Linux)" \
  "false"

# lefthook: git-hook driver. Binary on PATH is necessary but not sufficient —
# git hooks are only active after `lefthook install --force` writes shims into
# .git/hooks/. Verify-then-install: skip when .git/hooks/pre-commit already
# exists. Worktrees share the main repo's .git/hooks via core.hooksPath, so
# resolving via `git rev-parse --git-common-dir` reaches the right directory
# from any session start point.
check_git_filemode() {
  local name="git-core-filemode"

  # Windows-only check. On Linux/macOS the filesystem preserves exec bits
  # natively; git's default core.filemode=true is correct and `chmod +x`
  # marks files executable in the index. Forcing core.filemode=false on
  # those platforms would disable that tracking — exactly the class of
  # mistake this repo's exec-bit enforcement is designed to catch.
  # MSYS2 / Git Bash / Cygwin shells expose Linux-style filesystem perms
  # but the underlying NTFS layer does not preserve them, so on Windows
  # core.filemode=false is required.
  case "$(uname -s 2>/dev/null)" in
    MINGW* | MSYS* | CYGWIN*) ;;
    *)
      record_row PASS "$name" "n/a — Linux/macOS preserves exec bits via filesystem"
      return 0
      ;;
  esac

  local current
  current=$(cd "$ROOT" 2>/dev/null && git config --local --get core.filemode 2>/dev/null | tr -d '\r')

  if [[ "$current" == "false" ]]; then
    record_row PASS "$name" "core.filemode=false (prevents Windows-native git from reverting exec bit on git add)"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    WARNINGS+=("  - ${name}: core.filemode not set to false (run: git config --local core.filemode false)")
    record_row WARN "$name" "core.filemode=${current:-<unset>} — run: cd ${ROOT} && git config --local core.filemode false"
    return 0
  fi

  if (cd "$ROOT" && git config --local core.filemode false >/dev/null 2>&1); then
    ACTIONS+=("  - ${name}: set core.filemode=false (was ${current:-<unset>})")
    record_row PASS "$name" "set core.filemode=false (was ${current:-<unset>})"
    return 0
  fi

  FAILURES+=("  - ${name}: set failed — run: cd ${ROOT} && git config --local core.filemode false")
  record_row FAIL "$name" "set failed — run: cd ${ROOT} && git config --local core.filemode false"
  return 1
}
check_git_filemode || HAS_FAILURE=true

check_lefthook_install() {
  local name="lefthook"
  local install_hint
  install_hint="winget install evilmartians.lefthook (Windows) | brew install lefthook (macOS) | go install github.com/evilmartians/lefthook@latest (Linux)"

  if ! command -v lefthook >/dev/null 2>&1; then
    record_missing_binary "$name" "$install_hint" "true"
    return $?
  fi

  local hooks_dir
  hooks_dir=$(cd "$ROOT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null | tr -d '\r')
  if [[ -z "$hooks_dir" ]]; then
    WARNINGS+=("  - ${name}: could not resolve .git common dir (not a git repo?)")
    record_row WARN "$name" "could not resolve .git common dir"
    return 0
  fi
  case "$hooks_dir" in
    /* | ?:*) ;;
    *) hooks_dir="$ROOT/$hooks_dir" ;;
  esac

  if [[ -f "$hooks_dir/hooks/pre-commit" ]]; then
    record_row PASS "$name" "git hooks installed at $hooks_dir/hooks/"
    return 0
  fi

  if [[ "$CHECK_ONLY" == "true" ]]; then
    WARNINGS+=("  - ${name}: git hooks not installed — run: lefthook install --force")
    record_row FAIL "$name" "git hooks missing — run: cd ${ROOT} && lefthook install --force"
    return 1
  fi

  if (cd "$ROOT" && lefthook install --force >/dev/null 2>&1); then
    ACTIONS+=("  - ${name}: installed git hooks")
    record_row PASS "$name" "installed git hooks (just now)"
    return 0
  fi

  FAILURES+=("  - ${name}: install failed — run: cd ${ROOT} && lefthook install --force")
  record_row FAIL "$name" "install failed — run: cd ${ROOT} && lefthook install --force"
  return 1
}
check_lefthook_install || HAS_FAILURE=true

# editorconfig-checker: winget on Windows installs the binary as
# `ec-windows-amd64.exe` (no `ec` shim ships in the package). Detect any
# of the platform-suffixed names — the lefthook + /lint + /verify-changes scripts
# all handle whichever binary is present.
ec_binary=""
# editorconfig-checker is the go-install binary name; ec / ec-<platform>-amd64
# are the brew / winget binary names. Probe all.
for candidate in ec editorconfig-checker ec-windows-amd64 ec-linux-amd64 ec-darwin-amd64 ec-darwin-arm64; do
  if command -v "$candidate" >/dev/null 2>&1; then
    ec_binary="$candidate"
    break
  fi
done
if [[ -n "$ec_binary" ]]; then
  record_row PASS "editorconfig-checker" "$ec_binary on PATH"
else
  WARNINGS+=("  - editorconfig-checker: not found on PATH")
  WARNINGS+=("    Install: winget install EditorConfig-Checker.EditorConfig-Checker (Windows) | brew install editorconfig-checker (macOS) | go install github.com/editorconfig-checker/editorconfig-checker/v3/cmd/editorconfig-checker@latest (Linux)")
  record_row FAIL "editorconfig-checker" "missing — install: winget / brew / go install"
  HAS_FAILURE=true
fi

# MCP servers — auto-discover Node and Python projects under mcp-servers/.
# Convention: mcp-servers/{server-name}/{runtime}/ per AGENTS.md.
if [[ -d "$ROOT/mcp-servers" ]]; then
  while IFS= read -r pkg; do
    local_dir=$(dirname "$pkg")
    server_name=$(basename "$(dirname "$local_dir")")
    runtime=$(basename "$local_dir")
    check_node_project "$local_dir" "${server_name}-${runtime}-mcp" || HAS_FAILURE=true
  done < <(find "$ROOT/mcp-servers" -maxdepth 3 -name 'package.json' \
    -not -path '*/node_modules/*' 2>/dev/null)

  while IFS= read -r pyproj; do
    local_dir=$(dirname "$pyproj")
    server_name=$(basename "$(dirname "$local_dir")")
    runtime=$(basename "$local_dir")
    check_python_project "$local_dir" "${server_name}-${runtime}-mcp" || HAS_FAILURE=true
  done < <(find "$ROOT/mcp-servers" -maxdepth 3 -name 'pyproject.toml' \
    -not -path '*/.venv/*' 2>/dev/null)
fi

# Tooling helpers (Node + Python ecosystem dependencies for repo scripts).
# Shared Node libraries consumed by skill extraction pipelines via file: deps.
# Each needs its OWN node_modules — npm's file: linking does not install a linked
# package's transitive deps into the consumer (e.g. video-digestion's imghash),
# so a consumer-only install leaves the linked package unresolvable at runtime.
check_node_project "$ROOT/tools/shared/repo-analysis" "shared-repo-analysis" || HAS_FAILURE=true
check_node_project "$ROOT/tools/shared/video-digestion" "shared-video-digestion" || HAS_FAILURE=true
check_node_project "$ROOT/.claude/skills/youtube/extraction" "youtube-extraction" || HAS_FAILURE=true
check_node_project "$ROOT/.claude/skills/course-digest/extraction" "course-extraction" || HAS_FAILURE=true
check_playwright_browsers "$ROOT/.claude/skills/course-digest/extraction" "course-extraction-playwright" || HAS_FAILURE=true
check_python_project "$ROOT/.claude/skills" "skills-tests" || HAS_FAILURE=true
# markdown-coupling venv carries datasketch — load-bearing for the M2 near-dup pre-commit
# advisory lane (without it the lane silently SKIPs). uv sync --frozen installs it from uv.lock.
check_python_project "$ROOT/tools/markdown-coupling" "markdown-coupling" || HAS_FAILURE=true

if [[ "$REPORT_ROWS" == "true" ]]; then
  : # rows already emitted inline; suppress the prose summary
elif ((${#ACTIONS[@]} > 0)) || ((${#WARNINGS[@]} > 0)) || ((${#FAILURES[@]} > 0)); then
  printf 'MCP prerequisites:\n'
  ((${#ACTIONS[@]} > 0)) && printf '%s\n' "${ACTIONS[@]}"
  if ((${#WARNINGS[@]} > 0)); then
    printf 'Needs attention:\n'
    printf '%s\n' "${WARNINGS[@]}"
  fi
  if ((${#FAILURES[@]} > 0)); then
    printf 'Failed:\n'
    printf '%s\n' "${FAILURES[@]}"
  fi
elif [[ "$QUIET" != "true" ]]; then
  printf 'MCP prerequisites: all OK\n'
fi

if [[ "$HAS_FAILURE" == "true" ]]; then
  exit 1
fi

# Persist successful-run timestamp for fast-path on subsequent invocations.
# Skip when --check-only or --report-rows (those are read-only callers).
# Atomic temp+rename so concurrent sessions never observe a partial write.
if [[ "$CHECK_ONLY" != "true" && "$REPORT_ROWS" != "true" ]]; then
  mkdir -p "$STATE_DIR" 2>/dev/null && {
    printf '%s\n' "${EPOCHSECONDS:-$(date +%s)}" >"$STATE_FILE.tmp.$$" 2>/dev/null \
      && mv -f "$STATE_FILE.tmp.$$" "$STATE_FILE" 2>/dev/null
  } || true
fi

exit 0
