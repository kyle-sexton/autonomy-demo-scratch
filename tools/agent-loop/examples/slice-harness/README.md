# Slice harness templates

Scaffold agent-loop pilot artifacts for a `.work/<slug>/` slice:

```bash
bash tools/agent-loop/scripts/scaffold-slice-harness.sh \
  --slug youtube-skill \
  --phases 7 \
  --out-subdir .work/<slug>/out
```

Naming: `naming-convention.md`. Operator fills `<fill: …>` markers from PLAN; host runs `verify-phase-N.sh` after each loop.
