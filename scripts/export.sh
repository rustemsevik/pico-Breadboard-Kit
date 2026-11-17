#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Regenerate all manufacturing and documentation outputs from the KiCad project.
#
#   fabrication/  gerber + drill zip, BOM, pick-and-place (top, SMD only)
#   docs/         schematic PDF + SVG, top and bottom 3D renders
#
# Requires kicad-cli from KiCad 10.
# Usage:  scripts/export.sh            # export, report ERC/DRC results
#         scripts/export.sh --strict   # stop if ERC or DRC reports errors
# -----------------------------------------------------------------------------
set -euo pipefail

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HW="$ROOT/hardware"
FAB="$ROOT/fabrication"
DOCS="$ROOT/docs"
NAME="pico-breadboard"
SCH="$HW/$NAME.kicad_sch"
PCB="$HW/$NAME.kicad_pcb"

command -v kicad-cli >/dev/null || { echo "kicad-cli not found (install KiCad 10)"; exit 1; }
echo "Using $(kicad-cli version | head -1) (KiCad 10 required)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$FAB" "$DOCS"

# --- Checks ------------------------------------------------------------------
echo "== ERC / DRC"
erc_rc=0; drc_rc=0
kicad-cli sch erc --severity-error --exit-code-violations \
    -o "$TMP/erc.rpt" "$SCH" >/dev/null || erc_rc=$?
kicad-cli pcb drc --severity-error --schematic-parity --exit-code-violations \
    -o "$TMP/drc.rpt" "$PCB" >/dev/null || drc_rc=$?
if (( erc_rc || drc_rc )); then
    grep -hE '^\[|^    @' "$TMP/erc.rpt" "$TMP/drc.rpt" || true
    echo "ERC/DRC reported errors (see above)."
    (( STRICT )) && exit 1
else
    echo "ERC/DRC: no errors"
fi

# --- Gerbers + drill -> zip ------------------------------------------------------
echo "== Gerbers"
mkdir -p "$TMP/gerbers"
kicad-cli pcb export gerbers --board-plot-params -o "$TMP/gerbers/" "$PCB" >/dev/null
kicad-cli pcb export drill --format excellon --excellon-separate-th \
    --excellon-units mm --excellon-zeros-format decimal \
    -o "$TMP/gerbers/" "$PCB" >/dev/null
rm -f "$FAB/$NAME-gerbers.zip"
(cd "$TMP/gerbers" && zip -q -X "$FAB/$NAME-gerbers.zip" *)

# --- Pick and place (origin = board bottom-left, set as drill/aux origin) -----
echo "== Pick and place"
kicad-cli pcb export pos --side front --format csv --units mm --smd-only \
    --use-drill-file-origin -o "$FAB/$NAME-top-pos.csv" "$PCB" >/dev/null

# --- BOM ---------------------------------------------------------------------
echo "== BOM"
kicad-cli sch export bom \
    --fields 'Reference,Value,Footprint,${QUANTITY}' \
    --labels 'Reference,Value,Footprint,Qty' \
    --group-by 'Value,Footprint' --sort-field Reference \
    --exclude-dnp \
    -o "$FAB/$NAME-bom.csv" "$SCH" >/dev/null

# --- Schematic ---------------------------------------------------------------
echo "== Schematic"
kicad-cli sch export pdf -o "$DOCS/schematic.pdf" "$SCH" >/dev/null
kicad-cli sch export svg -o "$TMP/svg" "$SCH" >/dev/null
mv "$TMP/svg/$NAME.svg" "$DOCS/schematic.svg"

# --- 3D renders --------------------------------------------------------------
# Raytraced with the colour preset in scripts/render-3d_viewer.json (isolated
# config, so personal KiCad settings don't change the result).
# Top-down view; side lights raised to 75 degrees so shadows stay short and
# soft around each part instead of long streaks in four directions.
echo "== Renders"
RCFG="$TMP/render-config"
mkdir -p "$RCFG/10.0"
cp "$ROOT/scripts/render-3d_viewer.json" "$RCFG/10.0/3d_viewer.json"
for side in top bottom; do
    out="$DOCS/render.png"; [[ $side == bottom ]] && out="$DOCS/render-bottom.png"
    KICAD_CONFIG_HOME="$RCFG" kicad-cli pcb render --side "$side" \
        --quality user --preset readme --background opaque \
        --light-side-elevation 75 \
        -w 1800 -h 1400 --zoom 0.9 -o "$out" "$PCB" >/dev/null
done

echo "Done. Outputs in fabrication/ and docs/"
echo "Note: fabrication/$NAME-neoden-yy1.csv is maintained by hand (machine feeder setup)."
