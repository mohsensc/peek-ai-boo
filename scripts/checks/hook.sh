#!/bin/sh
# Builds the hook and runs its unit and integration tests.
set -u
out=$(make -C hook test 2>&1); rc=$?
printf '%s\n' "$out" | tail -15
[ $rc -eq 0 ] || exit $rc
printf '%s\n' "$out" | grep -Eq 'hook unit: [1-9][0-9]* passed' || { echo "no unit tests ran"; exit 1; }
printf '%s\n' "$out" | grep -Eq 'hook integration: [1-9][0-9]* passed' || { echo "no integration tests ran"; exit 1; }
