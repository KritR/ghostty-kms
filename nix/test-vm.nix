# A minimal NixOS guest for end-to-end testing of the kms runtime under
# QEMU with a virtio-gpu display. It boots straight from a kernel + initrd
# (netboot style, whole system in the initrd), autologins user `test` on
# tty1 and launches ghostty there, the same way a person would from a VT.
#
# Rendering uses Mesa's llvmpipe (software GL 4.5) since virtio-gpu
# without virgl has no 3D. That's also the planned Raspberry Pi path.
#
# Ghostty's log goes to the serial console (hvc0/ttyAMA0/ttyS0) so the
# host can read it. See tests/qemu/run.sh.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}: let
  ghostty-kms = config.programs.ghostty-kms.package;
  serial =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "ttyAMA0"
    else "ttyS0";

  # Started by the tty1 login shell. Logs go to the serial console.
  session = pkgs.writeShellScript "ghostty-kms-session" ''
    export GHOSTTY_KMS_SEAT_TIMEOUT=20000
    echo "=== starting ghostty on $(tty) ===" > /dev/${serial}
    ${lib.getExe ghostty-kms} 2>&1 | ${pkgs.coreutils}/bin/tee /tmp/ghostty.log > /dev/${serial}
    echo "=== ghostty exited: ''${PIPESTATUS[0]} ===" > /dev/${serial}
    # Leave the VT at a shell so the test can tell ghostty exited.
    exec ${pkgs.bashInteractive}/bin/bash -i
  '';
  demo = import ./ghostty-demo.nix {inherit pkgs ghostty-kms;};
in {
  imports = [
    (modulesPath + "/installer/netboot/netboot.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    (modulesPath + "/profiles/minimal.nix")
  ];

  system.stateVersion = lib.trivial.release;

  # Faster to build than xz; size doesn't matter for a test image.
  netboot.squashfsCompression = "zstd -Xcompression-level 3";

  boot.kernelParams = ["console=${serial}" "loglevel=4"];
  boot.initrd.availableKernelModules = ["virtio_gpu" "virtio_input" "virtio_pci"];
  boot.kernelModules = ["virtio_gpu"];

  # llvmpipe: virtio-gpu has no 3D without virgl.
  programs.ghostty-kms = {
    enable = true;
    softwareRendering = true;
  };

  # libseat works with logind (default) or seatd; use seatd here to
  # exercise that path. Our user is in the `seat` group.
  services.seatd.enable = true;
  environment.sessionVariables.LIBSEAT_BACKEND = "seatd";

  users.users.test = {
    isNormalUser = true;
    password = "";
    extraGroups = ["video" "input" "seat" "dialout" "tty"];
  };
  services.getty.autologinUser = "test";

  # The serial console is for logs, not a login.
  systemd.services."serial-getty@${serial}".enable = false;

  programs.bash.loginShellInit = ''
    if [ "$(tty)" = /dev/tty1 ]; then
      exec ${session}
    fi
  '';

  # Ghostty reads $XDG_CONFIG_HOME/ghostty/config.
  systemd.tmpfiles.rules = [
    "d /home/test/.config 0755 test users -"
    "d /home/test/.config/ghostty 0755 test users -"
    "L+ /home/test/.config/ghostty/config - - - - ${pkgs.writeText "ghostty-test-config" ''
      font-size = 14
      window-padding-x = 4
      window-padding-y = 4
      shell-integration = none
      command = ${pkgs.bashInteractive}/bin/bash --noprofile --norc -i
    ''}"
  ];

  environment.systemPackages = [
    pkgs.libdrm # modetest, for debugging
    pkgs.timg
    demo
  ];

  # Keep the image lean.
  documentation.enable = false;
  networking.firewall.enable = false;
  networking.useDHCP = false;
}
