#!/usr/bin/env bash
# H7 Orchestration — resolve next model in the fallback ladder (bash parity of
# harness-model-fallback.ps1). Reads casan-policies orchestration.model_fallback.
#   harness-model-fallback.sh <profile> [failed-model]
# Prints the chosen model id (empty if the ladder is exhausted).
set -euo pipefail

PROFILE="${1:-}"
FAILED="${2:-}"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
POL="$HARNESS_ROOT/.harness/control/casan-policies.yaml"

if [ -z "$PROFILE" ]; then echo "usage: harness-model-fallback.sh <profile> [failed]" >&2; exit 2; fi
command -v python3 >/dev/null 2>&1 || { echo ""; exit 0; }

POL="$POL" PROFILE="$PROFILE" FAILED="$FAILED" python3 - <<'PY'
import os, sys, yaml
try:
    pol = yaml.safe_load(open(os.environ["POL"], encoding="utf-8-sig")) or {}
except Exception:
    print(""); sys.exit(0)
profile = os.environ["PROFILE"]; failed = os.environ.get("FAILED", "")
ladder = ((pol.get("orchestration") or {}).get("model_fallback") or {}).get(profile) or []
if not ladder:
    print("")
elif not failed:
    print(ladder[0])
elif failed in ladder:
    i = ladder.index(failed)
    print(ladder[i + 1] if i + 1 < len(ladder) else "")
else:
    print(ladder[0])
PY
