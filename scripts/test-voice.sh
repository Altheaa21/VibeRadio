#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
VR_TEST_DIR=$(mktemp -d)
trap 'rm -rf "$VR_TEST_DIR"' EXIT
swiftc -parse-as-library App/DJVoice.swift tests/VoiceTests.swift -o "$VR_TEST_DIR/voice-tests"
"$VR_TEST_DIR/voice-tests"
