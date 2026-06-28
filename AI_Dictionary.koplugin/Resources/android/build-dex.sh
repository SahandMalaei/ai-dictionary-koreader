#!/usr/bin/env bash
#
# Build tts_helper.dex from TtsHelper.java using the Android SDK.
#
# Prerequisites:
#   - ANDROID_HOME (or ANDROID_SDK_ROOT) set to the Android SDK path
#   - Build tools installed (sdkmanager "build-tools;34.0.0")
#   - Platform API 21+ installed (sdkmanager "platforms;android-34")
#
# Usage:
#   ./build-dex.sh
#
# Output:
#   Resources/android/tts_helper.dex
#
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" ]]; then
    echo "Error: ANDROID_HOME or ANDROID_SDK_ROOT not set" >&2
    exit 1
fi

# Find build-tools (newest available)
BT_DIR=$(ls -d "$SDK/build-tools"/*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$BT_DIR" ]]; then
    echo "Error: No build-tools found in $SDK/build-tools/" >&2
    exit 1
fi
D8="$BT_DIR/d8"

# Find android.jar (newest platform)
PLATFORM=$(ls -d "$SDK/platforms"/android-*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$PLATFORM" ]]; then
    echo "Error: No platform found in $SDK/platforms/" >&2
    exit 1
fi
ANDROID_JAR="$PLATFORM/android.jar"

echo "SDK:         $SDK"
echo "Build tools: $BT_DIR"
echo "Platform:    $PLATFORM"
echo "d8:          $D8"

# Compile .java -> .class
echo "Compiling TtsHelper.java..."
mkdir -p build
javac -source 8 -target 8 \
    -classpath "$ANDROID_JAR" \
    -d build \
    TtsHelper.java

# Convert .class -> .dex (include inner/anonymous classes like TtsHelper$1)
echo "Dexing..."
"$D8" --min-api 21 --output . build/org/koreader/plugin/audiobook/TtsHelper*.class

# d8 outputs classes.dex; rename to our expected name
mv classes.dex tts_helper.dex
rm -rf build

echo "Created tts_helper.dex ($(wc -c < tts_helper.dex) bytes)"
