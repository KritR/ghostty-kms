# Test guest for `programs.ghostty-kms.console`: the same guest as
# test-vm.nix, but instead of autologin + launching ghostty from a shell,
# Ghostty *is* the login console on tty1 and tty2 (tty3 keeps getty), and
# tty4's Ghostty is replaced by a command that always fails, to exercise the
# fallback to getty.
# Logs reach the serial console through journald. See tests/qemu/e2e-console.sh.
{
  lib,
  pkgs,
  ...
}: let
  serial =
    if pkgs.stdenv.hostPlatform.isAarch64
    then "ttyAMA0"
    else "ttyS0";
in {
  imports = [./test-vm.nix];

  # Undo test-vm.nix's autologin session.
  services.getty.autologinUser = lib.mkForce null;
  programs.bash.loginShellInit = lib.mkForce "";
  users.users.test.password = lib.mkForce "test";

  programs.ghostty-kms.console = {
    enable = true;
    ttys = ["tty1" "tty2" "tty4"];
    settings = {
      font-size = 14;
      window-padding-x = 4;
      window-padding-y = 4;
      shell-integration = "none";
    };
  };

  # Simulate Ghostty failing to start on tty4 (e.g. a broken GPU driver).
  systemd.services."autovt@tty4".serviceConfig.ExecStart = lib.mkForce "${pkgs.coreutils}/bin/false";

  # Everything in the journal (including Ghostty's log) to the serial port.
  services.journald.console = "/dev/${serial}";
  services.journald.extraConfig = "MaxLevelConsole=info";
}
