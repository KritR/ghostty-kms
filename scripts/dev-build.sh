#!/usr/bin/env bash
# Incremental development build of the kms runtime, run on a Linux machine
# (or VM) with Nix. Builds inside upstream/ (a git checkout of the pinned
# Ghostty rev with our patches applied and src/apprt/kms symlinked to
# apprt-kms/, see scripts/setup-upstream.sh) using upstream's dev shell
# and its pre-fetched Zig dependency cache, so no network is needed.
#
# Usage: scripts/dev-build.sh [extra zig build args...]
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
deps="$(nix build "$root#packages.$system.ghostty-deps" --no-link --print-out-paths)"
cache="${ZIG_LOCAL_CACHE_DIR:-$HOME/.cache/ghostty-kms-zig}"
cd "$root/upstream"
exec nix develop "$root#devShells.$system.default" -c \
  zig build --system "$deps" --cache-dir "$cache" -Dapp-runtime=kms "$@"
