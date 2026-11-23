#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$PWD/.build/manifest-module-cache}"
toolchain="$(xcode-select -p)"
clt_macros="$toolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if [ -f "$clt_macros" ]; then
    # The standalone tools ship Testing separately from their native build defaults.
    frameworks="$toolchain/Library/Developer/Frameworks"
    set -- --build-system native --scratch-path .build/native-test --disable-xctest \
        -Xswiftc -F -Xswiftc "$frameworks" -Xlinker -F"$frameworks" -Xlinker -rpath -Xlinker "$frameworks" \
        -Xswiftc -load-plugin-library -Xswiftc "$clt_macros" "$@"
fi
swift test --manifest-cache local "$@"
