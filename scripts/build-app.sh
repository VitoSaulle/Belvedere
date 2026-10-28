#!/bin/sh
# Genera il progetto, compila gli helper e l'app, copia gli helper nel bundle.
set -e
cd "$(dirname "$0")/.."
LOG=.superpowers/build-last.log
mkdir -p .superpowers
xcodegen generate --quiet
swift build -c release --product belvedere-hook > "$LOG" 2>&1
swift build -c release --product belvedere-statusline >> "$LOG" 2>&1
BIN=$(swift build -c release --show-bin-path)
xcodebuild -project Belvedere.xcodeproj -scheme Belvedere -configuration Debug \
  -derivedDataPath build/DerivedData build >> "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -30; echo "BUILD FAILED"; exit 1; }
APP=build/DerivedData/Build/Products/Debug/Belvedere.app
mkdir -p "$APP/Contents/Helpers"
cp "$BIN/belvedere-hook" "$BIN/belvedere-statusline" "$APP/Contents/Helpers/"
codesign --force --sign - "$APP/Contents/Helpers/belvedere-hook" "$APP/Contents/Helpers/belvedere-statusline" >> "$LOG" 2>&1
codesign --force --sign - "$APP" >> "$LOG" 2>&1
grep -c "warning:" "$LOG" | xargs -I{} echo "warnings: {}"
echo "BUILD SUCCEEDED"
echo "$APP"
