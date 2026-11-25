{ appimageTools, fetchurl, lib, nix-update-script, pkgs }:

# jpackage app-image (Compose for Desktop): bin/Nuvio launcher + bundled JRE in
# lib/runtime, so nothing to build — only the libs the runtime dlopens have to
# come from the appimage FHS env. Alpha upstream: version is pinned per release.
let
  pname = "nuvio";
  version = "0.1.39-alpha";

  src = fetchurl {
    url = "https://github.com/NuvioMedia/NuvioDesktop/releases/download/${version}/Nuvio-Linux-x86_64-${version}.AppImage";
    sha256 = "sha256-sx86Ew5xShkWtVHdWkp+m7i1scyBSWap/gkp5XkrVvk=";
  };

  contents = appimageTools.extractType2 { inherit pname version src; };
in appimageTools.wrapType2 {
  inherit pname version src;

  # first run downloads libplayer_bridge.so into ~/.cache/nuvio, which dlopens
  # libmpv.so.2 and libwebkit2gtk-4.1.so.0; 26.05 has no libmpv attr (mpv ships
  # the .so in out)
  extraPkgs = p: with p; [ mpv webkitgtk_4_1 ];

  extraInstallCommands = ''
    mkdir -p $out/share/pixmaps $out/share/applications
    install -m 444 -D ${contents}/Nuvio.png $out/share/pixmaps/${pname}.png
    install -m 444 -D ${contents}/Nuvio.desktop $out/share/applications/${pname}.desktop
    substituteInPlace $out/share/applications/${pname}.desktop \
      --replace-fail 'Exec=AppRun' 'Exec=${pname}'
  '';

  passthru.updateScript = nix-update-script { };

  meta = {
    description = "Media library app that turns your own sources into a library";
    homepage = "https://github.com/NuvioMedia/NuvioDesktop";
    changelog = "https://github.com/NuvioMedia/NuvioDesktop/releases/tag/${version}";
    license = lib.licenses.gpl3Only;
    mainProgram = pname;
    platforms = lib.platforms.linux;
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
  };
}
