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

DO_LIST=0; DO_STOP=0; NO_VSCODE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_cyan" "$1" "$c_reset"; }
ok()   { printf '    %s[OK]%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s[!]%s %s\n'  "$c_yellow" "$c_reset" "$1"; }
err()  { printf '    %s[X]%s %s\n'  "$c_red" "$c_reset" "$1"; }

usage() {
  cat <<'EOF'
start-claude.sh - run Claude Code on any OpenAI-compatible LLM via LiteLLM
  ./start-claude.sh                 start proxy + open VS Code
  ./start-claude.sh --model NAME    use a different model for this run
  ./start-claude.sh --key KEY       use a different key for this run
  ./start-claude.sh --base-url URL  use a different endpoint for this run
  ./start-claude.sh --list          list models the endpoint exposes, then exit
  ./start-claude.sh --port N        proxy port (default 4000)
  ./start-claude.sh --stop          stop a running proxy on that port
  ./start-claude.sh --no-vscode     only start the proxy
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --model)     MODEL="$2"; shift 2 ;;
    --key)       KEY="$2"; shift 2 ;;
    --base-url)  BASE_URL="$2"; shift 2 ;;
    --port)      PORT="$2"; shift 2 ;;
    --list)      DO_LIST=1; shift ;;
    --stop)      DO_STOP=1; shift ;;
    --no-vscode) NO_VSCODE=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

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

# Is something listening on the given TCP port?
port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti "tcp:$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

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
  warn "Could not confirm the proxy after 30s. Check the log: $LOG_FILE"
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
  code "$SCRIPT_DIR"
  ok "Opened VS Code for: $SCRIPT_DIR"
  warn "If VS Code was already open, fully quit and reopen so it picks up the new settings."
else
  warn "'code' command not found."
  warn "This shell now has the env vars set -- run 'claude' here, or open VS Code from this shell."
fi

printf '\n%s=================================================================%s\n' "$c_green" "$c_reset"
printf '%s DONE. Claude Code now runs on: %s%s\n' "$c_green" "$MODEL" "$c_reset"
printf '%s=================================================================%s\n' "$c_green" "$c_reset"
printf ' Tool-calling smoke test (inside Claude Code):\n'
printf "   1. 'Read README.md and summarize it'\n"
printf "   2. 'Create a file test.txt containing hello'\n"
printf ' If it reads/creates the file -> good. If it only replies with text -> pick another model.\n\n'
printf '%s Stop the proxy when done:  ./start-claude.sh --stop --port %s%s\n' "$c_yellow" "$PORT" "$c_reset"
