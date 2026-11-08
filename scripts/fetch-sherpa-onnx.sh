#!/bin/bash
# Fetches sherpa-onnx (Apache 2.0) and ONNX Runtime (MIT) for macOS into Vendor/sherpa-onnx: the libraries
# Cohere Transcribe runs on, the same ones as in Klavko for Windows. They come from the official k2-fsa
# NuGet packages, checked against fixed hashes, and are joined into universal (Apple Silicon + Intel) files.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=1.13.8
OUT=Vendor/sherpa-onnx
[ -f "$OUT/libsherpa-onnx-c-api.dylib" ] && [ -f "$OUT/libonnxruntime.dylib" ] && exit 0

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
for ARCH in arm64 x64; do
    case $ARCH in
        arm64) SHA512=PYR+g7XY9zfL7lu6A3O4guc2n5TW+7HGnWtwaYBkYJ7WHmW/E4zsadusbT0e20ojSOX1tXSzKFyIwvgi+sspZQ== ;;
        x64) SHA512=u2Wq715bN1CVV08YM8xXUgOU6K6IzhfXo1P8h1iqvwXKQtcEBYZEd5/tGEY5QKUQCk7EurpEvhbQUmHeFaT4tw== ;;
    esac
    NAME=org.k2fsa.sherpa.onnx.runtime.osx-$ARCH
    CACHED="$HOME/.nuget/packages/$NAME/$VERSION/$NAME.$VERSION.nupkg"
    if [ -f "$CACHED" ]; then
        cp "$CACHED" "$WORK/$ARCH.nupkg"
    else
        curl -fsSL "https://api.nuget.org/v3-flatcontainer/$NAME/$VERSION/$NAME.$VERSION.nupkg" -o "$WORK/$ARCH.nupkg"
    fi
    ACTUAL="$(openssl dgst -sha512 -binary "$WORK/$ARCH.nupkg" | base64)"
    [ "$ACTUAL" = "$SHA512" ] || { echo "Wrong hash of $NAME $VERSION" >&2; exit 1; }
    mkdir -p "$WORK/$ARCH"
    unzip -q -j "$WORK/$ARCH.nupkg" "runtimes/osx-$ARCH/native/*.dylib" -d "$WORK/$ARCH"
done
mkdir -p "$OUT"
for LIB in libsherpa-onnx-c-api.dylib libonnxruntime.dylib; do
    lipo -create "$WORK/arm64/$LIB" "$WORK/x64/$LIB" -output "$OUT/$LIB"
done
echo "sherpa-onnx $VERSION in $OUT"
