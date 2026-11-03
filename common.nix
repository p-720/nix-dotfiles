{ config, lib, pkgs, ... }:

{
  imports = lib.my.findAllModulePathsIn /etc/nixos/modules/home-manager;
  modules.pi = {
    enable = true;
    extensions = [
      "npm:pi-caveman"
      "npm:pi-rtk-optimizer"
      "npm:pi-lens"
      "npm:context-mode"
      "npm:pi-ask-user"
      "npm:@sysid/pi-sandbox"
    ];
# https://mcp-nixos.io/usage
  };
  home.packages = [ pkgs.emacsPackages.cask ];

  xdg.desktopEntries = {
    yuzu = {
      name = "Yuzu";
      exec =
        "QT_QPA_PLATFORM=xcb ${pkgs.appimage-run}/bin/appimage-run /home/andrew/.local/share/lutris/runners/yuzu/yuzu-mainline.AppImage";
      genericName = "Yuzu Emulator";
      icon = "net.lutris.Lutris";
      categories = [ "Game" "Emulator" ];
      startupNotify = true;
    };
    OpenGamepadUI = {
      name = "OpenGamepadUI";
      exec =
        "${pkgs.opengamepadui}/share/opengamepadui/opengamepad-ui.x86_64 --fullscreen";
      genericName = "OpenGamepadUI";
      icon = "net.lutris.Lutris";
      categories = [ "Game" "Emulator" ];
      startupNotify = true;
    };

  };
  xsession = {
    enable = true;
    profileExtra = "dbus-update-activation-environment --systemd DISPLAY;";
    #     eval $(/run/wrappers/bin/gnome-keyring-daemon --start --daemonize)
    #     export SSH_AUTH_SOCK
    #   '';
  };
  # services.flameshot.enable = true;
  #  use of undeclared identifier 'wl_proxy_marshal_flags'
  # programs.chromium =
  #   let unstable = import <nixos-unstable> {};
  #   in {
  #     enable = true;
  #     package = (unstable.ungoogled-chromium.mkDerivation (base: rec {
  #       name = "dark-mode-chromium";
  #       patches = [
  #         (pkgs.fetchpatch {
  #           url = "https://raw.githubusercontent.com/PF4Public/gentoo-overlay/84f77f55a09f6ce0523591d7c300bf9deb2a1c01/www-client/ungoogled-chromium/files/gtk-fix-prefers-color-scheme-query.diff";
  #           sha256 = "sha256-y0v+ZArCsKVKGYSBChpugvPUmXiwnAxYHkVhAgT/aOk=";
  #         })];
  #     }));
  #   };
  home.pointerCursor = {
    gtk.enable = true;
    package = pkgs.adwaita-icon-theme;
    # x11.enable = true;
    name = "Adwaita";
    size = 10;
  };

  # qt = {
  #   enable = true;
  #   platformTheme = "gnome";
  #   # style = {
  #   #   name = "Adwaita";
  #   # };
  # };

  # gtk = {
  #   enable = true;

  #   # theme = {
  #   #   package = pkgs.gnome-themes-extra;
  #   #   name = "Adwaita";
  #   # };

  #   # iconTheme = {
  #   #   name = "Obsidian";
  #   #   package = pkgs.iconpack-obsidian;
  #   # };

  #   # font = {
  #   #   name = "Roboto";
  #   #   size = 10;
  #   # };
  # };

  xdg.mimeApps = {
    enable = true;
    # use mimeapps application/x-bittorrent
    # to list mimetypes
    defaultApplications = {
      "inode/directory" = "nautilus.desktop";
      "x-directory/normal" = "nautilus.desktop";
      "text/plain" = "org.gnome.gedit.desktop";
      "application/x-wine-extension-ini" = "org.gnome.gedit.desktop";
      "application/pdf" = "org.gnome.Evince.desktop";
      "application/x-extension-osz" = "osu!.desktop";
      "application/zip" = "osu!.desktop";
      "application/x-extension-osk" = "osu!.desktop";
      "application/x-extension-osb" = "osu!.desktop";
      "application/x-extension-osu" = "osu!.desktop";
      "application/x-osu-beatmap-archive" = "osu!.desktop";
      "application/x-osu-skin-archive" = "osu!.desktop";
      "application/x-bittorrent" = "org.qbittorrent.qBittorrent.desktop";
      # "image/jpeg" = "feh.desktop";
      "image/bmp" = "org.gnome.eog.desktop";
      "image/gif" = "org.gnome.eog.desktop";
      "image/jpeg" = "org.gnome.eog.desktop";
      "image/jpg" = "org.gnome.eog.desktop";
      "image/pjpeg" = "org.gnome.eog.desktop";
      "image/png" = "org.gnome.eog.desktop";
      "image/tiff" = "org.gnome.eog.desktop";
      "image/webp" = "org.gnome.eog.desktop";
      "image/x-bmp" = "org.gnome.eog.desktop";
      "image/x-pcx" = "org.gnome.eog.desktop";
      "image/x-png" = "org.gnome.eog.desktop";
      "image/x-portable-anymap" = "org.gnome.eog.desktop";
      "image/x-portable-bitmap" = "org.gnome.eog.desktop";
      "image/x-portable-graymap" = "org.gnome.eog.desktop";
      "image/x-portable-pixmap" = "org.gnome.eog.desktop";
      "image/x-tga" = "org.gnome.eog.desktop";
      "image/x-xbitmap" = "org.gnome.eog.desktop";
      "image/heic" = "org.gnome.eog.desktop";
      "x-scheme-handler/http" = "firefox.desktop";
      "x-scheme-handler/https" = "firefox.desktop";
      "x-scheme-handler/chrome" = "firefox.desktop";
      # Handler for custom uri
      "x-scheme-handler/tg" = "org.telegram.desktop.desktop";
      "text/html" = "firefox.desktop";
      "application/x-extension-htm" = "firefox.desktop";
      "application/x-extension-html" = "firefox.desktop";
      "application/x-extension-shtml" = "firefox.desktop";
      "application/xhtml+xml" = "firefox.desktop";
      "application/x-extension-xhtml" = "firefox.desktop";
      "application/x-extension-xht" = "firefox.desktop";
      "x-scheme-handler/sidequest" = "SideQuest.desktop";
      "x-scheme-handler/discord-529050037532098580" =
        "discord-529050037532098580.desktop";

      # OFFICE
      "application/msword" = "onlyoffice-desktopeditors.desktop";

      "application/vnd.openxmlformats-officedocument.wordprocessingml.document" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.wordprocessingml.template" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-word.document.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-word.template.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";

      "application/vnd.ms-excel" = "onlyoffice-desktopeditors.desktop";

      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.spreadsheetml.template" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-excel.sheet.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-excel.template.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-excel.addin.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-excel.sheet.binary.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";

      "application/vnd.ms-powerpoint" = "onlyoffice-desktopeditors.desktop";

      "application/vnd.openxmlformats-officedocument.presentationml.presentation" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.presentationml.template" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.openxmlformats-officedocument.presentationml.slideshow" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-powerpoint.addin.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-powerpoint.presentation.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-powerpoint.template.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";
      "application/vnd.ms-powerpoint.slideshow.macroEnabled.12" =
        "onlyoffice-desktopeditors.desktop";

      "application/vnd.ms-access" = "onlyoffice-desktopeditors.desktop";
    };
  };

  # home.file."${config.xdg.dataHome}/mimeapps.list".force = true;

  programs.git = {
    enable = true;
    userName = "patriot720";
    lfs.enable = true;
    userEmail = "cerkin-3@yandex.ru";
    extraConfig = {
      safe.directory = "*";
      core.autocrlf = false;
      core.trustctime = false;
      url = { "git@github.com:" = { insteadOf = "https://github.com/"; }; };
    };
    aliases = { coa = "!git add -A && git commit -m"; };
  };
  services.xsettingsd = { enable = true; };
  modules.shell.fish.enable = true;
  modules.gimp3-photoshop-shortcuts.enable = true;
  # modules.eww.enable = true;
  # modules.firefox.enable = true;
  programs.bash = {
    enable = true;
    initExtra = "\n      set -o vi;\n      ";
  };

  xdg.portal = {
    enable = true;
    xdgOpenUsePortal = true;
    extraPortals = [
      pkgs.xdg-desktop-portal-gtk
      # pkgs.kdePackages.xdg-desktop-portal-kde
      # pkgs.my.luminous
    ];
    config.common = {
      # This is the magic line: it forces the portal to use darkman for settings
      default = "*";
      "org.freedesktop.impl.portal.Settings" = [ "darkman" ];
      "org.freedesktop.impl.portal.Desktop" = [ "gtk" ];
    };
  };
  # xdg.portal.config.common.default = "*";
  # xdg.portal.config.common.org.freedesktop.impl.portal.InputCapture = "luminous;gtk";

  xdg.userDirs = { enable = true; };
  services.gnome-keyring.enable = true;
  services.lorri.enable = true;
  manual.json.enable = true;

  # systemd.user.services.kdeconnect = {
  #   Unit = {
  #     After = lib.mkForce [ "default.target" ];
  #     PartOf = lib.mkForce [ "default.target" ];
  #   };
  #   Service = {
  #     Environment = lib.mkForce ["QT_QPA_PLATFORM=wayland" "PATH=${config.home.profileDirectory}/bin"];
  #   };
  # };
  # nixpkgs.config.allowUnfree = true;
  # nixpkgs.config.allowBroken = true;
  programs.alacritty = {
    enable = true;
    settings = { window.opacity = 0.7; };
  };
  dconf.settings = {
    "org/gnome/desktop/interface" = {
      monospace-font-name = "Noto Sans Mono 10";
      font-name = "Noto Sans 10";
    };
  };

  home.stateVersion = "22.11";

  # services.blueman-applet.enable = true;
  home.keyboard = null;
  home.sessionPath = [ "/etc/nixos/bin" ];
  programs = {
    direnv = {
      enable = true;
      nix-direnv.enable = true;
    };
  };
  xdg.configFile."direnv/direnvrc" = {
    text = ''
      : "''${XDG_CACHE_HOME:="''${HOME}/.cache"}"
      declare -A direnv_layout_dirs
      direnv_layout_dir() {
          local hash path
          echo "''${direnv_layout_dirs[$PWD]:=$(
              hash="$(sha1sum - <<< "$PWD" | head -c40)"
              path="''${PWD//[^a-zA-Z0-9]/-}"
              echo "''${XDG_CACHE_HOME}/direnv/layouts/''${hash}''${path}"
                                             )}"
      }
    '';
  };

  home.file = {
    # ".config/GIMP" = {
    #   source = ./configs/GIMP;
    #   recursive = true;
    # };

    ".npmrc".text = "prefix = \${HOME}/.npm-packages";

    # telegram-desktop audio problems fix tdesktop
    ".alsoftrc".text = "drivers=pulse";

    ".config/dunst" = {
      source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/dunst;
    };

    ".config/minidlna.conf".text = ''
      network_interface=enp3s0
      friendly_name=Pepega Server
      inotify=yes
      media_dir=/mnt/md127/Downloads/stuff
    '';

    ".config/albert" = {
      source = ./configs/albert;
      recursive = true;
    };

    ".config/foot".source =
      config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/foot;

    ".config/psiphon" = {
      source = ./configs/psiphon;
      recursive = true;
    };

    # ".config/qt5ct" = {
    #   source = ./configs/qt5ct;
    #   recursive = true;
    # };
    ".config/mpv".source =
      config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/mpv;
    ".config/flameshot/flameshot.ini".source =
      config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/flameshot.ini;

    ".config/slop" = {
      source = ./configs/slop;
      recursive = true;
    };

    ".config/swappy" = {
      source = ./configs/swappy;
      recursive = true;
    };

    ".config/yay" = {
      source = ./configs/yay;
      recursive = true;
    };

    ".config/sway" = {
      source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/sway;
    };

    ".ideavimrc" = { source = ./configs/ideavim/.ideavimrc; };

    ".intellimacs" = {
      # submodule is not in the flake source; link the live checkout
      source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/ideavim/.intellimacs;
    };
    ".config/uair".source =
      config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/uair;
    ".config/redshift.conf" = {
      source =
        config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/redshift.conf;
    };
    ".config/gammastep.conf" = {
      source =
        config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/gammastep.conf;
    };

    ".config/picom/picom.conf" = {
      source =
        config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/picom/picom.conf;
    };

    # ".tmux.conf" = {
    #   source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/tmux/tmux.conf;
    # };

    ".local/share/nautilus" = {
      source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/nautilus;
    };

    ".local/share/nautilus-python" = {
      source =
        config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/nautilus-python;
    };

    ".local/share/nemo" = {
      source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/nemo;
    };

  };
}
