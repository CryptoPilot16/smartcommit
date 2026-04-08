#!/bin/bash
# ============================================================
# Claude Code post-task hook
# Drops this into Claude Code's workflow so every completed
# task auto-commits with an AI-generated message
# ============================================================

SMART_COMMIT="$HOME/smart-commit/smart-commit.sh"
REPO_DIR="${1:-$(pwd)}"

# Only run if we're in a git repo
if git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    "$SMART_COMMIT" commit "$REPO_DIR" "claude-code"
fi
