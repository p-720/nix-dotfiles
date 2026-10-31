{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.dwl;

  # upstream main needs wlroots 0.20; nixpkgs-26.05 dwl is 0.8/0.19
  dwl = (pkgs.dwl.override {
    configH = /etc/nixos/configs/dwl/config.h;
    wlroots_0_19 = pkgs.wlroots_0_20;
  }).overrideAttrs (old: {
    version = "0.10-dev";
    src = /mnt/new/dwl;
    patches = [ ./patches/bar-0.10.patch ];
    buildInputs = old.buildInputs ++ [ pkgs.fcft pkgs.libdrm ];
  });

  # the bar patch reads its right-hand status from dwl's stdin
  statusScript = pkgs.writeShellScript "dwl-status" ''
    runtime="''${XDG_RUNTIME_DIR:-/tmp}"
    weather_file="$runtime/dwl-weather"
    gcal_file="$runtime/dwl-gcal"
    pomo_file="$runtime/dwl-pomo"
    polypomo_file="$runtime/dwl-polypomo"
    tick=0
    while :; do
      vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ 2>/dev/null | awk '{ printf "%d", $2 * 100 }')
      mem=$(free -m | awk '/Mem:/ { printf "%d/%dG", $3/1024, $2/1024 }')
      disk=$(df -h / | awk 'NR==2 { printf "%s", $4 }')
      temp=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -n1)
      [ -n "$temp" ] && temp="$((temp / 1000))°C" || temp=""
      bat=$(cat /sys/class/power_supply/BAT*/capacity 2>/dev/null | head -n1)
      if [ $((tick % 600)) -eq 0 ]; then
        (curl -fsS --max-time 5 'https://wttr.in/Moscow?format=%c%t' > "$weather_file" 2>/dev/null) &
      fi
      if [ $((tick % 300)) -eq 0 ]; then
        (/etc/nixos/configs/waybar/waybar_gcal.sh 2>/dev/null | jq -r '.text // empty' > "$gcal_file") &
      fi
      if [ $((tick % 10)) -eq 0 ]; then
        pomo=$(timeout 1 /etc/nixos/configs/waybar/polybar-pomotask.py 2>/dev/null)
        [ -n "$pomo" ] && printf '%s' "$pomo" > "$pomo_file" || rm -f "$pomo_file"
        (timeout 1 "$HOME/.config/polybar/polypomo" --saveto /etc/nixos/configs/polybar/time.sqlite 2>/dev/null | tail -n1 > "$polypomo_file") &
      fi
      weather=$(cat "$weather_file" 2>/dev/null)
      gcal=$(cat "$gcal_file" 2>/dev/null)
      pomo=$(cat "$pomo_file" 2>/dev/null)
      polypomo=$(cat "$polypomo_file" 2>/dev/null)
      printf '󰍛 %s  󰋊 %s  %s  %s  %s  %s   %s%%  󰥔 %s' "$mem" "$disk" "$gcal" "$weather" "$pomo" "$polypomo" "''${vol:-0}" "$(date '+%a %d %b %H:%M')"
      [ -n "$temp" ] && printf '  󰔏 %s' "$temp"
      [ -n "$bat" ] && printf '  󰁹 %s%%' "$bat"
      printf '\n'
      tick=$((tick + 1))
      sleep 1
    done
  '';

  # -s runs after the Wayland socket exists, so awww/wayland clients work
  autostartScript = pkgs.writeShellScript "dwl-autostart" ''
    awww-daemon &
    sleep 1
    if [ "$(darkman get 2>/dev/null)" = dark ]; then
      awww img /etc/nixos/bg_old.png
    else
      awww img /etc/nixos/light.jpg
    fi
    gammastep -c /home/andrew/.config/gammastep.conf &
    wait
  '';

  dwlWrapped = (pkgs.writeShellScriptBin "dwl" ''
    ${statusScript} | ${dwl}/bin/dwl -s ${autostartScript} "$@"
  '').overrideAttrs (old: {
    meta = (old.meta or { }) // { mainProgram = "dwl"; };
  });
in {
  options.modules.dwl = {
    enable = mkEnableOption "dwl";
  };

  config = mkIf cfg.enable {
    programs.dwl = {
      enable = true;
      package = dwlWrapped;
      extraSessionCommands = ''
        export XDG_CURRENT_DESKTOP=dwl
        export XDG_SESSION_TYPE=wayland
        export MOZ_ENABLE_WAYLAND=1
        export ANKI_WAYLAND=1
        export QT_QPA_PLATFORM=wayland
        export QT_QPA_PLATFORMTHEME=gnome
        export GDK_BACKEND=wayland,x11
        export ELECTRON_OZONE_PLATFORM_HINT=auto
      '';
    };

    # autostart and screenshot/lock binds shell out to these
    environment.systemPackages = with pkgs; [
      awww
      gammastep
      grim
      slurp
      swaylock
      wl-clipboard
      xdg-desktop-portal-wlr
    ];
  };
}
