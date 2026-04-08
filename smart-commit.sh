#!/bin/bash
# ============================================================
# SMART-COMMIT — Intelligent auto-commit system for VPS
# Works with Claude Code, Codex, cron, or manual triggers
# ============================================================

set -euo pipefail

# --- CONFIG ---
COMMIT_LOG="$HOME/smart-commit/logs/commits.jsonl"
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID:-}"
OLLAMA_URL="http://localhost:11434"
OLLAMA_MODEL="llama3.1:8b"
MAX_DIFF_LINES=200
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- PROJECT REGISTRY ---
# Add all git repos here — auto-discovered or manual
PROJECTS_FILE="$SCRIPT_DIR/projects.json"

# --- COLORS ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# --- FUNCTIONS ---

log_info() { echo -e "${GREEN}[smart-commit]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[smart-commit]${NC} $1"; }
log_error() { echo -e "${RED}[smart-commit]${NC} $1"; }

# Discover all git repos under $HOME
discover_repos() {
    find "$HOME" -maxdepth 4 -name ".git" -type d 2>/dev/null | sed 's/\/.git$//'
}

# Get project name from repo path
get_project_name() {
    local repo_path="$1"
    basename "$repo_path"
}

# Check if repo has uncommitted changes
has_changes() {
    local repo_path="$1"
    cd "$repo_path"
    ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]
}

# Get a concise diff summary
get_diff_summary() {
    local repo_path="$1"
    cd "$repo_path"
    
    local summary=""
    
    # Staged + unstaged changes
    local changed_files
    changed_files=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null; git ls-files --others --exclude-standard 2>/dev/null)
    changed_files=$(echo "$changed_files" | sort -u)
    
    local file_count
    file_count=$(echo "$changed_files" | grep -c . || echo "0")
    
    # Get stat summary
    local stat
    stat=$(git diff --stat 2>/dev/null | tail -1)
    
    # Get truncated diff for AI commit message
    local diff_content
    diff_content=$(git diff 2>/dev/null | head -n "$MAX_DIFF_LINES")
    
    echo "$diff_content"
}

# Generate commit message using local Ollama
generate_commit_message() {
    local repo_path="$1"
    local project_name="$2"
    local diff_content="$3"
    
    # If diff is empty or tiny, use a simple message
    if [ ${#diff_content} -lt 10 ]; then
        echo "chore($project_name): minor updates"
        return
    fi
    
    # Truncate diff to avoid overloading Ollama
    local truncated_diff
    truncated_diff=$(echo "$diff_content" | head -c 3000)
    
    local prompt="You are a git commit message generator. Given the following git diff, write a single concise conventional commit message. Format: type(scope): description. Types: feat, fix, chore, refactor, docs, style, perf, test. Scope should be the module or area affected. Description should be under 72 chars. Reply with ONLY the commit message, nothing else.

Project: $project_name

Diff:
$truncated_diff"

    local response
    response=$(curl -s --max-time 15 "$OLLAMA_URL/api/generate" \
        -d "$(jq -n --arg model "$OLLAMA_MODEL" --arg prompt "$prompt" '{model: $model, prompt: $prompt, stream: false}')" \
        2>/dev/null | jq -r '.response // empty' 2>/dev/null)
    
    if [ -n "$response" ] && [ "$response" != "null" ]; then
        # Clean up response — take first line only, strip quotes
        echo "$response" | head -1 | sed 's/^["'\''"]//;s/["'\''"]$//' | head -c 100
    else
        # Fallback: generate from file names
        local files
        files=$(cd "$repo_path" && git diff --name-only 2>/dev/null | head -5 | tr '\n' ', ' | sed 's/,$//')
        echo "chore($project_name): update ${files:-files}"
    fi
}

# Commit and push a single repo
commit_repo() {
    local repo_path="$1"
    local source="${2:-auto}"  # auto, claude-code, codex, manual
    local custom_msg="${3:-}"
    
    local project_name
    project_name=$(get_project_name "$repo_path")
    
    cd "$repo_path"
    
    # Skip if no changes
    if ! has_changes "$repo_path"; then
        log_info "$project_name: no changes, skipping"
        return 0
    fi
    
    # Get diff summary
    local diff_content
    diff_content=$(get_diff_summary "$repo_path")
    
    # Generate or use custom commit message
    local commit_msg
    if [ -n "$custom_msg" ]; then
        commit_msg="$custom_msg"
    else
        log_info "$project_name: generating commit message..."
        commit_msg=$(generate_commit_message "$repo_path" "$project_name" "$diff_content")
    fi
    
    # Stage all changes
    git add -A
    
    # Get stats before committing
    local files_changed
    files_changed=$(git diff --cached --numstat | wc -l)
    local insertions
    insertions=$(git diff --cached --numstat | awk '{s+=$1} END {print s+0}')
    local deletions
    deletions=$(git diff --cached --numstat | awk '{s+=$1} END {print s+0}')
    
    # Commit
    git commit -m "$commit_msg" --no-verify 2>/dev/null
    
    # Push (non-blocking, don't fail if remote is down)
    git push 2>/dev/null &
    
    # Log to JSONL
    local log_entry
    log_entry=$(jq -n \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --arg project "$project_name" \
        --arg path "$repo_path" \
        --arg msg "$commit_msg" \
        --arg source "$source" \
        --argjson files "$files_changed" \
        --argjson adds "$insertions" \
        --argjson dels "$deletions" \
        '{timestamp: $ts, project: $project, path: $path, message: $msg, source: $source, files_changed: $files, insertions: $adds, deletions: $dels}')
    
    mkdir -p "$(dirname "$COMMIT_LOG")"
    echo "$log_entry" >> "$COMMIT_LOG"
    
    log_info "$project_name: ✓ committed — $commit_msg"
    
    return 0
}

# Commit all repos that have changes
commit_all() {
    local source="${1:-auto}"
    local committed=0
    local skipped=0
    
    log_info "Scanning all repos..."
    
    while IFS= read -r repo; do
        if has_changes "$repo"; then
            commit_repo "$repo" "$source"
            ((committed++))
        else
            ((skipped++))
        fi
    done < <(discover_repos)
    
    log_info "Done: $committed committed, $skipped skipped"
    
    # Send Telegram notification if any commits were made
    if [ "$committed" -gt 0 ] && [ -n "$TELEGRAM_BOT_TOKEN" ]; then
        send_telegram "🔄 Smart-commit: $committed repos updated"
    fi
}

# Daily rollup — summarize the day's commits and send to Telegram
daily_rollup() {
    local today
    today=$(date -u +%Y-%m-%d)
    
    if [ ! -f "$COMMIT_LOG" ]; then
        log_warn "No commit log found"
        return
    fi
    
    local today_commits
    today_commits=$(grep "\"$today" "$COMMIT_LOG" 2>/dev/null || true)
    
    if [ -z "$today_commits" ]; then
        send_telegram "📊 Daily Commit Rollup — $today
No commits today. Touch grass day? 🌱"
        return
    fi
    
    local total
    total=$(echo "$today_commits" | wc -l)
    
    local projects
    projects=$(echo "$today_commits" | jq -r '.project' | sort -u | tr '\n' ', ' | sed 's/,$//')
    
    local by_project
    by_project=$(echo "$today_commits" | jq -r '.project' | sort | uniq -c | sort -rn | head -10 | awk '{printf "  • %s: %d commits\n", $2, $1}')
    
    local by_source
    by_source=$(echo "$today_commits" | jq -r '.source' | sort | uniq -c | sort -rn | awk '{printf "  • %s: %d\n", $2, $1}')
    
    local recent_msgs
    recent_msgs=$(echo "$today_commits" | tail -5 | jq -r '"  → " + .message' 2>/dev/null)
    
    local msg="📊 Daily Commit Rollup — $today

Total: $total commits
Projects: $projects

By project:
$by_project

By source:
$by_source

Recent:
$recent_msgs"
    
    send_telegram "$msg"
    log_info "Daily rollup sent to Telegram"
}

# Weekly rollup — summarize the week's commits
weekly_rollup() {
    local today
    today=$(date -u +%Y-%m-%d)

    if [ ! -f "$COMMIT_LOG" ]; then
        log_warn "No commit log found"
        return
    fi

    # Last 7 days
    local week_commits=""
    for i in $(seq 0 6); do
        local day
        day=$(date -u -d "$i days ago" +%Y-%m-%d 2>/dev/null || date -u -v-${i}d +%Y-%m-%d)
        week_commits+=$(grep "\"$day" "$COMMIT_LOG" 2>/dev/null || true)
        week_commits+=$'\n'
    done
    week_commits=$(echo "$week_commits" | grep -v '^$' || true)

    if [ -z "$week_commits" ]; then
        send_telegram "📅 Weekly Commit Rollup
No commits this week."
        return
    fi

    local total
    total=$(echo "$week_commits" | wc -l)

    local projects
    projects=$(echo "$week_commits" | jq -r '.project' | sort -u | wc -l)

    local top_projects
    top_projects=$(echo "$week_commits" | jq -r '.project' | sort | uniq -c | sort -rn | head -5 | awk '{printf "  • %s: %d commits\n", $2, $1}')

    local by_source
    by_source=$(echo "$week_commits" | jq -r '.source' | sort | uniq -c | sort -rn | awk '{printf "  • %s: %d\n", $2, $1}')

    local msg="📅 Weekly Commit Rollup

$total commits across $projects projects

Top projects:
$top_projects

By source:
$by_source"

    send_telegram "$msg"
    log_info "Weekly rollup sent to Telegram"
}

# Send Telegram message
send_telegram() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="$TELEGRAM_CHAT_ID" \
            -d text="$message" \
            -d parse_mode="Markdown" \
            --max-time 10 >/dev/null 2>&1 || true
    fi
}

# --- CLI ---
case "${1:-help}" in
    commit)
        # Commit a specific repo
        repo="${2:-.}"
        source="${3:-manual}"
        msg="${4:-}"
        if [ "$repo" = "." ]; then
            repo=$(pwd)
        fi
        commit_repo "$repo" "$source" "$msg"
        ;;
    all)
        # Commit all repos with changes
        source="${2:-auto}"
        commit_all "$source"
        ;;
    rollup)
        daily_rollup
        ;;
    weekly)
        weekly_rollup
        ;;
    discover)
        echo "Git repos found:"
        discover_repos | while read -r r; do
            name=$(get_project_name "$r")
            if has_changes "$r"; then
                echo "  ● $name ($r) — HAS CHANGES"
            else
                echo "  ○ $name ($r) — clean"
            fi
        done
        ;;
    status)
        echo "=== Smart-Commit Status ==="
        echo ""
        echo "Repos:"
        discover_repos | while read -r r; do
            name=$(get_project_name "$r")
            if has_changes "$r"; then
                changed=$(cd "$r" && git status --porcelain | wc -l)
                echo "  ● $name: $changed files changed"
            else
                echo "  ○ $name: clean"
            fi
        done
        echo ""
        if [ -f "$COMMIT_LOG" ]; then
            local today=$(date -u +%Y-%m-%d)
            local today_count=$(grep -c "$today" "$COMMIT_LOG" 2>/dev/null || echo "0")
            local total_count=$(wc -l < "$COMMIT_LOG" 2>/dev/null || echo "0")
            echo "Commits today: $today_count"
            echo "Commits total: $total_count"
        else
            echo "No commit history yet"
        fi
        ;;
    help|*)
        echo "Smart-Commit — Intelligent auto-commit system"
        echo ""
        echo "Usage:"
        echo "  smart-commit commit [repo_path] [source] [message]  — Commit specific repo"
        echo "  smart-commit all [source]                           — Commit all dirty repos"
        echo "  smart-commit rollup                                 — Send daily Telegram rollup"
        echo "  smart-commit discover                               — List all repos & status"
        echo "  smart-commit status                                 — Show system status"
        echo ""
        echo "Sources: auto, claude-code, codex, manual"
        echo ""
        echo "Examples:"
        echo "  smart-commit commit /path/to/repo claude-code"
        echo "  smart-commit all codex"
        echo "  smart-commit commit . manual 'feat: add new endpoint'"
        ;;
esac
