{ lib, pkgs, ... }:

let
  # dyre shells out to `ghc` when taffybar.hs changes, so the session PATH needs
  # a ghc that already exposes the packages the config imports. Keep this list
  # in sync with the imports in taffybar.hs.
  ghc = pkgs.haskellPackages.ghcWithPackages (p: [
    p.X11
    p.bytestring
    p.containers
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
