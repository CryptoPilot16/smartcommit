#!/bin/bash
# ============================================================
# Codex post-task hook
# Same as Claude Code hook but tags source as codex
# ============================================================

SMART_COMMIT="$HOME/smart-commit/smart-commit.sh"
REPO_DIR="${1:-$(pwd)}"

if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    "$SMART_COMMIT" commit "$REPO_DIR" "codex"
fi
