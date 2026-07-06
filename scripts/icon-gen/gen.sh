#!/bin/bash
# Programa app icon generator — pixel-art terminal prompt, darkroom-safelight red.
set -euo pipefail
cd "$(dirname "$0")"

S=1024          # master canvas
C=44            # pixel cell size
GW=12; GH=8     # glyph grid
X0=$(( (S - GW*C) / 2 ))
Y0=$(( (S - GH*C) / 2 ))

# --- 1. Pixel glyph: ">" chevron + "_" cursor on a 12x8 grid -----------------
# cells as col ranges per row: row:colstart-colend (inclusive)
CHEVRON="0:0-1 1:0-3 2:2-5 3:4-7 4:4-7 5:2-5 6:0-3 7:0-1"
CURSOR="7:9-11"

draw=""
row_color() { # brighter at top, deeper at bottom — retro ramp
  case $1 in
    0) echo "#FF6248";; 1) echo "#FF5940";; 2) echo "#FA5038";; 3) echo "#F44730";;
    4) echo "#EE3F29";; 5) echo "#E63722";; 6) echo "#DE301C";; 7) echo "#D62A17";;
  esac
}
for spec in $CHEVRON; do
  r=${spec%%:*}; range=${spec##*:}; c1=${range%%-*}; c2=${range##*-}
  x1=$(( X0 + c1*C )); y1=$(( Y0 + r*C )); x2=$(( X0 + (c2+1)*C - 1 )); y2=$(( y1 + C - 1 ))
  draw+=" fill $(row_color $r) rectangle $x1,$y1 $x2,$y2"
done
for spec in $CURSOR; do
  r=${spec%%:*}; range=${spec##*:}; c1=${range%%-*}; c2=${range##*-}
  x1=$(( X0 + c1*C )); y1=$(( Y0 + r*C )); x2=$(( X0 + (c2+1)*C - 1 )); y2=$(( y1 + C - 1 ))
  draw+=" fill #FF8A66 rectangle $x1,$y1 $x2,$y2"
done

magick -size ${S}x${S} xc:none -draw "$draw" glyph.png

# --- 2. Background: near-black vertical gradient + vignette ------------------
magick -size ${S}x${S} gradient:'#1A191D'-'#0A090C' bg_grad.png
magick -size ${S}x${S} radial-gradient:'#00000000'-'#000000B0' vignette.png
magick bg_grad.png vignette.png -compose over -composite bg.png

# --- 3. Safelight glow: glyph flattened on black, blurred, screened on ------
# (screen with black = no-op, so only the glow adds light)
magick glyph.png -fill '#FF2D14' -colorize 45 -background black -alpha remove -alpha off \
  -blur 0x90 -evaluate multiply 0.62 glow_wide.png
magick glyph.png -background black -alpha remove -alpha off \
  -blur 0x22 -evaluate multiply 0.85 glow_tight.png

magick bg.png -alpha off \
  glow_wide.png  -compose screen -composite \
  glow_tight.png -compose screen -composite \
  glyph.png      -compose over   -composite \
  art_square.png

# --- 4. Squircle icon w/ baked shadow (for .appiconset) ----------------------
A=824; R=186; M=$(( (S - A) / 2 ))
magick -size ${S}x${S} xc:none -draw "roundrectangle $M,$M $((S-M-1)),$((S-M-1)) $R,$R" mask.png
magick art_square.png -resize ${A}x${A} -background none -gravity center -extent ${S}x${S} art_plate.png
magick art_plate.png mask.png -compose CopyOpacity -composite icon_noshadow.png
# baked drop shadow (black, not the mask's white fill)
magick mask.png -fill black -colorize 100 -channel A -evaluate multiply 0.45 +channel -blur 0x18 shadow.png
magick -size ${S}x${S} xc:none shadow.png -geometry +0+12 -compose over -composite PNG32:icon_shadow_layer.png
magick icon_noshadow.png icon_shadow_layer.png -compose DstOver -composite -colorspace sRGB PNG32:icon_master.png

echo done
