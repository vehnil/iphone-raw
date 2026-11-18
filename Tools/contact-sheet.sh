#!/bin/sh
# Renders photos and test charts through film configurations into one image,
# with the app's own develop and film code. Usage:
#
#   Tools/contact-sheet.sh [-o sheet.jpg] [-c configs.json] [-s 600] [--stages colour,tone] [input ...]
#
# Inputs are DNG files, `chart:<name>` (grey-ramp, color-checker, highlights,
# gradients) or `charts` for all of them; with none, all charts are used.
# Configs default to Neutral plus the built-in looks; -c takes a JSON file
# exported from the app's Lab.
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP="$ROOT/iphone-raw"
BUILD="$ROOT/build/contact-sheet"
mkdir -p "$BUILD"

SOURCES="$ROOT/Tools/ContactSheet/main.swift $APP/Develop.swift $APP/FilmLook.swift $APP/FilmPresets.swift \
$APP/FilmPipeline.swift $APP/TestCharts.swift $APP/LabConfig.swift"

# Rebuild only when a source has changed.
if [ ! -x "$BUILD/contact-sheet" ] || [ -n "$(find $SOURCES "$APP/FilmKernels.metal" -newer "$BUILD/contact-sheet")" ]; then
    xcrun -sdk macosx metal -c -fcikernel "$APP/FilmKernels.metal" -o "$BUILD/kernels.air"
    xcrun -sdk macosx metallib -cikernel "$BUILD/kernels.air" -o "$BUILD/kernels.metallib"
    xcrun -sdk macosx swiftc -O -o "$BUILD/contact-sheet" $SOURCES
fi
exec "$BUILD/contact-sheet" --kernels "$BUILD/kernels.metallib" "$@"
