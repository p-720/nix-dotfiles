{ appimageTools, lib, fetchurl, makeDesktopItem, pkgs }:

# Upstream ships a prebuilt AppImage with the Flutter UI baked in; nixpkgs'
# source-built rustdesk lags the releases the user wants, so wrap the binary
# instead of building it.
let
  pname = "rustdesk-bin";
  version = "1.5.1";

  src = fetchurl {
    url =
      "https://github.com/rustdesk/rustdesk/releases/download/${version}/rustdesk-${version}-x86_64.AppImage";
    sha256 = "sha256-u4t8yz9QogHczcibRjhc/5DzPmC0cw+u2p+lUErE3OY=";
  };
in appimageTools.wrapType2 rec {
  inherit pname version src;

  # AppImage bundles its own Qt/Flutter libs but not the X11/ALSA libs it
  # links against, nor the external tools its shell helpers shell out to.
  extraPkgs = p: with p; [
    alsa-lib
    libGL
    libX11
    libXext
    libXfixes
    libxkbcommon
    libxcb
    openssl
    wayland
    which
  ];

  desktopItems = [ (makeDesktopItem {
    name = "rustdesk";
    exec = "rustdesk %U";
    icon = "rustdesk";
    desktopName = "RustDesk";
    genericName = "Remote Desktop";
    comment = "Open-source remote desktop application";
    categories = [ "Network" "RemoteAccess" ];
    mimeTypes = [ "x-scheme-handler/rustdesk" ];
  }) ];

  meta = with lib; {
    description = "Open-source virtual / remote desktop infrastructure";
    homepage = "https://rustdesk.com";
    license = licenses.gpl3Only;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with sourceTypes; [ binaryNativeCode ];
    mainProgram = "rustdesk";
  };
}
