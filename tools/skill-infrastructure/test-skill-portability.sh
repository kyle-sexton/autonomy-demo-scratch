#!/usr/bin/env bash
# Backward-compat entry — delegates to tools/skill-contract/skill-portability-lib.sh
exec bash "$(git rev-parse --show-toplevel 2>/dev/null | tr -d '\r')/tools/skill-contract/skill-portability-lib.sh" "$@"
