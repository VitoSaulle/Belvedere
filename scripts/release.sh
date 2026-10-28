#!/bin/sh
# Build da distribuire fuori dallo Store: universale, firmata Developer ID, notarizzata da Apple, in un DMG.
# Firma e notarizzazione: sul Mac passano dall'account del team configurato in Xcode; su GitHub Actions da una
# chiave API di App Store Connect (ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID). Nessuna password nello script.
# VERSION (es. 0.2.0) e BUILD_NUMBER, se presenti, finiscono nel bundle.
# SPARKLE_KEY_FILE (chiave privata EdDSA esportata con generate_keys -x) e SPARKLE_PUBLIC_KEY: firma del DMG
# per gli aggiornamenti e appcast.xml da allegare alla release. Senza, l'app esce con gli aggiornamenti spenti.
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
[ -n "$SPARKLE_PUBLIC_KEY" ] && VERSIONING="$VERSIONING SPARKLE_PUBLIC_KEY=$SPARKLE_PUBLIC_KEY"
REPO_URL=https://github.com/VitoSaulle/Belvedere
SPM=build/spm
fail() { tail -30 "$LOG" | grep -E "error|Error|failed" | head -15; echo "RELEASE FALLITA: $1 (log in $LOG)"; exit 1; }

# Sul Mac: firma automatica (certificato del team in Xcode). Su GitHub Actions il certificato gestito nel cloud
# non è usabile con una chiave API: SIGNING_STYLE=manual firma con il Developer ID importato nel portachiavi.
SIGNING_STYLE=${SIGNING_STYLE:-automatic}
SIGNING_CERT=""
[ "$SIGNING_STYLE" = manual ] && SIGNING_CERT="
  <key>signingCertificate</key><string>Developer ID Application</string>"

step "progetto e helper universali"
xcodegen generate --quiet
for p in belvedere-hook belvedere-statusline; do
  swift build -c release --arch arm64 --arch x86_64 --product "$p" >> "$LOG" 2>&1 || fail "helper $p"
done
HELPERS=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)

step "archivio Release"
xcodebuild -project Belvedere.xcodeproj -scheme Belvedere -configuration Release \
  -archivePath "$OUT/Belvedere.xcarchive" -clonedSourcePackagesDirPath "$SPM" -allowProvisioningUpdates $AUTH \
  HELPERS_DIR="$HELPERS" $VERSIONING archive >> "$LOG" 2>&1 || fail "archivio"

cat > "$OUT/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>$SIGNING_STYLE</string>$SIGNING_CERT
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
DMG="$OUT/Belvedere-$VERSION.dmg"

if [ -n "$SPARKLE_KEY_FILE" ] && [ -s "$SPARKLE_KEY_FILE" ]; then
  step "firma per Sparkle e appcast"
  BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
  MIN_OS=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
  SIGNATURE=$("$SPM/artifacts/sparkle/Sparkle/bin/sign_update" --ed-key-file "$SPARKLE_KEY_FILE" "$DMG") || fail "firma Sparkle"
  cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Belvedere</title>
    <link>$REPO_URL</link>
    <item>
      <title>Belvedere $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>$REPO_URL/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <enclosure url="$REPO_URL/releases/download/v$VERSION/Belvedere-$VERSION.dmg" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
XML
fi
echo "PRONTA: $DMG"
