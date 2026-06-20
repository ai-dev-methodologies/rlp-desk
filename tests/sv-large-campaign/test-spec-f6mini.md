# Test Specification: f6mini

## Verification Commands
```bash
python3 -m pytest -v
```

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: models.py exists | automated | `test -f models.py` |
| US-001 AC2: make_task | automated | `python3 -c "from models import make_task; t=make_task('x'); assert t.id and t.done is False"` |
| US-001 AC3: invalid priority | automated | `python3 -c "from models import make_task; make_task('x','bogus')"` → ValueError |
| DONE: suite green | automated | `python3 -m pytest -v` → exit 0 |

## Notes for the Verifier
- Treat a missing module/function as the US FAIL, not a verifier error.
- A pre-existing untracked file (e.g. `local-notes.txt`) in the project root is
  EXPECTED for this repro and is NOT the Worker's concern — it must not affect
  the verdict (this is exactly the F-6 condition under test).
