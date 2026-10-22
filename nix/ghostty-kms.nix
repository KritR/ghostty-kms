# ghostty-kms: upstream's Ghostty package (`base`, one of its optimize
# variants) with the kms runtime patched in.
#
# Upstream's derivation is built for the GTK runtime: its inputs include
# GTK4, libadwaita, glib/GObject introspection, GStreamer, X11 and
# Wayland, and wrapGAppsHook4 wraps the binary with references to all
# of them. None of that is used with -Dapp-runtime=kms, so both input
# lists are replaced with explicit whitelists rather than appended to.
{
  lib,
  pkgs,
  ghosttySrc,
  base,
}: let
  # Build tools we keep from upstream's list, by name. Anything not
  # listed (wrapGAppsHook4, gobject-introspection, blueprint-compiler,
  # wayland-scanner/protocols) is dropped.
  keepNative = ["git" "ncurses" "pandoc-cli" "pkg-config-wrapper" "zig" "libxml2" "gettext"];

  slim = import ./slim-deps.nix {inherit lib pkgs;};

  zigDeps = import ./zig-deps.nix {inherit lib pkgs ghosttySrc;};
in
  base.overrideAttrs (old: {
    pname = "ghostty-kms";
    # Upstream's zigBuildFlags pass `--system ${finalAttrs.deps}`.
    deps = zigDeps;
    patches = (old.patches or []) ++ (lib.filesystem.listFilesRecursive ../patches);
    postPatch =
      (old.postPatch or "")
      + ''
        cp -r ${../apprt-kms} src/apprt/kms
        chmod -R u+w src/apprt/kms
      '';

    nativeBuildInputs = lib.filter (p: lib.elem (p.pname or p.name) keepNative) old.nativeBuildInputs;

    buildInputs = with pkgs; [
      # Libraries Ghostty's core links as system integrations.
      bzip2
      fontconfig
      freetype
      slim.harfbuzz
      libpng
      oniguruma
      simdutf
      zlib
      glslang
      spirv-cross
      # The kms runtime.
      slim.libglvnd # libEGL + libGLESv2
      slim.libdrm
      slim.libgbm
      slim.libinput
      slim.libxkbcommon
      seatd
      udev
    ];

    # Only used to find GTK's typelibs.
    GI_TYPELIB_PATH = null;

    zigBuildFlags =
      (lib.filter (f: !(lib.hasPrefix "-Dgtk-" f)) old.zigBuildFlags)
      ++ ["-Dapp-runtime=kms" "-Dgtk-x11=false" "-Dgtk-wayland=false"];

    # Upstream marks GStreamer (used by GTK's bell sound) for the user's
    # environment; we don't use it.
    postInstall =
      lib.replaceStrings [
        ''echo "gst_all_1.gstreamer" >> "$out/nix-support/propagated-user-env-packages"''
        ''echo "gst_all_1.gst-plugins-base" >> "$out/nix-support/propagated-user-env-packages"''
        ''echo "gst_all_1.gst-plugins-good" >> "$out/nix-support/propagated-user-env-packages"''
      ] ["" "" ""]
      old.postInstall
      + ''
        # Upstream always installs libghostty-vt and its headers. They're
        # not needed to run the terminal, and the static archive's debug
        # info references the Zig toolchain and dependency cache.
        rm -rf $out/lib/libghostty-vt* $out/include
      '';

    # Fail the build if anything GTK-adjacent sneaks back into the
    # runtime closure.
    disallowedRequisites = with pkgs; [
      gtk4
      libadwaita
      glib
      gobject-introspection
      gsettings-desktop-schemas
      gst_all_1.gstreamer
      gst_all_1.gst-plugins-base
      gst_all_1.gst-plugins-good
      gtk4-layer-shell
      wayland
      libx11
      libxcb
      libwacom
      zig_0_16
      pango
      cairo
      gdk-pixbuf
    ];
    # Build-time inputs are checked by scripts/check-no-gtk.sh.

    meta =
      old.meta
      // {
        description = "Ghostty running directly on DRM/KMS";
        mainProgram = "ghostty";
      };
  })
