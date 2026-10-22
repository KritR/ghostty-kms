# ghostty-raw-term

Run Ghostty directly on the Linux console (DRM/KMS), with no compositor, window
manager, or display server. Implemented as a new Ghostty **apprt** (app
runtime) called `kms`, maintained as a thin patch series on top of upstream
Ghostty and built with Nix.

Targets, in bring-up order: an Intel/AMD Linux dev machine, then an NVIDIA
Jetson (JetPack 6), then a Raspberry Pi (4/5).

## Decisions already made (and why)

- **New apprt inside Ghostty, not a separate program on libghostty-vt.** We get
  Ghostty's real renderer, fonts, Kitty graphics, themes, and config for free.
  Alternatives rejected: kmscon with libtsm swapped for libghostty-vt (would
  have to reimplement Kitty graphics compositing and wouldn't look like
  Ghostty); a Vulkan backend (lots of boilerplate, no gain for a terminal;
  Ghostty's Linux renderer is OpenGL).
- **Not upstreamable.** Upstream's answer to a KMS backend request
  (ghostty-org/ghostty discussion #13391) was to point at libghostty. Plan for
  a long-lived patch series that gets rebased.
- **Patch series via Nix, not a full fork.** See "Nix layout" below.
- **Language:** Zig. Ghostty currently builds with Zig 0.16 (per
  `nix/package.nix` upstream).

## What upstream Ghostty already provides

Findings from reading Ghostty `main` (version string `1.3.2-dev`, Oct 2026).
Re-verify against whatever revision is pinned; internals move fast.

### The renderer is already headless

- `src/renderer/OpenGL.zig` + `src/renderer/opengl/Device.zig` create their
  own EGL context. Default platform is `EGL_PLATFORM_SURFACELESS_MESA`, but the
  device options accept an EGL display from the apprt (the GTK apprt passes its
  Wayland/X11 display via `renderDeviceOptions`).
- Frames render into an offscreen texture (`src/renderer/opengl/Target.zig`)
  and are exported as a **DMABUF**, with a CPU-pixel fallback if export fails.
  The renderer stores the latest frame and sends a `.redraw` message to the
  surface mailbox.
- The GTK apprt consumes frames in `src/apprt/gtk/class/render_surface.zig`
  by importing the DMABUF as a texture. Mirror that flow.
- Requires **desktop OpenGL 4.3 core**. Shaders in
  `src/renderer/shaders/glsl/` use `#version 430 core`, an `std430` storage
  buffer for `bg_cells`, and `sampler2DRect` for the glyph atlases.
- **Frames are vertically flipped** (GL origin is bottom-left). GTK flips at
  composite time. Direct scanout would display upside down.

### The apprt interface is small

- Runtime selection: `src/apprt/runtime.zig`, `src/apprt.zig`. Build wiring:
  `src/build/Config.zig`, `src/build/SharedDeps.zig`.
- Methods the core calls on an apprt **Surface**: `getSize`,
  `getContentScale`, `getCursorPos`, `getTitle`, `close`, `defaultTermioEnv`,
  `renderDeviceOptions`, `supportsClipboard`, `clipboardRequest`,
  `setClipboard`.
- **App** needs `init` / `run` / `terminate`, `wakeup`, `keyboardLayout`,
  `performIpc`, and `performAction`. `performAction` switches over ~77 actions
  (`src/apprt/action.zig`); most are tabs/splits/window chrome and can return
  `false`.
- The apprt drives the core through `src/Surface.zig` callbacks: key, text,
  mouse button, cursor position, scroll, size, focus, content scale.
- `src/apprt/gtk/` (~24k lines) is the reference, but most of it is UI we
  don't need. `src/apprt/gtk/App.zig` shows the wrapper pattern;
  `src/apprt/embedded.zig` is a smaller second example.

### Keyboard mapping mostly exists

- `src/input/keycodes.zig` has a table of USB / evdev / XKB / Win / Mac codes
  mapped to Ghostty physical keys. libinput gives evdev codes (XKB = evdev + 8).
- `src/apprt/gtk/key.zig` (~650 lines) shows how to build `input.KeyEvent`
  (physical key, mods, UTF-8 text, consumed mods). Use xkbcommon for keysyms,
  text, and modifier state.

## Design of the `kms` apprt

1. **Seat:** libseat to open the DRM and input devices without root and to get
   enable/disable callbacks for VT switching.
2. **Display:** open the DRM device, pick connector/CRTC/mode, create a GBM
   device, and create an EGL display on `EGL_PLATFORM_GBM_KHR`. Pass that
   display through `renderDeviceOptions` so the renderer runs on the same GPU.
3. **Presenter:** a small GLES context on a GBM surface. On `.redraw`, take the
   latest frame, import the DMABUF as an EGLImage texture, draw a fullscreen
   quad **flipped vertically**, swap, lock the GBM front buffer, add a DRM
   framebuffer, and page-flip. This also avoids buffers whose format modifier
   can't be scanned out. If DMABUF import fails, upload the CPU-fallback pixels
   instead.
4. **Input:** libinput + xkbcommon, translated into core Surface callbacks.
5. **Main loop:** libxev (Ghostty already depends on it) watching the DRM fd
   (page-flip events), libinput fd, and libseat fd, plus an `xev.Async` for
   `wakeup` that runs the core tick.
6. **VT switching:** on seat disable, stop presenting and drop DRM master. On
   enable, re-modeset and force a full redraw.
7. **Single surface:** one fullscreen terminal. No tabs, splits, or windows.
8. **Clipboard:** in-process only (no system clipboard exists on the console).
9. **Mouse cursor:** DRM cursor plane, or skip at first.
10. **Content scale:** derive from the connector's physical size in mm, with a
    config override.

### Implementation notes (what was actually built)

The design above is implemented in `apprt-kms/` (one file per numbered
item: `Seat.zig`, `Drm.zig`, `Presenter.zig`, `Input.zig` + `Keyboard.zig`,
`App.zig`, `Surface.zig`, `Cursor.zig`). Things learned or decided while
building it:

- **Orientation:** the presenter maps texture (0,0) to the bottom-left of the
  GL window surface, which is already upright on screen (verified in QEMU).
  The "flip" GTK does is because GTK's scene graph has a top-left origin;
  only direct scanout of the renderer's buffer would need one. The shader
  keeps a `flip_y` knob (`GHOSTTY_KMS_FLIP_Y=1`) as an escape hatch.
- **kms-specific settings are environment variables** (`GHOSTTY_KMS_DEVICE`,
  `_CONNECTOR`, `_MODE`, `_SCALE`, `_RENDER_DEVICE`, `_PRESENT=cpu`,
  `_FLIP_Y`, `_REPEAT_DELAY`, `_REPEAT_RATE`, `_SEAT_TIMEOUT`; see README),
  so the patch doesn't have to touch Ghostty's config parser. Regular
  Ghostty config still applies.
- **C interop** goes through one translated header, `apprt-kms/c.c`, wired
  up with upstream's `translate_c` build helper (Zig 0.16 has no
  `@cImport` in this codebase). EGL comes from Ghostty's glad bindings
  (`@import("opengl").egl`) because glad's header refuses to coexist with
  `<EGL/egl.h>`; the presenter's GLES 2 calls link `libGLESv2` directly.
- **Main loop** is libxev as designed: `xev.Async` for `wakeup`, and
  one-shot readiness polls (`xev.File.poll`, rearmed) on the seat, DRM,
  libinput and key-repeat timerfd fds. Signals (INT/TERM/HUP) use a
  handler that notifies the Async; not a blocked mask + signalfd, because
  Ghostty resets handlers but not the signal mask before exec'ing the shell.
- **Keyboard events mirror the GTK apprt**: text is the keysym's character
  without control transformation (Ctrl+A gives "a"), C0 controls produce no
  text, sided modifiers come from the physical key, consumed mods use
  `XKB_CONSUMED_MODE_GTK`. Dead keys via xkbcommon compose. Ctrl+Alt+Fn
  (`XF86Switch_VT_n` keysyms) switches VTs and isn't forwarded.
- **Clipboard requests complete asynchronously** from the main loop (never
  inside `clipboardRequest`, to stay out of the core's call stack and
  locks). With no prompt UI: unsafe pastes from the in-process clipboard are
  confirmed automatically (the data came from this terminal); program
  clipboard access that the config says to "ask" about is denied.
- **DMABUF import** retries with an implicit modifier if an explicit one is
  rejected, then falls back to CPU frames via
  `reportPresentationHealth(.unhealthy)`. Mesa's llvmpipe on `kms_swrast`
  exports DMABUFs fine but can't import them (`EGL_BAD_ALLOC`), so software
  rendering always ends up on the CPU path.
- **The cursor plane** isn't touched while the seat is inactive (losing DRM
  master races the disable notification) and is re-applied after the
  modeset that follows re-enable.
- **zink when the native driver can't do GL 4.3, no software fallback.**
  At startup `App.initRenderDisplay` tries a GL 4.3 core context on the
  native driver; if that fails it opens the GPU's render node
  (`drmGetRenderDeviceNameFromFd`, else the first `renderD*`) with
  `MESA_LOADER_DRIVER_OVERRIDE=zink` set only while that display is
  created, plus `MESA_GL_VERSION_OVERRIDE=4.3`/`MESA_GLSL_VERSION_OVERRIDE=430`
  (zink on GPUs without tessellation, like V3D, reports less than 4.3;
  Ghostty doesn't use tessellation, and the presenter's GLES context
  ignores the GL override). On the Pi: V3D's GL driver fails ("Too many
  vertex shader storage blocks (1/0)" even with the version override),
  zink on V3DV works because Vulkan requires storage buffers in every
  stage. Software rasterizers are refused (`eglGetDisplayDriverName` is
  `swrast`/`kms_swrast`) unless `GHOSTTY_KMS_ALLOW_SOFTWARE=1`, which only
  the QEMU tests set: llvmpipe at 1440p browned out a Pi 5. The earlier
  `GHOSTTY_KMS_RENDER_DEVICE=software` (llvmpipe) option was removed.
  Drivers come from the system's `hardware.graphics`; `mesa-rpi` is a Mesa
  with only vc4/v3d/zink + V3DV (no LLVM, no software rasterizer) to use as
  a Pi's `hardware.graphics.package`. A global `MESA_LOADER_DRIVER_OVERRIDE=zink` doesn't work: it
  hits the vc4 display device too, zink fails there, and Mesa silently
  falls back to software.
- **Login console** (`programs.ghostty-kms.console` in `nix/module.nix`):
  per-VT `autovt@ttyN` units (an exact instance file beats the
  autovt@ = getty@ template, so other VTs keep getty), `login` as the
  command, `Restart=always`, `OnFailure=getty@ttyN`. Ghostty must *not* hold
  a logind session (no `PAMName`): logind refuses to create the user's
  session for a process already in one, and refuses a second session on an
  occupied VT. So it uses libseat's `builtin` backend as root, and `login`
  runs as `login -p` under `env -i` with just TERM/locale/Ghostty's terminal
  vars plus `XDG_SEAT`/`XDG_VTNR`, which pam_systemd uses to put the user's
  session on the seat and VT (plain `login` wipes its environment first).
  `GHOSTTY_KMS_SEAT_TIMEOUT=0` waits for the VT indefinitely, like getty.
  nixpkgs' kmscon module has the session problem; this design avoids it.
- **Seat acquisition times out** (10 s) with a clear error instead of hanging
  when started outside a VT session (e.g. over SSH).

## Nix layout

Override Ghostty's own flake package rather than forking:

```nix
inputs.ghostty.url = "github:ghostty-org/ghostty/<pinned-rev>";

ghostty-kms = ghostty.packages.${system}.ghostty-releasefast.overrideAttrs (old: {
  patches = (old.patches or []) ++ (lib.filesystem.listFilesRecursive ./patches);
  postPatch = (old.postPatch or "") + ''
    cp -r ${./apprt-kms} src/apprt/kms
  '';
  buildInputs = old.buildInputs ++ (with pkgs; [ libdrm libgbm libinput libxkbcommon seatd ]);
  zigBuildFlags = old.zigBuildFlags ++ [ "-Dapp-runtime=kms" ];
});
```

Rules:

- **New code lives in `apprt-kms/`** in this repo and is copied in during
  `postPatch`. New files never conflict on rebase.
- **Keep `patches/` minimal:** only the runtime enum, the `apprt.zig` switch,
  and build wiring. Target a few dozen lines.
- **No new Zig package dependencies.** Upstream's Nix build pre-fetches Zig
  deps from `build.zig.zon.nix`; adding one means regenerating it. Link only C
  system libraries through pkg-config.
- Upstream's package is built for GTK, so `nix/ghostty-kms.nix` replaces
  its input lists with whitelists instead of appending: no GTK4, libadwaita,
  glib/GObject introspection, GStreamer, X11, Wayland or wrapGAppsHook4. It
  also slims dependencies whose default nixpkgs builds link desktop libraries
  (harfbuzz without glib, libxkbcommon without X11/Wayland, libinput without
  libwacom, libglvnd without GLX, libdrm without libdrm_intel so hwdata's PCI
  ID database drops out, and libgbm rebuilt against that libdrm), uses a copy of upstream's Zig dependency
  cache without the GTK/Wayland binding packages (all lazy, only the GTK
  runtime requests them), generates xkbcommon's Compose data from the libX11
  source instead of the libX11 package, and deletes the libghostty-vt
  library upstream always installs. `disallowedRequisites` fails the build if
  any of that comes back into the runtime closure (106 MiB on x86_64, down
  from 3.2 GiB; most of what's left is glibc, libstdc++ and Ghostty itself); `scripts/check-no-gtk.sh` also checks what the build
  fetches and builds. Expect these overrides to need touching on upstream or
  nixpkgs bumps.
- **Updating:** bump the pinned rev, rebuild, fix any failing hunks. Keep a
  local git branch of upstream with our commits on top and regenerate patches
  with `git format-patch`.
- Ghostty's binary cache won't have this build. aarch64 builds happen on the
  boards, a remote builder, or under emulation (slow).

## Hardware notes

### Dev machine (Intel/AMD + Mesa)

Everything should just work. Do all initial development here.

### Jetson (JetPack 6)

- NVIDIA's driver supports desktop GL 4.6, so the renderer is fine.
- GPU and display controller are **separate DRM devices** on Orin. Load
  `nvidia-drm` with `modeset=1` so the display controller appears. Render on
  one device, scan out on the other.
- The renderer's default surfaceless platform is a Mesa extension; NVIDIA's EGL
  won't have it. We pass our own GBM display, so this shouldn't matter.
- GBM/KMS on Jetson has a buggy history (broken before JetPack 5.1.2), and
  GBM-DMABUF-to-GL imports have had issues. Fall back to the CPU frame path if
  needed.
- A Nix-built binary on stock JetPack will find Mesa's EGL from the Nix store
  instead of NVIDIA's. Either point libglvnd at the JetPack vendor libraries,
  or run NixOS on the Jetson via jetpack-nixos.

### Raspberry Pi (4/5)

- Mesa's V3D driver provides GLES 3.1 and desktop GL 3.1 at most. **Ghostty's
  GL 4.3 requirement is not met.**
- Plan was **llvmpipe** first. In practice it pegged all four cores and
  browned out a Pi 5; **zink on V3DV** (see Implementation notes) runs
  Ghostty on the GPU instead; ghostty-kms picks it automatically.
- Only if too slow: port the OpenGL backend to GLES 3.1 (GLSL ES shaders,
  `sampler2D` + `texelFetch` instead of `sampler2DRect`, move `bg_cells` into a
  texture if fragment-shader SSBOs aren't available). This is the one patch
  that would be painful to carry.
- On a non-NixOS Pi, Nix-built GL apps need help finding drivers (nixGL or
  similar). NixOS on the Pi avoids this.

## Milestones

Status as of 2026-10-13: 1-7 done and verified end to end in QEMU
(`tests/qemu/e2e.sh`, 19 checks, passing on aarch64 and x86_64 guests on
virtio-gpu + llvmpipe, i.e. the CPU frame path). 9 mostly: on a Pi 5
(2026-10-22) it runs at 2560x1440@144 with the renderer
on zink/V3DV (picked automatically) and the presenter on V3D, ~1% CPU idle;
the Pi 5 needs a solid supply. Not yet done:
input/VT checks on the Pi, real Intel/AMD hardware, and 8 (Jetson).

1. Flake builds unmodified upstream Ghostty from a pinned rev.
2. `kms` runtime compiles as a stub (empty apprt, build wiring patch).
3. Modeset and page-flip a solid color through GBM/EGL on the dev machine.
4. Ghostty frames on screen (DMABUF import, flipped blit).
5. Keyboard input; a usable shell.
6. VT switching via libseat.
7. Mouse, scroll, in-process clipboard, content scale.
8. Jetson bring-up.
9. Pi bring-up on llvmpipe.

## Testing

- **Unit tests** in `apprt-kms` run with Ghostty's test step:
  `scripts/dev-build.sh test -Dtest-filter=scaleFromDpi`.
- **End to end:** `tests/qemu/` boots a NixOS guest (`nix/test-vm.nix`,
  netboot-style kernel + initrd) with a virtio-gpu display, seatd and an
  autologin on tty1 that starts Ghostty; Ghostty's log goes to the serial
  console. `tests/qemu/e2e.sh` drives it over QMP and checks serial-console
  markers (keyboard -> shell) and exact screenshot pixel colors (renderer
  -> presenter -> KMS). On macOS: build the guest in a Linux VM (OrbStack;
  the repo is shared), run QEMU on the Mac with HVF.
- QEMU screendumps don't include the hardware cursor plane, so the e2e
  test checks the "hardware cursor enabled" log line instead.

## Useful references

- Upstream Ghostty: github.com/ghostty-org/ghostty
- kmscon (reference for seat, DRM, VT handling): github.com/kmscon/kmscon
- wlroots' DRM backend and renderer for GBM/EGL/page-flip patterns
- kmscube: minimal GBM + EGL + KMS example
