#!/bin/bash
# Rebuild and restart cmux app

set -e

cd "$(dirname "$0")/.."

# Kill existing app if running
pkill -9 -f "cmux" 2>/dev/null || true

# Build
swift build

# Copy to app bundle
cp .build/debug/programa .build/debug/Programa.app/Contents/MacOS/

# Open the app
open .build/debug/Programa.app
