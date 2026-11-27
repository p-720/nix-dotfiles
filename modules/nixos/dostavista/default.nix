{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.dostavista;

  # Live-edited, like taffybar.hs: the whole point of splitting the poller from
  # the bar is that radius/top-N/wording changes cost no rebuild and no switch,
  # and a store copy would freeze them at build time.
  pollerDir = "/etc/nixos/configs/taffybar/dostavista";

  # ExecStart has no shell to take env prefixes, and a --user unit inherits none
  # of the login shell's environment, so the two things the poller wants that are
  # not already in its env have to be exported here.
  launch = pkgs.writeShellScript "dostavista-poller" ''
    # notify-send needs the session bus to reach dunst; the cron entries in
    # configuration.nix hardcode the same address for the same reason. A missing
    # bus is not fatal: the poller logs the failed notification and keeps polling.
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
    # otherwise journald buffers the poll log until the process exits
    export PYTHONUNBUFFERED=1
    # the symlinked path, not the store: editing config.py and restarting the
    # unit is the whole tuning loop
    exec ${pkgs.python3}/bin/python3 "$HOME/.config/dostavista/poller.py"
  '';
in {
  options.modules.dostavista = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Poll Dostavista for orders whose every point is near home, and hand the
        result to the bar widget in taffybar.hs, which reads only state.json and
        decides nothing itself.
      '';
    };
  };

  # NOTE parens matter: `mkIf en {...} // x` drops x (see modules/nixos/taffybar)
  config = mkIf cfg.enable ({
    # Stdlib-only python: dvsign signs with hmac/hashlib over urlopen, maprender
    # shells out to ImageMagick, notifications shell out to notify-send. Both of
    # those are already installed system-wide (modules/nixos/taffybar ships
    # imagemagick; libnotify is in configuration.nix).
    systemd.user.services.dostavista-poller = {
      description = "Dostavista near-home order poller";
      # default.target, not graphical-session.target: dwm here is started by
      # SDDM's "none+dwm" session and the bar itself is looped by the dwm startup
      # script (modules/nixos/dwm), so nothing reliable pulls in the session
      # target. gtk-sni-tray uses default.target for the same reason.
      wantedBy = [ "default.target" ];
      serviceConfig = {
        ExecStart = "${launch}";
        # the loop is meant to be endless, so a crash (a response shape this code
        # has not seen) must come back on its own
        Restart = "always";
        RestartSec = 15;
        # bounded burst: a dead session makes every start fail fast, and without a
        # limit that is a hot loop against the courier API
        StartLimitIntervalSec = 600;
        StartLimitBurst = 5;
      };
    };
  } // (my.allUsers ({ config, ... }: {
    home.file = {
      ".config/dostavista".source =
        config.lib.file.mkOutOfStoreSymlink pollerDir;
    };
  })));
}
