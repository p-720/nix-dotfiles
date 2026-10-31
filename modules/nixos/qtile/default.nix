{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.qtile;

  # nixos-26.05 still pins qtile 0.36; the flake's unstable input has 0.37.1
  # lib.makeOverridable keeps .override, which the NixOS module needs for
  # extraPackages; plain overridePythonAttrs drops it
  qtile = lib.makeOverridable
    (args:
      (pkgs.unstable.python3Packages.qtile.override args).overridePythonAttrs (old: {
        postInstall = (old.postInstall or "") + ''
          cat > $out/share/xsessions/qtile.desktop <<EOF
          [Desktop Entry]
          Name=Qtile
          Comment=Qtile on X11
          Exec=$out/bin/qtile start -b x11
          Type=Application
          Keywords=wm;tiling
          EOF
          cat > $out/share/wayland-sessions/qtile.desktop <<EOF
          [Desktop Entry]
          Name=Qtile (Wayland)
          Comment=Qtile on Wayland
          Exec=$out/bin/qtile start -b wayland
          Type=Application
          Keywords=wm;tiling
          EOF
        '';
      }))
    { };
in {
  options.modules.qtile = {
    enable = mkEnableOption "qtile";
  };

  config = mkIf cfg.enable {
    services.xserver.windowManager.qtile = {
      enable = true;
      package = qtile;
      configFile = /etc/nixos/configs/qtile/config.py;
      # 0.37.1 collects no tests on python 3.14, so pytest exits 5 and fails the build
      extraPackages = ps: with ps; [
        (qtile-extras.overridePythonAttrs (_: { doCheck = false; }))
      ];
    };

    # taffybar is the X11 bar; Wayland keeps qtile's built-in bar
    modules.taffybar.enable = mkDefault true;

    # autostart/lock in config.py shell out to these (both backends)
    environment.systemPackages = with pkgs; [ awww dunst feh i3lock picom swaylock ];
  };
}
