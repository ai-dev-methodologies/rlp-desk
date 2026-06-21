# Test Specification: gatemed

## Verification Commands
```bash
python3 -m pytest -v
```

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: kvstore.py exists | automated | `test -f kvstore.py` |
| US-001 AC2/3: round-trip (L3 E2E) | automated | `python3 -c "import tempfile,kvstore as k; p=tempfile.mktemp(); k.kv_set(p,'a',1); assert k.kv_get(p,'a')==1 and k.kv_get(p,'b') is None"` |
| US-001 AC4: corrupt→None | automated | `python3 -c "import tempfile,kvstore as k; p=tempfile.mktemp(); open(p,'w').write('{bad'); assert k.kv_get(p,'x') is None"` |
| DONE: suite | automated | `python3 -m pytest -v` exit 0 |

## Verification Layers
- L1 Unit: pytest unit tests (always required) — PRESENT
- L2 Integration: N/A — no external services (local file only)
- L3 E2E: the set→get round-trip command above (always required) — PRESENT
- L4 Deploy: N/A — not deploying
