{ config, pkgs, self, ... }:

{
  imports = [ ./hardware-configuration.nix ];
  modules.flakes.enable = true;
  services.auto-cpufreq.enable = true;
  services.auto-cpufreq.settings = {
    charger = {
      governor = "performance";
      turbo = "always";
    };
    battery = {
      governor = "powersave"; # Or "schedutil" for a middle ground
      turbo = "auto";
    };
  };
  systemd.services.intel-gpu-tools-init = {
    description = "Set Intel GPU Frequency for UI performance";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # We use the absolute path from the nix store for the binary
      ExecStart = [
        "${pkgs.intel-gpu-tools}/bin/intel_gpu_frequency --custom max=1200"
        "${pkgs.intel-gpu-tools}/bin/intel_gpu_frequency -m 1100"
      ];
      RemainAfterExit = true;
    };
  };
  services.nanobanana.enable = true;
  pomotasker.enable = true;
  systemd.sleep.settings.Sleep = {
    AllowSuspend = "no";
    AllowHibernation = "no";
    AllowHybridSleep = "no";
    AllowSuspendThenHibernate = "no";
  };
  # services.tlp = {
  #   enable = true;
  #   settings = {
  #     CPU_SCALING_GOVERNOR_ON_AC = "performance";
  #     CPU_SCALING_GOVERNOR_ON_BAT = "powersave";

  #     CPU_ENERGY_PERF_POLICY_ON_BAT = "power";
  #     CPU_ENERGY_PERF_POLICY_ON_AC = "performance";

  #     CPU_MIN_PERF_ON_AC = 0;
  #     CPU_MAX_PERF_ON_AC = 100;
  #     CPU_MIN_PERF_ON_BAT = 0;
  #     CPU_MAX_PERF_ON_BAT = 20;
  #     INTEL_GPU_MIN_FREQ_ON_AC=1100000;

  #     #Optional helps save long term battery health
  #     # START_CHARGE_THRESH_BAT0 = 40; # 40 and below it starts to charge
  #     # STOP_CHARGE_THRESH_BAT0 = 80; # 80 and above it stops charging

  #   };
  # };

  # users.users.andrew.extraGroups = ["corectrl" "gamemode"];
  # programs.corectrl ={
  #   enable = true;
  # };
  security.rtkit.enable = true;

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [
      intel-media-driver
      intel-vaapi-driver
      libva-vdpau-driver
      intel-compute-runtime-legacy1
    ];

    extraPackages32 = with pkgs.driversi686Linux; [
      intel-media-driver
      libva-vdpau-driver
    ];
    # extraPackages = [
    #   # pkgs.intel-media-sdk
    #   # pkgs.intel-media-driver
    #   pkgs.intel-vaapi-driver
    #   pkgs.libvdpau-va-gl
    # ];
  };
  # hardware.opengl.enable = true;
  # hardware.opengl.driSupport = true;
  # hardware.opengl.extraPackages = with pkgs; [ intel-vaapi-driver libva-vdpau-driver libvdpau-va-gl];
  # hardware.opengl.extraPackages32 = with pkgs.pkgsi686Linux; [ intel-vaapi-driver ];

  environment.variables = { LIBVA_DRIVER_NAME = "i965"; };
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.grub.enable = true;
  # boot.loader.grub.default = 2;
  # boot.loader.grub.version = 2;
  boot.blacklistedKernelModules = [ "iTCO_wdt" "iTCO_vendor_support" ];

  # boot.kernelPackages = pkgs.linuxPackages_lts;

  # TODO just use self.user 
  user = self.user;

  # boot.tmpOnTmpfs = true;
  boot.tmp.cleanOnBoot = true;

  # TODO boot.loader.grub.device = "/dev/sda";

  # TODO extract
  networking.hostName = "${config.user}-laptop";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";

  i18n.defaultLocale = "en_US.UTF-8";
  services.gvfs.enable = true;
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ACTION=="add", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="201d" MODE="0777" GROUP="users"
    KERNEL=="ttyUSB*", MODE="0666"
  '';

  services.xserver = {
    enable = true;

    layout = "us,ru";
    xkbOptions = "grp:alt_shift_toggle";

    libinput = {
      enable = true;
      mouse = { accelProfile = "flat"; };
    };
    exportConfiguration = true;
    #windowManager.i3.enable = true;

    #displayManager = {
    #  defaultSession = "none+i3";
    #  autoLogin = {
    #    enable = true;
    #    user = config.user;
    #  };
    #};
  };
  programs.tmux = {
    enable = true;
    extraConfig = ''
      set-window-option -g mode-keys vi

      unbind C-b
      set-option -g prefix C-s
      bind-key C-s send-prefix

      # act like vim
      setw -g mode-keys vi
      bind-key h select-pane -L
      bind-key j select-pane -D
      bind-key k select-pane -U
      bind-key l select-pane -R

      set-option -g set-titles on
      set-option -g set-titles-string "#T"
      bind-key -T copy-mode-vi v send -X begin-selection


      run-shell ${pkgs.tmuxPlugins.yank}/share/tmux-plugins/yank/yank.tmux
    '';
  };

  modules.maestral.enable = true;
  # modules.mihomo = {
  #   enable = true;
  #   configFile = "/mnt/md127/Dropbox/mihomo/config.yaml";
  #   # package = pkgs.unstable.mihomo;
  #   package = pkgs.my.mihomo;
  #   # package = pkgs.old-24-05.mihomo;
  #   tunMode = true;
  # };

  modules.hypr = {
    enable = true;
    settingsFile = "/etc/nixos/configs/hypr/hyprland-laptop.conf";
  };
  # services.displayManager = {
  #   enable = true;
  #   defaultSession = "hyprland";

  #   sddm.enable = true;
  #   sddm.package = pkgs.kdePackages.sddm;
  #   sddm.settings = {
  #     X11 = {
  #       ServerArguments="-s 1 -logfile /tmp/x111.log";
  #     };
  #   };
  #   sddm.extraPackages = [
  #     pkgs.sddm-astronaut
  #   ];
  #   sddm.wayland.enable = false;
  #   sddm.wayland.compositorCommand =
  #     let
  #       xcfg = config.services.xserver;
  #       westonIni = (pkgs.formats.ini { }).generate "weston.ini" {
  #         libinput = {
  #           enable-tap = config.services.libinput.mouse.tapping;
  #           left-handed = config.services.libinput.mouse.leftHanded;
  #         };
  #         core = {
  #           idle-time = 15;
  #         };
  #         keyboard = {
  #           keymap_model = xcfg.xkb.model;
  #           keymap_layout = xcfg.xkb.layout;
  #           keymap_variant = xcfg.xkb.variant;
  #           keymap_options = xcfg.xkb.options;
  #         };
  #       };
  #     in
  #       "${pkgs.lib.getExe pkgs.weston} --idle-time=5 --shell=kiosk -c ${westonIni}";
  #   sddm.theme = "sddm-astronaut-theme";
  #   # enable = true;
  #   # defaultSession = "Hyprland";
  #   # ly.enable = true;
  #   # autoLogin = {
  #   #   enable = true;
  #   #   user = config.user;
  #   # };
  # };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;
  modules.hjkl.enable = true;
  modules.keyrings.enable = true;

  users.users.${config.user} = {
    isNormalUser = true;
    extraGroups =
      [ "corectrl" "gamemode" "wheel" "docker" ]; # Enable ‘sudo’ for the user.
  };

  users.defaultUserShell = pkgs.fish;
  programs.fish.enable = true;

  services = {
    dbus = {
      enable = true;
      packages = [ ];
    };
    cron = {
      enable = true;
      systemCronJobs = [
        # "00 20 * * * andrew fish -c 'sync_repos'"
      ];
    };
  };

  systemd.services.nix-daemon.serviceConfig = { MemoryMax = "2G"; };

  nix.settings.auto-optimise-store = true;
  nix.settings.trusted-users = [ "root" "andrew" ];
  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 1d";

  systemd.coredump.settings.Coredump.Storage = "none";

  modules.xdg.sessionVariables = true;
  modules.fonts.enable = true;
  modules.guake.enable = false;
  # modules.timed-lock.enable = false;
  # modules.timed-lock.time = "23:00:00";

  modules.darkman.enable = true;
  modules.vpn.enable = true;
  modules.vm.enable = false;
  modules.firefox.enable = true;

  zramSwap.enable = true;
  zramSwap.memoryPercent = 70;

  # programs.java = {
  #   enable = true;
  #   package = pkgs.oraclejre8;
  # };
  environment.systemPackages = with pkgs; [
    vim
    wget
    flameshot
    killall
    (sddm-astronaut.override {
      embeddedTheme = "black_hole";
      # themeConfig = {
      #   # FullBlur = true;
      #   # BlurRadius = 25;
      #   # PasswordFocus = false;
      # };
    })
    xdo
    inotify-tools
    (pkgs.python3.withPackages (ps: [
      ps.python-miio
      ps.pygobject-stubs
      ps.requests
      ps.pygobject3
      ps.lxml
    ]))
    my.pythonbin
    neovim
    gnome-disk-utility
    git
    ripgrep
    fd
    # TODO THEME
    kdePackages.breeze-gtk
    # libsForQt5.breeze-qt5
    nixfmt
    # gimp
    mpv
    playerctl
    brave
    gnome-system-monitor
    kdePackages.kdenlive
    libusb1
    ffmpeg
    peco
    xclip
    mc
    ranger
    xdotool
    tldr
    wofi
    # TODO THEME
    # libsForQt5.breeze-gtk
    # libsForQt5.breeze-qt5
    pasystray
    pavucontrol
    # cachix
    # deskflow
    paprefs
    # discord
    speedcrunch
    telegram-desktop
    # unstable-small.tdesktop
    jpegoptim
    # filelight
    gedit
    qbittorrent
    nautilus
    zip
    inetutils
    xsettingsd
    intel-gpu-tools
    nodejs
    # TODO THEME
    # iconpack-obsidian
    gsettings-desktop-schemas
    dunst
    # unstable.pythonPackages.yt-dlp
    # python39Packages.virtualenv
    # python39Packages.pip
    feh
    eog
    htop
    unzip
    my.get_current_screen_geometry
    # my.guake-latest
  ];
  services.openssh.enable = true;
  services.openssh.startWhenNeeded = false;

  networking.firewall.enable = false;
  system.stateVersion = "25.11"; # Did you read the comment?

}
