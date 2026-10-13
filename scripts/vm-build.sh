#!/usr/bin/env bash
# Run dev-build.sh inside the OrbStack VM named by $VM (default
# ghostty-kms) and show only the useful part of the output.
vm="${VM:-ghostty-kms}"
root="$(cd "$(dirname "$0")/.." && pwd)"
orb -m "$vm" bash -lc "'$root/scripts/dev-build.sh' $* 2>&1" |
  grep -v '^failed command\|^warning: Git tree' |
  awk '/error:/{p=1} p' | head -${LINES_MAX:-120}
