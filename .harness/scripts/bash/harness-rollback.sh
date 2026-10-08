#!/usr/bin/env bash
# H7 Orchestration — git-based transaction boundary (bash parity of
# harness-rollback.ps1). snapshot | restore | list a restore point so a deploy
# workflow can roll back on failure. Uncommitted work is stashed (recoverable).
set -euo pipefail

ACTION="${1:-snapshot}"
TAG="${2:-harness-restore-point}"
REPO="${3:-$(pwd)}"

cd "$REPO"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "[rollback] not a git repo: $REPO"; exit 0
fi

case "$ACTION" in
    snapshot)
        SHA=$(git rev-parse HEAD)
        git tag -f "$TAG" "$SHA" >/dev/null 2>&1
        echo "[rollback] restore point '$TAG' -> ${SHA:0:10}"
        ;;
    list)
        SHA=$(git rev-parse -q --verify "refs/tags/$TAG" 2>/dev/null || true)
        [ -n "$SHA" ] && echo "[rollback] $TAG -> ${SHA:0:10}" || echo "[rollback] no restore point '$TAG' yet"
        ;;
    restore)
        SHA=$(git rev-parse -q --verify "refs/tags/$TAG" 2>/dev/null || true)
        if [ -z "$SHA" ]; then echo "[rollback] no restore point '$TAG' — run snapshot first" >&2; exit 1; fi
        if [ -n "$(git status --porcelain)" ]; then
            git stash push -u -m "harness-rollback-autostash" >/dev/null 2>&1 || true
            echo "[rollback] uncommitted work stashed as 'harness-rollback-autostash' (git stash list)"
        fi
        git reset --hard "$TAG" >/dev/null 2>&1
        echo "[rollback] restored working tree to '$TAG' (${SHA:0:10})"
        ;;
    *)
        echo "usage: harness-rollback.sh [snapshot|restore|list] [tag] [repo]" >&2; exit 2
        ;;
esac
exit 0
