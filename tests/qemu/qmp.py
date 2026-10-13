# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Tiny QMP client for driving the test guest started by run.sh.

Commands:
  screenshot FILE.png        dump the virtio-gpu scanout
  type TEXT                  type text (Python escapes: \\n, \\t, \\x1b, \\\\)
  key COMBO [COMBO...]       press key combos, e.g. ctrl-alt-f2 ret
  mouse X Y                  move the pointer (absolute, in pixels)
  click [left|right|middle]  click a button at the current position
  scroll N                   wheel N notches (negative = up)
  quit                       stop QEMU
  wait-log PATTERN [SECS]    wait until serial.log contains PATTERN
  pixel FILE.png X Y         print the R G B of a pixel in a screenshot
  expect-color FILE.png X Y R G B [TOL]   exit 1 unless the pixel matches
"""

import json
import os
import struct
import zlib
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
SYSTEM = os.environ.get("GUEST_SYSTEM") or (
    "aarch64-linux" if os.uname().machine in ("arm64", "aarch64") else "x86_64-linux"
)
OUT = HERE / "out" / SYSTEM
SCREEN_W = int(os.environ.get("GUEST_WIDTH", "1280"))
SCREEN_H = int(os.environ.get("GUEST_HEIGHT", "800"))


class Qmp:
    def __init__(self, path: Path):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(str(path))
        self.f = self.sock.makefile("rw")
        json.loads(self.f.readline())  # greeting
        self.cmd("qmp_capabilities")

    def cmd(self, name: str, **args):
        msg = {"execute": name}
        if args:
            msg["arguments"] = args
        self.f.write(json.dumps(msg) + "\n")
        self.f.flush()
        while True:
            resp = json.loads(self.f.readline())
            if "event" in resp:
                continue
            if "error" in resp:
                raise RuntimeError(f"{name}: {resp['error']}")
            return resp.get("return")


# Characters to QEMU qcodes (US layout).
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal", "{": "bracket_left",
    "}": "bracket_right", "|": "backslash", ":": "semicolon", '"': "apostrophe",
    "~": "grave_accent", "<": "comma", ">": "dot", "?": "slash",
}
PLAIN = {
    " ": "spc", "\n": "ret", "\t": "tab", "\x1b": "esc", "-": "minus", "=": "equal",
    "[": "bracket_left", "]": "bracket_right", "\\": "backslash", ";": "semicolon",
    "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot", "/": "slash",
}


def char_keys(ch: str) -> list[str]:
    if ch.isascii() and ch.isalpha():
        return ["shift", ch.lower()] if ch.isupper() else [ch]
    if ch.isdigit():
        return [ch]
    if ch in PLAIN:
        return [PLAIN[ch]]
    if ch in SHIFTED:
        return ["shift", SHIFTED[ch]]
    raise ValueError(f"can't type {ch!r}")


def send_keys(q: Qmp, keys: list[str]):
    q.cmd("send-key", keys=[{"type": "qcode", "data": k} for k in keys], **{"hold-time": 40})
    time.sleep(0.06)


def unescape(s: str) -> str:
    # Python escapes: \n, \t, \x1b, and \\ for a literal backslash.
    return s.encode().decode("unicode_escape")


def abs_event(x: int, y: int) -> list[dict]:
    # virtio-tablet axes are 0..0x7fff.
    return [
        {"type": "abs", "data": {"axis": "x", "value": int(x * 0x7FFF / (SCREEN_W - 1))}},
        {"type": "abs", "data": {"axis": "y", "value": int(y * 0x7FFF / (SCREEN_H - 1))}},
    ]


def read_png(path: Path) -> tuple[int, int, int, list[bytes]]:
    """Minimal PNG decoder (8-bit RGB/RGBA, non-interlaced), enough for
    QEMU screendumps without third-party packages."""
    data = path.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, idat = 8, b""
    while pos < len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        kind = data[pos + 4 : pos + 8]
        chunk = data[pos + 8 : pos + 8 + length]
        if kind == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", chunk)
            assert depth == 8 and ctype in (2, 6) and interlace == 0, "unsupported PNG"
            bpp = 3 if ctype == 2 else 4
        elif kind == b"IDAT":
            idat += chunk
        pos += 12 + length
    raw = zlib.decompress(idat)
    stride = w * bpp
    rows: list[bytes] = []
    prev = bytearray(stride)
    for y in range(h):
        f = raw[y * (stride + 1)]
        line = bytearray(raw[y * (stride + 1) + 1 : (y + 1) * (stride + 1)])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if f == 1:
                line[i] = (line[i] + a) & 0xFF
            elif f == 2:
                line[i] = (line[i] + b) & 0xFF
            elif f == 3:
                line[i] = (line[i] + (a + b) // 2) & 0xFF
            elif f == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        rows.append(bytes(line))
        prev = line
    return w, h, bpp, rows


def pixel(path: Path, x: int, y: int) -> tuple[int, int, int]:
    w, h, bpp, rows = read_png(path)
    px = rows[y][x * bpp : x * bpp + 3]
    return px[0], px[1], px[2]


def main(argv: list[str]):
    if not argv:
        print(__doc__)
        return 1
    cmd, rest = argv[0], argv[1:]

    if cmd == "wait-log":
        pattern = rest[0]
        deadline = time.time() + (float(rest[1]) if len(rest) > 1 else 120)
        log = OUT / "serial.log"
        while time.time() < deadline:
            if log.exists() and pattern in log.read_text(errors="replace"):
                return 0
            time.sleep(0.5)
        print(f"timed out waiting for {pattern!r}", file=sys.stderr)
        return 1

    if cmd == "pixel":
        print(*pixel(Path(rest[0]), int(rest[1]), int(rest[2])))
        return 0

    if cmd == "expect-color":
        got = pixel(Path(rest[0]), int(rest[1]), int(rest[2]))
        want = tuple(int(v) for v in rest[3:6])
        tol = int(rest[6]) if len(rest) > 6 else 4
        ok = all(abs(g - w) <= tol for g, w in zip(got, want))
        print(f"pixel ({rest[1]},{rest[2]}) = {got}, want {want} +/-{tol}: {'ok' if ok else 'MISMATCH'}")
        return 0 if ok else 1

    q = Qmp(OUT / "qmp.sock")
    if cmd == "screenshot":
        path = Path(rest[0]).resolve()
        q.cmd("screendump", filename=str(path), format="png")
    elif cmd == "type":
        for ch in unescape(" ".join(rest)):
            send_keys(q, char_keys(ch))
    elif cmd == "key":
        for combo in rest:
            send_keys(q, combo.split("-"))
    elif cmd == "mouse":
        q.cmd("input-send-event", events=abs_event(int(rest[0]), int(rest[1])))
    elif cmd == "click":
        button = rest[0] if rest else "left"
        for down in (True, False):
            q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": button}}])
            time.sleep(0.05)
    elif cmd == "scroll":
        n = int(rest[0])
        button = "wheel-down" if n > 0 else "wheel-up"
        for _ in range(abs(n)):
            for down in (True, False):
                q.cmd("input-send-event", events=[{"type": "btn", "data": {"down": down, "button": button}}])
            time.sleep(0.03)
    elif cmd == "quit":
        q.cmd("quit")
    else:
        print(f"unknown command {cmd}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
