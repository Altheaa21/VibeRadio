#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
VR_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$VR_TEST_DIR"' EXIT
swiftc -parse-as-library App/MusicCatalog.swift App/AIClient.swift App/Companion.swift App/UPnP.swift tests/CompanionTests.swift -o "$VR_TEST_DIR/companion-tests"
"$VR_TEST_DIR/companion-tests"
