#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" ]]; then
    echo "Error: ANDROID_HOME or ANDROID_SDK_ROOT is not set" >&2
    exit 1
fi

BT_DIR=$(find "$SDK/build-tools" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
PLATFORM=$(find "$SDK/platforms" -mindepth 1 -maxdepth 1 -type d | sort -V | tail -1)
if [[ -z "$BT_DIR" || -z "$PLATFORM" ]]; then
    echo "Error: Android build-tools and a platform SDK are required" >&2
    exit 1
fi

rm -rf build-http
mkdir -p build-http/classes build-http/dex
javac -source 8 -target 8 \
    -classpath "$PLATFORM/android.jar" \
    -d build-http/classes \
    AndroidHttpWorker.java

"$BT_DIR/d8" --min-api 21 \
    --output build-http/dex \
    build-http/classes/org/koreader/plugin/aidictionary/AndroidHttpWorker*.class

mv build-http/dex/classes.dex http_worker.dex
rm -rf build-http
echo "Created http_worker.dex ($(wc -c < http_worker.dex) bytes)"
