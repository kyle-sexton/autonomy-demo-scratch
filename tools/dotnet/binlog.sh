#!/usr/bin/env bash
# Build with MSBuild binary log capture under artifacts/.
# Wraps `dotnet build` with the canonical -bl: flag and a unique-stamp filename
# (yyyyMMdd-HHmmss--<pid>--<6char>) via MSBuild's `{}` placeholder, so back-to-back
# invocations don't clobber prior logs.
#
# Usage:
#   tools/dotnet/binlog.sh                                  # build whole solution
#   tools/dotnet/binlog.sh apps/monolith-api/MonolithApi.csproj
#   tools/dotnet/binlog.sh -c Release Medley.slnx
#
# Output: artifacts/build-<stamp>.binlog (gitignored). Open with the
# MSBuild Structured Log Viewer (msbuildlog.com) or `dotnet msbuild
# -flp:logfile=...` for text replay. ProjectImports=Embed bundles all
# imported .props/.targets/.csproj files inside the .binlog so the log
# is fully self-contained.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
mkdir -p "$REPO_ROOT/artifacts"

exec dotnet build "$@" \
  "-bl:$REPO_ROOT/artifacts/build-{}.binlog;ProjectImports=Embed" \
  -v:n
