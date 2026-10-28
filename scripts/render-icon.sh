#!/bin/sh
# Genera i PNG dell'icona dell'app e del glifo della menu bar dagli SVG in design/icon.
set -e
cd "$(dirname "$0")/.."
R="swift scripts/render-icon.swift"
ICON=App/Assets.xcassets/AppIcon.appiconset
GLYPH=App/Assets.xcassets/MenuBarGlyph.imageset
mkdir -p "$ICON" "$GLYPH"
for s in 16 32 128 256 512; do
  $R design/icon/cupola.svg "$ICON/icon_${s}.png" $s
  $R design/icon/cupola.svg "$ICON/icon_${s}@2x.png" $((s * 2))
done
$R design/icon/cupola-glyph.svg "$GLYPH/glyph.png" 18
$R design/icon/cupola-glyph.svg "$GLYPH/glyph@2x.png" 36
cat > "$ICON/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16", "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16", "filename" : "icon_16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32", "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32", "filename" : "icon_32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON
cat > "$GLYPH/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "universal", "scale" : "1x", "filename" : "glyph.png" },
    { "idiom" : "universal", "scale" : "2x", "filename" : "glyph@2x.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 },
  "properties" : { "template-rendering-intent" : "template" }
}
JSON
echo "icone generate"
