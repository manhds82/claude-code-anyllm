#!/usr/bin/env bash
# Flip the "which Claude account is active on this machine" pointer (H6 attribution).
# Bash parity for harness-switch-account.ps1 (C7).
#
# Run this THE INSTANT you finish re-authenticating Claude Code to a different account.
# Overwrites a GLOBAL (not per-project) pointer file at ~/.harness/active-account.local.json
# -- global because Claude Code's login is a singleton per OS user, and this maintainer runs
# many project checkouts on one machine: a per-project pointer would mean repeating the switch
# in every checkout, defeating the "one command, sub-second" goal.
#
# agentops-sampler.sh reads this file fresh on every SubagentStop and stamps its value onto
# each telemetry record as "active_account". No network call.
set -euo pipefail

RAW_ACCOUNT="${1:-}"
if [ -z "$RAW_ACCOUNT" ]; then
    echo "Usage: harness-switch-account.sh <account-email>" >&2
    exit 1
fi

HARNESS_USER_DIR="${HOME}/.harness"
mkdir -p "$HARNESS_USER_DIR"
POINTER_FILE="$HARNESS_USER_DIR/active-account.local.json"

# Values passed via env, never string-interpolated into the python literal -- a stray
# quote/backslash in the account string must never break out of the script (same
# discipline agentops-sampler.sh uses for the untrusted hook JSON).
HARNESS_POINTER_FILE="$POINTER_FILE" HARNESS_NEW_ACCOUNT="$RAW_ACCOUNT" python3 - <<'PY'
import json, os
from datetime import datetime, timezone

pointer_file = os.environ["HARNESS_POINTER_FILE"]
new_account = os.environ["HARNESS_NEW_ACCOUNT"].strip()

# Read the CURRENT value first so the echo can report what we're switching FROM.
# A corrupted/unreadable pointer is treated as "no prior value" -- it must never
# block the switch itself.
old_account = "(none)"
if os.path.isfile(pointer_file):
    try:
        with open(pointer_file, "r", encoding="utf-8-sig") as f:
            prev = json.load(f)
        v = prev.get("active_account")
        if v:
            old_account = v
    except Exception:
        pass  # corrupted pointer -- fall through with "(none)"

record = {
    "active_account": new_account,
    "set_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}

# Atomic overwrite: temp file in the SAME directory (same-volume rename is atomic),
# then os.replace onto the real path -- a sampler reading concurrently from another
# process never observes a half-written file. Plain utf-8, no BOM (python never adds one).
tmp_file = pointer_file + ".tmp." + str(os.getpid())
with open(tmp_file, "w", encoding="utf-8") as f:
    f.write(json.dumps(record, separators=(",", ":")))
os.replace(tmp_file, pointer_file)

print("{0} -> {1}".format(old_account, new_account))
PY
