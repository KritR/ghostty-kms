# Upstream's offline Zig dependency cache, minus the GTK and Wayland
# bindings. They're lazy dependencies that only the GTK runtime asks for,
# but upstream's generated cache (build.zig.zon.nix) fetches every package.
# Entries in that file look like `    "<hash>" = fetchzip { name = "x"; ... };`.
{
  lib,
  pkgs,
  ghosttySrc,
}: let
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
  source = builtins.readFile "${ghosttySrc}/build.zig.zon.nix";
  filtered =
    lib.concatStringsSep "\n"
    (builtins.foldl' step {
      out = [];
      block = null;
    } (lib.splitString "\n" source)).out;
in
  pkgs.callPackage (builtins.toFile "build.zig.zon.nix" filtered) {name = "ghostty-kms-zig-deps";}
