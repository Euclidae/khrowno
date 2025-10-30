#!/bin/bash
# Simple build script for Khrowno
# Usage: ./build.sh [release|debug]

set -e

BUILD_MODE=${1:-debug}

echo "Building Khrowno in $BUILD_MODE mode..."

if [ "$BUILD_MODE" = "release" ]; then
    zig build -Doptimize=ReleaseFast
else
    zig build
fi

echo "Build complete!"
echo "Binary location: zig-out/bin/krowno"

# Check if we have the required libraries
echo ""
echo "Checking dependencies..."

if ! command -v curl &> /dev/null; then
    echo "WARNING: curl not found. Network features may not work."
fi

if ! pkg-config --exists gtk+-3.0 2>/dev/null; then
    echo "WARNING: GTK3 not found. GUI will not work (CLI still works)."
fi

echo ""
echo "To install: sudo cp zig-out/bin/krowno /usr/local/bin/"
