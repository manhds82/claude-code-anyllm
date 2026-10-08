#!/usr/bin/env bash
# Hash-chain ledger (bash parity) — append-only immutable audit trail (H5).
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LEDGER_DIR="$HARNESS_ROOT/.harness/ledger"
CHAIN_FILE="$LEDGER_DIR/chain.jsonl"
BUNDLE_DIR="$LEDGER_DIR/bundles"
mkdir -p "$BUNDLE_DIR"

COMMAND="${1:-append}"
shift || true

ENTRY_JSON_ARG=""
ENTRY_FILE_ARG=""
REASON_ARG=""
while [ $# -gt 0 ]; do
    case "$1" in
        --entry-json) ENTRY_JSON_ARG="$2"; shift 2 ;;
        --entry-file) ENTRY_FILE_ARG="$2"; shift 2 ;;
        --reason) REASON_ARG="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Resolve entry input without ever blocking on an unredirected terminal (PIPE-1).
# Prints to stdout; callers must pipe the result into python (never string-interpolate
# untrusted JSON into a `python -c` literal — that is a code-injection hole).
read_entry_input() {
    if [ -n "$ENTRY_JSON_ARG" ]; then
        printf '%s' "$ENTRY_JSON_ARG"
    elif [ -n "$ENTRY_FILE_ARG" ]; then
        cat "$ENTRY_FILE_ARG"
    elif [ ! -t 0 ]; then
        cat
    else
        echo "[evidence-ledger] No input provided — pass --entry-json, --entry-file, or pipe JSON via stdin" >&2
        exit 1
    fi
}

hash_entry() {
    # printf, not `echo -n`: echo eats a leading -n/-e as a flag (and some
    # shells print the -n literally), so the digest would silently be taken
    # over different bytes than the caller passed. In a hash chain a quietly
    # wrong digest is worse than a loud failure.
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Shared Python prelude for every command that writes chain.jsonl (PS parity:
# Enter-LedgerLock / Get-LastEntry in evidence-ledger.ps1).
#
# "Read the last entry_hash, then append a line linking to it" used to be two
# separate shell steps (get_last_hash, then python). Two hooks running at once
# both read the same last hash and both linked to it: the chain FORKED -- 974 of
# 8,953 entries in the toolkit's own chain on 2026-09-29, with doctor still OK.
# Now read and write happen in ONE python process holding the lock.
#
# The lock is a byte-range lock on byte 0 of chain.lock (msvcrt.locking on
# Windows, fcntl.lockf elsewhere) -- the primitive .NET's FileStream.Lock uses,
# so this and the PowerShell writer exclude each other on one machine. An OS
# lock dies with its process; a hook killed on timeout cannot wedge the ledger.
LEDGER_PY_PRELUDE='
import json, os, re, sys, time, random, hashlib
from datetime import datetime, timezone

LOCK_TIMEOUT_S = 10.0

def ledger_lock(ledger_dir):
    f = open(os.path.join(ledger_dir, "chain.lock"), "a+b")
    deadline = time.time() + LOCK_TIMEOUT_S
    while True:
        try:
            if os.name == "nt":
                import msvcrt
                f.seek(0)
                msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB, 1, 0)
            return f
        except OSError:
            if time.time() >= deadline:
                f.close()
                raise TimeoutError("ledger lock not acquired within %ss (another append is holding it)" % LOCK_TIMEOUT_S)
            time.sleep(random.uniform(0.01, 0.05))

def ledger_unlock(f):
    try:
        if os.name == "nt":
            import msvcrt
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            fcntl.lockf(f, fcntl.LOCK_UN, 1, 0)
    finally:
        f.close()

def last_link(chain_file):
    """(prev_hash, next_index) for the entry about to be written. Caller holds the lock.

    UNREADABLE, never GENESIS, when the last entry cannot be parsed: GENESIS
    would claim the chain starts here and orphan everything above it. The index
    is the line count, as before."""
    if not os.path.exists(chain_file) or os.path.getsize(chain_file) == 0:
        return "GENESIS", 0
    n = 0
    with open(chain_file, "rb") as f:
        for line in f:
            if line.strip():
                n += 1
    with open(chain_file, "rb") as f:
        size = os.path.getsize(chain_file)
        f.seek(max(0, size - 4 * 1024 * 1024))
        tail = f.read().decode("utf-8", "replace").rstrip("\r\n")
    last = tail.rsplit("\n", 1)[-1]
    h = None
    try:
        h = json.loads(last).get("entry_hash")
    except ValueError:
        m = re.findall(r"\"entry_hash\"\s*:\s*\"([0-9a-fA-F]{64})\"", last)
        h = m[-1] if m else None
    return (h or "UNREADABLE"), n

def entry_hash(e):
    c = dict(e)
    c["entry_hash"] = ""
    return hashlib.sha256(json.dumps(c, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

def now_utc():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
'

case "$COMMAND" in
    init)
        # Under the lock, and never over a chain that already has entries (PS
        # parity). Two sessions starting together both saw "no chain" and the
        # second genesis overwrote the first chain; starting over on top of history
        # is also what cut 24hHotnewsAI's live chain off from its sealed segment.
        # Paths travel in the ENVIRONMENT, never spliced into the python source
        # (a directory named O'Brien would otherwise close the string literal).
        CHAIN_FILE="$CHAIN_FILE" LEDGER_DIR="$LEDGER_DIR" python3 -c "$LEDGER_PY_PRELUDE
chain_file = os.environ['CHAIN_FILE']
lk = ledger_lock(os.environ['LEDGER_DIR'])
try:
    if os.path.exists(chain_file) and os.path.getsize(chain_file) > 0:
        print('[evidence-ledger] chain.jsonl already has entries -- not overwriting. To start a new segment use: evidence-ledger.sh seal --reason \"<why>\"')
        sys.exit(0)
    g = {'index': 0, 'prev_hash': 'GENESIS', 'entry_hash': '', 'timestamp': now_utc(),
         'actor': {'agent': 'harness', 'user': 'system', 'session_id': 'genesis', 'role': 'system'},
         'action': {'type': 'config_change', 'tool': 'harness-init', 'description': 'Genesis block'},
         'decision': {'result': 'allow', 'reason': 'System initialization', 'risk_level': 'none'},
         'payload_ref': '', 'signature': ''}
    g['entry_hash'] = entry_hash(g)
    with open(chain_file, 'w') as f:
        json.dump(g, f, separators=(',', ':'))
        f.write('\n')
    print('[evidence-ledger] Genesis block created at index 0, hash=' + g['entry_hash'])
finally:
    ledger_unlock(lk)
"
        ;;
    append)
        INPUT_JSON=$(read_entry_input)
        if [ -z "$INPUT_JSON" ]; then
            echo "[evidence-ledger] No input" >&2
            exit 1
        fi
        # Entry JSON is piped to python's stdin, never string-interpolated into
        # the script literal — untrusted content in a `python -c` string would
        # otherwise be a code-injection hole (e.g. an entry crafted to break out
        # of the ''' literal). Reading the last hash, building the entry and
        # writing it all happen inside this one process, under the lock.
        printf '%s' "$INPUT_JSON" | CHAIN_FILE="$CHAIN_FILE" LEDGER_DIR="$LEDGER_DIR" python3 -c "$LEDGER_PY_PRELUDE
entry = json.load(sys.stdin)
chain_file = os.environ['CHAIN_FILE']
stage = 'lock'
lk = None
try:
    lk = ledger_lock(os.environ['LEDGER_DIR'])
    stage = 'read-last-entry'
    prev_hash, next_idx = last_link(chain_file)
except Exception as exc:
    fail_file = os.path.join(os.path.dirname(chain_file), 'append-failures.jsonl')
    try:
        with open(fail_file, 'a') as ff:
            json.dump({'ts': now_utc(), 'type': 'append_failed', 'stage': stage,
                       'tool': (entry.get('action') or {}).get('tool', ''),
                       'session_id': os.environ.get('HARNESS_SESSION_ID', ''),
                       'reason': '%s: %s' % (type(exc).__name__, exc)}, ff, separators=(',', ':'))
            ff.write('\n')
    except Exception:
        pass
    if lk is not None:
        ledger_unlock(lk)
    sys.stderr.write('[evidence-ledger] APPEND FAILED at %s :: %s: %s\n' % (stage, type(exc).__name__, exc))
    sys.exit(3)
ts = now_utc()

new_entry = {
    'index': next_idx,
    'prev_hash': prev_hash,
    'entry_hash': '',
    'timestamp': ts,
    'actor': entry.get('actor', {'agent':'unknown','user':'unknown','session_id':'','role':''}),
    'action': entry.get('action', {'type':'tool_call','tool':'','description':'','input_hash':'','output_hash':''}),
    'decision': entry.get('decision', {'result':'allow','reason':'','risk_level':'none'}),
    'payload_ref': entry.get('payload_ref',''),
    'signature': entry.get('signature','')
}
canonical = dict(new_entry)
canonical['entry_hash'] = ''
h = hashlib.sha256(json.dumps(canonical, sort_keys=True, separators=(',',':')).encode()).hexdigest()
new_entry['entry_hash'] = h
# U1 (parity with evidence-ledger.ps1): an append that throws is a SIDE-EFFECT
# THAT HAPPENED WITH NO LINE RECORDING IT. The chain stays internally consistent
# -- the next entry links to the last one that succeeded -- so verify is green
# and the gap leaves no hole to find. This marker file is the only place the
# loss becomes visible; harness doctor grades a non-empty one as FAIL.
#
# NOT written into chain.jsonl: a marker has no valid prev_hash, so putting it
# in the chain would make verify report tampering -- trading a silent gap for a
# loud false alarm. Own file, cheapest possible writer.
try:
    with open(chain_file, 'a') as f:
        json.dump(new_entry, f, separators=(',',':'))
        f.write('\n')
except Exception as exc:
    fail_file = os.path.join(os.path.dirname(chain_file), 'append-failures.jsonl')
    marker = {
        'ts': ts,
        'type': 'append_failed',
        'stage': 'write-chain',
        'tool': (entry.get('action') or {}).get('tool', ''),
        'session_id': os.environ.get('HARNESS_SESSION_ID', ''),
        'reason': '%s: %s' % (type(exc).__name__, exc),
    }
    wrote = False
    try:
        with open(fail_file, 'a') as ff:
            json.dump(marker, ff, separators=(',',':'))
            ff.write('\n')
        wrote = True
    except Exception:
        # Even the cheap path failed. Last resort: the hook error log, with the
        # signature doctor grades FAIL.
        try:
            err_log = os.path.join(os.path.dirname(os.path.dirname(chain_file)),
                                   'telemetry', 'hook-errors.log')
            os.makedirs(os.path.dirname(err_log), exist_ok=True)
            with open(err_log, 'a') as ef:
                ef.write('%s LEDGER-APPEND-LOST tool=%s :: %s\n'
                         % (ts, marker['tool'], marker['reason']))
        except Exception:
            pass
    sys.stderr.write('[evidence-ledger] APPEND FAILED at write-chain for tool=%s :: %s%s\n'
                     % (marker['tool'], marker['reason'],
                        ' (recorded in append-failures.jsonl)' if wrote else ' (COULD NOT RECORD)'))
    ledger_unlock(lk)
    sys.exit(3)
ledger_unlock(lk)
print(f'Appended entry {next_idx}, hash={h}, prev={prev_hash}')
"
        ;;
    verify)
        CHAIN_FILE="$CHAIN_FILE" python3 -c "
import json, hashlib, os, sys
with open(os.environ['CHAIN_FILE']) as f:
    lines = [l.strip() for l in f if l.strip()]
prev = 'GENESIS'
valid = True
for i, line in enumerate(lines):
    e = json.loads(line)
    if e['prev_hash'] != prev:
        print(f'CHAIN BREAK at {i}: prev_hash mismatch', file=sys.stderr)
        valid = False
    stored = e['entry_hash']
    e['entry_hash'] = ''
    computed = hashlib.sha256(json.dumps(e, sort_keys=True, separators=(',',':')).encode()).hexdigest()
    if computed != stored:
        print(f'TAMPER at {i}: hash mismatch', file=sys.stderr)
        valid = False
    prev = stored
if valid:
    # ASCII '--', not an em dash: this prints to whatever console the operator
    # has, and cp932/cp936 consoles crash python on U+2014 (a consuming project's report).
    print(f'LEDGER INTACT -- {len(lines)} entries verified')
else:
    print('LEDGER COMPROMISED', file=sys.stderr)
    sys.exit(2)
" 2>&1
        ;;
    seal)
        # Close the segment around bad history instead of editing it (PS parity:
        # evidence-ledger.ps1 "seal"). One final entry saying why, archive the
        # file untouched as chain-NNN.jsonl, fresh chain.jsonl whose genesis
        # records the archive's name + head hash for cross-file continuity.
        if [ ! -f "$CHAIN_FILE" ]; then
            echo "[evidence-ledger] Nothing to seal -- no chain.jsonl"
            exit 0
        fi
        SEAL_REASON="${REASON_ARG:-segment sealed (no reason given)}"
        # One python process holds the lock from reading the head to the final
        # rename: an append landing between the seal entry and the archive move
        # would go into the archive after its seal, or start an unlinked chain.
        CHAIN_FILE="$CHAIN_FILE" LEDGER_DIR="$LEDGER_DIR" SEAL_REASON="$SEAL_REASON" \
            HOOK_USER="${HARNESS_USER:-}" HOOK_SESSION="${HARNESS_SESSION_ID:-}" python3 -c "$LEDGER_PY_PRELUDE
chain_file = os.environ['CHAIN_FILE']
ledger_dir = os.environ['LEDGER_DIR']
lk = ledger_lock(ledger_dir)
try:
    prev_hash, next_idx = last_link(chain_file)
    e = {'index': next_idx, 'prev_hash': prev_hash, 'entry_hash': '', 'timestamp': now_utc(),
         'actor': {'agent': 'harness', 'user': os.environ.get('HOOK_USER', ''),
                   'session_id': os.environ.get('HOOK_SESSION', ''), 'role': 'system'},
         'action': {'type': 'seal', 'tool': 'evidence-ledger', 'description': os.environ['SEAL_REASON']},
         'decision': {'result': 'allow', 'reason': 'segment sealed', 'risk_level': 'none'},
         'payload_ref': '', 'signature': ''}
    e['entry_hash'] = entry_hash(e)
    with open(chain_file, 'a') as f:
        json.dump(e, f, separators=(',', ':'))
        f.write('\n')
    # Next free archive number -- never overwrite an existing archive.
    n = 1
    for name in os.listdir(ledger_dir):
        m = re.match(r'^chain-(\d+)\.jsonl$', name)
        if m and int(m.group(1)) >= n:
            n = int(m.group(1)) + 1
    archive = 'chain-%03d.jsonl' % n
    g = {'index': 0, 'prev_hash': 'GENESIS', 'entry_hash': '', 'timestamp': now_utc(),
         'actor': {'agent': 'harness', 'user': 'system', 'session_id': 'seal', 'role': 'system'},
         'action': {'type': 'config_change', 'tool': 'evidence-ledger',
                    'description': 'Genesis block -- segment continues from ' + archive},
         'decision': {'result': 'allow', 'reason': 'segment rotation', 'risk_level': 'none'},
         'payload_ref': '', 'signature': '',
         'prev_segment': archive, 'prev_segment_head': e['entry_hash']}
    g['entry_hash'] = entry_hash(g)
    staged = os.path.join(ledger_dir, '.chain.genesis.tmp')
    with open(staged, 'w') as f:
        json.dump(g, f, separators=(',', ':'))
        f.write('\n')
    os.rename(chain_file, os.path.join(ledger_dir, archive))
    os.rename(staged, chain_file)
    print('[evidence-ledger] Sealed segment -> %s (head %s)' % (archive, e['entry_hash']))
    print('[evidence-ledger] New segment started; genesis links prev_segment_head for cross-file continuity')
finally:
    ledger_unlock(lk)
"
        ;;
    bundle)
        # Generate an evidence bundle for a change (PS parity: evidence-ledger.ps1
        # "bundle"). Field-for-field the same shape and the same
        # truthy-input-or-default fallback per field, so a bundle written on Linux
        # and one written on Windows agree byte-for-byte given the same input.
        INPUT_JSON=$(read_entry_input)
        if [ -z "$INPUT_JSON" ]; then
            echo "[evidence-ledger] No input provided for bundle" >&2
            exit 1
        fi
        TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        SESSION_ID="${HARNESS_SESSION_ID:-}"
        BUNDLE_JSON=$(printf '%s' "$INPUT_JSON" | TIMESTAMP="$TIMESTAMP" SESSION_ID="$SESSION_ID" python3 -c "
import json, os, sys, uuid

inp = json.load(sys.stdin)
if not isinstance(inp, dict):
    inp = {}

def sect(name):
    v = inp.get(name)
    return v if isinstance(v, dict) else {}

rv = sect('review_verdict')

# Same idiom as the PS bundle command: an explicitly-sent value wins, a
# missing/blank/zero one falls back to the field's default. Kept identical
# on purpose (C7) rather than 'fixed' here -- see the tracked follow-up on
# the PS side's truthy-vs-null-check gap for booleans.
def sv(d, k, default):
    v = d.get(k)
    return v if v not in (None, '', 0, False, []) else default

change_id = inp.get('change_id') or ('change-' + os.environ['TIMESTAMP'].replace('-', '').replace(':', '').replace('T', '').replace('Z', ''))

# H3-2 depth: pass the judge's per-dimension rubric through, same filter
# hard-gate.ps1 already applies when READING review_verdict (no hard-gate.sh
# exists yet -- a separate C7 gap) -- only numeric values, dimension omitted
# (not zero-filled) when the judge did not score it. rubric_scores itself is
# always present, {} when the judge gave nothing.
raw_rubric = rv.get('rubric_scores')
rubric = {}
if isinstance(raw_rubric, dict):
    for k, v in raw_rubric.items():
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            rubric[k] = float(v)

bundle = {
    'bundle_id': str(uuid.uuid4()),
    'change_id': change_id,
    'created_at': os.environ['TIMESTAMP'],
    'created_by': {
        'agent': sv(sect('created_by'), 'agent', 'unknown'),
        'user': sv(sect('created_by'), 'user', 'unknown'),
        'session_id': sv(sect('created_by'), 'session_id', os.environ.get('SESSION_ID', '')),
    },
    'requirement_trace': {
        'spec_ref': sv(sect('requirement_trace'), 'spec_ref', ''),
        'requirement_ids': sv(sect('requirement_trace'), 'requirement_ids', []),
    },
    'design_impact': {
        'description': sv(sect('design_impact'), 'description', ''),
        'affected_components': sv(sect('design_impact'), 'affected_components', []),
        'design_doc_ref': sv(sect('design_impact'), 'design_doc_ref', ''),
    },
    'code_diff': {
        'files_changed': sv(sect('code_diff'), 'files_changed', []),
        'diff_ref': sv(sect('code_diff'), 'diff_ref', ''),
        'diff_hash': sv(sect('code_diff'), 'diff_hash', ''),
    },
    'test_report': {
        'passed': sv(sect('test_report'), 'passed', 0),
        'failed': sv(sect('test_report'), 'failed', 0),
        'skipped': sv(sect('test_report'), 'skipped', 0),
        'coverage_percent': sv(sect('test_report'), 'coverage_percent', 0),
        'report_ref': sv(sect('test_report'), 'report_ref', ''),
    },
    'security_scan': {
        'scanner': sv(sect('security_scan'), 'scanner', ''),
        'findings_count': sv(sect('security_scan'), 'findings_count', 0),
        'high_critical_count': sv(sect('security_scan'), 'high_critical_count', 0),
        'passed': sv(sect('security_scan'), 'passed', True),
        'report_ref': sv(sect('security_scan'), 'report_ref', ''),
    },
    'review_verdict': {
        'verdict': sv(rv, 'verdict', 'PENDING'),
        'score': sv(rv, 'score', 0),
        'reviewer_agent': sv(rv, 'reviewer_agent', ''),
        'feedback': sv(rv, 'feedback', ''),
        'rubric_scores': rubric,
    },
    'approval_record': {
        'required': sv(sect('approval_record'), 'required', False),
        'approved_by': sv(sect('approval_record'), 'approved_by', ''),
        'approved_at': sv(sect('approval_record'), 'approved_at', ''),
        'approval_ref': sv(sect('approval_record'), 'approval_ref', ''),
    },
    'cost_telemetry': {
        'tokens_used': sv(sect('cost_telemetry'), 'tokens_used', 0),
        'estimated_cost_usd': sv(sect('cost_telemetry'), 'estimated_cost_usd', 0),
        'duration_seconds': sv(sect('cost_telemetry'), 'duration_seconds', 0),
    },
}
print(json.dumps(bundle, indent=2))
")
        # Re-derive change_id/bundle_id from the JSON itself (not from separate
        # shell variables) so the filename and the printed IDs can never disagree
        # with what was actually written.
        CHANGE_ID=$(echo "$BUNDLE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['change_id'])" 2>/dev/null)
        BUNDLE_FILE="$BUNDLE_DIR/$CHANGE_ID-bundle.json"
        printf '%s\n' "$BUNDLE_JSON" > "$BUNDLE_FILE"
        BUNDLE_ID=$(echo "$BUNDLE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['bundle_id'])" 2>/dev/null)
        echo "[evidence-ledger] Evidence bundle created: $BUNDLE_FILE"
        echo "[evidence-ledger] Bundle ID: $BUNDLE_ID"
        echo "[evidence-ledger] Change ID: $CHANGE_ID"
        printf '%s\n' "$BUNDLE_JSON"
        ;;
    *)
        echo "Usage: $0 {init|append|verify|seal|bundle}"
        exit 1
        ;;
esac
