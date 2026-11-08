#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
VR_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$VR_TEST_DIR"' EXIT
swiftc -parse-as-library App/MusicCatalog.swift App/AIClient.swift App/MusicLibraryModel.swift tests/MusicLibraryTests.swift -o "$VR_TEST_DIR/library-tests"
"$VR_TEST_DIR/library-tests"
