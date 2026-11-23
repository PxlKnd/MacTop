#!/bin/bash
# Baut MacTopWidget und richtet optional den Autostart ein.
set -euo pipefail
cd "$(dirname "$0")"

echo "→ Kompiliere MacTopWidget ..."
swiftc -O Sources/Metrics.swift Sources/main.swift -o MacTopWidget \
    -framework Cocoa -framework IOKit -lIOReport

echo "→ Binär: $(pwd)/MacTopWidget ($(du -h MacTopWidget | cut -f1))"

if [[ "${1:-}" == "--install-autostart" ]]; then
    LABEL="com.soren.mactopwidget"
    PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$(pwd)/MacTopWidget</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    sleep 1
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || true
    echo "→ Autostart eingerichtet und gestartet: $PLIST"
elif [[ "${1:-}" == "--uninstall-autostart" ]]; then
    LABEL="com.soren.mactopwidget"
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
    echo "→ Autostart entfernt."
else
    echo "→ Starte einmalig: ./MacTopWidget &"
fi
