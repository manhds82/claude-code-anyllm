# Golden fixtures

Behavioural regression fixtures: an input and its **expected exact output**. If a
change alters behaviour, the golden run fails loudly.

## Current sets

| File | What it pins |
|------|--------------|
| `select-suites.cases.json` | The impact-scoped resolver (`tests/select-suites.py`): changed files → which suites run. This decides CI safety, so it is golden-guarded. |

## Run

```bash
python tests/golden/run-golden.py        # exit 0 = pass; both suites call this
```

Both `tests/run-tests.ps1` and `tests/run-tests.sh` invoke it as the policy-ci check
**"golden: impact resolver"** (skipped gracefully if Python is unavailable).

## Add a case

Append one object to `cases` in `select-suites.cases.json`:

```json
{ "changed": ["path/that/changed"], "expect": "policy-ci red-team" }
```

`expect` is one of: `ALL`, `NONE`, `policy-ci`, `red-team`, `policy-ci red-team`.
