#!/bin/sh

REPO_ROOT="$(cd -P -- "$(dirname -- "$0")" && cd .. && pwd)"
HOOK_SRC="$REPO_ROOT/scripts/pre-commit"

if [ ! -f "$HOOK_SRC" ]; then
    echo "Error: pre-commit hook not found at $HOOK_SRC"
    exit 1
fi

HOOKS_DIR="$(git -C "$REPO_ROOT" rev-parse --git-dir)/hooks"
if [ $? -ne 0 ]; then
    echo "Error: not a git repository."
    exit 1
fi

mkdir -p "$HOOKS_DIR"
ln -sf "$HOOK_SRC" "$HOOKS_DIR/pre-commit"
echo "Pre-commit hook installed."
