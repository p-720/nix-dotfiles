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
      ./patches/attachbottom.diff
    ];
  };
in {
  options.modules.dwm = {
    enable = mkEnableOption "dwm";
  };

  config = mkIf cfg.enable {
    modules.taffybar.enable = mkDefault true;

    # X11 only: Wayland/Hyprland keeps hardware GL
    services.xserver.displayManager.sessionCommands = ''
      export LIBGL_ALWAYS_SOFTWARE=1
    '';

    # SDDM's greeter starts before the session xrandr layout; keep its login on DP-1
    services.xserver.displayManager.setupCommands = ''
      ${pkgs.xorg.xrandr}/bin/xrandr --output DP-1 --primary --mode 2560x1080 --pos 0x0 2>/dev/null || true
      ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-1 --off 2>/dev/null || true
    '';

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
        # HDMI-1 can enumerate without modes until its EDID is re-read; force it on
        # before laying out the screen, otherwise feh/taffybar see one monitor
        for i in $(seq 1 20); do
          ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-1 --auto 2>/dev/null || true
          monitors=$(${pkgs.xorg.xrandr}/bin/xrandr --listmonitors | ${pkgs.gawk}/bin/awk 'NR == 1 { print $2 }')
          [ "${monitors:-1}" -ge 2 ] && break
          sleep 0.25
        done
        ${pkgs.xorg.xrandr}/bin/xrandr --output DP-1 --mode 2560x1080 --pos 0x0 --primary 2>/dev/null || true
        ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-1 --mode 1920x1080 --pos 2560x0 2>/dev/null || true
        ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-2 --mode 1800x1080 --pos 4480x0 2>/dev/null || true
        sleep 1
        if [ "$(darkman get 2>/dev/null)" = dark ]; then
          ${pkgs.feh}/bin/feh --bg-fill --geometry +0+0 /etc/nixos/bg_old.png /etc/nixos/bg_old.png /etc/nixos/bg_old.png
        else
          ${pkgs.feh}/bin/feh --bg-fill --geometry +0+0 /etc/nixos/light.jpg /etc/nixos/light.jpg /etc/nixos/light.jpg
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
