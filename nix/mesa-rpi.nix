# A Mesa trimmed to the Raspberry Pi's drivers, for a Pi system's
# `hardware.graphics.package`: vc4 (display), v3d (GPU), zink and the
# V3DV Vulkan driver, no software rasterizer and no LLVM. ghostty-kms
# presents with v3d and renders through zink on its own, since V3D's
# GL driver lacks desktop GL 4.3 (and vertex-stage storage buffers).
# The default nixpkgs Mesa works too; this one is just much smaller.
{
  lib,
  pkgs,
}: let
  slim = import ./slim-deps.nix {inherit lib pkgs;};
in
  (pkgs.mesa.override {
    galliumDrivers = ["vc4" "v3d" "zink"];
    vulkanDrivers = ["broadcom"];
    vulkanLayers = [];
    eglPlatforms = [];
    withValgrind = false;
    enablePatentEncumberedCodecs = false;
    # The same libdrm/libgbm as ghostty-kms (no libdrm_intel, so no
    # hwdata, and one copy of each).
    inherit (slim) libdrm libgbm;
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
  })
