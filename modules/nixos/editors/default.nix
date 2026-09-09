{ config, lib, pkgs, ... }:

with lib;
with lib.my;
let cfg = config.modules.emacs-with-doom;
in{
  options.modules.emacs-with-doom = {
    enable = mkBoolOpt false;
    package = mkOpt types.package (pkgs.emacs);
    doom = {
      enable = mkBoolOpt true;
      forgeUrl = mkOpt types.str "https://github.com";
      repoUrl = mkOpt types.str "${cfg.doom.forgeUrl}/doomemacs/doomemacs";
      configRepoUrl = mkOpt types.str "${cfg.doom.forgeUrl}/p-720/.doom.d";
    };
  };
  config = mkIf cfg.enable (lib.my.withHome
    ({config,...}: {
      home.file = {
        ".doom.d".source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/modules/nixos/editors/.doom.d; # TODO resolve relative paths
      };})
    {
      # nixpkgs.overlays = [
      #   (import (builtins.fetchTarball {
      #     url =
      #       "https://github.com/nix-community/emacs-overlay/archive/master.tar.gz";
      #     sha256 = "0n8836xwcs6wckaszikzsxbvzsn34livcm3qc4rkrb0ndr5cp4jn";
      #   }))
      # ];
      services.emacs.install = true;
      services.emacs.enable = true;
      services.emacs.defaultEditor = true;
      # services.emacs.package = pkgs.emacs-unstable.override {
      #   withGTK3 = true;
      # };
      services.emacs.package = cfg.package;
#      system.userActivationScripts = mkIf cfg.doom.enable {
#        installDoomEmacs = ''
#        if [ ! -d "$HOME/.emacs.d" ]; then
#           ${pkgs.git} clone --depth=1 --single-branch "${cfg.doom.repoUrl}" "$HOME/.emacs.d"
#           ${pkgs.git} clone "${cfg.doom.configRepoUrl}" "$HOME/.doom.d"
#        fi
#      '';
#      };
    });

}
