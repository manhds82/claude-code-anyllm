#!/usr/bin/env bash
# ============================================================
#   setup-litellm.sh  (claude-code-anyllm)
#   Install the LiteLLM proxy environment -- RUN THIS ONCE.
#   macOS / Linux counterpart of setup-litellm.ps1
#
#   When done: run  ./start-claude.sh
# ============================================================
set -eo pipefail

usage() {
  cat <<'EOF'
setup-litellm.sh - install the LiteLLM proxy environment (run once)
  ./setup-litellm.sh               create .venv inside the project (recommended)
  ./setup-litellm.sh --force       delete the old venv and reinstall
  ./setup-litellm.sh --venv PATH   use a different venv location
  ./setup-litellm.sh --python BIN  force a specific python (e.g. python3.11)
EOF
}

VENV_PATH=""
PY=""
FORCE=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

c_cyan=$'\033[36m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_red=$'\033[31m'; c_reset=$'\033[0m'
step() { printf '\n%s==> %s%s\n' "$c_cyan" "$1" "$c_reset"; }
ok()   { printf '    %s[OK]%s %s\n' "$c_green" "$c_reset" "$1"; }
warn() { printf '    %s[!]%s %s\n'  "$c_yellow" "$c_reset" "$1"; }
err()  { printf '    %s[X]%s %s\n'  "$c_red" "$c_reset" "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --force)  FORCE=1; shift ;;
    --venv)   VENV_PATH="$2"; shift 2 ;;
    --python) PY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done

[ -z "$VENV_PATH" ] && VENV_PATH="$SCRIPT_DIR/.venv"
LITELLM="$VENV_PATH/bin/litellm"

step "Installing LiteLLM into: $VENV_PATH"

# ---------- 1. Already installed? ----------
if [ -x "$LITELLM" ] && [ "$FORCE" -eq 0 ]; then
  ok "LiteLLM is already present at $LITELLM"
  printf '    Reinstall from scratch: ./setup-litellm.sh --force\n'
  printf '\n    Next step: ./start-claude.sh\n'
  exit 0
fi

# ---------- 2. Find Python ----------
step "Looking for Python ..."
if [ -z "$PY" ]; then
  for cand in python3.12 python3.11 python3; do
    if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
  done
fi
if [ -z "$PY" ] || ! command -v "$PY" >/dev/null 2>&1; then
  err "Python 3 not found. Install Python 3.11/3.12:"
  err "  macOS:  brew install python@3.12"
  err "  Debian/Ubuntu:  sudo apt install python3 python3-venv"
  exit 1
fi
ok "Using: $PY ($("$PY" --version 2>&1))"

# ---------- 3. Remove old venv if --force ----------
if [ "$FORCE" -eq 1 ] && [ -d "$VENV_PATH" ]; then
  step "Removing the old venv (--force) ..."
  rm -rf "$VENV_PATH"
  ok "Removed $VENV_PATH"
fi

# ---------- 4. Create the venv ----------
if [ ! -x "$VENV_PATH/bin/python" ]; then
  step "Creating the virtual env ..."
  "$PY" -m venv "$VENV_PATH"
  ok "Created venv: $VENV_PATH"
else
  ok "Venv already exists, just installing/updating packages."
fi

VENV_PY="$VENV_PATH/bin/python"

# ---------- 5. Upgrade pip + install litellm[proxy] ----------
step "Upgrading pip ..."
"$VENV_PY" -m pip install --upgrade pip >/dev/null
ok "pip is up to date."

step "Installing litellm[proxy] (this can take a few minutes) ..."
"$VENV_PY" -m pip install "litellm[proxy]"

# ---------- 6. Verify ----------
if [ ! -x "$LITELLM" ]; then
  err "Installed but $LITELLM is missing. Try again with --force."
  exit 1
fi
ok "LiteLLM is ready. $("$VENV_PY" -m litellm --version 2>&1 || true)"

# ---------- 7. Pin Claude Code CLI to the stable build ----------
# Newer Claude Code builds sometimes misbehave behind a proxy; pin the stable one.
step "Pinning Claude Code CLI to the stable build ..."
if command -v claude >/dev/null 2>&1; then
  if claude install stable; then
    ok "Claude Code CLI pinned to stable."
  else
    warn "'claude install stable' returned an error (continuing anyway)."
  fi
else
  warn "'claude' CLI not found on PATH - skipping this step."
  warn "If you use Claude Code, run 'claude install stable' once yourself to pin a stable version."
fi

printf '\n%s=================================================================%s\n' "$c_green" "$c_reset"
printf '%s DONE. LiteLLM installed at: %s%s\n' "$c_green" "$VENV_PATH" "$c_reset"
printf '%s=================================================================%s\n' "$c_green" "$c_reset"
printf ' Next steps:\n'
printf '   1. Edit BASE_URL / MODEL / KEY at the top of start-claude.sh (or leave KEY blank to be prompted).\n'
printf '   2. Run:  ./start-claude.sh\n'
