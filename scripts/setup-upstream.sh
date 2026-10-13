#!/usr/bin/env bash
# Create upstream/: a git checkout of the Ghostty revision pinned in
# flake.lock, with the patches in patches/ applied as commits on a `kms`
# branch and src/apprt/kms symlinked to apprt-kms/. Used by dev-build.sh
# and for rebasing the patch series (see README.md "Updating upstream").
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rev="$(nix eval --raw --impure --expr "(builtins.fromJSON (builtins.readFile $root/flake.lock)).nodes.ghostty.locked.rev")"
cd "$root"
if [ ! -d upstream/.git ]; then
  git clone https://github.com/ghostty-org/ghostty upstream
fi
cd upstream
git fetch -q origin "$rev" 2>/dev/null || git fetch -q origin
if git rev-parse -q --verify kms >/dev/null; then
  echo "upstream/ already has a kms branch; leaving it alone"
else
  git checkout -q -b kms "$rev"
  git am -q "$root"/patches/*.patch
fi
ln -sfn ../../../apprt-kms src/apprt/kms
grep -qx 'src/apprt/kms' .git/info/exclude || echo 'src/apprt/kms' >> .git/info/exclude
git log --oneline -n 3
