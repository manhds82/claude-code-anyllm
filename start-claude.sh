#!/usr/bin/env bash
# ============================================================
#   start-claude.sh  (claude-code-anyllm)
#   Run Claude Code powered by ANY OpenAI-compatible LLM via a
#   local LiteLLM proxy.  macOS / Linux counterpart of start-claude.ps1
#
#   Flow:  VS Code (Claude Code) -> LiteLLM :4000 -> your provider's /v1
#
#   First time (LiteLLM not installed): runs setup-litellm.sh automatically.
# ============================================================
set -eo pipefail

# ================ EDIT THESE FOR YOUR PROVIDER ================
# OpenAI-compatible base URL (must end in /v1). Examples:
#   FPT Cloud : https://mkp-api.fptcloud.com/v1
#   OpenAI    : https://api.openai.com/v1
#   OpenRouter: https://openrouter.ai/api/v1
#   Groq      : https://api.groq.com/openai/v1
#   DeepSeek  : https://api.deepseek.com/v1
#   Ollama    : http://localhost:11434/v1
BASE_URL="https://mkp-api.fptcloud.com/v1"

# Model name exactly as the provider spells it (see options with --list).
# Pick one that supports tool/function calling so Claude Code can edit files.
MODEL="DeepSeek-V4-Flash"

# API key. Leave empty to read $LLM_API_KEY, else you'll be asked at runtime (hidden
# input). Recommended: don't hard-code it here -- export LLM_API_KEY instead.
KEY=""
# =============================================================

# Label Claude Code shows for the model (arbitrary; kept in sync automatically).
CLAUDE_ALIAS="claude-sonnet-4-6"
PORT=4000

DO_LIST=0; DO_STOP=0; NO_VSCODE=0; DO_LIST_PROVIDERS=0; DO_CHECK_KEYS=0; DO_BENCHMARK=0; DO_DASHBOARD=0
PROVIDER=""; BASE_URL_SET=0; MODEL_SET=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROVIDERS_FILE="$SCRIPT_DIR/config/providers.conf"

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_cyan" "$1" "$c_reset"; }
ok()   { printf '    %s[OK]%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s[!]%s %s\n'  "$c_yellow" "$c_reset" "$1"; }
err()  { printf '    %s[X]%s %s\n'  "$c_red" "$c_reset" "$1"; }

usage() {
  cat <<'EOF'
start-claude.sh - run Claude Code on any OpenAI-compatible LLM via LiteLLM
  ./start-claude.sh                    no flags -> interactive provider menu
                                        (built from config/providers.conf)
  ./start-claude.sh --provider nvidia  skip the menu, use this provider's id
  ./start-claude.sh --list-providers   list providers.conf and key status
  ./start-claude.sh --check-keys       test each provider's API key, then exit
  ./start-claude.sh --benchmark        run 3 test prompts; report latency + tool support
  ./start-claude.sh --dashboard        open browser to LiteLLM Swagger UI after proxy starts
  ./start-claude.sh --model NAME       use a different model for this run
  ./start-claude.sh --key KEY          use a different key for this run
  ./start-claude.sh --base-url URL     use a different endpoint for this run
  ./start-claude.sh --list             list models the endpoint exposes, then exit
  ./start-claude.sh --port N           proxy port (default 4000)
  ./start-claude.sh --stop             stop a running proxy on that port
  ./start-claude.sh --no-vscode        only start the proxy
  ./start-claude.sh --open-dir PATH    open VS Code in PATH instead of this folder
                                        (or drop open-with-claude.sh in your project)
EOF
}

OPEN_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --provider)  PROVIDER="$2"; shift 2 ;;
    --model)     MODEL="$2"; MODEL_SET=1; shift 2 ;;
    --key)       KEY="$2"; shift 2 ;;
    --base-url)  BASE_URL="$2"; BASE_URL_SET=1; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --list)      DO_LIST=1; shift ;;
    --list-providers) DO_LIST_PROVIDERS=1; shift ;;
    --check-keys) DO_CHECK_KEYS=1; shift ;;
    --benchmark)  DO_BENCHMARK=1; shift ;;
    --dashboard)  DO_DASHBOARD=1; shift ;;
    --stop)      DO_STOP=1; shift ;;
    --no-vscode) NO_VSCODE=1; shift ;;
    --open-dir)  OPEN_DIR="$2"; shift 2 ;;
    -h|--help)   usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

PROJECT_DIR="${OPEN_DIR:-$SCRIPT_DIR}"

CONFIG_PATH="$SCRIPT_DIR/config/litellm_config.yaml"
LOG_FILE="$SCRIPT_DIR/litellm-proxy.log"

# LiteLLM venv: prefer project-local .venv, else ~/litellm-env
LOCAL_VENV="$SCRIPT_DIR/.venv"
USER_VENV="$HOME/litellm-env"
if [ -x "$LOCAL_VENV/bin/litellm" ]; then VENV_PATH="$LOCAL_VENV"; else VENV_PATH="$USER_VENV"; fi
LITELLM="$VENV_PATH/bin/litellm"

# Return the configured key: inline -> $LLM_API_KEY -> prompt (hidden input).
resolve_key() {
  if [ -n "$KEY" ]; then printf '%s' "$KEY"; return 0; fi
  if [ -n "${LLM_API_KEY:-}" ]; then printf '%s' "$LLM_API_KEY"; return 0; fi
  local k=""
  if [ -r /dev/tty ]; then
    read -r -s -p "Enter API key: " k </dev/tty || true
    printf '\n' >&2
  fi
  printf '%s' "$k"
}

# Print providers.conf entries with [key set]/[no key] status.
list_providers() {
  step "Providers in config/providers.conf"
  [ -f "$PROVIDERS_FILE" ] || { err "providers.conf not found."; return 1; }
  while IFS='|' read -r id label baseurl model keyenv; do
    case "$id" in ''|\#*) continue ;; esac
    id="$(echo "$id" | xargs)"; label="$(echo "$label" | xargs)"; keyenv="$(echo "$keyenv" | xargs)"
    if [ -n "${!keyenv:-}" ]; then tag="[key set]"; else tag="[no key]"; fi
    printf '  %-8s %-38s %s   (env: %s)\n' "$id" "$label" "$tag" "$keyenv"
  done < "$PROVIDERS_FILE"
  printf '\nSet a key once:  export <KEY_ENV_NAME>="sk-..."   (add to ~/.zshrc or ~/.bashrc)\n'
  printf 'Use directly:    ./start-claude.sh --provider <id>\n'
}

# Test each provider that has a key set by calling GET /models on its endpoint.
check_keys() {
  step "Testing API keys for all providers in config/providers.conf ..."
  [ -f "$PROVIDERS_FILE" ] || { err "providers.conf not found."; return 1; }
  local ok_n=0 fail_n=0 skip_n=0
  while IFS='|' read -r id label baseurl model keyenv; do
    case "$id" in ''|\#*) continue ;; esac
    label="$(echo "$label" | xargs)"; baseurl="$(echo "$baseurl" | xargs)"
    model="$(echo "$model" | xargs)"; keyenv="$(echo "$keyenv" | xargs)"
    k="${!keyenv:-}"
    if [ -z "$k" ]; then
      printf '  %s[!]%s  %-40s no key  (set %s)\n' "$c_yellow" "$c_reset" "$label" "$keyenv"
      skip_n=$((skip_n + 1)); continue
    fi
    http_code="$(curl -o /dev/null -s -w "%{http_code}" \
      -H "Authorization: Bearer $k" --max-time 8 "$baseurl/models" 2>/dev/null || echo "000")"
    if [ "$http_code" = "200" ]; then
      printf '  %s[OK]%s %-40s %s\n' "$c_green" "$c_reset" "$label" "$model"
      ok_n=$((ok_n + 1))
    elif [ "$http_code" = "401" ] || [ "$http_code" = "403" ]; then
      printf '  %s[X]%s  %-40s HTTP %s — key không hợp lệ\n' "$c_red" "$c_reset" "$label" "$http_code"
      fail_n=$((fail_n + 1))
    elif [ "$http_code" = "429" ]; then
      printf '  %s[!]%s  %-40s 429 rate limit (key OK, thử lại sau)\n' "$c_yellow" "$c_reset" "$label"
      ok_n=$((ok_n + 1))
    elif [ "$http_code" = "404" ]; then
      printf '  %s[?]%s  %-40s /models không tồn tại (thử thủ công)\n' "$c_yellow" "$c_reset" "$label"
      ok_n=$((ok_n + 1))
    else
      printf '  %s[X]%s  %-40s HTTP %s — lỗi kết nối\n' "$c_red" "$c_reset" "$label" "$http_code"
      fail_n=$((fail_n + 1))
    fi
  done < "$PROVIDERS_FILE"
  printf '\nKết quả: %s OK, %s lỗi, %s chưa có key\n' "$ok_n" "$fail_n" "$skip_n"
}

# Run 3 test prompts against the configured endpoint; report latency + tool-call support.
run_benchmark() {
  local label="${SELECTED_LABEL:-$MODEL}"
  step "Benchmarking $label ..."
  printf '  %-22s %8s  %5s  %s\n' "Test" "Time" "Toks" "Result"
  printf '  %s\n' "$(printf '%0.s-' {1..56})"

  _bench() {
    local name="$1" prompt="$2" max_tok="$3" tool_test="${4:-0}"
    local body result http_code start_s end_s elapsed

    body="$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s}' \
      "$MODEL" "$prompt" "$max_tok")"

    if [ "$tool_test" -eq 1 ]; then
      body="$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s,"tools":[{"type":"function","function":{"name":"list_dir","description":"List files","parameters":{"type":"object","properties":{"path":{"type":"string"}}}}}],"tool_choice":"auto"}' \
        "$MODEL" "$prompt" "$max_tok")"
    fi

    start_s="$(date +%s)"
    result="$(curl -s -w '\n%{http_code}' -X POST \
      -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
      -d "$body" --max-time 30 "$BASE_URL/chat/completions" 2>/dev/null)"
    end_s="$(date +%s)"
    elapsed=$((end_s - start_s))
    http_code="$(printf '%s' "$result" | tail -1)"

    if [ "$http_code" = "200" ]; then
      local toks=""
      if command -v jq >/dev/null 2>&1; then
        toks="$(printf '%s' "$result" | head -1 | jq -r '.usage.completion_tokens // "?"' 2>/dev/null)"
      fi
      if [ "$tool_test" -eq 1 ]; then
        local has_tool=0
        if command -v jq >/dev/null 2>&1; then
          has_tool="$(printf '%s' "$result" | head -1 | jq -r '.choices[0].message.tool_calls // [] | length' 2>/dev/null || echo 0)"
        else
          has_tool="$(printf '%s' "$result" | head -1 | grep -c '"tool_calls"' 2>/dev/null || echo 0)"
        fi
        if [ "${has_tool:-0}" -gt 0 ]; then
          printf '  %-22s %6ds  %5s  %s[OK]%s tool call\n' "$name" "$elapsed" "${toks:-?}" "$c_green" "$c_reset"
        else
          printf '  %-22s %6ds  %5s  %s[!]%s text only — model may not edit files\n' "$name" "$elapsed" "${toks:-?}" "$c_yellow" "$c_reset"
        fi
      else
        printf '  %-22s %6ds  %5s  %s[OK]%s\n' "$name" "$elapsed" "${toks:-?}" "$c_green" "$c_reset"
      fi
    else
      printf '  %-22s FAIL        HTTP %s\n' "$name" "$http_code"
    fi
  }

  _bench "Ping"      "Reply with the single word: PONG"                       5  0
  _bench "Code gen"  "Shortest Python one-liner to reverse a string."         60 0
  _bench "Tool call" "What files are in the current directory?"               80 1
}

# Resolve a provider into SELECTED_BASE_URL / SELECTED_MODEL / SELECTED_KEYENV /
# SELECTED_LABEL. Pass an id to look it up directly, or "" for an interactive menu.
select_provider() {
  local want_id="$1"
  [ -f "$PROVIDERS_FILE" ] || return 1

  if [ -n "$want_id" ]; then
    while IFS='|' read -r id label baseurl model keyenv; do
      case "$id" in ''|\#*) continue ;; esac
      id="$(echo "$id" | xargs)"
      if [ "$id" = "$want_id" ]; then
        SELECTED_BASE_URL="$(echo "$baseurl" | xargs)"
        SELECTED_MODEL="$(echo "$model" | xargs)"
        SELECTED_KEYENV="$(echo "$keyenv" | xargs)"
        SELECTED_LABEL="$(echo "$label" | xargs)"
        return 0
      fi
    done < "$PROVIDERS_FILE"
    return 1
  fi

  step "Choose a provider (config/providers.conf)"
  local ids=() labels=() urls=() models=() keyenvs=() i=0
  while IFS='|' read -r id label baseurl model keyenv; do
    case "$id" in ''|\#*) continue ;; esac
    id="$(echo "$id" | xargs)"; label="$(echo "$label" | xargs)"
    baseurl="$(echo "$baseurl" | xargs)"; model="$(echo "$model" | xargs)"; keyenv="$(echo "$keyenv" | xargs)"
    ids+=("$id"); labels+=("$label"); urls+=("$baseurl"); models+=("$model"); keyenvs+=("$keyenv")
    i=$((i + 1))
    if [ -n "${!keyenv:-}" ]; then tag="[key set]"; else tag="[no key]"; fi
    printf '  %d. %-38s %s\n' "$i" "$label" "$tag"
  done < "$PROVIDERS_FILE"
  [ "$i" -eq 0 ] && return 1

  choice=""
  if [ -r /dev/tty ]; then read -r -p $'\nPick a number (Enter = 1): ' choice </dev/tty || true; fi
  [ -z "$choice" ] && choice=1
  idx=$((choice - 1))
  if [ "$idx" -lt 0 ] || [ "$idx" -ge "$i" ]; then return 1; fi
  SELECTED_BASE_URL="${urls[$idx]}"
  SELECTED_MODEL="${models[$idx]}"
  SELECTED_KEYENV="${keyenvs[$idx]}"
  SELECTED_LABEL="${labels[$idx]}"
}

# Is something listening on the given TCP port?
port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti "tcp:$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

# ---------- Mode --list-providers ----------
if [ "$DO_LIST_PROVIDERS" -eq 1 ]; then
  list_providers
  exit 0
fi

# ---------- Mode --check-keys ----------
if [ "$DO_CHECK_KEYS" -eq 1 ]; then
  check_keys
  exit 0
fi

# ---------- Mode --list ----------
if [ "$DO_LIST" -eq 1 ]; then
  KEY="$(resolve_key)"
  [ -z "$KEY" ] && { err "No API key. Aborting."; exit 1; }
  step "Fetching models from $BASE_URL/models ..."
  resp="$(curl -fsS -H "Authorization: Bearer $KEY" "$BASE_URL/models" 2>/dev/null || true)"
  if [ -z "$resp" ]; then err "GET /models failed (check key, base URL, network)."; exit 1; fi
  if command -v jq >/dev/null 2>&1; then
    echo "$resp" | jq -r '.data[].id' | sort | sed 's/^/    - /'
  else
    echo "$resp" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed -E 's/.*"([^"]*)"$/    - \1/' | sort -u
  fi
  exit 0
fi

# ---------- Mode --stop ----------
if [ "$DO_STOP" -eq 1 ]; then
  step "Looking for the process on port $PORT ..."
  pids=""
  if command -v lsof >/dev/null 2>&1; then
    pids="$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null || true)"
  elif command -v fuser >/dev/null 2>&1; then
    pids="$(fuser "$PORT/tcp" 2>/dev/null || true)"
  fi
  if [ -z "$pids" ]; then
    warn "No process is listening on port $PORT."
  else
    for pid in $pids; do
      if kill "$pid" 2>/dev/null; then ok "Stopped PID $pid."; else err "Could not stop PID $pid."; fi
    done
  fi
  exit 0
fi

# ---------- 0. Resolve provider (--provider, or an interactive menu) ----------
# Skipped entirely if the caller passed --base-url and/or --model explicitly --
# those always win over providers.conf.
if [ -n "$PROVIDER" ]; then
  if ! select_provider "$PROVIDER"; then
    err "Provider '$PROVIDER' not found. Run --list-providers to see valid ids."
    exit 1
  fi
  [ "$BASE_URL_SET" -eq 0 ] && BASE_URL="$SELECTED_BASE_URL"
  [ "$MODEL_SET" -eq 0 ] && MODEL="$SELECTED_MODEL"
  [ -z "$KEY" ] && KEY="${!SELECTED_KEYENV:-}"
  ok "Provider: $SELECTED_LABEL"
elif [ "$BASE_URL_SET" -eq 0 ] && [ "$MODEL_SET" -eq 0 ] && [ -f "$PROVIDERS_FILE" ]; then
  if ! select_provider ""; then
    err "Invalid choice."
    exit 1
  fi
  BASE_URL="$SELECTED_BASE_URL"
  MODEL="$SELECTED_MODEL"
  [ -z "$KEY" ] && KEY="${!SELECTED_KEYENV:-}"
  ok "Provider: $SELECTED_LABEL"
fi

# ---------- 1. Check the venv (auto-install if missing) ----------
step "Checking the LiteLLM virtual env ..."
if [ ! -x "$LITELLM" ]; then
  warn "LiteLLM not found. Trying to install it via setup-litellm.sh ..."
  if [ -x "$SCRIPT_DIR/setup-litellm.sh" ]; then
    "$SCRIPT_DIR/setup-litellm.sh"
  elif [ -f "$SCRIPT_DIR/setup-litellm.sh" ]; then
    bash "$SCRIPT_DIR/setup-litellm.sh"
  fi
  if [ -x "$LOCAL_VENV/bin/litellm" ]; then VENV_PATH="$LOCAL_VENV"; LITELLM="$VENV_PATH/bin/litellm"; fi
  if [ ! -x "$LITELLM" ]; then err "LiteLLM still missing. Run: ./setup-litellm.sh"; exit 1; fi
fi
ok "LiteLLM found."

# ---------- 2. Resolve the key ----------
KEY="$(resolve_key)"
[ -z "$KEY" ] && { err "No API key. Aborting."; exit 1; }

# ---------- Mode --benchmark: run test prompts against the provider, then exit ----------
if [ "$DO_BENCHMARK" -eq 1 ]; then
  run_benchmark
  exit 0
fi

# ---------- 3. Write the proxy config ----------
step "Writing config: $CONFIG_PATH"
mkdir -p "$(dirname "$CONFIG_PATH")"
cat > "$CONFIG_PATH" <<EOF
model_list:
  - model_name: $CLAUDE_ALIAS
    litellm_params:
      model: openai/$MODEL
      api_base: $BASE_URL
      api_key: os.environ/LLM_API_KEY

litellm_settings:
  cache: true
  cache_params:
    type: "local"
    ttl: 3600
EOF
ok "Config written."

# ---------- 4. Find a free port ----------
orig_port="$PORT"
while port_in_use "$PORT"; do
  PORT=$((PORT + 1))
  if [ "$PORT" -gt $((orig_port + 20)) ]; then err "No free port between $orig_port and $PORT."; exit 1; fi
done
[ "$PORT" != "$orig_port" ] && warn "Port $orig_port was busy, switching to port $PORT."
PROXY_URL="http://localhost:$PORT"

# ---------- 5. Start the proxy in the background ----------
step "Starting LiteLLM proxy in the background (port $PORT) ..."
LLM_API_KEY="$KEY" nohup "$LITELLM" --config "$CONFIG_PATH" --port "$PORT" >"$LOG_FILE" 2>&1 &
PROXY_PID=$!
disown "$PROXY_PID" 2>/dev/null || true
ok "Proxy started (PID $PROXY_PID). Logs: $LOG_FILE"

# ---------- 6. Wait until the proxy is ready ----------
step "Waiting for the proxy to be ready (up to 30s) ..."
ready=0
for _ in $(seq 1 30); do
  sleep 1
  if curl -fsS "$PROXY_URL/health/liveliness" >/dev/null 2>&1; then ready=1; break; fi
done
if [ "$ready" -eq 1 ]; then
  ok "Proxy is ready at $PROXY_URL"
else
  warn "Could not confirm the proxy after 30s."
  if [ -f "$LOG_FILE" ]; then
    warn "Lỗi cuối trong $LOG_FILE:"
    tail -5 "$LOG_FILE" | while IFS= read -r line; do printf '    %s\n' "$line"; done
    if grep -q "401\|Unauthorized" "$LOG_FILE" 2>/dev/null; then
      err "Provider trả về 401 — kiểm tra API key. Chạy: ./start-claude.sh --check-keys"
    elif grep -q "429\|RateLimitError" "$LOG_FILE" 2>/dev/null; then
      err "Provider trả về 429 rate limit — đổi provider hoặc thử lại sau."
    elif grep -q "ModuleNotFoundError\|ImportError" "$LOG_FILE" 2>/dev/null; then
      err "Thiếu Python package — chạy: ./setup-litellm.sh --force"
    elif grep -q "Connection refused\|No route to host\|Could not connect" "$LOG_FILE" 2>/dev/null; then
      err "Không thể kết nối tới provider — kiểm tra BASE_URL và mạng."
    fi
  fi
fi

# ---------- 7. Point Claude Code at the proxy ----------
export ANTHROPIC_BASE_URL="$PROXY_URL"
export ANTHROPIC_AUTH_TOKEN="litellm-proxy"   # dummy token; the real key lives in the proxy
export ANTHROPIC_MODEL="$CLAUDE_ALIAS"
# Route background models (haiku/sonnet/opus) to the same alias so they resolve too.
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$CLAUDE_ALIAS"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$CLAUDE_ALIAS"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$CLAUDE_ALIAS"
unset ANTHROPIC_API_KEY

if [ "$NO_VSCODE" -eq 1 ]; then
  step "Skipping VS Code (--no-vscode)."
  printf '\nProxy is running. To use it, run THESE in your shell:\n'
  printf "  export ANTHROPIC_BASE_URL='%s'\n" "$PROXY_URL"
  printf "  export ANTHROPIC_AUTH_TOKEN='litellm-proxy'\n"
  printf "  export ANTHROPIC_MODEL='%s'\n" "$CLAUDE_ALIAS"
  printf "  export ANTHROPIC_DEFAULT_HAIKU_MODEL='%s'\n" "$CLAUDE_ALIAS"
  printf "  export ANTHROPIC_DEFAULT_SONNET_MODEL='%s'\n" "$CLAUDE_ALIAS"
  printf "  export ANTHROPIC_DEFAULT_OPUS_MODEL='%s'\n" "$CLAUDE_ALIAS"
  printf "  unset ANTHROPIC_API_KEY\n"
  printf "  code .       # or run:  claude\n"
  exit 0
fi

# ---------- 8. Open VS Code (or hint for the CLI) ----------
step "Opening the editor (Claude Code pointed at the proxy) ..."
if command -v code >/dev/null 2>&1; then
  code "$PROJECT_DIR"
  ok "Opened VS Code for: $PROJECT_DIR"
  warn "If VS Code was already open, fully quit and reopen so it picks up the new settings."
else
  warn "'code' command not found."
  warn "This shell now has the env vars set -- run 'claude' here, or open VS Code from this shell."
fi

if [ "$DO_DASHBOARD" -eq 1 ]; then
  open "http://localhost:$PORT" 2>/dev/null || \
  xdg-open "http://localhost:$PORT" 2>/dev/null || \
  ok "Dashboard: http://localhost:$PORT  (open this URL in your browser)"
fi

# --- Usage log (logs/usage.csv) ---
log_dir="$SCRIPT_DIR/logs"
mkdir -p "$log_dir"
log_file="$log_dir/usage.csv"
[ -f "$log_file" ] || printf 'date,provider,model,port\n' > "$log_file"
provider_label="${SELECTED_LABEL:-custom}"
printf '%s,%s,%s,%s\n' "$(date '+%Y-%m-%d %H:%M')" "$provider_label" "$MODEL" "$PORT" >> "$log_file"

printf '\n%s=================================================================%s\n' "$c_green" "$c_reset"
printf '%s DONE. Claude Code now runs on: %s%s\n' "$c_green" "$MODEL" "$c_reset"
printf '%s=================================================================%s\n' "$c_green" "$c_reset"
printf ' Tool-calling smoke test (inside Claude Code):\n'
printf "   1. 'Read README.md and summarize it'\n"
printf "   2. 'Create a file test.txt containing hello'\n"
printf ' If it reads/creates the file -> good. If it only replies with text -> pick another model.\n\n'
printf '%s Stop the proxy when done:  ./start-claude.sh --stop --port %s%s\n' "$c_yellow" "$PORT" "$c_reset"
