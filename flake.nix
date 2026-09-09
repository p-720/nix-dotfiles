{
  # --fake 8 --ttl 5
  # --disorder 1 --auto=torst --fake -1 --tlsrec 3+h
  # --fake -1 --md5sig
  description = "An example NixOS configuration";
  nixConfig = {
    substitute = true;
    extra-substituters = [
      "https://nix-community.cachix.org"
      "https://hyprland.cachix.org"
      "https://upgradegamma.cachix.org"
    ];
    extra-trusted-public-keys = [
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "upgradegamma.cachix.org-1:iIifduPUNZ9OrRYgaEcKTeRQxbqr2/FbiF1bboND05A="
    ];
  };
  # Searching github for packages:
  # %package_name% language:nix
  inputs = {
    nixpkgs = { url = "github:nixos/nixpkgs/nixos-26.05"; };
    max-messenger.url = "github:spiage/max-messenger";
    playwright-cli.url = "github:p-720/playwright-cli-flake";

    nixos-unstable.url = "nixpkgs/nixos-unstable";
    appblocker.url = "github:p-720/appblocker";
    nanobanana.url = "github:p-720/nanobanana";
    ai-shell.url = "github:p-720/ai-shell";
    void-editor.url = "github:bariscodefxy/void-editor-flake";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    hyprland.url = "github:hyprwm/Hyprland/";
    # hyprland = {
    #   url = "git+https://github.com/hyprwm/Hyprland.git?ref=v0.47.0";
    # };
    tdesktop = {
      url =
        "git+https://github.com/p-720/tdesktop.git?ref=refs/heads/p2d0_update&allRefs=1&submodules=1";
    };

    quickshell = {
      url = "git+https://git.outfoxxed.me/outfoxxed/quickshell";

      # THIS IS IMPORTANT
      # Mismatched system dependencies will lead to crashes and other issues.
      inputs.nixpkgs.follows = "nixpkgs";
    };

    poetry2nix.url = "github:nix-community/poetry2nix";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    compfy.url = "github:allusive-dev/compfy";
    spl3g-config.url = "github:spl3g/nixfiles";
    pomotasker.url = "github:p-720/todolist";
    todolist-web.url = "github:p-720/todolist-web";
    zen-browser.url = "github:0xc000022070/zen-browser-flake";
    nixpkgs-amnezia.url = "github:averyanalex/nixpkgs/amneziawg";
    # hy3 = {
    #   url = "github:outfoxxed/hy3?ref=hl0.47.0-1";
    #   inputs.hyprland.follows = "hyprland";
    # };
  };

  outputs = inputs@{ self, nixpkgs, poetry2nix, tdesktop, playwright-cli
    , zen-browser, compfy, nixos-unstable, void-editor, hyprland,
    nixpkgs-amnezia, nanobanana, ai-shell, home-manager, appblocker
    , spl3g-config, pomotasker, todolist-web, ... }:
    let
      lib = nixpkgs.lib.extend
        (self: super: { my = import ./lib/util.nix { lib = nixpkgs.lib; }; });
      nixpkgs-tars = "https://github.com/NixOS/nixpkgs/archive/";
      system = "x86_64-linux";
      mkPkgs = pkgs: extraOverlays:
        import pkgs {
          # TODO convert to pkg-sets https://github.com/nix-community/home-manager/issues/1538#issuecomment-706627100
          inherit system;
          config.allowBroken = true;
          config.allowUnfree = true; # forgive me Stallman senpai

          config.permittedInsecurePackages = [
            "qtwebengine-5.15.19"

            "python3.11-youtube-dl-2021.12.17"
            "mbedtls-2.28.10"
            "ventoy-gtk3-1.1.12"
            "qbittorrent-qt5-4.6.4"
            "libsoup-2.74.3"
            "dotnet-runtime-6.0.36"
            "dotnet-sdk-wrapped-6.0.428"
            "dotnet-sdk-6.0.428"
            "dotnet-runtime-wrapped-6.0.36"
            "qbittorrent-4.6.4"
            "docker-28.5.2"
            "ventoy-gtk3-1.1.10"
            "xrdp-0.9.9"
            "python-2.7.18.8-env"
            "python-2.7.18.8"
            "python-2.7.18.7-env"
            "python-2.7.18.7"
            "libdwarf-20181024"
            "python-2.7.18.6"
          ];
          overlays = [
            (self: super: {
              inherit lib;
              # fish get-pr-override 218037
              pr218037 = import (fetchTarball
                "${nixpkgs-tars}84963237b438319092a352a7d375878d82beb1ca.tar.gz") {
                  config = self.config;
                };
              amnezia = import nixpkgs-amnezia {
                inherit system;
                config = self.config;
              };
              flacpkgs = import (builtins.fetchTarball {
                url =
                  "https://github.com/NixOS/nixpkgs/archive/cea111161b02f1a823698038bfd01bc93607e391.tar.gz";
              }) { };
              # gvfspkgs = import (builtins.fetchTarball {
              #   url = "https://github.com/NixOS/nixpkgs/archive/c3f5dc69cdff75a054db50eec743e0693d296978.tar.gz";
              # }) {};

              quickshell = inputs.quickshell.packages.${system}.default;
              max-messenger = inputs.max-messenger.packages.${system}.default;
              void-editor = inputs.void-editor.packages.${system}.default;
              ai-shell = ai-shell.packages.${system}.default;
              pomotasker = pomotasker.packages.${system}.default;

              unstable = import nixos-unstable { config = self.config; };
              compfy = compfy.packages.${system}.compfy;
              zen-browser = zen-browser.packages.${system}.default;
              tdesktop_p-720 = tdesktop.packages.${system}.default;
              playwright-cli = playwright-cli.packages.${system}.default;
              # my = lib.my.mapModules ./pkgs (p:
              #   let eval = builtins.tryEval (self.callPackage p {});
              #   in
              #     if eval.success then eval.value else builtins.throw "Package error " ++ p );
              my = lib.my.mapModules ./pkgs
                (p: (self.callPackage (lib.debug.traceVal p) { }));
              tgs2png = spl3g-config.overlays.additions.tgs2png;
            })
          ] ++ extraOverlays;
        };
      pkgs = mkPkgs nixpkgs [
        poetry2nix.overlays.default
        spl3g-config.overlays.additions
        hyprland.overlays.hyprland
        hyprland.overlays.hyprland-packages
      ];
    in {
      inherit lib;

      user = "andrew";
      # TODO
      # buildSpecific = path: {
      #   pkgs.
      # }
      # overlay =
      #   final: prev: {
      #     my = lib.mapModules ./pkgs (p: pkgs.callPackage p {});
      #   };
      # homeManagerModules = lib.my.mapModulesRec /etc/nixos/modules/home-manager import;
      # nixosModules = lib.

      overlays = {
        default = final: prev: pkgs.my;
        # compfy = compfy;
      };
      # user-modules = (lib.my.mapModulesRec' ./modules/nixos (p: pkgs.callPackage p {}));

      # nix eval .#tests --impure
      # kek = pkgs.my.apollo;
      tests = pkgs.callPackage ./tests/default.nix { };
      nix.nixPath = [ "nixpkgs=${pkgs.path}" "unstable=${nixos-unstable}" ];

      nixosConfigurations = {
        mysystem = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = (lib.my.findAllModulePathsIn ./modules/nixos) ++ [
            { nixpkgs.pkgs = pkgs; }
            {
              # pin system nixpkgs to the same version as the flake input
              # (don't see a way to declaratively set channels but this seems to work fine?)
              nix.nixPath =
                [ "nixpkgs=${pkgs.path}" "unstable=${nixos-unstable}" ];
            }
            home-manager.nixosModules.home-manager
            appblocker.nixosModules.default
            nanobanana.nixosModules.default
            # hyprland.nixosModules.default
            ./home.nix
            ./hosts/main/configuration.nix
            ./hosts/common.nix
          ];
          specialArgs = { inherit self inputs lib; };
        };

        laptop = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = (lib.my.findAllModulePathsIn ./modules/nixos) ++ [
            { nixpkgs.pkgs = pkgs; }
            {
              # pin system nixpkgs to the same version as the flake input
              # (don't see a way to declaratively set channels but this seems to work fine?)
              nix.nixPath =
                [ "nixpkgs=${pkgs.path}" "unstable=${nixos-unstable}" ];
            }
            home-manager.nixosModules.home-manager
            appblocker.nixosModules.default
            nanobanana.nixosModules.default
            todolist-web.nixosModules.pomotasker
            # hyprland.nixosModules.default
            ./home-laptop.nix
            ./hosts/laptop/configuration.nix
            ./hosts/common.nix
          ];
          specialArgs = { inherit self inputs lib; };
        };

        oldpc = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = (lib.my.findAllModulePathsIn ./modules/nixos) ++ [
            { nixpkgs.pkgs = pkgs; }
            {
              # pin system nixpkgs to the same version as the flake input
              # (don't see a way to declaratively set channels but this seems to work fine?)
              nix.nixPath =
                [ "nixpkgs=${pkgs.path}" "unstable=${nixos-unstable}" ];
            }
            home-manager.nixosModules.home-manager
            appblocker.nixosModules.default
            nanobanana.nixosModules.default
            # hyprland.nixosModules.default
            ./home-oldpc.nix
            ./hosts/oldpc/configuration.nix
            ./hosts/common.nix
          ];
          specialArgs = { inherit self inputs lib; };
        };

      };
    };
}
