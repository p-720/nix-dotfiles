{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.dwm;

  dwm = pkgs.dwm.override {
    conf = /etc/nixos/configs/dwm/config.h;
    patches = [
      ./patches/ewmhtags.diff
      ./patches/focusdesktop.diff
      ./patches/fakefullscreen.diff
      ./patches/overlay.diff
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
      export __GLX_VENDOR_LIBRARY_NAME=mesa
      export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
      export GALLIUM_DRIVER=llvmpipe
      export __EGL_VENDOR_LIBRARY_FILENAMES=/run/opengl-driver/share/glvnd/egl_vendor.d/50_mesa.json
      export VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json
      export VK_DRIVER_FILES=/run/opengl-driver/share/vulkan/icd.d/lvp_icd.x86_64.json
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
        # same explicit layout switch i3 used; fcitx5 can otherwise leave it stale
        ${pkgs.xorg.setxkbmap}/bin/setxkbmap us,ru -option 'grp:alt_shift_toggle'
        ${pkgs.dunst}/bin/dunst &
        ${pkgs.gammastep}/bin/gammastep -c /home/andrew/.config/gammastep.conf &
        # output names differ between nvidia and modesetting; find them by mode
        left=""
        right=""
        for i in $(seq 1 20); do
          ${pkgs.xorg.xrandr}/bin/xrandr --auto 2>/dev/null || true
          left=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gawk}/bin/awk '$2 == "connected" && $0 ~ /2560x1080/ { print $1; exit }')
          right=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gawk}/bin/awk -v l="$left" '$2 == "connected" && $1 != l { print $1; exit }')
          [ -n "$left" ] && [ -n "$right" ] && break
          sleep 0.25
        done
        [ -n "$left" ] || left=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gawk}/bin/awk '$2 == "connected" { print $1; exit }')
        [ -n "$right" ] || right=$(${pkgs.xorg.xrandr}/bin/xrandr --query | ${pkgs.gawk}/bin/awk -v l="$left" '$2 == "connected" && $1 != l { print $1; exit }')
        [ -n "$left" ] && ${pkgs.xorg.xrandr}/bin/xrandr --output "$left" --primary --mode 2560x1080 --pos 0x0 2>/dev/null || true
        [ -n "$right" ] && ${pkgs.xorg.xrandr}/bin/xrandr --output "$right" --mode 1920x1080 --pos 2560x0 2>/dev/null || true
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
