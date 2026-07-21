#!/bin/bash
# Programa app icon pipeline — squircle-mask the committed master (AppIcon-1024.png).
# The master art (dark ground, glowing dither grid, darkroom-safelight red) is
# designed externally; this script only applies the macOS squircle + baked shadow.
set -euo pipefail
cd "$(dirname "$0")"

S=1024
cp AppIcon-1024.png art_square.png

# --- Squircle icon w/ baked shadow (for .appiconset) ----------------------
A=824; R=186; M=$(( (S - A) / 2 ))
magick -size ${S}x${S} xc:none -draw "roundrectangle $M,$M $((S-M-1)),$((S-M-1)) $R,$R" mask.png
magick art_square.png -resize ${A}x${A} -background none -gravity center -extent ${S}x${S} art_plate.png
magick art_plate.png mask.png -compose CopyOpacity -composite icon_noshadow.png
# baked drop shadow (black, not the mask's white fill)
magick mask.png -fill black -colorize 100 -channel A -evaluate multiply 0.45 +channel -blur 0x18 shadow.png
magick -size ${S}x${S} xc:none shadow.png -geometry +0+12 -compose over -composite PNG32:icon_shadow_layer.png
magick icon_noshadow.png icon_shadow_layer.png -compose DstOver -composite -colorspace sRGB PNG32:icon_master.png

echo done
