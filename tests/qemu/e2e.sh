#!/usr/bin/env bash
# End-to-end test of the kms runtime in the QEMU test guest.
#
# Boots the guest (run.sh), then drives Ghostty with real input events
# through QEMU and checks the results two ways: commands typed into the
# terminal write markers to the serial console (proves keyboard -> Ghostty
# -> pty -> shell), and screenshots of the virtio-gpu scanout are checked
# for exact colors (proves renderer -> presenter -> KMS page flips).
#
# Prerequisite: tests/qemu/build-guest.sh (needs Linux; on macOS run it in
# a Linux VM). Usage: tests/qemu/e2e.sh [--keep]   (--keep leaves QEMU up)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
keep=0
[ "${1:-}" = "--keep" ] && keep=1

q() { uv run -q "$here/qmp.py" "$@"; }
case "$(uname -m)" in
  arm64|aarch64) system=aarch64-linux ;;
  *) system=x86_64-linux ;;
esac
out="$here/out/$system"
shots="$out/shots"
mkdir -p "$shots"
serial=/dev/ttyAMA0
[ "$system" = x86_64-linux ] && serial=/dev/ttyS0

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }

cleanup() {
  if [ "$keep" = 0 ] && [ -f "$out/qemu.pid" ]; then
    kill "$(cat "$out/qemu.pid")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$here/run.sh"

# Geometry of the test config (font-size 14, padding 4, scale 1).
cell_h=25
cell_w=11
pad=4
row_y() { echo $((pad + cell_h * $1 + cell_h / 2)); }
col_x() { echo $((pad + cell_w * $1 + cell_w / 2)); }

check "ghostty starts and presents a frame" q wait-log "first frame presented" 180
check "renderer initialized OpenGL >= 4.3" grep -q "loaded OpenGL 4\.[3-9]" "$out/serial.log"
sleep 1

# Keyboard -> shell. Shifted symbols and arithmetic exercise the keymap.
q type "echo \"e2e-\$((6*7))\" > $serial\n"
check "typed command runs in the shell" q wait-log "e2e-42" 20

# Rendering: fill the screen with an exact color and check the scanout.
q type 'clear; printf "\\e[48;2;200;30;40m\\e[2J"\n'
sleep 1.5
q screenshot "$shots/color.png"
check "screen shows the exact background color" q expect-color "$shots/color.png" 640 600 200 30 40 2

# VT switching: away to tty2 (fbcon, black), then back; Ghostty repaints.
q key ctrl-alt-f2
sleep 1.5
q screenshot "$shots/vt2.png"
check "Ctrl+Alt+F2 switches to another VT" q expect-color "$shots/vt2.png" 640 600 0 0 0 8
q key ctrl-alt-f1
sleep 2
q screenshot "$shots/vt1.png"
check "Ghostty repaints after switching back" q expect-color "$shots/vt1.png" 640 600 200 30 40 2
q type "echo \"back-\$((2+3))\" > $serial\n"
check "input works after switching back" q wait-log "back-5" 20

# Mouse selection -> copy -> paste through the in-process clipboard.
q type 'printf "\\e[0m"; clear; echo pastetoken\n'
sleep 1
# `clear` runs before `echo`, so the token is on the first row.
q mouse "$(col_x 3)" "$(row_y 0)"
q click left
q click left
sleep 0.3
q key ctrl-shift-c
q type 'echo got-'
q key ctrl-shift-v
q type " > $serial\n"
check "double-click selection, copy and paste" q wait-log "got-pastetoken" 20

# Scrollback with the mouse wheel changes what's on screen.
q type 'clear; seq 1 300\n'
sleep 1.5
q screenshot "$shots/before-scroll.png"
q scroll -20
sleep 1
q screenshot "$shots/after-scroll.png"
check "mouse wheel scrolls the viewport" bash -c "! cmp -s '$shots/before-scroll.png' '$shots/after-scroll.png'"

# Ctrl+C reaches the foreground process.
q key ret
q type "bash -c 'trap \"echo interrupted-by-sigint > $serial; exit\" INT; sleep 1000 & wait'\n"
sleep 1.5
q key ctrl-c
check "Ctrl+C interrupts the foreground job" q wait-log "interrupted-by-sigint" 20

# Exiting the shell exits Ghostty cleanly.
q type 'exit\n'
check "Ghostty exits when the shell exits" q wait-log "ghostty exited: 0" 20

if grep -q "panic\|segmentation fault\|error(kms" "$out/serial.log"; then
  fail "no panics or kms errors in the log"
  grep -n "panic\|segmentation fault\|error(kms" "$out/serial.log" | head -20
else
  pass "no panics or kms errors in the log"
fi

echo
if [ "$failures" = 0 ]; then
  echo "all e2e checks passed (screenshots in $shots)"
else
  echo "$failures e2e check(s) failed; serial log: $out/serial.log"
  exit 1
fi
