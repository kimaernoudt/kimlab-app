#!/bin/bash
# type-check only (fast feedback)
cd "$(dirname "$0")/Sources/KIMLAB"
swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 *.swift > ../../check.log 2>&1
echo "exit $?" >> ../../check.log
