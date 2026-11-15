#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.theos/audio-eq-tests"
mkdir -p "$BUILD"
clang++ -std=c++17 -O2 -fobjc-arc -fblocks -Wall -Wextra -Werror -Wno-unused-function \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreMedia \
    "$ROOT/Addons/AudioEQ/AudioDSP.cpp" "$ROOT/Addons/AudioEQ/tests/AudioDecoderAppleTests.mm" \
    -o "$BUILD/apple-decoder-tests"
"$BUILD/apple-decoder-tests" "$ROOT/Addons/AudioEQ/tests/fixtures"
