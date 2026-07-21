#!/bin/bash
# Emit all Programa icon assets from the master render (run gen.sh first).
set -euo pipefail
cd "$(dirname "$0")"
OUT=out; rm -rf $OUT; mkdir -p $OUT/main

emit() { # emit <srcmaster> <px> <dest>
  magick "$1" -resize "$2x$2" -unsharp 0x0.6+0.4+0 "PNG32:$3"
}

# Main appiconset (light + dark = same art; the icon IS the darkroom)
for spec in 16:16 32:16@2x 32:32 64:32@2x 128:128 256:128@2x 256:256 512:256@2x 512:512 1024:512@2x; do
  px=${spec%%:*}; name=${spec##*:}
  emit icon_master.png "$px" "$OUT/main/$name.png"
done

# Icon Composer layer (full-bleed square, system applies mask/shadow)
cp art_square.png $OUT/programa-terminal.png
# In-app imagesets (1024 with baked squircle)
cp icon_master.png $OUT/AppIconDark.png
cp icon_master.png $OUT/AppIconLight.png
echo done
