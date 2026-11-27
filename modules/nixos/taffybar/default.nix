{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.taffybar;

  # What taffybar.hs shells out to: python3 for ff-favicon.py (which itself
  # shells to ImageMagick for svg favicons and the FF-flame stamp), wpctl for the
  # WirePlumber volume, bash for streamingCommand. A --user unit gets only
  # systemd's minimal PATH - coreutils, findutils, gnugrep, gnused, systemd - so
  # without these the bar dies on the first window title with
  # `python3: readCreateProcessWithExitCode: posix_spawnp: does not exist`, and
  # dyreeed restarts make it a crash loop against the start limit.
  barBinPath = lib.makeBinPath [ pkgs.python3 pkgs.imagemagick pkgs.wireplumber pkgs.bash ];

  # The env the dwm launch line splices as `VAR=val` prefixes, in a script
  # instead: ExecStart has no shell to take that form (see its comment).
  waylandLaunch = pkgs.writeShellScript "taffybar-wayland" ''
    # dyre recompiles taffybar.hs on change and shells out to ghc; that env's bin
    # must precede PATH but must not leak into the rest of the session (it also
    # ships a taffybar of its own)
    PATH=${cfg.ghcEnv}/bin:${barBinPath}:$PATH
    # export, not bare: an assignment with no command on the line sets a shell
    # var that never reaches the bar (the dwm line prefixes the bar itself)
    export ${cfg.barEnv}
    exec ${pkgs.taffybar}/bin/taffybar
  '';
in {
  options.modules.taffybar = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = "";
      description = ''
      '';
    };
    # off by default: on a dwm host the session script there loops the bar itself,
    # so a unit would only race it for the same layer
    waylandBar.enable = mkOption {
      type = types.bool;
      default = false;
      description = "run taffybar as a systemd user unit in a Wayland session";
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
    # Wayland gives the bar no session script to loop the launch off the way
    # modules/nixos/dwm does, so it gets a unit instead.
    systemd.user.services.taffybar = mkIf cfg.waylandBar.enable {
      description = "taffybar";
      partOf = [ "graphical-session.target" ];
      # the bar's SNI tray drops the tray entirely without a watcher already up
      after = [ "graphical-session.target" "graphical-session-pre.target" "gtk-sni-tray.service" ];
      requires = [ "gtk-sni-tray.service" ];
      # PartOf/After only order and follow; nothing pulls the unit in without this
      wantedBy = [ "graphical-session.target" ];
      # the double-bar guard: in a dwm session the loop in modules/nixos/dwm
      # already runs taffybar, and WAYLAND_DISPLAY is not in the user manager env.
      # ANDed with HYPRLAND_INSTANCE_SIGNATURE below: repeated ConditionEnvironment=
      # lines must all hold.
      unitConfig.ConditionEnvironment = [ "WAYLAND_DISPLAY" "HYPRLAND_INSTANCE_SIGNATURE" ];
      # second guard: home-manager imports WAYLAND_DISPLAY with `systemd variables
      # = [--all]`, and that import survives until the user manager itself restarts,
      # so dwm started after hyprland without a logout would otherwise race this
      # unit. The bar's Hyprland widgets cannot work without HIS anyway.
      # StartLimit* parse only in [Unit] - in [Service] systemd reports "unknown
      # key, ignoring" and you silently have no limit. Bounded burst because the
      # bar exits 75 to self-restart on every hyprland configreload, and without a
      # limit that is a hot loop. SUPER+ALT+B (restart) clears the counter.
      startLimitIntervalSec = 60;
      startLimitBurst = 10;
      serviceConfig = {
        # ExecStart is exec'd with no shell, so it refuses the `VAR=val cmd` prefix
        # form the dwm launch uses ("Neither a valid executable name nor an
        # absolute path"), and Environment= cannot prepend onto the inherited PATH.
        ExecStart = "${waylandLaunch}";
        Restart = "always";
        RestartSec = 2;
        # hyprland's user-manager import covers WAYLAND_DISPLAY, HIS, PATH and a
        # few more, but none of these; a --user unit inherits no profile env either
        Environment = [
          # pinned both ways so a DISPLAY/WAYLAND_DISPLAY left over from the other
          # session can never steer GTK
          "GDK_BACKEND=wayland"
          "XDG_SESSION_TYPE=wayland"
          # no profile here ships a merged loaders.cache, so pixbuf loads nothing
          "GDK_PIXBUF_MODULE_FILE=${pkgs.gdk-pixbuf}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache"
        ];
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
