#!/bin/bash
# ============================================================
# SMART-COMMIT TELEGRAM BOT — Command listener
# Polls Telegram for commands and triggers smart-commit actions
# ============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load .env
if [ -f "$SCRIPT_DIR/.env" ]; then
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/.env"
    set +a
fi

SMART_COMMIT="$SCRIPT_DIR/smart-commit.sh"
OFFSET_FILE="$SCRIPT_DIR/.bot_offset"
PROJECTS_FILE="$SCRIPT_DIR/projects.txt"
LOG_FILE="$SCRIPT_DIR/logs/bot.log"

mkdir -p "$SCRIPT_DIR/logs"
touch "$PROJECTS_FILE"

# --- HELPERS ---

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG_FILE"; }

send() {
    local chat_id="$1"
    local text="$2"
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d chat_id="$chat_id" \
        --data-urlencode text="$text" \
        -d parse_mode="Markdown" \
        --max-time 10 >/dev/null 2>&1 || true
}

get_offset() {
    if [ -f "$OFFSET_FILE" ]; then
        cat "$OFFSET_FILE"
    else
        echo "0"
    fi
}

save_offset() {
    echo "$1" > "$OFFSET_FILE"
}

# Registered projects (manual, non-$HOME paths)
list_registered() {
    grep -v '^\s*$' "$PROJECTS_FILE" 2>/dev/null || true
}

register_repo() {
    local path="$1"
    # Validate it's a git repo
    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        echo "not_a_repo"
        return
    fi
    # Avoid duplicates
    if grep -qxF "$path" "$PROJECTS_FILE" 2>/dev/null; then
        echo "already_registered"
        return
    fi
    echo "$path" >> "$PROJECTS_FILE"
    echo "ok"
}

unregister_repo() {
    local path="$1"
    if grep -qxF "$path" "$PROJECTS_FILE" 2>/dev/null; then
        sed -i "\|^${path}$|d" "$PROJECTS_FILE"
        echo "ok"
    else
        echo "not_found"
    fi
}

# Discover $HOME + /opt repos + registered extras
all_repos() {
    find "$HOME" /opt -maxdepth 4 -name ".git" -type d 2>/dev/null \
        ! -path "*/.openclaw-backup/*" \
        ! -path "*/.openclaw.pre-revert*" \
        ! -path "*/.codex/.tmp/*" \
        ! -path "*/node_modules/*" \
        | sed 's/\/.git$//'
    # Manually registered extras (other paths)
    list_registered
}

# --- COMMAND HANDLERS ---

cmd_help() {
    local chat_id="$1"
    send "$chat_id" "🤖 *Smart-Commit Bot*

*Commit commands:*
\`/all\` — commit all dirty repos
\`/commit <path>\` — commit a specific repo
\`/discover\` — list all repos and their status

*Info commands:*
\`/status\` — show commit stats
\`/rollup\` — send today's commit summary
\`/weekly\` — send this week's summary

*Project registry:*
\`/register <path>\` — track a repo outside \$HOME
\`/unregister <path>\` — stop tracking a repo
\`/registered\` — list manually registered repos

\`/help\` — show this message"
}

cmd_status() {
    local chat_id="$1"
    local msg="📊 *Repo Status*\n"
    local dirty=0
    local clean=0

    while IFS= read -r repo; do
        local name
        name=$(basename "$repo")
        if git -C "$repo" diff --quiet 2>/dev/null && \
           git -C "$repo" diff --cached --quiet 2>/dev/null && \
           [ -z "$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)" ]; then
            ((clean++))
        else
            local count
            count=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
            msg+="● \`$name\` — $count file(s) changed\n"
            ((dirty++))
        fi
    done < <(all_repos | sort -u)

    msg+="\n✅ $clean clean  ●  🔴 $dirty dirty"

    # Commit log stats
    local log_file="$HOME/smart-commit/logs/commits.jsonl"
    if [ -f "$log_file" ]; then
        local today
        today=$(date -u +%Y-%m-%d)
        local today_count
        today_count=$(grep -c "\"$today" "$log_file" 2>/dev/null || echo "0")
        local total_count
        total_count=$(wc -l < "$log_file" 2>/dev/null || echo "0")
        msg+="\n\n📝 Today: $today_count commits  |  Total: $total_count"
    fi

    send "$chat_id" "$(echo -e "$msg")"
}

cmd_discover() {
    local chat_id="$1"
    local msg="🔍 *Discovered Repos*\n"

    while IFS= read -r repo; do
        local name
        name=$(basename "$repo")
        if git -C "$repo" diff --quiet 2>/dev/null && \
           git -C "$repo" diff --cached --quiet 2>/dev/null && \
           [ -z "$(git -C "$repo" ls-files --others --exclude-standard 2>/dev/null)" ]; then
            msg+="○ \`$name\`\n"
        else
            local count
            count=$(git -C "$repo" status --porcelain 2>/dev/null | wc -l)
            msg+="● \`$name\` — $count changed\n"
        fi
    done < <(all_repos | sort -u)

    send "$chat_id" "$(echo -e "$msg")"
}

cmd_all() {
    local chat_id="$1"
    send "$chat_id" "⏳ Committing all dirty repos..."
    local output
    output=$("$SMART_COMMIT" all auto 2>&1 || true)
    send "$chat_id" "✅ Done\n\`\`\`\n${output}\n\`\`\`"
}

cmd_commit() {
    local chat_id="$1"
    local path="${2:-}"

    if [ -z "$path" ]; then
        send "$chat_id" "⚠️ Usage: \`/commit <path>\`"
        return
    fi

    if ! git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
        send "$chat_id" "❌ Not a git repo: \`$path\`"
        return
    fi

    send "$chat_id" "⏳ Committing \`$(basename "$path")\`..."
    local output
    output=$("$SMART_COMMIT" commit "$path" manual 2>&1 || true)
    send "$chat_id" "✅ Done\n\`\`\`\n${output}\n\`\`\`"
}

cmd_rollup() {
    local chat_id="$1"
    "$SMART_COMMIT" rollup 2>&1 || true
    # rollup sends its own Telegram message, just confirm
    send "$chat_id" "📊 Rollup sent."
}

cmd_weekly() {
    local chat_id="$1"
    "$SMART_COMMIT" weekly 2>&1 || true
    send "$chat_id" "📅 Weekly rollup sent."
}

cmd_register() {
    local chat_id="$1"
    local path="${2:-}"

    if [ -z "$path" ]; then
        send "$chat_id" "⚠️ Usage: \`/register <path>\`"
        return
    fi

    # Expand ~ if present
    path="${path/#\~/$HOME}"

    local result
    result=$(register_repo "$path")
    case "$result" in
        ok)               send "$chat_id" "✅ Registered: \`$path\`" ;;
        already_registered) send "$chat_id" "ℹ️ Already registered: \`$path\`" ;;
        not_a_repo)       send "$chat_id" "❌ Not a git repo: \`$path\`" ;;
    esac
}

cmd_unregister() {
    local chat_id="$1"
    local path="${2:-}"

    if [ -z "$path" ]; then
        send "$chat_id" "⚠️ Usage: \`/unregister <path>\`"
        return
    fi

    path="${path/#\~/$HOME}"

    local result
    result=$(unregister_repo "$path")
    case "$result" in
        ok)        send "$chat_id" "✅ Unregistered: \`$path\`" ;;
        not_found) send "$chat_id" "❌ Not in registry: \`$path\`" ;;
    esac
}

cmd_registered() {
    local chat_id="$1"
    local repos
    repos=$(list_registered)

    if [ -z "$repos" ]; then
        send "$chat_id" "📋 No manually registered repos.\nUse \`/register <path>\` to add one."
    else
        local msg="📋 *Registered repos:*\n"
        while IFS= read -r repo; do
            msg+="• \`$repo\`\n"
        done <<< "$repos"
        send "$chat_id" "$(echo -e "$msg")"
    fi
}

# --- PROCESS INCOMING UPDATE ---

process_update() {
    local update="$1"

    local chat_id
    chat_id=$(echo "$update" | jq -r '.message.chat.id // empty')
    local text
    text=$(echo "$update" | jq -r '.message.text // empty')
    local from_id
    from_id=$(echo "$update" | jq -r '.message.from.id // empty')

    [ -z "$chat_id" ] || [ -z "$text" ] && return

    # Security: only respond to the owner's chat
    if [ -n "$TELEGRAM_CHAT_ID" ] && [ "$chat_id" != "$TELEGRAM_CHAT_ID" ]; then
        log "Ignored message from unknown chat: $chat_id"
        return
    fi

    local cmd
    cmd=$(echo "$text" | awk '{print $1}' | tr '[:upper:]' '[:lower:]')
    local args
    args=$(echo "$text" | cut -d' ' -f2- | sed 's/^ *//')
    [ "$args" = "$cmd" ] && args=""  # no args if single word

    log "CMD: $cmd | ARGS: $args | FROM: $from_id"

    case "$cmd" in
        /help)        cmd_help "$chat_id" ;;
        /status)      cmd_status "$chat_id" ;;
        /discover)    cmd_discover "$chat_id" ;;
        /all)         cmd_all "$chat_id" ;;
        /commit)      cmd_commit "$chat_id" "$args" ;;
        /rollup)      cmd_rollup "$chat_id" ;;
        /weekly)      cmd_weekly "$chat_id" ;;
        /register)    cmd_register "$chat_id" "$args" ;;
        /unregister)  cmd_unregister "$chat_id" "$args" ;;
        /registered)  cmd_registered "$chat_id" ;;
        *)
            send "$chat_id" "❓ Unknown command. Try /help"
            ;;
    esac
}

# --- MAIN POLL LOOP ---

log "Bot started. Polling for updates..."

while true; do
    offset=$(get_offset)

    response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" \
        -d timeout=30 \
        -d offset="$offset" \
        --max-time 40 2>/dev/null || echo '{"ok":false}')

    if echo "$response" | jq -e '.ok' >/dev/null 2>&1; then
        updates=$(echo "$response" | jq -c '.result[]?' 2>/dev/null || true)

        if [ -n "$updates" ]; then
            while IFS= read -r update; do
                update_id=$(echo "$update" | jq -r '.update_id')
                process_update "$update"
                save_offset $(( update_id + 1 ))
            done <<< "$updates"
        fi
    else
        log "Poll error, retrying in 5s..."
        sleep 5
    fi
done
