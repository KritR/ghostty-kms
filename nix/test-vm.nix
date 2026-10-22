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
  # `ghostty-demo`: what the README screenshot shows. Kitty graphics
  # (images via timg), the 16-color palette, 24-bit color and text styles.
  demo = pkgs.writeShellScriptBin "ghostty-demo" ''
    clear
    printf '\e[1mGhostty\e[0m on the bare Linux console: \e[3mno compositor, no display server\e[0m\n'
    printf '%s on %s, %s\n\n' \
      "$(cat /sys/class/drm/card0-*/modes 2>/dev/null | head -1)" "$(uname -sr)" "$(uname -m)"

    # Images through the Kitty graphics protocol.
    ${pkgs.timg}/bin/timg -pk -g 48x14 --grid=2 \
      ${ghostty-kms}/share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png \
      ${pkgs.nixos-icons}/share/icons/hicolor/256x256/apps/nix-snowflake.png
    echo

    for i in $(seq 0 15); do printf '\e[48;5;%sm     ' "$i"; done
    printf '\e[0m\n'

    # A 24-bit hue sweep across the full width.
    cols=$(stty size | cut -d' ' -f2)
    for ((i = 0; i < cols; i++)); do
      h=$((i * 360 / cols)); f=$(((h % 60) * 255 / 60))
      case $((h / 60)) in
        0) r=255 g=$f b=0 ;; 1) r=$((255 - f)) g=255 b=0 ;;
        2) r=0 g=255 b=$f ;; 3) r=0 g=$((255 - f)) b=255 ;;
        4) r=$f g=0 b=255 ;; *) r=255 g=0 b=$((255 - f)) ;;
      esac
      printf '\e[48;2;%d;%d;%dm ' "$r" "$g" "$b"
    done
    printf '\e[0m\n\n'

    printf '\e[31mred \e[32mgreen \e[33myellow \e[34mblue \e[35mmagenta \e[36mcyan\e[0m   '
    printf '\e[1mbold\e[0m \e[3mitalic\e[0m \e[4munderline\e[0m \e[9mstrikethrough\e[0m \e[7minverse\e[0m\n\n'
  '';
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
