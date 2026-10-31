{ config, lib, pkgs, ... }:

with lib;
with lib.my;
let cfg = config.modules.xmonad;
in {
  options.modules.xmonad = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      Enable xmonad with configs
      '';
    };
  };
  # NOTE parens matter: `mkIf en {...} // x` drops x (mkIf wraps the whole
  # attrset and swallows merged siblings); `mkIf en ({...} // x)` keeps it
  config = mkIf cfg.enable ({
    services.xserver = {
      windowManager.xmonad = {
        enable = true;
        enableContribAndExtras = true;
      };
      displayManager = {
        # common.nix defines defaultSession ("hyprland") for every host;
        # mkForce or the two definitions conflict
        defaultSession = mkForce "none+xmonad";
      };
    };
  } // (my.allUsers ({ config, ... }: {
    home.file = {
      ".xmonad/lib".source =
        config.lib.file.mkOutOfStoreSymlink /etc/nixos/modules/nixos/xmonad/lib;

      ".xmonad/xmonad.hs" = {
        source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/modules/nixos/xmonad/xmonad.hs;
      };
    };
  })));
}
