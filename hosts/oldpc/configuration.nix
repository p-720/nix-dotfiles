{ config, pkgs, self, ... }:

{
  imports = [
    ./hardware-configuration.nix
    # ./NVFanControl.nix
  ];
  modules.flakes.enable = true;
  modules.taffybar.enable = true;

  # users.users.andrew.extraGroups = ["corectrl" "gamemode"];
  # programs.corectrl ={
  #   enable = true;
  # };
  security.rtkit.enable = true;

  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [];

    extraPackages32 = with pkgs.driversi686Linux; [];
  };

  environment.variables = { ROC_ENABLE_PRE_VEGA = "1"; };

  # hardware.opengl.enable = true;
  # hardware.opengl.driSupport = true;
  # hardware.opengl.extraPackages = with pkgs; [ intel-vaapi-driver libva-vdpau-driver libvdpau-va-gl];
  # hardware.opengl.extraPackages32 = with pkgs.pkgsi686Linux; [ intel-vaapi-driver ];

  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.grub.enable = true;
  # boot.loader.grub.default = 2;
  # boot.loader.grub.version = 2;
  boot.blacklistedKernelModules = [ "iTCO_wdt" "iTCO_vendor_support" ];

  # boot.kernelPackages = pkgs.linuxPackages_lts;

  # TODO just use self.user 
  user = self.user;

  boot.tmpOnTmpfs = false;
  boot.tmp.cleanOnBoot = true;

  # TODO boot.loader.grub.device = "/dev/sda";

  # TODO extract
  networking.hostName = "${config.user}";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";

  # t3 ships a generic glibc binary; without nix-ld the stub loader refuses it (exit 127)
  programs.nix-ld.enable = true;

  services.gvfs.enable = true;
  services.udev.extraRules = ''
    SUBSYSTEM=="usb", ACTION=="add", ATTR{idVendor}=="0e8d", ATTR{idProduct}=="201d" MODE="0777" GROUP="users"
    KERNEL=="ttyUSB*", MODE="0666"
  '';

  modules.nvidia.enable = true;

  hardware.nvidia = {
    modesetting.enable = true;
    nvidiaSettings = true;
    # package = pkgs.unstable.linuxKernel.packages.linux_zen.nvidia_x11;
    powerManagement = {
      enable = false;
      finegrained = false;
    };
    # gsp.enable = false;
    open = true;
  };


  services.xserver = {
    enable = true;
    videoDrivers = [ "nvidia" ];
    dpi = 96;

    # Doesnt work
    xkb = {
      layout = "us,ru";
      options = "grp:alt_shift_toggle,compose:ralt";
    };
    # software 2D: no glamor, no NVIDIA X driver
    deviceSection = ''
      Option "AccelMethod" "none"
      Option "BackingStore" "false"
    '';
    serverFlagsSection = ''
  Option "BlankTime" "1"
  Option "StandbyTime" "1"
  Option "SuspendTime" "1"
  Option "OffTime" "1"
'';
    exportConfiguration = true;
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

  # modules.hypr = {
  #   enable = true;
  # };

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
    extraGroups = [ "corectrl" "gamemode" "wheel" "docker" ]; # Enable ‘sudo’ for the user.
  };

  users.defaultUserShell = pkgs.fish;
  programs.fish.enable = true;

  # HM sets dconf.settings (common.nix). Without this the session bus has no
  # ca.desrt.dconf.service, so dconfSettings activation dies and linkGeneration
  # never runs: home.file links stop updating.
  programs.dconf.enable = true;

  services = {
    dbus = {
      enable = true;
      packages = [];
    };
    cron = {
      enable = true;
      systemCronJobs = [
        # "00 20 * * * andrew fish -c 'sync_repos'"
      ];
    };
  };
  modules.printing3d.enable = true;

  systemd.services.nix-daemon.serviceConfig = {
    MemoryMax = "2G"; 
  };

  nix.settings.auto-optimise-store = true;
  nix.settings.trusted-users = [ "root" "andrew" ];
  nix.gc.automatic = true;
  nix.gc.options = "--delete-older-than 1d";

  # systemd.coredump.extraConfig = ''
  #   Storage=none
  # '';

  modules.xdg.sessionVariables = true;
  modules.fonts.enable = true;
  modules.guake.enable = false;

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
  environment.systemPackages = with pkgs;
    [
      vim
      wget
      flameshot
      killall
      xdo
      audacity
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
      t3-code
      peco
      xclip
      mc
      ranger
      insomnia
      xdotool
      pkgs.onlyoffice-desktopeditors
      claude-code
      stremio-linux-shell
      anki-bin
      tldr
      # (pkgs.wrapOBS.override {
      #   obs-studio = obs-studio.override { cudaSupport = true;};
      # } {
      #   plugins = with pkgs.obs-studio-plugins; [
      #     # obs-gstreamer
      #     # obs-vkcapture
      #     # obs-vaapi
      #     # wlrobs
      #     # droidcam-obs
      #     obs-multi-rtmp
      #   ];
      # })
      # (pkgs.wrapOBS.override {
      #   obs-studio = obs-studio.override { cudaSupport = true;};
      # } {
      #   plugins = with pkgs.unstable.obs-studio-plugins; [
      #     # obs-gstreamer
      #     # obs-vkcapture
      #     # obs-vaapi
      #     # wlrobs
      #     # droidcam-obs
      #   ];
      # })
      wofi
      # TODO THEME
      # libsForQt5.breeze-gtk
      # libsForQt5.breeze-qt5
      pasystray
      my.osu-lazer-bin
      unstable.opencode
      # my.opencode-baseline
      pavucontrol
      cachix
      # deskflow
      paprefs
      # discord
      speedcrunch
      telegram-desktop
      # unstable-small.tdesktop
      jpegoptim
      kdePackages.filelight
      my.anydesk
      unstable.rustdesk-bin
      my.ketch
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
