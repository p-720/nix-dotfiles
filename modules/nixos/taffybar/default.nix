{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.taffybar;
in {
  options.modules.taffybar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
    # ghc for dyre's runtime recompile of taffybar.hs. Its bin also contains a
    # taffybar binary and other packages' tools, so it must stay off the system
    # PATH and only wrap the bar launch.
    ghcEnv = mkOption {
      type = types.package;
      readOnly = true;
      default = pkgs.callPackage ./ghc-env.nix { };
      description = "GHC with the packages taffybar.hs imports, for dyre";
    };
  };
  # NOTE parens matter: `mkIf en {...} // x` drops x (mkIf wraps the whole
  # attrset and swallows merged siblings); `mkIf en ({...} // x)` keeps it
  config = mkIf cfg.enable ({
    systemd.user.services.gtk-sni-tray = {
      enable = true;
      description = "Gtk sni tray";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart =
          "${pkgs.haskellPackages.status-notifier-item}/bin/status-notifier-watcher";
      };
    };
    # not home.packages: home-manager's home-path is not on PATH here
    # status-notifier-item puts status-notifier-watcher on PATH for the
    # xmonad startup hook (taffybar's SNI tray needs a watcher)
    environment.systemPackages = [ pkgs.taffybar pkgs.haskellPackages.status-notifier-item ];
  } // (my.allUsers ({ config, ... }: {
    # out-of-store links: taffybar recompiles its config while running, and a
    # home.file source copy would freeze it at build time
    home.file = {
      ".config/taffybar/taffybar.css".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/taffybar.css";
      ".config/taffybar/gotham.css".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/gotham.css";
      ".config/taffybar/taffybar.hs".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/taffybar.hs";
    };
  })));
}
