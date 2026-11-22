#!/bin/sh
# Build the Swift pipeline core with a Mac harness and compare to the Python golden data (local only).
set -e
cd "$(dirname "$0")/../.."
mkdir -p build
swiftc -O app/Core/*.swift tools/swiftcheck/main.swift -o build/swiftcheck
build/swiftcheck "$PWD/tools/models"
