#!/bin/bash
# ============================================================
# update-previews.sh — Auto-screenshot landing pages
# Updates assets/preview.png in each project repo and commits
# Runs weekly (low frequency — pages don't change often)
# ============================================================

INSTALL_DIR="$HOME/smart-commit"
[ -f "$INSTALL_DIR/.env" ] && set -a && source "$INSTALL_DIR/.env" && set +a

PUPPETEER_DIR="/tmp/node_modules/puppeteer"

# Install puppeteer if not present
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

# ---- Project registry ----
# Format: "repo_path|landing_url"
PROJECTS=(
    "/opt/smartcommit|https://cryptopilot.dev/smartcommits"
    "/opt/uploader|https://cryptopilot.dev/uploader"
)

for entry in "${PROJECTS[@]}"; do
    repo_path="${entry%%|*}"
    url="${entry##*|}"
    name=$(basename "$repo_path")
    asset_dir="$repo_path/assets"
    screenshot="$asset_dir/preview.png"

    mkdir -p "$asset_dir"

    echo "[update-previews] screenshotting $url..."
    if take_screenshot "$url" "$screenshot"; then
        # Commit if changed
        if ! git -C "$repo_path" diff --quiet "$screenshot" 2>/dev/null || \
           ! git -C "$repo_path" ls-files --error-unmatch "$screenshot" 2>/dev/null; then
            git -C "$repo_path" add "$screenshot"
            git -C "$repo_path" commit -m "chore(assets): update landing page preview screenshot" 2>/dev/null
            git -C "$repo_path" push 2>/dev/null &
            echo "[update-previews] ✓ updated: $name"
        else
            echo "[update-previews] unchanged: $name"
        fi
    else
        echo "[update-previews] ✗ screenshot failed: $url"
    fi
done
