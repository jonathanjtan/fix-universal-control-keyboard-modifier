#!/bin/bash
# ucmodswap installer.
#
#   ./install.sh              build, install, and start the agent
#   ./install.sh --uninstall  remove everything it wrote
#
# Builds a small Swift binary that taps the Quartz event stream and swaps
# option<->command on keyboards arriving over Universal Control. Needs the
# Command Line Tools for swiftc, and one Accessibility grant.
set -euo pipefail

LABEL="local.ucmodswap"
# Installed under ~/Applications rather than ~/.local: the Accessibility
# file picker hides dotted directories, which makes granting the permission
# needlessly painful.
APP="$HOME/Applications/ucmodswap.app"
BIN="$APP/Contents/MacOS/ucmodswap"
BINDIR="$HOME/.local/bin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ucmodswap.swift"
UID_="$(id -u)"

if [ "$(uname -s)" != "Darwin" ]; then
  echo "This only makes sense on macOS." >&2
  exit 1
fi

if [ "${1:-}" = "--uninstall" ] || [ "${1:-}" = "uninstall" ]; then
  launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
  rm -f "$PLIST" "$BINDIR/ucmodswap"
  rm -rf "$APP"
  echo "Removed. Log left at ~/Library/Logs/ucmodswap.log."
  echo "Revoke the leftover entry in System Settings > Privacy & Security > Accessibility by hand."
  exit 0
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Command Line Tools:  xcode-select --install" >&2
  exit 1
fi
[ -f "$SRC" ] || { echo "cannot find $SRC" >&2; exit 1; }

echo "Building..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$BINDIR" "$HOME/Library/LaunchAgents" "$HOME/Applications"

cat > "$APP/Contents/Info.plist" <<'PLIST_INNER_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ucmodswap</string>
  <key>CFBundleIdentifier</key><string>local.ucmodswap</string>
  <key>CFBundleName</key><string>ucmodswap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
</dict>
</plist>
PLIST_INNER_EOF

xcrun swiftc -O -o "$BIN" "$SRC"
# Ad-hoc signing gives TCC a stable identity to hang the Accessibility grant on.
# Without it the grant is dropped every time the binary is rebuilt.
codesign --force --sign - --identifier "$LABEL" "$APP"

CFGDIR="$HOME/.config/ucmodswap"
mkdir -p "$CFGDIR"
if [ ! -f "$CFGDIR/config.json" ]; then
  cat > "$CFGDIR/config.json" <<'CFG_EOF'
{
  "_comment": "swapPattern is a case-insensitive regex tested against the originating device's row in `hidutil list`. Universal Control publishes its devices as 'V-<original name>'. The negative lookahead skips Apple keyboards shared over Universal Control, which already have Mac modifier placement. Edit this file and run `kill -HUP $(pgrep -f ucmodswap.app)` to reload without rebuilding.",
  "swapPattern": " V-(?!Apple)",
  "learnOnly": false,
  "refreshSeconds": 3
}
CFG_EOF
fi

cat > "$BINDIR/ucmodswap" <<WRAP_EOF
#!/bin/sh
exec "$BIN" "\$@"
WRAP_EOF
chmod +x "$BINDIR/ucmodswap"

cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$BIN</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- Interactive, not Background: macOS disables an event tap whose callback
       is slow to return, and a throttled process gets there easily. -->
  <key>ProcessType</key><string>Interactive</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/ucmodswap.err.log</string>
</dict>
</plist>
PLIST_EOF

launchctl bootout "gui/$UID_/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_" "$PLIST"
launchctl kickstart -k "gui/$UID_/$LABEL" >/dev/null 2>&1 || true

echo
echo "Installed."
echo "  app     $APP"
echo "  agent   $PLIST"
echo "  log     ~/Library/Logs/ucmodswap.log"
echo "  config  $HOME/.config/ucmodswap/config.json"
echo "  cli     $BINDIR/ucmodswap  (check | probe)"
echo

if "$BIN" check >/dev/null 2>&1; then
  echo "Accessibility is already granted -- the swap is live."
else
  cat <<'NEEDPERM'
One thing left: grant Accessibility.

  System Settings > Privacy & Security > Accessibility > turn on "ucmodswap"

If it is not listed, add it with "+", then press Cmd-Shift-G and paste:
  ~/Applications/ucmodswap.app

The agent is already running and will start swapping the moment you flip it on;
no restart or logout needed.
NEEDPERM
fi
