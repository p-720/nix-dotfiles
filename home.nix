{ config, lib, pkgs, ... }:

let configbase = config;
in {
  specialisation.default = {
    configuration = {
      programs.steam.enable = true;
      # programs.steam.package = pkgs.unstable.steam;
      hardware.opentabletdriver.enable = true;
      # autologin skips password auth so PAM never sees it and the login keyring stays locked
      services.displayManager.autoLogin = {
        enable = false;
        user = config.user;
      };
      environment.systemPackages = [
        # (unstable.obs-studio.overrideAttrs(oldAttrs: rec {
        #   patches = [
        #     (pkgs.fetchpatch {
        #       url = "https://pastebin.com/raw/aPDNZWJK";
        #       sha256 = "sha256-20SfLfUuo8h5sKyWQAAhc1X8qgF35+8zMRjE3+o8oHU=";
        #     })];
        # }))


        # pkgs.obs-studio
        (pkgs.lutris.override {
          extraPkgs = pkgs: with pkgs;[
            pkgs.alsa-lib
            # pkgs.pkgsi686Linux.alsa-lib
            pkgs.SDL2
            pkgs.mangohud
            pkgs.speex
            pkgs.flacpkgs.flac
            pkgs.gamemode.lib

            pkgs.libusb1
            pkgs.libsoup_2_4
            pkgs.openal
            pkgs.libgudev
            pkgs.libvdpau
            pkgs.libpulseaudio
            pkgs.pkgsi686Linux.libpulseaudio
            pkgs.winetricks
            pkgs.gtk3-x11
            pkgs.pango
            pkgs.gdk-pixbuf
            pkgs.shared-mime-info
            pkgs.libxcrypt
          ];
        })
        # pkgs.unstable.stremio
        pkgs.my.osu-lazer-bin
        # pkgs.my.tlauncher
        # pkgs.unstable.osu-lazer-bin
        pkgs.chatterino2
      ];
    };
    inheritParentConfig = true;
  };

  specialisation.work = {
    configuration = {

      networking.extraHosts = ''
        # 127.0.0.1 youtube.com
        # 127.0.0.1 www.youtube.com
        127.0.0.1 reddit.com
        127.0.0.1 www.reddit.com
        # 127.0.0.1 www.osu.ppy.sh
        # 127.0.0.1 osu.ppy.sh
      '';
      environment.systemPackages = [
      ];
      environment.variables = {
        WORK_MODE = "1";
        ROC_ENABLE_PRE_VEGA = "1";
      };
      # environment.sessionVariables = {
      #   WORK_MODE = "1";
      # };
    };
    inheritParentConfig = true;
  };

  home-manager.useGlobalPkgs = true;
  home-manager.backupFileExtension = "backup";
  # xdg.configFile."mimeapps.list".force = true;

  home-manager.users.${config.user} =
    { pkgs, config, guake, fetchFromGitHub, callPackage, ... }: {
      imports = [
        ./common.nix
      ];
      home.packages = [
      ];
      home.file = {
        ".config/waybar" = {
          source = config.lib.file.mkOutOfStoreSymlink /etc/nixos/configs/waybar;
        };
      };
      services.kdeconnect.enable = true;
      modules.eww.enable = true;

      programs.fish.shellInit = ''
        function rebuild-work
          set -x NIX_BUILD_CORES 10
          sudo nixos-rebuild switch --impure  --flake '/etc/nixos/.?submodules=1#mysystem' -j10 $argv
          sudo /run/current-system/specialisation/work/activate
        end
        function activate-specialisation-work
          sudo /run/current-system/specialisation/work/activate
        end
        function rebuild-default
          set -x NIX_BUILD_CORES 10
          sudo nixos-rebuild switch --impure  --flake '/etc/nixos/.?submodules=1#mysystem' -j10 $argv
          sudo /run/current-system/specialisation/default/activate
        end
        function update-system
          nix flake update /etc/nixos
          set -x NIX_BUILD_CORES 10
          sudo nixos-rebuild boot --impure  --flake '/etc/nixos/.?submodules=1#mysystem' -j10 $argv
        end
        function activate-specialisation-default
          sudo /run/current-system/specialisation/default/activate
        end'';
      modules.ssh.enable = true;
      

      # TODO is it a good way?
      systemd.user.tmpfiles.rules = [
        "L /home/${configbase.user}/Downloads - - - - /mnt/new/Downloads"
        "L /home/${configbase.user}/Documents - - - - /mnt/md127/Documents"
        "L /home/${configbase.user}/Videos - - - - /mnt/md127/Videos"
        "L /home/${configbase.user}/.ssh - - - - /mnt/md127/backup_arch/.ssh"
      ];
    };
}
