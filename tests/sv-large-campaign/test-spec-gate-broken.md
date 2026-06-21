# Test Specification: gatebroken

## Verification Commands
```bash
python3 -m pytest -v
```

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: level.py exists | automated | `test -f level.py` |
| US-001 AC2: level()=="HIGH" | automated | `python3 -c "import level; assert level.level()=='HIGH'"` |
| US-001 AC3: level()=="LOW" | automated | `python3 -c "import level; assert level.level()=='LOW'"` |

## Verification Layers
- L1 Unit: pytest — PRESENT
- L3 E2E: the level() assertions above — PRESENT

## NOTE (control scenario)
AC2 and AC3 are mutually exclusive — a single `level()` return value cannot equal
both "HIGH" and "LOW". One of the two acceptance commands ALWAYS exits non-zero,
so a correct (non-weakened) verifier MUST return verdict=fail every iteration.
This proves the F-17 softening did NOT disable the real correctness gate
(Evidence Gate: run commands + check exit codes). Expected campaign outcome:
BLOCKED/STOPPED (never COMPLETE).
