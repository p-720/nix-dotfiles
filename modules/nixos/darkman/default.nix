{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.darkman;
    darkman = pkgs.darkman.overrideAttrs(oldAttrs: rec {
      postPatch = oldAttrs.postPatch + ''
    sed -i '16a Environment=PATH=/run/current-system/sw/bin' darkman.service'';
    });

    # No compiled gschemas.compiled ends up in the system path (environment.pathsToLink
    # drops share/glib-2.0), so every gsettings call in the session died with
    # "No schemas installed". glib carries a patch that searches this variable as the
    # first schema source; the schemas package keeps the compiled copy under
    # share/gsettings-schemas/<name>.
    schemaDir = "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.pname}-${pkgs.gsettings-desktop-schemas.version}/glib-2.0/schemas";
    gsettings = "${pkgs.glib}/bin/gsettings";

    # one user service serves every session type, so the wallpaper tool is chosen at run
    # time: awww talks to a wayland socket that does not exist under dwm or dwl-on-X11.
    wallpaperScript = image: ''
      if [ -n "''${WAYLAND_DISPLAY:-}" ]; then
        ${pkgs.awww}/bin/awww img ${image} --transition-type center
      elif [ -n "''${DISPLAY:-}" ]; then
        ${pkgs.feh}/bin/feh --bg-fill ${image}
      else
        # lingering can start this service before any session exists; nothing to paint on
        exit 0
      fi
    '';
in {
  options.modules.darkman = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = '';
      '';
    };
  };
  config = mkIf cfg.enable ({

    # reaches the session and, through pam_env, the systemd user manager that runs
    # darkman.service. Without this the scripts below still cannot read their schemas.
    environment.sessionVariables.NIX_GSETTINGS_OVERRIDES_DIR = schemaDir;

  } // (my.allUsers ({...}: {
    services.darkman = {
      enable = true;
      darkModeScripts = {
        gtk-theme = ''
          # 1. Set the color scheme preference (Primary for modern apps/Firefox)
          ${gsettings} set org.gnome.desktop.interface color-scheme 'prefer-dark'
          # 2. Set the legacy theme (For GTK3 apps)
          ${gsettings} set org.gnome.desktop.interface gtk-theme 'Adwaita-dark'
        '';
        wallpaper = wallpaperScript /etc/nixos/bg_old.png;
      };
      lightModeScripts = {
        gtk-theme = ''
          ${gsettings} set org.gnome.desktop.interface color-scheme 'prefer-light'
          ${gsettings} set org.gnome.desktop.interface gtk-theme 'Adwaita'
        '';
        wallpaper = wallpaperScript /etc/nixos/light.jpg;
      };
      settings = {
        lat = 55.7;
        lng = 37.6;
        usegeoclue = false;
      };
    };

    systemd.user.services.darkman = {
      Unit = {
        After = ["awww.service"];
      };
      # pam_env only feeds variables to sessions that go through PAM; a lingered user
      # manager started at boot gets none of them, and this service has to read schemas
      # at that point too.
      serviceConfig.Environment = ["NIX_GSETTINGS_OVERRIDES_DIR=${schemaDir}"];
    };
  })));
}
