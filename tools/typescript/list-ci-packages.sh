#!/usr/bin/env bash
# Discover TypeScript CI packages — dirs holding tsconfig.json + package.json +
# package-lock.json. SSOT for typescript-ci.yml matrix; new packages need only
# those three files (no workflow edit).
#
# Usage:
#   list-ci-packages.sh                    # one package path per line (sorted)
#   list-ci-packages.sh --json             # JSON array of paths (GitHub Actions matrix)
#   list-ci-packages.sh --json-detail      # JSON array of {path, vitest} objects
#   list-ci-packages.sh --include-npm-only   # also dirs with package.json + lockfile (no tsconfig)

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')
[[ -n "$REPO_ROOT" && -d "$REPO_ROOT" ]] || {
  echo "list-ci-packages: not inside a git repository" >&2
  exit 1
}

JSON=false
JSON_DETAIL=false
INCLUDE_NPM_ONLY=false
for arg in "$@"; do
  case "$arg" in
    --json) JSON=true ;;
    --json-detail) JSON_DETAIL=true ;;
    --include-npm-only) INCLUDE_NPM_ONLY=true ;;
    -h | --help)
      printf '%s\n' "Usage: list-ci-packages.sh [--json | --json-detail | --include-npm-only]"
      exit 0
      ;;
    *)
      printf 'list-ci-packages: unknown argument: %s\n' "$arg" >&2
      exit 2
      ;;
  esac
done

uses_vitest() {
  local pkg_json="$1"
  node -e '
    const fs = require("node:fs");
    const pkg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    const deps = { ...pkg.dependencies, ...pkg.devDependencies };
    process.exit(deps.vitest ? 0 : 1);
  ' "$pkg_json" 2>/dev/null
}

packages=()
while IFS= read -r -d '' tsconfig; do
  pkg_dir=$(dirname "$tsconfig")
  rel="${pkg_dir#"$REPO_ROOT"/}"
  [[ -f "$pkg_dir/package.json" && -f "$pkg_dir/package-lock.json" ]] || continue
  # Skip gitignored dirs (e.g. vendored, locally-cloned companion repos under a
  # skill's data/) — CI packages are tracked; find is not git-aware so it would
  # otherwise discover untracked package dirs.
  if git -C "$REPO_ROOT" check-ignore -q "$pkg_dir"; then continue; fi
  packages+=("$rel")
done < <(find "$REPO_ROOT" -path '*/node_modules' -prune -o -path '*/build' -prune -o -name 'tsconfig.json' -print0)

if [[ "$INCLUDE_NPM_ONLY" == true ]]; then
  while IFS= read -r -d '' pkg_json; do
    pkg_dir=$(dirname "$pkg_json")
    [[ "$pkg_dir" == "$REPO_ROOT" ]] && continue
    rel="${pkg_dir#"$REPO_ROOT"/}"
    [[ -f "$pkg_dir/package-lock.json" ]] || continue
    [[ -f "$pkg_dir/tsconfig.json" ]] && continue
    if git -C "$REPO_ROOT" check-ignore -q "$pkg_dir"; then continue; fi
    packages+=("$rel")
  done < <(find "$REPO_ROOT" -path '*/node_modules' -prune -o -name 'package.json' -print0)
fi

if [[ ${#packages[@]} -eq 0 ]]; then
  if [[ "$JSON" == true || "$JSON_DETAIL" == true ]]; then
    printf '[]\n'
  fi
  exit 0
fi

mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)

if [[ "$JSON_DETAIL" == true ]]; then
  printf '['
  first=true
  for rel in "${packages[@]}"; do
    vitest=false
    if uses_vitest "$REPO_ROOT/$rel/package.json"; then
      vitest=true
    fi
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '{"path":"%s","vitest":%s}' "$rel" "$vitest"
  done
  printf ']\n'
  exit 0
fi

if [[ "$JSON" == true ]]; then
  printf '['
  first=true
  for rel in "${packages[@]}"; do
    if [[ "$first" == true ]]; then
      first=false
    else
      printf ','
    fi
    printf '"%s"' "$rel"
  done
  printf ']\n'
  exit 0
fi

printf '%s\n' "${packages[@]}"
