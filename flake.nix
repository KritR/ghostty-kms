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

    # The kms package on top of one of upstream's package variants.
    mkKms = pkgs: base:
      import ./nix/ghostty-kms.nix {
        inherit lib pkgs base;
        ghosttySrc = ghostty;
      };

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

      # The README screenshot's demo (Kitty graphics, colors, styles).
      ghostty-demo = import ./nix/ghostty-demo.nix {inherit pkgs ghostty-kms;};

      # Trimmed Mesa for a Raspberry Pi's hardware.graphics.package.
      mesa-rpi = import ./nix/mesa-rpi.nix {inherit lib pkgs;};

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
