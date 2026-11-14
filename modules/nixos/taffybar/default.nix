{ config, lib, pkgs, ... }:

with lib;
let cfg = config.modules.taffybar;
in {
  options.modules.taffybar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
    # ghc for dyre's runtime recompile of taffybar.hs. Its bin also contains a
    # taffybar binary and other packages' tools, so it must stay off the system
    # PATH and only wrap the bar launch.
    ghcEnv = mkOption {
      type = types.package;
      readOnly = true;
      default = pkgs.callPackage ./ghc-env.nix { };
      description = "GHC with the packages taffybar.hs imports, for dyre";
    };
    # Runtime env for the bar process itself, spliced in at the launch site
    # (modules/nixos/dwm). File paths, not PATH entries.
    #   LOCALE_ARCHIVE: gi marshals String through the locale codeset, so with
    #   no locale set the emoji taffybar.hs draws come out empty. NixOS sets
    #   neither here (i18n.defaultLocale is off).
    # No CA setup needed: the TLS client validates against the trust store
    # compiled into the tls library (settingDisableCertificateValidation is
    # False, verified live against the pomotasker server).
    barEnv = mkOption {
      type = types.str;
      readOnly = true;
      default =
        ''LOCALE_ARCHIVE=${pkgs.glibcLocales}/lib/locale/locale-archive LANG=C.UTF-8 LC_ALL=C.UTF-8'';
      description = "env assignments the taffybar launch needs";
    };
  };
  # NOTE parens matter: `mkIf en {...} // x` drops x (mkIf wraps the whole
  # attrset and swallows merged siblings); `mkIf en ({...} // x)` keeps it
  config = mkIf cfg.enable ({
    systemd.user.services.gtk-sni-tray = {
      enable = true;
      description = "Gtk sni tray";
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart =
          "${pkgs.haskellPackages.status-notifier-item}/bin/status-notifier-watcher";
      };
    };
    # not home.packages: home-manager's home-path is not on PATH here
    # status-notifier-item puts status-notifier-watcher on PATH for the
    # xmonad startup hook (taffybar's SNI tray needs a watcher)
    # ff-favicon.py shells out to ImageMagick for svg-only favicons and for the
    # FF-flame stamp; without it those icons silently fall back to nothing/plain
    environment.systemPackages =
      [ pkgs.taffybar pkgs.haskellPackages.status-notifier-item pkgs.imagemagick ];
  } // (my.allUsers ({ config, ... }: {
    # out-of-store links: taffybar recompiles its config while running, and a
    # home.file source copy would freeze it at build time
    home.file = {
      ".config/taffybar/taffybar.css".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/taffybar.css";
      ".config/taffybar/gotham.css".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/gotham.css";
      ".config/taffybar/taffybar.hs".source =
        config.lib.file.mkOutOfStoreSymlink "/etc/nixos/modules/nixos/taffybar/taffybar.hs";
    };
  })));
}
