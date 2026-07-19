#!/usr/bin/env bash
# Cloud setup script for Medley polyglot monorepo.
# Runs as root on Ubuntu 24.04 before cloud agent sessions.
#
# Consumers (dual path — keep header accurate when editing):
#   - Cursor Cloud: `.cursor/environment.json` `install` auto-runs this script from repo root.
#   - Claude Code Cloud: paste into the Setup script field at https://claude.ai/code (UI-stored;
#     not loaded from the tracked file on Claude's side).
#
# Design goals:
#   1. Install every tool required by lefthook.yml pre-commit (shellcheck, shfmt,
#      markdownlint-cli2, actionlint, check-jsonschema, pwsh for PSScriptAnalyzer).
#   2. Install every tool expected by .claude/hooks/*.sh formatter guards.
#   3. Keep .NET install even though `dotnet restore` was historically blocked
#      by cloud-proxy JWT format — SDK on PATH is needed for analyzer tooling
#      regardless. Empirical retest 2026-04-24: `dotnet restore` succeeds end-
#      to-end; treat as provisional until a second independent retest confirms.
#   4. Install fnm + uv python --default + bubblewrap so `/onboard` Phase 1 goes
#      green on cloud sessions. Skip tools that cannot work here at all —
#      ffmpeg 7.1+ / ImageMagick 7 are only needed by the course-digest skill.
#
# Exit-code policy:
#   `|| true` / function-level `|| echo WARN` on every non-critical command so
#   one transient failure does not abort the whole script. A failed setup
#   script prevents the session from starting at all.
#
# Testing:
#   Set CLOUD_SETUP_SKIP_MAIN=1 before sourcing to expose helper functions
#   without side effects (used by tools/cloud-setup/setup.test.sh).

set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# retry_fetch — resilient download helper.
# The cloud proxy intermittently returns error bodies with HTTP 200 from
# some domains (dot.net, packages.microsoft.com, dl.cloudsmith.io) — the
# "DNS cache overflow" issue documented in .claude/rules/cloud-conventions.md.
# Plain `curl -sSL ... || true` silently saves a garbage response over the
# target file, and downstream `chmod +x` / `dpkg -i` / `bash` steps then
# fail noisily. This helper uses `-f` (fail on HTTP error) + curl's own
# retry logic + a final `[[ -s $out ]]` size check + outer retry loop.
#
# Usage: retry_fetch <url> <output-path> [max_attempts=3]
# Returns 0 on success (non-empty file downloaded), 1 on persistent failure.
# ---------------------------------------------------------------------------
retry_fetch() {
  local url="$1" out="$2" max="${3:-3}" i
  for ((i = 1; i <= max; i++)); do
    if curl -fsSL --retry 2 --retry-delay 3 --retry-connrefused \
      "$url" -o "$out" && [[ -s "$out" ]]; then
      return 0
    fi
    echo "retry_fetch: attempt $i/$max failed for $url" >&2
    sleep $((i * 2))
  done
  echo "retry_fetch: giving up on $url after $max attempts" >&2
  rm -f "$out" 2>/dev/null || true
  return 1
}

# ---------------------------------------------------------------------------
# Base apt packages + prerequisite tools for the other installers below.
#   - openssh-client: `ssh` binary; Phase -1 `ssh client present` probe fails
#     without it. Even though cloud blocks outbound TCP 22, the binary is still
#     used by `git@github.com:...` remote drivers.
#   - bubblewrap: required by `claude mcp list` when
#     CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 (the cloud default). Without it the
#     subcommand errors immediately: "bubblewrap is required for subprocess env
#     scrubbing and isolation". Do NOT disable env scrubbing to dodge this.
#   - xz-utils: required to extract ShellCheck's `.tar.xz` release tarball.
# `universe` stays enabled as a fallback but shellcheck/shfmt now come from
# GitHub releases (see install_shellcheck_github / install_shfmt_github) — the
# apt versions are below the repo's Phase 2 floor.
# ---------------------------------------------------------------------------
install_base_packages() {
  apt-get update -qq || true
  apt-get install -y -qq \
    apt-transport-https ca-certificates software-properties-common \
    curl wget gnupg unzip tar xz-utils jq \
    openssh-client bubblewrap || true
  add-apt-repository universe -y 2>/dev/null || true
  apt-get update -qq || true
}

# ---------------------------------------------------------------------------
# .NET SDK 10 (pinned by global.json — match its version when it moves).
# Pre-install .NET in the cloud image so analyzers and Roslyn tooling work.
# NOTE: `dotnet restore` WAS blocked by the cloud-proxy JWT format issue,
# but empirical testing 2026-04-24 on cloud_default shows it succeeding end-to-
# end. The issue may have been mitigated silently by an infra change. Re-verify
# before asserting the limitation in new docs. SDK on PATH is always needed for
# analyzers, Roslyn tooling, and the nuget MCP regardless of restore status.
# ---------------------------------------------------------------------------
install_dotnet_sdk() {
  retry_fetch "https://dot.net/v1/dotnet-install.sh" /tmp/dotnet-install.sh || return 0
  # Sanity-check: first line must be a shebang. Guards against proxy error
  # bodies served with HTTP 200 (seen: "DNS: command not found" after chmod+x).
  if ! head -c 2 /tmp/dotnet-install.sh | grep -q '^#!'; then
    echo "WARN: /tmp/dotnet-install.sh does not start with #! — skipping .NET install" >&2
    return 0
  fi
  chmod +x /tmp/dotnet-install.sh
  /tmp/dotnet-install.sh --channel 10.0 --install-dir /usr/share/dotnet || true
  ln -sf /usr/share/dotnet/dotnet /usr/bin/dotnet 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# ShellCheck (GitHub release — Ubuntu 24.04 apt is at 0.9.0-1, below our
# Phase 2 floor of 0.11.0). The .shellcheckrc enables optional checks that
# require 0.11+; using apt's 0.9 produces spurious "unknown check" warnings.
# ---------------------------------------------------------------------------
install_shellcheck_github() {
  local sc_ver=0.11.0
  retry_fetch \
    "https://github.com/koalaman/shellcheck/releases/download/v${sc_ver}/shellcheck-v${sc_ver}.linux.x86_64.tar.xz" \
    /tmp/shellcheck.tar.xz || return 0
  if ! tar -tJf /tmp/shellcheck.tar.xz >/dev/null 2>&1; then
    echo "WARN: /tmp/shellcheck.tar.xz is not a valid xz archive — skipping ShellCheck install" >&2
    rm -f /tmp/shellcheck.tar.xz
    return 0
  fi
  tar -xJf /tmp/shellcheck.tar.xz -C /tmp || true
  install -m 0755 "/tmp/shellcheck-v${sc_ver}/shellcheck" /usr/local/bin/shellcheck 2>/dev/null || true
  rm -rf /tmp/shellcheck.tar.xz "/tmp/shellcheck-v${sc_ver}"
}

# ---------------------------------------------------------------------------
# shfmt (GitHub release — Ubuntu 24.04 apt is at 3.8.0, below our floor 3.13;
# snap lags at 3.12.x). Single self-contained binary, no archive to extract.
# Download to a staging path and validate `--version` before promoting to
# /usr/local/bin/shfmt — the cloud proxy occasionally returns garbage with
# HTTP 200, which would clobber a working shfmt if we installed directly.
# ---------------------------------------------------------------------------
install_shfmt_github() {
  local shfmt_ver=3.13.1
  retry_fetch \
    "https://github.com/mvdan/sh/releases/download/v${shfmt_ver}/shfmt_v${shfmt_ver}_linux_amd64" \
    /tmp/shfmt.new || return 0
  chmod +x /tmp/shfmt.new 2>/dev/null || true
  if /tmp/shfmt.new --version >/dev/null 2>&1; then
    install -m 0755 /tmp/shfmt.new /usr/local/bin/shfmt
  else
    echo "WARN: /tmp/shfmt.new is not a valid shfmt binary — skipping install" >&2
  fi
  rm -f /tmp/shfmt.new
}

# ---------------------------------------------------------------------------
# GitHub CLI apt source (official apt source). Installs gh in cloud sessions
# for general GitHub CLI usage. Note: /autofix-pr uses the user's terminal gh
# to detect the open PR; the cloud session itself uses built-in GitHub tools.
# Method per https://github.com/cli/cli/blob/trunk/docs/install_linux.md
# ---------------------------------------------------------------------------
install_github_cli_apt_source() {
  # Split mkdir + chmod to satisfy SC2174 (mkdir -p -m applies mode only to
  # deepest dir — identical to what we want but shellcheck warns anyway).
  mkdir -p /etc/apt/keyrings
  chmod 755 /etc/apt/keyrings
  retry_fetch "https://cli.github.com/packages/githubcli-archive-keyring.gpg" \
    /etc/apt/keyrings/githubcli-archive-keyring.gpg || return 0
  chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
    >/etc/apt/sources.list.d/github-cli.list
  apt-get update -qq || true
}

# ---------------------------------------------------------------------------
# PowerShell 7.4+ apt source (needed for PSScriptAnalyzer — 48+ .ps1/.psm1
# files in repo, and the powershell-format plugin's PostToolUse hook).
# Method: Microsoft apt repo with dynamic ${VERSION_ID} template.
# ---------------------------------------------------------------------------
install_powershell_apt_source() {
  # VERSION_ID comes from sourcing /etc/os-release (a system file outside
  # source-path). ShellCheck can't statically follow that, so SC1091 and
  # SC2154 are both expected and safe to suppress here.
  # shellcheck disable=SC1091,SC2154
  . /etc/os-release
  # shellcheck disable=SC2154
  retry_fetch "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" \
    /tmp/packages-microsoft-prod.deb || return 0
  # Sanity-check: dpkg-deb -I verifies the file is a valid Debian package.
  if ! dpkg-deb -I /tmp/packages-microsoft-prod.deb >/dev/null 2>&1; then
    echo "WARN: /tmp/packages-microsoft-prod.deb is not a valid .deb — skipping MS apt source" >&2
    rm -f /tmp/packages-microsoft-prod.deb
    return 0
  fi
  dpkg -i /tmp/packages-microsoft-prod.deb || true
  apt-get update -qq || true
  rm -f /tmp/packages-microsoft-prod.deb
}

# ---------------------------------------------------------------------------
# install_psscriptanalyzer — PSGallery module via Install-Module with retries.
# Required by .lefthook/pre-commit/psscriptanalyzer.sh and the
# powershell-format plugin hook (both call `Invoke-ScriptAnalyzer`).
# apt install powershell ships the interpreter only, NOT the analyzer module;
# PSScriptAnalyzer lives on PSGallery and must be installed via Install-Module.
#
# Why a retry loop: PowerShellGet 2.x on Linux hits transient
# hash-mismatch / zip-truncation errors through the cloud egress proxy
# ("End of Central Directory record could not be found") — empirically one
# retry usually suffices. Previous -ErrorAction SilentlyContinue swallowed
# the failure silently, leaving the module missing with no signal. We use
# -ErrorAction Stop inside try/catch so failures surface and get retried.
#
# Embedded PowerShell (scoped exception to CLAUDE.md "No embedded
# cross-language scripts"): this script is a single-file deliverable — its
# contents are pasted into the Claude Code cloud UI "Setup script" field,
# which has no access to sibling files at runtime. A prior attempt to
# extract this block into tools/Install-PSScriptAnalyzer.ps1 + pwsh -File
# broke PSScriptAnalyzer install in cloud sessions because the sibling .ps1
# doesn't exist in the pasted context.
# The general rule yields to this architectural constraint; see CLAUDE.md
# "Single-file UI-paste scripts" for the exception scope.
#
# Refs:
#   https://support.sonatype.com/hc/en-us/articles/17731370015891
#   https://github.com/PowerShell/PowerShellGallery/issues/96
# ---------------------------------------------------------------------------
install_psscriptanalyzer() {
  command -v pwsh >/dev/null 2>&1 || return 0
  pwsh -NoProfile -NonInteractive -Command '
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    $max = 3
    for ($i = 1; $i -le $max; $i++) {
      try {
        Install-Module -Name PSScriptAnalyzer -Scope AllUsers -Force -ErrorAction Stop
        exit 0
      } catch {
        Write-Host ("install_psscriptanalyzer: attempt {0}/{1} failed: {2}" -f $i, $max, $_.Exception.Message)
        Start-Sleep -Seconds ($i * 2)
      }
    }
    Write-Host ("install_psscriptanalyzer: giving up after {0} attempts" -f $max)
    exit 1
  ' >&2 || echo "WARN: PSScriptAnalyzer install failed after retries" >&2
}

# ---------------------------------------------------------------------------
# actionlint (GitHub Actions workflow linter).
#
# Pinning: the installer script (download-actionlint.bash) is fetched from a
# release tag rather than `main` so a force-pushed tag or silent `main` change
# can't swap the installer out from under us, and we pass an explicit version
# to the installer instead of `latest`. Bump ACTIONLINT_VERSION alongside the
# installer-script tag when upgrading. Same pattern as install_shellcheck_github
# and install_shfmt_github below.
# ---------------------------------------------------------------------------
install_actionlint() {
  local actionlint_version='v1.7.12'
  local installer_tag="${actionlint_version}"
  retry_fetch \
    "https://raw.githubusercontent.com/rhysd/actionlint/${installer_tag}/scripts/download-actionlint.bash" \
    /tmp/download-actionlint.bash || return 0
  # Sanity-check: first line must be a shebang. Guards against proxy error
  # bodies served with HTTP 200 — same defense as install_dotnet_sdk /
  # install_fnm. Without it, `bash /tmp/download-actionlint.bash` executes
  # whatever garbage the proxy returned.
  if ! head -c 2 /tmp/download-actionlint.bash | grep -q '^#!'; then
    echo "WARN: /tmp/download-actionlint.bash does not start with #! — skipping actionlint install" >&2
    rm -f /tmp/download-actionlint.bash
    return 0
  fi
  bash /tmp/download-actionlint.bash "${actionlint_version#v}" /usr/local/bin || true
  chmod +x /usr/local/bin/actionlint 2>/dev/null || true
  rm -f /tmp/download-actionlint.bash
}

# ---------------------------------------------------------------------------
# install_lefthook — evilmartians lefthook via npm.
#
# Why npm instead of apt (Cloudsmith): the Cloudsmith `setup.deb.sh`
# empirically runs without error in the cloud image but does NOT leave an apt
# source in /etc/apt/sources.list.d/, so `apt-get install lefthook` then fails
# with "Unable to locate package". Node 22 is pre-installed in the cloud image
# and the `lefthook` npm package ships a pre-built Go binary via platform-
# specific optional deps (lefthook-linux-x64), so npm is the zero-bootstrap
# path on Linux. Install takes ~1s.
#
# The binary lands on PATH via npm's standard global-bin mechanism
# (/opt/node22/bin/lefthook → ../lib/node_modules/lefthook/bin/index.js).
#
# Version is pinned with `~` (patch-only updates) to match the pinning
# discipline of the other installers in this file (shellcheck 0.11.0,
# shfmt 3.13.1, actionlint v1.7.12). Bump alongside lefthook.yml testing.
# ---------------------------------------------------------------------------
install_lefthook() {
  npm install -g 'lefthook@~2.1.6' 2>/dev/null \
    || echo "WARN: npm install -g lefthook failed" >&2
}

# ---------------------------------------------------------------------------
# check-jsonschema (Python tool, isolated via uv — pre-installed in image).
# Requires Python >=3.9; the repo's 3.14 pin is for other code, not this tool.
# ---------------------------------------------------------------------------
install_check_jsonschema() {
  uv tool install check-jsonschema 2>/dev/null || true
  # Make `uv tool`'s bin dir visible to Claude Code and hooks.
  ln -sf "$HOME/.local/bin/check-jsonschema" /usr/local/bin/check-jsonschema 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# markdownlint-cli2 (npm — used by lefthook pre-commit + markdown-format hook).
# Node 22 is pre-installed; npm is already on PATH.
# ---------------------------------------------------------------------------
install_markdownlint_cli2() {
  npm install -g markdownlint-cli2 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# firecrawl-cli (npm — /research escalation fallback for 403/429 WebFetch,
# replaced the firecrawl-mcp server on 2026-04-24). Reads FIRECRAWL_API_KEY
# from the cloud env directly — no `firecrawl login` needed. The `/firecrawl`
# skill shells out to the `firecrawl` binary; without this install the
# escalation path in `.claude/skills/research/SKILL.md` fails with
# command-not-found.
# ---------------------------------------------------------------------------
install_firecrawl_cli() {
  npm install -g firecrawl-cli 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# fnm (Fast Node Manager — Node 22 is already pre-installed via nvm, but the
# /onboard Phase 1 gate probes for fnm specifically per CLAUDE.md. Installing
# it lets Phase 1 go green without disturbing the pre-existing nvm+node stack.
# --skip-shell avoids editing ~/.bashrc from the setup script; we symlink the
# binary into /usr/local/bin so every shell sees it.
# ---------------------------------------------------------------------------
install_fnm() {
  retry_fetch "https://fnm.vercel.app/install" /tmp/fnm-install.sh || return 0
  if ! head -c 2 /tmp/fnm-install.sh | grep -q '^#!'; then
    echo "WARN: /tmp/fnm-install.sh does not start with #! — skipping fnm install" >&2
    rm -f /tmp/fnm-install.sh
    return 0
  fi
  bash /tmp/fnm-install.sh --skip-shell 2>/dev/null || true
  ln -sf "$HOME/.local/share/fnm/fnm" /usr/local/bin/fnm 2>/dev/null || true
  rm -f /tmp/fnm-install.sh
}

# ---------------------------------------------------------------------------
# Python pinned by .python-version (3.14). uv is pre-installed in the cloud
# image. `uv python install --default` reads .python-version, installs the
# pinned minor (idempotent), and registers python/python3 in ~/.local/bin
# (no symlinks). Persist ~/.local/bin on PATH so skill scripts invoked via
# `python3` shebang resolve to the pinned interpreter.
# ---------------------------------------------------------------------------
install_python_default() {
  command -v uv >/dev/null 2>&1 || return 0
  uv python install --default 2>/dev/null || true
  if [[ -d "$HOME/.local/bin" ]]; then
    cat >/etc/profile.d/medley-uv-path.sh <<'EOF'
export PATH="$HOME/.local/bin:$PATH"
EOF
    chmod 644 /etc/profile.d/medley-uv-path.sh 2>/dev/null || true
    export PATH="$HOME/.local/bin:$PATH"
  fi
}

# ---------------------------------------------------------------------------
# sanity_check — makes silent install failures obvious in the cloud UI.
# One line per tool; scan for MISS entries after a session start if MCP
# servers, hooks, or lefthook pre-commit misbehave.
# ---------------------------------------------------------------------------
sanity_check() {
  echo "=== Cloud setup sanity check ==="
  local tool
  for tool in dotnet gh pwsh ssh bwrap jq shellcheck shfmt actionlint lefthook fnm python3 check-jsonschema markdownlint-cli2 firecrawl; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo "  OK   $tool"
    else
      echo "  MISS $tool"
    fi
  done
  # Version spot-check on the two linters we pin above the apt floor — a MISS
  # here means the GitHub-release download silently failed and the /onboard
  # Phase 2 gate will FAIL at session start.
  if command -v shellcheck >/dev/null 2>&1; then
    echo "       shellcheck: $(shellcheck --version | awk '/^version:/ {print $2}')"
  fi
  if command -v shfmt >/dev/null 2>&1; then
    echo "       shfmt:      $(shfmt --version)"
  fi
  # Module check — pwsh on PATH does not imply PSScriptAnalyzer is importable.
  command -v pwsh >/dev/null 2>&1 || return 0
  if pwsh -NoProfile -NonInteractive -Command \
    'if (Get-Module -ListAvailable -Name PSScriptAnalyzer) { exit 0 } else { exit 1 }' \
    2>/dev/null; then
    echo "  OK   PSScriptAnalyzer (pwsh module)"
  else
    echo "  MISS PSScriptAnalyzer (pwsh module)"
  fi
}

# ---------------------------------------------------------------------------
# main — orchestrate the install flow.
# Order matters:
#   1. base packages + universe (prereqs for other installers)
#   2. .NET install (standalone, no apt dependency)
#   3. ShellCheck + shfmt from GitHub releases (apt versions are below our
#      Phase 2 floor — see install_shellcheck_github / install_shfmt_github)
#   4. register gh + MS apt sources BEFORE any `apt-get install` that needs them
#   5. apt installs — split by source so one unreachable repo can't cascade-fail
#   6. PSGallery module (needs pwsh on PATH from step 5)
#   7. standalone binary installers (actionlint, lefthook via npm, uv tool, npm)
#   8. fnm + uv python --default so /onboard Phase 1 goes green
#   9. sanity check — makes silent install failures obvious
# ---------------------------------------------------------------------------
main() {
  install_base_packages
  install_dotnet_sdk
  install_shellcheck_github
  install_shfmt_github
  install_github_cli_apt_source
  install_powershell_apt_source

  # apt installs split by source so one unreachable repo can't cascade-fail
  # unrelated packages. `apt-get install` is atomic: if any one package is
  # unresolvable (e.g., the MS apt source failed to register during a proxy
  # storm), the whole transaction aborts and everything listed is skipped.
  #   - gh: from cli.github.com apt source
  #   - powershell: from packages.microsoft.com apt source
  # (shellcheck + shfmt come from GitHub releases above, not apt.)
  apt-get install -y -qq gh || true
  apt-get install -y -qq powershell || true

  install_psscriptanalyzer
  install_actionlint
  install_lefthook
  install_check_jsonschema
  install_markdownlint_cli2
  install_firecrawl_cli
  install_fnm
  install_python_default

  sanity_check
}

# Invoke main unless the caller set CLOUD_SETUP_SKIP_MAIN=1. The test file
# (tools/cloud-setup/setup.test.sh) sets this before sourcing so it can exercise
# individual helper functions without triggering the full install flow.
# The cloud UI runs this script via `bash <file>` — no env var set, so main
# runs. The env-var guard is unambiguous regardless of how the script is
# invoked (direct exec, piped to `bash -s`, etc.).
if [[ "${CLOUD_SETUP_SKIP_MAIN:-0}" != "1" ]]; then
  main "$@"
fi

# ---------------------------------------------------------------------------
# Optional: ffmpeg 7.1+ and ImageMagick 7 — only needed for the
# course-digest skill's media pipeline. Add a helper and
# wire into main() if those flows are needed. Ubuntu 24.04 apt ships
# ffmpeg 6.1.1 (below bootstrap.sh floor) and ImageMagick 6 (repo needs 7),
# so both require non-apt installs. Skipped by default to keep setup fast.
# ---------------------------------------------------------------------------
# add-apt-repository -y ppa:ubuntuhandbook1/ffmpeg7 && apt-get update -qq && apt-get install -y -qq ffmpeg
# IM_VER=7.1.2-21 && wget -q "https://imagemagick.org/archive/binaries/ImageMagick-${IM_VER}-gcc-x86_64.AppImage" -O /usr/local/bin/magick && chmod +x /usr/local/bin/magick && cd /opt && /usr/local/bin/magick --appimage-extract && ln -sf /opt/squashfs-root/usr/bin/magick /usr/local/bin/magick
