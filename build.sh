#!/bin/bash
# build.sh — Compile ClaudeUsage.swift into a macOS menu bar app
#
# Usage:  bash build.sh
# Output: ClaudeUsage.app  (in the same folder)

set -e

APP="ClaudeUsage"
BUNDLE="${APP}.app"
CONTENTS="${BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"

# ── 1. Check prerequisites ───────────────────────────────────────────────────
if ! command -v swiftc &>/dev/null; then
    echo "❌  swiftc not found. Install Xcode Command Line Tools:"
    echo "    xcode-select --install"
    exit 1
fi

echo "✅  Swift $(swiftc --version 2>&1 | head -1)"

# ── 2. Compile ────────────────────────────────────────────────────────────────
echo "🔨  Compiling ${APP}.swift …"
swiftc -O -o "${APP}" "${APP}.swift"

# ── 3. Build app bundle ───────────────────────────────────────────────────────
echo "📦  Assembling ${BUNDLE} …"
rm -rf "${BUNDLE}"
mkdir -p "${MACOS}"

mv "${APP}" "${MACOS}/"

# ── 4. Write Info.plist ───────────────────────────────────────────────────────
cat > "${CONTENTS}/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <!-- Bundle identity -->
  <key>CFBundleExecutable</key>   <string>ClaudeUsage</string>
  <key>CFBundleIdentifier</key>   <string>com.local.ClaudeUsage</string>
  <key>CFBundleName</key>         <string>Claude Usage</string>
  <key>CFBundleVersion</key>      <string>1.0</string>
  <key>LSMinimumSystemVersion</key><string>12.0</string>

  <!-- Menu-bar-only: no Dock icon, no app switcher entry -->
  <key>LSUIElement</key>          <true/>

  <!-- Retina support -->
  <key>NSHighResolutionCapable</key><true/>

  <!-- Allow WKWebView to load claude.ai over HTTPS -->
  <key>NSAppTransportSecurity</key>
  <dict>
    <key>NSAllowsArbitraryLoads</key><false/>
    <key>NSExceptionDomains</key>
    <dict>
      <key>claude.ai</key>
      <dict>
        <key>NSIncludesSubdomains</key>              <true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><false/>
      </dict>
      <key>anthropic.com</key>
      <dict>
        <key>NSIncludesSubdomains</key>              <true/>
        <key>NSExceptionAllowsInsecureHTTPLoads</key><false/>
      </dict>
    </dict>
  </dict>
</dict>
</plist>
PLIST

# ── 5. Done ───────────────────────────────────────────────────────────────────
echo ""
echo "✅  Built: ${BUNDLE}"
echo ""
echo "── How to launch ──────────────────────────────────────────────────────"
echo "  From Terminal (removes Gatekeeper quarantine):"
echo "    xattr -cr ${BUNDLE} && open ${BUNDLE}"
echo ""
echo "  Or: right-click ${BUNDLE} → Open → Open"
echo ""
echo "── Auto-start at login ────────────────────────────────────────────────"
echo "  System Settings → General → Login Items → add ${BUNDLE}"
echo ""
echo "── Usage ──────────────────────────────────────────────────────────────"
echo "  • Left-click the gauge icon  → usage popover (reloads each time)"
echo "  • Right-click                → Reload / Open in Browser / Quit"
echo "  • Log into claude.ai once inside the popover — session persists"
echo "────────────────────────────────────────────────────────────────────────"
