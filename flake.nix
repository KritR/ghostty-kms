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

    # Apply the kms runtime on top of one of upstream's package variants.
    mkKms = pkgs: base:
      base.overrideAttrs (old: {
        pname = "ghostty-kms";
        patches = (old.patches or []) ++ (lib.filesystem.listFilesRecursive ./patches);
        postPatch =
          (old.postPatch or "")
          + ''
            cp -r ${./apprt-kms} src/apprt/kms
            chmod -R u+w src/apprt/kms
          '';
        buildInputs =
          old.buildInputs
          ++ (with pkgs; [
            libdrm
            libgbm
            libinput
            libxkbcommon
            seatd
            libGL
            udev
          ]);
        zigBuildFlags = old.zigBuildFlags ++ ["-Dapp-runtime=kms"];
        # The upstream postInstall assumes the GTK install layout (desktop
        # files, vim plugin, etc.), which the kms runtime also installs, so we
        # keep it as is.
        meta =
          old.meta
          // {
            description = "Ghostty running directly on DRM/KMS";
            mainProgram = "ghostty";
          };
      });

    # NixOS guest for end-to-end tests under QEMU (see nix/test-vm.nix).
    mkTestVm = system:
      nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs.ghostty-kms = self.packages.${system}.ghostty-kms;
        modules = [./nix/test-vm.nix];
      };
  in {
    nixosConfigurations = {
      test-vm-x86_64-linux = mkTestVm "x86_64-linux";
      test-vm-aarch64-linux = mkTestVm "aarch64-linux";
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

      # Kernel, initrd and command line of the test guest, for
      # tests/qemu/run.sh.
      test-vm = let
        cfg = self.nixosConfigurations."test-vm-${system}".config;
      in
        pkgs.runCommand "ghostty-kms-test-vm" {} ''
          mkdir -p $out
          ln -s ${cfg.system.build.kernel}/${cfg.system.boot.loader.kernelFile} $out/kernel
          ln -s ${cfg.system.build.netbootRamdisk}/initrd $out/initrd
          echo "init=${cfg.system.build.toplevel}/init ${toString cfg.boot.kernelParams}" > $out/cmdline
        '';
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
