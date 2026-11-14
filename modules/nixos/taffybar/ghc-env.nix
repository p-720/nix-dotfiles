{ lib, pkgs, ... }:

let
  # dyre shells out to `ghc` when taffybar.hs changes, so the session PATH needs
  # a ghc that already exposes the packages the config imports. Keep this list
  # in sync with the imports in taffybar.hs.
  #
  # Haskell packages only. The UTF-8 locale the bar needs is env at the launch
  # site (modules.taffybar.barEnv), and the TLS trust store is compiled into the
  # tls library, so neither is a package here.
  ghc = pkgs.haskellPackages.ghcWithPackages (p: [
    p.X11
    # pomotaskWidget: TLS websocket + habits fetch, hand-rolled because nixpkgs has
    # no websocket/wuss client (wuss needs the missing `websockets` package).
    p.aeson
    p.base64-bytestring
    p.bytestring
    p.containers
    p.crypton-connection
    p.directory
    p.enclosed-exceptions
    p.filepath
    p.gi-gdk3
    p.gi-gdkpixbuf
    p.gi-gtk3
    p.gtk-sni-tray
    p.gtk-strut
    p.haskell-gi-base
    p.hostname
    p.hslogger
    p.http-types
    p.process
    p.random
    p.simple-cmd
    p.split
    p.taffybar
    p.text
    p.time
    p.transformers
    p.unix
    p.xdg-basedir
  ]);
in ghc
