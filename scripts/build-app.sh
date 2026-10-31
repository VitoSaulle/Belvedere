#!/bin/sh
# Build di sviluppo (firma ad-hoc): genera il progetto, compila gli helper, poi l'app che li copia nel bundle.
set -e
cd "$(dirname "$0")/.."
LOG=.superpowers/build-last.log
mkdir -p .superpowers
xcodegen generate --quiet
swift build -c release --product belvedere-hook > "$LOG" 2>&1
swift build -c release --product belvedere-statusline >> "$LOG" 2>&1
BIN=$(swift build -c release --show-bin-path)
xcodebuild -project Belvedere.xcodeproj -scheme Belvedere -configuration Debug \
  -derivedDataPath build/DerivedData HELPERS_DIR="$BIN" build >> "$LOG" 2>&1 || { grep -E "error:" "$LOG" | head -30; tail -25 "$LOG" | cut -c1-300; echo "BUILD FAILED"; exit 1; }
APP=build/DerivedData/Build/Products/Debug/Belvedere.app
grep -c "warning:" "$LOG" | xargs -I{} echo "warnings: {}"
echo "BUILD SUCCEEDED"
echo "$APP"
