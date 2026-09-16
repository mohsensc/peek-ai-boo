#!/bin/sh
# Runs every scripts/checks/*.sh in name order, then prints a summary.
# PRs add a check file here instead of editing this one.
cd "$(dirname "$0")/.." || exit 1
fail=0
summary=""
for check in scripts/checks/*.sh; do
  [ -f "$check" ] || { echo "no checks found"; exit 1; }
  name=$(basename "$check" .sh)
  echo "== $name"
  if sh "$check"; then
    summary="${summary}ok   $name
"
  else
    summary="${summary}FAIL $name
"
    fail=1
  fi
done
echo "== summary"
printf '%s' "$summary"
exit $fail
