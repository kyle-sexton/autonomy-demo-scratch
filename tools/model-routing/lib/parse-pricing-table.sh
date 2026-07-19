#!/usr/bin/env bash
# shellcheck shell=bash
# Extract model names from pricing markdown table (pipe stdin).

set -uo pipefail

parse_pricing_model_ids() {
  awk -F'|' '
    NR < 3 { next }
    $0 ~ /^\|/ {
      gsub(/^[ \t|]+|[ \t|]+$/, "", $0)
      n = split($0, cols, "|")
      for (i = 1; i <= n; i++) {
        gsub(/^[ \t]+|[ \t]+$/, "", cols[i])
      }
      if (cols[1] != "" && cols[1] !~ /^Model$/ && cols[1] !~ /^---/) {
        print cols[1]
      }
    }
  ' | tr '[:upper:]' '[:lower:]' | sed -e 's/ /-/g' -e 's/claude-opus-4\.8/claude-opus-4-8/g' | sort -u
}
