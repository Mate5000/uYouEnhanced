#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.theos/audio-eq-tests"
mkdir -p "$BUILD"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    "$ROOT/Addons/AudioEQ/AudioDSP.cpp" "$ROOT/Addons/AudioEQ/tests/AudioDSPTests.cpp" \
    -o "$BUILD/dsp-tests"
"$BUILD/dsp-tests"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror -pthread \
    "$ROOT/Addons/AudioEQ/tests/AudioDiagnosticsTests.cpp" -o "$BUILD/diagnostic-tests"
"$BUILD/diagnostic-tests"
"${CXX:-c++}" -std=c++17 -O2 -Wall -Wextra -Werror \
    "$ROOT/Addons/AudioEQ/tests/DecoderPCMTests.cpp" -o "$BUILD/decoder-pcm-tests"
"$BUILD/decoder-pcm-tests"
python3 "$ROOT/Scripts/audio-eq/test_verify_ipa.py"
if [[ "$(uname -s)" == Darwin ]]; then
    bash "$ROOT/Tools/test-audio-decoder-apple.sh"
fi
