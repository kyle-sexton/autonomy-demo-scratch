# process-management

PID lifecycle helpers: `pid-alive.sh` (winpid-aware liveness), `pid-file-read.sh`, `pid-graceful-stop.sh` (signal → poll → SIGKILL escalation; see `docs/ecosystems/bash-gotchas-reference.md` on MSYS2 INT delivery). Sourceable libs + sibling tests.

Owner: process-supervision policy. Consumers derive on demand via the repo dep-graph edge scan (`tools/AGENTS.md` "Vertical slices").
