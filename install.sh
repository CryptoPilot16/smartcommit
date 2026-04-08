#!/bin/bash
# ============================================================
# Smart-Commit Installer
# Run this ONCE on your VPS to set everything up
# ============================================================

set -euo pipefail

GREEN='\033[0;32m'
NC='\033[0m'
log() { echo -e "${GREEN}[installer]${NC} $1"; }

INSTALL_DIR="$HOME/smart-commit"

# --- 1. Create directory structure ---
log "Creating directory structure..."
mkdir -p "$INSTALL_DIR"/{hooks,logs}

# --- 2. Copy files ---
log "Copying smart-commit files..."
cp /opt/smartcommit/smart-commit.sh "$INSTALL_DIR/smart-commit.sh"
cp /opt/smartcommit/hooks/post-task-claude.sh "$INSTALL_DIR/hooks/post-task-claude.sh"
cp /opt/smartcommit/hooks/post-task-codex.sh "$INSTALL_DIR/hooks/post-task-codex.sh"

chmod +x "$INSTALL_DIR/smart-commit.sh"
chmod +x "$INSTALL_DIR/hooks/"*.sh

# --- 3. Symlink to PATH ---
log "Adding to PATH..."
ln -sf "$INSTALL_DIR/smart-commit.sh" /usr/local/bin/smart-commit

# --- 4. Environment variables ---
log "Setting up environment..."
ENV_FILE="$INSTALL_DIR/.env"

if [ ! -f "$ENV_FILE" ]; then
    cat > "$ENV_FILE" << 'ENVEOF'
# Smart-Commit Environment
# Fill in your Telegram bot token and chat ID
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
OLLAMA_MODEL=llama3.1:8b
ENVEOF
    log "Created $ENV_FILE — EDIT THIS with your Telegram credentials"
else
    log ".env already exists, skipping"
fi

# Source env in smart-commit
if ! grep -q "source.*\.env" "$INSTALL_DIR/smart-commit.sh" 2>/dev/null; then
    sed -i '4a\\n# Load environment\nif [ -f "'$INSTALL_DIR'/.env" ]; then\n    set -a\n    source "'$INSTALL_DIR'/.env"\n    set +a\nfi' "$INSTALL_DIR/smart-commit.sh"
fi

# --- 5. Cron jobs ---
log "Setting up cron jobs..."

# Backup existing crontab
crontab -l > /tmp/crontab_backup_$(date +%Y%m%d) 2>/dev/null || true

# Add smart-commit crons if not already present
(crontab -l 2>/dev/null || true) | {
    CRON_CONTENT=$(cat)
    
    # Auto-commit all repos every 2 hours
    if ! echo "$CRON_CONTENT" | grep -q "smart-commit all auto"; then
        echo "$CRON_CONTENT"
        echo ""
        echo "# Smart-Commit: auto-commit all dirty repos every 2 hours"
        echo "0 */2 * * * /usr/local/bin/smart-commit all auto >> $INSTALL_DIR/logs/cron.log 2>&1"
        echo ""
        echo "# Smart-Commit: daily rollup at 23:55 UTC"
        echo "55 23 * * * /usr/local/bin/smart-commit rollup >> $INSTALL_DIR/logs/cron.log 2>&1"
        echo ""
        echo "# Smart-Commit: wire any new repos hourly"
        echo "0 * * * * bash $INSTALL_DIR/wire-repos.sh >> $INSTALL_DIR/logs/cron.log 2>&1"
        echo ""
        echo "# Smart-Commit: weekly rollup every Monday 08:00 UTC"
        echo "0 8 * * 1 /usr/local/bin/smart-commit weekly >> $INSTALL_DIR/logs/cron.log 2>&1"
    else
        echo "$CRON_CONTENT"
    fi
} | crontab -

# --- 6. Claude Code integration ---
log "Configuring Claude Code hook..."

CLAUDE_HOOKS_DIR="$HOME/.claude"
mkdir -p "$CLAUDE_HOOKS_DIR"

# Create/update Claude Code settings to include post-task hook
CLAUDE_SETTINGS="$CLAUDE_HOOKS_DIR/settings.json"
if [ -f "$CLAUDE_SETTINGS" ]; then
    # Add hook command to allowlist if not present
    if ! grep -q "smart-commit" "$CLAUDE_SETTINGS" 2>/dev/null; then
        log "NOTE: Add this to your Claude Code post-task workflow:"
        log "  $HOME/smart-commit/hooks/post-task-claude.sh \$(pwd)"
    fi
else
    log "No Claude Code settings found — configure manually"
fi

# --- 7. Git global config ---
# Set git identity if not already configured
if [ -z "$(git config --global user.name 2>/dev/null)" ] || [ -z "$(git config --global user.email 2>/dev/null)" ]; then
    log "NOTE: Git global user.name/email not set — configure with:"
    log "  git config --global user.name 'Your Name'"
    log "  git config --global user.email 'you@example.com'"
fi

# --- 8. Wire all repos (git hooks + CLAUDE.md + AGENTS.md) ---
log "Wiring all repos..."
for repo in $(find "$HOME" -maxdepth 4 -name ".git" -type d 2>/dev/null | sed 's/\/.git$//'); do
    # Git post-commit hook
    hook_file="$repo/.git/hooks/post-commit"
    if [ ! -f "$hook_file" ] || ! grep -q "smart-commit" "$hook_file" 2>/dev/null; then
        echo '#!/bin/bash' > "$hook_file"
        echo "# Log commit to smart-commit system" >> "$hook_file"
        echo 'PROJECT=$(basename "$(git rev-parse --show-toplevel)")' >> "$hook_file"
        echo 'MSG=$(git log -1 --pretty=%B)' >> "$hook_file"
        echo 'jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg project "$PROJECT" --arg msg "$MSG" --arg source "direct" '"'"'{timestamp: $ts, project: $project, message: $msg, source: $source}'"'"' >> '"$HOME"'/smart-commit/logs/commits.jsonl 2>/dev/null || true' >> "$hook_file"
        chmod +x "$hook_file"
        log "  git hook: $(basename $repo)"
    fi

    # Claude Code — CLAUDE.md
    [ ! -f "$repo/CLAUDE.md" ] && touch "$repo/CLAUDE.md"
    if ! grep -q "smart-commit" "$repo/CLAUDE.md" 2>/dev/null; then
        echo -e "\n## Auto-Commit\nAfter completing any task, run: smart-commit commit . claude-code" >> "$repo/CLAUDE.md"
        log "  CLAUDE.md: $(basename $repo)"
    fi

    # Codex — AGENTS.md
    [ ! -f "$repo/AGENTS.md" ] && touch "$repo/AGENTS.md"
    if ! grep -q "smart-commit" "$repo/AGENTS.md" 2>/dev/null; then
        echo -e "\n## Auto-Commit\nAfter completing any task, run: smart-commit commit . codex" >> "$repo/AGENTS.md"
        log "  AGENTS.md: $(basename $repo)"
    fi
done

# --- 9. Test ---
log ""
log "============================================"
log " Smart-Commit installed successfully!"
log "============================================"
log ""
log "Commands:"
log "  smart-commit discover    — see all repos"
log "  smart-commit status      — check status"  
log "  smart-commit all         — commit all dirty repos"
log "  smart-commit rollup      — send daily Telegram summary"
log "  smart-commit commit .    — commit current repo"
log ""
log "Cron:"
log "  Every 2h: auto-commit all dirty repos"
log "  23:55 UTC: daily rollup to Telegram"
log ""
log "TODO:"
log "  1. Edit $INSTALL_DIR/.env with Telegram credentials"
log "  2. Set git identity if not already configured"
log ""

smart-commit discover
