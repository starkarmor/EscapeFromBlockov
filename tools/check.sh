#!/bin/bash
# Syntax-check every Luau source (compile only; Roblox globals are not type-checked here).
cd "$(dirname "$0")/.." || exit 1
fail=0
while IFS= read -r f; do
  out=$(luau-compile --binary "$f" 2>&1 >/dev/null)
  if [ -n "$out" ]; then echo "$out"; fail=1; fi
done < <(find src -name '*.luau')
[ $fail -eq 0 ] && echo "luau: all sources compile"
exit $fail
