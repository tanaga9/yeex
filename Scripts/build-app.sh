#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
test "$(uname -m)" = arm64 || { echo "YeeX requires Apple Silicon." >&2; exit 1; }
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/manifest-module-cache}"
set -- --scratch-path .build/distribution --manifest-cache local --arch arm64 --configuration release \
    --sdk "$(xcrun --sdk macosx --show-sdk-path)" "$@"
case "$(xcode-select -p)" in
    */CommandLineTools)
        # Swift Build can record the deployment target as the SDK version with standalone tools.
        set -- --build-system native "$@"
        ;;
esac
swift build "$@"
binary="$(swift build "$@" --show-bin-path)/YeeX"
app="$PWD/dist/YeeX.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
staged="$(mktemp "$app/Contents/MacOS/.YeeX.XXXXXX")"
trap 'rm -f "$staged"' EXIT
cp "$binary" "$staged"
chmod 755 "$staged"
mv -f "$staged" "$app/Contents/MacOS/YeeX"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp LICENSE Resources/X11-rgb-LICENSE.txt Resources/YeeX.icns "$app/Contents/Resources/"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "$app"
