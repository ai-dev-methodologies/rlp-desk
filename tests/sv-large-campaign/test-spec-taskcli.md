# Test Specification: taskcli

All acceptance criteria are automatically verifiable. The Verifier runs the
commands below from the project root. `$S` denotes a scratch store path the
Verifier chooses inside a temp dir (never the campaign's real tasks.json).

## Verification Commands

### Full test suite (primary gate)
```bash
python3 -m pytest -v          # collects test_taskcli.py + test_integration.py → ALL PASSED, exit 0
```

### Module import sanity
```bash
python3 -c "import models, store, service, stats, export, cli"
```

### End-to-end CLI smoke
```bash
S=$(mktemp -d)/tasks.json
python3 cli.py --store "$S" add "Buy milk"            # exit 0
python3 cli.py --store "$S" list | grep -q "Buy milk" # task visible
python3 cli.py --store "$S" stats | grep -qiE "total"  # stats render
```

## Criteria → Verification Mapping

| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: models.py exists | automated | `test -f models.py` |
| US-001 AC2/3: make_task | automated | `python3 -c "from models import make_task; t=make_task('x'); assert t.id and t.done is False"` |
| US-001 AC4: invalid priority | automated | `python3 -c "from models import make_task; make_task('x','bogus')"` → ValueError |
| US-002 AC2: missing → [] | automated | `python3 -c "from store import load_tasks; assert load_tasks('/no/such/f.json')==[]"` |
| US-002 AC3: round-trip | automated | `python3 -c "from store import load_tasks,save_tasks; from models import make_task; import tempfile,os; p=tempfile.mktemp(); t=make_task('a'); save_tasks(p,[t]); assert load_tasks(p)[0].title=='a'"` |
| US-002 AC4: corrupt → [] | automated | `python3 -c "import tempfile; p=tempfile.mktemp(); open(p,'w').write('{bad'); from store import load_tasks; assert load_tasks(p)==[]"` |
| US-003: add_task persists | automated | `python3 -c "import tempfile; from service import add_task; from store import load_tasks; p=tempfile.mktemp(); add_task(p,'a'); assert len(load_tasks(p))==1"` |
| US-004: list filter | automated | covered by `python3 -m pytest test_taskcli.py -k list -v` |
| US-005: complete + idempotent + KeyError | automated | covered by `python3 -m pytest test_taskcli.py -k complete -v` |
| US-006: delete + KeyError | automated | covered by `python3 -m pytest test_taskcli.py -k delete -v` |
| US-007: search case-insensitive | automated | covered by `python3 -m pytest test_taskcli.py -k search -v` |
| US-008: compute_stats invariants | automated | `python3 -c "from stats import compute_stats; from models import make_task; s=compute_stats([make_task('a'),make_task('b','high')]); assert s['total']==s['done']+s['pending']==2 and sum(s['by_priority'].values())==2"` |
| US-009: to_csv N+1 lines | automated | `python3 -c "import tempfile; from export import to_csv; from models import make_task; p=tempfile.mktemp(); to_csv(p,[make_task('a'),make_task('b')]); assert len([l for l in open(p) if l.strip()])==3"` |
| US-010: CLI add+list exit 0 | automated | see End-to-end CLI smoke above |
| US-011: unit tests pass, ≥12 | automated | `python3 -m pytest test_taskcli.py -v` → PASSED count ≥ 12, exit 0 |
| US-012: integration test passes | automated | `python3 -m pytest test_integration.py -v` → exit 0 |
| DONE: whole suite | automated | `python3 -m pytest -v` → ALL PASSED, exit 0 |

## Notes for the Verifier
- Treat a missing module/function as the corresponding US FAIL, not a verifier error.
- Tests must use a temp store (`tmp_path`); a test that writes the repo's real
  `tasks.json` is an automatic US-011/US-012 FAIL.
- The campaign is COMPLETE only when `python3 -m pytest -v` is green AND every
  US-NNN above has its mapped check passing.
