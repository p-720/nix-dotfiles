{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.sunshine;
in {
  options.modules.sunshine = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
  };
  config = mkIf cfg.enable {
    programs.opengamepadui.enable = true;
    programs.opengamepadui.args = "--fullscreen";
    # programs.opengamepadui.gamescopeSession.enable = true;
    programs.opengamepadui.extraPackages = [ pkgs.vulkan-tools pkgs.hwdata ];
    services.sunshine.enable = true;
    services.sunshine.capSysAdmin = true;
    services.sunshine.package = pkgs.sunshine;
    services.sunshine.autoStart = true;
    # services.sunshine.openFirewall = true;
    services.sunshine.settings = {
      upnp = "enabled";
      output_name = 2;
      capture = "kms";
      encoder = "nvenc";
      # nvenc_twopass = "disabled";
      # min_log_level = "Debug";
    };
    hardware.uinput.enable = true;

    systemd.services.sunshine-touch-remap = {
      description = "Sunshine Touch Coordinate Remapper";
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        ExecStart = "${pkgs.python3.withPackages (ps: [ ps.evdev ])}/bin/python3 /etc/nixos/modules/nixos/sunshine/remap.py";
        Restart = "always";
        RestartSec = "2s";
        User = "root";
      };
    };

    services.sunshine.applications = {
      # env = {
      #   PATH = "\${PATH}:\${HOME}/.local/bin";
      # };
      apps = let
        # each of these is a real script on disk — sunshine never sees a quote
        wsFocus = n: pkgs.writeShellScript "hypr-focus-ws-${toString n}" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.focus({ workspace = ${toString n} })"
  '';

        dpms = monitor: action: pkgs.writeShellScript "hypr-dpms-${monitor}-${action}" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.dpms({ action = \"${action}\", monitor = \"${monitor}\" })"
  '';

        pkill = name: pkgs.writeShellScript "hypr-pkill-${name}" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.exec_cmd(\"pkill ${name}\")"
  '';

        yuzu = pkgs.writeShellScript "launch-yuzu" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.exec_cmd(\"env QT_QPA_PLATFORM=xcb ${pkgs.appimage-run}/bin/appimage-run /home/andrew/.local/share/lutris/runners/yuzu/yuzu-mainline.AppImage\")"
  '';

        steamBigPicture = pkgs.writeShellScript "launch-steam-bp" ''
    exec ${pkgs.hyprland}/bin/hyprctl dispatch "hl.dsp.exec_cmd(\"steam steam://open/bigpicture\")"
  '';
      in
        [
          {
            name = "OpenGamepadUI";
            cmd = "${pkgs.opengamepadui}/share/opengamepadui/opengamepad-ui.x86_64 --fullscreen";
            prep-cmd = [ { do = "${wsFocus 13}"; } ];
            exclude-global-prep-cmd = "false";
            auto-detach = "true";
          }
          {
            name = "Yuzu";
            cmd = "${yuzu}";
            prep-cmd = [ { do = "${wsFocus 13}"; } ];
            exclude-global-prep-cmd = "false";
            auto-detach = "true";
          }
          {
            name = "All Monitors Desktop";
            image-path = "/etc/nixos/pkgs/sunshine/desktop-multiple.png";
            exclude-global-prep-cmd = "false";
            prep-cmd = [ { do = "${wsFocus 13}"; } ];
            auto-detach = "true";
          }
          {
            name = "Desktop";
            image-path = "desktop.png";
            exclude-global-prep-cmd = "false";
            prep-cmd = [
              { do = "${wsFocus 13}"; }
              { do = "${dpms "DP-3" "disable"}"; undo = "${dpms "DP-3" "enable"}"; }
              { do = "${dpms "HDMI-A-1" "disable"}"; undo = "${dpms "HDMI-A-1" "enable"}"; }
              # { do = "${pkill "emacs"}"; }
              # { do = "${pkill "zen"}"; }
              # { do = "${pkill "telegram"}"; }
            ];
            auto-detach = "true";
          }
          {
            name = "Steam Big Picture";
            cmd = "${steamBigPicture}";
            prep-cmd = [ { do = "${wsFocus 13}"; } ];
            image-path = "steam.png";
            exclude-global-prep-cmd = "false";
            auto-detach = "true";
          }
        ];
    };
  };
}

