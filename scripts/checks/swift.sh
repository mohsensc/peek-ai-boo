#!/bin/sh
# Builds everything and runs the swift-testing suite.
# CLT ships Testing.framework but swiftpm won't find it on its own. Without
# these flags swift test either can't import Testing or runs zero tests and
# exits 0, so the count gets checked too.
set -u
D=/Library/Developer/CommandLineTools/Library/Developer
swift build || exit 1
log=$(mktemp)
swift test \
  -Xswiftc -F -Xswiftc "$D/Frameworks" \
  -Xlinker -rpath -Xlinker "$D/Frameworks" \
  -Xlinker -rpath -Xlinker "$D/usr/lib" >"$log" 2>&1
rc=$?
grep -E 'Test run with|✘|error:' "$log" | tail -20
if [ $rc -ne 0 ]; then rm -f "$log"; exit $rc; fi
if ! grep -Eq 'Test run with [1-9][0-9]* tests? .*passed' "$log"; then
  echo "swift test ran no tests"; rm -f "$log"; exit 1
fi
rm -f "$log"
