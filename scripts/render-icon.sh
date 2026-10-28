#!/bin/sh
# Genera i PNG del glifo della menu bar da design/icon. L'icona dell'app è App/AppIcon.icon
# (Icon Composer: strati SVG in Assets, varianti scura e tinta in icon.json).
set -e
cd "$(dirname "$0")/.."
R="swift scripts/render-icon.swift"
GLYPH=App/Assets.xcassets/MenuBarGlyph.imageset
mkdir -p "$GLYPH"
$R design/icon/cupola-glyph.svg "$GLYPH/glyph.png" 18
$R design/icon/cupola-glyph.svg "$GLYPH/glyph@2x.png" 36
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
