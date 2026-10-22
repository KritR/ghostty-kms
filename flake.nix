{
  description = "Ghostty on the bare Linux console (DRM/KMS) via a `kms` apprt patch series";

  inputs = {
    # Pinned upstream revision. To update: bump the rev, rebuild, fix any
    # failing hunks in patches/ (see README.md "Updating upstream").
    ghostty.url = "github:ghostty-org/ghostty/81598385d608dda4946093d6d6a234d204a2f225";
    nixpkgs.follows = "ghostty/nixpkgs";
  };

  outputs = {
    self,
    ghostty,
    nixpkgs,
    ...
  }: let
    inherit (nixpkgs) lib;
    systems = ["x86_64-linux" "aarch64-linux"];
    forSystems = f: lib.genAttrs systems (system: f system nixpkgs.legacyPackages.${system});

    # Dependencies whose default nixpkgs builds link desktop libraries.
    # Shared by ghostty-kms and the Mesa bundled into ghostty-kms-rpi.
    slimFor = pkgs: rec {
      # glib/gobject integration is only for GTK-style consumers.
      harfbuzz = (pkgs.harfbuzz.override {withIntrospection = false;}).overrideAttrs (o: {
        mesonFlags = o.mesonFlags ++ ["-Dglib=disabled" "-Dgobject=disabled" "-Ddocs=disabled" "-Dtests=disabled"];
        nativeBuildInputs = lib.subtractLists [pkgs.glib pkgs.gtk-doc] o.nativeBuildInputs;
        buildInputs = lib.remove pkgs.glib o.buildInputs;
        doCheck = false;
        outputs = lib.remove "devdoc" o.outputs;
      });

      # Compose tables (dead keys) and locale aliases are part of libX11's
      # locale data. Generate them from the libX11 *source* the way its
      # build does (nls/Makefile.am, cpprules.in), so no X11 binaries are
      # fetched or built.
      xlocale = pkgs.runCommandCC "xlocale-data" {inherit (pkgs.libx11) src;} ''
        tar -xf $src
        cd libX11-*/nls
        magic() {
          LC_CTYPE=C sed -e '/^#  *[0-9][0-9]*  *.*$/d' \
            -e '/^#line  *[0-9][0-9]*  *.*$/d' \
            -e '/^[	 ]*XCOMM$/s/XCOMM/#/' \
            -e '/^[	 ]*XCOMM[^a-zA-Z0-9_]/s/XCOMM/#/' \
            -e '/^[	 ]*XHASH/s/XHASH/#/' \
            -e "s,X11_LOCALEDATADIR,$out,g" \
            -e '/@@$/s/@@$/\\/' \
            -e '/^$/d'
        }
        pp() { cpp -undef -traditional -DWCHAR32=1 < "$1" | magic; }
        mkdir -p $out
        for f in locale.alias compose.dir locale.dir; do
          pp $f.pre > $f.l1
          LC_CTYPE=C sed -e '/^[^#][^	 ]*:/s/://' -e '/^[^#].*[	 ].*:/d' < $f.l1 > $f.l2
          cat $f.l2 $f.l1 > $out/$f
        done
        for d in */; do
          d=''${d%/}
          for f in Compose XLC_LOCALE; do
            if [ -f $d/$f.pre ]; then
              mkdir -p $out/$d
              pp $d/$f.pre > $out/$d/$f
            fi
          done
          if [ -f $d/XI18N_OBJS ]; then
            mkdir -p $out/$d
            cp $d/XI18N_OBJS $out/$d/
          fi
        done
      '';

      # No libxkbcommon-x11 (libxcb), Wayland tools, docs or the X11-based
      # test suite (xvfb, setxkbmap, xkbcomp).
      libxkbcommon = (pkgs.libxkbcommon.override {withWaylandTools = false;}).overrideAttrs (o: {
        nativeBuildInputs = with pkgs.buildPackages; [meson ninja pkg-config bison];
        buildInputs = [pkgs.xkeyboard_config pkgs.libxml2];
        nativeCheckInputs = [];
        doCheck = false;
        outputs = lib.remove "doc" o.outputs;
        mesonFlags =
          (lib.filter (f: !(lib.any (p: lib.hasPrefix p f) ["-Dx-locale-root=" "-Denable-wayland=" "-Denable-docs="])) o.mesonFlags)
          ++ [
            "-Dx-locale-root=${xlocale}"
            "-Denable-x11=false"
            "-Denable-wayland=false"
            "-Denable-docs=false"
          ];
      });

      # Only libEGL and libGLESv2 are used (desktop GL entry points are
      # resolved through eglGetProcAddress), so build without GLX/X11.
      libglvnd = pkgs.libglvnd.overrideAttrs (o: {
        buildInputs = [];
        configureFlags = (o.configureFlags or []) ++ ["--disable-x11" "--disable-glx"];
        postFixup = "";
      });

      # libdrm_intel is the only libdrm library that links libpciaccess,
      # which drags in hwdata's 10 MiB PCI ID database. Nothing we load
      # uses it (Mesa's Intel drivers don't either).
      libdrm = pkgs.libdrm.override {withIntel = false;};

      # The same gbm-only Mesa build as nixpkgs', against that libdrm.
      # Upstream propagates libdrm, which leaves libdrm's -dev output in
      # the runtime closure; we list libdrm in our own buildInputs instead.
      libgbm = (pkgs.libgbm.override {inherit libdrm;}).overrideAttrs (o: {
        propagatedBuildInputs = [];
        buildInputs = (o.buildInputs or []) ++ [libdrm];
      });

      # libwacom (tablets) pulls in glib and libgudev; Lua plugins aren't
      # needed for a terminal.
      libinput = pkgs.libinput.override {
        wacomSupport = false;
        luaSupport = false;
      };
    };

    # Apply the kms runtime on top of one of upstream's package variants.
    #
    # Upstream's derivation is built for the GTK runtime: its inputs include
    # GTK4, libadwaita, glib/GObject introspection, GStreamer, X11 and
    # Wayland, and wrapGAppsHook4 wraps the binary with references to all
    # of them. None of that is used with -Dapp-runtime=kms, so both input
    # lists are replaced with explicit whitelists rather than appended to.
    mkKms = pkgs: base: let
      # Build tools we keep from upstream's list, by name. Anything not
      # listed (wrapGAppsHook4, gobject-introspection, blueprint-compiler,
      # wayland-scanner/protocols) is dropped.
      keepNative = ["git" "ncurses" "pandoc-cli" "pkg-config-wrapper" "zig" "libxml2" "gettext"];

      slim = slimFor pkgs;

      # Upstream's offline Zig dependency cache, minus the GTK and Wayland
      # bindings. They're lazy dependencies that only the GTK runtime asks
      # for, but the generated cache fetches every package. Entries in the
      # generated file look like `    "<hash>" = fetchzip { name = "x"; ... };`.
      zigDeps = let
        drop = ["gobject" "gtk4_layer_shell" "wayland" "wayland_protocols" "plasma_wayland_protocols" "zig_wayland"];
        isDropped = block: lib.any (n: lib.elem "      name = \"${n}\";" block) drop;
        step = acc: line:
          if acc.block != null
          then
            if line == "    };"
            then {
              block = null;
              out = acc.out ++ lib.optionals (!isDropped acc.block) (acc.block ++ [line]);
            }
            else acc // {block = acc.block ++ [line];}
          else if lib.hasPrefix "    \"" line && lib.hasInfix "\" = fetch" line
          then acc // {block = [line];}
          else acc // {out = acc.out ++ [line];};
        source = builtins.readFile "${ghostty}/build.zig.zon.nix";
        filtered = lib.concatStringsSep "\n" (builtins.foldl' step {
          out = [];
          block = null;
        } (lib.splitString "\n" source)).out;
      in
        pkgs.callPackage (builtins.toFile "build.zig.zon.nix" filtered) {name = "ghostty-kms-zig-deps";};
    in
      base.overrideAttrs (old: {
        pname = "ghostty-kms";
        # Upstream's zigBuildFlags pass `--system ${finalAttrs.deps}`.
        deps = zigDeps;
        patches = (old.patches or []) ++ (lib.filesystem.listFilesRecursive ./patches);
        postPatch =
          (old.postPatch or "")
          + ''
            cp -r ${./apprt-kms} src/apprt/kms
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
      });

    # Kernel, initrd and command line of a test guest, for tests/qemu/run.sh.
    mkGuestFiles = pkgs: name: let
      cfg = self.nixosConfigurations.${name}.config;
    in
      pkgs.runCommand "ghostty-kms-${name}" {} ''
        mkdir -p $out
        ln -s ${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile} $out/kernel
        ln -s ${cfg.system.build.netbootRamdisk}/initrd $out/initrd
        echo "init=${cfg.system.build.toplevel}/init ${toString cfg.boot.kernelParams}" > $out/cmdline
      '';

    # NixOS guests for end-to-end tests under QEMU (see nix/test-vm*.nix).
    mkTestVm = system: module:
      nixpkgs.lib.nixosSystem {
        inherit system;
        modules = [self.nixosModules.default module];
      };
  in {
    nixosModules.default = import ./nix/module.nix self;

    nixosConfigurations = {
      test-vm-x86_64-linux = mkTestVm "x86_64-linux" ./nix/test-vm.nix;
      test-vm-aarch64-linux = mkTestVm "aarch64-linux" ./nix/test-vm.nix;
      test-vm-console-x86_64-linux = mkTestVm "x86_64-linux" ./nix/test-vm-console.nix;
      test-vm-console-aarch64-linux = mkTestVm "aarch64-linux" ./nix/test-vm-console.nix;
    };

    packages = forSystems (system: pkgs: let
      up = ghostty.packages.${system};
    in rec {
      # Milestone 1: unmodified upstream from the pinned rev.
      ghostty-upstream = up.ghostty-releasefast;

      # Upstream's pre-fetched Zig dependency cache, for offline
      # `zig build --system <path>` during development (see README).
      ghostty-deps = up.deps;

      ghostty-kms = mkKms pkgs up.ghostty-releasefast;
      ghostty-kms-debug = mkKms pkgs up.ghostty-debug;
      ghostty-kms-releasesafe = mkKms pkgs up.ghostty-releasesafe;

      default = ghostty-kms;

      # Raspberry Pi variant for systems without GPU userspace drivers
      # (hardware.graphics disabled, or not NixOS). Bundles a Mesa with only
      # the Pi's drivers and no software rasterizer:
      #
      #   - presenter (blit + scanout): native vc4/v3d, OpenGL ES 3.1
      #   - renderer: zink on V3DV (Vulkan), because V3D's own GL driver
      #     lacks desktop GL 4.3 and allows no vertex-stage storage buffers
      #
      # zink is selected for the v3d render node only, through a driconf
      # file, so the display device keeps its native driver.
      ghostty-kms-rpi = let
        mesa =
          (pkgs.mesa.override {
            galliumDrivers = ["vc4" "v3d" "zink"];
            vulkanDrivers = ["broadcom"];
            vulkanLayers = [];
            eglPlatforms = [];
            withValgrind = false;
            enablePatentEncumberedCodecs = false;
            # The same libdrm/libgbm as ghostty-kms (no libdrm_intel, so no
            # hwdata, and one copy of each).
            inherit (slimFor pkgs) libdrm libgbm;
          }).overrideAttrs (o: {
            # nixpkgs builds with every auto feature on; without the X11
            # platform these have to be off explicitly. No LLVM: none of the
            # Pi's drivers need it (it's for llvmpipe, radeonsi and OpenCL).
            mesonFlags =
              (lib.filter (f:
                !(lib.any (p: lib.hasPrefix p f) [
                  "-Dtools="
                  "-Dintel-rt="
                  "-Damdgpu-virtio="
                  "-Dfreedreno-kmds="
                  "-Dgallium-rusticl"
                  "-Dclang-libdir="
                  "-Dinstall-mesa-clc="
                  "-Dinstall-precomp-compiler="
                ]))
              o.mesonFlags)
              ++ [
                "-Dxlib-lease=disabled"
                "-Dglx=disabled"
                "-Dtools="
                "-Dintel-rt=disabled"
                "-Damdgpu-virtio=false"
                "-Dgallium-va=disabled"
                "-Dllvm=disabled"
                "-Dgallium-rusticl=false"
                "-Dmesa-clc=auto"
                "-Dinstall-mesa-clc=false"
                "-Dinstall-precomp-compiler=false"
              ];
            # Outputs nixpkgs declares that only drivers/frontends we don't
            # build populate.
            postInstall = (o.postInstall or "") + "\nmkdir -p $spirv2dxil $opencl $cross_tools\n";
            # nixpkgs also adds zink's libvulkan RPATH to the OpenCL
            # library, which isn't built without LLVM.
            postFixup = lib.replaceStrings [" $opencl/lib/libRusticlOpenCL.so"] [""] o.postFixup;
          });

        # Mesa's defaults plus: use zink for the v3d device (the render node).
        drirc = pkgs.runCommand "ghostty-kms-rpi-drirc" {} ''
          mkdir -p $out
          cp ${mesa}/share/drirc.d/* $out/
          cat > $out/99-ghostty-kms-rpi.conf <<'XML'
          <?xml version="1.0" standalone="yes"?>
          <driconf>
            <device driver="loader" kernel_driver="v3d">
              <application name="all">
                <option name="dri_driver" value="zink"/>
              </application>
            </device>
          </driconf>
          XML
        '';
      in
        pkgs.runCommand "ghostty-kms-rpi-${ghostty-kms.version}" {
          nativeBuildInputs = [pkgs.makeWrapper];
          meta = ghostty-kms.meta // {platforms = ["aarch64-linux"];};
          passthru = {inherit mesa;};
        } ''
          mkdir -p $out/bin
          makeWrapper ${ghostty-kms}/bin/ghostty $out/bin/ghostty \
            --set-default __EGL_VENDOR_LIBRARY_FILENAMES ${mesa}/share/glvnd/egl_vendor.d/50_mesa.json \
            --set-default GBM_BACKENDS_PATH ${mesa}/lib/gbm \
            --set-default VK_DRIVER_FILES ${mesa}/share/vulkan/icd.d/broadcom_icd.aarch64.json \
            --set-default DRIRC_CONFIGDIR ${drirc} \
            --set-default GHOSTTY_KMS_RENDER_DEVICE /dev/dri/renderD128 \
            --set-default MESA_GL_VERSION_OVERRIDE 4.3 \
            --set-default MESA_GLSL_VERSION_OVERRIDE 430
          ln -s ${ghostty-kms}/share $out/share
        '';

      # Test guests for tests/qemu/ (autologin session, and the console).
      test-vm = mkGuestFiles pkgs "test-vm-${system}";
      test-vm-console = mkGuestFiles pkgs "test-vm-console-${system}";
    });

    # Development shell: upstream's shell plus the kms system libraries, for
    # iterating with `zig build -Dapp-runtime=kms` inside upstream/.
    devShells = forSystems (system: pkgs: {
      default = ghostty.devShells.${system}.default.overrideAttrs (old: {
        buildInputs =
          (old.buildInputs or [])
          ++ (with pkgs; [
            libdrm
            libgbm
            libinput
            libxkbcommon
            seatd
            libGL
            udev
          ]);
      });
    });

    formatter = forSystems (_: pkgs: pkgs.alejandra);
  };
}
