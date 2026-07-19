# shellcheck shell=bash
# Shared datasketch-aware Python interpreter discovery for the markdown-coupling tools.
#
# Library — NOT executable (mode 100644). Pure-ish: probes interpreters but does no file I/O,
# no exit, no `set` (would leak into the caller). Sourced by measure.sh, the M2 near-dup lane
# (.lefthook/pre-commit/markdown-near-dup-check.sh), and their tests so all three resolve the
# SAME interpreter — the one that imports datasketch (axis-1 / M2's load-bearing dependency).
#
# Why a probe instead of bare `command -v python3`: a Windows uv venv exposes only `python`
# (no `python3`), so `python3` escapes to a system interpreter lacking the dep while the venv
# `python` has it (#1096). Probe the slice venv first, then PATH candidates; keep the first
# that resolves as the fallback so a missing-datasketch caller still has a usable interpreter
# for its error message.

# mc_discover_python <mc_dir> — echo the best Python interpreter path for the markdown-coupling
# tools rooted at <mc_dir> (the directory that holds .venv). Resolution order: the first
# candidate that can `import datasketch`; else the first candidate that resolves at all; else
# empty (caller treats empty as "no interpreter").
mc_discover_python() {
  local mc_dir="$1"
  local py="" candidate resolved
  local -a candidates=(
    "$mc_dir/.venv/bin/python"
    "$mc_dir/.venv/Scripts/python.exe"
    python3
    python
  )
  for candidate in "${candidates[@]}"; do
    if [[ "$candidate" == */* ]]; then
      [[ -f "$candidate" ]] || continue
      resolved="$candidate"
    else
      resolved="$(command -v "$candidate" 2>/dev/null)" || continue
    fi
    [[ -n "$py" ]] || py="$resolved"
    if "$resolved" -c 'import datasketch' >/dev/null 2>&1; then
      py="$resolved"
      break
    fi
  done
  printf '%s' "$py"
}
