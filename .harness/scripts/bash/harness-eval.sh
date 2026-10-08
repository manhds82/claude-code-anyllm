#!/usr/bin/env bash
# H3 evaluation runner (bash parity of harness-eval.ps1): run a project's REAL
# test suites and append honest pass/fail/skip to .harness/telemetry/test-reports.jsonl.
# Sources: casan-policies.yaml evaluation.suite_commands (declared) else auto-detect
# pytest (when it collects >0) / npm test. A suite with no parseable counts writes
# NO report — never fabricate a green run (C10).
set -uo pipefail
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TEL="$HARNESS_ROOT/.harness/telemetry"
POLICY="$HARNESS_ROOT/.harness/control/casan-policies.yaml"
mkdir -p "$TEL"
REPORT="$TEL/test-reports.jsonl"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
QUIET=0; [ "${1:-}" = "--quiet" ] && QUIET=1
say() { [ "$QUIET" -eq 1 ] || echo "$@"; }

# Parse pass/fail/skip from suite output. Echoes "P F S" or nothing.
parse_counts() {
  local text="$1" p f s
  p=$(printf '%s' "$text" | grep -ioE '^[[:space:]]*Passed[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  f=$(printf '%s' "$text" | grep -ioE '^[[:space:]]*Failed[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  s=$(printf '%s' "$text" | grep -ioE '^[[:space:]]*Skipped[[:space:]]*:[[:space:]]*[0-9]+' | grep -oE '[0-9]+' | head -1)
  [ -z "$p" ] && p=$(printf '%s' "$text" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | head -1)
  [ -z "$f" ] && f=$(printf '%s' "$text" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | head -1)
  [ -z "$s" ] && s=$(printf '%s' "$text" | grep -oE '[0-9]+ skipped' | grep -oE '[0-9]+' | head -1)
  [ -z "$p" ] && [ -z "$f" ] && return 1
  echo "${p:-0} ${f:-0} ${s:-0}"
}

declare -a NAMES CMDS
# 1. Declared suite_commands
if [ -f "$POLICY" ]; then
  inblock=0; blockindent=0
  while IFS= read -r line; do
    if printf '%s' "$line" | grep -qE '^[[:space:]]*suite_commands:[[:space:]]*$'; then
      inblock=1; ws="${line%%[! ]*}"; blockindent=${#ws}; continue
    fi
    if [ "$inblock" -eq 1 ]; then
      printf '%s' "$line" | grep -qE '^[[:space:]]*$' && continue   # blank line inside block
      ws="${line%%[! ]*}"; indent=${#ws}
      # Any line indented at or above the block key ends the block. Comparing to
      # the block's own indent (not just column 0) is what stops sibling keys
      # under `evaluation:` from being picked up and executed as shell commands.
      if [ "$indent" -le "$blockindent" ]; then inblock=0; continue; fi
      if printf '%s' "$line" | grep -qE '^[[:space:]]+[A-Za-z0-9_-]+:'; then
        name=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*([A-Za-z0-9_-]+):.*/\1/')
        # Either quote style: Prettier with singleQuote rewrites "..." to '...'
        # (PS parity: harness-eval.ps1).
        cmd=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]*//; s/[[:space:]]*#.*$//; s/^"//; s/"$//'" ; s/^'//; s/'\$//")
        if [ -n "$cmd" ]; then NAMES+=("$name"); CMDS+=("$cmd"); fi
      fi
    fi
  done < "$POLICY"
fi
# 2. Auto-detect
if [ "${#NAMES[@]}" -eq 0 ]; then
  if command -v python3 >/dev/null 2>&1; then
    co=$(cd "$HARNESS_ROOT" && python3 -m pytest --co -q 2>&1)
    if [ $? -eq 0 ] && ! printf '%s' "$co" | grep -q 'no tests collected'; then
      NAMES+=("pytest"); CMDS+=("python3 -m pytest -q -p no:cacheprovider")
    fi
  fi
  if [ -f "$HARNESS_ROOT/package.json" ] && grep -qE '"test"[[:space:]]*:' "$HARNESS_ROOT/package.json"; then
    NAMES+=("npm-test"); CMDS+=("npm test --silent")
  fi
fi
if [ "${#NAMES[@]}" -eq 0 ]; then
  say "[harness-eval] No declared or auto-detected test suite — nothing to report (honest)."; exit 0
fi

json_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
written=0
for i in "${!NAMES[@]}"; do
  name="${NAMES[$i]}"; cmd="${CMDS[$i]}"
  say "[harness-eval] running $name: $cmd"
  out=$(cd "$HARNESS_ROOT" && bash -lc "$cmd" 2>&1)
  if counts=$(parse_counts "$out"); then
    read -r p f s <<< "$counts"
    cov=$(printf '%s' "$out" | grep -ioE 'TOTAL.*[0-9]+%' | grep -oE '[0-9]+' | tail -1); cov=${cov:-0}
    printf '{"suite_name":"%s","passed":%s,"failed":%s,"skipped":%s,"coverage_percent":%s,"ts":"%s","triggered_by":"harness-eval"}\n' \
      "$(json_esc "$name")" "$p" "$f" "$s" "$cov" "$TS" >> "$REPORT"
    written=$((written+1))
    say "  > $name: passed=$p failed=$f skipped=$s"
  else
    say "  ~ $name: no parseable result -> skipped (no report written)"
    first=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | head -2 | tr '\n' '|')
    say "    output began: ${first:-(the command printed nothing)}"
  fi
done
say "[harness-eval] wrote $written report(s) -> $REPORT"
exit 0
