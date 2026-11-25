{ config, lib,inputs, pkgs, ... }:

with lib;
let cfg = config.modules.hypr;
in {
  options.modules.hypr = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
    settingsFile = mkOption {
      type = types.str;
      default = "/etc/nixos/configs/hypr/lua/hyprland.lua";
    };
  };
  config = mkIf cfg.enable (lib.my.withHome
    (args:{
      wayland.windowManager.hyprland  = {
        enable = true;
        # package = pkgs.hyprland;
        # package = inputs.hyprland.packages.x86_64-linux.hyprland;
        # package
        package = pkgs.hyprland;
        # portalPackage = pkgs.unstable.xdg-desktop-portal-hyprland;
        plugins = [
          # pkgs.hyprold.hyprlandPlugins.hy3
          # pkgs.hyprlandPlugins.hyprgrass

          # pkgs.hyprlandPlugins.hypr-darkwindow
          # (pkgs.unstable.hyprlandPlugins.hypr-darkwindow.overrideAttrs(oldAttrs: rec {
          #   patches = [
          #     /etc/nixos/modules/nixos/hypr/eldata.patch
          #     # /etc/nixos/modules/nixos/hypr/noblur.patch
          #     # /etc/nixos/modules/nixos/hypr/tearing.patch
          #   ];
          # }))

          # eldata.patch is upstream since v0.56 (m_passElements holds values,
          # not pointers) -> patching would just fail to apply.
          pkgs.my.hypr-darkwindow
          # (pkgs.my.hypr-darkwindow.overrideAttrs(oldAttrs: rec {
          #   patches = [
          #     /etc/nixos/modules/nixos/hypr/eldata.patch
          #     # /etc/nixos/modules/nixos/hypr/noblur.patch
          #     # /etc/nixos/modules/nixos/hypr/tearing.patch
          #   ];
          # }))
 
          # pkgs.my.hypr-darkwindow
          # inputs.hypr-darkwindow.packages.x86_64-linux.Hypr-DarkWindow
          # inputs.hy3.packages.x86_64-linux.hy3
        ];
        systemd.enable = true;
        xwayland.enable = true;
        # withUWSM = true;
        systemd.variables = [
          "--all"
        ];
        configType = "lua";
        extraConfig = ''
          package.path = "/etc/nixos/configs/hypr/lua/?.lua;/etc/nixos/configs/hypr/lua/?/init.lua;" .. package.path
          require("hyprland")
        '';
      };

      systemd.user.services.awww = {
        Install = { WantedBy = [ "graphical-session.target" ]; };

        Unit = {
          ConditionEnvironment = "WAYLAND_DISPLAY";
          Description = "awww wallpaper daemon";
          After = [ "graphical-session-pre.target" ];
          PartOf = [ "graphical-session.target" ];
        };

        Service = {
          ExecStart = "${pkgs.awww}/bin/awww-daemon";
          Restart = "always";
          RestartSec = "10";
        };
      };

      home.file = {
        ".config/hypr/hypridle.conf".source = args.config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/hypr/hypridle.conf;
        ".config/hypr/hyprlock.conf".source = args.config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/hyprlock/hyprlock.conf;
      };

      # services.hyprpaper = {
      #   enable = true;
      #   package = pkgs.unstable.hyprpaper;
      #   settings = {
      #     ipc = "on";
      #     preload = [ "/etc/nixos/light.jpg" "/etc/nixos/bg_old.png"];
      #   };
      # };
      #       home.file = {
      # ".config/hypr/hyprpaper.conf".source = args.config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/hypr/hyprpaper.conf;
      # };
    })
    {
      programs.hyprland = {
        enable = true;
        xwayland.enable = true;
      };
      programs.hyprlock.enable = true;
      environment.variables = {
        qt_qpa_PLATFORM = "wayland";
        ANKI_WAYLAND = 1;
      };
      services.hypridle.enable = true;
      
      # xdg.portal = {
      #   enable = true;
      #   config.common.default = "*";
      #   extraPortals = [
      #     pkgs.xdg-desktop-portal-hyprland
      #   ];
      # };
      # programs.waybar = {
      #   enable = false;
      #  package = 
      # };

      environment.systemPackages = with pkgs;
        [
          gammastep
          my.waybar
          awww
          # hyprwall
          grim # screenshot functionality
          slurp # screenshot functionality
          wl-clipboard # wl-copy and wl-paste for copy/paste from stdin / stdout
          wf-recorder
          # unstable.waybar
          
        ];
    }) ;
}
