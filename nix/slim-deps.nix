# Dependencies whose default nixpkgs builds link desktop libraries (glib,
# X11, Wayland, ...), rebuilt without them. Shared by ghostty-kms and
# mesa-rpi so both use the same libdrm/libgbm.
{
  lib,
  pkgs,
}: rec {
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
}
