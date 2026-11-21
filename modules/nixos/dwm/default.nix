{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.dwm;

  # nixpkgs picom has none of the animation/transparency options configs/picom relies on
  picomPijulius = pkgs.unstable.picom-pijulius;

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
      ./patches/dragmfact.diff
      ./patches/parkorder.diff
      ./patches/classcache.diff
      # last: its context lines only exist after anybar rewrites bh/updategeom
      ./patches/permonitorstart.diff
      ./patches/movedrag.diff
    ];
  };
in {
  options.modules.dwm = {
    enable = mkEnableOption "dwm";
  };

  config = mkIf cfg.enable {
    modules.taffybar.enable = mkDefault true;


    # SDDM's greeter starts before the session xrandr layout; keep its login on DP-1
    services.xserver.displayManager.setupCommands =
      lib.optionalString (config.services.displayManager.defaultSession == "none+dwm") ''
        ${pkgs.xorg.xrandr}/bin/xrandr --output DP-1 --primary --mode 2560x1080 --pos 0x0 2>/dev/null || true
        ${pkgs.xorg.xrandr}/bin/xrandr --output HDMI-1 --off 2>/dev/null || true
      '';

    services.xserver.windowManager.dwm = {
      enable = true;
      package = dwm;
      extraSessionCommands = ''
        ${pkgs.xorg.xsetroot}/bin/xsetroot -cursor_name left_ptr
        ${pkgs.xorg.xset}/bin/xset s off
        # NOTE xset dpms only counts raw input, so it blanks mid-video. Keep the
        # server timers at 0 (DPMS stays enabled or force off returns BadMatch)
        # and let xidlehook blank, since it can see audio and fullscreen windows.
        ${pkgs.xorg.xset}/bin/xset dpms 0 0 0
        (while xset q >/dev/null 2>&1; do ${pkgs.procps}/bin/pgrep -x xidlehook >/dev/null || ${pkgs.xidlehook}/bin/xidlehook --detect-sleep --not-when-audio --not-when-fullscreen \
          --timer 180 '${pkgs.xorg.xset}/bin/xset dpms force off' '${pkgs.xorg.xset}/bin/xset dpms force on'; sleep 2; done) &
        # same explicit layout switch i3 used; fcitx5 can otherwise leave it stale
        ${pkgs.xorg.setxkbmap}/bin/setxkbmap us,ru -option 'grp:alt_shift_toggle'
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
        # dwm composites nothing itself; without picom there are no shadows, rounded
        # corners or transparency. Loop so a crash comes back while the X session lives;
        # the pgrep guard keeps us from stacking a second compositor if something else
        # (a manual picom, or an xdg autostart entry) won the race - picom refuses a
        # second CM registration and would otherwise retry every 2s forever.
        (while xset q >/dev/null 2>&1; do ${pkgs.procps}/bin/pgrep -x picom >/dev/null || ${picomPijulius}/bin/picom; sleep 2; done) &
        # dyre recompiles taffybar.hs on change and shells out to ghc; that
        # env's bin must precede PATH but must not leak into the rest of the
        # session (it also ships a taffybar of its own)
        # barEnv is spliced as bare assignments: without a UTF-8 locale the
        # emoji the bar draws come out empty.
        (while xset q >/dev/null 2>&1; do PATH=${config.modules.taffybar.ghcEnv}/bin:$PATH ${config.modules.taffybar.barEnv} ${pkgs.taffybar}/bin/taffybar; sleep 2; done) &
      '';
    };

    environment.systemPackages = with pkgs; [
      feh
      gammastep
      i3lock
      picomPijulius
    ];
  };
}
