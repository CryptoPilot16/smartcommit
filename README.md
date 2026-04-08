# 🔁 Smart-Commit

Autopilot commits across all your repos.

## What it does

- **Detects dirty repos** across all projects under `~/projects`
- **Generates meaningful commit messages** using local Ollama (llama3.1:8b) — no API costs
- **Skips clean repos** — no empty commits, no noise
- **Tags commit source** — know if a commit came from Claude Code, Codex, cron, or manual
- **Logs everything** to JSONL for analytics
- **Daily Telegram rollup** — wake up to a summary of what shipped
- **Git hooks** — even manual commits get logged to the system

## Architecture

```
┌─────────────────┐  ┌──────────────┐  ┌──────────────┐
│  Claude Code    │  │    Codex     │  │  Cron (2h)   │
│  post-task hook │  │  post-task   │  │  auto-sweep  │
└────────┬────────┘  └──────┬───────┘  └──────┬───────┘
         │                  │                  │
         └──────────────────┼──────────────────┘
                            │
                   ┌────────▼────────┐
                   │  smart-commit   │
                   │    engine       │
                   └────────┬────────┘
                            │
              ┌─────────────┼─────────────┐
              │             │             │
       ┌──────▼──────┐ ┌───▼────┐ ┌──────▼──────┐
       │ Ollama LLM  │ │  Git   │ │  Telegram   │
       │ commit msg  │ │ commit │ │  rollup     │
       └─────────────┘ └────────┘ └─────────────┘
```

## Commands

```bash
smart-commit discover              # List all repos and their status
smart-commit status                # System overview
smart-commit all [source]          # Commit all dirty repos
smart-commit commit [path] [source] [msg]  # Commit specific repo
smart-commit rollup                # Send daily Telegram summary
smart-commit weekly                # Send weekly Telegram summary
```

## Sources

| Source | When |
|--------|------|
| `auto` | Cron job sweep (default) |
| `claude-code` | Claude Code task completion |
| `codex` | Codex task completion |
| `manual` | You ran it yourself |
| `direct` | Git hook caught a manual `git commit` |

## Setup

```bash
# 1. Run installer
bash ~/projects/smart-commit/install.sh

# 2. Edit env file with Telegram creds
nano ~/projects/smart-commit/.env

# 3. Test
smart-commit discover
smart-commit all
```

## Claude Code Integration

After each Claude Code task, run:
```bash
~/projects/smart-commit/hooks/post-task-claude.sh $(pwd)
```

Or add to your Claude Code workflow/CLAUDE.md:
```
After completing any task, run: smart-commit commit . claude-code
```

## Codex Integration

Same pattern:
```bash
~/projects/smart-commit/hooks/post-task-codex.sh $(pwd)
```

## Commit Log Format

All commits logged to `~/projects/smart-commit/logs/commits.jsonl`:

```json
{
  "timestamp": "2026-04-08T14:30:00Z",
  "project": "my-app",
  "path": "~/projects/my-app",
  "message": "feat(api): add rate limiting middleware",
  "source": "claude-code",
  "files_changed": 3,
  "insertions": 47,
  "deletions": 12
}
```

## Telegram Notifications

| When | What |
|------|------|
| After every sweep (if commits made) | 🔄 X repos updated |
| When a new repo is auto-created | 🆕 New repo created on GitHub |
| 23:55 UTC daily | 📊 Daily commit rollup |
| Monday 08:00 UTC | 📅 Weekly commit rollup |

## Cron Schedule

| When | What |
|------|------|
| Every hour | Wire any new repos |
| Every 2 hours | Auto-commit all dirty repos |
| 23:55 UTC daily | Daily Telegram rollup |
| Monday 08:00 UTC | Weekly Telegram rollup |
