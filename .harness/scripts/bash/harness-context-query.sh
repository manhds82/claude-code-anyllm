#!/usr/bin/env bash
# H1 Context Harness — retrieve most relevant context chunks for a query
# (RAG-lite / semantic cache; bash parity). Thin wrapper over
# scripts/lib/harness_rag.py. BM25 by default; neural if HARNESS_EMBED_CMD set.
#   harness-context-query.sh "how is the ingest key validated" [k]
set -euo pipefail

Q="${1:-}"
K="${2:-5}"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LIB="$HARNESS_ROOT/.harness/scripts/lib/harness_rag.py"

[ -z "$Q" ] && { echo "usage: harness-context-query.sh \"question\" [k]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "[rag] python3 not found" >&2; exit 0; }
[ -f "$LIB" ] || { echo "[rag] core not found: $LIB" >&2; exit 0; }

HARNESS_ROOT="$HARNESS_ROOT" python3 "$LIB" query "$Q" --root "$HARNESS_ROOT" --k "$K"
