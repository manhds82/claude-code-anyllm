#!/usr/bin/env bash
# H3 Evaluation — auto-run regression suites before a release, then gate it
# (bash parity of harness-release.ps1). Runs evaluation.suite_commands for the
# required suites -> writes test-reports.jsonl -> pushes -> asks the Portal PDP
# release gate -> only deploys if the gate returns "allow".
#   harness-release.sh                       # run + push + check gate
#   harness-release.sh "npm run deploy"      # + deploy if gate passes
set -uo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
DEPLOY_CMD="${1:-}"
POLICY="$HARNESS_ROOT/.harness/control/casan-policies.yaml"
TEL="$HARNESS_ROOT/.harness/telemetry"; mkdir -p "$TEL"
REPORT="$TEL/test-reports.jsonl"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

command -v python3 >/dev/null 2>&1 || { echo "[release] python3 required" >&2; exit 1; }

# suites -> commands (JSON) from policy
SUITES_JSON=$(POLICY="$POLICY" python3 - <<'PY'
import json,os,yaml
try: e=(yaml.safe_load(open(os.environ["POLICY"],encoding="utf-8-sig")) or {}).get("evaluation") or {}
except Exception: e={}
req=e.get("regression_suites_required") or []; cmds=e.get("suite_commands") or {}
print(json.dumps({s:cmds.get(s,"") for s in req}))
PY
)

all_green=1
for s in $(echo "$SUITES_JSON" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin).keys()))"); do
  cmd=$(echo "$SUITES_JSON" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$s',''))")
  if [ -z "$cmd" ]; then echo "[release] suite '$s' has no command -- SKIP"; continue; fi
  echo "[release] running suite '$s': $cmd"
  out=$(bash -c "$cmd" 2>&1); code=$?
  # Labelled form FIRST, same as harness-eval.sh parse_counts. Without it this
  # loop could not parse the harness's own suites at all ("Passed : 25" never
  # matches '[0-9]+ passed'), so both counters kept their defaults and the gate
  # recorded a green built from numbers no suite ever reported -- a false green
  # in the last check before a release (C10).
  passed=""; failed=""
  passed=$(printf '%s' "$out" | grep -ioE '^[[:space:]]*Passed[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  failed=$(printf '%s' "$out" | grep -ioE '^[[:space:]]*Failed[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  [ -z "$passed" ] && passed=$(printf '%s' "$out" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  [ -z "$failed" ] && failed=$(printf '%s' "$out" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | head -1)
  # Nothing parseable is NOT a pass: an unreadable suite fails the gate.
  if [ -z "$passed" ] && [ -z "$failed" ]; then passed=0; failed=1
    echo "[release] suite '$s': output not parseable -- counted as FAILED"
  fi
  passed=${passed:-0}; failed=${failed:-0}
  [ "$code" -ne 0 ] && [ "$failed" -eq 0 ] && { failed=1; passed=0; }
  [ "$failed" -gt 0 ] && all_green=0
  python3 -c "import json;print(json.dumps({'suite_name':'$s','passed':$passed,'failed':$failed,'skipped':0,'coverage_percent':0,'ts':'$NOW','triggered_by':'harness-release'}))" >> "$REPORT"
  echo "[release] suite '$s': passed=$passed failed=$failed (exit $code)"
done

push="$(dirname "$0")/push-telemetry.sh"
[ -f "$push" ] && HARNESS_ROOT="$HARNESS_ROOT" bash "$push" >/dev/null 2>&1 && echo "[release] pushed test reports to Portal"

# ask PDP release gate
decision="allow"; reason="(gate not consulted)"
CFG="$HARNESS_ROOT/.harness/portal-sync.json"
if [ -f "$CFG" ]; then
  read -r decision reason < <(CFG="$CFG" ROOT="$HARNESS_ROOT" KEY="${HARNESS_PORTAL_INGEST_KEY:-}" ALLGREEN="$all_green" AUTH_LIB="$HARNESS_ROOT/.harness/scripts/lib/harness_checkout_facts.py" python3 - <<'PY'
import os,json,urllib.request
try: cfg=json.load(open(os.environ["CFG"],encoding="utf-8-sig"))
except Exception: cfg={}
# Portal v2 P1 1.2b: the CHECKOUT credential (X-Checkout-Id + X-Checkout-Credential) when
# this machine holds one, read by the shared reader, headers only (C5); else the legacy
# shared key (X-Ingest-Key) with a once-a-day notice. Never both. Parity with the .ps1.
import re,subprocess,sys,importlib.util
def _native(p):
    m=re.match(r"^/([a-zA-Z])/(.*)$",p)
    return "%s:/%s"%(m.group(1),m.group(2)) if (m and os.name=="nt") else p
root=_native(os.environ["ROOT"])
fm=None; headers={}
try:
    lib=_native(os.environ.get("AUTH_LIB",""))
    if lib and os.path.isfile(lib):
        sp=importlib.util.spec_from_file_location("harness_checkout_facts",lib)
        fm=importlib.util.module_from_spec(sp); sp.loader.exec_module(fm)
        a=fm.checkout_auth(root)
        if a: headers={"X-Checkout-Id":a["checkout_id"],"X-Checkout-Credential":a["checkout_credential"]}
except Exception:
    headers={}
if not headers:
    key=os.environ.get("KEY") or ""
    if not key:
        kf=os.path.join(os.environ["ROOT"],".harness","portal-sync.key")
        if os.path.isfile(kf): key=open(kf,encoding="utf-8").read().strip()
    if key:
        headers={"X-Ingest-Key":key}
        try:
            w=fm.legacy_warning("harness-release") if fm else ""
            if w: sys.stderr.write(w+chr(10))
        except Exception: pass
if cfg.get("portal_url") and cfg.get("project_id") and headers:
    url=cfg["portal_url"].rstrip("/")+"/api/pdp/"+cfg["project_id"]+"/decide"
    # The REAL requester: HARNESS_USER, else git user.email; with neither, empty and the
    # server uses the member bound to the credential. The script's own name is never an
    # actor -- it travels as requested_via.
    actor=os.environ.get("HARNESS_USER") or ""
    if not actor:
        try: actor=subprocess.check_output(["git","-C",root,"config","user.email"],stderr=subprocess.DEVNULL,timeout=5).decode().strip()
        except Exception: actor=""
    body=json.dumps({"tool":"deploy","command":"release","actor":actor,"requested_via":"harness-release"}).encode()
    req=urllib.request.Request(url,data=body,method="POST",headers={"Content-Type":"application/json","User-Agent":"harness-release/1.0",**headers})
    try:
        d=json.load(urllib.request.urlopen(req,timeout=15)); print(d.get("decision","deny"), (d.get("reason","") or "-").replace(" ","_"))
    except Exception as e:
        # Tell "the PDP answered no" from "the PDP could not be reached". An explicit 403 is a
        # server refusal and never falls back to allow; 401 and network errors keep the
        # local-suite fallback (documented design, C10) but are named for what they are.
        code=getattr(e,"code",0)
        local="allow" if os.environ["ALLGREEN"]=="1" else "deny"
        if code==403:
            sys.stderr.write("[release] PDP rejected this credential (HTTP 403: revoked / disabled / not permitted) -- release refused"+chr(10))
            print("deny","PDP_rejected_this_credential_(HTTP_403)")
        elif code==401:
            sys.stderr.write("[release] PDP rejected this credential (HTTP 401: revoked / expired) -- server-side enforcement is NOT active; using local suite result"+chr(10))
            print(local,"local_suites")
        else:
            sys.stderr.write("[release] PDP not reachable -- using local suite result"+chr(10))
            print(local,"local_suites")
else:
    print("allow","gate_not_consulted")
PY
)
fi

echo "=================================================================="
echo " Release gate: $decision -- ${reason//_/ }"
echo "=================================================================="
[ "$decision" != "allow" ] && { echo "[release] BLOCKED. Fix tests / get approval, then re-run."; exit 1; }
if [ -n "$DEPLOY_CMD" ]; then echo "[release] gate passed -- deploying: $DEPLOY_CMD"; bash -c "$DEPLOY_CMD"; exit $?; fi
echo "[release] gate passed -- safe to release."; exit 0
