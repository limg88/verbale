#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
# Sources/CParakeet includes a header from this submodule; a fresh clone has it empty.
[ -f native/parakeet.cpp/include/parakeet_capi.h ] || git submodule update --init native/parakeet.cpp
python3 scripts/build_echo.py
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang"
swift run --disable-sandbox --cache-path .build/cache --scratch-path .build/swift verbale-checks "$@"
