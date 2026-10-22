#!/usr/bin/env bash
# Boot the test guest (built by build-guest.sh) in QEMU with a virtio-gpu
# display, virtio keyboard and tablet. Works on macOS (HVF) and Linux
# (KVM) hosts; QEMU comes from nixpkgs.
#
# The guest's serial console (ghostty's log) goes to out/<system>/serial.log
# and a QMP socket is at out/<system>/qmp.sock; drive it with qmp.py:
#
#   uv run tests/qemu/qmp.py screenshot shot.png
#   uv run tests/qemu/qmp.py type 'echo hello\n'
#
# Usage: run.sh [--system aarch64-linux|x86_64-linux] [--guest test-vm-console]
#               [--width W --height H] [--foreground]
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

host_arch="$(uname -m)"
case "$host_arch" in
  arm64|aarch64) system=aarch64-linux ;;
  x86_64) system=x86_64-linux ;;
  *) echo "unsupported host $host_arch" >&2; exit 1 ;;
esac
width=1280
height=800
foreground=0
guest=test-vm
while [ $# -gt 0 ]; do
  case "$1" in
    --system) system="$2"; shift 2 ;;
    --guest) guest="$2"; shift 2 ;;
    --width) width="$2"; shift 2 ;;
    --height) height="$2"; shift 2 ;;
    --foreground) foreground=1; shift ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

out="$here/out/$system${guest#test-vm}"
for f in kernel initrd cmdline; do
  [ -f "$out/$f" ] || { echo "missing $out/$f; run build-guest.sh first" >&2; exit 1; }
done

qemu_pkg="$(nix build --inputs-from "$root" nixpkgs#qemu --no-link --print-out-paths)"

accel=tcg
cpu=max
case "$(uname -s)-$system-$host_arch" in
  Darwin-aarch64-linux-arm64) accel=hvf; cpu=host ;;
  Linux-aarch64-linux-aarch64|Linux-x86_64-linux-x86_64)
    [ -w /dev/kvm ] && { accel=kvm; cpu=host; } ;;
esac

extra=()
case "$system" in
  aarch64-linux) qemu="$qemu_pkg/bin/qemu-system-aarch64"; machine="virt" ;;
  # No legacy VGA: virtio-gpu must be the only display, or screendumps
  # capture the VGA text console instead.
  x86_64-linux) qemu="$qemu_pkg/bin/qemu-system-x86_64"; machine="q35"; extra=(-vga none) ;;
esac

rm -f "$out/qmp.sock" "$out/serial.log"
args=(
  -machine "$machine" -accel "$accel" -cpu "$cpu" -smp 4 -m 6144
  -kernel "$out/kernel" -initrd "$out/initrd" -append "$(cat "$out/cmdline")"
  -device "virtio-gpu-pci,xres=$width,yres=$height"
  -device virtio-keyboard-pci
  -device virtio-tablet-pci
  -display none
  -serial "file:$out/serial.log"
  -qmp "unix:$out/qmp.sock,server,nowait"
  -nic none
  ${extra[@]+"${extra[@]}"}
)

if [ "$foreground" = 1 ]; then
  exec "$qemu" "${args[@]}"
fi
"$qemu" "${args[@]}" -daemonize -pidfile "$out/qemu.pid"
echo "QEMU running (pid $(cat "$out/qemu.pid")); serial log: $out/serial.log"
