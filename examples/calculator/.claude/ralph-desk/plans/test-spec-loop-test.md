# Test Specification: loop-test

## Verification Commands
### Test
```bash
python3 -m pytest test_calc.py -v
```
### Type hint check
```bash
grep -c "def.*float.*float.*float" calc.py
```
### Divide by zero
```bash
python3 -c "from calc import divide; divide(1, 0)"
# must raise ValueError
```

## Criteria → Verification Mapping
| Criterion | Method | Command |
|-----------|--------|---------|
| US-001 AC1: calc.py exists | automated | `test -f calc.py` |
| US-001 AC2: 4 functions | automated | `python3 -c "from calc import add, subtract, multiply, divide"` |
| US-001 AC3: divide by zero | automated | `python3 -c "from calc import divide; divide(1, 0)"` → ValueError |
| US-001 AC4: type hints | automated | `grep "def add" calc.py` must show float annotations |
| US-002 AC1: test_calc.py exists | automated | `test -f test_calc.py` |
| US-002 AC2: uses pytest | automated | `grep "import pytest" test_calc.py` |
| US-002 AC3: 8+ tests | automated | `python3 -m pytest test_calc.py -v` → count PASSED >= 8 |
| US-002 AC4: divide zero test | automated | `grep "pytest.raises" test_calc.py` |
| US-002 AC5: ALL PASSED | automated | `python3 -m pytest test_calc.py -v` exit code 0 |
