#!/usr/bin/env bash
# Stable entry point for the shell test runner (implementation: shell-test-runner/run.sh
# and composable modules under shell-test-runner/).
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shell-test-runner/run.sh" "$@"
