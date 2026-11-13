{
  config,
  lib,
  ...
}:

with lib;
let
  cfg = config.modules.software-gl;

  # 3090 stays free for Strata compute; the CPU (llvmpipe) draws the X11 session.
  # The NVIDIA driver still owns the screen, only app rendering moves off the card.
  llvmpipeEnv = ''
    export LIBGL_ALWAYS_SOFTWARE=1
    export __GLX_VENDOR_LIBRARY_NAME=mesa
    export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
    export GALLIUM_DRIVER=llvmpipe
    export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json
    export VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json
    export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json
  '';
in
{
  options.modules.software-gl = {
    enable = mkEnableOption "llvmpipe software rendering for X11 sessions, freeing the GPU";

    disableComposite = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Disable the X Composite extension. Kills every compositor: picom exits with
        "The X server doesn't have the X Composite extension".
      '';
    };
  };

  config = mkMerge [
    (mkIf cfg.enable {
      services.xserver.displayManager.sessionCommands = llvmpipeEnv;
      # startx has no display manager, so sessionCommands never runs there
      services.xserver.displayManager.startx.extraCommands = llvmpipeEnv;
    })
    (mkIf cfg.disableComposite {
      services.xserver.extraConfig = ''
        Section "Extensions"
          Option "Composite" "Disable"
        EndSection
      '';
    })
  ];
}
