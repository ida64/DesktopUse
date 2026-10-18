#!/bin/zsh
# Builds claude-desktop-use and registers it with Claude Code and/or Claude Desktop.
set -euo pipefail
cd "${0:A:h}"

swift build -c release
BIN="$PWD/.build/release/claude-desktop-use"
mkdir -p "$HOME/.local/bin"
ln -sf "$BIN" "$HOME/.local/bin/claude-desktop-use"
echo "✅ Built $BIN"

if command -v claude >/dev/null; then
  claude mcp add --scope user desktop-use -- "$BIN" 2>/dev/null \
    && echo "✅ Registered with Claude Code (user scope) as 'desktop-use'" \
    || echo "ℹ️  Claude Code: already registered (or run: claude mcp add --scope user desktop-use -- $BIN)"
fi

DESKTOP_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
if [[ -d "${DESKTOP_CONFIG:h}" ]]; then
  /usr/bin/python3 - "$DESKTOP_CONFIG" "$BIN" <<'EOF'
import json, os, sys
path, binary = sys.argv[1], sys.argv[2]
config = json.load(open(path)) if os.path.exists(path) else {}
config.setdefault("mcpServers", {})["desktop-use"] = {"command": binary}
json.dump(config, open(path, "w"), indent=2)
print("✅ Registered with Claude Desktop (restart the app to load it)")
EOF
fi

echo
echo "Next: grant Accessibility and Screen Recording to the app that runs the server"
echo "(Terminal/iTerm for Claude Code, Claude.app for Claude Desktop), then restart it."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
