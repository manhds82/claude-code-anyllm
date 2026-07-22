#!/usr/bin/env bash
# ============================================================
#   tests/run-tests.sh  (claude-code-anyllm)
#   Deterministic, offline test runner (bash parity of run-tests.ps1).
#   Never launches a proxy, hits a provider, or opens an editor.
#
#   Suites: policy-ci (correctness/governance), red-team (security)
#   Usage:  bash tests/run-tests.sh [policy-ci|red-team|all]
#   Exit code = number of failed checks (0 = all green).
# ============================================================
set -uo pipefail
SUITE="${1:-all}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PASS_PC=0; FAIL_PC=0; PASS_RT=0; FAIL_RT=0
c_green=$'\033[32m'; c_red=$'\033[31m'; c_cyan=$'\033[36m'; c_dim=$'\033[90m'; c_reset=$'\033[0m'

check() { # <suite> <name> <0|1 ok> [detail]
  local suite="$1" name="$2" ok="$3" detail="${4:-}"
  if [ "$ok" -eq 0 ]; then
    printf '  %sPASS%s  [%s] %s\n' "$c_green" "$c_reset" "$suite" "$name"
    [ "$suite" = policy-ci ] && PASS_PC=$((PASS_PC+1)) || PASS_RT=$((PASS_RT+1))
  else
    printf '  %sFAIL%s  [%s] %s%s\n' "$c_red" "$c_reset" "$suite" "$name" "${detail:+  -> $detail}"
    [ "$suite" = policy-ci ] && FAIL_PC=$((FAIL_PC+1)) || FAIL_RT=$((FAIL_RT+1))
  fi
}

PRODUCT_PS1=(setup-litellm.ps1 start-claude.ps1 toggle-brain.ps1)
PRODUCT_SH=(setup-litellm.sh start-claude.sh toggle-brain.sh)

has_nonascii() { LC_ALL=C od -An -tu1 -v "$1" | awk '{for(i=1;i<=NF;i++) if($i>127){f=1}} END{exit !f}'; }
has_bom()      { [ "$(head -c3 "$1" 2>/dev/null | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; }
b() { [ "$1" = true ] && echo 0 || echo 1; }   # bool -> exit-style

run_policy_ci() {
  printf '\n%s=== suite: policy-ci ===%s\n' "$c_cyan" "$c_reset"

  # 1. bash scripts pass `bash -n`
  for f in "${PRODUCT_SH[@]}"; do
    if [ ! -f "$f" ]; then check policy-ci "syntax $f" 1 missing; continue; fi
    if bash -n "$f" 2>/dev/null; then check policy-ci "syntax $f (bash -n)" 0; else check policy-ci "syntax $f (bash -n)" 1 "bash -n failed"; fi
  done

  # 1b. .ps1 parse via pwsh if present (else skip); AST correctness
  if command -v pwsh >/dev/null 2>&1; then
    for f in "${PRODUCT_PS1[@]}"; do
      [ -f "$f" ] || { check policy-ci "parse $f" 1 missing; continue; }
      if pwsh -NoProfile -Command "\$e=\$null;[void][System.Management.Automation.Language.Parser]::ParseInput([IO.File]::ReadAllText('$ROOT/$f',[Text.UTF8Encoding]::new(\$false)),[ref]\$null,[ref]\$e);exit \$e.Count" >/dev/null 2>&1; then
        check policy-ci "parse $f" 0; else check policy-ci "parse $f" 1 "pwsh parse errors"; fi
    done
  else
    check policy-ci "parse *.ps1 (pwsh)" 0 "SKIP: pwsh not on PATH"
  fi

  # 1c. .ps1 must be PS 5.1-safe: pure-ASCII OR UTF-8 BOM
  for f in "${PRODUCT_PS1[@]}"; do
    [ -f "$f" ] || continue
    if has_nonascii "$f" && ! has_bom "$f"; then
      check policy-ci "ps1 PS5.1-safe encoding: $f" 1 "non-ASCII without UTF-8 BOM"
    else
      check policy-ci "ps1 PS5.1-safe encoding: $f" 0
    fi
  done

  # 2. profiles/*.json valid + described
  local anyp=1
  for pf in profiles/*.json; do
    [ -f "$pf" ] || continue
    anyp=0
    local okj=1
    if command -v python3 >/dev/null 2>&1; then python3 -c "import json,sys;d=json.load(open(sys.argv[1], encoding='utf-8'));sys.exit(0 if d.get('description') else 1)" "$pf" 2>/dev/null && okj=0
    elif command -v python >/dev/null 2>&1; then python  -c "import json,sys;d=json.load(open(sys.argv[1], encoding='utf-8'));sys.exit(0 if d.get('description') else 1)" "$pf" 2>/dev/null && okj=0
    else grep -q '"description"' "$pf" && head -c1 "$pf" | grep -q '{' && okj=0; fi
    check policy-ci "profile valid+described: $(basename "$pf")" "$okj"
  done
  check policy-ci "profiles/ has JSON files" "$anyp"

  # 3. generated config references env key + has model_name
  check policy-ci "config has model_name"       "$(b "$(grep -q 'model_name:' config/litellm_config.yaml && echo true || echo false)")"
  check policy-ci "config key via os.environ"   "$(b "$(grep -Eq 'api_key:[[:space:]]*os\.environ/' config/litellm_config.yaml && echo true || echo false)")"

  # 4. .gitignore / .gitattributes
  check policy-ci ".gitignore ignores .venv"    "$(b "$(grep -Eq '^\.venv/' .gitignore && echo true || echo false)")"
  check policy-ci ".gitignore ignores .env"     "$(b "$(grep -Eq '^\.env' .gitignore && echo true || echo false)")"
  check policy-ci ".gitattributes *.sh eol=lf"  "$(b "$(grep -Eq '\*\.sh[[:space:]]+text[[:space:]]+eol=lf' .gitattributes && echo true || echo false)")"

  # 5. cross-platform flag parity
  local feats="list:--list stop:--stop port:--port model:--model key:--key base-url:--base-url provider:--provider no-vscode:--no-vscode"
  declare -A psTok=( [list]='$List' [stop]='$Stop' [port]='$Port' [model]='$Model' [key]='$Key' [base-url]='$BaseUrl' [provider]='$Provider' [no-vscode]='$NoVSCode' )
  for pair in $feats; do
    local f="${pair%%:*}" shf="${pair#*:}"
    if grep -Fq -- "${psTok[$f]}" start-claude.ps1 && grep -Fq -- "$shf" start-claude.sh; then
      check policy-ci "parity: $f" 0; else check policy-ci "parity: $f" 1; fi
  done

  # 6. engineering docs
  check policy-ci "docs/SRS.md exists"  "$(b "$([ -f docs/SRS.md ] && echo true || echo false)")"
  check policy-ci "docs/spec.md exists" "$(b "$([ -f docs/spec.md ] && echo true || echo false)")"
}

run_red_team() {
  printf '\n%s=== suite: red-team ===%s\n' "$c_cyan" "$c_reset"
  local pat='sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'

  # 1. no secret patterns in tracked files (excluding tests/)
  local leaks=""
  while IFS= read -r f; do
    case "$f" in tests/*|.venv/*) continue;; esac
    [ -f "$f" ] || continue
    if LC_ALL=C grep -EqI "$pat" "$f" 2>/dev/null; then leaks="$leaks $f"; fi
  done < <(git ls-files 2>/dev/null)
  check red-team "no secret patterns in tracked files" "$(b "$([ -z "$leaks" ] && echo true || echo false)")" "$leaks"

  # 2. config: no literal api_key
  if grep -E 'api_key:' config/litellm_config.yaml | grep -qv 'os.environ/'; then
    check red-team "config has no literal api_key" 1; else check red-team "config has no literal api_key" 0; fi

  # 3. profiles carry no key material
  local badp=""
  for pf in profiles/*.json; do [ -f "$pf" ] || continue
    if LC_ALL=C grep -Eq 'sk-[A-Za-z0-9_-]{20,}' "$pf" || grep -Eiq '"?api[_-]?key"?[[:space:]]*:' "$pf"; then badp="$badp $(basename "$pf")"; fi
  done
  check red-team "profiles contain no key material" "$(b "$([ -z "$badp" ] && echo true || echo false)")" "$badp"

  # 4. ANTHROPIC_AUTH_TOKEN dummy only
  local authbad=0
  for f in start-claude.ps1 start-claude.sh profiles/fpt.json; do [ -f "$f" ] || continue
    if grep -q 'ANTHROPIC_AUTH_TOKEN' "$f"; then
      grep 'ANTHROPIC_AUTH_TOKEN' "$f" | grep -q 'litellm-proxy' || authbad=1
    fi
  done
  check red-team "ANTHROPIC_AUTH_TOKEN is dummy only" "$authbad"

  # 5. no remote-to-shell in product scripts
  local rex=0
  for f in "${PRODUCT_PS1[@]}" "${PRODUCT_SH[@]}"; do [ -f "$f" ] || continue
    if grep -Eiq '(curl|wget|irm|invoke-restmethod)[^|]*\|[[:space:]]*(bash|sh|iex|invoke-expression)\b' "$f"; then rex=1; fi
    if grep -Eiq 'iex[[:space:]]*\([[:space:]]*(irm|invoke-restmethod)' "$f"; then rex=1; fi
  done
  check red-team "no remote-to-shell in product scripts" "$rex"
}

[ "$SUITE" = all ] || [ "$SUITE" = policy-ci ] && run_policy_ci
[ "$SUITE" = all ] || [ "$SUITE" = red-team ]  && run_red_team

printf '\n%s=== summary ===%s\n' "$c_cyan" "$c_reset"
printf '  policy-ci  %d passed, %d failed\n' "$PASS_PC" "$FAIL_PC"
printf '  red-team   %d passed, %d failed\n' "$PASS_RT" "$FAIL_RT"
TOTALF=$((FAIL_PC+FAIL_RT)); TOTALP=$((PASS_PC+PASS_RT))
printf '  TOTAL      %d/%d passed\n' "$TOTALP" "$((TOTALP+TOTALF))"
if [ "$TOTALF" -eq 0 ]; then printf '\n%sALL GREEN%s\n' "$c_green" "$c_reset"; else printf '\n%s%d CHECK(S) FAILED%s\n' "$c_red" "$TOTALF" "$c_reset"; fi
exit "$TOTALF"
