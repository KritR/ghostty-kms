#!/usr/bin/env bash
# Build a test guest (kernel, initrd, cmdline) and copy it to
# tests/qemu/out/<system>[-console]/, where run.sh picks it up.
#
# Defaults to this machine's architecture, which needs Linux (e.g. an
# OrbStack VM on macOS: the repo is shared, so the copied files are visible
# to the macOS host). `--system x86_64-linux` works from any host whose Nix
# has a builder for that system (e.g. a remote builder).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
guest=test-vm
while [ $# -gt 0 ]; do
  case "$1" in
    --system) system="$2"; shift 2 ;;
    --guest) guest="$2"; shift 2 ;;  # test-vm (default) or test-vm-console
    *) break ;;
  esac
done
out="$root/tests/qemu/out/$system${guest#test-vm}"
result="$(nix build "$root#packages.$system.$guest" --no-link --print-out-paths "$@")"
mkdir -p "$out"
cp -fL "$result/kernel" "$result/initrd" "$result/cmdline" "$out/"
chmod u+w "$out"/*
echo "guest in $out"
