#!/usr/bin/env bash
# ============================================================
#   open-with-claude.sh  — per-project Claude Code launcher
#   Drop this file into any project folder (chmod +x first).
#
#   Usage:
#     ./open-with-claude.sh                   # interactive provider menu
#     ./open-with-claude.sh --provider fpt    # skip the menu
#     ./open-with-claude.sh --provider nvidia --key "nvapi-..."
#
#   All flags are forwarded to start-claude.sh.
#   Edit CLAUDE_SETUP below to point at your claude-code-anyllm folder.
# ============================================================

# ---- EDIT THIS: path to your claude-code-anyllm installation ----
CLAUDE_SETUP="$HOME/claude-code-anyllm"
# -----------------------------------------------------------------

LAUNCHER="$CLAUDE_SETUP/start-claude.sh"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ ! -f "$LAUNCHER" ]; then
  printf '\033[31m[X]\033[0m start-claude.sh not found at: %s\n' "$CLAUDE_SETUP"
  printf '    Edit the CLAUDE_SETUP variable in this file to point at your claude-code-anyllm folder.\n'
  exit 1
fi

exec bash "$LAUNCHER" --open-dir "$THIS_DIR" "$@"
