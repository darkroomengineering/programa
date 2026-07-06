#!/bin/bash
# Emit all Programa icon assets from the master renders (run gen.sh first).
set -euo pipefail
cd "$(dirname "$0")"
OUT=out; rm -rf $OUT; mkdir -p $OUT/main $OUT/nightly

# Small-size variant: no glow (kills contrast at 16/32), boosted glyph
magick bg.png -alpha off glyph.png -compose over -composite PNG32:art_small_square.png
A=824; S=1024; R=186; M=$(( (S - A) / 2 ))
magick art_small_square.png -resize ${A}x${A} -background none -gravity center -extent ${S}x${S} \
  mask.png -compose CopyOpacity -composite -modulate 108,118 PNG32:icon_small_master.png

emit() { # emit <srcmaster> <px> <dest>
  magick "$1" -resize "$2x$2" -unsharp 0x0.6+0.4+0 "PNG32:$3"
}

# Main appiconset (light + dark = same art; the icon IS the darkroom)
for spec in 16:16 32:16@2x 32:32 64:32@2x 128:128 256:128@2x 256:256 512:256@2x 512:512 1024:512@2x; do
  px=${spec%%:*}; name=${spec##*:}
  src=icon_master.png; [ "$px" -le 32 ] && src=icon_small_master.png
  emit $src "$px" "$OUT/main/$name.png"
  cp "$OUT/main/$name.png" "$OUT/main/${name}_dark.png"
done

# Nightly: amber banner + NIGHTLY text, clipped by squircle, then sizes
BANNER_TOP=724
magick art_plate.png \
  \( -size ${S}x$((S-BANNER_TOP)) xc:'#FFB000' \) -geometry +0+${BANNER_TOP} -compose over -composite \
  -font /System/Library/Fonts/Helvetica.ttc -weight bold -pointsize 118 -fill black \
  -gravity south -annotate +0+92 'NIGHTLY' \
  mask.png -compose CopyOpacity -composite PNG32:nightly_noshadow.png
magick nightly_noshadow.png icon_shadow_layer.png -compose DstOver -composite -colorspace sRGB PNG32:nightly_master.png
for spec in 16:16 32:16@2x 32:32 64:32@2x 128:128 256:128@2x 256:256 512:256@2x 512:512 1024:512@2x; do
  px=${spec%%:*}; name=${spec##*:}
  emit nightly_master.png "$px" "$OUT/nightly/$name.png"
done

# Icon Composer layer (full-bleed square, system applies mask/shadow)
cp art_square.png $OUT/programa-terminal.png
# In-app imagesets (1024 with baked squircle)
cp icon_master.png $OUT/AppIconDark.png
cp icon_master.png $OUT/AppIconLight.png
echo done
