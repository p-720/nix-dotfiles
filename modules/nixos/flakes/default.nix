{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.flakes;
in {
  options.modules.flakes = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
  };
  config = mkIf cfg.enable {
    nix = {
      package = pkgs.nixVersions.stable; # or versioned attributes like nixVersions.nix_2_8
      extraOptions = ''
      experimental-features = nix-command flakes
      access-tokens = github.com=${builtins.readFile /home/andrew/Dropbox/github-token}
    '';
    };
  };
}
