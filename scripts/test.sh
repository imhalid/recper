#!/bin/zsh
# Usage: scripts/test.sh [--filter RecperCoreTests]
# Builds in release so performance measurements are meaningful.
# Only when Command Line Tools is active: Swift Testing ships with CLT but is not on the search path, so paths
# are passed here (when set in Package.swift, SwiftPM can't find the tests). Not passed when Xcode is active:
# Xcode's test macros don't match CLT's older Testing.framework.
set -euo pipefail
cd "${0:A:h}/.."
flags=(-c release -Xswiftc -enable-testing)
if [[ "${DEVELOPER_DIR:-$(xcode-select -p)}" == /Library/Developer/CommandLineTools* ]]; then
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  flags+=(-Xswiftc -F$FW -Xlinker -F$FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB)
fi
exec swift test $flags "$@"
