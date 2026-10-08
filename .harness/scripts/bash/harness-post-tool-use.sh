#!/usr/bin/env bash
# PostToolUse hook (POSIX parity of harness-post-tool-use.ps1). Appends a
# telemetry line for each completed tool call. Reads the hook JSON on stdin.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TEL="$HARNESS_ROOT/.harness/telemetry"
mkdir -p "$TEL"

# W1-4 parity of Write-HookError (harness-post-tool-use.ps1): one line per
# swallowed failure into hook-errors.log. "Never fail the tool call" had rotted
# into "never tell anyone" -- this repo's ledger was dead for 14 days with zero
# trace because every error path ended in /dev/null. Record, then carry on.
hook_error() {
  { printf '{"timestamp":"%s","hook":"post-tool-use","error":"' "$(date +%Y-%m-%dT%H:%M:%S%z)"
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
    printf '"}\n'
  } >> "$TEL/hook-errors.log" 2>/dev/null || true
}
INPUT="$(cat || true)"
[ -n "$INPUT" ] || exit 0

PY="$(command -v python3 || command -v python || true)"
if [ -n "$PY" ]; then
  # Pass the hook JSON via env (the heredoc already occupies python's stdin).
  HARNESS_HOOK_INPUT="$INPUT" "$PY" - "$TEL/tool-calls.log" "${HARNESS_SESSION_ID:-}" <<'PY'
import os, json, sys, datetime
log, sid = sys.argv[1], sys.argv[2]
try:
    d = json.loads(os.environ.get("HARNESS_HOOK_INPUT", ""))
except Exception:
    sys.exit(0)
rec = {
    "timestamp": datetime.datetime.now().astimezone().isoformat(),
    "agent": d.get("agent"),
    "tool": d.get("tool_name") or d.get("tool"),
    "success": d.get("success"),
    "session_id": sid,
}
open(log, "a", encoding="utf-8").write(json.dumps(rec) + "\n")
PY

  # C9: every side-effect tool call appends one line to the evidence ledger
  # (identity + input/output hash). Best-effort — never fail the hook on it.
  LEDGER="$HARNESS_ROOT/.harness/scripts/bash/evidence-ledger.sh"
  if [ -f "$LEDGER" ]; then
    ENTRY=$(HARNESS_HOOK_INPUT="$INPUT" HOOK_SESSION="${HARNESS_SESSION_ID:-}" HOOK_USER="${HARNESS_USER:-${USER:-}}" "$PY" - <<'PY' 2>/dev/null || true
import os, json, hashlib
try:
    d = json.loads(os.environ.get("HARNESS_HOOK_INPUT", ""))
except Exception:
    raise SystemExit(0)
tool = d.get("tool_name") or d.get("tool") or ""
tin = json.dumps(d.get("tool_input") or d.get("input") or {}, sort_keys=True)
tout = json.dumps(d.get("tool_response") or d.get("output") or {}, sort_keys=True, default=str)
print(json.dumps({
    "actor": {"agent": d.get("agent") or "claude-code", "user": os.environ.get("HOOK_USER", ""), "session_id": os.environ.get("HOOK_SESSION", ""), "role": "member"},
    "action": {"type": "tool_call", "tool": tool, "description": "completed tool call",
               "input_hash": hashlib.sha256(tin.encode()).hexdigest(),
               "output_hash": hashlib.sha256(tout.encode()).hexdigest()},
    "decision": {"result": "allow", "reason": "completed", "risk_level": "none"},
}))
PY
)
    if [ -n "$ENTRY" ]; then
      # Failures and stalls both land in hook-errors.log (same contract as the
      # PowerShell hook). SECONDS gives whole-second granularity, which is enough:
      # a healthy append is a tail-read plus one write -- if it takes 3+ seconds
      # the chain holds something pathological, and that early warning is exactly
      # what 14 silent days lacked.
      _t0=$SECONDS
      if LEDGER_OUT="$(bash "$LEDGER" append --entry-json "$ENTRY" 2>&1)"; then
        _dt=$((SECONDS - _t0))
        [ "$_dt" -ge 3 ] && hook_error "ledger append took ${_dt}s (expected <1s) -- chain may hold an oversized entry"
      else
        hook_error "ledger append failed for this call :: $(printf '%.300s' "$LEDGER_OUT")"
      fi
    fi
  fi

  # --- H3/H5: qa-gate verdict gates the release-affecting tools (C2/C10) ------
  # POSIX parity of harness-post-tool-use.ps1. Runs LAST, after telemetry and the
  # ledger entry: a denied call still happened, and omitting it from the evidence
  # trail would hide exactly the events an auditor came for.
  #
  # Enable flag and tool list come from casan-policies.yaml, never from here.
  # Default off -- a project on the legacy 3-stage DAG has no qa-gate stage and
  # so no verdict, and blocking every commit there would be a breaking change
  # shipped as a bugfix. Once enabled, a missing verdict fails CLOSED.
  GATE_OUT="$(HOOK_TOOL="$(printf '%s' "$INPUT" | "$PY" -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tool_name") or d.get("tool") or "")' 2>/dev/null || true)" \
    HARNESS_ROOT="$HARNESS_ROOT" "$PY" - <<'PY' 2>/dev/null || true
import os, re, sys
root = os.environ["HARNESS_ROOT"]
tool = os.environ.get("HOOK_TOOL", "")
policy = os.path.join(root, ".harness", "control", "casan-policies.yaml")
ctx = os.path.join(root, ".harness", "context", "pipeline-context.yaml")

enabled, blocking, in_gate = False, [], False
try:
    with open(policy, encoding="utf-8-sig") as f:
        for line in f:
            if re.match(r"^\s{2}qa_gate:\s*$", line):
                in_gate = True
                continue
            if in_gate:
                if line.strip() and not re.match(r"^\s{4}", line):
                    in_gate = False
                    continue
                m = re.match(r"^\s{4}enabled:\s*(\S+)", line)
                if m:
                    enabled = m.group(1).strip().lower() in ("true", "yes", "1")
                m = re.match(r'^\s{6}-\s*"?([A-Za-z0-9_.\-]+)"?', line)
                if m:
                    blocking.append(m.group(1))
except OSError:
    raise SystemExit(0)          # no policy file -> nothing was ever enabled

if not (enabled and tool and tool in blocking):
    raise SystemExit(0)

verdict, vpath = "", "artifacts/qa-gate/<pipeline_id>-verdict.md"
try:
    with open(ctx, encoding="utf-8-sig") as f:
        for line in f:
            m = re.match(r'^\s*qa_gate_verdict:\s*"?([A-Za-z_]+)"?', line)
            if m and not verdict:
                verdict = m.group(1)
            m = re.match(r'^\s*qa_gate_verdict_path:\s*"?([^"\r\n]+)"?', line)
            if m:
                vpath = m.group(1).strip()
except OSError:
    pass                          # absent context with the gate ON = fail closed

if verdict != "APPROVED":
    if not verdict:
        print("qa-gate block: verdict missing -- fail-closed. The gate is enabled in "
              "casan-policies.yaml but pipeline-context.yaml carries no qa_gate_verdict. "
              "Run the qa-gate stage, or set governance.qa_gate.enabled: false.")
    else:
        print("qa-gate block: verdict=%s (needs APPROVED) for tool '%s'. Resolve at %s."
              % (verdict, tool, vpath))
    print("This is a LOCAL hook -- defense-in-depth, not a boundary. Release actions "
          "need server-side enforcement at the gateway (C10).")
    raise SystemExit(9)           # 9 = "deny" signal to the shell below
PY
)"
  # SystemExit(9) from the block above leaves its message in GATE_OUT; a non-empty
  # GATE_OUT is therefore the deny signal. Checking the text rather than $? keeps
  # this working under `set -e` with the `|| true` guard above.
  if [ -n "$GATE_OUT" ]; then
    printf '%s\n' "$GATE_OUT" >&2
    exit 2
  fi
fi
exit 0
