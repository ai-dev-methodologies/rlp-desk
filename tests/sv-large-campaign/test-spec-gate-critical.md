# Test Specification: gatecrit

## Verification Commands
```bash
python3 -m pytest -v
```

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: safe_path.py exists | automated | `test -f safe_path.py` |
| US-001 AC2: traversal rejected (security / L3 error-path) | automated | `python3 -c "import safe_path as s; s.safe_join('/tmp/base','../etc/passwd')"` → ValueError (nonzero exit) |
| US-001 AC3: absolute escape rejected (security) | automated | `python3 -c "import safe_path as s; s.safe_join('/tmp/base','/etc/passwd')"` → ValueError |
| US-001 AC4: normal subpath OK | automated | `python3 -c "import safe_path as s; p=s.safe_join('/tmp/base','sub/f.txt'); assert str(p).startswith('/tmp/base')"` |
| DONE: suite | automated | `python3 -m pytest -v` exit 0 |

## Verification Layers
- L1 Unit: pytest unit tests (always required) — PRESENT
- L2 Integration: N/A — no external services
- L3 E2E (error-path): the traversal/absolute-escape rejection commands — PRESENT
- L4 Deploy: N/A — library module, nothing is deployed
- Security: traversal + absolute-escape rejection (AC2/AC3) — PRESENT

## Reproducibility Gate
N/A — Python standard library ONLY (no third-party dependencies to lock), no
install/build/deploy step, no env vars, no secrets. Reproducibility checks are
not applicable to this single-file stdlib module.

## Test Sufficiency (IL-4) — REQUIRED
Each acceptance criterion MUST have at least 3 tests spanning at least 2 of:
- happy path (e.g. a normal sub-path resolves under base)
- negative (e.g. `../` traversal raises ValueError; absolute `/etc/passwd` raises)
- boundary (e.g. empty string, ".", trailing slash, a path that normalizes to base)
Single-category test sets are INSUFFICIENT and will (correctly) fail IL-4.
