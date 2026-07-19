#!/usr/bin/env bash
# Measure the markdown-coupling baseline across three axes of duplication / blast radius:
#   1. lexical near-duplication (MinHash over heading-section chunks),
#   2. co-change coupling (git history support + confidence),
#   3. per-hotspot blast radius (semantic-duplication hotspot file/site counts).
# Enumerates the markdown-discipline "Scope" corpus (NOT Glob — git ls-files, tracked-only),
# gathers git co-change history, and writes an assertion-only baseline under
# .work/<slug>/baselines/. The functional core lives in detect.py / lexical.py /
# cochange.py; this script is the mutable shell (git + file I/O).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DETECT="${SCRIPT_DIR}/detect.py"
HOTSPOTS_DEFAULT="${SCRIPT_DIR}/hotspots.tsv"
REQUIREMENTS="${SCRIPT_DIR}/requirements.txt"

# This slice's working-dir name; the baseline lands under .work/<slug>/baselines/.
readonly SLUG="markdown-coupling"
# Corpus-scope SSOT — SCOPE_RE (markdown-discipline.md "Scope") + NOISE_RE. Shared with
# the M2 near-dup lane via corpus-scope.sh (D8 — was triplicated).
# shellcheck source=corpus-scope.sh
source "${SCRIPT_DIR}/corpus-scope.sh"
# Datasketch-aware interpreter discovery — shared with the M2 near-dup lane + tests so all
# resolve the same interpreter (the one importing datasketch). Was duplicated inline here.
# shellcheck source=py-discovery.sh
source "${SCRIPT_DIR}/py-discovery.sh"

usage() {
  cat <<'EOF'
Usage: measure.sh [options]

Measure the markdown-coupling baseline (lexical near-dup + co-change + per-hotspot blast radius)
and write an assertion-only baseline file.

Options:
  --since <sha>          Co-change FORWARD window: count only commits in <sha>..HEAD. At the
                         baseline HEAD, --since <head_sha> yields an empty forward window
                         (this is what Phase 6 re-runs to measure post-intervention coupling).
  --out <file>           Write the baseline to <file> (default: a timestamped file under
                         .work/<slug>/baselines/).
  --hotspots <file>      Axis-3 hotspot definitions (default: hotspots.tsv beside this script).
  --root <dir>           Repo root to enumerate + resolve corpus paths against (default: the
                         git toplevel of this script).
  --corpus-file <file>   Override primary-corpus enumeration with a newline-delimited path list
                         (hermetic-test seam; skips git ls-files).
  --secondary-file <f>   Override .work secondary-corpus enumeration (hermetic-test seam).
  --log-file <file>      Override git-log gathering with a pre-captured dump (hermetic-test seam).
  --dry-run              Print what would be measured (corpus counts, head_sha, output path)
                         without invoking the detector or writing a file.
  --help                 Show this help and exit.

Requires datasketch for axis 1 (`cd tools/markdown-coupling && uv sync --frozen`, or pip install -r tools/markdown-coupling/requirements.txt). Without
it, axis 1 reports SKIPPED and axes 2-3 still run.
EOF
}

err() { echo "ERROR: $*" >&2; }

main() {
  local since="" out="" hotspots="$HOTSPOTS_DEFAULT" root=""
  local corpus_file="" secondary_file="" log_file="" dry_run=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --since)
        since="${2:?--since needs a sha}"
        shift 2
        ;;
      --out)
        out="${2:?--out needs a path}"
        shift 2
        ;;
      --hotspots)
        hotspots="${2:?--hotspots needs a path}"
        shift 2
        ;;
      --root)
        root="${2:?--root needs a path}"
        shift 2
        ;;
      --corpus-file)
        corpus_file="${2:?--corpus-file needs a path}"
        shift 2
        ;;
      --secondary-file)
        secondary_file="${2:?--secondary-file needs a path}"
        shift 2
        ;;
      --log-file)
        log_file="${2:?--log-file needs a path}"
        shift 2
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --help | -h)
        usage
        return 0
        ;;
      *)
        err "unknown argument: $1"
        usage >&2
        return 2
        ;;
    esac
  done

  # Discover the interpreter that can import datasketch (axis 1 dep) via the shared probe —
  # measure.sh, the M2 lane, and their tests all resolve the same one (py-discovery.sh).
  local py
  py="$(mc_discover_python "$SCRIPT_DIR")"
  if [[ -z "$py" ]]; then
    err "python3 (or python) not found on PATH"
    return 1
  fi

  if [[ -z "$root" ]]; then
    root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel | tr -d '\r')"
  fi

  local head_sha
  head_sha="$(git -C "$root" rev-parse HEAD | tr -d '\r')"

  # Working files (auto-cleaned). Reuse caller-provided overrides for the hermetic-test seam.
  local tmpdir
  tmpdir="$(mktemp -d)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmpdir'" EXIT

  local primary="${corpus_file:-$tmpdir/primary.txt}"
  local secondary="${secondary_file:-$tmpdir/secondary.txt}"
  local log="${log_file:-$tmpdir/log.txt}"

  if [[ -z "$corpus_file" ]]; then
    git -C "$root" ls-files '*.md' | tr -d '\r' \
      | grep -vE "$NOISE_RE" | grep -v '^\.work/' | grep -E "$SCOPE_RE" \
      | LC_ALL=C sort >"$primary" || true
  fi
  if [[ -z "$secondary_file" ]]; then
    git -C "$root" ls-files '*.md' | tr -d '\r' \
      | grep -vE "$NOISE_RE" | grep -E '^\.work/' \
      | LC_ALL=C sort >"$secondary" || true
  fi
  if [[ -z "$log_file" ]]; then
    local range="HEAD"
    [[ -n "$since" ]] && range="${since}..HEAD"
    git -C "$root" log "$range" --no-merges --pretty=format:'__COMMIT__%H' \
      --name-only -- '*.md' | tr -d '\r' >"$log" || true
  fi

  local primary_n secondary_n
  primary_n="$(grep -c . "$primary" || true)"
  secondary_n="$(grep -c . "$secondary" || true)"

  local datasketch_ok=1
  "$py" -c 'import datasketch' >/dev/null 2>&1 || datasketch_ok=0

  if ((dry_run)); then
    echo "head_sha:        $head_sha"
    echo "since:           ${since:-<full history>}"
    echo "primary files:   $primary_n"
    echo "secondary files: $secondary_n"
    echo "hotspots:        $hotspots"
    echo "datasketch:      $datasketch_ok (1=present, 0=missing)"
    echo "output path:     ${out:-<timestamped under .work/${SLUG}/baselines/>}"
    return 0
  fi

  # datasketch is load-bearing now — M2 (near_dup_gate.py) is wired into lefthook and the
  # /onboard Phase 9d gate is a HARD prerequisite. A missing dep fails LOUD here rather than
  # silently SKIPping axis 1; a fully onboarded machine never reaches this.
  if ((datasketch_ok == 0)); then
    err "datasketch not installed — required for axis 1 (lexical near-dup)."
    err "  install: pip install -r ${REQUIREMENTS}  (or: cd tools/markdown-coupling && uv sync --frozen)"
    return 1
  fi

  if [[ -z "$out" ]]; then
    local ts
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    out="${root}/.work/${SLUG}/baselines/${ts}-duplication.md"
  fi
  mkdir -p "$(dirname "$out")"

  local body
  body="$("$py" "$DETECT" \
    --primary-file "$primary" \
    --secondary-file "$secondary" \
    --log-file "$log" \
    --hotspots "$hotspots" \
    --root "$root" \
    --head-sha "$head_sha" \
    ${since:+--since "$since"})"

  # Frontmatter is the ONLY non-deterministic surface: `generated` is the single varying line,
  # so two runs at the same HEAD diff only on that line (determinism Sanity Check).
  {
    echo "---"
    echo "type: baseline"
    echo "slug: markdown-coupling"
    echo "head_sha: $head_sha"
    echo "since: ${since:-full-history}"
    echo "generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "---"
    echo ""
    printf '%s\n' "$body"
  } >"$out"

  echo "$out"
}

main "$@"
