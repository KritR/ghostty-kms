#!/usr/bin/env bash
# Regenerate patches/ from the commits on upstream/'s kms branch on top of
# the rev pinned in flake.lock.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rev="$(nix eval --raw --impure --expr "(builtins.fromJSON (builtins.readFile $root/flake.lock)).nodes.ghostty.locked.rev")"
rm -f "$root"/patches/*.patch
git -C "$root/upstream" format-patch -q --zero-commit --no-signature -o "$root/patches" "$rev..kms"
ls "$root/patches"
