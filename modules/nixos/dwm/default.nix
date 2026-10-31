{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.dwm;

  dwm = pkgs.dwm.override {
    conf = /etc/nixos/configs/dwm/config.h;
    patches = [
      ./patches/ewmhtags.diff
      ./patches/anybar.diff
      ./patches/altbarfit.diff
      ./patches/noborder.diff
      ./patches/ewmhclick.diff
      ./patches/nobardrw.diff
    ];
  };
in {
  options.modules.dwm = {
    enable = mkEnableOption "dwm";
  };

  config = mkIf cfg.enable {
    modules.taffybar.enable = mkDefault true;

    services.xserver.windowManager.dwm = {
      enable = true;
      package = dwm;
      extraSessionCommands = ''
        ${pkgs.xorg.xsetroot}/bin/xsetroot -cursor_name left_ptr
        ${pkgs.xorg.xset}/bin/xset s off
        ${pkgs.xorg.xset}/bin/xset dpms 0 0 180
        ${pkgs.picom}/bin/picom --daemon
        ${pkgs.dunst}/bin/dunst &
        ${pkgs.gammastep}/bin/gammastep -c /home/andrew/.config/gammastep.conf &
        if [ "$(darkman get 2>/dev/null)" = dark ]; then
          ${pkgs.feh}/bin/feh --bg-fill /etc/nixos/bg_old.png
        else
          ${pkgs.feh}/bin/feh --bg-fill /etc/nixos/light.jpg
        fi
        (rm -f ~/.cache/status-notifier-item/*.json; status-notifier-watcher) &
        (while xset q >/dev/null 2>&1; do taffybar; sleep 2; done) &
      '';
    };

    environment.systemPackages = with pkgs; [
      dunst
      feh
      gammastep
      i3lock
      picom
    ];
  };
}
