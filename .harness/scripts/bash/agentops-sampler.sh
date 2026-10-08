#!/usr/bin/env bash
# AgentOps Sampler (bash parity) — records agent run metrics (H6).
#
# Fired on SubagentStop (and invoked from harness-session-end.sh on SessionEnd)
# with the Claude Code hook JSON on stdin. The hook payload does NOT carry
# token counts directly — it carries a transcript_path. Real token usage is
# summed from the transcript JSONL (assistant messages carry message.usage),
# which is the only honest source (C10): no numbers are fabricated.
set -euo pipefail

HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TELEMETRY_DIR="$HARNESS_ROOT/.harness/telemetry"
mkdir -p "$TELEMETRY_DIR"

INPUT_JSON=""
if [ ! -t 0 ]; then
    INPUT_JSON=$(cat)
fi

if [ -z "$INPUT_JSON" ]; then
    exit 0
fi

LOG_FILE="$TELEMETRY_DIR/agentops.log"

# Hook JSON via env — NEVER string-interpolate untrusted JSON into a python
# literal (breaks on quotes/backslashes and is a code-injection hole).
HARNESS_HOOK_INPUT="$INPUT_JSON" \
HARNESS_AGENTOPS_LOG="$LOG_FILE" \
HARNESS_SESSION="${HARNESS_SESSION_ID:-}" \
python3 - <<'PY' 2>&1 || true
import json, os, sys
from datetime import datetime, timezone

try:
    event = json.loads(os.environ.get("HARNESS_HOOK_INPUT", ""))
except Exception:
    sys.exit(0)

now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
log_file = os.environ["HARNESS_AGENTOPS_LOG"]

agent = event.get("agent_name") or event.get("agent_type") or event.get("agent") or (
    "subagent" if event.get("hook_event_name") == "SubagentStop" else "main"
)
session = event.get("session_id") or os.environ.get("HARNESS_SESSION", "") or "unknown"
status = event.get("status", "completed")

# --- Real usage: sum the transcript (the only place token counts exist) ---
transcript = event.get("agent_transcript_path") or event.get("transcript_path") or ""
# Fallback: some launchers don't pass transcript_path -- locate by session id
# under the standard Claude Code projects dir so sampling still works.
if (not transcript or not os.path.isfile(transcript)) and session and session != "unknown":
    import glob
    home = os.environ.get("HOME") or os.environ.get("USERPROFILE") or os.path.expanduser("~")
    matches = glob.glob(os.path.join(home, ".claude", "projects", "*", session + ".jsonl"))
    if matches:
        transcript = matches[0]
tokens_in = tokens_out = tool_calls = 0
model = ""
first_ts = last_ts = None

if transcript and os.path.isfile(transcript):
    usage_by_msg = {}   # message id -> usage dict (last one wins; streamed
                        # chunks repeat the same id with identical totals)
    try:
        with open(transcript, "r", encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = rec.get("timestamp")
                if ts:
                    first_ts = first_ts or ts
                    last_ts = ts
                msg = rec.get("message") or {}
                if rec.get("type") != "assistant" or not isinstance(msg, dict):
                    continue
                usage = msg.get("usage") or {}
                mid = msg.get("id")
                # Dedupe by real message id only (streamed chunks repeat it).
                # Never fall back to a positional key -- that counts every
                # message separately and multi-counts a session's tokens.
                if usage and mid:
                    usage_by_msg[mid] = usage
                if msg.get("model") and msg.get("model") != "<synthetic>":
                    model = msg["model"]
                for block in msg.get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "tool_use":
                        tool_calls += 1
    except OSError:
        pass
    # tokens_in = NEW input only (uncached input + newly-created cache).
    # cache_read_input_tokens is EXCLUDED on purpose: it's the same context
    # re-read each turn, so summing over N turns multi-counts the same tokens
    # (a 7000-turn session produced 1.6B phantom tokens). Cache reads are cheap
    # re-reads, not new work.
    for u in usage_by_msg.values():
        tokens_in += int(u.get("input_tokens") or 0) \
                   + int(u.get("cache_creation_input_tokens") or 0)
        tokens_out += int(u.get("output_tokens") or 0)

# Legacy fallback: explicit numeric fields on the event itself
if tokens_in == 0 and tokens_out == 0:
    def _num(*keys):
        for k in keys:
            v = event.get(k)
            if isinstance(v, (int, float)) and not isinstance(v, bool):
                return int(v)
        return 0
    tokens_in = _num("tokens_in", "input_tokens")
    tokens_out = _num("tokens_out", "output_tokens")
    if not tool_calls:
        tool_calls = _num("tool_calls", "tool_calls_count")

if not model:
    m = event.get("model")
    model = m if isinstance(m, str) else "unknown"

latency_ms = 0
if first_ts and last_ts:
    try:
        t0 = datetime.fromisoformat(first_ts.replace("Z", "+00:00"))
        t1 = datetime.fromisoformat(last_ts.replace("Z", "+00:00"))
        span = int((t1 - t0).total_seconds() * 1000)
        # A resumed session's transcript spans days -- not a meaningful
        # latency. Cap at 6h; larger = a resume, report 0.
        latency_ms = span if 0 <= span <= 21600000 else 0
    except ValueError:
        pass

# Rough public-list-price estimate (non-cache rates); it is labeled estimated.
cost = (tokens_in / 1_000_000 * 3.0) + (tokens_out / 1_000_000 * 15.0)

# --- Attribution stamps: WHICH Claude account, WHICH human. Two independent axes --
# one human can hold two accounts; two humans can in principle share a machine -- so
# neither is inferred from the other. Read fresh every run: this whole script is a
# brand-new process per SubagentStop, so "fresh" is automatic. Absent/unreadable ->
# empty string, NEVER raise: this hook fires on every SubagentStop and must not break
# a developer's session over a missing/stale pointer file (C10).
active_account = ""
_home = os.environ.get("HOME") or os.environ.get("USERPROFILE") or os.path.expanduser("~")
_pointer_file = os.path.join(_home, ".harness", "active-account.local.json")
if os.path.isfile(_pointer_file):
    try:
        with open(_pointer_file, "r", encoding="utf-8-sig") as pf:
            _pointer = json.load(pf)
        active_account = _pointer.get("active_account") or ""
    except Exception:
        pass  # corrupted/unreadable pointer -- fail OPEN to empty string

active_member = os.environ.get("HARNESS_USER") or ""

record = {
    "timestamp": now,
    "agent_name": agent,
    "model": model,
    "session_id": session,
    "status": status,
    "tokens_in": tokens_in,
    "tokens_out": tokens_out,
    "total_tokens": tokens_in + tokens_out,
    "estimated_cost_usd": round(cost, 6),
    "latency_ms": latency_ms,
    "tool_calls": tool_calls,
    "start_time": first_ts or now,
    "end_time": last_ts or now,
    "active_account": active_account,
    "active_member": active_member,
    # WHICH assistant produced this line (B9a). A literal, not config: this
    # script IS the Claude Code sampler -- it runs from a Claude Code hook and
    # reads a Claude Code transcript, so the value is a fact about the writer,
    # not a rule to be looked up. A collector for another assistant stamps its
    # own value; the ingest defaults a MISSING stamp to claude-code, so an
    # un-upgraded machine still lands in the right bucket.
    "assistant": "claude-code",
}

with open(log_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
print(f"[agentops] Recorded {agent}: {record['total_tokens']} tokens, ${cost:.4f}")
PY
exit 0
