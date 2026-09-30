{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.nvidia;
in {
  options.modules.nvidia = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
  };
  config = mkIf cfg.enable {
    environment.etc."nvidia/nvidia-application-profiles-rc.d/50-limit-free-buffer-pool-in-wayland-compositors.json".text = builtins.toJSON {
      rules = [
        { pattern = { feature = "procname"; matches = "Hyprland"; }; profile = "No VidMem Reuse"; }
        { pattern = { feature = "procname"; matches = ".Hyprland-wrapped"; }; profile = "No VidMem Reuse"; }
      ];
      profiles = [
        { name = "No VidMem Reuse"; settings = [ { key = "GLVidHeapReuseRatio"; value = 0; } ]; }
      ];
    };
  };
}

