#!/bin/bash
# ============================================================
# update-previews.sh — Auto-screenshot landing pages
# Smart: only retakes screenshot if page content changed
# Runs weekly via cron (Sundays 03:00 UTC)
# ============================================================

INSTALL_DIR="$HOME/smart-commit"
HASH_DIR="$INSTALL_DIR/logs/preview-hashes"
[ -f "$INSTALL_DIR/.env" ] && set -a && source "$INSTALL_DIR/.env" && set +a

mkdir -p "$HASH_DIR"

PUPPETEER_DIR="/tmp/node_modules/puppeteer"
if [ ! -d "$PUPPETEER_DIR" ]; then
    echo "[update-previews] installing puppeteer..."
    cd /tmp && npm install puppeteer --silent 2>/dev/null
fi

take_screenshot() {
    local url="$1"
    local output="$2"
    node -e "
const puppeteer = require('$PUPPETEER_DIR');
(async () => {
  const browser = await puppeteer.launch({args:['--no-sandbox','--disable-setuid-sandbox']});
  const page = await browser.newPage();
  await page.setViewport({width:1280, height:900});
  await page.goto('$url', {waitUntil:'networkidle0', timeout:15000});
  await page.screenshot({path:'$output', fullPage:false});
  await browser.close();
})().catch(e => { console.error(e.message); process.exit(1); });
" 2>/dev/null
}

page_changed() {
    local url="$1"
    local hash_file="$HASH_DIR/$(echo "$url" | md5sum | cut -d' ' -f1).hash"
    local current_hash
    current_hash=$(curl -s --max-time 10 "$url" | md5sum | cut -d' ' -f1)
    local stored_hash=""
    [ -f "$hash_file" ] && stored_hash=$(cat "$hash_file")
    if [ "$current_hash" != "$stored_hash" ]; then
        echo "$current_hash" > "$hash_file"
        return 0  # changed
    fi
    return 1  # unchanged
}

# ---- Project registry ----
# Format: "repo_path|landing_url|vps_asset_copies (colon-separated)"
PROJECTS=(
    "/opt/smartcommit|https://cryptopilot.dev/smartcommits|/opt/cryptopilotdev/projects/smartcommits/assets/preview.png"
    "/opt/uploader|https://cryptopilot.dev/uploader|/opt/cryptopilotdev/projects/uploader/assets/preview.png"
)

for entry in "${PROJECTS[@]}"; do
    IFS='|' read -r repo_path url vps_copy <<< "$entry"
    name=$(basename "$repo_path")
    asset_dir="$repo_path/assets"
    screenshot="$asset_dir/preview.png"

    mkdir -p "$asset_dir"

    if page_changed "$url"; then
        echo "[update-previews] change detected: $name — retaking screenshot..."
        if take_screenshot "$url" "$screenshot"; then
            # Mirror to cryptopilotdev for Caddy serving
            if [ -n "$vps_copy" ]; then
                mkdir -p "$(dirname "$vps_copy")"
                cp "$screenshot" "$vps_copy"
            fi
            # Commit if changed in git
            if ! git -C "$repo_path" diff --quiet "$screenshot" 2>/dev/null || \
               ! git -C "$repo_path" ls-files --error-unmatch "$screenshot" 2>/dev/null; then
                git -C "$repo_path" add "$screenshot"
                git -C "$repo_path" commit -m "chore(assets): update landing page preview screenshot"
                git -C "$repo_path" push 2>/dev/null &
                echo "[update-previews] ✓ committed: $name"
            else
                echo "[update-previews] screenshot unchanged in git: $name"
            fi
        else
            echo "[update-previews] ✗ screenshot failed: $url"
        fi
    else
        echo "[update-previews] no change: $name — skipping"
    fi
done
