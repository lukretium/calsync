#!/bin/bash
# ./install.sh          App bauen (falls Quellcode neuer), nach ~/Applications, Kalenderzugriff
#                       anfragen, Config-Vorlage anlegen. Auch für Updates nach git pull.
# ./install.sh enable   Hintergrund-Sync alle 10 Minuten aktivieren
# ./install.sh disable  Hintergrund-Sync stoppen
# ./install.sh watch <Firmenkalender>   Auf dem Hauptrechner: alle 15 Minuten prüfen, ob alle
#                       Instanzen laufen, sonst macOS-Mitteilung. "watch off" stoppt das.
set -euo pipefail
cd "$(dirname "$0")"
APP="$HOME/Applications/CalSync.app"
CFG="$HOME/.config/calsync/config.json"
LABEL=com.lukretium.calsync
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
WLABEL=$LABEL.watch
WPLIST="$HOME/Library/LaunchAgents/$WLABEL.plist"

case "${1:-install}" in
install)
  BIN=build/CalSync.app/Contents/MacOS/calsync
  if [ ! -f "$BIN" ] || [ main.swift -nt "$BIN" ] || [ Info.plist -nt "$BIN" ]; then
    command -v swiftc >/dev/null || { echo "swiftc fehlt: erst 'xcode-select --install', dann nochmal."; exit 1; }
    echo "Baue CalSync (dauert ca. 1 Minute) ..."
    ./build.sh
  fi
  mkdir -p "$HOME/Applications"
  rm -rf "$APP" && cp -R build/CalSync.app "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
  echo "Kalenderzugriff anfragen: Dialog bestätigen (liegt evtl. hinter anderen Fenstern) ..."
  ./calsync list
  if [ ! -f "$CFG" ]; then
    mkdir -p "$(dirname "$CFG")"
    cp config.example.json "$CFG"
    echo "Config-Vorlage: $CFG  (Kalender aus der Liste oben eintragen)"
  fi
  echo "Test: ./calsync sync --dry-run   danach: ./install.sh enable"
  ;;
enable)
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/calsync</string><string>sync</string></array>
  <key>StartInterval</key><integer>600</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/calsync.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/calsync.log</string>
</dict>
</plist>
PL
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "aktiv, Log: tail -f ~/Library/Logs/calsync.log"
  ;;
disable)
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "gestoppt (gespiegelte Termine entfernen: ./calsync clean)"
  ;;
watch)
  launchctl bootout "gui/$(id -u)/$WLABEL" 2>/dev/null || true
  if [ "${2:-}" = off ]; then rm -f "$WPLIST"; echo "Wächter gestoppt"; exit 0; fi
  [ -n "${2:-}" ] || { echo "usage: ./install.sh watch <Firmenkalender aus ./calsync list> | off"; exit 2; }
  cat > "$WPLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WLABEL</string>
  <key>ProgramArguments</key><array><string>$APP/Contents/MacOS/calsync</string><string>watch</string><string>$2</string></array>
  <key>StartInterval</key><integer>900</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/calsync-watch.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/calsync-watch.log</string>
</dict>
</plist>
PL
  launchctl bootstrap "gui/$(id -u)" "$WPLIST"
  echo "Wächter aktiv, Log: tail ~/Library/Logs/calsync-watch.log"
  ;;
esac
