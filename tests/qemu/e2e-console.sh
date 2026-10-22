#!/usr/bin/env bash
# End-to-end test of `programs.ghostty-kms.console` (nix/test-vm-console.nix):
# Ghostty as the login console, like getty.
#
#   tty1, tty2: Ghostty with a login prompt (tty2 started on demand)
#   tty3:       plain getty
#   tty4:       Ghostty that always fails -> falls back to getty
#
# Checks go through the serial console (journald forwards everything there,
# and commands typed into the console write markers to it) and screenshot
# colors (Ghostty's background vs. the black text console).
#
# Prerequisite: tests/qemu/build-guest.sh --guest test-vm-console
# Usage: tests/qemu/e2e-console.sh [--keep] [--system x86_64-linux]
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
case "$(uname -m)" in
  arm64|aarch64) native=aarch64-linux ;;
  *) native=x86_64-linux ;;
esac
system="${system:-$native}"
if [ "$system" = "$native" ]; then slow="${E2E_SLOWDOWN:-1}"; else slow="${E2E_SLOWDOWN:-10}"; fi
nap() { sleep "$(awk "BEGIN { print $1 * $slow }")"; }
secs() { awk "BEGIN { print int($1 * $slow) }"; }

export GUEST_SYSTEM="$system"
export GUEST_DIR="$here/out/$system-console"
q() { uv run -q "$here/qmp.py" "$@"; }
out="$GUEST_DIR"
log="$out/serial.log"
shots="$out/shots"
mkdir -p "$shots"
serial=/dev/ttyAMA0
[ "$system" = x86_64-linux ] && serial=/dev/ttyS0

failures=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; failures=$((failures + 1)); }
check() { local name="$1"; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
count() { grep -ac -- "$1" "$log" || true; }

cleanup() {
  if [ "$keep" = 0 ] && [ -f "$out/qemu.pid" ]; then
    kill "$(cat "$out/qemu.pid")" 2>/dev/null || true
  fi
}
trap cleanup EXIT

"$here/run.sh" --system "$system" --guest test-vm-console

# Ghostty's background at the screen center vs. the text console's black.
ghostty_bg() { q expect-color "$1" 640 600 40 44 52 2; }
text_console() { q expect-color "$1" 640 600 0 0 0 8; }

check "boots into Ghostty on tty1" q wait-log "Started Ghostty console on tty1" "$(secs 180)"
check "Ghostty presents a frame" q wait-log "first frame presented" "$(secs 60)"
nap 2
q screenshot "$shots/tty1.png"
check "tty1 shows Ghostty" ghostty_bg "$shots/tty1.png"

# Log in at Ghostty's prompt.
q type 'test\n'
nap 1
q type 'test\n'
nap 3
q type "loginctl show-session \$XDG_SESSION_ID -p Seat -p VTNr -p Class -p Active | tr '\\\\n' ' ' | sed 's/^/session: /' > $serial; echo \" rt=\$XDG_RUNTIME_DIR\" > $serial\n"
check "login gives the user a session" q wait-log "session: " "$(secs 30)"
s="$(grep -a "session: " "$log" | tail -1)"
check "session is on seat0" grep -q "Seat=seat0" <<<"$s"
check "session is on VT 1" grep -q "VTNr=1" <<<"$s"
check "session is an active user session" bash -c "grep -q 'Class=user' <<<'$s' && grep -q 'Active=yes' <<<'$s'"
check "user has a runtime dir" grep -aq "rt=/run/user/1000" "$log"

# xterm-ghostty must resolve system-wide, not only through TERMINFO.
q type "env -u TERMINFO infocmp xterm-ghostty >/dev/null 2>&1 && echo terminfo-ok > $serial\n"
check "xterm-ghostty terminfo is installed system-wide" q wait-log "terminfo-ok" "$(secs 20)"

# tty2: a second Ghostty, started on demand.
q key ctrl-alt-f2
check "switching to tty2 starts Ghostty there" q wait-log "Started Ghostty console on tty2" "$(secs 30)"
nap 2
q screenshot "$shots/tty2.png"
check "tty2 shows Ghostty" ghostty_bg "$shots/tty2.png"

# tty3: untouched, plain getty.
q key ctrl-alt-f3
nap 3
q screenshot "$shots/tty3.png"
check "tty3 is a plain getty" text_console "$shots/tty3.png"

# tty4: Ghostty keeps failing, so systemd falls back to getty.
q key ctrl-alt-f4
check "a failing console falls back to getty" q wait-log "Started Getty on tty4" "$(secs 60)"
nap 2
q screenshot "$shots/tty4.png"
check "tty4 shows the fallback getty" text_console "$shots/tty4.png"

# Back to tty1: still logged in.
q key ctrl-alt-f1
nap 3
q screenshot "$shots/tty1-back.png"
check "tty1 shows Ghostty again" ghostty_bg "$shots/tty1-back.png"
q type "echo \"back-\$((1+1))\" > $serial\n"
check "the tty1 session survived the VT switches" q wait-log "back-2" "$(secs 20)"

# Logging out gives a fresh console, like getty.
frames="$(count "first frame presented")"
q type 'exit\n'
check "logging out restarts the console" q wait-log "autovt@tty1.service: Scheduled restart job" "$(secs 30)"
for _ in $(seq 1 "$(secs 30)"); do
  [ "$(count "first frame presented")" -gt "$frames" ] && break
  sleep 1
done
check "a new Ghostty comes up after logout" test "$(count "first frame presented")" -gt "$frames"

if grep -aq "panic\|segmentation fault\|error(kms" "$log"; then
  fail "no panics or kms errors in the log"
  grep -an "panic\|segmentation fault\|error(kms" "$log" | head -20
else
  pass "no panics or kms errors in the log"
fi

echo
if [ "$failures" = 0 ]; then
  echo "all console e2e checks passed (screenshots in $shots)"
else
  echo "$failures console e2e check(s) failed; serial log: $log"
  exit 1
fi
