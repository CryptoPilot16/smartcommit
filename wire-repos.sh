#!/bin/bash
# ============================================================
# wire-repos.sh — Auto-wire any new git repos
# Runs hourly via cron to pick up newly created repos
# ============================================================

INSTALL_DIR="$HOME/smart-commit"
COMMIT_LOG="$INSTALL_DIR/logs/commits.jsonl"

# Load env for GITHUB_TOKEN
[ -f "$INSTALL_DIR/.env" ] && set -a && source "$INSTALL_DIR/.env" && set +a

for repo in $(find "$HOME" -maxdepth 4 -name ".git" -type d 2>/dev/null | sed 's/\/.git$//'); do
    name=$(basename "$repo")

    # Git post-commit hook
    hook_file="$repo/.git/hooks/post-commit"
    if [ ! -f "$hook_file" ] || ! grep -q "smart-commit" "$hook_file" 2>/dev/null; then
        echo '#!/bin/bash' > "$hook_file"
        echo "# Log commit to smart-commit system" >> "$hook_file"
        echo 'PROJECT=$(basename "$(git rev-parse --show-toplevel)")' >> "$hook_file"
        echo 'MSG=$(git log -1 --pretty=%B)' >> "$hook_file"
        echo 'jq -n --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg project "$PROJECT" --arg msg "$MSG" --arg source "direct" '"'"'{timestamp: $ts, project: $project, message: $msg, source: $source}'"'"' >> '"$HOME"'/smart-commit/logs/commits.jsonl 2>/dev/null || true' >> "$hook_file"
        chmod +x "$hook_file"
        echo "[wire-repos] git hook: $name"
    fi

    # Claude Code — CLAUDE.md
    [ ! -f "$repo/CLAUDE.md" ] && touch "$repo/CLAUDE.md"
    if ! grep -q "smart-commit" "$repo/CLAUDE.md" 2>/dev/null; then
        echo -e "\n## Auto-Commit\nAfter completing any task, run: smart-commit commit . claude-code" >> "$repo/CLAUDE.md"
        echo "[wire-repos] CLAUDE.md: $name"
    fi

    # Codex — AGENTS.md
    [ ! -f "$repo/AGENTS.md" ] && touch "$repo/AGENTS.md"
    if ! grep -q "smart-commit" "$repo/AGENTS.md" 2>/dev/null; then
        echo -e "\n## Auto-Commit\nAfter completing any task, run: smart-commit commit . codex" >> "$repo/AGENTS.md"
        echo "[wire-repos] AGENTS.md: $name"
    fi

    # GitHub remote — create repo if no remote set
    if [ -n "$GITHUB_TOKEN" ] && [ -n "$GITHUB_USERNAME" ]; then
        remote_url=$(git -C "$repo" remote get-url origin 2>/dev/null || true)

        if [ -z "$remote_url" ]; then
            # No remote at all — create GitHub repo and wire it
            response=$(curl -s -X POST \
                -H "Authorization: token ${GITHUB_TOKEN}" \
                -H "Content-Type: application/json" \
                -d "{\"name\": \"${name}\", \"private\": true, \"auto_init\": false}" \
                "https://api.github.com/user/repos")

            github_url=$(echo "$response" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('html_url',''))" 2>/dev/null)

            if [ -n "$github_url" ]; then
                git -C "$repo" remote add origin "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${name}.git"
                echo "[wire-repos] GitHub repo created + remote set: $name → $github_url"
                # Notify Telegram
                source "$INSTALL_DIR/.env" 2>/dev/null || true
                curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
                    -d chat_id="$TELEGRAM_CHAT_ID" \
                    -d text="🆕 New repo auto-created on GitHub: ${name}
$github_url" \
                    --max-time 10 >/dev/null 2>&1 || true
            else
                # Repo may already exist on GitHub, just wire the remote
                git -C "$repo" remote add origin "https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com/${GITHUB_USERNAME}/${name}.git"
                echo "[wire-repos] remote set: $name"
            fi

        elif echo "$remote_url" | grep -q "github.com" && ! echo "$remote_url" | grep -q "@github.com"; then
            # Remote exists but no token embedded — inject it
            new_url=$(echo "$remote_url" | sed "s|https://github.com|https://${GITHUB_USERNAME}:${GITHUB_TOKEN}@github.com|")
            git -C "$repo" remote set-url origin "$new_url"
            echo "[wire-repos] auth wired: $name"
        fi
    fi
done
