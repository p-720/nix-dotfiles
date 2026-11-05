{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.strataProxy;

  # the person's Strata model directory: instance configs (each load writes a new one with a fresh
  # random API key) and state.json (the share-port API key clients already have) are 0600 there, so
  # this has to run as that user, not as a DynamicUser
  user = cfg.user or config.user;

  proxy = pkgs.runCommand "strata-direct-proxy" { } ''
    mkdir -p $out/bin
    install -m 0644 ${./proxy.py} $out/bin/strata-direct-proxy.py
  '';
in {
  options.modules.strataProxy = {
    enable = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Put a proxy in front of the Strata engine's own API server so API clients are not held to
        the host gateway's hard-coded 12 MiB request-body cap (apps/host/server/index.mjs
        readBody(req, 12*1024*1024)), which answers HTTP 500 for a turn carrying several pictures.
      '';
    };

    bind = mkOption {
      type = types.str;
      default = "0.0.0.0";
      example = "127.0.0.1";
      description = ''
        0.0.0.0 matches the exposure Strata's own share port already has, and clients still present
        the same API key. Use 127.0.0.1 to keep it on the machine and reach it over an SSH forward.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 18600;
      description = "The port API clients point at instead of Strata's share port.";
    };

    maxBodyMiB = mkOption {
      type = types.ints.positive;
      default = 256;
      description = ''
        Request-body ceiling for this proxy. 256 matches serve/server.py CHUNKED_BODY_MAX, the
        engine's own limit; asking for more than that only moves the refusal from this proxy to the
        engine.
      '';
    };

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Whose ~/.strata to read. Defaults to the host's config.user.";
    };
  };

  config = mkIf cfg.enable {
    systemd.services.strata-proxy = {
      description = "Strata engine API proxy (no 12 MiB request-body cap)";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        STRATA_PROXY_BIND = cfg.bind;
        STRATA_PROXY_PORT = toString cfg.port;
        STRATA_MAX_BODY_MIB = toString cfg.maxBodyMiB;
        STRATA_DATA_DIR = "/home/${user}/.strata/data";
      };

      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python3 ${proxy}/bin/strata-direct-proxy.py";
        # named User here, not `inherit user`: inherit would take the let-bound name and write a
        # lowercase serviceConfig.user, which is not the option systemd reads
        User = user;
        Restart = "always";
        RestartSec = 3;
        NoNewPrivileges = true;
        # ProtectSystem=strict would make the user's home unreadable, and the instance configs are in it
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = true;
      };
    };
  };
}
