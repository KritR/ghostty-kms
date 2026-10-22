# NixOS module.
#
#   programs.ghostty-kms.enable = true;
#     Installs Ghostty with the kms runtime. Run `ghostty` from a VT login;
#     logind (NixOS's default) provides the seat.
#
#   programs.ghostty-kms.console.enable = true;
#     Ghostty *is* the login console on the chosen VTs, in place of getty:
#     each VT shows a login prompt inside Ghostty, and logging out (or the
#     prompt timing out) gives a fresh one, like getty. Other VTs keep getty,
#     and a VT falls back to getty if Ghostty keeps failing to start.
#
# On a Raspberry Pi without system GPU drivers, set
# `package = ghostty-raw-term.packages.aarch64-linux.ghostty-kms-rpi` and
# `hardware.graphics.enable = false` (that package brings its own Mesa).
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.ghostty-kms;
  ccfg = cfg.console;

  # Ghostty config for the console. Lists become repeated keys.
  toGhosttyConfig = settings:
    lib.concatStringsSep "\n" (lib.flatten (lib.mapAttrsToList (k: v:
      map (x: "${k} = ${
        if lib.isBool x
        then lib.boolToString x
        else toString x
      }") (lib.toList v))
    settings))
    + "\n";

  consoleConfig = pkgs.writeText "ghostty-kms-console.conf" (toGhosttyConfig ccfg.settings);

  # `login` wipes its environment before PAM runs unless given -p, and
  # pam_systemd needs XDG_SEAT/XDG_VTNR to put the user's session on this
  # seat and VT. With -p the user would inherit all of the service's
  # environment, so pass just what a getty login has (TERM, locale) plus
  # Ghostty's terminal variables and the seat/VT.
  loginWrapper = pkgs.writeShellScript "ghostty-kms-login" ''
    keep=()
    for v in TERM TERMINFO COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION \
             GHOSTTY_RESOURCES_DIR GHOSTTY_BIN_DIR LANG XDG_SEAT XDG_VTNR; do
      if [ -n "''${!v-}" ]; then keep+=("$v=''${!v}"); fi
    done
    exec ${pkgs.coreutils}/bin/env -i "''${keep[@]}" ${ccfg.loginProgram} -p
  '';

  # Like getty: one login, and Ghostty (hence the unit) exits when it does,
  # so systemd restarts it with a clean screen.
  consoleService = tty: {
    description = "Ghostty console on ${tty}";
    documentation = ["https://github.com/ghostty-org/ghostty"];
    after = [
      "systemd-user-sessions.service"
      "plymouth-quit-wait.service"
      "getty-pre.target"
      "systemd-logind.service"
    ];
    before = ["getty.target"];
    # Don't fight a plain getty on the same VT (e.g. the fallback).
    conflicts = ["rescue.service" "getty@${tty}.service"];
    unitConfig = {
      IgnoreOnIsolate = true;
      ConditionPathExists = "/dev/${tty}";
      # Give up on Ghostty (e.g. after a broken GPU driver update) and hand
      # the VT to a plain getty rather than leaving it without a login.
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
      OnFailure = lib.mkIf ccfg.fallbackToGetty ["getty@${tty}.service"];
    };
    environment =
      {
        # Wait for our VT to be in front, like getty does.
        GHOSTTY_KMS_SEAT_TIMEOUT = "0";
        # Ghostty holds no logind session of its own (see PAMName below), so
        # it takes the DRM/input devices and handles VT switching with
        # libseat's built-in, root-only backend.
        LIBSEAT_BACKEND = "builtin";
        # Inherited by `login`: pam_systemd registers the user's session on
        # this seat and VT, as it would for getty's login.
        XDG_SEAT = "seat0";
        XDG_VTNR = lib.removePrefix "tty" tty;
      }
      // lib.optionalAttrs cfg.softwareRendering {
        LIBGL_ALWAYS_SOFTWARE = "1";
        GHOSTTY_KMS_ALLOW_SOFTWARE = "1";
      }
      // ccfg.environment;
    serviceConfig = {
      ExecStart = lib.escapeShellArgs [
        (lib.getExe cfg.package)
        "--config-default-files=false"
        "--config-file=${consoleConfig}"
        "--command=${loginWrapper}"
      ];
      Type = "idle";
      Restart = "always";
      RestartSec = "1";
      UtmpIdentifier = tty;
      TTYPath = "/dev/${tty}";
      TTYReset = true;
      TTYVHangup = true;
      TTYVTDisallocate = true;
      StandardInput = "tty";
      StandardOutput = "journal";
      StandardError = "journal";
      # No PAMName: if Ghostty held a logind session on the VT, logind would
      # refuse the session `login` opens for the user ("already running in
      # a session", "virtual terminal already occupied"), and users would
      # get no XDG_RUNTIME_DIR, user services or seat device access.
      SendSIGHUP = true;
    };
    restartIfChanged = false;
  };
in {
  options.programs.ghostty-kms = {
    enable = lib.mkEnableOption "Ghostty on the Linux console (DRM/KMS)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.ghostty-kms;
      defaultText = lib.literalExpression "ghostty-raw-term.packages.\${system}.ghostty-kms";
      description = ''
        The ghostty-kms package. Use `ghostty-kms-rpi` on a Raspberry Pi
        without system GPU drivers.
      '';
    };

    softwareRendering = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Render with Mesa's llvmpipe (LIBGL_ALWAYS_SOFTWARE=1) and allow it
        (GHOSTTY_KMS_ALLOW_SOFTWARE=1). Meant for VMs without a GPU; it keeps
        every core busy. Not for the Raspberry Pi: use `ghostty-kms-rpi`.
      '';
    };

    console = {
      enable = lib.mkEnableOption ''
        Ghostty as the login console on {option}`programs.ghostty-kms.console.ttys`,
        replacing getty there'';

      ttys = lib.mkOption {
        type = lib.types.listOf (lib.types.strMatching "tty[0-9]+");
        default = ["tty2" "tty3" "tty4" "tty5" "tty6"];
        example = ["tty1" "tty2"];
        description = ''
          VTs that get Ghostty instead of getty. Like getty, each starts on
          demand when you switch to it (tty1 starts at boot). The default
          leaves tty1 as a plain getty to fall back on; logind only starts
          VTs up to its `NAutoVTs` (6 by default) on demand.
        '';
      };

      settings = lib.mkOption {
        type = with lib.types; attrsOf (oneOf [str int float bool (listOf (oneOf [str int float bool]))]);
        default = {};
        example = {
          font-size = 14;
          theme = "Catppuccin Mocha";
        };
        description = ''
          Ghostty configuration for the console, as `key = value` pairs
          (lists repeat the key). Users' own configs are not read: the
          console starts before anyone logs in.
        '';
      };

      environment = lib.mkOption {
        type = with lib.types; attrsOf str;
        default = {};
        example = {GHOSTTY_KMS_MODE = "1920x1080@60";};
        description = "Extra environment for the console, e.g. GHOSTTY_KMS_* settings.";
      };

      loginProgram = lib.mkOption {
        type = lib.types.path;
        default = config.services.getty.loginProgram;
        defaultText = lib.literalExpression "config.services.getty.loginProgram";
        description = "The program run inside Ghostty to log in.";
      };

      fallbackToGetty = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          If Ghostty fails to start 5 times within a minute on a VT, start a
          plain getty there instead.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      environment.systemPackages = [cfg.package];
      hardware.graphics.enable = lib.mkDefault true;
      environment.sessionVariables = lib.mkIf cfg.softwareRendering {
        LIBGL_ALWAYS_SOFTWARE = "1";
        # ghostty-kms refuses software rasterizers unless told otherwise.
        GHOSTTY_KMS_ALLOW_SOFTWARE = "1";
      };
    }

    (lib.mkIf ccfg.enable {
      # logind starts autovt@ttyN.service when switching to a VT with no
      # session, and getty.target pulls in autovt@tty1. A unit file named
      # for the exact instance takes precedence over the autovt@ (= getty@)
      # template, so these VTs get Ghostty and the rest keep getty.
      systemd.services = lib.listToAttrs (map (tty: lib.nameValuePair "autovt@${tty}" (consoleService tty)) ccfg.ttys);

      assertions = [
        {
          assertion = !(config.services.kmscon.enable or false);
          message = "programs.ghostty-kms.console and services.kmscon both replace getty; enable only one.";
        }
      ];
    })
  ]);
}
