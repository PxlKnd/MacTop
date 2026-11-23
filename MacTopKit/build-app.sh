#!/bin/bash
# MacTopKit: WidgetKit-App (Schreibtisch-Widget) — Build ohne Xcode-Projekt
set -euo pipefail
cd "$(dirname "$0")"
APP=build/MacTopMonitor.app
EXT=$APP/Contents/PlugIns/MacTopMonitorWidget.appex
SDK=$(xcrun --sdk macosx --show-sdk-path)
ARCH=$(uname -m)

rm -rf build
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources $APP/Contents/PlugIns

echo "→ Compiliere Host-App ($ARCH)…"
xcrun swiftc -O -parse-as-library -sdk "$SDK" -target $ARCH-apple-macosx27.0 \
  app/main.swift -o $APP/Contents/MacOS/MacTopMonitor \
  -framework SwiftUI -framework AppKit -framework WidgetKit

echo "→ Compiliere Widget-Extension…"
mkdir -p $EXT/Contents/MacOS
xcrun swiftc -O -parse-as-library -application-extension -sdk "$SDK" -target $ARCH-apple-macosx27.0 \
  widget/MacTopWidget.swift widget/Metrics.swift \
  -o $EXT/Contents/MacOS/MacTopMonitorWidget.tmp \
  -Xlinker -e -Xlinker _NSExtensionMain \
  -Xlinker -application_extension \
  -framework SwiftUI -framework WidgetKit -framework Foundation \
  -framework IOKit -framework CoreServices -framework SystemConfiguration

# Extension-Binary braucht denselben Namen wie CFBundleExecutable → mv statt -o (Verzeichnis-Problem)
mv $EXT/Contents/MacOS/MacTopMonitorWidget.tmp $EXT/Contents/MacOS/MacTopMonitorWidget

cp app/Info.plist $APP/Contents/Info.plist
cp widget/Info.plist $EXT/Contents/Info.plist
printf 'APPL????' > $APP/Contents/PkgInfo
printf 'XPC!????' > $EXT/Contents/PkgInfo

echo "→ Signiere (Apple Development, Sandbox = Pflicht für Widget-Registrierung)…"
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' | head -n 1)}"
if [ -z "$IDENTITY" ]; then
  echo "Fehler: Keine 'Apple Development'-Signatur im Schlüsselbund gefunden (oder CODESIGN_IDENTITY setzen)." >&2
  exit 1
fi
codesign --force --options runtime -s "$IDENTITY" \
  --entitlements widget/entitlements.entitlements --timestamp=none $EXT
codesign --force --options runtime -s "$IDENTITY" \
  --entitlements app/entitlements.entitlements --timestamp=none $APP

if [ -w /Applications ]; then
  DEST=/Applications
else
  DEST=$HOME/Applications
  mkdir -p "$DEST"
fi
INSTALL=$DEST/MacTopMonitor.app
echo "→ Installiere nach $INSTALL …"
rm -rf "$INSTALL"
cp -R build/MacTopMonitor.app "$DEST/"

# Registrierung anstoßen (Version-Bump + NotificationCenter/chronod-Neustart aktualisiert den Galerie-Descriptor-Cache)
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$INSTALL"
pluginkit -r "$INSTALL/Contents/PlugIns/MacTopMonitorWidget.appex" 2>/dev/null || true
pluginkit -a "$INSTALL/Contents/PlugIns/MacTopMonitorWidget.appex" 2>/dev/null || true
pluginkit -e use -i com.soren.MacTopKit.widget 2>/dev/null || true
killall MacTopMonitor 2>/dev/null || true
killall MacTopMonitorWidget 2>/dev/null || true
killall chronod 2>/dev/null || true
killall NotificationCenter 2>/dev/null || true
sleep 2

echo "→ Fertig: $INSTALL"
echo '  Jetzt: Rechtsklick Schreibtisch → "Widgets bearbeiten…" → nach "MacTop Monitor" suchen → Medium oder Groß auf den Schreibtisch ziehen'
