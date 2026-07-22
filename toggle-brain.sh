#!/usr/bin/env bash
# ============================================================
#   toggle-brain.sh  (claude-code-anyllm)
#   Toggle Claude Code's "brain" between real Anthropic and
#   any OpenAI-compatible LLM via a local LiteLLM proxy.
#   macOS / Linux counterpart of toggle-brain.ps1
#
#   USAGE:
#     ./toggle-brain.sh claude          Switch to real Anthropic
#     ./toggle-brain.sh proxy           Switch to proxy LLM
#     ./toggle-brain.sh status          Show current brain status
#     ./toggle-brain.sh profiles        List available profiles
#     ./toggle-brain.sh proxy --start   Switch + auto-start proxy
#     ./toggle-brain.sh proxy --key sk-... --start
#     ./toggle-brain.sh stop            Stop running proxy
# ============================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROFILES_DIR="$SCRIPT_DIR/profiles"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_PATH="$CLAUDE_DIR/settings.json"
CONFIG_PATH="$SCRIPT_DIR/config/litellm_config.yaml"
LOG_FILE="$SCRIPT_DIR/litellm-proxy.log"
PORT=4000
PROXY_URL="http://localhost:$PORT"

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_magenta=$'\033[35m'; c_gray=$'\033[90m'; c_reset=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "$c_cyan" "$1" "$c_reset"; }
ok()   { printf '    %s[OK]%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s[!]%s %s\n'  "$c_yellow" "$c_reset" "$1"; }
err()  { printf '    %s[X]%s %s\n'  "$c_red" "$c_reset" "$1"; }
star() { printf '    %s[*]%s %s\n'  "$c_magenta" "$c_reset" "$1"; }

usage() {
  cat <<'USAGE'

  toggle-brain.sh — Toggle Claude Code's brain

  USAGE:
    ./toggle-brain.sh claude          Switch to real Anthropic
    ./toggle-brain.sh proxy           Switch to proxy LLM
    ./toggle-brain.sh status          Show current brain status
    ./toggle-brain.sh profiles        List available profiles
    ./toggle-brain.sh stop            Stop running proxy

  OPTIONS (with "proxy"):
    --profile <name>   Use a specific profile (default: fpt)
    --key <key>        API key (omit to be prompted)
    --start            Auto-start the proxy if not running
    --port <int>       Proxy port (default 4000)

  EXAMPLES:
    ./toggle-brain.sh claude
    ./toggle-brain.sh proxy --start
    ./toggle-brain.sh proxy --profile openai --key "sk-..." --start
    ./toggle-brain.sh status
USAGE
}

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

get_current_mode() {
  if [ ! -f "$SETTINGS_PATH" ]; then echo "unknown"; return; fi
  local env_count
  env_count=$(grep -c '"env"' "$SETTINGS_PATH" 2>/dev/null || true)
  local has_url
  has_url=$(grep -c 'ANTHROPIC_BASE_URL' "$SETTINGS_PATH" 2>/dev/null || true)
  local is_localhost
  is_localhost=$(grep -c 'localhost' "$SETTINGS_PATH" 2>/dev/null || true)
  if [ "$has_url" -eq 0 ]; then echo "claude"; return; fi
  if [ "$is_localhost" -gt 0 ]; then echo "proxy"; else echo "custom"; fi
}

port_in_use() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -ti "tcp:$1" -sTCP:LISTEN >/dev/null 2>&1
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$1") >/dev/null 2>&1 && { exec 3>&- 3<&-; return 0; } || return 1
  fi
}

list_profiles() {
  step "AVAILABLE PROFILES"
  if [ ! -d "$PROFILES_DIR" ]; then err "No profiles/ directory found."; exit 1; fi
  for f in "$PROFILES_DIR"/*.json; do
    local name
    name=$(basename "$f" .json)
    local desc
    desc=$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
    [ -z "$desc" ] && desc="No description"
    printf '  %s%s%s  — %s\n' "$c_cyan" "$name" "$c_reset" "$desc"
  done
  printf '\n  Use:  ./toggle-brain.sh proxy --profile <name>\n'
}

# ──────────────────────────────────────────────────────────────
# Parse args
# ──────────────────────────────────────────────────────────────
ACTION="${1:-}"
shift 2>/dev/null || true
PROFILE=""
KEY=""
DO_START=0

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    --key)     KEY="$2"; shift 2 ;;
    --start)   DO_START=1; shift ;;
    --port)    PORT="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

case "$ACTION" in
  status)
    step "BRAIN STATUS"
    local mode
    mode=$(get_current_mode)
    case "$mode" in
      claude) printf '  Current brain: %sREAL ANTHROPIC%s\n' "$c_green" "$c_reset" ;;
      proxy)  printf '  Current brain: %sPROXY (third-party LLM)%s\n' "$c_yellow" "$c_reset" ;;
      custom) printf '  Current brain: %sCUSTOM CONFIG%s\n' "$c_magenta" "$c_reset" ;;
      *)      printf '  Current brain: %sUNKNOWN%s\n' "$c_red" "$c_reset" ;;
    esac
    if [ -f "$SETTINGS_PATH" ]; then printf '  Config file:   %s\n' "$SETTINGS_PATH"; else printf '  Config file:   (not found)\n'; fi
    if port_in_use "$PORT"; then
      printf '  Proxy status:  %sRUNNING (port %s)%s\n' "$c_green" "$PORT" "$c_reset"
    else
      printf '  Proxy status:  %sSTOPPED%s\n' "$c_gray" "$c_reset"
    fi
    printf '\n'
    if [ "$mode" = "proxy" ] && ! port_in_use "$PORT"; then
      warn "Proxy mode is active but the proxy is NOT running."
      printf '  Start it:  ./toggle-brain.sh proxy --start\n'
    elif [ "$mode" = "claude" ] && port_in_use "$PORT"; then
      warn "Claude mode is active but the proxy is still running."
      printf '  Stop it:   ./toggle-brain.sh stop\n'
    fi
    printf '\n  Toggle:    ./toggle-brain.sh proxy\n'
    printf '  Profiles:  ./toggle-brain.sh profiles\n'
    exit 0
    ;;

  profiles)
    list_profiles
    exit 0
    ;;

  stop)
    step "STOP PROXY"
    local pids=""
    if command -v lsof >/dev/null 2>&1; then
      pids=$(lsof -ti "tcp:$PORT" -sTCP:LISTEN 2>/dev/null || true)
    elif command -v fuser >/dev/null 2>&1; then
      pids=$(fuser "$PORT/tcp" 2>/dev/null || true)
    fi
    if [ -z "$pids" ]; then warn "No proxy process found on port $PORT."; exit 0; fi
    for pid in $pids; do
      if kill "$pid" 2>/dev/null; then ok "Stopped PID $pid."; else err "Could not stop PID $pid."; fi
    done
    exit 0
    ;;

  claude|proxy)
    # resolve profile
    if [ -z "$PROFILE" ]; then
      [ "$ACTION" = "claude" ] && PROFILE="claude" || PROFILE="fpt"
    fi
    local profile_path="$PROFILES_DIR/$PROFILE.json"
    if [ ! -f "$profile_path" ]; then
      err "Profile '$PROFILE' not found in $PROFILES_DIR"
      list_profiles
      exit 1
    fi
    local profile_desc
    profile_desc=$(grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$profile_path" 2>/dev/null | head -1 | sed -E 's/.*"([^"]*)"$/\1/')
    [ -z "$profile_desc" ] && profile_desc="$PROFILE"

    step "SWITCHING BRAIN → $(echo "$PROFILE" | tr '[:lower:]' '[:upper:]')"
    printf '  Profile:     %s.json\n' "$PROFILE"
    printf '  Target:      %s\n' "$profile_desc"

    # apply profile
    mkdir -p "$CLAUDE_DIR"
    cp "$profile_path" "$SETTINGS_PATH"
    ok "Applied profile → $SETTINGS_PATH"

    # show env vars
    local env_vars
    env_vars=$(grep -o '"ANTHROPIC_[^"]*"' "$profile_path" 2>/dev/null || true)
    if [ -n "$env_vars" ]; then
      printf '  Environment variables set:\n'
      echo "$env_vars" | while read -r var; do
        local val
        val=$(grep -o "\"$var\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" "$profile_path" 2>/dev/null | sed -E 's/.*: "([^"]*)"/\1/')
        printf '    %s = %s\n' "$var" "$val"
      done
    else
      printf '  Environment: empty (real Anthropic mode)\n'
    fi

    # proxy lifecycle
    if [ "$ACTION" = "proxy" ]; then
      if [ "$DO_START" -eq 1 ] && ! port_in_use "$PORT"; then
        step "STARTING PROXY"
        if [ -z "$KEY" ]; then
          printf 'Enter API key: '
          read -r -s KEY </dev/tty || true
          printf '\n'
        fi
        if [ -z "$KEY" ]; then
          err "No API key. Profile applied but proxy not started."
          star "DONE. Restart Claude Code to take effect."
          exit 0
        fi

        # Find LiteLLM
        local litellm=""
        if [ -x "$SCRIPT_DIR/.venv/bin/litellm" ]; then
          litellm="$SCRIPT_DIR/.venv/bin/litellm"
        elif [ -x "$HOME/litellm-env/bin/litellm" ]; then
          litellm="$HOME/litellm-env/bin/litellm"
        else
          err "LiteLLM not found. Run setup-litellm.sh first."
          star "DONE. Profile applied. Restart Claude Code to take effect."
          exit 0
        fi

        # Write config
        local claude_alias
        claude_alias=$(grep -o '"ANTHROPIC_MODEL"[[:space:]]*:[[:space:]]*"[^"]*"' "$profile_path" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/')
        [ -z "$claude_alias" ] && claude_alias="claude-sonnet-4-6"
        local base_url
        base_url=$(grep -o '"ANTHROPIC_BASE_URL"[[:space:]]*:[[:space:]]*"[^"]*"' "$profile_path" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/')

        mkdir -p "$(dirname "$CONFIG_PATH")"
        # F-03: quote user-supplied values as YAML single-quoted scalars so a
        # stray quote/colon/newline cannot break or inject YAML structure.
        yqs() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
        cat > "$CONFIG_PATH" <<EOF
model_list:
  - model_name: $(yqs "$claude_alias")
    litellm_params:
      model: $(yqs "openai/DeepSeek-V4-Flash")
      api_base: $(yqs "$base_url")
      api_key: os.environ/LLM_API_KEY
EOF
        ok "Config written: $CONFIG_PATH"

        # Start proxy
        LLM_API_KEY="$KEY" nohup "$litellm" --config "$CONFIG_PATH" --port "$PORT" >"$LOG_FILE" 2>&1 &
        local ppid=$!
        disown "$ppid" 2>/dev/null || true
        ok "Proxy starting (PID $ppid). Logs: $LOG_FILE"

        # Wait for readiness
        printf '  Waiting for proxy (up to 15s)...'
        local ready=0
        for _ in $(seq 1 15); do
          sleep 1
          if curl -fsS "$PROXY_URL/health/liveliness" >/dev/null 2>&1; then ready=1; break; fi
          printf '.'
        done
        printf '\n'
        if [ "$ready" -eq 1 ]; then
          ok "Proxy is ready at $PROXY_URL"
        else
          warn "Could not confirm proxy after 15s. Check: $LOG_FILE"
        fi
      elif [ "$DO_START" -eq 1 ] && port_in_use "$PORT"; then
        ok "Proxy is already running on port $PORT."
      elif ! port_in_use "$PORT"; then
        warn "Proxy is NOT running. Start it with --start:"
        printf '    ./toggle-brain.sh proxy --start\n'
      fi
    fi

    # hint for claude mode
    if [ "$ACTION" = "claude" ] && port_in_use "$PORT"; then
      warn "Proxy is still running on port $PORT."
      printf '  Stop it:  ./toggle-brain.sh stop\n'
    fi

    printf '\n'
    star "DONE. Claude Code brain switched to: $profile_desc"
    warn "IMPORTANT: Close and reopen Claude Code (or New session) for the change to take effect."
    printf '\n  Verify:    ./toggle-brain.sh status\n'
    if [ "$ACTION" = "proxy" ]; then
      printf '  Revert:    ./toggle-brain.sh claude\n'
    else
      printf '  Revert:    ./toggle-brain.sh proxy\n'
    fi
    ;;

  "")
    usage
    ;;
  *)
    err "Unknown action: $ACTION"
    usage
    exit 1
    ;;
esac
