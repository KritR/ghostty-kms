# NixOS module: `programs.ghostty-kms.enable = true;` installs Ghostty with
# the kms runtime and the bits it needs at runtime. Run `ghostty` from a VT
# login; logind (NixOS's default) provides the seat.
self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.ghostty-kms;
in {
  options.programs.ghostty-kms = {
    enable = lib.mkEnableOption "Ghostty on the Linux console (DRM/KMS)";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.ghostty-kms;
      defaultText = lib.literalExpression "ghostty-raw-term.packages.\${system}.ghostty-kms";
      description = "The ghostty-kms package.";
    };

    softwareRendering = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Render with Mesa's llvmpipe (sets LIBGL_ALWAYS_SOFTWARE=1). Needed on
        GPUs without desktop OpenGL 4.3, such as the Raspberry Pi's V3D.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [cfg.package];
    hardware.graphics.enable = true;
    environment.sessionVariables = lib.mkIf cfg.softwareRendering {
      LIBGL_ALWAYS_SOFTWARE = "1";
      # ghostty-kms refuses software rasterizers unless told otherwise.
      GHOSTTY_KMS_ALLOW_SOFTWARE = "1";
    };
  };
}
