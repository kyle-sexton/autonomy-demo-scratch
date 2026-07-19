#!/usr/bin/env bash
# Install transitive deps of a package's `file:`-linked local dependencies.
#
# npm links a `file:` (non-workspace) dependency by symlink but does NOT install
# that linked package's own dependencies. Node resolves the symlink to its real
# path before resolving the linked package's imports, so those deps must sit in
# the linked dir's own node_modules. This installs them per linked dir that has a
# lockfile (npm ci) or package.json (npm install). No-op when the package has no
# file: deps.
#
# Usage:
#   install-local-file-deps.sh <package-dir>
#
# Exit codes:
#   0  success (including the no-file:-deps no-op case)
#   1  package dir or its package.json missing
#   2  argument error

set -euo pipefail

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'USAGE'
install-local-file-deps.sh <package-dir>

Install transitive deps of <package-dir>'s file:-linked local dependencies.
npm links a file: (non-workspace) dep by symlink but does not install that
linked package's own deps; Node resolves the symlink's real path, so the deps
must live in the linked dir's node_modules. Installs them per linked dir via
npm ci (lockfile present) or npm install. No-op when there are no file: deps.

Exit codes:
  0  success (including the no-file:-deps no-op case)
  1  package dir or its package.json missing, or a linked dep lacks package.json
  2  argument error
USAGE
  exit 0
fi

if [[ $# -ne 1 ]]; then
  echo "usage: install-local-file-deps.sh <package-dir>" >&2
  exit 2
fi

pkg_dir="$1"
if [[ ! -d "$pkg_dir" ]]; then
  echo "install-local-file-deps: not a directory: $pkg_dir" >&2
  exit 1
fi

pkg_dir="$(cd "$pkg_dir" && pwd)"
pkg_json="$pkg_dir/package.json"
if [[ ! -f "$pkg_json" ]]; then
  echo "install-local-file-deps: no package.json in $pkg_dir" >&2
  exit 1
fi

# Emit one resolved absolute path per file:-linked local dependency.
mapfile -t linked_dirs < <(
  node -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const pkgDir = process.argv[1];
    const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, "package.json"), "utf8"));
    const deps = { ...pkg.dependencies, ...pkg.optionalDependencies };
    for (const spec of Object.values(deps)) {
      if (typeof spec === "string" && spec.startsWith("file:")) {
        process.stdout.write(path.resolve(pkgDir, spec.slice("file:".length)) + "\n");
      }
    }
  ' "$pkg_dir"
)

for linked in "${linked_dirs[@]}"; do
  [[ -n "$linked" ]] || continue
  if [[ ! -f "$linked/package.json" ]]; then
    echo "install-local-file-deps: linked dep has no package.json: $linked" >&2
    exit 1
  fi
  echo "install-local-file-deps: installing deps for $linked"
  if [[ -f "$linked/package-lock.json" ]]; then
    (cd "$linked" && npm ci)
  else
    (cd "$linked" && npm install)
  fi
done
