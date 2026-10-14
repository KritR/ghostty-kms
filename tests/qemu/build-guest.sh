#!/usr/bin/env bash
# Build the test guest (kernel, initrd, cmdline) and copy it to
# tests/qemu/out/<system>/, where run.sh picks it up.
#
# Defaults to this machine's architecture, which needs Linux (e.g. an
# OrbStack VM on macOS: the repo is shared, so the copied files are visible
# to the macOS host). `--system x86_64-linux` works from any host whose Nix
# has a builder for that system (e.g. a remote builder).
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
system="$(nix eval --impure --raw --expr builtins.currentSystem)"
if [ "${1:-}" = "--system" ]; then system="$2"; shift 2; fi
out="$root/tests/qemu/out/$system"
result="$(nix build "$root#packages.$system.test-vm" --no-link --print-out-paths "$@")"
mkdir -p "$out"
cp -fL "$result/kernel" "$result/initrd" "$result/cmdline" "$out/"
chmod u+w "$out"/*
echo "guest in $out"
