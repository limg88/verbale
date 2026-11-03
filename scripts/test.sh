#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export CLANG_MODULE_CACHE_PATH="$PWD/.build/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/clang"
swift run --disable-sandbox --cache-path .build/cache --scratch-path .build/swift verbale-checks "$@"
