# ghostty-raw-term

Ghostty running directly on the Linux console (DRM/KMS): no compositor,
window manager or display server. It's a new Ghostty app runtime (`kms`)
carried as a small patch series on top of upstream Ghostty and built with
Nix. You get Ghostty's real renderer, fonts, Kitty graphics, themes and
config.

See [CLAUDE.md](CLAUDE.md) for the design and the reasoning behind it.

## Running

Build and run from a VT (Ctrl+Alt+F3 or similar, logged in on the text
console, not over SSH and not inside another graphical session):

```bash
nix build .#ghostty-kms
```

```bash
./result/bin/ghostty
```

Device access goes through libseat, so you need either a logind session
(the default when you log in on a VT) or seatd with your user in its
group. No root needed. Ctrl+Alt+F1..F12 switches VTs; Ghostty stops
drawing while you're away and repaints when you come back.

Your normal Ghostty config (`~/.config/ghostty/config`) applies. Things
that only make sense with a windowing system (tabs, splits, window
decorations, quick terminal, ...) are ignored. The terminal exits when its
shell does.

### kms settings

Console-specific settings are environment variables, so we don't have to
patch Ghostty's config parser:

| Variable | Meaning |
| --- | --- |
| `GHOSTTY_KMS_DEVICE` | DRM device to scan out on, e.g. `/dev/dri/card1`. Default: the first card with a connected display. |
| `GHOSTTY_KMS_CONNECTOR` | Output to use, e.g. `HDMI-A-1`, `DP-2`, `eDP-1`. Default: the first connected one. |
| `GHOSTTY_KMS_MODE` | `WIDTHxHEIGHT` or `WIDTHxHEIGHT@HZ`. Default: the display's preferred mode. |
| `GHOSTTY_KMS_SCALE` | Content scale (e.g. `2`). Default: from the display's physical size (DPI / 96, rounded to 0.25). |
| `GHOSTTY_KMS_RENDER_DEVICE` | Render on a different device than the one scanning out, e.g. `/dev/dri/renderD128` (Jetson, Raspberry Pi), or `software` for Mesa's llvmpipe (needs `GHOSTTY_KMS_ALLOW_SOFTWARE=1`). |
| `GHOSTTY_KMS_ALLOW_SOFTWARE=1` | Allow running on a software rasterizer. Off by default. |
| `GHOSTTY_KMS_PRESENT=cpu` | Skip DMABUF sharing and copy frames through the CPU. Automatic if the import fails. |
| `GHOSTTY_KMS_FLIP_Y=1` | Flip the image vertically, for a driver that gets orientation wrong. |
| `GHOSTTY_KMS_REPEAT_DELAY` / `GHOSTTY_KMS_REPEAT_RATE` | Key repeat delay (ms, default 400) and rate (Hz, default 25). |
| `GHOSTTY_KMS_SEAT_TIMEOUT` | How long to wait for the seat to become active (ms, default 10000). |
| `XKB_DEFAULT_LAYOUT`, `XKB_DEFAULT_VARIANT`, `XKB_DEFAULT_OPTIONS`, ... | Keyboard layout, read by xkbcommon. Default: `us`. |

Ghostty's log goes to stderr; redirect it to a file if you want to read it
after exiting (`./result/bin/ghostty 2>/tmp/ghostty.log`).

### Clipboard

There's no system clipboard on the console, so the clipboard is
in-process: copy and paste work within the terminal (including OSC 52
from programs). There's no UI to confirm a paste, so multi-line pastes
from the in-process clipboard go through without the usual prompt, and
program clipboard access that the config says to "ask" about is denied.

## How it works

- **Seat** (`apprt-kms/Seat.zig`): libseat opens the DRM and input devices
  and tells us when our VT is switched away and back.
- **Display** (`Drm.zig`): picks the device, connector, CRTC and mode,
  creates a GBM device and an EGL display on `EGL_PLATFORM_GBM_KHR`. That
  display is passed to Ghostty's renderer through `renderDeviceOptions`, so
  rendering happens on the same GPU.
- **Presenter** (`Presenter.zig`): Ghostty's OpenGL renderer draws offscreen
  and exports each frame as a DMABUF (or CPU pixels if that fails). We
  import it as an EGLImage texture in a small GLES 2 context on a GBM
  surface, draw a fullscreen quad, swap, wrap the GBM buffer in a DRM
  framebuffer and page-flip. If the import fails we ask the renderer for
  CPU frames instead.
- **Input** (`Input.zig`, `Keyboard.zig`): libinput for devices, xkbcommon
  for keymaps, modifiers and dead keys; key repeat with a timerfd. Key
  events are built the same way the GTK runtime builds them.
- **Cursor** (`Cursor.zig`): the DRM cursor plane, an arrow or an I-beam,
  shown once the mouse moves.
- **Main loop** (`App.zig`): poll(2) over the seat, DRM, libinput, repeat
  timer and an eventfd for the core's `wakeup`, then a core tick.

## Repository layout

```
flake.nix          pins upstream Ghostty and overrides its package
patches/           the patch series against upstream (build wiring only)
apprt-kms/         the kms runtime, copied to src/apprt/kms at build time
nix/test-vm.nix    NixOS guest for end-to-end tests
tests/qemu/        QEMU runner and QMP driver for the test guest
scripts/           development helpers
```

## Development

The fast loop is an incremental `zig build` in a checkout of upstream with
the patches applied and `src/apprt/kms` symlinked to `apprt-kms/`:

```bash
scripts/setup-upstream.sh
```

```bash
scripts/dev-build.sh
```

`dev-build.sh` runs on Linux (on macOS, inside a Linux VM such as OrbStack
with the repo shared: `scripts/vm-build.sh` wraps that). It uses
upstream's dev shell and its pre-fetched Zig dependency cache, so it needs
no network. The binary lands in `upstream/zig-out/bin/ghostty`.

### Raspberry Pi

`ghostty-kms-rpi` (aarch64) is for Pis without GPU drivers installed
(`hardware.graphics` off). It bundles a Mesa with only the Pi's drivers
and no software rasterizer:

- presenter (blit + scanout): the native vc4/V3D driver, OpenGL ES 3.1
- renderer: zink, i.e. desktop OpenGL on the V3DV Vulkan driver, on
  `/dev/dri/renderD128`. V3D's own GL driver can't run Ghostty: it lacks
  desktop GL 4.3 and allows no storage buffers in vertex shaders. Zink is
  selected for the v3d device only, via a driconf file, and GL 4.3 is
  enabled with `MESA_GL_VERSION_OVERRIDE` (Ghostty doesn't use the
  tessellation shaders V3D lacks).

Run it from a VT login. Use a solid supply (the official 27 W one); the Pi 5
logs undervoltage under load on weaker ones.

### Software rendering

ghostty-kms refuses to run on a software rasterizer (llvmpipe and friends)
unless `GHOSTTY_KMS_ALLOW_SOFTWARE=1` is set, since that keeps every core
busy. The NixOS module's `softwareRendering` option sets it, as does the
QEMU test guest.

### No GTK

The package is built without GTK and its neighbours (glib/GObject,
GStreamer, X11, Wayland, ...): the runtime closure is about 106 MiB on x86_64 (mostly glibc, libstdc++ and Ghostty itself), and
the build fails if any of them sneak back in. To check what a build
fetches and builds as well:

```bash
scripts/check-no-gtk.sh
```

### End-to-end test in QEMU

`tests/qemu/` boots a NixOS guest with a virtio-gpu display (a real
DRM/KMS device), seatd, and an autologin on tty1 that starts Ghostty. It
renders with llvmpipe, i.e. the CPU frame path.

```bash
tests/qemu/build-guest.sh
```

```bash
tests/qemu/run.sh
```

```bash
uv run tests/qemu/qmp.py screenshot shot.png
```

`build-guest.sh` needs Linux (on macOS, run it in the Linux VM; the result
is copied into the shared repo). `run.sh` works on macOS (HVF) and Linux
(KVM). `qmp.py` can also type text, press key combos, move and click the
mouse, and scroll; `tests/qemu/e2e.sh` runs a scripted check.

### Updating upstream

1. Bump the rev in `flake.nix` (`inputs.ghostty.url`) and run
   `nix flake update ghostty`.
2. In `upstream/`, rebase the `kms` branch onto the new rev and fix any
   conflicts (the patch only touches a handful of lines).
3. Regenerate the patch: `scripts/export-patches.sh`.
4. Rebuild: `nix build .#ghostty-kms`. Fix anything in `apprt-kms/` the
   new upstream broke (internal APIs move fast).

## Hardware status

| Target | Status |
| --- | --- |
| Intel/AMD + Mesa | Primary target. Builds; not yet run on real hardware (the DMABUF zero-copy path needs a real GPU to exercise). |
| QEMU virtio-gpu + llvmpipe | `tests/qemu/e2e.sh` passes on aarch64 (HVF) and x86_64 (emulated). |
| NVIDIA Jetson (JetPack 6) | Not yet tried. See CLAUDE.md "Hardware notes"; `GHOSTTY_KMS_RENDER_DEVICE` exists for the split render/display devices. |
| Raspberry Pi 4/5 | Pi 5: `ghostty-kms-rpi` runs at 2560x1440@144 with the renderer on zink (V3DV) and the presenter on V3D, ~1% CPU idle. Input and VT switching not yet checked on the Pi. Pi 4 untried. |
