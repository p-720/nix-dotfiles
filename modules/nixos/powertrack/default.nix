{ config, lib, pkgs, ... }:

with lib;
let
  cfg = config.modules.powertrack;

  # Checked at eval rather than through config.assertions: a kWh silently priced at the
  # wrong zone is worse than a failed build, and this fires on every eval path.
  numberedZones = imap1 (i: z: { inherit i; inherit (z) hours; }) cfg.tariff.zones;

  zoneCoverage = map (h: {
    inherit h;
    hits = filter (z: elem h z.hours) numberedZones;
  }) (range 0 23);

  badHours = map (c: toString c.h) (filter (c: length c.hits != 1) zoneCoverage);

  # hour 0..23 -> 1-based index into tariff.zones, baked into the CLI as a 24-number
  # table so pricing never does date arithmetic nor re-parses hour ranges.
  zoneIndex =
    if !cfg.tariff.enable || badHours == [] then
      concatStringsSep " "
        (map (c: toString (head c.hits).i) zoneCoverage)
    else
      throw ''
        modules.powertrack.tariff.zones must charge every local hour 0..23 exactly once.
        Bad hours: ${concatStringsSep " " badHours}
      '';

  # Nix pads floats to six decimals; the tariff table should read like the bill.
  fmtRate = r:
    let
      strip = t: if hasSuffix "0" t then strip (removeSuffix "0" t) else t;
      m = builtins.match "^([-+0-9]+)[.]([0-9]+)$" (toString r);
      frac = strip (builtins.elemAt m 1);
    in
      if m == null then toString r
      else builtins.elemAt m 0 + optionalString (frac != "") ".${frac}";

  zoneRates = concatStringsSep "|"
    (map (z: "${z.name}:${fmtRate z.rate}") cfg.tariff.zones);

  tariffEnabled = optionalString cfg.tariff.enable;

  binPath = makeBinPath [ pkgs.coreutils pkgs.gawk ];

  # systemd units get a minimal PATH (coreutils/findutils/grep/sed/systemd), so nvidia-smi
  # is never on it: use the driver's own output, which is also the version-matched one.
  nvidiaPkg = config.hardware.nvidia.package or null;
  driverSmi =
    if nvidiaPkg == null then null else "${nvidiaPkg.bin or nvidiaPkg}/bin/nvidia-smi";
  smiPath = if cfg.nvidiaSmi != null then cfg.nvidiaSmi else driverSmi;

  collect = pkgs.writeShellScriptBin "powertrack-collect" ''
    export PATH=${binPath}:$PATH
    export POWERTRACK_STATE="''${POWERTRACK_STATE:-${escapeShellArg cfg.stateDir}}"
    export PT_SAMPLE=${toString cfg.sampleInterval}
    export PT_GPU_SAMPLE=${toString cfg.gpuSampleInterval}
    export PT_PERSIST=${toString cfg.persistInterval}
    export PT_STATUS=${toString (if cfg.statusInterval == null then 1000000000 else cfg.statusInterval)}
    export PT_GPU_FAILS=${toString cfg.gpuFailLimit}
    export PT_GPU_RETRY=${toString cfg.gpuRetryInterval}
    export PT_BASE_W=${toString cfg.basePowerW}
    export PT_CPU_SCALE_PCT=${toString cfg.cpuScalePercent}
    export PT_PSU_EFFICIENCY_PCT=${toString cfg.psuEfficiencyPercent}
    export PT_CPU_TDP_W=${toString cfg.cpuTdpW}
    export PT_ESTIMATE_CPU=${optionalString cfg.estimateCpuPower "1"}
    export PT_GPU_DISABLE=${optionalString (!cfg.gpu.enable) "1"}
    export PT_NVIDIA_SMI=${escapeShellArg (if smiPath == null then "nvidia-smi" else smiPath)}
    ${builtins.readFile ./collect.sh}
  '';

  cli = pkgs.writeShellScriptBin "powertrack" ''
    export PATH=${binPath}:$PATH
    export POWERTRACK_STATE="''${POWERTRACK_STATE:-${escapeShellArg cfg.stateDir}}"
    export PT_CURRENCY=${escapeShellArg cfg.tariff.currency}
    export PT_ZONES=${escapeShellArg (tariffEnabled zoneRates)}
    export PT_ZONE_IDX=${escapeShellArg (tariffEnabled zoneIndex)}
    ${builtins.readFile ./cli.sh}
  '';

  package = pkgs.runCommand "powertrack" { } ''
    mkdir -p $out/bin
    ln -s ${collect}/bin/powertrack-collect $out/bin/powertrack-collect
    ln -s ${cli}/bin/powertrack $out/bin/powertrack
  '';
in
{
  options.modules.powertrack = {
    enable = mkEnableOption ''
      powertrack: about 5 MB of RSS, keeps live daily, ISO-weekly and monthly energy totals
      for this machine from the RAPL cpu counter and NVML gpu power
    '';

    package = mkOption {
      type = types.package;
      default = package;
      defaultText = literalExpression "./package built from collect.sh + cli.sh";
      description = "powertrack-collect and the powertrack CLI to run and install.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/powertrack";
      description = ''
        Where counters, hourly.tsv and history.tsv live. Grows around 10 KB a year:
        24 hour rows plus 3 period rows per day.
      '';
    };

    sampleInterval = mkOption {
      type = types.ints.positive;
      default = 10;
      description = ''
        Seconds between RAPL counter reads, and the bound on accuracy. The package counter
        spans 65 kJ, so at 10 s even a 6 kW CPU cannot make it overflow.
      '';
    };

    gpuSampleInterval = mkOption {
      type = types.ints.positive;
      default = 20;
      description = "Seconds between nvidia-smi power queries, which cost about 30 ms each.";
    };

    persistInterval = mkOption {
      type = types.ints.positive;
      default = 60;
      description = "How often counters are rewritten; also the worst-case loss after a crash.";
    };

    statusInterval = mkOption {
      type = types.nullOr types.ints.positive;
      default = 3600;
      description = "Log one journald status line this often. null disables it.";
    };

    basePowerW = mkOption {
      type = types.number;
      default = 50;
      description = ''
        Constant draw for everything no sensor covers: chipset, RAM, NVMe, fans, USB.
        Measured CPU and GPU power is added on top of this.
      '';
    };

    cpuScalePercent = mkOption {
      type = types.ints.between 0 400;
      default = 115;
      description = ''
        Multiplier on RAPL cpu energy. RAPL counts what the silicon burns; the Vcore VRM
        loses another 10-20% as heat before it reaches the wall.
      '';
    };

    psuEfficiencyPercent = mkOption {
      # ints.between keeps the collector's divisor non-zero, which is the real constraint
      type = types.ints.between 1 100;
      default = 90;
      description = ''
        AC-to-DC efficiency, applied by dividing, so totals are wall-side. An 80+ Gold 1000 W
        unit at 25-45% load (this box) sits around 90-92%.
      '';
    };

    estimateCpuPower = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Estimate cpu power from /proc/stat busy time x cpuTdpW when there is no readable RAPL
        zone. Only worth turning on for hosts without one.
      '';
    };

    cpuTdpW = mkOption {
      type = types.number;
      default = 0;
      description = "Package TDP used by estimateCpuPower.";
    };

    gpu.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Sample gpu board power over NVML.";
    };

    gpuFailLimit = mkOption {
      type = types.ints.positive;
      default = 5;
      description = "Consecutive NVML failures before backing off to gpuRetryInterval.";
    };

    gpuRetryInterval = mkOption {
      type = types.ints.positive;
      default = 300;
      description = ''
        Once gpu sampling has given up, probe again this often. It gives up instead of
        spawning nvidia-smi on every sample while the driver is down, but it has to come
        back on its own: the binary is absent from the minimal service PATH and NVML also
        refuses before the driver loads, so a permanent verdict would black out the gpu.
      '';
    };

    nvidiaSmi = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        Path to nvidia-smi. Null means the driver-matched `bin` output of
        `config.hardware.nvidia.package`, because systemd units on NixOS get a minimal PATH
        that does not contain /run/current-system/sw/bin.
      '';
    };

    tariff = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Price energy with a time-of-day tariff.";
      };

      currency = mkOption {
        type = types.str;
        default = "руб";
        description = "Suffix on every cost figure.";
      };

      zones = mkOption {
        type = with types; listOf (submodule {
          options = {
            name = mkOption {
              type = str;
              description = "Short label used in reports.";
            };
            rate = mkOption {
              type = number;
              description = "Currency per kWh.";
            };
            hours = mkOption {
              type = listOf (ints.between 0 23);
              description = "Local hours charged at this rate.";
            };
          };
        });
        # Moscow three-zone tariff as charged on this meter: T1 7-10/17-21,
        # T3 10-17/21-23, T2 23-7.
        default = [
          {
            name = "T1";
            rate = 12.39;
            hours = [ 7 8 9 17 18 19 20 ];
          }
          {
            name = "T3";
            rate = 8.90;
            hours = [ 10 11 12 13 14 15 16 21 22 ];
          }
          {
            name = "T2";
            rate = 4.85;
            hours = [ 23 0 1 2 3 4 5 6 ];
          }
        ];
        description = "Tariff zones; every local hour must fall in exactly one zone.";
      };
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.services.powertrack = {
      description = "Machine energy totals (RAPL cpu + NVML gpu)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/powertrack-collect";
        # RAPL energy counters are 0400 root and the zone has to be enabled, so there is
        # no DynamicUser here: a udev rule would cost more than the isolation is worth.
        StateDirectory = "powertrack";
        StateDirectoryMode = "0755";
        Restart = "always";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = "yes";
        # deliberately not ProtectKernelTunables: it read-only binds /sys paths this unit
        # has to write, namely enabling the RAPL zone.
        ProtectSystem = "strict";
        ProtectKernelModules = true;
        ProtectClock = true;
        ReadWritePaths = [ cfg.stateDir ];
        TasksMax = 64;
        LimitNOFILE = 256;
      };
    };
  };
}
