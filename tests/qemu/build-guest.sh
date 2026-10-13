#!/usr/bin/env bash
# Build the test guest (kernel, initrd, cmdline) for this machine's Linux
# architecture and copy it to tests/qemu/out/, where run.sh picks it up.
# Must run on Linux with Nix (e.g. an OrbStack VM on macOS: the repo is
# shared, so the copied files are visible to the macOS host).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
out="$root/tests/qemu/out/$system"
result="$(nix build "$root#packages.$system.test-vm" --no-link --print-out-paths "$@")"
mkdir -p "$out"
cp -fL "$result/kernel" "$result/initrd" "$result/cmdline" "$out/"
chmod u+w "$out"/*
echo "guest in $out"
