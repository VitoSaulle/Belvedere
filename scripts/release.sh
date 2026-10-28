#!/bin/sh
# Build da distribuire fuori dallo Store: universale, firmata Developer ID, notarizzata da Apple, in un DMG.
# Firma e notarizzazione: sul Mac passano dall'account del team configurato in Xcode; su GitHub Actions da una
# chiave API di App Store Connect (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID). Nessuna password nello script.
# VERSION (es. 0.2.0) e BUILD_NUMBER, se presenti, finiscono nel bundle.
set -e
cd "$(dirname "$0")/.."
TEAM=94BHT7B4R9
OUT=build/release
LOG=.superpowers/release-last.log
rm -rf "$OUT"
mkdir -p "$OUT" .superpowers
: > "$LOG"

step() { echo "· $1"; }
AUTH=""
if [ -n "$ASC_KEY_PATH" ]; then
  AUTH="-authenticationKeyPath $ASC_KEY_PATH -authenticationKeyID $ASC_KEY_ID -authenticationKeyIssuerID $ASC_ISSUER_ID"
fi
VERSIONING=""
[ -n "$VERSION" ] && VERSIONING="MARKETING_VERSION=$VERSION"
[ -n "$BUILD_NUMBER" ] && VERSIONING="$VERSIONING CURRENT_PROJECT_VERSION=$BUILD_NUMBER"
fail() { tail -30 "$LOG" | grep -E "error|Error|failed" | head -15; echo "RELEASE FALLITA: $1 (log in $LOG)"; exit 1; }

step "progetto e helper universali"
xcodegen generate --quiet
for p in belvedere-hook belvedere-statusline; do
  swift build -c release --arch arm64 --arch x86_64 --product "$p" >> "$LOG" 2>&1 || fail "helper $p"
done
HELPERS=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

step "archivio Release"
xcodebuild -project Belvedere.xcodeproj -scheme Belvedere -configuration Release \
  -archivePath "$OUT/Belvedere.xcarchive" -allowProvisioningUpdates $AUTH \
  HELPERS_DIR="$HELPERS" $VERSIONING archive >> "$LOG" 2>&1 || fail "archivio"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>upload</string>
</dict>
</plist>
PLIST

step "firma Developer ID e invio alla notarizzazione"
xcodebuild -exportArchive -archivePath "$OUT/Belvedere.xcarchive" -exportOptionsPlist "$OUT/ExportOptions.plist" \
 -exportPath "$OUT/upload" -allowProvisioningUpdates $AUTH >> "$LOG" 2>&1 || fail "esportazione"

step "attesa della notarizzazione (di solito pochi minuti)"
i=0
until xcodebuild -exportNotarizedApp -archivePath "$OUT/Belvedere.xcarchive" -exportPath "$OUT/app" $AUTH >> "$LOG" 2>&1; do
  i=$((i + 1))
  [ $i -ge 60 ] && fail "notarizzazione non arrivata in 30 minuti"
  sleep 30
done
APP="$OUT/app/Belvedere.app"

step "verifica"
codesign --verify --deep --strict "$APP" >> "$LOG" 2>&1 || fail "firma"
spctl --assess --type execute "$APP" >> "$LOG" 2>&1 || fail "Gatekeeper"
xcrun stapler validate "$APP" >> "$LOG" 2>&1 || fail "ticket di notarizzazione"

step "DMG"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applicazioni"
hdiutil create -volname "Belvedere $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$OUT/Belvedere-$VERSION.dmg" >> "$LOG" 2>&1 || fail "DMG"
echo "PRONTA: $OUT/Belvedere-$VERSION.dmg"
