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
# a Linux VM).
#
# Usage: tests/qemu/e2e.sh [--keep] [--system x86_64-linux]
#   --keep    leave QEMU running afterwards
#   --system  test a guest of another architecture (emulated, so slow;
#             timings are scaled by E2E_SLOWDOWN, default 10 when emulated)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
keep=0
system=""
while [ $# -gt 0 ]; do
  case "$1" in
    --keep) keep=1; shift ;;
    --system) system="$2"; shift 2 ;;
    *) echo "unknown arg $1" >&2; exit 1 ;;
  esac
done

q() { uv run -q "$here/qmp.py" "$@"; }
case "$(uname -m)" in
  arm64|aarch64) native=aarch64-linux ;;
  *) native=x86_64-linux ;;
esac
system="${system:-$native}"
export GUEST_SYSTEM="$system"
if [ "$system" = "$native" ]; then slow="${E2E_SLOWDOWN:-1}"; else slow="${E2E_SLOWDOWN:-10}"; fi
# Sleep / timeout scaled for slow (emulated) guests.
nap() { sleep "$(awk "BEGIN { print $1 * $slow }")"; }
secs() { awk "BEGIN { print int($1 * $slow) }"; }
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

"$here/run.sh" --system "$system"

# Geometry of the test config (font-size 14, padding 4, scale 1).
cell_h=25
cell_w=11
pad=4
row_y() { echo $((pad + cell_h * $1 + cell_h / 2)); }
col_x() { echo $((pad + cell_w * $1 + cell_w / 2)); }

check "ghostty starts and presents a frame" q wait-log "first frame presented" "$(secs 180)"
check "renderer initialized OpenGL >= 4.3" grep -q "loaded OpenGL 4\.[3-9]" "$out/serial.log"
nap 1

# Keyboard -> shell. Shifted symbols and arithmetic exercise the keymap.
q type "echo \"e2e-\$((6*7))\" > $serial\n"
check "typed command runs in the shell" q wait-log "e2e-42" "$(secs 20)"

# Rendering: fill the screen with an exact color and check the scanout.
q type 'clear; printf "\\e[48;2;200;30;40m\\e[2J"\n'
nap 1.5
q screenshot "$shots/color.png"
check "screen shows the exact background color" q expect-color "$shots/color.png" 640 600 200 30 40 2

# VT switching: away to tty2 (fbcon, black), then back; Ghostty repaints.
q key ctrl-alt-f2
nap 1.5
q screenshot "$shots/vt2.png"
check "Ctrl+Alt+F2 switches to another VT" q expect-color "$shots/vt2.png" 640 600 0 0 0 8
q key ctrl-alt-f1
nap 2
q screenshot "$shots/vt1.png"
check "Ghostty repaints after switching back" q expect-color "$shots/vt1.png" 640 600 200 30 40 2
q type "echo \"back-\$((2+3))\" > $serial\n"
check "input works after switching back" q wait-log "back-5" "$(secs 20)"

# Mouse selection -> copy -> paste through the in-process clipboard.
q type 'printf "\\e[0m"; clear; echo pastetoken\n'
nap 1
# `clear` runs before `echo`, so the token is on the first row.
q mouse "$(col_x 3)" "$(row_y 0)"
q click left
q click left
nap 0.3
q key ctrl-shift-c
q type 'echo got-'
q key ctrl-shift-v
q type " > $serial\n"
check "double-click selection, copy and paste" q wait-log "got-pastetoken" "$(secs 20)"
check "mouse shows the hardware cursor" grep -q "hardware cursor enabled" "$out/serial.log"

# Scrollback with the mouse wheel changes what's on screen.
q type 'clear; seq 1 300\n'
nap 1.5
q screenshot "$shots/before-scroll.png"
q scroll -20
nap 1
q screenshot "$shots/after-scroll.png"
check "mouse wheel scrolls the viewport" bash -c "! cmp -s '$shots/before-scroll.png' '$shots/after-scroll.png'"

# Ctrl+C reaches the foreground process.
q key ret
q type "bash -c 'trap \"echo interrupted-by-sigint > $serial; exit\" INT; sleep 1000 & wait'\n"
nap 1.5
q key ctrl-c
check "Ctrl+C interrupts the foreground job" q wait-log "interrupted-by-sigint" "$(secs 20)"

# Exiting the shell exits Ghostty cleanly.
q type 'exit\n'
check "Ghostty exits when the shell exits" q wait-log "ghostty exited: 0" "$(secs 20)"
nap 1

# Relaunch from the console shell with an explicit mode and scale.
q type "GHOSTTY_KMS_MODE=1024x768 GHOSTTY_KMS_SCALE=2 ghostty 2> $serial\n"
check "GHOSTTY_KMS_MODE selects the mode" q wait-log "mode=1024x768" "$(secs 60)"
check "GHOSTTY_KMS_SCALE sets the content scale" q wait-log "content scale=2" "$(secs 10)"
q wait-log "first frame presented" "$(secs 60)" >/dev/null || true
nap 3
q type 'printf "\\e[48;2;0;200;0m \\e[0m"\n'
nap 1.5
q screenshot "$shots/scaled.png"
check "screen is 1024x768" bash -c "[ \"\$(uv run -q '$here/qmp.py' size '$shots/scaled.png')\" = '1024 768' ]"
# Row 0 is the prompt + command; the green cell is at the start of row 1.
# At scale 2 a cell is ~22x50 px plus 8 px padding, so (12, 8+50+25) is
# inside it; at scale 1 that point would be on row 3.
check "text is drawn at 2x scale" q expect-color "$shots/scaled.png" 12 83 0 200 0 2
q type 'exit\n'

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
