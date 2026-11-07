{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.strataEngine;

  # official headless distribution: bundled python + serve/server.py
  control = "${cfg.package}/terminal";

  # Engine and picture reader live outside the nix store, in a versioned folder the app
  # installs/updates; run.sh fills both into the generated run config at start.
  runConfig = pkgs.writeText "strata-engine-config.json" (builtins.toJSON ({
    exe = "@ENGINE@";
    args = cfg.engineArgs;
    cwd = control;
    tokenizer = cfg.tokenizer;
    model_name = cfg.modelName;
    backend = "cuda";
    gpu = cfg.gpu;
    env = cfg.engineEnv;
    drafting = "dflash2";
    mtp = true;
  } // optionalAttrs (cfg.logFile != null) { log = cfg.logFile; }
    // optionalAttrs cfg.vision {
    vision = {
      exe = "@VISION@";
      mmproj = cfg.mmproj;
      model = cfg.modelGguf;
      gpu = false;
      max_tokens = 1024;
    };
  }));

  runner = pkgs.runCommand "strata-engine-run" { } ''
    mkdir -p $out/bin
    install -m 0755 ${./run.sh} $out/bin/strata-engine-run
  '';
in {
  options.modules.strataEngine = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Run the Strata engine's own API server (the AppImage's serve/server.py) as a system
        service, without the desktop app: fixed engine arguments in nix, no GUI rewriting them.
      '';
    };

    user = mkOption {
      type = types.str;
      default = config.user;
      description = "The user who owns the models, the engine component and ~/.strata.";
    };

    package = mkOption {
      type = types.package;
      default = pkgs.my.strata-control;
      description = "The Strata Terminal package (headless: bundled python + serve/server.py).";
    };

    componentsDir = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.local/share/strata/components";
      description = "Where the downloaded engine components live.";
    };

    engineDir = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/home/andrew/.local/share/strata/components/engine/0.1.58-linux-x86_64-cuda-cuda13";
      description = "Pin one engine folder. Null follows the newest installed component.";
    };

    modelPack = mkOption {
      type = types.str;
      default = "/home/andrew/Strata/models/packs/unsloth-ud-iq2_xs";
      description = "The model's pack folder (tokenizer + native expert blobs).";
    };

    modelGguf = mkOption {
      type = types.str;
      default = "/home/andrew/Strata/models/models/unsloth-UD-IQ2_XS/Qwen3.8-Flash-Next-UD-IQ2_XS-00001-of-00003.gguf";
      description = "The model's first GGUF shard.";
    };

    tokenizer = mkOption {
      type = types.str;
      default = "${cfg.modelPack}/tokenizer";
      description = "The pack tokenizer folder.";
    };

    mmproj = mkOption {
      type = types.str;
      default = "/home/andrew/Strata/models/models/mmproj-Qwen3.8-Flash-Next-BF16.gguf";
      description = "The picture reader's mmproj file.";
    };

    modelName = mkOption {
      type = types.str;
      default = "qwen3.8-flash-next-unsloth-ud-iq2_xs";
      description = "The model id clients ask for.";
    };

    mtp = mkOption {
      type = types.str;
      default = "/home/andrew/Strata/models/mtp/rt";
      description = "The draft layer (--mtp) folder.";
    };

    context = mkOption {
      type = types.int;
      default = 204800;
      description = "The engine's --max-context.";
    };

    kv = mkOption {
      type = types.str;
      default = "int8";
      description = "The engine's --kv type.";
    };

    residentBudgetGiB = mkOption {
      type = types.int;
      default = 30;
      description = ''
        --resident-budget-gib. The engine clamps this to what free RAM allows after
        engineEnv.STRATA_RESIDENT_HEADROOM_GIB and its own margin, so a high value means
        "use what is there".
      '';
    };

    vramReserveMiB = mkOption {
      type = types.int;
      # 150 was below what dflash2 + int8 KV at 200k needs: at ~139k tokens the card was full
      # (11 MiB free) and the driver paged VRAM to host RAM, decode fell to ~15 t/s. The engine
      # asked for 704; 768 keeps the 512 MiB advisory free at request time.
      default = 768;
      description = "The engine's --vram-reserve-mib.";
    };

    vision = mkOption {
      type = types.bool;
      default = true;
      description = "Start the picture reader (CPU). Off removes the vision section and --vision.";
    };

    gpu = mkOption {
      type = types.int;
      default = 0;
      description = "nvidia-smi index of the card.";
    };

    engineEnv = mkOption {
      type = types.attrsOf types.str;
      default = {
        STRATA_HC_Q8 = "1";
        # host RAM kept free beside the expert copy; the engine's own overhead comes out of this
        STRATA_RESIDENT_HEADROOM_GIB = "3";
      };
      description = "Environment the engine is started with (merged into the run config's env).";
    };

    engineArgs = mkOption {
      type = types.listOf types.str;
      default = [
        "--pack" cfg.modelPack
        "--native" cfg.modelGguf
        "--expert-profile" "${control}/data/expert-profile.bin"
        "--expert-cache" "auto"
        "--prefill" "auto"
        "--spec" "4"
        "--spec-min-p" "0.5"
        "--mtp" cfg.mtp
        "--max-context" (toString cfg.context)
        "--kv" cfg.kv
        "--resident-budget-gib" (toString cfg.residentBudgetGiB)
        "--adapt-async" "1"
        "--expert-cache-per-layer"
        "--vram-reserve-mib" (toString cfg.vramReserveMiB)
      ] ++ optional cfg.vision "--vision";
      description = "Engine arguments, verbatim. Overridable as a whole.";
    };

    bind = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = ''
        Listen address. 0.0.0.0 keeps the exposure the share port had; drop to 127.0.0.1 to
        keep the API on this machine.
      '';
    };

    port = mkOption {
      type = types.port;
      default = 18600;
      description = "Listen port. 18600 is the port the old proxy used, so clients keep working.";
    };

    stateFile = mkOption {
      type = types.str;
      default = "/home/${cfg.user}/.strata/data/state.json";
      description = ''
        Read serving.apiKey from here, the same key clients already use. Without a key the
        service listens on 127.0.0.1 only, whatever bind says.
      '';
    };

    logFile = mkOption {
      type = types.nullOr types.str;
      default = "/var/log/strata-engine/engine.log";
      description = "Where the engine's own log goes (systemd's LogsDirectory). Null streams it away.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "modules.strataEngine needs pkgs/strata-control.nix (pkgs.my.strata-control).";
      }
    ];

    systemd.services.strata-engine = {
      description = "Strata engine API server (headless)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${runner}/bin/strata-engine-run";
        User = cfg.user;
        Restart = "on-failure";
        RestartSec = 15;
        RuntimeDirectory = "strata-engine";
        RuntimeDirectoryMode = "0750";
        LogsDirectory = "strata-engine";
        # the model's expert copy is pinned/page-locked; swapping it turns decode into a crawl
        MemorySwapMax = "0";
        LimitMEMLOCK = "infinity";
        # SIGTERM to the server only, so it drains the engine's current request before it stops it
        KillMode = "mixed";
        TimeoutStopSec = 120;
        NoNewPrivileges = true;
        ProtectSystem = "full";
        ProtectHome = false;
        PrivateTmp = true;
      };
      environment = {
        STRATA_CONTROL = control;
        STRATA_CONFIG_TEMPLATE = runConfig;
        STRATA_COMPONENTS_DIR = cfg.componentsDir;
        STRATA_BIND = cfg.bind;
        STRATA_PORT = toString cfg.port;
        STRATA_STATE_FILE = cfg.stateFile;
        PYTHONUNBUFFERED = "1";
        PYTHONDONTWRITEBYTECODE = "1";
        # foreign engine binaries: nix-ld resolves their loader, these two supply libstdc++ and the driver
        NIX_LD_LIBRARY_PATH = "/run/current-system/sw/share/nix-ld/lib";
        LD_LIBRARY_PATH = "/run/opengl-driver/lib:${pkgs.stdenv.cc.cc.lib}/lib";
        PATH = mkForce "/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.jq}/bin";
      } // optionalAttrs (cfg.engineDir != null) { STRATA_ENGINE_DIR = cfg.engineDir; };
    };
  };
}
